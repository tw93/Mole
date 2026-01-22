# fn-2.4 Build CPU monitoring widget

## Description

Create the CPU widget that displays CPU usage with per-core graphs and top apps.

**Files to create:**
- `Tonic/Views/MenuBarWidgets/CPUWidgetView.swift` - Compact menu bar view
- `Tonic/Views/MenuBarWidgets/CPUDetailView.swift` - Popover detail view

**Compact view (menu bar):**
- Icon: "cpu" or "chart.bar.fill"
- Total CPU percentage
- Color: green (<50%), yellow (50-80%), red (>80%)

**Detail view (popover):**
- Total usage large display
- Per-core bar graph (P/E cores distinguished on Apple Silicon)
- Mini history graph (60 points)
- Top 5 CPU-consuming apps list

**Reuse:** `Tonic/Views/SystemStatusDashboard.swift:186-249` getCPUUsage()

## Acceptance

- [ ] Compact view shows CPU percentage with icon
- [ ] Color coding based on usage level
- [ ] Detail view with per-core graph
- [ ] History line chart (60 data points)
- [ ] Top 5 apps list with percentages
- [ ] Updates every 2 seconds via WidgetDataManager
- [ ] Uses TonicColors for status colors

## Done summary
Created CPU widget with compact menu bar display and detailed popover view. Shows total CPU percentage with color coding (green < 50%, yellow 50-80%, red > 80%). Detail view includes per-core bar graphs, history line chart with 60 data points using SwiftUI Charts, and top 5 CPU-consuming apps. Updates every 2 seconds via WidgetDataManager. Uses TonicColors for status colors.
## Evidence
- Commits:
- Tests:
- PRs: