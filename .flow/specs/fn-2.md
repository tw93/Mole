# Menu Bar System Monitoring with Customizable Widgets

## Overview

Build a comprehensive menu bar system monitoring feature that allows users to customize and display multiple monitoring widgets as separate NSStatusItems in the macOS menu bar. Each widget is self-managing and shows its own detail popover when clicked.

**Key Features:**
- **Separate NSStatusItems**: Each widget (CPU, GPU, Memory, Disk, Network, Weather, Battery) gets its own menu bar icon
- **Self-managing widgets**: Each widget creates and manages its own NSStatusItem
- **Drag-and-drop customization**: Users can reorder widgets and choose display modes
- **Weather with animations**: Delightful SwiftUI animations, auto-location + multiple locations
- **Notification rules engine**: Configurable alerts with threshold + duration requirements
- **Wallpaper preview**: Real wallpaper preview during customization

## Architecture Changes

**Major Change from Initial Plan:**
- Changed from single NSStatusItem with combined view to **separate NSStatusItems per widget**
- Each widget is self-contained and manages its own NSStatusItem
- No central MenuBarWidgetController - widgets coordinate via shared WidgetDataManager

**Widget Display Modes** (per-widget configurable):
1. **Icon only** - Minimal display
2. **Icon + value** - Short label (e.g., "CPU 75%")
3. **Icon + value + sparkline** - Includes mini history graph

**Data Flow:**
```
SystemMonitor (existing) + New Monitors (WeatherService, GPUMonitor, PerAppResourceMonitor)
    ↓
WidgetDataManager (@Observable, aggregates data)
    ↓
Individual Widget Controllers (self-managing NSStatusItem)
    ↓
SwiftUI Views (Compact menu bar + Detail popover)
```

## Component Structure

### New Files to Create:

**Services:**
- `WidgetDataManager.swift` - Central @Observable data aggregator
- `WeatherService.swift` - Open-Meteo API client
- `GPUMonitor.swift` - Apple Silicon GPU monitoring (reference library for IOKit)
- `PerAppResourceMonitor.swift` - Top apps by CPU/memory usage
- `LocationManager.swift` - CoreLocation wrapper
- `NotificationRuleEngine.swift` - Rules evaluation with cooldowns
- `WidgetHistoryStore.swift` - Persist graph history (1 week, performance-optimized)

**Models:**
- `WidgetConfiguration.swift` - Widget types, display modes, positions
- `NotificationRule.swift` - Rule model with threshold + duration
- `WeatherData.swift` - Weather condition models
- `GraphHistory.swift` - Time-series data with persistence

**Views:**
- `MenuBarWidgets/` (NEW folder)
  - `WidgetStatusItem.swift` - Base NSStatusItem wrapper
  - `CPUWidgetView.swift` - Compact + detail views
  - `GPUWidgetView.swift` - Apple Silicon only
  - `MemoryWidgetView.swift` - With pressure dot
  - `DiskWidgetView.swift` - Multi-volume with S.M.A.R.T.
  - `NetworkWidgetView.swift` - Connection-based icon
  - `WeatherWidgetView.swift` - With animations
  - `BatteryWidgetView.swift` - Portable Macs only (auto-hide)
- `WidgetCustomizationView.swift` - With wallpaper preview
- `WidgetOnboardingView.swift` - Tour + default enable
- `NotificationRulesView.swift` - Rules configuration UI

## Detailed Specifications

### Widget Behavior

**CPU Widget:**
- Compact: "cpu" icon + percentage + optional sparkline
- Detail: Total usage, per-core graph (P/E cores on Apple Silicon), history chart (SwiftUI Charts), top 5 apps
- Color: Gradient tint (TonicColors), P/E core distinction in detail view only
- Update: 2 sec default (Power: 5s, Balanced: 2s, Perf: 1s)

**GPU Widget:**
- Apple Silicon only - auto-hide on Intel Macs
- Shows unified memory usage when available
- Uses third-party library reference for IOKit GPU stats
- Temperature if supported

**Memory Widget:**
- Compact: "memorychip" icon + percentage + optional sparkline + pressure dot
- Pressure: Dot only (green/yellow/red)
- Detail: Usage gauge, compressed/swap sizes, history graph, top 5 apps
- Color: Follow app theme (TonicColors)

**Disk Widget:**
- Compact: "internaldrive" icon + primary usage + optional sparkline + I/O indicator
- I/O activity: Animated indicator when disk active (IOKit disk stats)
- S.M.A.R.T.: All internal drives, external drives skipped
- Detail: All volumes sorted by primary first then size, per-app usage

**Network Widget:**
- Compact: Connection-based icon (wifi/ethernet/network) + bandwidth + optional sparkline
- Disconnected state indicator
- Detail: Bandwidth graph, connection type, SSID, IP address
- Delta calculation: Store previous value

**Weather Widget:**
- Compact: SF Symbol icon + temperature + location name
- SF Symbol mapping for conditions (sun.rain, cloud.snow, etc.)
- Detail: Large temp, condition, hourly graph, 7-day forecast, humidity/wind/UV
- Animations: SwiftUI weather effects (rain, snow, clouds)
- Location: Auto-detect via CoreLocation (in onboarding), allow multiple locations
- Offline: Hybrid approach - cached data + error indicators
- Units: Follow system locale with override toggle in Settings

**Battery Widget:**
- Portable Macs only - auto-hide on desktop Macs
- Detect via IOKit Power Sources
- Shows percentage, time remaining, health

### Display Modes (Per-Widget Configurable)

**Mode 1: Icon only** - Minimal, 16pt width
**Mode 2: Icon + value** - Short label, ~40pt width (e.g., "CPU 75%")
**Mode 3: Icon + value + sparkline** - Mini graph, ~80pt width

User can also hide/show widget name label in each mode.

### Notification Rules

**Presets (off by default, user enables):**
- CPU > 80% for 5 minutes
- Disk < 10% free on any volume
- Memory pressure critical

**Custom Rules:**
- Metric: CPU/Memory/Disk/Network/Weather
- Condition: greaterThan / lessThan / equals
- Threshold + Duration required (e.g., "> 80% for 5 min")
- Cooldown: Fixed 15-30 minutes globally
- Max: 5 custom rules

**State Storage:**
- Trigger history log for each rule
- Timestamp + last value + cooldown state
- Persist via UserDefaults

### Widget Customization UI

**Layout:**
- Two sections: Available widgets | Enabled widgets
- Drag-and-drop between sections
- Reorder within Enabled section
- Per-widget: Display mode selector, Hide/show label toggle

**Preview:**
- Real wallpaper via NSWorkspace.desktopImageURL
- Shows live widget arrangement with user's wallpaper
- Visual feedback + confirmation toast on changes

**Actions:**
- Reset to defaults button
- Changes apply immediately to menu bar

### First-Run Experience

**Onboarding:**
- Tour of widget system
- Default enable: CPU, Memory, Disk
- CoreLocation permission prompt for weather
- Quick setup for widget preferences

### History Persistence

**Graph History:**
- 60 data points for graphs
- Persist to disk for 1 week
- Storage: Choose best performance option (UserDefaults + file cache vs database)
- Reset on app launch after 1 week

### Popover Behavior

**Position:** Below widget (standard NSPopover behavior)
**Size:** Medium (~600px) by default, user resizable
**Behavior:** Transient (close when clicking outside)
**Content:** Adaptive layout that rearranges on resize

### Styling

**Icons:** SF Symbols with gradient tint (TonicColors accent/pro)
**Colors:** Follow app theme
**Animations:** Animate on significant change only
**Sparkline:** Mini line chart (30-60 points) in graph mode

## File Structure References

**Existing Code to Reuse:**
- `Tonic/MenuBar/MenuBarController.swift:126-141` - NSStatusItem setup pattern
- `Tonic/Views/SystemStatusDashboard.swift:111-505` - SystemMonitor (extend, don't duplicate)
- `Tonic/Views/SystemStatusDashboard.swift:186-249` - getCPUUsage()
- `Tonic/Views/SystemStatusDashboard.swift:297-351` - getMemoryUsage()
- `Tonic/Views/SystemStatusDashboard.swift:355-385` - getDiskUsage()
- `Tonic/Views/SystemStatusDashboard.swift:394-429` - getNetworkStats()
- `Tonic/Views/SystemStatusDashboard.swift:491-504` - getBatteryInfo()
- `Tonic/Design/DesignComponents.swift:430-487` - StatusLevel/StatusIndicator
- `Tonic/Design/DesignTokens.swift` - All design tokens
- `Tonic/Views/PreferencesView.swift` - Add Widgets tab

**Third-Party References:**
- GPU monitoring: Reference existing library (Stats project approach)
- Per-app monitoring: Investigate for best accuracy/performance
- History graphs: SwiftUI Charts framework

## Key Implementation Notes

1. **Separate NSStatusItems per widget** - each widget self-managing
2. **Per-widget display modes** - icon, icon+value, icon+value+sparkline
3. **Battery widget auto-hides** on desktop Macs (IOKit detection)
4. **P/E cores only on Apple Silicon** - hide on Intel Macs
5. **Network delta via previous value storage**
6. **Disk I/O via IOKit** stats
7. **Weather animations with SwiftUI**
8. **History persistence: 1 week**, performance-optimized storage choice
9. **CoreLocation in onboarding** for weather
10. **Notification rules: threshold + duration required, 5 rule max**
11. **Real wallpaper preview** via NSWorkspace.desktopImageURL
12. **SwiftUI Charts** for history graphs
13. **Power mode presets** for update intervals
14. **Warning badge overlay** on widgets when thresholds crossed

## Acceptance Criteria

### Core Functionality
- [ ] Each widget has separate NSStatusItem in menu bar
- [ ] Widgets can be enabled/disabled independently
- [ ] Full drag-and-drop reordering with live wallpaper preview
- [ ] Per-widget display mode selection (icon/icon+value/icon+value+sparkline)
- [ ] All settings persist across app restarts
- [ ] First-run onboarding with tour + default enable

### Each Widget
- [ ] Compact display with icon + value + optional sparkline
- [ ] Click opens detail popover below widget
- [ ] Detail view has history graph (SwiftUI Charts)
- [ ] Top 5 apps with actual app icons (detail only)
- [ ] Color-coded with warning badge when threshold crossed

### CPU Widget
- [ ] Total CPU percentage with color coding
- [ ] Per-core graph (P/E cores on Apple Silicon)
- [ ] History chart (60 points)
- [ ] Top 5 apps by CPU usage
- [ ] Power/Balanced/Performance update interval modes

### GPU Widget
- [ ] Apple Silicon unified memory usage
- [ ] Auto-hide on Intel Macs
- [ ] Temperature display when supported
- [ ] Graceful handling when unavailable

### Memory Widget
- [ ] Usage percentage with pressure dot (minimal)
- [ ] Compressed and swap sizes
- [ ] Pressure-based color coding
- [ ] Top 5 apps by memory usage

### Disk Widget
- [ ] Primary disk usage + optional sparkline
- [ ] I/O activity indicator (animated)
- [ ] All volumes (primary first, then by size)
- [ ] S.M.A.R.T. status for internal drives
- [ ] Top 5 apps by disk usage

### Network Widget
- [ ] Connection-based icon (wifi/ethernet/network)
- [ ] Bandwidth display (up/down)
- [ ] Disconnected state
- [ ] SSID and IP address in detail
- [ ] Bandwidth history graph

### Weather Widget
- [ ] Current temp + SF Symbol condition icon
- [ ] Auto-location via CoreLocation
- [ ] Multiple location support
- [ ] Hourly + weekly forecast
- [ ] C/F toggle (system locale with override)
- [ ] SwiftUI weather animations
- [ ] Offline hybrid handling

### Battery Widget
- [ ] Shows on portable Macs only (IOKit detection)
- [ ] Auto-hide on desktop Macs
- [ ] Percentage + time remaining
- [ ] Battery health

### Notification Rules
- [ ] Dedicated Rules tab in Settings + per-widget toggles
- [ ] Preset rules (CPU/Disk/Memory alerts) off by default
- [ ] Custom rule creation (max 5 rules)
- [ ] Threshold + Duration requirement
- [ ] 15-30 minute cooldown
- [ ] Trigger history log

### Customization UI
- [ ] Real wallpaper preview (NSWorkspace.desktopImageURL)
- [ ] Drag-and-drop reordering
- [ ] Per-widget display mode selector
- [ ] Visual feedback + toast notifications
- [ ] Reset to defaults

## Quick Commands

```bash
# Build
xcodebuild -scheme Tonic -configuration Debug -destination 'platform=macOS' build

# Run
open /Users/saransh1337/Library/Developer/Xcode/DerivedData/Tonic-*/Build/Products/Debug/Tonic.app

# Check menu bar widget logs
log stream --predicate 'subsystem == "com.tonic.widgets"' --level debug

# Test widget visibility
defaults read com.tonic.Tonic widgetConfigs

# Reset widget preferences
defaults delete com.tonic.Tonic.widgetConfigs
```

## Test Commands

```bash
# Verify all NSStatusItems created
# Expected: One status item per enabled widget

# Test widget reordering
# 1. Open Widget Preferences
# 2. Drag CPU to position 2
# 3. Verify menu bar order updates immediately

# Test display modes
# 1. Select CPU widget
# 2. Cycle through icon / icon+value / icon+value+sparkline
# 3. Verify width changes appropriately

# Test notifications
# 1. Create CPU > 80% for 5 min rule
# 2. Trigger with synthetic load
# 3. Verify notification after duration
# 4. Verify cooldown prevents repeat

# Test weather offline
# 1. Disable network
# 2. Verify cached data + error indicator shows
# 3. Re-enable network
# 4. Verify fresh data loads
```

## References

- `Tonic/MenuBar/MenuBarController.swift` - NSStatusItem patterns
- `Tonic/Views/SystemStatusDashboard.swift` - SystemMonitor to reuse
- `Tonic/Design/DesignComponents.swift` - StatusLevel/StatusIndicator
- `Tonic/Design/DesignTokens.swift` - Design tokens
- `Tonic/Views/PreferencesView.swift` - Settings structure
- [Stats - GitHub](https://github.com/exelban/stats) - GPU/per-app monitoring reference
- [SwiftUI Charts - Apple](https://developer.apple.com/documentation/charts) - Graph framework
- [Open-Meteo API](https://open-meteo.com/) - Weather data

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Too many NSStatusItems | Allow user to disable, horizontal scroll if needed |
| GPU monitoring complexity | Apple Silicon only, reference library |
| Per-app monitoring accuracy | Investigate APIs, choose performance |
| Weather API limits | Open-Meteo (no key, generous limits) |
| History performance | 1 week retention, optimal storage choice |
| CoreLocation denial | Manual location entry fallback |
| Menu bar overflow | User can disable widgets to manage space |
