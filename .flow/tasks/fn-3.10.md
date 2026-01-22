# fn-3.10 Implement automatic history saving in WidgetHistoryStore

## Description

The `saveHistory()` method exists but is never called, so history data is lost when the app quits.

**File:** `Tonic/Services/WidgetHistoryStore.swift`

**Current:** History only stored in memory arrays.

**Required:** Automatic saving on:
- App background/termination
- Periodic intervals (every 5 minutes)
- After significant data updates

## Acceptance

- [x] Subscribe to app lifecycle notifications (`NSApplication.willTerminate`)
- [x] Add periodic timer for auto-save (every 5 minutes)
- [x] Call `saveHistory()` on app background
- [x] Verify history persists across app restarts
- [x] Test history data survives app quit

## Done summary
Implemented automatic history saving on app termination, app resign active, and every 5 minutes via timer. Added NSNotificationCenter observers for lifecycle events. History data now persists across app restarts.
## Evidence
- Commits:
- Tests:
- PRs: