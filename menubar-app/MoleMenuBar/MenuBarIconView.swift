import Cocoa

class MenuBarIconView: NSView {
    private var cpuUsage: Double = 0.0
    private var cpuHistory: [Double] = []
    private let maxHistoryCount = 8
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Initialize with empty history
        cpuHistory = Array(repeating: 0.0, count: maxHistoryCount)
    }

    func updateWithCPU(usage: Double, perCore: [Double]) {
        cpuUsage = usage

        // Add to history (most recent on the right)
        cpuHistory.append(usage)
        if cpuHistory.count > maxHistoryCount {
            cpuHistory.removeFirst()
        }

        // Trigger redraw
        DispatchQueue.main.async {
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Clear background
        NSColor.clear.setFill()
        context.fill(bounds)

        // Calculate layout
        let totalWidth = CGFloat(maxHistoryCount) * (barWidth + barSpacing) - barSpacing
        let startX = (bounds.width - totalWidth) / 2
        let maxBarHeight = bounds.height - 4

        // Draw each bar in the history
        for (index, usage) in cpuHistory.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + barSpacing)
            let normalizedUsage = min(max(usage / 100.0, 0.0), 1.0)
            let barHeight = maxBarHeight * CGFloat(normalizedUsage)
            let y = (bounds.height - barHeight) / 2

            // Choose color based on usage
            let color = colorForUsage(usage)
            context.setFillColor(color)

            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            context.fill(barRect)
        }
    }

    private func colorForUsage(_ usage: Double) -> CGColor {
        switch usage {
        case 0..<30:
            // Green
            return CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1.0)
        case 30..<70:
            // Yellow
            return CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
        default:
            // Red
            return CGColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        }
    }
}
