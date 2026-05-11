# Mole Security Audit

This document describes the security-relevant behavior of the current `main` branch, updated for V1.38.1 on 2026-05-11. It is intended as a public description of Mole's safety boundaries, destructive-operation controls, release integrity signals, and known limitations.

## Executive Summary

Mole is a local system maintenance tool. Its main risk surface is not remote code execution; it is unintended local damage caused by cleanup, uninstall, optimize, purge, installer cleanup, or other destructive operations.

The project is designed around safety-first defaults:

- destructive paths are validated before deletion
- critical system roots and sensitive user-data categories are protected
- sudo use is bounded and additional restrictions apply when elevated deletion is required
- symlink handling is conservative
- preview, confirmation, timeout, and operation logging are used to make destructive behavior more visible and auditable

Mole prioritizes bounded cleanup over aggressive cleanup. When uncertainty exists, the tool should refuse, skip, or require stronger confirmation instead of widening deletion scope.

The project continues to strengthen:

- release integrity and public security signals
- targeted regression coverage for high-risk paths
- clearer documentation for privilege boundaries and known limitations

## Threat Surface

The highest-risk areas in Mole are:

- direct file and directory deletion
- recursive cleanup across common user and system cache locations
- uninstall flows that combine app removal with remnant cleanup
- project artifact purge for large dependency/build directories
- elevated cleanup paths that require sudo
- release, install, and update trust signals for distributed artifacts

`mo analyze` is intentionally lower-risk than cleanup flows:

- it does not require sudo
- it respects normal user permissions and SIP
- delete actions require explicit confirmation
- deletion routes through Finder Trash behavior rather than direct permanent removal

## Destructive Operation Boundaries

All destructive shell file operations are routed through guarded helpers in `lib/core/file_ops.sh`.

Core controls include:

- `validate_path_for_deletion()` rejects empty paths
- relative paths are rejected
- path traversal segments such as `..` as a path component are rejected
- paths containing control characters are rejected
- raw `find ... -delete` is avoided for security-sensitive cleanup logic
- removal flows use guarded helpers such as `safe_remove()`, `safe_sudo_remove()`, `safe_find_delete()`, and `safe_sudo_find_delete()`
- uninstall removal flows that move items to Trash use `mole_delete`, which validates the path again and records the operation result
- incomplete download cleanup skips files currently open (lsof check) and uses quoted glob patterns to prevent word-splitting on filenames that contain spaces

Blocked paths remain protected even with sudo. Examples include:

```text
/
/System
/bin
/sbin
/usr
/etc
/var
/private
/Library/Extensions
```

Some subpaths under otherwise protected roots are explicitly allowlisted for bounded cleanup where the project intentionally supports cache/log maintenance. Examples include:

- `/private/tmp`
- `/private/var/tmp`
- `/private/var/log`
- `/private/var/folders`
- `/private/var/db/diagnostics`
- `/private/var/db/DiagnosticPipeline`
- `/private/var/db/powerlog`
- `/private/var/db/reportmemoryexception`

This design keeps cleanup scoped to known-safe maintenance targets instead of broad root-level deletion patterns.

## Path Protection Reference

### Protected Prefixes (Never Deleted)

```text
/
/System
/bin
/sbin
/usr
/etc
/var
/private
/Library/Extensions
```

### Whitelist Exceptions (Allowlisted for Cleanup)

Some subpaths under protected roots are explicitly allowlisted:

- `/private/tmp`
- `/private/var/tmp`
- `/private/var/log`
- `/private/var/folders`
- `/private/var/db/diagnostics`
- `/private/var/db/DiagnosticPipeline`
- `/private/var/db/powerlog`
- `/private/var/db/reportmemoryexception`

### Protected Categories

In addition to path blocking, these categories are protected:

- Keychains, password managers, credentials
- VPN/proxy tools (Shadowsocks, V2Ray, Clash, Tailscale, AmneziaWG, WireGuard, NetworkExtension preferences)
- AI tools (Cursor, Claude, ChatGPT, Ollama)
- Codex Desktop runtime state and active VM/runtime caches
- Browser history and cookies
- Apple-owned app group containers, including `group.com.apple.notes`
- Time Machine data (during active backup)
- `com.apple.*` LaunchAgents/LaunchDaemons
- user-owned `~/Library/LaunchAgents/*.plist` automation/configuration
- iCloud-synced `Mobile Documents`

## Implementation Details

All deletion routes pass through `lib/core/file_ops.sh`:

- `validate_path_for_deletion()` - Empty, relative, traversal checks
- `should_protect_path()` - Prefix and pattern matching
- `safe_remove()`, `safe_find_delete()`, `safe_sudo_remove()` - Guarded operations

See [`journal/2026-03-11-safe-remove-design.md`](journal/2026-03-11-safe-remove-design.md) for design rationale.

## Protected Directories and Categories

Mole has explicit protected-path and protected-category logic in addition to root-path blocking.

Protected or conservatively handled categories include:

- system components such as Control Center, System Settings, TCC, Spotlight, Finder, and Dock-related state
- keychains, password-manager data, tokens, credentials, and similar sensitive material
- VPN and proxy tools such as Shadowsocks, V2Ray, Clash, Tailscale, AmneziaWG, WireGuard, and NetworkExtension preferences
- AI tools in generic protected-data logic, including Cursor, Claude, ChatGPT, and Ollama
- Codex Desktop runtime state and active VM/runtime caches
- `~/Library/Messages/Attachments`
- Apple Notes and other Apple-owned app group containers, including `~/Library/Group Containers/group.com.apple.notes`
- browser history and cookies
- Time Machine data while backup state is active or ambiguous
- `com.apple.*` LaunchAgents and LaunchDaemons
- user-owned `~/Library/LaunchAgents/*.plist` automation/configuration
- iCloud-synced `Mobile Documents` data

Project purge also uses conservative heuristics:

- purge targets must be inside configured project boundaries
- direct-child artifact cleanup is only allowed in single-project mode
- recently modified artifacts are treated as recent for 7 days
- nested artifacts are filtered to avoid parent-child over-deletion
- protected vendor/build-output heuristics block ambiguous directories

Developer cleanup also preserves high-value state. Examples intentionally left alone include:

- `~/.cargo/bin`
- `~/.rustup`
- `~/.mix/archives`
- `~/.stack/programs`

## Symlink and Path Traversal Handling

Symlink behavior is intentionally conservative.

- path validation checks symlink targets before deletion
- symlinks pointing at protected system targets are rejected
- `safe_sudo_remove()` refuses to sudo-delete symlinks
- `safe_find_delete()` and `safe_sudo_find_delete()` refuse to scan symlinked base directories
- installer discovery avoids treating symlinked installer files as deletion candidates
- analyzer scanning skips following symlinks to unexpected targets

Path traversal handling is also explicit:

- non-absolute paths are rejected for destructive helpers
- `..` is rejected when it appears as a path component
- legitimate names containing `..` inside a single path element remain allowed to avoid false positives for real application data
- `mo analyze` delete validates the raw user-supplied path before `filepath.Abs` resolves it, then validates the resolved absolute path a second time, closing a window where traversal segments could survive `Abs` normalization

## Privilege Escalation and Sudo Boundaries

Mole uses sudo for a subset of system-maintenance paths, but elevated behavior is still bounded by validation and protected-path rules.

Key properties:

- sudo access is explicitly requested instead of assumed
- non-interactive preview remains conservative when sudo is unavailable
- protected roots remain blocked even when sudo is available
- sudo deletion uses the same path validation gate as non-sudo deletion
- sudo cleanup skips or reports denied operations instead of widening scope
- sudo-required uninstall paths are routed to the invoking user's Trash where possible instead of root-owned Trash or direct deletion
- sudo Trash routing refuses unsafe Trash locations, including symlinked Trash directories
- authentication, SIP/MDM, and read-only filesystem failures are classified separately in file-operation results
- sudo credential prompting passes through the system's native PAM prompt rather than a hardcoded string, ensuring correct behavior across locales and PAM configurations

When sudo is denied or unavailable, Mole prefers skipping privileged cleanup to forcing execution through unsafe fallback behavior.

## Sensitive Data Exclusions

Mole is not intended to aggressively delete high-value user data.

Examples of conservative handling include:

- sensitive app families are excluded from generic orphan cleanup
- orphaned app data waits for inactivity windows before cleanup
- Claude VM orphan cleanup uses a separate stricter rule
- uninstall file lists are decoded and revalidated before removal
- reverse-DNS bundle ID validation is required before LaunchAgent and LaunchDaemon pattern matching
- LaunchAgents that only declare `MachServices` are unload-only and are not treated as safe deletion targets without a backing executable or bundle match

Installed-app detection is broader than a single `/Applications` scan and includes:

- `/Applications`
- `/System/Applications`
- `~/Applications`
- Homebrew Caskroom locations
- Setapp application paths

This reduces the risk of incorrectly classifying active software as orphaned data.

## Dry-Run, Confirmation, and Audit Logging

Mole exposes multiple safety controls before and during destructive actions:

- `--dry-run` previews are available for major destructive commands
- dry-run output deduplicates targets by filesystem identity (device+inode), so aliased paths and symlinks do not appear as separate items
- interactive high-risk flows require explicit confirmation before deletion
- purge marks recent projects conservatively and leaves them unselected by default
- purge configuration is written atomically (mktemp then rename) to prevent partial writes if the process is interrupted
- analyzer delete uses Finder Trash rather than direct permanent removal
- operation logs are written to `~/Library/Logs/mole/operations.log` unless disabled with `MO_NO_OPLOG=1`
- `mole_delete` Trash and permanent deletion attempts are also recorded by the file-operation layer with result status, target path, and error context where available
- timeouts bound external commands so stalled discovery or uninstall operations do not silently hang the entire flow

Relevant timeout behavior includes:

- orphan and Spotlight checks: 2s
- LaunchServices rebuild during uninstall: bounded 10s and 15s steps
- Homebrew uninstall cask flow: 300s by default, extended for large apps when needed
- project scans and sizing operations: bounded to avoid whole-home stalls

## Release Integrity and Continuous Security Signals

Mole treats release trust as part of its security posture, not just a packaging detail.

Repository-level signals include:

- weekly Dependabot updates for Go modules and GitHub Actions
- pre-commit hook that mirrors GitHub CI checks locally (shell syntax, shfmt, shellcheck, Go vet)
- CI checks for unsafe `rm -rf` usage patterns and core protection behavior
- targeted tests for path validation, purge boundaries, symlink behavior, dry-run flows, and destructive helpers
- macOS 14 and macOS 15 compatibility coverage for core Bats suites
- CodeQL scanning for Go and GitHub Actions workflows, with workflow permission hardening
- curated changelog-driven release notes for user-visible changes
- published SHA-256 checksums for release assets
- GitHub artifact attestations for release assets

These controls do not eliminate all supply-chain risk, but they make release changes easier to review and verify.

## Testing Coverage

There is no single `tests/security.bats` file. Instead, security-relevant behavior is covered by focused suites, including:

- `tests/core_safe_functions.bats`
- `tests/clean_core.bats`
- `tests/clean_user_core.bats`
- `tests/clean_dev_caches.bats`
- `tests/clean_system_maintenance.bats`
- `tests/clean_apps.bats`
- `tests/file_ops_mole_delete.bats`
- `tests/purge.bats`
- `tests/installer.bats`
- `tests/optimize.bats`
- `cmd/analyze/*_test.go`

Key coverage areas include:

- path validation rejects empty, relative, traversal, and system paths
- symlinked directories are rejected for destructive scans
- purge protects shallow or ambiguous paths and filters nested artifacts
- dry-run flows preview actions without applying them and do not emit duplicate targets
- confirmation flows exist for high-risk interactive operations
- LaunchAgent unload-only handling, Homebrew Cask paths, and sudo-required Trash routing
- Apple Notes group containers and other Apple-owned group containers remain protected
- sudo credential prompting and session management (`tests/manage_sudo.bats`)
- purge config path discovery and write behavior (`tests/purge_config_paths.bats`)
- hint and cleanup-hint flows (`tests/clean_hints.bats`)

## Known Limitations and Future Work

- Cleanup is destructive. Most cleanup flows do not provide undo.
- `mo analyze` delete is safer because it uses Trash, but other cleanup flows are permanent once confirmed.
- `mo uninstall` now routes more removals through Trash, but Trash availability, permissions, and volume behavior still depend on the local macOS environment.
- Generic orphan data waits 30 days before cleanup; this is conservative but heuristic.
- Claude VM orphan cleanup waits 7 days before cleanup; this is also heuristic.
- Time Machine safety windows are hour-based and intentionally conservative.
- Localized app names may still be missed in some heuristic paths, though bundle IDs are preferred where available.
- Users who want immediate removal of app data should use explicit uninstall flows rather than waiting for orphan cleanup.
- Release artifacts include checksums and attestations, but downstream package-manager trust also depends on external distribution infrastructure.
- Planned follow-up work includes stronger destructive-command threat modeling, more regression coverage for high-risk paths, and continued hardening of release integrity and disclosure workflow.

For reporting procedures and supported versions, see [SECURITY.md](SECURITY.md).
