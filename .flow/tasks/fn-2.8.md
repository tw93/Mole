# fn-2.8 Build network monitoring widget

## Description

Create the network widget showing bandwidth and connectivity.

**Files to create:**
- `Tonic/Views/MenuBarWidgets/NetworkWidgetView.swift`
- `Tonic/Views/MenuBarWidgets/NetworkDetailView.swift`

**Compact view:**
- Icon: "wifi" or "network"
- Arrow indicators for up/down
- Current bandwidth (e.g., "↓2.5MB ↑500KB")
- Disconnected state when offline

**Detail view:**
- Large bandwidth display
- Connection type (WiFi/Ethernet)
- SSID when on WiFi
- Signal strength
- IP address
- Graph of recent activity

**Reuse:** `Tonic/Views/SystemStatusDashboard.swift:394-429` getNetworkStats()

**Use NWPathMonitor** for connectivity status

## Acceptance

- [ ] Compact view shows up/down bandwidth
- [ ] Icon reflects connection type
- [ ] Shows disconnected state
- [ ] Detail view has bandwidth graph
- [ ] Displays IP address and SSID
- [ ] Updates every 5 seconds
- [ ] Uses delta calculation for accurate bandwidth

## Done summary
Created network widget with bandwidth display. Shows up/down speeds with arrow indicators, connection type (WiFi/Ethernet), and disconnected state. Detail view includes bandwidth graphs for upload/download history, SSID, and IP address. Uses delta calculation for accurate bandwidth measurement.
## Evidence
- Commits:
- Tests:
- PRs: