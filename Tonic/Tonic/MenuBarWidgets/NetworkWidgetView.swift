//
//  NetworkWidgetView.swift
//  Tonic
//
//  Network monitoring widget views
//  Task ID: fn-2.8
//

import SwiftUI
import Charts
import Network

// MARK: - Network Compact View

/// Compact menu bar view for Network widget
public struct NetworkCompactView: View {

    @State private var dataManager = WidgetDataManager.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: connectionIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(dataManager.networkData.isConnected ? .blue : .secondary)

            if dataManager.networkData.isConnected {
                // Show download speed in compact view
                Text(compactBandwidthText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            } else {
                // Disconnected indicator
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    private var connectionIcon: String {
        switch dataManager.networkData.connectionType {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .unknown: return "network"
        }
    }

    private var compactBandwidthText: String {
        let download = dataManager.networkData.downloadBytesPerSecond
        if download >= 1_000_000 {
            return String(format: "%.1fM", download / 1_000_000)
        } else if download >= 1_000 {
            return String(format: "%.0fK", download / 1_000)
        } else {
            return "0K"
        }
    }
}

// MARK: - Network Detail View

/// Detailed popover view for Network widget
public struct NetworkDetailView: View {

    @State private var dataManager = WidgetDataManager.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Connection status
                    connectionStatusSection

                    if dataManager.networkData.isConnected {
                        // Bandwidth display
                        bandwidthSection

                        // History graph
                        historyGraphSection

                        // Connection details
                        connectionDetailsSection
                    }
                }
                .padding()
            }
        }
        .frame(width: 320, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Image(systemName: dataManager.networkData.isConnected ? connectionIcon : "wifi.slash")
                .font(.title2)
                .foregroundColor(dataManager.networkData.isConnected ? .blue : .secondary)

            Text("Network")
                .font(.headline)

            Spacer()

            if dataManager.networkData.isConnected {
                Image(systemName: "circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var connectionIcon: String {
        switch dataManager.networkData.connectionType {
        case .wifi: return "wifi.fill"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right.fill"
        case .unknown: return "network"
        }
    }

    private var connectionStatusSection: some View {
        HStack(spacing: 16) {
            Image(systemName: dataManager.networkData.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title)
                .foregroundColor(dataManager.networkData.isConnected ? .green : .red)

            VStack(alignment: .leading, spacing: 4) {
                Text(dataManager.networkData.isConnected ? "Connected" : "Disconnected")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if let ssid = dataManager.networkData.ssid, dataManager.networkData.isConnected {
                    Text(ssid)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if dataManager.networkData.isConnected {
                    Text(connectionTypeName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var connectionTypeName: String {
        switch dataManager.networkData.connectionType {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .unknown: return "Network"
        }
    }

    private var bandwidthSection: some View {
        VStack(spacing: 16) {
            // Download
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)

                        Text("Download")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(dataManager.networkData.downloadString)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)

                    Text("current speed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Upload
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Upload")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.blue)
                    }

                    Text(dataManager.networkData.uploadString)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)

                    Text("current speed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var historyGraphSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bandwidth History")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                // Download history
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)

                        Text("Download")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Chart(dataManager.networkDownloadHistory.enumerated().map { (index, value) in
                        ChartDataPoint(index: index, value: value)
                    }) { item in
                        LineMark(
                            x: .value("Time", item.index),
                            y: .value("Speed", item.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .frame(height: 60)
                }

                // Upload history
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundColor(.blue)

                        Text("Upload")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Chart(dataManager.networkUploadHistory.enumerated().map { (index, value) in
                        ChartDataPoint(index: index, value: value)
                    }) { item in
                        LineMark(
                            x: .value("Time", item.index),
                            y: .value("Speed", item.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .frame(height: 60)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var connectionDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Details")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                detailRow(label: "Connection Type", value: connectionTypeName)
                detailRow(label: "Interface", value: connectionIcon)

                if let ssid = dataManager.networkData.ssid {
                    detailRow(label: "Network Name", value: ssid)
                }

                if let ip = dataManager.networkData.ipAddress {
                    detailRow(label: "IP Address", value: ip)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Network Status Item

/// Manages the Network widget's NSStatusItem
@MainActor
public final class NetworkStatusItem: WidgetStatusItem {

    public override init(widgetType: WidgetType = .network, configuration: WidgetConfiguration) {
        super.init(widgetType: widgetType, configuration: configuration)
    }

    // Uses base WidgetStatusItem.createCompactView() which respects configuration

    public override func createDetailView() -> AnyView {
        AnyView(NetworkDetailView())
    }
}

// MARK: - Preview

#Preview("Network Detail") {
    NetworkDetailView()
        .frame(width: 320, height: 400)
}
