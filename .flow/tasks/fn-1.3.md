# fn-1.3 Port system status dashboard to Swift

## Description
Port the system status dashboard from Go to SwiftUI. This displays real-time system health metrics (CPU, RAM, disk, network).

**Key Actions:**
1. Study `cmd/status/main.go` and `cmd/status/view.go:1-792`
2. Create Swift metrics collectors (using IOKit, sysctl)
3. Implement real-time updates (Timer or Combine)
4. Build card-based UI matching existing design
5. Add SF Symbols for each metric type
6. Create menu bar mini-view
7. Implement proper metric formatting (percentages, bytes)

**Reuse from codebase:**
- `cmd/status/view.go` - Card layout → SwiftUI LazyVGrid
- `lib/check/health_json.sh` - Health data structure → Swift models

**Performance targets:**
- Metrics update within 1 second of actual value
- Memory usage <50MB for dashboard
- Smooth animations for value changes

**References:**
- `cmd/status/view.go:1-792` - Existing card-based UI
- IOKit documentation: https://developer.apple.com/documentation/iokit
## Acceptance
- [ ] CPU usage displays accurately
- [ ] Memory usage displays accurately (used/total)
- [ ] Disk space displays for all volumes
- [ ] Network activity shows (in/out)
- [ ] Metrics update in real-time (<1s latency)
- [ ] Menu bar mini-view implemented
- [ ] Card-based UI matches existing design language
- [ ] Dashboard uses <50MB RAM
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
