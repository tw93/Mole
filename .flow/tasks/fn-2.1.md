# fn-2.1 Create widget configuration data model and preferences

## Description

Create the data models for widget configuration and preferences management. This task establishes the foundation for the widget system.

**Files to create:**
- `Tonic/Models/WidgetConfiguration.swift` - Widget types, configuration model
- `Tonic/Services/WidgetPreferences.swift` - UserDefaults wrapper

**Widget types to support:**
- CPU, GPU, Memory, Disk, Network, Weather

**Models needed:**
```swift
enum WidgetType: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, weather
}

struct WidgetConfiguration: Codable {
    let type: WidgetType
    var isEnabled: Bool
    var position: Int
    var compactMode: Bool
}

@Observable
final class WidgetPreferences {
    static let shared = WidgetPreferences()
    var widgetConfigs: [WidgetConfiguration]
    var updateInterval: TimeInterval
    func save()
    func load()
}
```

**Follow existing pattern:** `Tonic/Views/DarkModeThemeView.swift:37-103` for UserDefaults structure

## Acceptance

- [ ] `WidgetType` enum with all widget types defined
- [ ] `WidgetConfiguration` struct with Codable conformance
- [ ] `WidgetPreferences` class using @Observable pattern
- [ ] UserDefaults persistence with "tonic.widget." key prefix
- [ ] `load()` initializes default config if none exists
- [ ] `save()` persists to UserDefaults
- [ ] Default configuration: CPU, Memory, Disk enabled

## Done summary
Created widget configuration data models and preferences service following existing patterns. Widget types defined for CPU, GPU, Memory, Disk, Network, Weather, and Battery. Display modes support icon only, icon+value, and icon+value+sparkline. WidgetPreferences class uses @Observable pattern with UserDefaults persistence using "tonic.widget." key prefix. Default configuration enables CPU, Memory, and Disk. Update interval presets (Power/Balanced/Performance) control refresh rates.
## Evidence
- Commits:
- Tests:
- PRs: