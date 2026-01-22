# fn-3.11 Implement Apple Silicon GPU monitoring

## Description

GPU monitoring was completely unimplemented - `updateGPUData()` was a stub that returned no data.

**File:** `Tonic/Services/WidgetDataManager.swift` (lines 734-744)

**Current:**
```swift
private func updateGPUData() {
    // GPU monitoring requires IOKit GPU access
    // Return nil data for now
}
```

**Solution:** Use IOKit to read Apple Silicon GPU statistics from the IOGPU device.

## Acceptance

- [x] Implement IOKit-based GPU data collection
- [x] Get GPU memory usage (used/total unified memory)
- [x] Get GPU utilization percentage
- [x] Update `gpuData` property with real values
- [x] Verify GPU widget shows actual data on Apple Silicon
- [x] Hide GPU widget on Intel Macs (no unified memory)

## Done summary
Implemented Apple Silicon GPU monitoring using IOKit IOGPU/IOAccelerator devices. GPU widget now shows unified memory usage, estimated utilization from IORegistry, and thermal information where available. On Intel Macs, returns empty GPUData to properly hide GPU widget.
## Evidence
- Commits:
- Tests:
- PRs: