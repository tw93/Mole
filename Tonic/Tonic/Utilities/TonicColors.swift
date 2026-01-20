//
//  TonicColors.swift
//  Tonic
//
//  Color palette migrated from Mole CLI base.sh
//

import SwiftUI

/// Tonic color palette
/// Migrated from lib/core/base.sh color definitions
public enum TonicColors {
    // Brand colors
    public static let accent = Color(red: 0.3, green: 0.5, blue: 1.0)
    public static let pro = Color(red: 1.0, green: 0.75, blue: 0.0)

    // Status colors (migrated from ESC color codes)
    public static let success = Color(red: 0.2, green: 0.8, blue: 0.4)
    public static let error = Color(red: 1.0, green: 0.3, blue: 0.3)
    public static let warning = Color(red: 1.0, green: 0.6, blue: 0.0)

    // UI colors
    public static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    public static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
    public static let backgroundTertiary = Color(nsColor: .textBackgroundColor)

    public static let textPrimary = Color(nsColor: .labelColor)
    public static let textSecondary = Color(nsColor: .secondaryLabelColor)
    public static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // Category colors for visual distinction
    public static let categorySystem = Color(red: 0.5, green: 0.5, blue: 0.5)
    public static let categoryProductivity = Color(red: 0.2, green: 0.6, blue: 1.0)
    public static let categoryCreativity = Color(red: 0.9, green: 0.3, blue: 0.5)
    public static let categoryDevelopment = Color(red: 0.3, green: 0.7, blue: 0.4)
    public static let categoryCommunication = Color(red: 0.4, green: 0.4, blue: 0.9)
    public static let categoryEntertainment = Color(red: 0.8, green: 0.4, blue: 0.2)
    public static let categoryUtilities = Color(red: 0.6, green: 0.5, blue: 0.3)
}

extension Color {
    /// Initialize from RGB values (0-1)
    init(red: Double, green: Double, blue: Double) {
        self.init(red: red, green: green, blue: blue, opacity: 1.0)
    }

    /// Initialize from hex string
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
