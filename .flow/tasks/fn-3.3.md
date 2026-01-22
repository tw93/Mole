# fn-3.3 Implement disk activity tracking

## Description

Disk activity tracking in `WidgetDataManager.updateDiskData()` never works because the values are never assigned.

**File:** `Tonic/Services/WidgetDataManager.swift` (lines 505-556)

**Bug:**
```swift
var currentDiskReadBytes: UInt64 = 0
var currentDiskWriteBytes: UInt64 = 0
// ... these are never assigned ...
primaryDiskActivity = (currentDiskReadBytes != lastDiskReadBytes || ...)
```

**Solution:** Use IOKit to get actual disk I/O statistics from `IOBlockStorageDriver`.

## Acceptance

- [x] Implement IOKit-based disk I/O statistics collection
- [x] Track read/write bytes per second
- [x] Update `primaryDiskActivity` based on real data
- [x] Handle multiple volumes correctly
- [ ] Verify disk activity indicator works in widget (requires fn-3.8)

## Done summary
Implemented IOKit-based disk I/O tracking using IOBlockStorageDriver to get real read/write statistics. Added getDiskIOStatistics() function that queries IOServiceGetMatchingServices for all block storage devices and accumulates read/write bytes.
## Evidence
- Commits:
- Tests:
- PRs: