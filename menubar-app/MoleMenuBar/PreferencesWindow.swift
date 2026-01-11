import SwiftUI
import AppKit
import ServiceManagement

class PreferencesWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let contentView = PreferencesView()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window?.center()
            window?.title = "Mole Menu Bar Preferences"
            window?.contentView = NSHostingView(rootView: contentView)
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PreferencesView: View {
    @AppStorage("updateInterval") private var updateInterval: Double = 2.0
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showCPU") private var showCPU: Bool = true
    @AppStorage("showMemory") private var showMemory: Bool = true
    @AppStorage("showDisk") private var showDisk: Bool = true
    @AppStorage("showNetwork") private var showNetwork: Bool = true
    @AppStorage("showBattery") private var showBattery: Bool = true
    @AppStorage("healthThreshold") private var healthThreshold: Double = 40.0
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = false

    var body: some View {
        TabView {
            // General Tab
            VStack(alignment: .leading, spacing: 20) {
                Text("General Settings")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Update Interval: \(String(format: "%.1f", updateInterval))s")
                    Slider(value: $updateInterval, in: 1...10, step: 0.5)
                        .frame(width: 300)
                }

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }

                Spacer()

                Text("Note: Update interval changes will take effect after restarting the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .tabItem {
                Label("General", systemImage: "gear")
            }

            // Metrics Tab
            VStack(alignment: .leading, spacing: 20) {
                Text("Metrics Display")
                    .font(.headline)

                Text("Choose which metrics to show in the dropdown menu:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show CPU", isOn: $showCPU)
                    Toggle("Show Memory", isOn: $showMemory)
                    Toggle("Show Disk", isOn: $showDisk)
                    Toggle("Show Network", isOn: $showNetwork)
                    Toggle("Show Battery", isOn: $showBattery)
                }

                Spacer()
            }
            .padding()
            .tabItem {
                Label("Metrics", systemImage: "chart.bar")
            }

            // Advanced Tab
            VStack(alignment: .leading, spacing: 20) {
                Text("Advanced Settings")
                    .font(.headline)

                Toggle("Enable Notifications", isOn: $notificationsEnabled)

                if notificationsEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Health Score Threshold: \(Int(healthThreshold))")
                        Slider(value: $healthThreshold, in: 0...100, step: 5)
                            .frame(width: 300)
                        Text("Get notified when health score drops below this value")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .tabItem {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
            }

            // About Tab
            VStack(spacing: 20) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)

                Text("Mole Menu Bar")
                    .font(.title)
                    .bold()

                Text("System Monitoring for macOS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Version 1.0.0")
                    .font(.caption)

                Spacer()

                VStack(spacing: 8) {
                    Link("Visit Mole on GitHub", destination: URL(string: "https://github.com/tw93/mole")!)
                    Text("Built with Swift and Go")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .frame(width: 500, height: 400)
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            }
        } else {
            // Fallback for older macOS versions
            // Would need to use SMLoginItemSetEnabled here
            print("Launch at login requires macOS 13.0 or later")
        }
    }
}
