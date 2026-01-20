//
//  AccessibilityView.swift
//  Tonic
//
//  Accessibility and performance optimization
//  Task ID: fn-1.12
//

import SwiftUI

/// Accessibility and performance settings
struct AccessibilityView: View {
    @State private var reduceMotion = false
    @State private var reduceTransparency = false
    @State private var highContrast = false
    @State private var preferredContentSize = ContentSize.regular
    @State private var voiceOverEnabled = false
    @State private var increaseLineHeight = false
    @State private var showLabels = true

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    visionSection
                    motorSection
                    displaySection
                    performanceSection
                }
                .padding()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Accessibility")
                .font(.headline)

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Vision Section

    private var visionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccessibilitySectionHeader(icon: "eye.fill", title: "Vision", description: "Adjust visual display options")

            AccessibilityToggle(
                title: "High Contrast Mode",
                description: "Increase contrast for better visibility",
                isOn: $highContrast
            )

            AccessibilityToggle(
                title: "Increase Line Height",
                description: "Add more spacing between lines of text",
                isOn: $increaseLineHeight
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Content Size")
                    .font(.subheadline)

                Picker("", selection: $preferredContentSize) {
                    Text("Extra Small").tag(ContentSize.extraSmall)
                    Text("Small").tag(ContentSize.small)
                    Text("Regular").tag(ContentSize.regular)
                    Text("Large").tag(ContentSize.large)
                    Text("Extra Large").tag(ContentSize.extraLarge)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Motor Section

    private var motorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccessibilitySectionHeader(icon: "hand.raised.fill", title: "Motor", description: "Interaction assistance options")

            AccessibilityToggle(
                title: "Reduce Motion",
                description: "Minimize animation and motion effects",
                isOn: $reduceMotion
            )
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Display Section

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccessibilitySectionHeader(icon: "display", title: "Display", description: "Visual appearance options")

            AccessibilityToggle(
                title: "Reduce Transparency",
                description: "Replace transparency with solid colors",
                isOn: $reduceTransparency
            )

            AccessibilityToggle(
                title: "Show Icon Labels",
                description: "Always display text labels next to icons",
                isOn: $showLabels
            )

            VoiceOverIndicator(isEnabled: $voiceOverEnabled)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Performance Section

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccessibilitySectionHeader(icon: "gauge.with.dots.needle.67percent", title: "Performance", description: "App performance optimization")

            VStack(alignment: .leading, spacing: 12) {
                PerformanceRow(
                    title: "Background Scanning",
                    status: "Optimized"
                )

                PerformanceRow(
                    title: "Memory Usage",
                    status: "Normal",
                    value: "120 MB"
                )

                PerformanceRow(
                    title: "Disk Cache",
                    status: "Managed",
                    value: "45 MB"
                )

                PerformanceRow(
                    title: "Animation Performance",
                    status: "60 FPS"
                )
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Supporting Types

enum ContentSize: String, CaseIterable {
    case extraSmall = "XS"
    case small = "S"
    case regular = "M"
    case large = "L"
    case extraLarge = "XL"

    var scale: CGFloat {
        switch self {
        case .extraSmall: return 0.8
        case .small: return 0.9
        case .regular: return 1.0
        case .large: return 1.1
        case .extraLarge: return 1.2
        }
    }
}

// MARK: - Supporting Views

struct AccessibilitySectionHeader: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(TonicColors.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

struct AccessibilityToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(description)")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct VoiceOverIndicator: View {
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "accessibility")
                .font(.title2)
                .foregroundColor(isEnabled ? .green : .gray)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("VoiceOver")
                    .font(.subheadline)

                Text(isEnabled ? "VoiceOver is currently enabled" : "VoiceOver is disabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Circle()
                .fill(isEnabled ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
        }
        .onAppear {
            // Check VoiceOver status
            isEnabled = NSWorkspace.shared.isVoiceOverEnabled
        }
    }
}

struct PerformanceRow: View {
    let title: String
    let status: String
    var value: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)

                if let value = value {
                    Text(value)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(status)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch status {
        case "Optimized", "Normal", "Managed", "60 FPS":
            return .green
        case "High", "Large":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Accessibility Modifier

struct AccessibleView: ViewModifier {
    let label: String
    let hint: String?

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }
}

extension View {
    func accessible(label: String, hint: String? = nil) -> some View {
        modifier(AccessibleView(label: label, hint: hint))
    }
}

// MARK: - Preview

#Preview {
    AccessibilityView()
        .frame(width: 500, height: 700)
}
