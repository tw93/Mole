//
//  OnboardingView.swift
//  Tonic
//
//  User onboarding with helper installation and permissions
//  Task ID: fn-1.11
//

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    @Environment(\.dismiss) private var dismiss

    @State private var permissionManager = PermissionManager.shared
    @State private var helperManager = PrivilegedHelperManager.shared
    @State private var isCheckingPermissions = false
    @State private var isInstallingHelper = false

    private let totalPages = 4

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress indicator
                HStack {
                    ForEach(0..<totalPages, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index <= currentPage ? TonicColors.accent : Color.gray.opacity(0.3))
                            .frame(width: index == currentPage ? 32 : 8, height: 4)
                            .animation(.easeInOut(duration: 0.3), value: currentPage)
                    }
                }
                .padding()

                Spacer()

                // Content
                switch currentPage {
                case 0:
                    welcomePage
                case 1:
                    permissionsPage
                case 2:
                    helperPage
                default:
                    readyPage
                }

                Spacer()

                // Navigation buttons
                navigationButtons
            }
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Image(systemName: "drop.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.linearGradient(
                    colors: [TonicColors.accent, TonicColors.pro],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 12) {
                Text("Welcome to Tonic")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("The ultimate Mac optimization tool")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Smart Scanning",
                    description: "Quickly identify what's consuming your disk space"
                )

                FeatureRow(
                    icon: "sparkles",
                    title: "Safe Cleanup",
                    description: "Remove junk files while protecting your important data"
                )

                FeatureRow(
                    icon: "app.badge",
                    title: "App Management",
                    description: "Uninstall apps completely with all their files"
                )
            }
            .padding()
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 50))
                .foregroundColor(TonicColors.accent)

            VStack(spacing: 12) {
                Text("Permissions")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Tonic needs Full Disk Access to work properly")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Full Disk Access section with detailed instructions
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill")
                                .font(.title2)
                                .foregroundColor(permissionManager.hasFullDiskAccess ? .green : .orange)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Full Disk Access")
                                    .font(.headline)
                                Text("Required to scan all files and folders on your Mac")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if permissionManager.hasFullDiskAccess {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)

                        if !permissionManager.hasFullDiskAccess {
                            // Step-by-step instructions
                            VStack(alignment: .leading, spacing: 12) {
                                Text("How to grant Full Disk Access:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                stepRow(number: 1, text: "Click the button below to open System Settings")
                                stepRow(number: 2, text: "Click the lock icon and enter your password")
                                stepRow(number: 3, text: "Find \"Tonic\" in the list and enable it")
                                stepRow(number: 4, text: "Quit System Settings and click \"I've Granted Access\" below")
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(10)

                            Button {
                                permissionManager.requestFullDiskAccess()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "gear")
                                    Text("Open System Settings")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(TonicColors.accent)
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task {
                                    await permissionManager.checkAllPermissions()
                                }
                            } label: {
                                Text("I've Granted Access")
                                    .font(.subheadline)
                                    .underline()
                            }
                            .buttonStyle(.plain)

                            Text("Without Full Disk Access, Tonic cannot scan your entire disk and will show permission prompts for each folder.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.top, 4)
                        }
                    }

                    // Optional permissions section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Optional Permissions")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        optionalPermissionRow(
                            icon: "bell.fill",
                            title: "Notifications",
                            description: "Get notified about scan results and updates"
                        )
                    }
                }
                .padding()
            }

            Text("Full Disk Access is required for the best experience")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .task {
            await permissionManager.checkAllPermissions()
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(TonicColors.accent))

            Text(text)
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()
        }
    }

    private func optionalPermissionRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Optional")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var helperPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 50))
                .foregroundColor(helperManager.isHelperInstalled ? .green : TonicColors.accent)

            VStack(spacing: 12) {
                Text("Privileged Helper")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Helper tool for advanced system operations")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                HelperFeatureRow(
                    icon: "gear",
                    title: "System Optimization",
                    description: "Flush DNS, clear RAM, rebuild services"
                )

                HelperFeatureRow(
                    icon: "trash.fill",
                    title: "Deep Clean",
                    description: "Remove system-level cache files"
                )

                HelperFeatureRow(
                    icon: "externaldrive.badge.plus",
                    title: "Hidden Space",
                    description: "Access hidden system directories"
                )
            }
            .padding()

            if helperManager.isHelperInstalled {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Helper installed")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                Button {
                    Task {
                        await installHelper()
                    }
                } label: {
                    if isInstallingHelper {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Installing...")
                        }
                    } else {
                        Text("Install Helper")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInstallingHelper)
            }

            Text("The helper tool allows Tonic to perform operations that require elevated privileges")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .task {
            _ = helperManager.checkInstallationStatus()
        }
    }

    private var readyPage: some View {
        VStack(spacing: 24) {
            Image(systemName: permissionManager.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(permissionManager.hasFullDiskAccess ? .green : .orange)

            VStack(spacing: 12) {
                Text(permissionManager.hasFullDiskAccess ? "You're All Set!" : "Almost There!")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text(permissionManager.hasFullDiskAccess ? "Tonic is ready to help you optimize your Mac" : "Full Disk Access is recommended for the best experience")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Permission status summary
            VStack(spacing: 12) {
                statusRow(
                    icon: "externaldrive.fill",
                    title: "Full Disk Access",
                    isGranted: permissionManager.hasFullDiskAccess
                )

                statusRow(
                    icon: "checkmark.shield.fill",
                    title: "Privileged Helper",
                    isGranted: helperManager.isHelperInstalled
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            if !permissionManager.hasFullDiskAccess {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.orange)
                    Text("You can grant Full Disk Access later in System Settings, or Disk Analysis will prompt you")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Button {
                    completeOnboarding()
                } label: {
                    Text(permissionManager.hasFullDiskAccess ? "Get Started" : "Continue Without Full Disk Access")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(TonicColors.accent)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                if !permissionManager.hasFullDiskAccess {
                    Button {
                        // Go back to permissions page
                        withAnimation {
                            currentPage = 1
                        }
                    } label: {
                        Text("Back to Permissions")
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)
        }
    }

    private func statusRow(icon: String, title: String, isGranted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isGranted ? .green : .secondary)
                .frame(width: 24)

            Text(title)
                .font(.subheadline)

            Spacer()

            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isGranted ? .green : .red)
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack(spacing: 16) {
            if currentPage > 0 {
                Button("Back") {
                    withAnimation {
                        currentPage -= 1
                    }
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if currentPage < totalPages - 1 {
                Button("Next") {
                    withAnimation {
                        currentPage += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func installHelper() async {
        isInstallingHelper = true

        do {
            try await helperManager.installHelper()
            // Refresh status after installation
            _ = helperManager.checkInstallationStatus()
        } catch {
            // Show error - in production, display alert
            print("Helper installation failed: \(error)")
        }

        isInstallingHelper = false
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        isPresented = false
        dismiss()

        // Show widget onboarding after main onboarding
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.Name("ShowWidgetOnboarding"), object: nil)
        }
    }
}

// MARK: - Supporting Views

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(TonicColors.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(isGranted ? .green : .orange)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: action ?? {}) {
                    HStack(spacing: 6) {
                        if isGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Granted")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundColor(.orange)
                            Text("Grant")
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isGranted || action == nil)
            }

            if !isGranted && action != nil {
                Text("Click to open System Settings")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct HelperFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(TonicColors.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
