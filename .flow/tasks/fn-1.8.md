# fn-1.8 Port app uninstaller to SwiftUI

## Description
Port the app uninstaller from Bash to SwiftUI with helper tool integration. This removes apps completely including related files.

**Key Actions:**
1. Study `bin/uninstall.sh:1-587` and `lib/uninstall/batch.sh:169-641`
2. Create SwiftUI app selection UI (drag-and-drop support)
3. Implement related files detection via helper
4. Add Homebrew cask integration
5. Implement LaunchServices cleanup
6. Create uninstall confirmation UI
7. Add undo capability (move to Trash first)
8. Handle running apps (quit before uninstall)

**Reuse from codebase:**
- `bin/uninstall.sh:1-587` - Complete uninstall flow
- `lib/uninstall/batch.sh:169-641` - `batch_uninstall_applications()`
- `lib/uninstall/brew.sh` - Homebrew integration
- `lib/core/common.sh` - `find_app_system_files()`

**Safety:**
- Check if app is running before uninstall
- Never delete protected apps
- Show all related files before confirmation
- Move to Trash first (don't immediately delete)

**References:**
- `bin/uninstall.sh:1-587` - Full uninstall logic
- `lib/core/app_protection.sh` - Protected apps list
## Acceptance
- [ ] Apps can be selected for uninstall (multi-select)
- [ ] Related files detected and displayed
- [ ] Running apps detected and quit before uninstall
- [ ] Homebrew apps uninstalled via `brew uninstall --cask`
- [ ] LaunchServices rebuilt after uninstall
- [ ] Protected apps cannot be uninstalled
- [ ] Confirmation UI shows all files to be deleted
- [ ] Apps moved to Trash (allow undo)
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
