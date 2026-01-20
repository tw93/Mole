//
//  DarkModeThemeView.swift
//  Tonic
//
//  Dark mode and visual polish
//  Task ID: fn-1.13
//

import SwiftUI

/// Theme mode
public enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: return "desktopcomputer"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Appearance preferences
@Observable
public final class AppearancePreferences: @unchecked Sendable {
    public static let shared = AppearancePreferences()

    public var themeMode: ThemeMode = .system
    public var accentColor: AccentColor = .blue
    public var iconStyle: IconStyle = .filled
    public var reduceTransparency: Bool = false
    public var reduceMotion: Bool = false

    private init() {
        loadFromUserDefaults()
    }

    private enum Keys {
        static let themeMode = "tonic.appearance.themeMode"
        static let accentColor = "tonic.appearance.accentColor"
        static let iconStyle = "tonic.appearance.iconStyle"
        static let reduceTransparency = "tonic.appearance.reduceTransparency"
        static let reduceMotion = "tonic.appearance.reduceMotion"
    }

    public func setThemeMode(_ mode: ThemeMode) {
        themeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.themeMode)
    }

    public func setAccentColor(_ color: AccentColor) {
        accentColor = color
        UserDefaults.standard.set(color.rawValue, forKey: Keys.accentColor)
    }

    public func setIconStyle(_ style: IconStyle) {
        iconStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Keys.iconStyle)
    }

    public func setReduceTransparency(_ reduce: Bool) {
        reduceTransparency = reduce
        UserDefaults.standard.set(reduce, forKey: Keys.reduceTransparency)
    }

    public func setReduceMotion(_ reduce: Bool) {
        reduceMotion = reduce
        UserDefaults.standard.set(reduce, forKey: Keys.reduceMotion)
    }

    private func loadFromUserDefaults() {
        if let modeString = UserDefaults.standard.string(forKey: Keys.themeMode),
           let mode = ThemeMode(rawValue: modeString) {
            themeMode = mode
        }

        if let colorString = UserDefaults.standard.string(forKey: Keys.accentColor),
           let color = AccentColor(rawValue: colorString) {
            accentColor = color
        }

        if let styleString = UserDefaults.standard.string(forKey: Keys.iconStyle),
           let style = IconStyle(rawValue: styleString) {
            iconStyle = style
        }

        reduceTransparency = UserDefaults.standard.bool(forKey: Keys.reduceTransparency)
        reduceMotion = UserDefaults.standard.bool(forKey: Keys.reduceMotion)
    }
}

/// Accent color options
public enum AccentColor: String, CaseIterable, Identifiable {
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case teal = "Teal"
    case gray = "Gray"

    public var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.3, green: 0.5, blue: 1.0)
        case .purple: return Color(red: 0.5, green: 0.3, blue: 1.0)
        case .pink: return Color(red: 1.0, green: 0.3, blue: 0.6)
        case .red: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .orange: return Color(red: 1.0, green: 0.5, blue: 0.0)
        case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .green: return Color(red: 0.3, green: 0.8, blue: 0.4)
        case .teal: return Color(red: 0.2, green: 0.7, blue: 0.7)
        case .gray: return Color(red: 0.5, green: 0.5, blue: 0.5)
        }
    }
}

/// Icon style options
public enum IconStyle: String, CaseIterable, Identifiable {
    case filled = "Filled"
    case outline = "Outline"

    public var id: String { rawValue }
}

/// Appearance settings view
struct AppearanceSettingsView: View {
    @State private var preferences = AppearancePreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    themeSection
                    accentColorSection
                    iconStyleSection
                    effectsSection
                }
                .padding()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferences.themeMode.colorScheme)
    }

    private var header: some View {
        HStack {
            Text("Appearance")
                .font(.headline)

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                ForEach(ThemeMode.allCases) { mode in
                    ThemeModeButton(
                        mode: mode,
                        isSelected: preferences.themeMode == mode
                    ) {
                        preferences.setThemeMode(mode)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Accent Color Section

    private var accentColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent Color")
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 12) {
                ForEach(AccentColor.allCases) { color in
                    AccentColorButton(
                        color: color,
                        isSelected: preferences.accentColor == color
                    ) {
                        preferences.setAccentColor(color)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Icon Style Section

    private var iconStyleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon Style")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                ForEach(IconStyle.allCases) { style in
                    IconStyleButton(
                        style: style,
                        isSelected: preferences.iconStyle == style
                    ) {
                        preferences.setIconStyle(style)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Effects Section

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visual Effects")
                .font(.subheadline)
                .fontWeight(.semibold)

            EffectToggle(
                title: "Reduce Transparency",
                subtitle: "Replace transparency effects with solid colors",
                isOn: $preferences.reduceTransparency
            )

            EffectToggle(
                title: "Reduce Motion",
                subtitle: "Minimize animation effects",
                isOn: $preferences.reduceMotion
            )
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Supporting Views

struct ThemeModeButton: View {
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

struct AccentColorButton: View {
    let color: AccentColor
    let isSelected: Bool

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.color)
                    .frame(width: 32, height: 32)

                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 32, height: 32)

                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct IconStyleButton: View {
    let style: IconStyle
    let isSelected: Bool
    let action: () -> Void

    var iconName: String {
        style == .filled ? "star.fill" : "star"
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? TonicColors.accent : .secondary)

                Text(style.rawValue)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? TonicColors.accent.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct EffectToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
        }
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 500, height: 600)
}
