# CLAUDE.md - AI Assistant Guide for Mole

This document provides comprehensive guidance for AI assistants (like Claude) working on the Mole codebase.

## Project Overview

**Mole** is a macOS maintenance and cleanup utility that helps users reclaim disk space and optimize system performance. The name comes from the concept of "digging deep like a mole" to find and clean hidden system cruft.

**Current Version:** 1.9.15
**License:** MIT
**Author:** tw93
**Language Requirements:** Bash 3.2+, Go 1.24.0+
**Target Platform:** macOS (both Intel x86_64 and Apple Silicon arm64)

### Core Features

1. **Deep System Cleanup** (`bin/clean.sh`) - Removes caches, logs, temp files from 100+ locations
2. **Smart App Uninstaller** (`bin/uninstall.sh`) - Removes apps and scans 22+ locations for leftovers
3. **System Optimization** (`bin/optimize.sh`) - Rebuilds caches, resets services, optimizes performance
4. **Interactive Disk Analyzer** (`cmd/analyze/`) - TUI for exploring and cleaning large files

## Architecture

### Hybrid Design

Mole uses a **hybrid shell + Go architecture**:

- **Shell Scripts (Bash):** Core functionality, UI, and orchestration (~7,247 lines)
- **Go Application:** High-performance disk analyzer with concurrent scanning

### Directory Structure

```
mub/
├── mole                        # Main entry point (621 lines)
├── mo                          # Lightweight alias wrapper
├── bin/                        # Core functionality modules
│   ├── clean.sh               # System cleanup (1,496 lines)
│   ├── uninstall.sh           # App uninstaller (874 lines)
│   ├── optimize.sh            # System optimization (335 lines)
│   ├── analyze.sh             # Analyzer wrapper (52 lines)
│   ├── analyze-go             # Go binary (universal macOS binary)
│   └── touchid.sh             # Touch ID configuration (97 lines)
├── lib/                        # Shared libraries
│   ├── common.sh              # Common utilities (550 lines)
│   ├── menu_paginated.sh      # Paginated menus (265 lines)
│   ├── menu_simple.sh         # Simple menus (111 lines)
│   ├── whitelist_manager.sh   # Cache protection (200 lines)
│   └── ui_app_selector.sh     # App selection UI (320 lines)
├── cmd/analyze/               # Go analyzer source
│   ├── main.go                # TUI application (Bubble Tea)
│   ├── scanner.go             # Concurrent directory scanning
│   ├── cache.go               # Persistent caching
│   ├── delete.go              # Safe file deletion
│   ├── format.go              # Display formatting
│   └── constants.go           # Configuration
├── scripts/                    # Build and utility scripts
│   ├── check.sh               # Run all quality checks
│   ├── format.sh              # Code formatting
│   └── setup-quick-launchers.sh # Raycast/Alfred integration
├── tests/                      # BATS unit tests
│   └── run.sh                 # Test runner
└── install.sh                 # Installation script (439 lines)
```

## Development Guidelines

### Code Standards

#### Shell Scripts

**Requirements:**
- **Bash 3.2+ compatible** (macOS ships with Bash 3.2, don't use modern features)
- **BSD commands, not GNU** (e.g., `sed -i ''` not `sed -i`)
- **4-space indentation** (configured in `.editorconfig`)
- **Strict mode:** Always use `set -euo pipefail` at the top of scripts
- **Quote all variables:** Always use `"${var}"` not `$var`

**Conventions:**
- Use `readonly` for constants
- Prefix functions with their purpose (e.g., `safe_clean`, `check_macos`)
- Use descriptive variable names in snake_case
- Add comments for complex logic
- Use `|| true` to ignore expected errors

**Example:**
```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

safe_clean() {
    local path="${1}"
    local description="${2}"

    if [[ -d "${path}" ]]; then
        rm -rf "${path}" || true
        echo "✓ Cleaned ${description}"
    fi
}
```

#### Go Code

**Requirements:**
- **Go 1.24.0+**
- Use `gofmt` for formatting
- Follow standard Go conventions
- Handle errors explicitly
- Use context for cancellation

**Key Dependencies:**
- `github.com/charmbracelet/bubbletea` - TUI framework
- `github.com/cespare/xxhash/v2` - Fast hashing for cache
- `golang.org/x/sync` - Concurrency primitives

### Quality Checks

**Before committing, always run:**
```bash
./scripts/check.sh
```

This runs:
1. **Code formatting check** (shfmt)
2. **ShellCheck linting** (shellcheck)
3. **Unit tests** (BATS)

**Individual commands:**
```bash
./scripts/format.sh    # Format code
./tests/run.sh         # Run tests only
```

**Configuration:**
- `.editorconfig` - Code style
- `.shellcheckrc` - ShellCheck rules (some warnings disabled)

## Safety Considerations

**CRITICAL:** Mole modifies system files and can delete user data. Safety is paramount.

### Safety Mechanisms

1. **Path Validation:**
   ```bash
   # Always validate paths before deletion
   if [[ ! "${path}" =~ ^/Users/.*/(Library|.Trash)/ ]]; then
       echo "ERROR: Invalid path"
       return 1
   fi
   ```

2. **Whitelist Protection:**
   - Critical apps are protected: `1Password`, `Claude`, `ClashX`, system apps
   - Users can add apps to whitelist via `mo clean --whitelist`
   - Check `lib/whitelist_manager.sh` for whitelist logic

3. **Dry-Run Mode:**
   - Always support `--dry-run` flag for preview
   - Never actually delete in dry-run mode
   - Show what would be deleted

4. **Size Limits:**
   - Skip files/directories over 100GB (might be important)
   - Warn before deleting very large items

5. **User Confirmation:**
   - Require sudo for dangerous operations
   - Show summary before proceeding
   - Support Touch ID for better UX

### Protected Locations

**Never clean these:**
- `/Applications/*.app` (except when explicitly uninstalling)
- `/System/`
- `/Library/` (system, not user)
- User home directory root
- Active browser profiles
- Apps in whitelist

**Example from `bin/clean.sh:1262`:**
```bash
case "${app_name}" in
    com.apple.* | Adobe* | 1Password | Claude | *ClashX* | *clash* | mihomo* | *Surge*)
        # Protected apps - skip cleaning
        ;;
esac
```

## Key Patterns and Conventions

### 1. Error Handling

```bash
# Good: Explicit error handling
if ! some_command; then
    echo "ERROR: Command failed"
    return 1
fi

# Good: Ignore expected errors
rm -rf "${temp_dir}" 2>/dev/null || true

# Bad: No error handling
some_command
```

### 2. UI/UX Patterns

**Colors and Icons:**
- Use functions from `lib/common.sh`: `success()`, `error()`, `info()`
- Icons: ✓ (success), ✗ (error), ⚠ (warning), ⟳ (loading)

**Progress Indicators:**
- Spinners for long operations (see `spinner_start` in `lib/common.sh`)
- Size indicators: `format_size()` for human-readable sizes
- Progress bars for multi-step operations

**Interactive Menus:**
- Use `lib/menu_paginated.sh` for lists with many items
- Arrow key navigation (↑↓ to move, Enter to select)
- Support for multi-select with checkboxes (☑/☐)

### 3. Sudo Management

```bash
# Keep sudo alive during long operations
keep_sudo_alive() {
    while true; do
        sudo -n true
        sleep 50
        kill -0 "$$" 2>/dev/null || exit
    done 2>/dev/null &
}
```

### 4. Version Checking

**Update mechanism:**
- Check GitHub API for latest version
- Cache check results for 24 hours
- Show update notification in main menu
- Provide `mo update` command

**Implementation:** See `mole:60-120` for update checking logic

### 5. Concurrent Operations (Go Analyzer)

**Worker Pool Pattern:**
```go
// cmd/analyze/scanner.go uses worker pools
- Configurable number of workers (default: runtime.NumCPU())
- Channel-based communication
- Context for cancellation
- Aggregate results from all workers
```

**Caching:**
- Use xxhash for fast directory fingerprinting
- Store cache in `~/.cache/mole-analyzer/`
- Invalidate cache if directory modified time changes

## File-by-File Guide

### Core Entry Points

**`mole` (621 lines)**
- Main entry point and router
- Parses CLI arguments
- Shows interactive menu if no args
- Handles version checking and updates
- Manages sudo elevation

**`mo` (lightweight wrapper)**
- Sets `MO_ENTRY=mo` environment variable
- Calls `mole` with same arguments
- Provides shorter command name

### Module Deep-Dive

**`bin/clean.sh` (1,496 lines) - System Cleanup**

Key sections:
- Lines 1-100: Setup, constants, help text
- Lines 100-200: Whitelist checking logic
- Lines 200-600: User cache cleaning (~/Library/Caches)
- Lines 600-800: Browser data (Chrome, Safari, Firefox)
- Lines 800-1000: Developer tools (Xcode, Node.js, npm, pods)
- Lines 1000-1200: App-specific caches (Spotify, Slack, Docker)
- Lines 1200-1400: System logs and temp files
- Lines 1400-1496: Main orchestration and summary

**Notable locations cleaned:**
- `~/Library/Caches/*` - User app caches
- `~/Library/Logs/*` - Application logs
- `/Library/Logs/*` - System logs (sudo required)
- `~/.Trash/` - User trash
- `~/Downloads/` - Old downloads (optional)
- Browser caches: Chrome, Safari, Firefox, Edge
- Developer: `~/Library/Developer/Xcode/DerivedData`, `node_modules`, `.npm`

**`bin/uninstall.sh` (874 lines) - App Uninstaller**

**Scan locations (22+):**
1. `/Applications/*.app`
2. `~/Applications/*.app`
3. `~/Library/Application Support/[AppName]`
4. `~/Library/Caches/[AppName]`
5. `~/Library/Preferences/[AppIdentifier].plist`
6. `~/Library/Logs/[AppName]`
7. `~/Library/Saved Application State/[AppIdentifier]*`
8. `~/Library/WebKit/[AppIdentifier]`
9. `~/Library/Cookies/[AppIdentifier].binarycookies`
10. `~/Library/LaunchAgents/[AppIdentifier]*`
11. `~/Library/Application Scripts/[AppIdentifier]`
12. `/Library/LaunchDaemons/[AppIdentifier]*` (sudo)
13. `/Library/LaunchAgents/[AppIdentifier]*` (sudo)
14. `/Library/Application Support/[AppName]`
15. `/Library/PrivilegedHelperTools/[AppIdentifier]*`
16. And more...

**Process:**
1. Scan `/Applications` and `~/Applications`
2. Show interactive multi-select menu
3. For each selected app:
   - Find app identifier (CFBundleIdentifier)
   - Search all 22+ locations for related files
   - Show preview of what will be deleted
   - Delete app and all related files
   - Report total space freed

**`bin/optimize.sh` (335 lines) - System Optimization**

**Operations performed:**
1. System health check (RAM, disk, uptime)
2. Rebuild launch services database
3. Flush DNS cache
4. Reset network services
5. Rebuild Spotlight index
6. Purge memory and swap files
7. Restart Dock and Finder
8. Clear crash reports
9. Rebuild dyld shared cache

**Warning:** Some operations require reboot to fully take effect.

**`cmd/analyze/main.go` - Disk Analyzer TUI**

**Architecture:**
- Built with Bubble Tea (Elm architecture for Go)
- Model-View-Update pattern
- Keyboard-driven navigation

**Features:**
- Navigate directories with arrow keys
- Sort by size, name, or age
- Filter by age (>6mo, >1yr)
- Delete files/folders with progress tracking
- Open in Finder
- Persistent caching for fast re-scans

**Key bindings:**
- `↑↓` - Navigate items
- `←` - Go up one level
- `→` or `Enter` - Enter directory
- `O` - Open in Finder
- `F` - Reveal in Finder
- `⌫` or `Delete` - Delete item
- `L` - Toggle large files only (>24MB)
- `Q` - Quit

### Libraries

**`lib/common.sh` (550 lines)**

Essential utilities used throughout:
- `success()`, `error()`, `info()`, `warn()` - Colored output
- `format_size()` - Convert bytes to human-readable (e.g., "1.5GB")
- `get_macos_version()` - Detect macOS version
- `check_macos()` - Verify running on macOS
- `spinner_start()`, `spinner_stop()` - Loading indicators
- Path validation functions
- Sudo keepalive logic

**`lib/menu_paginated.sh` (265 lines)**

Implements paginated arrow-key navigation:
- Supports 100s of items
- Pagination (show 10-20 items per page)
- Arrow keys (↑↓) for navigation
- Enter to select
- Visual indicators (▶ for current item)

**`lib/menu_simple.sh` (111 lines)**

Simple numbered menus:
- User types number to select
- No pagination
- Good for < 10 items

**`lib/whitelist_manager.sh` (200 lines)**

Manages cache whitelist:
- Add apps to whitelist: `mo clean --whitelist`
- Stores whitelist in `~/.config/mole/cache_whitelist.txt`
- Interactive add/remove UI
- Validates app names

**`lib/ui_app_selector.sh` (320 lines)**

Multi-select app picker:
- Checkboxes (☑/☐)
- Arrow key navigation
- Space to toggle selection
- Shows app size and last modified
- Used by uninstaller

## Testing

### Unit Tests (BATS)

**Location:** `tests/*.bats`

**Run tests:**
```bash
./tests/run.sh
```

**Test structure:**
```bash
@test "function_name should do something" {
    result=$(function_name "arg")
    [ "$result" = "expected" ]
}
```

**Coverage:**
- Path validation functions
- Size formatting
- Menu navigation logic
- Whitelist management
- Cleanup safety checks

**Note:** Some tests require macOS-specific commands, so they may not run on Linux.

### Manual Testing Checklist

Before releasing:

1. **Clean:**
   - [ ] Run `mo clean --dry-run` - verify no critical paths
   - [ ] Run `mo clean` - verify space freed
   - [ ] Check whitelist protection works

2. **Uninstall:**
   - [ ] Install a test app
   - [ ] Run `mo uninstall`
   - [ ] Verify all leftovers removed

3. **Optimize:**
   - [ ] Run `mo optimize`
   - [ ] Verify no errors
   - [ ] Check system still stable

4. **Analyze:**
   - [ ] Run `mo analyze`
   - [ ] Navigate directories
   - [ ] Test deletion
   - [ ] Verify cache persistence

5. **Cross-platform:**
   - [ ] Test on Intel Mac
   - [ ] Test on Apple Silicon Mac
   - [ ] Test on macOS 12, 13, 14+

## Common Tasks

### Adding a New Cleanup Target

1. **Edit `bin/clean.sh`**
2. Add cleanup function following existing patterns:
   ```bash
   clean_new_target() {
       local target_path="${HOME}/Library/NewTarget"

       # Check if whitelisted
       if is_whitelisted "NewTarget"; then
           info "Skipping NewTarget (whitelisted)"
           return 0
       fi

       # Calculate size
       local size
       size=$(du -sk "${target_path}" 2>/dev/null | awk '{print $1}') || size=0

       # Dry run check
       if [[ "${DRY_RUN}" == "true" ]]; then
           echo "Would clean NewTarget: $(format_size $((size * 1024)))"
           return 0
       fi

       # Actually clean
       safe_clean "${target_path}/*" "NewTarget cache"

       # Update stats
       TOTAL_FREED=$((TOTAL_FREED + size))
   }
   ```

3. Call function in main cleanup sequence
4. Add tests in `tests/clean.bats`
5. Update README.md if significant

### Adding a New Command

1. **Create script** in `bin/new-command.sh`
2. Follow existing patterns (use `lib/common.sh`)
3. **Update `mole`** to route to new command:
   ```bash
   case "${command}" in
       # ... existing commands ...
       new-command)
           "${BIN_DIR}/new-command.sh" "$@"
           ;;
   esac
   ```
4. Add help text
5. Add tests
6. Update README.md

### Updating the Go Analyzer

1. **Edit source** in `cmd/analyze/*.go`
2. **Build universal binary:**
   ```bash
   cd cmd/analyze
   GOOS=darwin GOARCH=arm64 go build -o ../../bin/analyze-go-arm64
   GOOS=darwin GOARCH=amd64 go build -o ../../bin/analyze-go-amd64
   lipo -create -output ../../bin/analyze-go \
       ../../bin/analyze-go-arm64 \
       ../../bin/analyze-go-amd64
   ```
3. **Test** on both architectures if possible
4. **Commit** the updated binary

### Updating Homebrew Formula

1. **Create GitHub release** with new tag
2. **Update formula** at `https://github.com/tw93/homebrew-tap/blob/main/Formula/mole.rb`
3. Update version and SHA256
4. Test: `brew upgrade mole`

**CI automatically updates formula** on new releases via `.github/workflows/homebrew.yml`

## Debugging Tips

### Shell Scripts

**Enable debug mode:**
```bash
bash -x mole clean
```

**Add debug prints:**
```bash
[[ "${DEBUG:-}" == "true" ]] && echo "DEBUG: variable=${variable}"
```

**Common issues:**
- Quote all variables: `"${var}"` not `$var`
- Check for BSD vs GNU commands: `sed -i ''` on macOS
- Bash 3.2 doesn't have associative arrays
- Use `|| true` for commands that may fail

### Go Analyzer

**Run with debug output:**
```bash
DEBUG=1 ./bin/analyze-go ~/Documents
```

**Profile performance:**
```bash
go run -cpuprofile=cpu.prof cmd/analyze/main.go ~/Documents
go tool pprof cpu.prof
```

**Common issues:**
- Permissions: analyzer needs read access to scan
- Symlinks: follow them or exclude them?
- Concurrent access: handle files being modified during scan
- Memory: limit number of cached entries

## Important Notes

### Claude Desktop Integration

Mole recognizes Claude Desktop as an application:

**In `bin/clean.sh:1151-1152`:**
```bash
safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Claude desktop cache"
safe_clean ~/Library/Logs/Claude/* "Claude logs"
```

**In `bin/clean.sh:1262` (whitelist):**
```bash
com.apple.* | Adobe* | 1Password | Claude | *ClashX* | *clash* | mihomo* | *Surge*)
    # Protected apps - skip cleaning
```

**Why:** Claude Desktop is recognized as a critical app and protected from aggressive cleaning, similar to password managers and system utilities.

### macOS Compatibility

**Target:** macOS 10.15+ (Catalina and later)

**Considerations:**
- System Integrity Protection (SIP): Can't modify `/System/`
- Gatekeeper: Unsigned binaries require user approval
- Bash 3.2: Ancient version, avoid modern features
- BSD tools: Different flags than GNU versions

**Version detection:**
```bash
macos_version=$(sw_vers -productVersion)
major_version=$(echo "${macos_version}" | cut -d. -f1)
```

### Performance Optimization

**Shell:**
- Minimize subshells (use `$(...)` sparingly)
- Batch file operations when possible
- Use `find` with `-exec` for bulk operations
- Cache expensive operations (e.g., `du` results)

**Go Analyzer:**
- Worker pool sized to CPU count
- Concurrent directory scanning
- Persistent caching with xxhash
- Limit cache size to prevent memory issues

## Security Considerations

1. **Input Validation:**
   - Always validate paths before deletion
   - Prevent directory traversal attacks
   - Sanitize user input for app names

2. **Privilege Escalation:**
   - Only use `sudo` when absolutely necessary
   - Drop privileges as soon as possible
   - Never run entire script as root

3. **Data Loss Prevention:**
   - Dry-run mode for preview
   - Size limits to prevent accidental deletion
   - Whitelist for critical apps
   - Clear warnings before destructive operations

4. **Code Injection:**
   - Never use `eval` with user input
   - Quote all variables in shell
   - Use `--` to separate options from arguments

## Contribution Workflow

1. **Fork** the repository
2. **Create branch:** `git checkout -b feature/my-feature`
3. **Make changes** following code standards
4. **Run checks:** `./scripts/check.sh`
5. **Commit:** Clear, descriptive messages
6. **Push** and open Pull Request
7. **CI** will verify formatting, linting, and tests

**PR guidelines:**
- Keep PRs focused (one feature/fix per PR)
- Include tests for new functionality
- Update README.md if user-facing changes
- Follow existing code style
- Be responsive to review feedback

## Resources

- **Repository:** https://github.com/tw93/mole
- **Issues:** https://github.com/tw93/mole/issues
- **Releases:** https://github.com/tw93/mole/releases
- **Homebrew Tap:** https://github.com/tw93/homebrew-tap

---

**Last Updated:** 2025-11-19
**For Claude Version:** Claude Sonnet 4.5
**Mole Version:** 1.9.15
