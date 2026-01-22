# fn-3.2 Start WidgetCoordinator on app launch

## Description

The `WidgetCoordinator` is only started when onboarding completes. If onboarding is already done (or skipped), the widgets never start.

**File:** `Tonic/TonicApp.swift` or `Tonic/AppDelegate.swift`

**Current:** Only `WidgetOnboardingView.completeOnboarding()` calls `WidgetCoordinator.shared.start()`

**Required:** Add to app lifecycle so widgets always start.

## Acceptance

- [x] Call `WidgetCoordinator.shared.start()` in `AppDelegate.applicationDidFinishLaunching()`
- [x] Check if onboarding completed before starting
- [ ] Verify widgets appear in menu bar on app launch (requires fn-3.8)
- [x] Handle case where user hasn't completed onboarding

## Done summary
Added WidgetCoordinator.shared.start() to AppDelegate.applicationDidFinishLaunching() with onboarding check. Uses runtime class lookup to compile before widget files are added to Xcode project. Will start widgets automatically once fn-3.8 completes.
## Evidence
- Commits:
- Tests:
- PRs: