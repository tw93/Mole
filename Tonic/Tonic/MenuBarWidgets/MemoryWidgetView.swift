//
//  MemoryWidgetView.swift
//  Tonic
//
//  Memory monitoring widget views
//  Task ID: fn-2.6
//

import SwiftUI
import Charts

// MARK: - Memory Compact View

/// Compact menu bar view for Memory widget
public struct MemoryCompactView: View {
    let usagePercentage: Double
    let pressure: MemoryPressure

    public init(usagePercentage: Double, pressure: MemoryPressure) {
        self.usagePercentage = usagePercentage
        self.pressure = pressure
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(pressureColor)

            Text("\(Int(usagePercentage))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)

            // Pressure indicator dot
            Circle()
                .fill(pressureColor)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    private var pressureColor: Color {
        switch pressure {
        case .normal: return TonicColors.success
        case .warning: return TonicColors.warning
        case .critical: return TonicColors.error
        }
    }
}

// MARK: - Memory Detail View

/// Detailed popover view for Memory widget
public struct MemoryDetailView: View {

    @State private var dataManager = WidgetDataManager.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Usage gauge
                    usageGaugeSection

                    // Memory breakdown
                    memoryBreakdownSection

                    // Pressure level
                    pressureSection

                    // History graph
                    historyGraphSection

                    // Top apps
                    topAppsSection

                    // Activity Monitor link
                    activityMonitorButton
                }
                .padding()
            }
        }
        .frame(width: 320, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var activityMonitorButton: some View {
        Button {
            NSWorkspace.shared.launchApplication("Activity Monitor")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 14))
                Text("Open Activity Monitor")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Image(systemName: "memorychip.fill")
                .font(.title2)
                .foregroundColor(pressureColor)

            Text("Memory")
                .font(.headline)

            Spacer()

            Text("\(Int(dataManager.memoryData.usagePercentage))%")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(pressureColor)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var usageGaugeSection: some View {
        VStack(spacing: 16) {
            // Circular gauge
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: dataManager.memoryData.usagePercentage / 100)
                    .stroke(
                        pressureColor.gradient,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: dataManager.memoryData.usagePercentage)

                VStack(spacing: 4) {
                    Text("\(Int(dataManager.memoryData.usagePercentage))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(pressureColor)

                    Text("used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Used/Total text
            HStack(spacing: 4) {
                Text(formatBytes(dataManager.memoryData.usedBytes))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("of")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(formatBytes(dataManager.memoryData.totalBytes))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var memoryBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory Breakdown")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                memoryRow(label: "Used", value: dataManager.memoryData.usedBytes, color: pressureColor)
                memoryRow(label: "Compressed", value: dataManager.memoryData.compressedBytes, color: .purple)
                memoryRow(label: "Swap", value: dataManager.memoryData.swapBytes, color: .orange)

                let freeBytes = dataManager.memoryData.totalBytes - dataManager.memoryData.usedBytes
                memoryRow(label: "Free", value: freeBytes, color: .gray)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func memoryRow(label: String, value: UInt64, color: Color) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 6)

                    let percentage = dataManager.memoryData.totalBytes > 0 ? Double(value) / Double(dataManager.memoryData.totalBytes) : 0
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, geometry.size.width * percentage), height: 6)
                }
            }
            .frame(height: 6)

            Text(formatBytes(value))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    private var pressureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory Pressure")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Image(systemName: pressureIcon)
                    .font(.title2)
                    .foregroundColor(pressureColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(pressureText)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(pressureDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var historyGraphSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage History")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Chart(dataManager.memoryHistory.enumerated().map { (index, value) in
                ChartDataPoint(index: index, value: value)
            }) { item in
                LineMark(
                    x: .value("Time", item.index),
                    y: .value("Usage", item.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(pressureColor.gradient)
                .lineStyle(StrokeStyle(lineWidth: 2))

                AreaMark(
                    x: .value("Time", item.index),
                    y: .value("Usage", item.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [pressureColor.opacity(0.3), pressureColor.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let intValue = value.as(Int.self) {
                            Text("\(intValue)%")
                                .font(.caption2)
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 100)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Memory Apps")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if dataManager.topMemoryApps.isEmpty {
                Text("No app data available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(dataManager.topMemoryApps.prefix(5))) { app in
                        HStack(spacing: 12) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 20, height: 20)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.caption)
                                    .lineLimit(1)

                                Text(app.memoryString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("\(Double(app.memoryBytes) / Double(dataManager.memoryData.totalBytes) * 100, specifier: "%.1f")%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospaced()
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var pressureColor: Color {
        switch dataManager.memoryData.pressure {
        case .normal: return TonicColors.success
        case .warning: return TonicColors.warning
        case .critical: return TonicColors.error
        }
    }

    private var pressureIcon: String {
        switch dataManager.memoryData.pressure {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        }
    }

    private var pressureText: String {
        switch dataManager.memoryData.pressure {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private var pressureDescription: String {
        switch dataManager.memoryData.pressure {
        case .normal: return "Memory pressure is normal"
        case .warning: return "System is under memory pressure"
        case .critical: return "Critical memory pressure - close apps"
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

// MARK: - Memory Status Item

/// Manages the Memory widget's NSStatusItem
@MainActor
public final class MemoryStatusItem: WidgetStatusItem {

    public override init(widgetType: WidgetType = .memory, configuration: WidgetConfiguration) {
        super.init(widgetType: widgetType, configuration: configuration)
    }

    // Uses base WidgetStatusItem.createCompactView() which respects configuration

    public override func createDetailView() -> AnyView {
        AnyView(MemoryDetailView())
    }
}

// MARK: - Preview

#Preview("Memory Detail") {
    MemoryDetailView()
        .frame(width: 320, height: 450)
}
