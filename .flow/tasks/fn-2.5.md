# fn-2.5 Build GPU monitoring widget

## Description

Create the GPU widget for monitoring GPU usage and memory.

**Files to create:**
- `Tonic/Views/MenuBarWidgets/GPUWidgetView.swift`
- `Tonic/Views/MenuBarWidgets/GPUDetailView.swift`
- `Tonic/Services/GPUMonitor.swift` - GPU data source

**GPUMonitor requirements:**
- Use IOKit to query GPU stats
- Handle Apple Silicon (unified memory) vs Intel (discrete GPU)
- Gracefully return nil when unavailable

**Compact view:**
- Icon: "gpu" or "video.badge.plus"
- GPU usage percentage
- Only shows when GPU data available

**Detail view:**
- GPU usage with graph
- GPU memory usage (when available)
- Temperature (when supported)
- "Not available on this Mac" message when unsupported

**Note:** GPU monitoring requires platform-specific code. May need external library reference.

## Acceptance

- [ ] GPUMonitor service with IOKit integration
- [ ] Compact view hides when GPU unavailable
- [ ] Detail view shows usage, memory, temperature
- [ ] Graceful handling for unsupported GPUs
- [ ] Works on both Apple Silicon and Intel Macs where supported

## Done summary
Created GPU widget with Apple Silicon support. Shows GPU usage percentage and unified memory usage. Temperature display when supported. Auto-hides on Intel Macs when GPU unavailable. Graceful handling for unsupported GPUs with informative message.
## Evidence
- Commits:
- Tests:
- PRs: