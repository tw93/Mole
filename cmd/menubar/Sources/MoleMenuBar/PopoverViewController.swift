import AppKit

// Available metrics for status bar display.
enum BarMetric: String, CaseIterable {
    case cpu, ram, disk, batt
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .ram: return "RAM"
        case .disk: return "DISK"
        case .batt: return "BATT"
        }
    }
}

class PopoverViewController: NSViewController {
    // MARK: - Labels

    private let healthLabel = NSTextField(labelWithString: "⏳ Health ● -- — Loading")
    private let hardwareLabel = NSTextField(labelWithString: "")
    private let cpuLabel = NSTextField(labelWithString: "🟢 CPU --%")
    private let memLabel = NSTextField(labelWithString: "🟢 MEM --%")
    private let diskLabel = NSTextField(labelWithString: "🟢 DISK --%")
    private let battLabel = NSTextField(labelWithString: "🟢 BATT --%")
    private let procsLabel = NSTextField(labelWithString: "❊ --")

    private let netLabel = NSTextField(labelWithString: "⇅ --")
    private let netInfoLabel = NSTextField(labelWithString: "")

    // Settings controls
    private var intervalButton: NSButton!
    private var intervalMenu: NSMenu!
    private var barMetricChecks: [BarMetric: NSButton] = [:]

    var onIntervalChange: ((TimeInterval) -> Void)?
    var onBarMetricsChange: ((Set<BarMetric>) -> Void)?

    var currentInterval: TimeInterval = 1.0
    var barMetrics: Set<BarMetric> = [.cpu, .ram]

    // MARK: - Lifecycle

    private let popoverWidth: CGFloat = 400

    override func loadView() {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.widthAnchor.constraint(equalToConstant: popoverWidth).isActive = true

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 5
        container.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        let labelWidth = popoverWidth - 24 // subtract left+right edge insets

        // Health + Hardware
        configureLabel(healthLabel, size: 12.5, bold: true)
        configureLabel(hardwareLabel, size: 10, color: .secondaryLabelColor)
        container.addArrangedSubview(healthLabel)
        container.addArrangedSubview(hardwareLabel)
        container.addArrangedSubview(makeSeparator())

        // Metric rows
        for label in [cpuLabel, memLabel, diskLabel, battLabel, procsLabel, netLabel] {
            configureLabel(label, size: 11.5, mono: true)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: labelWidth).isActive = true
            container.addArrangedSubview(label)
        }
        configureLabel(netInfoLabel, size: 10, color: .secondaryLabelColor)
        netInfoLabel.widthAnchor.constraint(lessThanOrEqualToConstant: labelWidth).isActive = true
        container.addArrangedSubview(netInfoLabel)
        container.addArrangedSubview(makeSeparator())

        // Settings: Interval | Bar display (single row)
        container.addArrangedSubview(makeSettingsRow())
        container.addArrangedSubview(makeSeparator())

        // Action buttons
        let openBtn = makeButton("Open Terminal Status", action: #selector(openTerminalStatus))
        let quitBtn = makeButton("Quit", action: #selector(quitApp))
        let btnRow = NSStackView(views: [openBtn, quitBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        container.addArrangedSubview(btnRow)

        self.view = wrapper
    }

    // MARK: - Public

    func update(with snap: MetricsSnapshot) {
        // Health
        let score = snap.HealthScore ?? 0
        let emoji = score >= 75 ? "🟢" : (score >= 60 ? "🟡" : "🔴")
        var scoreLabel = snap.HealthScoreMsg ?? ""
        if let colonIdx = scoreLabel.firstIndex(of: ":") {
            scoreLabel = String(scoreLabel[..<colonIdx])
        }
        healthLabel.stringValue = "\(emoji) Health ● \(score) — \(scoreLabel)"

        // Hardware
        var infoParts: [String] = []
        if let hw = snap.Hardware {
            if let m = hw.Model, !m.isEmpty { infoParts.append(m) }
            if let c = hw.CPUModel, !c.isEmpty { infoParts.append(c) }
            var specs: [String] = []
            if let r = hw.TotalRAM, !r.isEmpty { specs.append(r) }
            if let d = hw.DiskSize, !d.isEmpty { specs.append(d) }
            if !specs.isEmpty { infoParts.append(specs.joined(separator: "/")) }
            if let os = hw.OSVersion, !os.isEmpty { infoParts.append(os) }
        }
        if let up = snap.Uptime, !up.isEmpty { infoParts.append("up \(up)") }
        hardwareLabel.stringValue = infoParts.joined(separator: " · ")
        hardwareLabel.isHidden = infoParts.isEmpty

        // CPU
        let cpuPct = snap.CPU?.Usage ?? 0
        let cpuEmoji = cpuPct >= 85 ? "🔴" : (cpuPct >= 60 ? "🟡" : "🟢")
        var cpuText = String(format: "%@ CPU %.1f%%", cpuEmoji, cpuPct)
        if let temp = snap.Thermal?.CPUTemp, temp > 0 {
            cpuText += String(format: " @ %.1f°C", temp)
        }
        if let cpu = snap.CPU {
            cpuText += String(format: " · Load %.2f/%.2f/%.2f",
                              cpu.Load1 ?? 0, cpu.Load5 ?? 0, cpu.Load15 ?? 0)
        }
        cpuLabel.stringValue = cpuText

        // Memory
        let memPct = snap.Memory?.UsedPercent ?? 0
        let memEmoji = memPct >= 85 ? "🔴" : (memPct >= 60 ? "🟡" : "🟢")
        let used = humanBytes(snap.Memory?.Used ?? 0)
        let total = humanBytes(snap.Memory?.Total ?? 0)
        memLabel.stringValue = String(format: "%@ MEM %.1f%% · %@/%@", memEmoji, memPct, used, total)

        // Disk
        if let disks = snap.Disks, let d = disks.first {
            let dEmoji = (d.UsedPercent ?? 0) >= 85 ? "🔴" : ((d.UsedPercent ?? 0) >= 60 ? "🟡" : "🟢")
            let dUsed = humanBytesShort(d.Used ?? 0)
            let dTotal = humanBytesShort(d.Total ?? 0)
            diskLabel.stringValue = String(format: "%@ DISK %.1f%% · %@/%@",
                                           dEmoji, d.UsedPercent ?? 0, dUsed, dTotal)
        }

        // Battery
        if let batts = snap.Batteries, let b = batts.first {
            let bPct = b.Percent ?? 0
            let bEmoji = bPct < 20 ? "🔴" : (bPct < 50 ? "🟡" : "🟢")
            var bText = String(format: "%@ BATT %.0f%%", bEmoji, bPct)
            if let status = b.Status, !status.isEmpty { bText += " · \(status)" }
            if let tl = b.TimeLeft, !tl.isEmpty { bText += " · \(tl)" }
            battLabel.stringValue = bText
        } else {
            battLabel.stringValue = "BATT N/A"
        }

        // Processes
        if let procs = snap.TopProcesses, !procs.isEmpty {
            let top = procs.prefix(2).map { p in
                var name = p.Name ?? "?"
                // Strip common prefixes for readability.
                for prefix in ["com.apple.", "com.google.", "org.mozilla."] {
                    if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)); break }
                }
                if name.count > 12 { name = String(name.prefix(11)) + "…" }
                return String(format: "%@ %.1f%%", name, p.CPU ?? 0)
            }.joined(separator: ", ")
            procsLabel.stringValue = "❊ \(top)"
        }

        // Network
        var totalRx = 0.0, totalTx = 0.0
        var primaryIP = ""
        if let nets = snap.Network {
            for n in nets {
                totalRx += n.RxRateMBs ?? 0
                totalTx += n.TxRateMBs ?? 0
                if primaryIP.isEmpty, let ip = n.IP, !ip.isEmpty, n.Name == "en0" {
                    primaryIP = ip
                }
            }
        }
        netLabel.stringValue = "⇅ ↓\(formatRate(totalRx)) ↑\(formatRate(totalTx))"

        // Proxy + IP info line
        var netInfoParts: [String] = []
        if let proxy = snap.Proxy, proxy.Enabled == true {
            var proxyText = "Proxy \(proxy.Type ?? "")"
            if let host = proxy.Host, !host.isEmpty { proxyText += " \(host)" }
            netInfoParts.append(proxyText)
        }
        if !primaryIP.isEmpty { netInfoParts.append(primaryIP) }
        netInfoLabel.stringValue = netInfoParts.joined(separator: " · ")
        netInfoLabel.isHidden = netInfoParts.isEmpty
    }

    // MARK: - Helpers

    private func configureLabel(_ label: NSTextField, size: CGFloat, bold: Bool = false,
                                mono: Bool = false, color: NSColor = .labelColor) {
        label.font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }

    private func makeSettingsRow() -> NSStackView {
        // Interval part
        let intLabel = NSTextField(labelWithString: "Interval:")
        intLabel.font = NSFont.systemFont(ofSize: 11)

        intervalMenu = NSMenu()
        let intervals: [(String, TimeInterval)] = [("1s", 1), ("2s", 2), ("3s", 3), ("5s", 5), ("10s", 10)]
        for (title, secs) in intervals {
            let item = NSMenuItem(title: title, action: #selector(intervalMenuItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(secs * 10)
            item.state = (secs == currentInterval) ? .on : .off
            intervalMenu.addItem(item)
        }
        let currentTitle = intervals.first(where: { $0.1 == currentInterval })?.0 ?? "1s"
        intervalButton = NSButton(title: "\(currentTitle) ▾", target: self, action: #selector(showIntervalMenu(_:)))
        intervalButton.bezelStyle = .inline
        intervalButton.font = NSFont.systemFont(ofSize: 11)

        // Separator "|"
        let sep = NSTextField(labelWithString: "|")
        sep.font = NSFont.systemFont(ofSize: 11)
        sep.textColor = .tertiaryLabelColor

        // Bar part
        let barLabel = NSTextField(labelWithString: "Bar:")
        barLabel.font = NSFont.systemFont(ofSize: 11)

        var views: [NSView] = [intLabel, intervalButton, sep, barLabel]
        for metric in BarMetric.allCases {
            let btn = NSButton(checkboxWithTitle: metric.label, target: self, action: #selector(barMetricToggled(_:)))
            btn.font = NSFont.systemFont(ofSize: 11)
            btn.state = barMetrics.contains(metric) ? .on : .off
            btn.tag = BarMetric.allCases.firstIndex(of: metric)!
            barMetricChecks[metric] = btn
            views.append(btn)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 5
        return row
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 11)
        return btn
    }

    // MARK: - Actions

    @objc private func showIntervalMenu(_ sender: NSButton) {
        intervalMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func intervalMenuItemClicked(_ sender: NSMenuItem) {
        let secs = TimeInterval(sender.tag) / 10.0
        currentInterval = secs
        // Update checkmarks.
        for item in intervalMenu.items {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
        // Update button title.
        intervalButton.title = "\(sender.title) ▾"
        onIntervalChange?(secs)
    }

    @objc private func barMetricToggled(_ sender: NSButton) {
        let metric = BarMetric.allCases[sender.tag]
        if sender.state == .on {
            barMetrics.insert(metric)
        } else {
            // Don't allow deselecting all — keep at least one.
            if barMetrics.count > 1 {
                barMetrics.remove(metric)
            } else {
                sender.state = .on
                return
            }
        }
        onBarMetricsChange?(barMetrics)
    }

    @objc private func openTerminalStatus() {
        let script = """
        tell application "Terminal"
            activate
            do script "mo status"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
