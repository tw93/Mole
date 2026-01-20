# fn-1.4 Implement app inventory feature

## Description
Implement app inventory feature to scan and display installed applications with metadata (size, version, last used).

**Key Actions:**
1. Study `bin/uninstall.sh` app scanning logic
2. Create Swift app scanner for `/Applications`
3. Extract app metadata (Info.plist parsing)
4. Calculate app bundle sizes
5. Detect last-used time via LSQuarantine or file access time
6. Identify orphaned app data (read-only detection)
7. Implement safety checks using PROTECTED_APPS
8. Build SwiftUI list view with app icons

**Reuse from codebase:**
- `bin/uninstall.sh:72-186` - App selection logic
- `lib/core/app_protection.sh` - Protected apps list
- `lib/core/common.sh` - `find_app_files()` function
- `lib/ui/app_selector.sh` - TUI selection patterns

**Safety:**
- Never delete protected apps (system apps)
- Show warnings before any destructive action
- Allow users to add custom whitelist

**References:**
- `bin/uninstall.sh:1-587` - Full uninstall flow
- `lib/core/app_protection.sh` - PROTECTED_APPS list
## Acceptance
- [ ] App inventory scans `/Applications` in <5 seconds
- [ ] App icons display correctly
- [ ] App metadata extracted (name, version, size, last-used)
- [ ] Orphaned app data detected and displayed
- [ ] Protected apps cannot be selected for deletion
- [ ] Custom whitelist can be added by user
- [ ] Scan results cached for performance
- [ ] App search/filter implemented
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
