//
//  DesignComponents.swift
//  Tonic
//
//  Reusable SwiftUI components built on design tokens
//

import SwiftUI

// MARK: - Card Component

struct Card<Content: View>: View {
    let content: Content
    var padding: CGFloat = DesignTokens.Spacing.cardPadding
    var cornerRadius: CGFloat = DesignTokens.CornerRadius.large

    init(padding: CGFloat = DesignTokens.Spacing.cardPadding, cornerRadius: CGFloat = DesignTokens.CornerRadius.large, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(DesignTokens.Colors.surface)
            .cornerRadius(cornerRadius)
            .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 2)
    }
}

// MARK: - Primary Button

struct PrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .font(DesignTokens.Typography.headlineSmall)
            }
            .frame(minWidth: DesignTokens.Layout.minButtonHeight)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(isPressed ? DesignTokens.Colors.accent.opacity(0.8) :
                          isHovered ? DesignTokens.Colors.accent : DesignTokens.Colors.accent.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(DesignTokens.CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignTokens.Animation.fast) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Secondary Button

struct SecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .font(DesignTokens.Typography.headlineSmall)
            }
            .frame(minWidth: DesignTokens.Layout.minButtonHeight)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(isHovered ? DesignTokens.Colors.surfaceHovered : DesignTokens.Colors.surface)
            .foregroundColor(DesignTokens.Colors.text)
            .cornerRadius(DesignTokens.CornerRadius.medium)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(DesignTokens.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignTokens.Animation.fast) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let value: Double // 0-1
    let total: Double
    var color: Color? = nil
    var height: CGFloat = 8
    var showPercentage: Bool = true

    init(value: Double, total: Double = 1.0, color: Color? = nil, height: CGFloat = 8, showPercentage: Bool = true) {
        self.value = min(max(value / total, 0), 1)
        self.total = total
        self.color = color
        self.height = height
        self.showPercentage = showPercentage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if showPercentage {
                HStack {
                    Text("\(Int(value * 100))%")
                        .font(DesignTokens.Typography.captionLarge)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    Spacer()
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(DesignTokens.Colors.backgroundSecondary)

                    // Progress fill
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(color ?? progressColor)
                        .frame(width: geometry.size.width * value)
                        .animation(.easeInOut(duration: 0.3), value: value)
                }
            }
            .frame(height: height)
        }
    }

    private var progressColor: Color {
        switch value {
        case 0..<0.5: return DesignTokens.Colors.progressLow
        case 0.5..<0.8: return DesignTokens.Colors.progressMedium
        default: return DesignTokens.Colors.progressHigh
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = DesignTokens.Colors.accent
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(DesignTokens.Typography.headlineSmall)
                Spacer()
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(value)
                    .font(DesignTokens.Typography.displaySmall)

                Text(title)
                    .font(DesignTokens.Typography.bodySmall)
                    .foregroundColor(DesignTokens.Colors.textSecondary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.captionSmall)
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: 20)
            }
            Text(label)
                .font(DesignTokens.Typography.bodyMedium)
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Typography.bodyMedium)
                .foregroundColor(DesignTokens.Colors.text)
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(DesignTokens.Typography.headlineMedium)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.bodySmall)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }

            Spacer()

            if let action = action, let actionTitle = actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(DesignTokens.Typography.bodySmall)
                }
                .buttonStyle(.link)
            }
        }
    }
}

// MARK: - Badge

struct Badge: View {
    let text: String
    var color: Color = DesignTokens.Colors.accent
    var size: BadgeSize = .medium

    enum BadgeSize {
        case small, medium, large

        var padding: (horizontal: CGFloat, vertical: CGFloat) {
            switch self {
            case .small: return (6, 2)
            case .medium: return (8, 4)
            case .large: return (12, 6)
            }
        }

        var font: Font {
            switch self {
            case .small: return DesignTokens.Typography.captionSmall
            case .medium: return DesignTokens.Typography.captionMedium
            case .large: return DesignTokens.Typography.captionLarge
            }
        }
    }

    var body: some View {
        Text(text)
            .font(size.font)
            .foregroundColor(.white)
            .padding(.horizontal, size.padding.horizontal)
            .padding(.vertical, size.padding.vertical)
            .background(color)
            .cornerRadius(DesignTokens.CornerRadius.round)
    }
}

// MARK: - Loading Indicator

struct LoadingIndicator: View {
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                DesignTokens.Colors.accent,
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 24, height: 24)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isRotating)
            .onAppear {
                isRotating = true
            }
    }
}

// MARK: - Empty State

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(DesignTokens.Colors.textTertiary)

            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(DesignTokens.Typography.headlineMedium)
                    .foregroundColor(DesignTokens.Colors.text)

                Text(message)
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let action = action, let actionTitle = actionTitle {
                PrimaryButton(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xxl)
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search..."

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(DesignTokens.Colors.textSecondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.bodyMedium)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .stroke(DesignTokens.Colors.border, lineWidth: 1)
        )
    }
}

// MARK: - Toggle Row

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(DesignTokens.Typography.bodyMedium)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.bodySmall)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.medium)
    }
}

// MARK: - RAG Status Indicators

/// Status level for RAG (Red-Amber-Green) indicators
enum StatusLevel: Sendable {
    case healthy   // Green - all good
    case warning   // Amber - partial/not optimal
    case critical  // Red - missing/error
    case unknown   // Gray - not checked

    var color: Color {
        switch self {
        case .healthy: return TonicColors.success
        case .warning: return TonicColors.warning
        case .critical: return TonicColors.error
        case .unknown: return .gray
        }
    }

    var icon: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .healthy: return "Good"
        case .warning: return "Warning"
        case .critical: return "Issue"
        case .unknown: return "Unknown"
        }
    }
}

/// RAG status indicator component - shows colored dot with label
struct StatusIndicator: View {
    let level: StatusLevel
    let size: CGFloat

    init(level: StatusLevel, size: CGFloat = 12) {
        self.level = level
        self.size = size
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.color)
                .frame(width: size, height: size)

            Text(level.label)
                .font(.caption)
                .foregroundColor(level.color)
        }
    }
}

/// Status card with icon, title, description, and RAG indicator
struct StatusCard: View {
    let icon: String
    let title: String
    let description: String
    let status: StatusLevel
    let action: (() -> Void)?

    init(icon: String, title: String, description: String, status: StatusLevel, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.description = description
        self.status = status
        self.action = action
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(status.color)
                .frame(width: 32)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status indicator
            StatusIndicator(level: status)

            // Action button if provided
            if let action = action {
                Button(action: action) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(DesignTokens.CornerRadius.medium)
    }
}
