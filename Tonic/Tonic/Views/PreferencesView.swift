//
//  PreferencesView.swift
//  Tonic
//
//  Settings window with tabs for General, Permissions, Helper, Updates, and About
//

import SwiftUI
import UserNotifications

// Conditional import for Sparkle
#if canImport(Sparkle)
import Sparkle
#endif

struct PreferencesView: View {
    @AppStorage("automaticallyChecksForUpdates") private var automaticallyChecksForUpdates = true
    @AppStorage("allowBetaUpdates") private var allowBetaUpdates = false
    @AppStorage("sendAnonymousProfile") private var sendAnonymousProfile = true

    @State private var currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    @State private var buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    var body: some View {
        TabView {
            // General Settings Tab
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            // Permissions Settings Tab
            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "hand.raised.fill")
                }

            // Helper Settings Tab
            HelperSettingsView()
                .tabItem {
                    Label("Helper", systemImage: "checkmark.shield.fill")
                }

            // Updates Settings Tab
            UpdatesSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.down.circle")
                }

            // About Tab
            AboutView(version: currentVersion, build: buildNumber)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 550, height: 420)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @State private var preferences = AppearancePreferences.shared
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Appearance section
                appearanceSection

                // Startup section
                startupSection
            }
            .padding()
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.headline)

            // Theme selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    ForEach(ThemeMode.allCases) { mode in
                        ThemeButton(mode: mode, isSelected: preferences.themeMode == mode) {
                            preferences.setThemeMode(mode)
                            NotificationCenter.default.post(name: NSNotification.Name("TonicThemeDidChange"), object: nil)
                        }
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)

            // Accent color
            VStack(alignment: .leading, spacing: 8) {
                Text("Accent Color")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                    ForEach(AccentColor.allCases) { color in
                        AccentColorButton(color: color, isSelected: preferences.accentColor == color) {
                            preferences.setAccentColor(color)
                        }
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Startup")
                .font(.headline)

            Toggle("Launch Tonic at login", isOn: $launchAtLogin)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
        }
    }
}

// MARK: - Theme Button

struct ThemeButton: View {
    let mode: ThemeMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 50, height: 40)

                    Image(systemName: mode.icon)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? TonicColors.accent : .secondary)
                }

                Text(mode.rawValue)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {
    @State private var permissionManager = PermissionManager.shared
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Permissions")
                    .font(.headline)

                Spacer()

                Button {
                    Task { await refreshPermissions() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    Text("System Permissions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Full Disk Access
                    permissionCard(
                        for: .fullDiskAccess,
                        title: "Full Disk Access",
                        description: "Required to scan all files and folders on your Mac",
                        isCritical: true
                    )

                    // Accessibility
                    permissionCard(
                        for: .accessibility,
                        title: "Accessibility",
                        description: "Required for enhanced system monitoring",
                        isCritical: false
                    )

                    // Notifications
                    permissionCard(
                        for: .notifications,
                        title: "Notifications",
                        description: "Get notified about scan results and updates",
                        isCritical: false
                    )
                }
                .padding()
            }
        }
        .task {
            await permissionManager.checkAllPermissions()
        }
    }

    private func permissionCard(for permission: TonicPermission, title: String, description: String, isCritical: Bool) -> some View {
        let status = permissionManager.permissionStatuses[permission] ?? .notDetermined
        let statusLevel: StatusLevel = {
            switch status {
            case .authorized: return .healthy
            case .denied: return isCritical ? .critical : .warning
            case .notDetermined: return .unknown
            }
        }()

        return StatusCard(
            icon: permission.icon,
            title: title,
            description: description,
            status: statusLevel
        ) {
            // Open System Settings for this permission
            grantPermission(permission)
        }
    }

    private func grantPermission(_ permission: TonicPermission) {
        switch permission {
        case .fullDiskAccess:
            _ = permissionManager.requestFullDiskAccess()
        case .accessibility:
            _ = permissionManager.requestAccessibility()
        case .notifications:
            // Request notification permission
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func refreshPermissions() async {
        isRefreshing = true
        await permissionManager.checkAllPermissions()
        isRefreshing = false
    }
}

// MARK: - Helper Settings

struct HelperSettingsView: View {
    @State private var helperManager = PrivilegedHelperManager.shared
    @State private var isInstalling = false
    @State private var isUninstalling = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Privileged Helper")
                    .font(.headline)

                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Helper status card
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Helper Status")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        helperStatusCard
                    }

                    // What is helper section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What is the Privileged Helper?")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 8) {
                            featureRow("System Optimization", "Flush DNS, clear RAM, rebuild services")
                            featureRow("Deep Clean", "Remove system-level cache files")
                            featureRow("Hidden Space", "Access hidden system directories")
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)
                    }

                    // Actions
                    actionButtons
                }
                .padding()
            }
        }
        .task {
            _ = helperManager.checkInstallationStatus()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
    }

    private var helperStatusCard: some View {
        let statusLevel: StatusLevel = {
            if isInstalling || isUninstalling {
                return .unknown
            }
            return helperManager.isHelperInstalled ? .healthy : .critical
        }()

        return StatusCard(
            icon: "checkmark.shield.fill",
            title: "Privileged Helper Tool",
            description: helperManager.isHelperInstalled
                ? "Installed and ready for system operations"
                : "Not installed - required for advanced features",
            status: statusLevel
        ) {
            // Reinstall action
            if helperManager.isHelperInstalled {
                Task { await reinstallHelper() }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if !helperManager.isHelperInstalled {
                Button {
                    Task { await installHelper() }
                } label: {
                    HStack {
                        if isInstalling {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text(isInstalling ? "Installing..." : "Install Helper")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInstalling)
            } else {
                HStack(spacing: 12) {
                    Button {
                        Task { await reinstallHelper() }
                    } label: {
                        HStack {
                            if isInstalling {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isInstalling ? "Reinstalling..." : "Reinstall")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isInstalling)

                    Button {
                        Task { await uninstallHelper() }
                    } label: {
                        HStack {
                            if isUninstalling {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text(isUninstalling ? "Uninstalling..." : "Uninstall")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isUninstalling)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func featureRow(_ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func installHelper() async {
        isInstalling = true
        do {
            try await helperManager.installHelper()
        } catch {
            errorMessage = "Installation failed: \(error.localizedDescription)"
        }
        isInstalling = false
    }

    private func reinstallHelper() async {
        isInstalling = true
        do {
            try await helperManager.uninstallHelper()
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            try await helperManager.installHelper()
        } catch {
            errorMessage = "Reinstallation failed: \(error.localizedDescription)"
        }
        isInstalling = false
    }

    private func uninstallHelper() async {
        isUninstalling = true
        do {
            try await helperManager.uninstallHelper()
        } catch {
            errorMessage = "Uninstallation failed: \(error.localizedDescription)"
        }
        isUninstalling = false
    }
}

// MARK: - Updates Settings

struct UpdatesSettingsView: View {
    @AppStorage("automaticallyChecksForUpdates") private var automaticallyChecksForUpdates = true
    @AppStorage("allowBetaUpdates") private var allowBetaUpdates = false
    @AppStorage("sendAnonymousProfile") private var sendAnonymousProfile = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Software Update")
                .font(.headline)
                .padding(.bottom, 5)

            Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    #if canImport(Sparkle)
                    SparkleUpdater.shared.automaticallyChecksForUpdates = newValue
                    #endif
                }

            Toggle("Include beta versions", isOn: $allowBetaUpdates)
                .onChange(of: allowBetaUpdates) { _, _ in
                    #if canImport(Sparkle)
                    if automaticallyChecksForUpdates {
                        // TODO: Implement background update check
                    }
                    #endif
                }

            Divider()
                .padding(.vertical, 5)

            Button("Check for Updates...") {
                // TODO: Implement update check
            }
            .controlSize(.large)
            .keyboardShortcut("U", modifiers: [.command, .shift])
            .disabled(true)

            Spacer()
        }
        .padding()
        .onAppear {
            #if canImport(Sparkle)
            // Sync settings with Sparkle updater
            automaticallyChecksForUpdates = SparkleUpdater.shared.automaticallyChecksForUpdates
            #endif
        }
    }
}

// MARK: - About View

struct AboutView: View {
    let version: String
    let build: String

    var body: some View {
        VStack(spacing: 20) {
            // App icon
            Image(systemName: "drop.circle.fill")
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundStyle(.linearGradient(
                    colors: [TonicColors.accent, TonicColors.pro],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 5) {
                Text("Tonic for Mac")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Version \(version) (Build \(build))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("A modern Mac management utility.\n\nTransforming Mole CLI into a native macOS experience.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button("Check for Updates...") {
                    // TODO: Implement update check
                }
                .controlSize(.large)
                .disabled(true)

                Link("Website", destination: URL(string: "https://github.com/tw93/Mole")!)
                Link("Privacy Policy", destination: URL(string: "https://github.com/tw93/Mole")!)
                Link("License", destination: URL(string: "https://github.com/tw93/Mole/blob/main/LICENSE")!)
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Window Manager for Preferences

class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func showWindow() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let contentView = PreferencesView()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Settings"
            window?.contentView = NSHostingView(rootView: contentView)
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            window?.delegate = self
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Preview

#Preview {
    PreferencesView()
}
