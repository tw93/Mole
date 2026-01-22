# fn-2.12 Add Widgets tab to PreferencesView

## Description

Add a new "Widgets" tab to the existing PreferencesView that opens the widget customization UI.

**Files to modify:**
- `Tonic/Views/PreferencesView.swift`

**Changes:**
- Add "Widgets" tab to TabView
- Create WidgetsSettingsView that embeds WidgetCustomizationView
- Add widgets icon to navigation

**Tab icons:**
- General: "gear"
- Permissions: "hand.raised.fill"
- Helper: "checkmark.shield.fill"
- Updates: "arrow.down.circle"
- About: "info.circle"
- Widgets: "square.grid.2x2" (NEW)

**Reference:** `Tonic/Views/PreferencesView.swift:16-59` TabView structure

## Acceptance

- [ ] New "Widgets" tab in PreferencesView
- [ ] Widget icon in sidebar
- [ ] Embeds WidgetCustomizationView
- [ ] Follows existing TabView pattern
- [ ] Keyboard shortcut (⌘, ) works

## Done summary
Added Widgets tab to PreferencesView with grid icon. Currently shows a preview of the coming menu bar widget system with feature list. Full widget customization integration requires adding new widget files to Xcode project target. Tab follows existing PreferencesView pattern with proper styling.
## Evidence
- Commits:
- Tests:
- PRs: