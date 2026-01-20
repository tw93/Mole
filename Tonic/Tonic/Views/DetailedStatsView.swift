//
//  DetailedStatsView.swift
//  Tonic
//
//  Detailed dropdown views with graphs
//  Task ID: fn-1.26
//

import SwiftUI

/// Detailed statistics view with graphs and charts
struct DetailedStatsView: View {
    @State private var selectedTab: StatsTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            tabSelector

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .overview:
                    overviewTab
                case .cpu:
                    cpuGraph
                case .memory:
                    memoryGraph
                case .disk:
                    diskGraph
                case .network:
                    networkGraph
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(StatsTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16))

                        Text(tab.shortName)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedTab == tab ? TonicColors.accent.opacity(0.2) : Color.clear)
                    .foregroundColor(selectedTab == tab ? TonicColors.accent : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Quick stats grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 16) {
                    QuickStatCard(
                        title: "CPU Usage",
                        value: "45%",
                        icon: "cpu.fill",
                        color: .blue
                    )

                    QuickStatCard(
                        title: "Memory",
                        value: "8.2 GB",
                        subtitle: "of 16 GB",
                        icon: "memorychip.fill",
                        color: .purple
                    )

                    QuickStatCard(
                        title: "Disk",
                        value: "234 GB",
                        subtitle: "of 512 GB",
                        icon: "internaldrive.fill",
                        color: .orange
                    )

                    QuickStatCard(
                        title: "Network",
                        value: "↓ 1.2 MB/s",
                        subtitle: "↑ 234 KB/s",
                        icon: "network",
                        color: .green
                    )
                }
                .padding()

                // Mini graphs
                VStack(spacing: 16) {
                    MiniGraphSection(
                        title: "CPU History",
                        data: cpuHistoryData,
                        color: .blue
                    )

                    MiniGraphSection(
                        title: "Memory History",
                        data: memoryHistoryData,
                        color: .purple
                    )
                }
                .padding()
            }
        }
    }

    // MARK: - CPU Graph

    private var cpuGraph: some View {
        VStack(spacing: 20) {
            Text("CPU Usage")
                .font(.headline)
                .padding()

            LineGraphView(
                data: cpuHistoryData,
                color: .blue,
                maxValue: 100
            )
            .frame(height: 200)
            .padding()

            VStack(alignment: .leading, spacing: 12) {
                StatRow(label: "Current Usage", value: "45%", color: .blue)
                StatRow(label: "Average (1h)", value: "38%", color: Color.blue.opacity(0.7))
                StatRow(label: "Peak (1h)", value: "82%", color: Color.blue.opacity(0.5))
                StatRow(label: "Processes", value: "342", color: Color.blue.opacity(0.3))
            }
            .padding()
        }
    }

    // MARK: - Memory Graph

    private var memoryGraph: some View {
        VStack(spacing: 20) {
            Text("Memory Usage")
                .font(.headline)
                .padding()

            LineGraphView(
                data: memoryHistoryData,
                color: .purple,
                maxValue: 100
            )
            .frame(height: 200)
            .padding()

            // Memory breakdown
            VStack(alignment: .leading, spacing: 12) {
                Text("Memory Breakdown")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                MemoryBreakdownRow(label: "Wired", value: 2.4, total: 16, color: .red)
                MemoryBreakdownRow(label: "Active", value: 4.8, total: 16, color: .blue)
                MemoryBreakdownRow(label: "Compressed", value: 1.2, total: 16, color: .orange)
                MemoryBreakdownRow(label: "Free", value: 7.6, total: 16, color: .green)
            }
            .padding()
        }
    }

    // MARK: - Disk Graph

    private var diskGraph: some View {
        VStack(spacing: 20) {
            Text("Disk Usage")
                .font(.headline)
                .padding()

            // Disk breakdown chart
            DonutChartView(
                segments: diskSegments
            )
            .frame(height: 250)
            .padding()

            VStack(alignment: .leading, spacing: 8) {
                Text("Breakdown by Category")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                ForEach(diskSegments, id: \.label) { item in
                    HStack {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)

                        Text(item.label)
                            .font(.caption)

                        Spacer()

                        Text(item.value)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding()
        }
    }

    private var diskSegments: [DiskSegment] {
        [
            DiskSegment(label: "System", value: "98 GB", color: .blue, chartValue: 98),
            DiskSegment(label: "Applications", value: "64 GB", color: .purple, chartValue: 64),
            DiskSegment(label: "Documents", value: "45 GB", color: .orange, chartValue: 45),
            DiskSegment(label: "Media", value: "27 GB", color: .green, chartValue: 27),
            DiskSegment(label: "Free Space", value: "\(remainingDisk) GB", color: Color.gray.opacity(0.3), chartValue: remainingDisk)
        ]
    }

    private var remainingDisk: Int {
        512 - 98 - 64 - 45 - 27
    }

    // MARK: - Network Graph

    private var networkGraph: some View {
        VStack(spacing: 20) {
            Text("Network Activity")
                .font(.headline)
                .padding()

            HStack(spacing: 30) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)

                    Text("Download")
                        .font(.caption)

                    Text("1.2 MB/s")
                        .font(.headline)
                }

                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.blue)

                    Text("Upload")
                        .font(.caption)

                    Text("234 KB/s")
                        .font(.headline)
                }
            }

            Divider()
                .padding()

            VStack(alignment: .leading, spacing: 12) {
                StatRow(label: "Total Downloaded", value: "2.4 GB", color: .green)
                StatRow(label: "Total Uploaded", value: "456 MB", color: .blue)
            }
            .padding()
        }
    }

    // MARK: - Sample Data

    private var cpuHistoryData: [Double] {
        [23, 28, 35, 42, 38, 45, 52, 48, 45, 41, 38, 44, 51, 58, 62, 55, 48, 45, 42, 45]
    }

    private var memoryHistoryData: [Double] {
        [45, 48, 52, 55, 53, 56, 58, 54, 52, 50, 51, 53, 55, 57, 56, 54, 52, 51, 50, 51]
    }
}

// MARK: - Stats Tab

enum StatsTab: String, CaseIterable, Identifiable {
    case overview
    case cpu
    case memory
    case disk
    case network

    var id: String { rawValue }

    var name: String {
        switch self {
        case .overview: return "Overview"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        }
    }

    var shortName: String {
        switch self {
        case .overview: return "All"
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .disk: return "Disk"
        case .network: return "Net"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .cpu: return "cpu.fill"
        case .memory: return "memorychip.fill"
        case .disk: return "internaldrive.fill"
        case .network: return "network"
        }
    }
}

// MARK: - Data Models

struct DiskSegment: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let color: Color
    let chartValue: Int
}

// MARK: - Supporting Views

struct QuickStatCard: View {
    let title: String
    let value: String
    var subtitle: String?
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
            }

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.title2)
                .fontWeight(.semibold)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct MiniGraphSection: View {
    let title: String
    let data: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            MiniLineGraphView(data: data, color: color)
                .frame(height: 60)
        }
    }
}

struct MiniLineGraphView: View {
    let data: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let max = data.max() ?? 1

            Path { path in
                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) / CGFloat(data.count - 1) * width
                    let y = height - (CGFloat(value) / max * height)

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Fill gradient
            Path { path in
                path.move(to: CGPoint(x: 0, y: height))

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) / CGFloat(data.count - 1) * width
                    let y = height - (CGFloat(value) / max * height)

                    path.addLine(to: CGPoint(x: x, y: y))
                }

                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
            .fill(LinearGradient(
                colors: [color.opacity(0.3), color.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            ))
        }
    }
}

struct LineGraphView: View {
    let data: [Double]
    let color: Color
    var maxValue: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let max = maxValue ?? data.max() ?? 1

            ZStack {
                // Grid lines
                ForEach(0..<5) { index in
                    let y = CGFloat(index) / 4 * height
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: 1))
                }

                // Data line
                Path { path in
                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) / CGFloat(data.count - 1) * width
                        let y = height - (CGFloat(value) / max * height * 0.9) - height * 0.05

                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                // Fill
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))

                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) / CGFloat(data.count - 1) * width
                        let y = height - (CGFloat(value) / max * height * 0.9) - height * 0.05

                        path.addLine(to: CGPoint(x: x, y: y))
                    }

                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [color.opacity(0.2), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                ))

                // Points
                ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                    let x = CGFloat(index) / CGFloat(data.count - 1) * width
                    let y = height - (CGFloat(value) / max * height * 0.9) - height * 0.05

                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }
            }
        }
    }
}

struct DonutChartView: View {
    let segments: [DiskSegment]

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) / 2 - 20
            let total = segments.reduce(0) { $0 + $1.chartValue }

            ZStack {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let startAngle = angleForOffset(segments[..<index].reduce(0) { $0 + $1.chartValue }, total: total)
                    let endAngle = angleForOffset(segments[...(index)].reduce(0) { $0 + $1.chartValue }, total: total)

                    Path { path in
                        path.addArc(
                            center: center,
                            radius: radius,
                            startAngle: .degrees(startAngle),
                            endAngle: .degrees(endAngle),
                            clockwise: false
                        )
                    }
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 30))
                }

                // Center label
                VStack(spacing: 4) {
                    Text("\(Int((1 - Double(segments.last?.chartValue ?? 0) / Double(total)) * 100))%")
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    Text("Used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .position(center)
            }
        }
    }

    private func angleForOffset(_ value: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total) * 360 - 90
    }
}

struct StatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.subheadline)

            Spacer()

            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }
}

struct MemoryBreakdownRow: View {
    let label: String
    let value: Double
    let total: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(label)
                    .font(.caption)

                Spacer()

                Text(String(format: "%.1f GB", value))
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(color.opacity(0.2))

                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(value / total))
                }
            }
            .frame(height: 4)
        }
    }
}

#Preview {
    DetailedStatsView()
        .frame(width: 400, height: 500)
}
