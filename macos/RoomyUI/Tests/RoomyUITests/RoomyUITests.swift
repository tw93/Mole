import XCTest
@testable import RoomyUIPrivileged
@testable import RoomyUICore

final class RoomyUITests: XCTestCase {
    func testCommandBuilderProducesAPIArguments() {
        let builder = RoomyCommandBuilder(executableURL: URL(fileURLWithPath: "/tmp/roomy"))

        XCTAssertEqual(builder.arguments(for: .status), ["api", "status"])
        XCTAssertEqual(builder.arguments(for: .cleanupPreview), ["api", "clean", "preview", "--json"])
        XCTAssertEqual(
            builder.arguments(for: .externalCleanupPreview(path: "/Volumes/Backup")),
            ["api", "clean", "preview", "--json", "--external", "/Volumes/Backup"]
        )
        XCTAssertEqual(builder.arguments(for: .applications), ["api", "apps", "list", "--json"])
        XCTAssertEqual(builder.arguments(for: .storageScan(path: "/Users/example")), ["api", "storage", "scan", "--path", "/Users/example"])
        XCTAssertEqual(
            builder.arguments(for: .storageExecute(planURL: URL(fileURLWithPath: "/tmp/storage-plan.json"))),
            ["api", "storage", "execute", "--plan", "/tmp/storage-plan.json"]
        )
        XCTAssertEqual(builder.arguments(for: .optimizePreview), ["api", "optimize", "preview"])
        XCTAssertEqual(builder.arguments(for: .purgePreview), ["api", "purge", "preview", "--json"])
        XCTAssertEqual(builder.arguments(for: .installerPreview), ["api", "installer", "preview", "--json"])
        XCTAssertEqual(builder.arguments(for: .whitelist(mode: "clean")), ["api", "whitelist", "list", "--mode", "clean"])
        XCTAssertEqual(builder.arguments(for: .purgePaths), ["api", "purge", "paths", "--json"])
        XCTAssertEqual(builder.arguments(for: .maintenanceStatus), ["api", "update", "status"])
        XCTAssertEqual(builder.arguments(for: .touchIDStatus), ["api", "touchid", "status"])
        XCTAssertEqual(builder.arguments(for: .completionStatus), ["api", "completion", "status"])
        XCTAssertEqual(builder.arguments(for: .launcherStatus), ["api", "launchers", "status"])

        let planURL = URL(fileURLWithPath: "/tmp/plan.json")
        XCTAssertEqual(
            builder.arguments(for: .execute(domain: .clean, planURL: planURL)),
            ["api", "clean", "execute", "--plan", "/tmp/plan.json"]
        )
        XCTAssertEqual(
            builder.arguments(for: .touchIDExecute(action: "enable", planURL: planURL)),
            ["api", "touchid", "execute", "--action", "enable", "--plan", "/tmp/plan.json"]
        )
        XCTAssertEqual(
            builder.arguments(for: .completionExecute(planURL: planURL)),
            ["api", "completion", "execute", "--plan", "/tmp/plan.json"]
        )
        XCTAssertEqual(
            builder.arguments(for: .launcherExecute(planURL: planURL)),
            ["api", "launchers", "execute", "--plan", "/tmp/plan.json"]
        )
        XCTAssertEqual(
            builder.arguments(for: .purgePathsUpdate(planURL: planURL)),
            ["api", "purge", "paths", "update", "--plan", "/tmp/plan.json"]
        )
        XCTAssertEqual(
            builder.arguments(for: .execute(domain: .update, planURL: planURL)),
            ["api", "update", "execute", "--plan", "/tmp/plan.json"]
        )
        XCTAssertEqual(
            builder.arguments(for: .execute(domain: .remove, planURL: planURL)),
            ["api", "remove", "execute", "--plan", "/tmp/plan.json"]
        )
    }

    func testCLIPathResolverHonorsEnvironmentOverride() {
        let resolved = RoomyCLIPathResolver.resolve(
            environment: ["ROOMY_CLI_PATH": "/custom/roomy"],
            currentDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(resolved.path, "/custom/roomy")
    }

    func testCLIPathResolverUsesBundledProjectRootMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let project = root.appendingPathComponent("RoomyProject", isDirectory: true)
        let cli = project.appendingPathComponent("roomy")

        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try project.path.write(
            to: resources.appendingPathComponent("roomy-project-root"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = RoomyCLIPathResolver.resolve(
            environment: [:],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            bundleResourceURL: resources,
            bundleExecutableURL: nil
        )

        XCTAssertEqual(resolved.path, cli.path)
    }

    func testRunProcessDrainsLargeOutputBeforeExit() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        i=0
        while [ "$i" -lt 5000 ]; do
          printf '0123456789abcdef0123456789abcdef\\n'
          i=$((i + 1))
        done
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        let data = try await client.runProcess(.status)

        XCTAssertGreaterThan(data.count, 160_000)
    }

    func testAdministratorProcessUsesPrivilegedHelperRunner() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-admin-plan-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)

        let runner = RecordingPrivilegedRunner(result: PrivilegedCommandResult(
            exitCode: 0,
            standardOutput: Data(#"{"event":"completed","domain":"clean","exit_code":0}"#.utf8),
            standardError: Data()
        ))
        let script = try makeExecutableScript("#!/bin/sh\n")
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 12, privilegedRunner: runner)

        let data = try await client.runAdministratorProcess(.execute(domain: .clean, planURL: planURL))

        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"event":"completed","domain":"clean","exit_code":0}"#)
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands.first?.arguments, ["api", "clean", "execute", "--plan", planURL.path])
        XCTAssertEqual(runner.commands.first?.timeoutSeconds, 12)
    }

    func testRunProcessTimesOutHungCommand() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        sleep 2
        printf '{}\\n'
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 0.1)

        do {
            _ = try await client.runProcess(.status)
            XCTFail("Expected timeout")
        } catch RoomyAPIError.timedOut(let command, let seconds) {
            XCTAssertTrue(command.contains("api status"))
            XCTAssertEqual(seconds, 0.1, accuracy: 0.01)
        } catch {
            XCTFail("Expected RoomyAPIError.timedOut, got \(error)")
        }
    }

    @MainActor
    func testHomeLoadAvoidsProtectedPreviewScansOnStartup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let callsLog = root.appendingPathComponent("calls.log")
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(callsLog.path)"
        if [ "$1 $2" = "api status" ]; then
          printf '%s\\n' '{"health_score":91,"gpu":[],"disks":[],"batteries":[],"network":[],"top_processes":[],"process_alerts":[]}'
          exit 0
        fi
        if [ "$1 $2 $3" = "api optimize preview" ]; then
          printf '%s\\n' '{"schema_version":1,"memory_used_gb":1,"memory_total_gb":2,"disk_used_percent":40,"optimizations":[]}'
          exit 0
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)

        await model.loadHome()

        let calls = try String(contentsOf: callsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(calls, ["api status"])
        XCTAssertEqual(model.status?.healthScore, 91)
        XCTAssertNil(model.optimizePreview)
    }

    @MainActor
    func testCleanMyMacFlowPreviewsThenExecutesGuardedCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-clean-my-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let callsLog = root.appendingPathComponent("calls.log")
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(callsLog.path)"
        if [ "$1 $2 $3 $4" = "api clean preview --json" ]; then
          printf '%s\\n' '{"schema_version":1,"command":"clean.preview","dry_run":true,"status":"success","estimated_bytes":4096,"item_count":2,"category_count":1,"skipped_count":3,"protected_count":2,"whitelist_count":1,"admin_required":false,"delete_mode":"trash","details_path":"/tmp/clean-list.txt","categories":[{"section":"User essentials","name":"User app cache","estimated_bytes":4096,"item_count":2,"skipped_count":0,"risk":"LOW","risk_reason":"Cache/log files, automatically regenerated","admin_required":false}]}'
          exit 0
        fi
        if [ "$1 $2 $3" = "api clean execute" ] && [ "$4" = "--plan" ]; then
          grep -q '"confirmed" : true' "$5" || exit 65
          printf '%s\\n' '{"event":"started","domain":"clean"}'
          sleep 0.1
          printf '%s\\n' '{"event":"completed","domain":"clean","exit_code":0,"bytes":4096,"item_count":2,"category_count":1}'
          sleep 0.1
          exit 0
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)

        await model.prepareCleanMyMac()
        await model.executeCleanMyMac()

        let calls = try String(contentsOf: callsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(calls.first, "api clean preview --json")
        XCTAssertTrue(calls.dropFirst().first?.hasPrefix("api clean execute --plan ") == true)
        XCTAssertEqual(model.cleanupPreview?.estimatedBytes, 4096)
        XCTAssertEqual(model.cleanupPreview?.deleteMode, "trash")
        XCTAssertEqual(model.cleanupPreview?.protectedCount, 2)
        XCTAssertEqual(model.executionEvents.map(\.event), ["started", "completed"])
        XCTAssertEqual(model.executionEvents.last?.bytes, 4096)
        XCTAssertEqual(model.executionState, .completed)
    }

    func testFullDiskAccessDetectorSummarizesProbeResults() {
        let enabled = RoomyFullDiskAccessDetector.status(for: [
            FullDiskAccessProbe(path: "/Users/example/Library/Mail", exists: true, readable: true)
        ])
        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertEqual(enabled.displayValue, "Enabled")

        let limited = RoomyFullDiskAccessDetector.status(for: [
            FullDiskAccessProbe(path: "/Users/example/Library/Mail", exists: true, readable: false, errorDescription: "Operation not permitted")
        ])
        XCTAssertEqual(limited.state, .limited)
        XCTAssertTrue(limited.detail.contains("Full Disk Access"))

        let unknown = RoomyFullDiskAccessDetector.status(for: [
            FullDiskAccessProbe(path: "/Users/example/Library/Mail", exists: false, readable: false)
        ])
        XCTAssertEqual(unknown.state, .unknown)
    }

    func testPermissionDeniedErrorsBecomeActionableMessages() {
        let message = RoomyViewModel.userFacingMessage("find: /Users/example/Library/Mail: Operation not permitted")

        XCTAssertEqual(
            message,
            "macOS denied access to part of the scan. Enable Full Disk Access once in System Settings, or choose a narrower folder and try again."
        )

        let event = ExecutionEvent(event: "failed", domain: "storage", message: "Permission denied", exitCode: 1)
        XCTAssertEqual(RoomyViewModel.transition(from: .running, event: event), .failed(message))
    }

    func testOperationJournalReadsNewestEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = root.appendingPathComponent("operation_journal.jsonl")
        let lines = [
            #"{"schema_version":1,"timestamp":"2026-05-12 01:00:00","record_type":"operation","command":"clean","action":"TRASHED","path":"/tmp/a","detail":"1 KB"}"#,
            #"{"schema_version":1,"timestamp":"2026-05-12 01:01:00","record_type":"event","source":"api","payload":{"event":"completed","domain":"storage","message":"Scan complete","exit_code":0,"item_count":3}}"#
        ]
        try lines.joined(separator: "\n").write(to: journal, atomically: true, encoding: .utf8)

        let entries = RoomyAPIClient.readOperationJournal(url: journal, limit: 2)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "Storage completed")
        XCTAssertEqual(entries[0].summary, "Scan complete")
        XCTAssertEqual(entries[1].title, "Clean TRASHED")
        XCTAssertEqual(entries[1].summary, "/tmp/a")
    }

    func testStreamEventsYieldsBeforeProcessExit() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"test"}'
        sleep 1
        printf '%s\\n' '{"event":"completed","domain":"test","exit_code":0}'
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let start = Date()
        var firstOffset: TimeInterval?
        var events: [ExecutionEvent] = []

        for try await event in client.streamEvents(.status) {
            if firstOffset == nil {
                firstOffset = Date().timeIntervalSince(start)
            }
            events.append(event)
        }

        let total = Date().timeIntervalSince(start)
        XCTAssertLessThan(firstOffset ?? 10, total - 0.25)
        XCTAssertGreaterThan(total, 0.9)
        XCTAssertEqual(events.map(\.event), ["started", "completed"])
    }

    func testStreamEventsFailsWhenProcessExitsAfterPartialEvent() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"test"}'
        exit 7
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            for try await _ in client.streamEvents(.status) {}
            XCTFail("Expected process failure")
        } catch RoomyAPIError.processFailed(let status, _) {
            XCTAssertEqual(status, 7)
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testCleanupPreviewDecodesContract() throws {
        let json = """
        {
          "schema_version": 1,
          "command": "clean.preview",
          "dry_run": true,
          "status": "success",
          "estimated_bytes": 2048,
          "item_count": 2,
          "category_count": 1,
          "skipped_count": 1,
          "protected_count": 1,
          "whitelist_count": 0,
          "admin_required": false,
          "delete_mode": "trash",
          "details_path": "/Users/example/.config/roomy/clean-list.txt",
          "categories": [
            {
              "section": "User essentials",
              "name": "User app cache",
              "estimated_bytes": 2048,
              "item_count": 2,
              "skipped_count": 1,
              "risk": "LOW",
              "risk_reason": "Cache/log files, automatically regenerated",
              "admin_required": false
            }
          ]
        }
        """

        let preview = try JSONDecoder().decode(CleanupPreview.self, from: Data(json.utf8))

        XCTAssertEqual(preview.schemaVersion, 1)
        XCTAssertEqual(preview.estimatedBytes, 2048)
        XCTAssertEqual(preview.categories.first?.name, "User app cache")
        XCTAssertEqual(preview.categories.first?.risk, "LOW")
    }

    func testApplicationListDecodesContract() throws {
        let json = """
        {
          "schema_version": 1,
          "apps": [
            {
              "name": "Slack",
              "bundle_id": "com.tinyspeck.slackmacgap",
              "source": "Homebrew",
              "uninstall_name": "slack",
              "path": "/Applications/Slack.app",
              "size": "180MB"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(ApplicationListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.apps.count, 1)
        XCTAssertEqual(response.apps[0].uninstallName, "slack")
        XCTAssertEqual(response.apps[0].source, "Homebrew")
    }

    private func makeExecutableScript(_ contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("roomy")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testPreviewExecutionStateTransitions() {
        let started = ExecutionEvent(event: "started", domain: "clean", message: nil, exitCode: nil)
        let completed = ExecutionEvent(event: "completed", domain: "clean", message: nil, exitCode: 0)
        let failed = ExecutionEvent(event: "failed", domain: "clean", message: "Plan refused", exitCode: 1)

        XCTAssertEqual(RoomyViewModel.transition(from: .previewReady, event: started), .running)
        XCTAssertEqual(RoomyViewModel.transition(from: .running, event: completed), .completed)
        XCTAssertEqual(RoomyViewModel.transition(from: .running, event: failed), .failed("Plan refused"))
    }

    func testStorageCleanupPreviewsDecodeContracts() throws {
        let purgeJSON = """
        {
          "schema_version": 1,
          "command": "purge.preview",
          "estimated_bytes": 4096,
          "item_count": 1,
          "search_paths": ["/Users/example/Projects"],
          "items": [
            {
              "name": "node_modules",
              "path": "/Users/example/Projects/App/node_modules",
              "project_root": "/Users/example/Projects/App",
              "bytes": 4096,
              "recent": false,
              "age_days": 18
            }
          ]
        }
        """

        let installerJSON = """
        {
          "schema_version": 1,
          "command": "installer.preview",
          "estimated_bytes": 2048,
          "item_count": 1,
          "items": [
            {
              "name": "Example.dmg",
              "path": "/Users/example/Downloads/Example.dmg",
              "source": "Downloads",
              "bytes": 2048
            }
          ]
        }
        """

        let purge = try JSONDecoder().decode(PurgePreview.self, from: Data(purgeJSON.utf8))
        let installers = try JSONDecoder().decode(InstallerPreview.self, from: Data(installerJSON.utf8))

        XCTAssertEqual(purge.items.first?.name, "node_modules")
        XCTAssertEqual(purge.items.first?.ageDays, 18)
        XCTAssertEqual(installers.items.first?.source, "Downloads")
        XCTAssertEqual(installers.estimatedBytes, 2048)
    }

    func testSettingsContractsDecode() throws {
        let whitelistJSON = """
        {
          "schema_version": 1,
          "mode": "clean",
          "items": [
            {
              "name": "Playwright browser binaries",
              "pattern": "~/Library/Caches/ms-playwright*",
              "category": "ai_ml_cache",
              "selected": true
            }
          ]
        }
        """

        let purgePathsJSON = """
        {
          "schema_version": 1,
          "config_path": "/Users/example/.config/roomy/purge_paths",
          "paths": ["/Users/example/Projects"],
          "default_paths": ["/Users/example/Projects", "/Users/example/Code"]
        }
        """

        let touchIDJSON = """
        {
          "schema_version": 1,
          "configured": false,
          "supported": true,
          "sudo_file": "/etc/pam.d/sudo",
          "sudo_local_file": "/etc/pam.d/sudo_local"
        }
        """

        let completionJSON = """
        {
          "schema_version": 1,
          "shell": "zsh",
          "config_file": "/Users/example/.zshrc",
          "installed": false,
          "command_name": "roomy"
        }
        """

        let launcherJSON = """
        {
          "schema_version": 1,
          "raycast_dir": "/Users/example/Library/Application Support/Raycast/script-commands",
          "raycast_installed": true,
          "raycast_count": 5,
          "alfred_dir": "/Users/example/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows",
          "alfred_available": false,
          "alfred_installed": false,
          "alfred_count": 0,
          "command_count": 5,
          "commands": [
            {
              "command": "clean",
              "title": "Roomy Clean",
              "raycast_installed": true,
              "alfred_installed": false
            }
          ]
        }
        """

        let maintenanceJSON = """
        {
          "schema_version": 1,
          "version": "1.38.0",
          "channel": "stable",
          "commit": "",
          "install_method": "local",
          "cli_path": "/Users/example/Roomy/roomy",
          "config_path": "/Users/example/.config/roomy"
        }
        """

        let whitelist = try JSONDecoder().decode(WhitelistResponse.self, from: Data(whitelistJSON.utf8))
        let purgePaths = try JSONDecoder().decode(PurgePathsResponse.self, from: Data(purgePathsJSON.utf8))
        let touchID = try JSONDecoder().decode(TouchIDStatus.self, from: Data(touchIDJSON.utf8))
        let completion = try JSONDecoder().decode(CompletionStatus.self, from: Data(completionJSON.utf8))
        let launchers = try JSONDecoder().decode(LauncherStatus.self, from: Data(launcherJSON.utf8))
        let maintenance = try JSONDecoder().decode(RoomyMaintenanceStatus.self, from: Data(maintenanceJSON.utf8))

        XCTAssertTrue(whitelist.items[0].selected)
        XCTAssertEqual(purgePaths.paths, ["/Users/example/Projects"])
        XCTAssertTrue(touchID.supported)
        XCTAssertFalse(touchID.configured)
        XCTAssertEqual(completion.shell, "zsh")
        XCTAssertFalse(completion.installed)
        XCTAssertTrue(launchers.raycastInstalled)
        XCTAssertEqual(launchers.commands.first?.title, "Roomy Clean")
        XCTAssertEqual(maintenance.version, "1.38.0")
        XCTAssertEqual(maintenance.installMethod, "local")
    }

    func testStatusSnapshotDecodesMonitorSignals() throws {
        let json = """
        {
          "hardware": {
            "model": "MacBook Air",
            "cpu_model": "Apple M2",
            "total_ram": "16.0 GB"
          },
          "health_score": 91,
          "cpu": { "usage": 12.5, "logical_cpu": 8 },
          "gpu": [
            { "name": "Apple M2", "usage": -1, "core_count": 8, "note": "integrated" }
          ],
          "memory": { "used": 1, "total": 2, "used_percent": 50 },
          "disks": [],
          "disk_io": { "read_rate": 1.2, "write_rate": 3.4 },
          "proxy": { "enabled": true, "type": "TUN", "host": "utun0+" },
          "thermal": { "battery_temp": 31, "fan_speed": 0, "system_power": 5.5 },
          "bluetooth": [
            { "name": "Keyboard", "connected": true, "battery": "80%" }
          ],
          "network": [],
          "top_processes": [],
          "process_alerts": []
        }
        """

        let status = try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(status.hardware?.model, "MacBook Air")
        XCTAssertEqual(status.gpu.first?.coreCount, 8)
        XCTAssertEqual(status.diskIO?.writeRate, 3.4)
        XCTAssertEqual(status.proxy?.type, "TUN")
        XCTAssertEqual(status.bluetooth.first?.name, "Keyboard")
    }

    func testExecutionPlanEncodesSafetyKeys() throws {
        let plan = ExecutionPlan(
            confirmed: true,
            dryRun: true,
            targets: ["/tmp/demo.dmg"],
            paths: ["/Users/example/Projects"],
            externalPath: "/Volumes/Backup",
            scanPath: "/Users/example/Downloads",
            operation: "trash",
            force: true,
            nightly: false
        )
        let data = try JSONEncoder().encode(plan)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(text.contains("\"confirmed\":true"))
        XCTAssertTrue(text.contains("\"dry_run\":true"))
        XCTAssertTrue(text.contains("\"targets\""))
        XCTAssertTrue(text.contains("\"paths\""))
        XCTAssertTrue(text.contains("\"external_path\":\"\\/Volumes\\/Backup\""))
        XCTAssertTrue(text.contains("\"scan_path\":\"\\/Users\\/example\\/Downloads\""))
        XCTAssertTrue(text.contains("\"operation\":\"trash\""))
        XCTAssertTrue(text.contains("\"force\":true"))
        XCTAssertTrue(text.contains("\"nightly\":false"))
    }

    func testExecutionEventDecodesCleanupMetrics() throws {
        let json = """
        {
          "event": "completed",
          "domain": "clean",
          "exit_code": 0,
          "bytes": 13743895347,
          "item_count": 488,
          "category_count": 41,
          "free_space": "47Gi",
          "equivalent": "Equivalent to ~2 4K movies of storage."
        }
        """

        let event = try JSONDecoder().decode(ExecutionEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.event, "completed")
        XCTAssertEqual(event.bytes, 13_743_895_347)
        XCTAssertEqual(event.itemCount, 488)
        XCTAssertEqual(event.categoryCount, 41)
        XCTAssertEqual(event.freeSpace, "47Gi")
        XCTAssertEqual(event.equivalent, "Equivalent to ~2 4K movies of storage.")
    }

    func testCleanupByteFormatterMatchesCLISummaryStyle() {
        XCTAssertEqual(Formatters.cleanupBytes(12_800_000_000), "12.80GB")
        XCTAssertEqual(Formatters.cleanupBytes(12_850_000), "12.8MB")
        XCTAssertEqual(Formatters.cleanupBytes(12_800), "13KB")
        XCTAssertEqual(Formatters.cleanupBytes(488), "488B")
    }

    func testPrivilegedCommandPolicyOnlyAllowsRoomyExecutePlans() throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-policy-plan-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)

        let command = try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", planURL.path],
            environment: [
                "HOME": "/Users/example",
                "PATH": "/tmp/unsafe",
                "ROOMY_CLI_PATH": "/tmp/unsafe-roomy",
                "UNSAFE": "1",
                "TERM": "xterm-256color"
            ],
            timeoutSeconds: 5
        )

        XCTAssertEqual(command.arguments[1], "clean")
        XCTAssertEqual(command.environment["HOME"], "/Users/example")
        XCTAssertEqual(command.environment["PATH"], PrivilegedCommandPolicy.safePath)
        XCTAssertEqual(command.environment["TERM"], "xterm-256color")
        XCTAssertNil(command.environment["ROOMY_CLI_PATH"])
        XCTAssertNil(command.environment["UNSAFE"])

        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/bin/sh",
            arguments: ["-c", "id"],
            environment: [:],
            timeoutSeconds: 5
        ))

        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "status"],
            environment: [:],
            timeoutSeconds: 5
        ))

        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", planURL.path],
            environment: [:],
            timeoutSeconds: PrivilegedCommandPolicy.maxTimeoutSeconds + 1
        ))
    }

    func testPrivilegedCommandPolicyValidatesPlanFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let invalidJSON = root.appendingPathComponent("invalid.json")
        try #"{"confirmed":true"#.write(to: invalidJSON, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", invalidJSON.path],
            environment: [:],
            timeoutSeconds: 5
        )) { error in
            XCTAssertTrue(String(describing: error).contains("invalid JSON"))
        }

        let unconfirmed = root.appendingPathComponent("unconfirmed.json")
        try #"{"confirmed":false}"#.write(to: unconfirmed, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", unconfirmed.path],
            environment: [:],
            timeoutSeconds: 5
        ))

        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: PrivilegedCommandPolicy.maxPlanBytes + 1).write(to: oversized)
        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", oversized.path],
            environment: [:],
            timeoutSeconds: 5
        ))

        let realPlan = root.appendingPathComponent("real.json")
        let symlinkPlan = root.appendingPathComponent("symlink.json")
        try #"{"confirmed":true}"#.write(to: realPlan, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkPlan, withDestinationURL: realPlan)
        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", symlinkPlan.path],
            environment: [:],
            timeoutSeconds: 5
        ))
    }
}

private final class RecordingPrivilegedRunner: RoomyPrivilegedCommandRunning {
    var commands: [PrivilegedCommand] = []
    var result: PrivilegedCommandResult

    init(result: PrivilegedCommandResult) {
        self.result = result
    }

    func run(command: PrivilegedCommand) async throws -> PrivilegedCommandResult {
        commands.append(command)
        return result
    }
}
