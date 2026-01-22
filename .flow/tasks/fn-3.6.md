# fn-3.6 Fix NotificationRuleEngine timer leak

## Description

The `setupObserver()` method creates a Timer but doesn't store it, causing:
1. Timer to be deallocated immediately
2. Multiple timers on repeated calls
3. No way to stop evaluation

**File:** `Tonic/Services/NotificationRuleEngine.swift` (lines 306-314)

**Solution:** Store timer reference and provide cancellation method.

## Acceptance

- [x] Add `private var evaluationTimer: Timer?` property
- [x] Store timer reference when created
- [x] Add `stopObserver()` method to invalidate timer
- [x] Call `setupObserver()` from `NotificationRuleEngine.start()`
- [x] Ensure only one timer exists at a time

## Done summary
Fixed NotificationRuleEngine timer leak by adding evaluationTimer property. The timer reference is now stored when created in setupObserver(). Added stopObserver() method to invalidate timer. start() now calls setupObserver() and stop() calls stopObserver().
## Evidence
- Commits:
- Tests:
- PRs: