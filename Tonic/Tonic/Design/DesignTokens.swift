//
//  DesignTokens.swift
//  Tonic
//
//  Design system tokens for colors, typography, spacing, and animations
//

import SwiftUI

// MARK: - Design Tokens

/// Design system tokens for consistent UI across the app
enum DesignTokens {

    // MARK: - Color Extensions

    /// Extended color palette
    enum Colors {
        // Brand colors (from TonicColors)
        static let accent = TonicColors.accent
        static let pro = TonicColors.pro
        static let success = TonicColors.success
        static let error = TonicColors.error
        static let warning = TonicColors.warning

        // Semantic colors
        static let background = Color(nsColor: .windowBackgroundColor)
        static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
        static let backgroundTertiary = Color(nsColor: .textBackgroundColor)

        static let text = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        // Surface colors
        static let surface = Color(red: 0.12, green: 0.12, blue: 0.13)
        static let surfaceElevated = Color(red: 0.15, green: 0.15, blue: 0.17)
        static let surfaceHovered = Color(red: 0.18, green: 0.18, blue: 0.20)

        // Border colors
        static let border = Color(red: 0.2, green: 0.2, blue: 0.22)
        static let borderFocused = Color(red: 0.3, green: 0.5, blue: 1.0)

        // Overlay colors
        static let overlay = Color.black.opacity(0.4)
        static let overlayLight = Color.black.opacity(0.2)

        // Progress colors
        static let progressLow = Color(red: 0.2, green: 0.8, blue: 0.4)
        static let progressMedium = Color(red: 1.0, green: 0.6, blue: 0.0)
        static let progressHigh = Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    // MARK: - Typography Scale

    /// Typography scale for consistent text styling
    enum Typography {
        // Display sizes
        static let displayLarge = Font.system(size: 32, weight: .bold, design: .default)
        static let displayMedium = Font.system(size: 28, weight: .bold, design: .default)
        static let displaySmall = Font.system(size: 24, weight: .semibold, design: .default)

        // Headline sizes
        static let headlineLarge = Font.system(size: 20, weight: .semibold, design: .default)
        static let headlineMedium = Font.system(size: 18, weight: .semibold, design: .default)
        static let headlineSmall = Font.system(size: 16, weight: .medium, design: .default)

        // Body sizes
        static let bodyLarge = Font.system(size: 16, weight: .regular, design: .default)
        static let bodyMedium = Font.system(size: 14, weight: .regular, design: .default)
        static let bodySmall = Font.system(size: 12, weight: .regular, design: .default)

        // Caption sizes
        static let captionLarge = Font.system(size: 12, weight: .medium, design: .default)
        static let captionMedium = Font.system(size: 11, weight: .regular, design: .default)
        static let captionSmall = Font.system(size: 10, weight: .regular, design: .default)

        // Monospace (for code/numbers)
        static let monoLarge = Font.system(size: 16, weight: .regular, design: .monospaced)
        static let monoMedium = Font.system(size: 14, weight: .regular, design: .monospaced)
        static let monoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
    }

    // MARK: - Spacing Constants

    /// Spacing scale for consistent layout
    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64

        // Component-specific spacing
        static let cardPadding: CGFloat = 16
        static let listPadding: CGFloat = 12
        static let buttonPadding: CGFloat = 12
        static let inputPadding: CGFloat = 8
    }

    // MARK: - Corner Radius

    /// Corner radius scale
    enum CornerRadius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let xlarge: CGFloat = 16
        static let round: CGFloat = 9999 // Fully rounded
    }

    // MARK: - Animation Durations

    /// Animation timing
    enum AnimationDuration {
        static let instant: TimeInterval = 0
        static let fast: TimeInterval = 0.15
        static let normal: TimeInterval = 0.25
        static let slow: TimeInterval = 0.35
        static let slower: TimeInterval = 0.5
    }

    // MARK: - Animation Curves

    /// Animation easing curves
    enum AnimationCurve {
        static var linear: SwiftUI.Animation { .linear }
        static var easeIn: SwiftUI.Animation { .easeIn }
        static var easeOut: SwiftUI.Animation { .easeOut }
        static var easeInOut: SwiftUI.Animation { .easeInOut }

        // Custom curves
        static var spring: SwiftUI.Animation {
            .spring(response: 0.3, dampingFraction: 0.7)
        }
        static var springBouncy: SwiftUI.Animation {
            .spring(response: 0.4, dampingFraction: 0.5)
        }
        static var smooth: SwiftUI.Animation {
            .timingCurve(0.25, 0.1, 0.25, 1.0)
        }
    }

    // MARK: - Combined Animations

    /// Predefined animation combinations
    enum Animation {
        static let fast = SwiftUI.Animation.easeOut(duration: AnimationDuration.fast)
        static let normal = SwiftUI.Animation.easeInOut(duration: AnimationDuration.normal)
        static let slow = SwiftUI.Animation.easeInOut(duration: AnimationDuration.slow)
        static let spring = AnimationCurve.spring
        static let springBouncy = AnimationCurve.springBouncy
    }

    // MARK: - Shadow

    /// Shadow styles
    enum Shadow {
        static let small = NSShadow()
        static let medium: NSShadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
            shadow.shadowOffset = NSSize(width: 0, height: 2)
            shadow.shadowBlurRadius = 4
            return shadow
        }()
        static let large: NSShadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowOffset = NSSize(width: 0, height: 4)
            shadow.shadowBlurRadius = 8
            return shadow
        }()
    }

    // MARK: - Layout

    /// Layout constants
    enum Layout {
        static let minButtonHeight: CGFloat = 36
        static let minRowHeight: CGFloat = 44
        static let maxContentWidth: CGFloat = 1200
        static let sidebarWidth: CGFloat = 220
        static let cardMinWidth: CGFloat = 280
    }
}

// MARK: - Font Extensions

extension Font {
    /// Initialize from typography token
    static func typography(_ token: Font) -> Font {
        return token
    }

    /// Monospace font for numbers/code
    static func mono(size: CGFloat, weight: Weight = .regular) -> Font {
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - View Extensions for Design Tokens

extension View {
    /// Apply card styling
    func cardStyle() -> some View {
        self
            .background(DesignTokens.Colors.surface)
            .cornerRadius(DesignTokens.CornerRadius.large)
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    /// Apply hover effect
    func hoverEffect() -> some View {
        self.onHover { isHovered in
            NSCursor.pointingHand.push()
        }
    }
}

// MARK: - Animation Extensions

// No extensions needed - using SwiftUI.Animation directly
