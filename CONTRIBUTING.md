# Contributing to Mole

## Setup

```bash
# Install development tools
brew install shfmt shellcheck bats-core golangci-lint
```

## Development

Run quality checks before committing (auto-formats code):

```bash
./scripts/check.sh
```

Run tests:

```bash
./scripts/test.sh
```

## Code Style

### Basic Rules

- Bash 3.2+ compatible (macOS default)
- 4 spaces indent
- Use `set -euo pipefail` in all scripts
- Quote all variables: `"$variable"`
- Use `[[ ]]` not `[ ]` for tests
- Use `local` for function variables, `readonly` for constants
- Function names: `snake_case`
- BSD commands not GNU (e.g., `stat -f%z` not `stat --format`)

Config: `.editorconfig` and `.shellcheckrc`

### File Operations

**Always use safe wrappers, never `rm -rf` directly:**

```bash
# Single file/directory
safe_remove "/path/to/file"

# Purge files older than 7 days
safe_find_delete "$dir" "*.log" 7 "f"

# With sudo
safe_sudo_remove "/Library/Caches/com.example"
```

See `lib/core/file_ops.sh` for all safe functions.

### Pipefail Safety

All commands that might fail must be handled:

```bash
# Correct: handle failure
find /nonexistent -name "*.cache" 2>/dev/null || true

# Correct: check array before use
if [[ ${#array[@]} -gt 0 ]]; then
    for item in "${array[@]}"; do
        process "$item"
    done
fi

# Correct: arithmetic operations
((count++)) || true
```

### Error Handling

```bash
# Network requests with timeout
result=$(curl -fsSL --connect-timeout 2 --max-time 3 "$url" 2>/dev/null || echo "")

# Command existence check
if ! command -v brew >/dev/null 2>&1; then
    log_warning "Homebrew not installed"
    return 0
fi
```

### UI and Logging

```bash
# Logging
log_info "Starting cleanup"
log_success "Cache cleaned"
log_warning "Some files skipped"
log_error "Operation failed"

# Spinners
with_spinner "Cleaning cache" rm -rf "$cache_dir"

# Or inline
start_inline_spinner "Processing..."
# ... work ...
stop_inline_spinner "Complete"
```

### Debug Mode

Enable debug output with `--debug`:

```bash
mo --debug clean
./bin/clean.sh --debug
```

Modules check the internal `MO_DEBUG` variable:

```bash
if [[ "${MO_DEBUG:-0}" == "1" ]]; then
    echo "[MODULE] Debug message" >&2
fi
```

Format: `[MODULE_NAME] message` output to stderr.

## Requirements

- macOS 10.14 or newer, works on Intel and Apple Silicon
- Default macOS Bash 3.2+ plus administrator privileges for cleanup tasks
- Install Command Line Tools with `xcode-select --install` for curl, tar, and related utilities
- Go 1.24+ is required to build the `mo status` or `mo analyze` TUI binaries locally.

## Go Components

`mo status` and `mo analyze` use Go with Bubble Tea for interactive dashboards.

**Code organization:**

- Each module split into focused files by responsibility
- `cmd/analyze/` - Disk analyzer with 7 files under 500 lines each
- `cmd/status/` - System monitor with metrics split into 11 domain files

**Development workflow:**

- Format code with `gofmt -w ./cmd/...`
- Run `go vet ./cmd/...` to check for issues
- Build with `go build ./...` to verify all packages compile

**Building Go Binaries:**

For local development:

```bash
# Build binaries for current architecture
make build

# Or run directly without building
go run ./cmd/analyze
go run ./cmd/status
```

For releases, GitHub Actions builds architecture-specific binaries automatically.

**Guidelines:**

- Keep files focused on single responsibility
- Extract constants instead of magic numbers
- Use context for timeout control on external commands
- Add comments explaining **why** something is done, not just **what** is being done.

## Pull Requests

> **Important:** Please submit PRs to the `dev` branch, not `main`. We merge `dev` into `main` after testing.

1. Fork and create branch from `dev`
2. Make changes
3. Run checks: `./scripts/check.sh`
4. Commit and push
5. Open PR targeting `dev`

CI will verify formatting, linting, and tests.
