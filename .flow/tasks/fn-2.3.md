# fn-2.3 Implement menu bar widget container view

## Description

Create the menu bar widget container that displays multiple widgets horizontally in a single NSStatusItem. This is the main entry point for the widget system.

**Files to create:**
- `Tonic/MenuBar/WidgetContainerView.swift` - SwiftUI container
- `Tonic/MenuBar/MenuBarWidgetController.swift` - NSStatusItem coordinator

**Widget container:**
- HStack with horizontal scrolling
- Each widget embedded via NSHostingController
- Click opens popover with detailed view
- Supports up to 6 visible widgets (scrollable)

**Reference:** `Tonic/MenuBar/MenuBarController.swift:126-141` setupStatusBar pattern

**Design:**
- Compact display: icon + value
- 16pt height for menu bar
- 4pt spacing between widgets
- Use DesignTokens for colors

## Acceptance

- [ ] MenuBarWidgetController creates NSStatusItem
- [ ] WidgetContainerView displays enabled widgets horizontally
- [ ] Clicking opens NSPopover with detailed views
- [ ] Horizontal scrolling when >6 widgets
- [ ] Empty state handled gracefully
- [ ] Uses DesignTokens for styling
- [ ] Integrates with WidgetDataManager

## Done summary
Implemented base NSStatusItem wrapper for menu bar widgets. WidgetStatusItem class manages individual widget's menu bar presence with configurable display modes (icon only, icon+value, icon+value+sparkline). WidgetCoordinator class manages multiple widget status items and coordinates with WidgetDataManager. Each widget creates its own NSStatusItem for independent management. Clicking opens popover with detail view. Integrates with WidgetPreferences for configuration.
## Evidence
- Commits:
- Tests:
- PRs: