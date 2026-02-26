import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!
    private var refreshInterval: TimeInterval = 1.0
    private var barMetrics: Set<BarMetric> = [.cpu, .ram]
    private var latestSnap: MetricsSnapshot?

    // Long-lived child process for streaming metrics.
    private var watchProcess: Process?
    private var watchPipe: Pipe?

    // Prefs file path.
    private var prefsPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.config/mole/menubar_prefs"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPrefs()
        parseCLIArgs()

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "CPU --% | RAM --%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.action = #selector(togglePopover)
            button.target = self
        }

        popoverVC = PopoverViewController()
        popoverVC.currentInterval = refreshInterval
        popoverVC.barMetrics = barMetrics
        popoverVC.onIntervalChange = { [weak self] newInterval in
            self?.refreshInterval = newInterval
            self?.savePrefs()
            self?.restartWatchProcess()
        }
        popoverVC.onBarMetricsChange = { [weak self] metrics in
            self?.barMetrics = metrics
            self?.savePrefs()
            if let snap = self?.latestSnap { self?.updateStatusBar(with: snap) }
        }

        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 310)

        startWatchProcess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatchProcess()
    }

    // MARK: - CLI args

    private func parseCLIArgs() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(where: { $0 == "--interval" || $0 == "-interval" }),
           idx + 1 < args.count, let val = TimeInterval(args[idx + 1]), val >= 0.5 {
            refreshInterval = val
        }
        if let idx = args.firstIndex(where: { $0 == "--display" || $0 == "-display" }),
           idx + 1 < args.count {
            let parts = args[idx + 1].lowercased().split(separator: ",")
            var parsed = Set<BarMetric>()
            for p in parts {
                if let m = BarMetric(rawValue: String(p)) { parsed.insert(m) }
            }
            if !parsed.isEmpty { barMetrics = parsed }
        }
    }

    // MARK: - Prefs persistence

    private func loadPrefs() {
        guard let data = try? String(contentsOfFile: prefsPath, encoding: .utf8) else { return }
        for line in data.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]), val = String(kv[1])
            switch key {
            case "interval":
                if let v = TimeInterval(val), v >= 0.5 { refreshInterval = v }
            case "display":
                var parsed = Set<BarMetric>()
                for p in val.split(separator: ",") {
                    if let m = BarMetric(rawValue: String(p)) { parsed.insert(m) }
                }
                if !parsed.isEmpty { barMetrics = parsed }
            default: break
            }
        }
    }

    private func savePrefs() {
        let dir = (prefsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let display = BarMetric.allCases.filter { barMetrics.contains($0) }.map(\.rawValue).joined(separator: ",")
        let content = "interval=\(refreshInterval)\ndisplay=\(display)\n"
        try? content.write(toFile: prefsPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Popover toggle

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Watch process management

    private func findBinary() -> (path: String, args: [String])? {
        let selfDir = (CommandLine.arguments.first.flatMap {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }) ?? ""

        var projectBin: String? = nil
        if !selfDir.isEmpty {
            var dir = URL(fileURLWithPath: selfDir)
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("bin/status-go").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    projectBin = candidate
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        let candidates = ([
            selfDir.isEmpty ? nil : "\(selfDir)/status-go",
            projectBin,
            "/usr/local/bin/mo",
            "/opt/homebrew/bin/mo",
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.config/mole/bin/status-go" }
        ] as [String?]).compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                if path.hasSuffix("status-go") {
                    return (path, ["--json", "--watch", "--interval", "\(refreshInterval)"])
                } else {
                    return (path, ["status", "--json", "--watch", "--interval", "\(refreshInterval)"])
                }
            }
        }
        return nil
    }

    // MARK: - Watch process

    private func startWatchProcess() {
        guard let (bin, args) = findBinary() else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        proc.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe

        do {
            try proc.run()
        } catch {
            return
        }

        watchProcess = proc
        watchPipe = pipe

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fh = pipe.fileHandleForReading
            var buffer = Data()
            let newline = Data("\n".utf8)

            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                while let range = buffer.range(of: newline) {
                    let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)

                    guard let snap = try? JSONDecoder().decode(MetricsSnapshot.self, from: line) else {
                        continue
                    }
                    DispatchQueue.main.async {
                        self?.latestSnap = snap
                        self?.updateStatusBar(with: snap)
                        self?.popoverVC.update(with: snap)
                    }
                }
            }
        }
    }

    private func stopWatchProcess() {
        if let proc = watchProcess, proc.isRunning {
            proc.terminate()
        }
        watchProcess = nil
        watchPipe = nil
    }

    private func restartWatchProcess() {
        stopWatchProcess()
        startWatchProcess()
    }

    // MARK: - Status bar

    private func updateStatusBar(with snap: MetricsSnapshot) {
        guard let button = statusItem.button else { return }
        var parts: [String] = []
        let ordered: [BarMetric] = [.cpu, .ram, .disk, .batt]
        for m in ordered where barMetrics.contains(m) {
            switch m {
            case .cpu:
                parts.append(String(format: "CPU %.0f%%", snap.CPU?.Usage ?? 0))
            case .ram:
                parts.append(String(format: "RAM %.0f%%", snap.Memory?.UsedPercent ?? 0))
            case .disk:
                if let d = snap.Disks?.first {
                    parts.append(String(format: "DISK %.0f%%", d.UsedPercent ?? 0))
                }
            case .batt:
                if let b = snap.Batteries?.first {
                    parts.append(String(format: "BATT %.0f%%", b.Percent ?? 0))
                }
            }
        }
        button.title = parts.joined(separator: " | ")
    }
}
