# fn-3.12 Fix WidgetPreferences thread safety with @MainActor

## Description

`WidgetPreferences` uses `@unchecked Sendable` without proper synchronization, creating potential thread safety issues.

**File:** `Tonic/Models/WidgetConfiguration.swift` (line 171)

**Current:**
```swift
@Observable
public final class WidgetPreferences: @unchecked Sendable {
```

**Solution:** Mark as `@MainActor` to ensure all access happens on main thread.

## Acceptance

- [x] Add `@MainActor` annotation to `WidgetPreferences`
- [x] Remove `@unchecked Sendable` (replace with proper Sendable via @MainActor)
- [x] Verify all accesses are on main thread
- [x] Test preferences changes from background thread are safe

## Done summary
Marked WidgetPreferences as @MainActor for proper thread safety. Removed @unchecked Sendable and ensured all access is synchronized via main actor. Class now conforms to Sendable safely through @MainActor annotation.
## Evidence
- Commits:
- Tests:
- PRs: