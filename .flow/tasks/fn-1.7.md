# fn-1.7 Port deep clean module to Swift

## Description
Port the deep clean module from Bash to Swift with privileged helper integration. This handles system cache, app data, and development tool cleanup.

**Key Actions:**
1. Study all `lib/clean/` modules
2. Create Swift cleanup orchestrator
3. Implement cache scanning via helper tool
4. Add preview mode (dry-run) before actual deletion
5. Create cleanup progress UI
6. Implement safety checks (whitelist patterns)
7. Add undo/restore capability if possible
8. Calculate space savings before/after

**Reuse from codebase:**
- `lib/clean/apps.sh` - Application data cleanup
- `lib/clean/app_caches.sh` - Browser caches
- `lib/clean/dev.sh` - Development tool caches (npm, pip, cargo)
- `lib/clean/system.sh` - System log cleanup
- `lib/clean/user.sh` - User data cleanup
- `lib/clean/brew.sh` - Homebrew cache management
- `lib/core/common.sh` - `should_protect_path()` safety checks

**Safety:**
- Always show preview before delete
- Honor DEFAULT_WHITELIST_PATTERNS
- Never delete sensitive data
- Allow user to review each category

**References:**
- `lib/clean/` - All cleanup modules
- `lib/core/common.sh` - Safety functions like `should_protect_path()`
## Acceptance
- [ ] All `lib/clean/` modules ported to Swift
- [ ] Preview mode shows what will be deleted
- [ ] Space savings calculated and displayed
- [ ] Whitelist patterns honored (DEFAULT_WHITELIST_PATTERNS)
- [ ] Browser cache cleanup works
- [ ] Development cache cleanup works (npm, pip, cargo)
- [ ] System cache cleanup works via helper
- [ ] Progress UI updates during cleanup
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
