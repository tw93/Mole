# fn-3.4 Fix network connection and WiFi detection

## Description

Network connection detection always returns `.ethernet` because `getWiFiInterface()` is not implemented.

**File:** `Tonic/Services/WidgetDataManager.swift` (lines 638-662)

**Issues:**
- `getWiFiInterface()` always returns `nil`
- `getWiFiSSID()` always returns `nil`
- Connection type always shows ethernet icon

**Solution:** Use CoreWLAN framework (`CWInterface` class) for accurate WiFi detection.

## Acceptance

- [x] Import CoreWLAN framework
- [x] Implement `getWiFiInterface()` using `CWWiFiClient.shared().interfaces()`
- [x] Implement `getWiFiSSID()` using `CWInterface.ssid()`
- [x] Return correct connection type (.wifi, .ethernet, .other)
- [ ] Verify network widget shows correct icon and SSID (requires fn-3.8)

## Done summary
Added CoreWLAN framework integration for accurate WiFi detection. getConnectionType() now uses CWWiFiClient to detect WiFi vs Ethernet. getWiFiSSID() returns the actual SSID using CWInterface.ssid().
## Evidence
- Commits:
- Tests:
- PRs: