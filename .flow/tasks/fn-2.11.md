# fn-2.11 Build widget customization UI with wallpaper preview

## Description

Create the widget customization UI that allows users to enable/disable and reorder widgets with live wallpaper preview.

**Files to create:**
- `Tonic/Views/WidgetCustomizationView.swift` - Main customization UI
- `Tonic/Views/WidgetPreviewContainer.swift` - Wallpaper preview component

**UI Layout:**
```
+------------------------------------------+
| Widget Customization              [Reset] |
+------------------------------------------+
|                                          |
|  [Wallpaper Preview Area]                |
|  ┌────────────────────────────────────┐  |
|  │ 🌐 75% 💾 45% 💿 80% 🌤️ 72°       │  | <- Preview with wallpaper
|  └────────────────────────────────────┘  |
|                                          |
|  Available Widgets                       |
|  [CPU] [GPU] [MEM] [DISK] [NET] [⛅]     |
|                                          |
|  Enabled (drag to reorder)               |
|  ┌────────────────────────────────────┐  |
|  | ☑ CPU  ☑ Memory  ☑ Disk  ☑ Weather|  |
|  └────────────────────────────────────┘  |
|                                          |
|  [Apply Changes]                         |
+------------------------------------------+
```

**Wallpaper access:**
- Use NSWorkspace.desktopImageURL for current wallpaper
- Fallback to blurred gradient if unavailable

**Drag & drop:**
- Use SwiftUI `.onDrag` and `.onDrop`
- Update WidgetPreferences position on drop

## Acceptance

- [ ] Two-column layout: Available | Enabled
- [ ] Drag widgets between sections
- [ ] Reorder within Enabled section
- [ ] Wallpaper preview shows live widget arrangement
- [ ] Checkbox for enable/disable
- [ ] Reset to defaults button
- [ ] Changes apply immediately
- [ ] Uses DesignTokens for styling

## Done summary
Created widget customization UI with wallpaper preview. Two-column layout with Available and Enabled sections. Drag-and-drop widget arrangement with live wallpaper preview via NSWorkspace.desktopImageURL. Checkbox for enable/disable, display mode selector, and show label toggle. Reset to defaults button. Changes apply immediately via WidgetCoordinator refresh.
## Evidence
- Commits:
- Tests:
- PRs: