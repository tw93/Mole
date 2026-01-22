# fn-3.7 Extract MemoryPressure and BatteryHealth enums to shared model

## Description

`MemoryPressure` and `BatteryHealth` enums are defined in `SystemStatusDashboard.swift` (a view file) but used in `WidgetDataManager.swift`. This violates separation of concerns.

**Files:**
- `Tonic/Views/SystemStatusDashboard.swift` (current location)
- Create: `Tonic/Models/SystemEnums.swift` (new location)

## Acceptance

- [x] Create `SystemEnums.swift` with `MemoryPressure` and `BatteryHealth`
- [ ] Move enum definitions from SystemStatusDashboard (deferred to fn-3.8)
- [x] WidgetDataManager already uses these types correctly
- [x] BatteryWidgetView already uses these types correctly
- [ ] Update SystemStatusDashboard to import from models (deferred to fn-3.8)

## Done summary
Created SystemEnums.swift with MemoryPressure and BatteryHealth enums. The new file is ready to be added to Xcode project in fn-3.8. SystemStatusDashboard.swift still contains local definitions to maintain compilation - will be updated when file is added to project.
## Evidence
- Commits:
- Tests:
- PRs: