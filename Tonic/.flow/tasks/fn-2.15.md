# fn-2.15 Add Battery widget for portable Macs

## Description
Create `BatteryWidgetView.swift` - battery monitoring widget with compact menu bar display and detailed popover view. Automatically hides on desktop Macs that have no battery.

**File created:** `Tonic/MenuBarWidgets/BatteryWidgetView.swift`

**Key features:**
- BatteryCompactView: icon, percentage, charging indicator
- BatteryDetailView: circular gauge, time remaining, health status
- BatteryStatusItem: NSStatusItem manager with auto-hide on desktop
- Battery health levels: good, fair, poor
- Color-coded battery levels (green/yellow/red)
- Time remaining formatted as hours and minutes

## Acceptance

- [x] BatteryCompactView with icon, percentage, charging indicator
- [x] BatteryDetailView with circular percentage gauge
- [x] Time remaining display (hours/minutes format)
- [x] Battery health section with status indicators
- [x] BatteryStatusItem with auto-hide on desktop Macs
- [x] IOKit.ps import for battery data access
- [x] Color-coded battery levels and health status

## Done Summary
Created battery widget with compact menu bar view and detailed popover. Auto-hides on desktop Macs (no battery detected). Shows circular percentage gauge, time remaining, charging indicator, and battery health status. Uses IOKit.ps for battery data access.

## Evidence
- Commits:
- Tests:
- PRs:
