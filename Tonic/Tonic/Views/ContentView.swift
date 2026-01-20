//
//  ContentView.swift
//  Tonic
//
//  Main view with sidebar navigation
//  Integrated with onboarding and permission checks
//

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var selectedDestination: NavigationDestination = .dashboard
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showOnboarding = false
    @State private var showPermissionPrompt = false
    @State private var missingPermissionFor: PermissionManager.Feature?

    @State private var permissionManager = PermissionManager.shared
    @State private var hasSeenOnboardingValue = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")

    var hasSeenOnboarding: Bool {
        get { hasSeenOnboardingValue }
        set { hasSeenOnboardingValue = newValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedDestination: $selectedDestination)
        } detail: {
            DetailView(
                item: selectedDestination,
                onPermissionNeeded: { feature in
                    missingPermissionFor = feature
                    showPermissionPrompt = true
                }
            )
        }
        .navigationTitle("Tonic")
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .sheet(isPresented: $showPermissionPrompt) {
            PermissionPromptView(
                feature: missingPermissionFor,
                isPresented: $showPermissionPrompt
            )
        }
        .onAppear {
            checkFirstLaunch()
        }
    }

    private func checkFirstLaunch() {
        if !hasSeenOnboarding {
            showOnboarding = true
        }

        // Check permissions on app launch
        Task {
            await permissionManager.checkAllPermissions()
        }
    }
}

struct DetailView: View {
    let item: NavigationDestination
    let onPermissionNeeded: (PermissionManager.Feature) -> Void

    @State private var permissionManager = PermissionManager.shared
    @State private var checkedPermissions = false

    var body: some View {
        Group {
            if !checkedPermissions {
                ProgressView("Checking permissions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .task {
                        await permissionManager.checkAllPermissions()
                        checkedPermissions = true
                    }
            } else {
                contentForItem
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var contentForItem: some View {
        switch item {
        case .dashboard:
            DashboardView()
        case .systemCleanup:
            SmartScanView()
        case .appManager:
            if permissionManager.hasFullDiskAccess {
                AppInventoryView()
            } else {
                PermissionRequiredView(
                    icon: "externaldrive.fill",
                    title: "Full Disk Access Required",
                    description: "App Manager needs Full Disk Access to scan all installed applications and their support files.",
                    onGrantPermission: {
                        onPermissionNeeded(.appManager)
                    }
                )
            }
        case .diskAnalysis:
            if permissionManager.hasFullDiskAccess {
                DiskAnalysisView()
            } else {
                PermissionRequiredView(
                    icon: "externaldrive.fill",
                    title: "Full Disk Access Required",
                    description: "Disk Analysis needs Full Disk Access to scan all directories on your Mac.",
                    onGrantPermission: {
                        onPermissionNeeded(.diskScan)
                    }
                )
            }
        case .liveMonitoring:
            SystemStatusDashboard()
        case .developerTools:
            DeveloperToolsView()
        case .settings:
            PreferencesView()
        }
    }
}

// MARK: - Permission Prompt View

struct PermissionPromptView: View {
    let feature: PermissionManager.Feature?
    @Binding var isPresented: Bool

    @State private var permissionManager = PermissionManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(TonicColors.warning)

            Text("Permission Required")
                .font(.title)
                .fontWeight(.semibold)

            Text(messageText)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(TonicPermission.fullDiskAccess)
                permissionRow(TonicPermission.accessibility)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Open System Settings") {
                    grantPermission()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 400)
    }

    private var messageText: String {
        switch feature {
        case .diskScan, .appManager:
            return "Tonic needs Full Disk Access to scan all files and applications on your Mac."
        case .smartScan:
            return "Smart Scan requires Full Disk Access to perform a comprehensive system scan."
        case .systemOptimization:
            return "System optimization requires the privileged helper tool to be installed."
        case .basicScan, nil:
            return "Tonic needs additional permissions to function properly."
        }
    }

    private func permissionRow(_ permission: TonicPermission) -> some View {
        let status = permissionManager.permissionStatuses[permission] ?? .notDetermined

        return HStack {
            Image(systemName: permission.icon)
                .foregroundColor(status == .authorized ? .green : TonicColors.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.rawValue)
                    .font(.subheadline)
                Text(permission.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                if status == .authorized {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Granted")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                    Text("Required")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private func grantPermission() {
        // Open Full Disk Access in System Settings
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)

        // Recheck permissions after delay
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await permissionManager.checkAllPermissions()

            // If granted, dismiss
            if permissionManager.hasFullDiskAccess {
                isPresented = false
            }
        }
    }
}

// MARK: - Permission Required View

struct PermissionRequiredView: View {
    let icon: String
    let title: String
    let description: String
    let onGrantPermission: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(TonicColors.warning)

            Text(title)
                .font(.title)
                .fontWeight(.semibold)

            Text(description)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Grant Permission") {
                onGrantPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("You can also grant this permission later in System Settings > Privacy & Security > Full Disk Access")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Views that use SystemCleanupView

struct AppManagerView: View {
    var body: some View {
        AppInventoryView()
    }
}

struct MonitoringView: View {
    var body: some View {
        SystemStatusDashboard()
    }
}

struct DeveloperToolsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Developer Tools")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Clean up development artifacts and project files.")
                .foregroundColor(.secondary)

            // Add project artifact cleanup options
            VStack(alignment: .leading, spacing: 12) {
                Text("Supported Tools")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                toolRow("Node.js", icon: "shippingbox.fill")
                toolRow("Python", icon: "python")
                toolRow("Docker", icon: "shippingbox.fill")
                toolRow("Xcode", icon: "xcodes")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
        }
        .padding()
    }

    private func toolRow(_ name: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            Text(name)
                .font(.body)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
