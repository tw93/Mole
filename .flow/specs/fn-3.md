# fn-3 Fix Menu Bar Widgets - Critical Issues & Integration

## Description

This epic addresses critical bugs, missing integrations, and implementation gaps discovered during the deep review of Epic fn-2 (Menu Bar System Monitoring with Customizable Widgets).

**Background:** Epic fn-2 implemented a comprehensive widget system but has 8 critical bugs, 6 important issues, and 4 missing integrations that prevent the system from working correctly.

## Goals

1. Fix all critical bugs that could cause crashes or data loss
2. Complete missing integrations so widgets actually appear in menu bar
3. Implement stubbed features (disk I/O, WiFi, GPU)
4. Ensure thread safety and proper memory management

## Technical Context

**Critical Issues to Fix:**
- CPU memory deallocation uses wrong size type
- Disk activity tracking never works (values never assigned)
- Network connection detection always returns ethernet
- WiFi SSID always returns nil
- TemporaryLocationManager not retained (weather location fails)
- NotificationRuleEngine timer leaks (no reference stored)
- WidgetCoordinator never started in app lifecycle
- MemoryPressure/BatteryHealth enums in wrong file (type conflicts)

**Important Issues:**
- @unchecked Sendable without proper synchronization
- WidgetHistoryStore.saveHistory() never called
- GPU monitoring completely unimplemented
- Drag-and-drop may not propagate state
- Notification rules on 10s timer independent of data updates
- BatteryData optional check on non-optional type

**Missing Integrations:**
- WidgetCoordinator.start() not called in AppDelegate
- NotificationRuleEngine.setupObserver() never invoked
- PreferencesView Widgets tab shows placeholder instead of WidgetCustomizationView
- Update interval changes don't propagate to WidgetDataManager

## Files to Modify

- `Tonic/TonicApp.swift` - Start WidgetCoordinator
- `Tonic/Services/WidgetDataManager.swift` - Fix CPU memory, disk I/O, WiFi
- `Tonic/Services/WeatherService.swift` - Fix location retention
- `Tonic/Services/NotificationRuleEngine.swift` - Fix timer management
- `Tonic/Views/PreferencesView.swift` - Connect WidgetCustomizationView
- `Tonic/Models/WidgetConfiguration.swift` - Move enums, fix synchronization
- `Tonic/Services/WidgetHistoryStore.swift` - Add auto-save
- `Tonic/MenuBarWidgets/GPUWidgetView.swift` - Implement GPU monitoring

## Acceptance Criteria

- [ ] All 8 critical bugs fixed
- [ ] WidgetCoordinator starts on app launch (widgets appear in menu bar)
- [ ] Disk activity tracking shows real data
- [ ] WiFi detection works correctly
- [ ] Notification rules evaluate properly
- [ ] History persists across app restarts
- [ ] No memory leaks or crashes
- [ ] All new files added to Xcode project
