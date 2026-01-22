//
//  WidgetCustomizationView.swift
//  Tonic
//
//  Widget customization UI with wallpaper preview
//  Task ID: fn-2.11
//

import SwiftUI

// MARK: - Widget Customization View

/// Main UI for customizing menu bar widgets
struct WidgetCustomizationView: View {

    @State private var preferences = WidgetPreferences.shared
    @State private var draggedWidget: WidgetType?
    @State private var wallpaperURL: URL?
    @State private var showingResetAlert = false

    init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Main content
            VStack(spacing: 20) {
                // Wallpaper preview
                wallpaperPreviewSection

                // Available widgets
                availableWidgetsSection

                // Enabled widgets
                enabledWidgetsSection
            }
            .padding()

            Spacer()

            Divider()

            // Footer
            footer
        }
        .frame(width: 600, height: 500)
        .task {
            loadWallpaper()
        }
        .alert("Reset to Defaults", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                preferences.resetToDefaults()
            }
        } message: {
            Text("This will reset all widget settings to their default values.")
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .foregroundColor(TonicColors.accent)

                Text("Widget Customization")
                    .font(.headline)
            }

            Spacer()

            Button {
                showingResetAlert = true
            } label: {
                Text("Reset")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var wallpaperPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Preview area with wallpaper
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Wallpaper background
                    if let wallpaperURL = wallpaperURL,
                       let image = NSImage(contentsOf: wallpaperURL) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Fallback gradient
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }

                    // Widget preview overlay
                    HStack(spacing: 8) {
                        ForEach(preferences.enabledWidgets) { config in
                            widgetPreviewChip(config)
                        }
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
                }
            }
            .frame(height: 80)
            .cornerRadius(12)
        }
    }

    private func widgetPreviewChip(_ config: WidgetConfiguration) -> some View {
        HStack(spacing: 4) {
            Image(systemName: config.type.icon)
                .font(.system(size: 10))
                .foregroundColor(.white)

            Text(widgetPreviewText(config))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.5))
        .cornerRadius(4)
    }

    private func widgetPreviewText(_ config: WidgetConfiguration) -> String {
        switch config.type {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .disk: return "DISK"
        case .network: return "NET"
        case .weather: return "⛅"
        case .battery: return "🔋"
        }
    }

    private var availableWidgetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Widgets")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(WidgetType.allCases, id: \.self) { type in
                    let isEnabled = preferences.config(for: type)?.isEnabled ?? false

                    availableWidgetChip(type: type, isEnabled: isEnabled)
                        .onTapGesture {
                            toggleWidget(type)
                        }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func availableWidgetChip(type: WidgetType, isEnabled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: type.icon)
                .foregroundColor(isEnabled ? TonicColors.accent : .secondary)
                .frame(width: 20)

            Text(type.displayName)
                .font(.caption)
                .foregroundColor(isEnabled ? .primary : .secondary)

            Spacer()

            if isEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(TonicColors.success)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isEnabled ? Color.accentColor.opacity(0.1) : Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }

    private var enabledWidgetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Enabled Widgets")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Drag to reorder")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            let enabledConfigs = preferences.enabledWidgets

            if enabledConfigs.isEmpty {
                Text("No widgets enabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(enabledConfigs.enumerated()), id: \.element.id) { index, config in
                        enabledWidgetRow(config, at: index)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func enabledWidgetRow(_ config: WidgetConfiguration, at index: Int) -> some View {
        HStack(spacing: 12) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .frame(width: 20)

            // Widget info
            HStack(spacing: 8) {
                Image(systemName: config.type.icon)
                    .foregroundColor(TonicColors.accent)

                Text(config.type.displayName)
                    .font(.caption)

                // Display mode selector
                Picker("", selection: Binding(
                    get: { config.displayMode },
                    set: { newMode in
                        preferences.setWidgetDisplayMode(type: config.type, mode: newMode)
                    }
                )) {
                    ForEach(WidgetDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }

            Spacer()

            // Show label toggle
            Toggle("", isOn: Binding(
                get: { config.showLabel },
                set: { show in
                    preferences.setWidgetShowLabel(type: config.type, show: show)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            // Remove button
            Button {
                preferences.setWidgetEnabled(type: config.type, enabled: false)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .onDrag {
            draggedWidget = config.type
            return NSItemProvider(object: config.type.rawValue as NSString)
        } preview: {
            HStack {
                Image(systemName: config.type.icon)
                Text(config.type.displayName)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .onDrop(of: [.text], delegate: WidgetDropDelegate(
            currentType: config.type,
            widgets: preferences.enabledWidgets,
          onDrop: { newType in
                guard let draggedType = draggedWidget else { return false }
                preferences.reorderWidgets(move: draggedType, to: config.type)
                draggedWidget = nil
                return true
            }
        ))
    }

    private var footer: some View {
        HStack {
            Text("\(preferences.enabledWidgets.count) widgets enabled")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("Apply Changes") {
                WidgetCoordinator.shared.refreshWidgets()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helper Methods

    private func loadWallpaper() {
        wallpaperURL = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!)
    }

    private func toggleWidget(_ type: WidgetType) {
        let currentConfig = preferences.config(for: type)
        let newState = !(currentConfig?.isEnabled ?? false)

        if newState {
            // Enable - add to end of enabled list
            let maxPosition = preferences.widgetConfigs.map { $0.position }.max() ?? 0
            var newConfig = WidgetConfiguration.default(for: type, at: maxPosition + 1)
            newConfig.isEnabled = true
            preferences.updateConfig(for: type) { config in
                config = newConfig
            }
        } else {
            // Disable
            preferences.setWidgetEnabled(type: type, enabled: false)
        }
    }
}

// MARK: - Widget Drop Delegate

private struct WidgetDropDelegate: DropDelegate {
    let currentType: WidgetType
    let widgets: [WidgetConfiguration]
    let onDrop: (WidgetType) -> Bool

    func performDrop(info: DropInfo) -> Bool {
        return onDrop(currentType)
    }

    func dropEntered(info: DropInfo) {
        // Could add visual feedback here
    }
}

// MARK: - Widget Preferences Extension

extension WidgetPreferences {
    /// Reorder widgets by moving one type to another's position
    func reorderWidgets(move typeToMove: WidgetType, to targetType: WidgetType) {
        guard let fromIndex = widgetConfigs.firstIndex(where: { $0.type == typeToMove }),
              let toIndex = widgetConfigs.firstIndex(where: { $0.type == targetType }),
              typeToMove != targetType else {
            return
        }

        // Remove from current position
        let movedConfig = widgetConfigs[fromIndex]
        widgetConfigs.remove(at: fromIndex)

        // Insert at new position
        widgetConfigs.insert(movedConfig, at: toIndex)

        // Update all positions
        repositionWidgets()

        saveConfigs()
    }

    private func repositionWidgets() {
        for (index, var config) in widgetConfigs.enumerated() {
            config.position = index
            widgetConfigs[index] = config
        }
    }
}

// MARK: - Preview

#Preview("Widget Customization") {
    WidgetCustomizationView()
        .frame(width: 600, height: 500)
}
