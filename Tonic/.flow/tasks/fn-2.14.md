# fn-2.14 Implement widget onboarding tour experience

## Description
Create `WidgetOnboardingView.swift` - a first-run tour experience that introduces users to the menu bar widget system with a 4-page guided walkthrough.

**File created:** `Tonic/Views/WidgetOnboardingView.swift`

**Key features:**
- 4-page onboarding tour with TabView
- Pages: Menu Bar Widgets, Real-Time Monitoring, Fully Customizable, Smart Notifications
- Gradient icons for visual appeal
- Page indicators with dots
- Back/Next navigation with Get Started button
- Integrates with WidgetPreferences to mark completion and start coordinator

## Acceptance

- [x] WidgetOnboardingView created with 4 pages
- [x] TabView with page indicators
- [x] Navigation buttons (Back/Next/Get Started)
- [x] Each page has icon, title, and description
- [x] Marks onboarding complete in preferences
- [x] Starts WidgetCoordinator on completion
- [x] Follows Tonic design system with accent/pro gradients

## Done Summary
Created 4-page onboarding tour experience with TabView, page indicators, and Back/Next navigation. Each page features large gradient icons with title and description. Completion updates WidgetPreferences and starts WidgetCoordinator.

## Evidence
- Commits:
- Tests:
- PRs:
