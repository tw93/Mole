//
//  WidgetCustomizationView.swift
//  Tonic
//
//  Widget customization UI with wallpaper preview - Redesigned
//  Task ID: fn-2.11
//

import SwiftUI

// MARK: - Widget Category

/// Categories for filtering widgets in the library
enum WidgetCategory: String, CaseIterable {
    case all = "All"
    case system = "System"
    case network = "Network"
    case utility = "Utility"

    static func category(for type: WidgetType) -> WidgetCategory {
        switch type {
        case .cpu, .memory, .gpu, .disk:
            return .system
        case .network:
            return .network
        case .weather, .battery:
            return .utility
        }
    }

    var categoryLabel: String {
        switch self {
        case .all: return "All"
        case .system: return "SYSTEM"
        case .network: return "INTERNET"
        case .utility: return "LIFESTYLE"
        }
    }
}

// MARK: - Dark Theme Colors

private enum DarkTheme {
    static let background = Color(red: 0.05, green: 0.055, blue: 0.067)
    static let cardBackground = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let cardBorder = Color(red: 0.22, green: 0.22, blue: 0.24)
    static let secondaryText = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let tagBackground = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let accentBlue = Color(red: 0.37, green: 0.62, blue: 1.0)
}

// MARK: - Widget Customization View

/// Main UI for customizing menu bar widgets - Redesigned
struct WidgetCustomizationView: View {

    @State private var preferences = WidgetPreferences.shared
    @State private var draggedWidget: WidgetType?
    @State private var wallpaperURL: URL?
    @State private var showingResetAlert = false
    @State private var selectedCategory: WidgetCategory = .all
    @State private var dataManager = WidgetDataManager.shared
    @State private var selectedWidgetForSettings: WidgetType?
    @State private var hoveredWidget: WidgetType?

    init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header with title and buttons
            headerSection

            ScrollView {
                VStack(spacing: 24) {
                    // Menu bar preview with wallpaper
                    menuBarPreviewSection

                    // Two-column layout: Active Widgets + Widget Library
                    HStack(alignment: .top, spacing: 20) {
                        // Active Widgets (left)
                        activeWidgetsSection
                            .frame(width: 300)

                        // Widget Library (right)
                        widgetLibrarySection
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
        }
        .background(DarkTheme.background)
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
        .sheet(item: $selectedWidgetForSettings) { type in
            WidgetSettingsSheet(widgetType: type, preferences: preferences)
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize Menu Bar")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Drag and drop widgets to arrange your perfect setup. Changes appear instantly in the preview below.")
                    .font(.system(size: 13))
                    .foregroundColor(DarkTheme.secondaryText)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    showingResetAlert = true
                } label: {
                    Text("Reset to Default")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(DarkTheme.tagBackground)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        WidgetCoordinator.shared.refreshWidgets()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Apply Changes")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(DarkTheme.accentBlue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Menu Bar Preview Section

    private var menuBarPreviewSection: some View {
        ZStack {
            // Wallpaper background
            if let wallpaperURL = wallpaperURL,
               let image = NSImage(contentsOf: wallpaperURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Fallback - beautiful nature gradient
                Image(systemName: "photo")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Active Widgets Section

    private var activeWidgetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Active Widgets")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text("\(preferences.enabledWidgets.count) Active")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DarkTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DarkTheme.tagBackground)
                    .cornerRadius(12)
            }

            // Active widgets list
            VStack(spacing: 8) {
                ForEach(Array(preferences.enabledWidgets.enumerated()), id: \.element.id) { index, config in
                    activeWidgetRow(config, at: index)
                }

                // Drop zone placeholder
                dropZonePlaceholder
            }
        }
    }

    private func activeWidgetRow(_ config: WidgetConfiguration, at index: Int) -> some View {
        HStack(spacing: 10) {
            // Drag handle
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 2) {
                        Circle().frame(width: 2.5, height: 2.5)
                        Circle().frame(width: 2.5, height: 2.5)
                    }
                }
            }
            .foregroundColor(Color(white: 0.35))

            // Widget icon with color
            Image(systemName: config.type.icon)
                .font(.system(size: 13))
                .foregroundColor(config.accentColor.colorValue(for: config.type))
                .frame(width: 20)

            // Widget info
            VStack(alignment: .leading, spacing: 1) {
                Text(config.type.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Text(config.displayMode.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(DarkTheme.secondaryText)
            }

            Spacer()

            // Current value display
            HStack(spacing: 5) {
                Image(systemName: config.type.icon)
                    .font(.system(size: 9))
                    .foregroundColor(config.accentColor.colorValue(for: config.type))

                Text(widgetPreviewValue(config))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            // Mini sparkline
            miniSparkline(for: config)
                .frame(width: 36, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DarkTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(hoveredWidget == config.type ? DarkTheme.accentBlue.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
        .scaleEffect(hoveredWidget == config.type ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hoveredWidget)
        .onHover { isHovered in
            hoveredWidget = isHovered ? config.type : nil
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedWidgetForSettings = config.type
            }
        }
        .onDrag {
            draggedWidget = config.type
            return NSItemProvider(object: config.type.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: WidgetDropDelegate(
            currentType: config.type,
            widgets: preferences.enabledWidgets,
            onDrop: { _ in
                guard let draggedType = draggedWidget else { return false }
                preferences.reorderWidgets(move: draggedType, to: config.type)
                draggedWidget = nil
                return true
            }
        ))
        .contextMenu {
            Button {
                selectedWidgetForSettings = config.type
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Divider()

            Button(role: .destructive) {
                withAnimation {
                    preferences.setWidgetEnabled(type: config.type, enabled: false)
                }
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
    }

    private var dropZonePlaceholder: some View {
        HStack {
            Spacer()
            Text("Drop widgets here")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.35))
            Spacer()
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundColor(Color(white: 0.25))
        )
        .onDrop(of: [.text], isTargeted: nil) { _ in
            guard let draggedType = draggedWidget else { return false }
            if preferences.config(for: draggedType)?.isEnabled == false {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    preferences.setWidgetEnabled(type: draggedType, enabled: true)
                }
            }
            draggedWidget = nil
            return true
        }
    }

    private func miniSparkline(for config: WidgetConfiguration) -> some View {
        let data = sparklineData(for: config.type)
        let sparklineColor = config.accentColor.colorValue(for: config.type)

        return GeometryReader { geometry in
            Path { path in
                guard data.count > 1 else { return }

                let stepX = geometry.size.width / CGFloat(data.count - 1)
                let maxY = data.max() ?? 1
                let minY = data.min() ?? 0
                let range = max(maxY - minY, 0.1)

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * stepX
                    let normalizedY = (value - minY) / range
                    let y = geometry.size.height * (1 - normalizedY)

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                LinearGradient(
                    colors: [sparklineColor, sparklineColor.opacity(0.4)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1.5
            )
        }
    }

    private func sparklineData(for type: WidgetType) -> [Double] {
        switch type {
        case .cpu:
            let history = dataManager.cpuHistory.suffix(10)
            return history.isEmpty ? [30, 35, 32, 38, 36, 34, 37, 35, 33, 36] : Array(history)
        case .memory:
            let history = dataManager.memoryHistory.suffix(10)
            return history.isEmpty ? [60, 62, 58, 65, 63, 67, 64, 68, 66, 65] : Array(history)
        default:
            return [30, 35, 32, 38, 36, 34, 37, 35, 33, 36]
        }
    }

    // MARK: - Widget Library Section

    private var widgetLibrarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with filter tabs
            HStack {
                Text("Widget Library")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Filter tabs
                HStack(spacing: 2) {
                    ForEach(WidgetCategory.allCases, id: \.self) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedCategory = category
                            }
                        } label: {
                            Text(category.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(selectedCategory == category ? .white : DarkTheme.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedCategory == category ? DarkTheme.tagBackground : Color.clear)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Widget cards grid
            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredWidgetTypes, id: \.self) { type in
                    widgetLibraryCard(for: type)
                }
            }
        }
    }

    private var filteredWidgetTypes: [WidgetType] {
        if selectedCategory == .all {
            return WidgetType.allCases.filter { type in
                preferences.config(for: type)?.isEnabled != true
            }
        }
        return WidgetType.allCases.filter { type in
            WidgetCategory.category(for: type) == selectedCategory &&
            preferences.config(for: type)?.isEnabled != true
        }
    }

    private func widgetLibraryCard(for type: WidgetType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Preview area
            HStack {
                Spacer()
                widgetPreviewDisplay(for: type)
                Spacer()
            }
            .frame(height: 44)
            .padding(.top, 12)

            // Widget info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(type.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text(WidgetCategory.category(for: type).categoryLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DarkTheme.secondaryText)
                }

                Text(widgetDescription(for: type))
                    .font(.system(size: 11))
                    .foregroundColor(DarkTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Display mode tags - interactive
                HStack(spacing: 4) {
                    ForEach(displayModesForType(type), id: \.self) { mode in
                        Text(mode.shortLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DarkTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(DarkTheme.tagBackground)
                            .cornerRadius(4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(DarkTheme.cardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DarkTheme.cardBorder, lineWidth: 1)
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                toggleWidget(type)
            }
        }
        .onDrag {
            draggedWidget = type
            return NSItemProvider(object: type.rawValue as NSString)
        }
    }

    private func widgetPreviewDisplay(for type: WidgetType) -> some View {
        HStack(spacing: 6) {
            Image(systemName: type.icon)
                .font(.system(size: 14))
                .foregroundColor(widgetAccentColor(for: type))

            Text(widgetPreviewValueForLibrary(for: type))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private func displayModesForType(_ type: WidgetType) -> [WidgetDisplayMode] {
        // All widgets now support both compact and detailed modes
        return [.compact, .detailed]
    }

    // MARK: - Helper Methods

    private func loadWallpaper() {
        wallpaperURL = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!)
    }

    private func toggleWidget(_ type: WidgetType) {
        let currentConfig = preferences.config(for: type)
        let newState = !(currentConfig?.isEnabled ?? false)

        if newState {
            let maxPosition = preferences.widgetConfigs.map { $0.position }.max() ?? 0
            var newConfig = WidgetConfiguration.default(for: type, at: maxPosition + 1)
            newConfig.isEnabled = true
            preferences.updateConfig(for: type) { config in
                config = newConfig
            }
        } else {
            preferences.setWidgetEnabled(type: type, enabled: false)
        }
    }

    private func widgetAccentColor(for type: WidgetType) -> Color {
        switch type {
        case .cpu: return Color(red: 0.37, green: 0.62, blue: 1.0)
        case .memory: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .disk: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .network: return Color(red: 0.39, green: 0.82, blue: 1.0)
        case .gpu: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .battery: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .weather: return Color(red: 1.0, green: 0.84, blue: 0.04)
        }
    }

    private func widgetPreviewValue(_ config: WidgetConfiguration) -> String {
        let usePercent = config.valueFormat == .percentage

        switch config.type {
        case .cpu:
            return "\(Int(dataManager.cpuData.totalUsage))%"
        case .memory:
            if usePercent {
                return "\(Int(dataManager.memoryData.usagePercentage))%"
            } else {
                let usedGB = Double(dataManager.memoryData.usedBytes) / (1024 * 1024 * 1024)
                return String(format: "%.1f GB", usedGB)
            }
        case .disk:
            if let primary = dataManager.diskVolumes.first {
                if usePercent {
                    return "\(Int(primary.usagePercentage))%"
                } else {
                    let freeGB = primary.freeBytes / (1024 * 1024 * 1024)
                    return "\(freeGB)GB"
                }
            }
            return "--"
        case .network:
            return dataManager.networkData.downloadString
        case .gpu:
            if let usage = dataManager.gpuData.usagePercentage {
                return "\(Int(usage))%"
            }
            return "--"
        case .battery:
            return "\(Int(dataManager.batteryData.chargePercentage))%"
        case .weather:
            return "21°C"
        }
    }

    private func widgetPreviewValueForLibrary(for type: WidgetType) -> String {
        switch type {
        case .cpu: return "45%"
        case .memory: return "13.0 GB"
        case .disk: return "41GB"
        case .network: return "12 mb/s"
        case .gpu: return "45%"
        case .battery: return "85%"
        case .weather: return "21°C"
        }
    }

    private func widgetDescription(for type: WidgetType) -> String {
        switch type {
        case .cpu: return "Monitor CPU usage and core activity in real-time."
        case .memory: return "Track RAM usage and available memory."
        case .disk: return "Monitor available space on your primary drive."
        case .network: return "Real-time upload and download speeds."
        case .gpu: return "Monitor GPU utilization and performance."
        case .battery: return "Displays current charge and time remaining estimates."
        case .weather: return "Current local temperature and conditions."
        }
    }
}

// MARK: - Widget Settings Sheet

struct WidgetSettingsSheet: View {
    let widgetType: WidgetType
    @Bindable var preferences: WidgetPreferences
    @Environment(\.dismiss) private var dismiss

    private var config: WidgetConfiguration? {
        preferences.config(for: widgetType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: widgetType.icon)
                        .font(.system(size: 18))
                        .foregroundColor(widgetAccentColor)

                    Text("\(widgetType.displayName) Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(white: 0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()
                .background(Color(white: 0.2))

            // Settings content
            ScrollView {
                VStack(spacing: 20) {
                    // Display Mode Section
                    settingsSection(title: "Display Mode", icon: "square.grid.2x2") {
                        displayModeSelector
                    }

                    // Value Format Section
                    settingsSection(title: "Value Format", icon: "textformat.123") {
                        valueFormatSelector
                    }

                    // Widget Color Section
                    settingsSection(title: "Widget Color", icon: "paintpalette") {
                        colorSelector
                    }

                    // Update Frequency Section
                    settingsSection(title: "Update Frequency", icon: "clock") {
                        updateFrequencySelector
                    }

                    // Preview Section
                    settingsSection(title: "Preview", icon: "eye") {
                        widgetPreview
                    }
                }
                .padding(20)
            }

            Divider()
                .background(Color(white: 0.2))

            // Footer
            HStack {
                Button {
                    withAnimation {
                        preferences.setWidgetEnabled(type: widgetType, enabled: false)
                    }
                    dismiss()
                } label: {
                    Text("Remove Widget")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    WidgetCoordinator.shared.refreshWidgets()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(DarkTheme.accentBlue)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(width: 400, height: 520)
        .background(DarkTheme.background)
    }

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(DarkTheme.secondaryText)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DarkTheme.secondaryText)
                    .textCase(.uppercase)
            }

            content()
        }
    }

    private var displayModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(WidgetDisplayMode.allCases) { mode in
                displayModeButton(mode)
            }
        }
    }

    private func displayModeButton(_ mode: WidgetDisplayMode) -> some View {
        let isSelected = config?.displayMode == mode

        return Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                preferences.setWidgetDisplayMode(type: widgetType, mode: mode)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: iconForDisplayMode(mode))
                    .font(.system(size: 16))

                Text(mode.shortLabel)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : DarkTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? DarkTheme.accentBlue : DarkTheme.cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DarkTheme.accentBlue : DarkTheme.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconForDisplayMode(_ mode: WidgetDisplayMode) -> String {
        switch mode {
        case .compact: return "square.split.1x2"
        case .detailed: return "chart.line.uptrend.xyaxis"
        }
    }

    private var valueFormatSelector: some View {
        HStack(spacing: 8) {
            ForEach(WidgetValueFormat.allCases) { format in
                valueFormatButton(format)
            }
        }
    }

    private func valueFormatButton(_ format: WidgetValueFormat) -> some View {
        let isSelected = config?.valueFormat == format

        return Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                preferences.setWidgetValueFormat(type: widgetType, format: format)
            }
        } label: {
            VStack(spacing: 4) {
                Text(exampleValueForFormat(format))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))

                Text(format.displayName)
                    .font(.system(size: 10))
            }
            .foregroundColor(isSelected ? .white : DarkTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? DarkTheme.accentBlue : DarkTheme.cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DarkTheme.accentBlue : DarkTheme.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func exampleValueForFormat(_ format: WidgetValueFormat) -> String {
        switch format {
        case .percentage:
            switch widgetType {
            case .cpu: return "42%"
            case .memory: return "65%"
            case .disk: return "78%"
            case .gpu: return "45%"
            case .battery: return "85%"
            default: return "50%"
            }
        case .valueWithUnit:
            switch widgetType {
            case .cpu: return "4.2 GHz"
            case .memory: return "13.0 GB"
            case .disk: return "41 GB"
            case .network: return "12 MB/s"
            case .gpu: return "1.2 GHz"
            case .battery: return "3h 20m"
            case .weather: return "21°C"
            }
        }
    }

    private var updateFrequencySelector: some View {
        HStack(spacing: 8) {
            ForEach(WidgetUpdateInterval.allCases) { interval in
                updateIntervalButton(interval)
            }
        }
    }

    private func updateIntervalButton(_ interval: WidgetUpdateInterval) -> some View {
        let isSelected = config?.refreshInterval == interval

        return Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                preferences.setWidgetRefreshInterval(type: widgetType, interval: interval)
            }
        } label: {
            VStack(spacing: 4) {
                Text("\(Int(interval.timeInterval))s")
                    .font(.system(size: 14, weight: .semibold))

                Text(intervalLabel(interval))
                    .font(.system(size: 10))
            }
            .foregroundColor(isSelected ? .white : DarkTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? DarkTheme.accentBlue : DarkTheme.cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DarkTheme.accentBlue : DarkTheme.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func intervalLabel(_ interval: WidgetUpdateInterval) -> String {
        switch interval {
        case .power: return "Power Saver"
        case .balanced: return "Balanced"
        case .performance: return "Real-time"
        }
    }

    private var colorSelector: some View {
        HStack(spacing: 8) {
            ForEach(WidgetAccentColor.allCases) { color in
                colorButton(color)
            }
        }
    }

    private func colorButton(_ color: WidgetAccentColor) -> some View {
        let isSelected = config?.accentColor == color

        return Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                preferences.setWidgetColor(type: widgetType, color: color)
            }
        } label: {
            VStack(spacing: 6) {
                // Color swatch
                Circle()
                    .fill(swatchColor(for: color))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: isSelected ? "checkmark" : "")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    )

                Text(color.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white : DarkTheme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? DarkTheme.accentBlue : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func swatchColor(for color: WidgetAccentColor) -> Color {
        switch color {
        case .system:
            // Show the widget's default color for "Auto"
            return widgetAccentColor
        case .blue: return Color(red: 0.37, green: 0.62, blue: 1.0)
        case .green: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .purple: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
        }
    }

    private var widgetPreview: some View {
        HStack {
            Spacer()

            HStack(spacing: 8) {
                Image(systemName: widgetType.icon)
                    .font(.system(size: 14))
                    .foregroundColor(previewColor)

                if config?.displayMode == .compact || config?.displayMode == .detailed {
                    Text(previewValue)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }

                if config?.displayMode == .detailed {
                    // Mini sparkline
                    sparklinePreview
                        .frame(width: 40, height: 14)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.4))
            .cornerRadius(6)

            Spacer()
        }
        .padding(.vertical, 16)
        .background(DarkTheme.cardBackground)
        .cornerRadius(8)
    }

    private var previewColor: Color {
        guard let config = config else {
            return widgetAccentColor
        }
        return config.accentColor.colorValue(for: widgetType)
    }

    private var previewValue: String {
        let usePercent = config?.valueFormat == .percentage
        switch widgetType {
        case .cpu: return usePercent ? "42%" : "4.2 GHz"
        case .memory: return usePercent ? "65%" : "13.0 GB"
        case .disk: return usePercent ? "78%" : "41 GB"
        case .network: return "12 MB/s"
        case .gpu: return usePercent ? "45%" : "1.2 GHz"
        case .battery: return usePercent ? "85%" : "3h 20m"
        case .weather: return "21°C"
        }
    }

    private var sparklinePreview: some View {
        GeometryReader { geometry in
            Path { path in
                let data: [Double] = [30, 35, 32, 45, 42, 38, 44, 40, 42]
                let stepX = geometry.size.width / CGFloat(data.count - 1)
                let maxY = data.max() ?? 1
                let minY = data.min() ?? 0
                let range = max(maxY - minY, 0.1)

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * stepX
                    let normalizedY = (value - minY) / range
                    let y = geometry.size.height * (1 - normalizedY)

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                LinearGradient(
                    colors: [previewColor, previewColor.opacity(0.4)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1.5
            )
        }
    }

    private var widgetAccentColor: Color {
        switch widgetType {
        case .cpu: return Color(red: 0.37, green: 0.62, blue: 1.0)
        case .memory: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .disk: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .network: return Color(red: 0.39, green: 0.82, blue: 1.0)
        case .gpu: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .battery: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .weather: return Color(red: 1.0, green: 0.84, blue: 0.04)
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
        // Visual feedback handled by hover state
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
        for (index, _) in widgetConfigs.enumerated() {
            widgetConfigs[index].position = index
        }

        saveConfigs()
    }
}

// MARK: - Preview

#Preview("Widget Customization") {
    WidgetCustomizationView()
        .frame(width: 960, height: 700)
}
