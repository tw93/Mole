//
//  CPUWidgetView.swift
//  Tonic
//
//  CPU monitoring widget views
//  Task ID: fn-2.4
//

import SwiftUI
import Charts
import os

// MARK: - CPU Compact View

/// Compact menu bar view for CPU widget
public struct CPUCompactView: View {
    let cpuUsage: Double

    public init(cpuUsage: Double) {
        self.cpuUsage = cpuUsage
    }

    public var body: some View {
        let cpuValue = Int(cpuUsage)

        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(usageColor)

            Text("\(cpuValue)%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    private var usageColor: Color {
        switch cpuUsage {
        case 0..<50: return TonicColors.success
        case 50..<80: return TonicColors.warning
        default: return TonicColors.error
        }
    }
}

// MARK: - CPU Detail View

/// Detailed popover view for CPU widget
public struct CPUDetailView: View {

    @State private var dataManager = WidgetDataManager.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Total usage display
                    totalUsageSection

                    // Per-core usage
                    perCoreSection

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
        .frame(width: 320, height: 450)
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
            Image(systemName: "cpu.fill")
                .font(.title2)
                .foregroundColor(usageColor)

            Text("CPU Usage")
                .font(.headline)

            Spacer()

            Text("\(Int(dataManager.cpuData.totalUsage))%")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var totalUsageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Total Usage")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(Int(dataManager.cpuData.totalUsage))%")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(usageColor)

                Text("of \(dataManager.cpuData.perCoreUsage.count) cores")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Usage bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(usageColor)
                        .frame(width: max(0, geometry.size.width * (dataManager.cpuData.totalUsage / 100)), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private var perCoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-Core Usage")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(Array(dataManager.cpuData.perCoreUsage.enumerated()), id: \.offset) { index, usage in
                    HStack(spacing: 12) {
                        Text("Core \(index + 1)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(height: 6)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(colorForUsage(usage))
                                    .frame(width: max(0, geometry.size.width * (usage / 100)), height: 6)
                            }
                        }
                        .frame(height: 6)

                        Text("\(Int(usage))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                }
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

            Chart(dataManager.cpuHistory.enumerated().map { (index, value) in
                ChartDataPoint(index: index, value: value)
            }) { item in
                LineMark(
                    x: .value("Time", item.index),
                    y: .value("Usage", item.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(usageColor.gradient)
                .lineStyle(StrokeStyle(lineWidth: 2))

                AreaMark(
                    x: .value("Time", item.index),
                    y: .value("Usage", item.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [usageColor.opacity(0.3), usageColor.opacity(0.05)],
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
            Text("Top CPU Apps")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if dataManager.topCPUApps.isEmpty {
                Text("No app data available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(dataManager.topCPUApps.prefix(5))) { app in
                        HStack(spacing: 12) {
                            // App icon
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .frame(width: 20, height: 20)
                            }

                            Text(app.name)
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()

                            Text("\(Int(app.cpuUsage))%")
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

    private var usageColor: Color {
        colorForUsage(dataManager.cpuData.totalUsage)
    }

    private func colorForUsage(_ usage: Double) -> Color {
        switch usage {
        case 0..<50: return TonicColors.success
        case 50..<80: return TonicColors.warning
        default: return TonicColors.error
        }
    }
}

// MARK: - Chart Data Point

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let index: Int
    let value: Double
}

// MARK: - CPU Status Item

/// Manages the CPU widget's NSStatusItem
@MainActor
public final class CPUStatusItem: WidgetStatusItem {

    public override init(widgetType: WidgetType = .cpu, configuration: WidgetConfiguration) {
        super.init(widgetType: widgetType, configuration: configuration)
    }

    // Uses base WidgetStatusItem.createCompactView() which respects configuration

    public override func createDetailView() -> AnyView {
        AnyView(CPUDetailView())
    }
}

// MARK: - Preview

#Preview("CPU Detail") {
    CPUDetailView()
        .frame(width: 320, height: 400)
}
