# fn-2.6 Build memory monitoring widget

## Description

Create the memory widget showing usage, pressure, and top apps.

**Files to create:**
- `Tonic/Views/MenuBarWidgets/MemoryWidgetView.swift`
- `Tonic/Views/MenuBarWidgets/MemoryDetailView.swift`

**Compact view:**
- Icon: "memorychip" or "chart.pie.fill"
- Memory usage percentage
- Pressure indicator dot (green/yellow/red)

**Detail view:**
- Large usage gauge
- Pressure level with description
- Compressed memory size
- Swap size
- History graph
- Top 5 memory-consuming apps

**Reuse:** `Tonic/Views/SystemStatusDashboard.swift:297-351` getMemoryUsage()

**Pressure colors:** Use existing StatusLevel enum from DesignComponents.swift

## Acceptance

- [ ] Compact view shows usage % with pressure indicator
- [ ] Detail view with usage gauge
- [ ] Pressure color: green (normal), yellow (warning), red (critical)
- [ ] Shows compressed and swap sizes
- [ ] History graph included
- [ ] Top 5 apps list
- [ ] Uses SystemMonitor memory data

## Done summary
Created memory widget with pressure-aware display. Shows usage percentage with pressure indicator dot (green/yellow/red). Detail view includes circular usage gauge, memory breakdown (used/compressed/swap/free), pressure level description, history graph with 60 points, and top 5 memory-consuming apps. Color-coded by memory pressure level.
## Evidence
- Commits:
- Tests:
- PRs: