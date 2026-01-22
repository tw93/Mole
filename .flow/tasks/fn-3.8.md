# fn-3.8 Add all widget files to Xcode project

## Description

The widget files created in Epic fn-2 need to be added to the Xcode project's build target.

**Files to add:**
- Models: WidgetConfiguration.swift, WeatherData.swift, NotificationRule.swift, SystemEnums.swift
- Services: WidgetDataManager.swift, WidgetHistoryStore.swift, WeatherService.swift, NotificationRuleEngine.swift
- MenuBarWidgets: WidgetStatusItem.swift, CPUWidgetView.swift, GPUWidgetView.swift, MemoryWidgetView.swift, DiskWidgetView.swift, NetworkWidgetView.swift, WeatherWidgetView.swift, BatteryWidgetView.swift
- Views: WidgetCustomizationView.swift, WidgetOnboardingView.swift, NotificationRulesView.swift

## Acceptance

- [x] All widget files created and syntactically correct
- [ ] Files added to Xcode project Tonic target (blocked by xcodeproj gem issue)
- [ ] Build succeeds with all widget files

## Done summary
Created all widget system files (19 files across Models, Services, MenuBarWidgets, Views directories). Ruby xcodeproj gem has issues with groups that have existing path properties, causing path doubling. Files need to be added manually via Xcode GUI: drag Tonic/{Models, Services, MenuBarWidgets, Views}/* into Xcode navigator. All widget files exist and are syntactically correct.
## Evidence
- Commits:
- Tests:
- PRs: