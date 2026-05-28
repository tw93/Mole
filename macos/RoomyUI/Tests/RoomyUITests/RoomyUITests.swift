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

    func testNonStreamingExecutionRejectsSuccessfulCommandWithoutEvents() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-empty-exec-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' 'done'
        exit 0
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            _ = try await client.execute(domain: .clean, planURL: planURL)
            XCTFail("Expected invalid event output failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.contains("without emitting execution events"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testNonStreamingExecutionRejectsSuccessfulCommandWithoutTerminalEvent() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-started-exec-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"clean"}'
        exit 0
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            _ = try await client.execute(domain: .clean, planURL: planURL)
            XCTFail("Expected missing terminal event failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.contains("without emitting a terminal execution event"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testNonStreamingExecutionRejectsCompletedEventWithNonzeroExitCode() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-bad-completed-exec-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"completed","domain":"clean","exit_code":2}'
        exit 0
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            _ = try await client.execute(domain: .clean, planURL: planURL)
            XCTFail("Expected nonzero completed event failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 2)
            XCTAssertTrue(message.contains("completed event reported status 2"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testNonStreamingExecutionRejectsFailedCommandWithoutTerminalEvent() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-failed-started-exec-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"clean"}'
        exit 7
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            _ = try await client.execute(domain: .clean, planURL: planURL)
            XCTFail("Expected failed process event validation")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 7)
            XCTAssertTrue(message.contains("without emitting a failed terminal execution event"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testNonStreamingExecutionRejectsFailedCommandWithCompletedTerminalOnly() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-failed-completed-exec-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"completed","domain":"clean","exit_code":0}'
        exit 7
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            _ = try await client.execute(domain: .clean, planURL: planURL)
            XCTFail("Expected failed process event validation")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 7)
            XCTAssertTrue(message.contains("without emitting a failed terminal execution event"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testNonStreamingExecutionReturnsFailedTerminalEventsFromFailedCommand() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-failed-terminal-exec-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"clean"}'
        printf '%s\\n' '{"event":"failed","domain":"clean","message":"plan refused","exit_code":7}'
        exit 7
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        let events = try await client.execute(domain: .clean, planURL: planURL)

        XCTAssertEqual(events.map(\.event), ["started", "failed"])
        XCTAssertEqual(events.last?.message, "plan refused")
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
    func testLoadingStateRemainsActiveForOverlappingLoads() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        if [ "$1 $2" = "api status" ]; then
          sleep 1
          printf '%s\\n' '{"health_score":91,"gpu":[],"disks":[],"batteries":[],"network":[],"top_processes":[],"process_alerts":[]}'
          exit 0
        fi
        if [ "$1 $2 $3" = "api optimize preview" ]; then
          sleep 2
          printf '%s\\n' '{"memory_used_gb":1,"memory_total_gb":2,"disk_used_gb":20,"disk_total_gb":50,"disk_used_percent":40,"uptime_days":1,"optimizations":[]}'
          exit 0
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)

        let statusTask = Task { @MainActor in
            await model.loadStatus()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let optimizeTask = Task { @MainActor in
            await model.loadOptimizePreview()
        }
        try await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertTrue(model.isLoading)

        await statusTask.value
        XCTAssertTrue(model.isLoading)

        await optimizeTask.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.status?.healthScore, 91)
        XCTAssertEqual(model.optimizePreview?.memoryTotalGB, 2)
    }

    @MainActor
    func testSectionErrorsDoNotLeakIntoOtherScreens() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        if [ "$1 $2" = "api status" ]; then
          printf '%s\\n' '{"error":{"message":"monitor probe failed"}}' >&2
          exit 70
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)
        model.selectedSection = .cleanup

        await model.loadStatus()

        XCTAssertNil(model.error(for: .cleanup))
        XCTAssertNil(model.error(for: .storage))
        XCTAssertEqual(model.error(for: .monitor), "roomy failed with status 70: monitor probe failed")
        XCTAssertEqual(model.errorMessage, "roomy failed with status 70: monitor probe failed")
        XCTAssertEqual(model.executionState, .idle)
    }

    @MainActor
    func testSettingsLoadKeepsSuccessfulPanelsWhenOneEndpointFails() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        if [ "$1 $2 $3 $4 $5" = "api whitelist list --mode clean" ]; then
          printf '%s\\n' '{"schema_version":1,"mode":"clean","items":[{"name":"Caches","pattern":"~/Library/Caches/*","category":"cache","selected":true}]}'
          exit 0
        fi
        if [ "$1 $2 $3 $4 $5" = "api whitelist list --mode optimize" ]; then
          printf '%s\\n' '{"error":{"message":"optimize whitelist broke"}}' >&2
          exit 72
        fi
        if [ "$1 $2 $3 $4" = "api purge paths --json" ]; then
          printf '%s\\n' '{"schema_version":1,"config_path":"/tmp/purge_paths","paths":["/Users/example/Projects"],"default_paths":["/Users/example/Projects"]}'
          exit 0
        fi
        if [ "$1 $2" = "api touchid" ] && [ "$3" = "status" ]; then
          printf '%s\\n' '{"schema_version":1,"configured":false,"supported":true,"sudo_file":"/etc/pam.d/sudo","sudo_local_file":"/etc/pam.d/sudo_local"}'
          exit 0
        fi
        if [ "$1 $2" = "api completion" ] && [ "$3" = "status" ]; then
          printf '%s\\n' '{"schema_version":1,"shell":"zsh","config_file":"/Users/example/.zshrc","installed":false,"command_name":"roomy"}'
          exit 0
        fi
        if [ "$1 $2" = "api launchers" ] && [ "$3" = "status" ]; then
          printf '%s\\n' '{"schema_version":1,"raycast_dir":"/tmp/raycast","raycast_installed":true,"raycast_count":5,"alfred_dir":"/tmp/alfred","alfred_available":false,"alfred_installed":false,"alfred_count":0,"command_count":5,"commands":[{"command":"clean","title":"Roomy Clean","raycast_installed":true,"alfred_installed":false}]}'
          exit 0
        fi
        if [ "$1 $2" = "api update" ] && [ "$3" = "status" ]; then
          printf '%s\\n' '{"schema_version":1,"version":"1.39.0","channel":"stable","commit":"","install_method":"local","cli_path":"/tmp/roomy","config_path":"/tmp/config"}'
          exit 0
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)
        model.selectedSection = .settings

        await model.loadSettings()

        XCTAssertEqual(model.cleanWhitelist?.items.first?.name, "Caches")
        XCTAssertNil(model.optimizeWhitelist)
        XCTAssertEqual(model.purgePaths?.paths, ["/Users/example/Projects"])
        XCTAssertEqual(model.touchIDStatus?.supported, true)
        XCTAssertEqual(model.completionStatus?.shell, "zsh")
        XCTAssertEqual(model.launcherStatus?.commands.first?.title, "Roomy Clean")
        XCTAssertEqual(model.maintenanceStatus?.version, "1.39.0")
        XCTAssertTrue(model.error(for: .settings)?.contains("Performance protection: roomy failed with status 72: optimize whitelist broke") == true)
        if case .failed(let message) = model.executionState {
            XCTAssertTrue(message.contains("Performance protection"))
        } else {
            XCTFail("Expected failed settings state")
        }
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
          mode=$(stat -f %Lp "$5" 2>/dev/null || stat -c %a "$5" 2>/dev/null || printf unknown)
          printf 'mode:%s\\n' "$mode" >> "\(callsLog.path)"
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
        let executeCall = try XCTUnwrap(calls.dropFirst().first)
        XCTAssertTrue(executeCall.hasPrefix("api clean execute --plan "))
        let planPath = String(executeCall.dropFirst("api clean execute --plan ".count))
        XCTAssertTrue(calls.contains("mode:600"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: planPath))
        XCTAssertEqual(model.cleanupPreview?.estimatedBytes, 4096)
        XCTAssertEqual(model.cleanupPreview?.deleteMode, "trash")
        XCTAssertEqual(model.cleanupPreview?.protectedCount, 2)
        XCTAssertEqual(model.executionEvents.map(\.event), ["started", "completed"])
        XCTAssertEqual(model.executionEvents.last?.bytes, 4096)
        XCTAssertEqual(model.executionState, .completed)
    }

    @MainActor
    func testExecutionFailureUpdatesStateAfterSectionChanges() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        if [ "$1 $2 $3" = "api clean execute" ] && [ "$4" = "--plan" ]; then
          printf '%s\\n' '{"event":"started","domain":"clean"}'
          sleep 0.5
          printf '%s\\n' 'not-json'
          exit 0
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)
        model.selectedSection = .cleanup

        let task = Task { @MainActor in
            await model.execute(domain: .clean, plan: ExecutionPlan(confirmed: true))
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        model.selectedSection = .monitor
        await task.value

        XCTAssertEqual(model.executionEvents.map(\.event), ["started"])
        XCTAssertEqual(model.error(for: .cleanup), "roomy failed with status 0: roomy completed without emitting a terminal execution event")
        XCTAssertNil(model.error(for: .monitor))
        if case .failed(let message) = model.executionState {
            XCTAssertTrue(message.contains("terminal execution event"))
        } else {
            XCTFail("Expected failed execution state after section change")
        }
    }

    @MainActor
    func testTemporaryExecutionPlanIsRemovedAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-plan-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let callsLog = root.appendingPathComponent("calls.log")
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(callsLog.path)"
        if [ "$1 $2 $3" = "api installer execute" ] && [ "$4" = "--plan" ]; then
          test -f "$5" || exit 66
          mode=$(stat -f %Lp "$5" 2>/dev/null || stat -c %a "$5" 2>/dev/null || printf unknown)
          printf 'mode:%s\\n' "$mode" >> "\(callsLog.path)"
          printf '%s\\n' '{"event":"started","domain":"installer"}'
          exit 65
        fi
        exit 64
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        let model = RoomyViewModel(apiClient: client)
        model.selectedSection = .storage

        await model.execute(
            domain: .installer,
            plan: ExecutionPlan(confirmed: true, targets: ["/tmp/Example.dmg"])
        )

        let executeCall = try XCTUnwrap(try String(contentsOf: callsLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .first)
        XCTAssertTrue(executeCall.hasPrefix("api installer execute --plan "))
        let planPath = String(executeCall.dropFirst("api installer execute --plan ".count))
        XCTAssertTrue(try String(contentsOf: callsLog, encoding: .utf8).contains("mode:600"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: planPath))

        XCTAssertEqual(model.executionEvents.map(\.event), ["started"])
        if case .failed = model.executionState {
            // Expected.
        } else {
            XCTFail("Expected failed execution state")
        }
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

    func testStreamEventsRejectsSuccessfulCommandWithoutEvents() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' 'done'
        exit 0
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)

        do {
            for try await _ in client.streamEvents(.status) {}
            XCTFail("Expected invalid event stream failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.contains("without emitting execution events"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testStreamEventsRejectsSuccessfulCommandWithoutTerminalEvent() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"test"}'
        exit 0
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        var events: [ExecutionEvent] = []

        do {
            for try await event in client.streamEvents(.status) {
                events.append(event)
            }
            XCTFail("Expected missing terminal event failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.contains("without emitting a terminal execution event"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }

        XCTAssertEqual(events.map(\.event), ["started"])
    }

    func testStreamEventsRejectsCompletedEventWithNonzeroExitCode() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"completed","domain":"test","exit_code":2}'
        exit 0
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5)
        var events: [ExecutionEvent] = []

        do {
            for try await event in client.streamEvents(.status) {
                events.append(event)
            }
            XCTFail("Expected nonzero completed event failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 2)
            XCTAssertTrue(message.contains("completed event reported status 2"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }

        XCTAssertEqual(events.map(\.event), ["completed"])
    }

    func testAdministratorStreamRejectsSuccessfulCommandWithoutEvents() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-empty-admin-stream-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let runner = RecordingPrivilegedRunner(result: PrivilegedCommandResult(
            exitCode: 0,
            standardOutput: Data("not json\n".utf8),
            standardError: Data()
        ))
        let script = try makeExecutableScript("#!/bin/sh\n")
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5, privilegedRunner: runner)

        do {
            for try await _ in client.streamEvents(.execute(domain: .clean, planURL: planURL), administrator: true) {}
            XCTFail("Expected invalid privileged event stream failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.contains("without emitting execution events"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }
    }

    func testAdministratorStreamRejectsSuccessfulCommandWithoutTerminalEvent() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-started-admin-stream-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let runner = RecordingPrivilegedRunner(result: PrivilegedCommandResult(
            exitCode: 0,
            standardOutput: Data(#"{"event":"started","domain":"clean"}"#.utf8),
            standardError: Data()
        ))
        let script = try makeExecutableScript("#!/bin/sh\n")
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5, privilegedRunner: runner)
        var events: [ExecutionEvent] = []

        do {
            for try await event in client.streamEvents(.execute(domain: .clean, planURL: planURL), administrator: true) {
                events.append(event)
            }
            XCTFail("Expected missing terminal privileged event stream failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.contains("without emitting a terminal execution event"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }

        XCTAssertEqual(events.map(\.event), ["started"])
    }

    func testAdministratorStreamRejectsCompletedEventWithNonzeroExitCode() async throws {
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-bad-completed-admin-stream-\(UUID().uuidString).json")
        try #"{"confirmed":true}"#.write(to: planURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: planURL) }

        let runner = RecordingPrivilegedRunner(result: PrivilegedCommandResult(
            exitCode: 0,
            standardOutput: Data(#"{"event":"completed","domain":"clean","exit_code":2}"#.utf8),
            standardError: Data()
        ))
        let script = try makeExecutableScript("#!/bin/sh\n")
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 5, privilegedRunner: runner)
        var events: [ExecutionEvent] = []

        do {
            for try await event in client.streamEvents(.execute(domain: .clean, planURL: planURL), administrator: true) {
                events.append(event)
            }
            XCTFail("Expected nonzero privileged completed event failure")
        } catch RoomyAPIError.processFailed(let status, let message) {
            XCTAssertEqual(status, 2)
            XCTAssertTrue(message.contains("completed event reported status 2"))
        } catch {
            XCTFail("Expected RoomyAPIError.processFailed, got \(error)")
        }

        XCTAssertEqual(events.map(\.event), ["completed"])
    }

    func testStreamEventsTimesOutHungCommandAfterPartialEvent() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"started","domain":"test"}'
        sleep 2
        printf '%s\\n' '{"event":"completed","domain":"test","exit_code":0}'
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 1.0)
        let start = Date()
        var events: [ExecutionEvent] = []

        do {
            for try await event in client.streamEvents(.status) {
                events.append(event)
            }
            XCTFail("Expected timeout")
        } catch RoomyAPIError.timedOut(let command, let seconds) {
            XCTAssertTrue(command.contains("api status"))
            XCTAssertEqual(seconds, 1.0, accuracy: 0.01)
        } catch {
            XCTFail("Expected RoomyAPIError.timedOut, got \(error)")
        }

        XCTAssertEqual(events.map(\.event), ["started"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testStreamTimeoutDoesNotBlockWhenProcessIgnoresTermination() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' '{"event":"started","domain":"test"}'
        sleep 2
        printf '%s\\n' '{"event":"completed","domain":"test","exit_code":0}'
        """)
        let client = RoomyAPIClient(executableURL: script, environment: [:], processTimeout: 0.2)
        let start = Date()

        do {
            for try await _ in client.streamEvents(.status) {}
            XCTFail("Expected timeout")
        } catch RoomyAPIError.timedOut(let command, let seconds) {
            XCTAssertTrue(command.contains("api status"))
            XCTAssertEqual(seconds, 0.2, accuracy: 0.01)
        } catch {
            XCTFail("Expected RoomyAPIError.timedOut, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
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
              "size": "180MB",
              "uninstall_supported": false,
              "uninstall_reason": "Managed externally"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(ApplicationListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.apps.count, 1)
        XCTAssertEqual(response.apps[0].uninstallName, "slack")
        XCTAssertEqual(response.apps[0].source, "Homebrew")
        XCTAssertEqual(response.apps[0].uninstallSupported, false)
        XCTAssertEqual(response.apps[0].uninstallReason, "Managed externally")
        XCTAssertFalse(response.apps[0].canUninstall)
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
        let inconsistentCompleted = ExecutionEvent(event: "completed", domain: "clean", message: nil, exitCode: 2)
        let failed = ExecutionEvent(event: "failed", domain: "clean", message: "Plan refused", exitCode: 1)

        XCTAssertEqual(RoomyViewModel.transition(from: .previewReady, event: started), .running)
        XCTAssertEqual(RoomyViewModel.transition(from: .running, event: completed), .completed)
        XCTAssertEqual(
            RoomyViewModel.transition(from: .running, event: inconsistentCompleted),
            .failed("Execution exited with status 2")
        )
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
          "version": "1.39.0",
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
        XCTAssertEqual(maintenance.version, "1.39.0")
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
            executablePath: "/usr/local/bin/roomy\n",
            arguments: ["api", "clean", "execute", "--plan", planURL.path],
            environment: [:],
            timeoutSeconds: 5
        )) { error in
            XCTAssertTrue(String(describing: error).contains("control characters"))
        }

        XCTAssertThrowsError(try PrivilegedCommandPolicy.command(
            executablePath: "/usr/local/bin/roomy",
            arguments: ["api", "clean", "execute", "--plan", "\(planURL.path)\n"],
            environment: [:],
            timeoutSeconds: 5
        )) { error in
            XCTAssertTrue(String(describing: error).contains("control characters"))
        }

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
