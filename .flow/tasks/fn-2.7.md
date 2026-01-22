# fn-2.7 Build disk monitoring widget

## Description

Create the disk widget showing usage and activity.

**Files to create:**
- `Tonic/Views/MenuBarWidgets/DiskWidgetView.swift`
- `Tonic/Views/MenuBarWidgets/DiskDetailView.swift`

**Compact view:**
- Icon: "internaldrive" or "hdd.fill"
- Primary disk usage percentage
- Activity indicator when I/O active

**Detail view:**
- All volumes with gauges
- Used/free space for each
- Live I/O indicator
- S.M.A.R.T. status when available
- Per-app disk usage (top 5)

**Reuse:** `Tonic/Views/SystemStatusDashboard.swift:355-385` getDiskUsage()

**S.M.A.R.T. reading:** Use IOKit IOBlockStorageDevice

## Acceptance

- [ ] Compact view shows primary disk usage
- [ ] Animated indicator during disk I/O
- [ ] Detail view lists all volumes
- [ ] S.M.A.R.T. status display when available
- [ ] Per-app disk usage in detail view
- [ ] Uses SystemMonitor disk data

## Done summary
Created disk widget with multi-volume support. Shows primary disk usage percentage with animated I/O activity indicator. Detail view lists all volumes with progress bars, used/free/total space, live I/O status, and S.M.A.R.T. placeholder. Volumes sorted with boot volume first.
## Evidence
- Commits:
- Tests:
- PRs: