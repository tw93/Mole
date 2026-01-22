# fn-2.13 Create WidgetHistoryStore for graph persistence

## Description
Create `WidgetHistoryStore.swift` to store graph history data for widgets with 1-week persistence. The store maintains 60 data points each for CPU, memory, and network history.

**File created:** `Tonic/Services/WidgetHistoryStore.swift`

**Key features:**
- 60-point rolling history arrays for CPU, memory, network upload, network download
- 1-week persistence duration via UserDefaults
- Automatic cleanup of old history
- Thread-safe operations with @MainActor

## Acceptance

- [x] WidgetHistoryStore class created with @Observable
- [x] 60 data point limit for each history type
- [x] 1-week persistence with automatic cleanup
- [x] UserDefaults persistence with proper keys
- [x] Public API: addCPUValue, addMemoryValue, addNetworkUploadValue, addNetworkDownloadValue
- [x] saveHistory() and clearHistory() methods

## Done Summary
Created WidgetHistoryStore.swift with 60-point history arrays for CPU, memory, and network data. History persists for 1 week via UserDefaults with automatic cleanup of old data. Store uses @MainActor @Observable pattern for thread-safe access.

## Evidence
- Commits:
- Tests:
- PRs:
