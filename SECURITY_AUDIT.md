# Mole Security Audit

This document describes the security-relevant behavior of the current `main` branch, updated for V1.53.0 on 2026-08-30. It is intended as a public description of Mole's safety boundaries, destructive-operation controls, release integrity signals, and known limitations.

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
- uninstall removal flows that move items to Trash use `mole_delete`, which validates the path again and records the operation result. `mole_delete` now also validates symlinks instead of skipping them, and normalizes the target by collapsing repeated slashes and stripping a trailing slash before the protected-path check, so equivalent path spellings cannot slip past protection.
- incomplete download cleanup skips files currently open (lsof check) and uses quoted glob patterns to prevent word-splitting on filenames that contain spaces
- live user-cache protection refuses any reverse-DNS directory under `~/Library/Caches` whose owner is still running. Deleting an open SQLite cache can send the owning helper into a loop writing to unlinked files until the volume fills, observed with Autodesk Fusion's background helpers (issue #1390). The owner probe is tri-state and denies on both "running" and "could not tell": an unreadable process table is never read as idle. For SQLite cache families, the base database plus any `-wal` and `-shm` companions are covered by one bounded `lsof` probe over the whole family; cleanup proceeds only after every existing member is conclusively idle. Both of that probe's signals count as "in use", a record on stdout or a clean exit status, because with several names in one query neither alone is complete. A stale `-shm` file alone is not treated as liveness evidence, while a missing, timed-out, or failed `lsof` probe denies cleanup. The gate runs inside `validate_path_for_deletion()` and again at the `safe_remove()` sink, so a helper that launches after sizing still blocks deletion. The same protection covers the generic `~/Library/Caches/*` sweep, not only app-specific cleaners
- `mo clean` does not touch the LaunchServices database. A per-record removal is not implementable: `lsregister -u` resolves the path before unregistering, so on macOS 15 and later it returns `-10814` for exactly the records whose app is already gone. The only supported repair is a domain rescan, which is an explicit user-triggered task in `mo optimize` (`opt_launch_services_rebuild`), never an automatic step inside cleanup
- uninstall leftover removal is gated by a shared-bundle-id sibling guard: when another install of the same bundle id is still present, shared leftovers are kept and only the selected bundle is removed. Absence of a sibling must be proven, not assumed, so the scan reports three states and only a complete "no other install" result unlocks full leftover removal; a timeout, an unreadable volume, or an unreadable bundle degrades to the narrowed plan. The package-receipt half of that evidence is cached on disk keyed by a checksum of the installed receipt list rather than by time alone, because a TTL cannot prove completeness and a package installed after the last write would otherwise stay invisible to the guard
- orphaned system-service cleanup in `mo clean` (`lib/clean/apps.sh` `clean_orphaned_system_services`) runs only when sudo is already available, scans `/Library/{LaunchDaemons,LaunchAgents,PrivilegedHelperTools}` while skipping `com.apple.*`, and flags an entry only when its launchd `Program`/`ProgramArguments[0]` path is absolute and missing, or a `PrivilegedHelperTools` helper whose parent app is uninstalled (`bundle_has_installed_app`). Package-manager and system binary locations, a known-helper protect list, mdfind-resolved installed apps, the whitelist, and `should_protect_path` (with `SYSTEM_CRITICAL_BUNDLES` still enforced) all exclude entries before removal. Root-owned plists are read with non-interactive sudo and fail closed, so an unreadable plist is never misread as a missing binary. A standalone helper app under `/Library/PrivilegedHelperTools/*.app/Contents/MacOS/*` remains protected even while its updater temporarily removes the executable leaf. Before any direct helper file is deleted, Mole completely re-scans LaunchDaemons and LaunchAgents and keeps the helper if a surviving plist still references it or the reference scan is inconclusive. Removal routes through guarded `safe_sudo_remove`, does not alter launchd state, and honors dry-run (issues #1082 and #1447)

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
- OrbStack and similar local container/VM runtimes: live container and machine images under `~/Library/Group Containers/*dev.orbstack` and `~/.orbstack`, plus protected bundles `dev.orbstack.*` and `dev.kdrag0n.MacVirt`. Rebuildable caches such as `~/Library/Caches/dev.orbstack.OrbStack` remain cleanable.
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

The current design rationale is kept in this audit document so the safety model stays next to the implementation notes.

## Protected Directories and Categories

Mole has explicit protected-path and protected-category logic in addition to root-path blocking.

Protected or conservatively handled categories include:

- system components such as Control Center, System Settings, TCC, Spotlight, Finder, and Dock-related state
- keychains, password-manager data, tokens, credentials, and similar sensitive material
- VPN and proxy tools such as Shadowsocks, V2Ray, Clash, Tailscale, AmneziaWG, WireGuard, and NetworkExtension preferences
- AI tools in generic protected-data logic, including Cursor, Claude, ChatGPT, and Ollama
- Codex Desktop runtime state and active VM/runtime caches
- OrbStack and similar local container/VM runtimes, including live data under `~/Library/Group Containers/*dev.orbstack` and `~/.orbstack`, while rebuildable runtime caches stay eligible for cleanup
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
- an *ancestor* being a symlink is caught too, not just the leaf: the parent is canonicalized and the deny checks re-run on the resolved path, so a redirected `~/Library/Caches` cannot route a cache sweep into a protected tree. The re-check is deny-only, so a resolved path never grants permission the literal path lacked
- `mole_delete` validates symlinks rather than skipping them, so a symlink whose target resolves into a protected root is refused instead of silently moved
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
- Touch ID PAM configuration (`mo touchid`) uses `sudo install -m 444 -o root -g wheel` for atomic file writes, preventing temporary permission windows where PAM files could be user-writable (fixed in V1.39.0; prior versions used `sudo mv` which preserved temp-file ownership)
- the perl-based command timeout fallback creates a new process group with `setpgid(0, 0)` rather than calling `setsid()`, so the timed child keeps the controlling terminal. This lets nested sudo inside a Homebrew cask uninstall script reuse the already-cached credential instead of failing on a detached tty, while the group-kill cleanup semantics (`kill TERM -pid`) are unchanged.

When sudo is denied or unavailable, Mole prefers skipping privileged cleanup to forcing execution through unsafe fallback behavior.

## Sensitive Data Exclusions

Mole is not intended to aggressively delete high-value user data.

Examples of conservative handling include:

- sensitive app families are excluded from generic orphan cleanup
- orphaned app data waits for inactivity windows before cleanup
- Claude VM orphan cleanup uses a separate stricter rule
- uninstall file lists are decoded and revalidated before removal
- reverse-DNS bundle ID validation is required before LaunchAgent and LaunchDaemon pattern matching; bundle ID matching uses boundary-aware comparisons (`mole_name_starts_with_bundle_id_boundary`, `mole_name_has_bundle_id_boundary`) to prevent cross-app false matches (e.g. `com.example` not matching `com.example123`), and `defaults delete` is guarded by `mole_is_reverse_dns_bundle_id()` to reject malformed or adversarial domain strings
- LaunchAgents that only declare `MachServices` are unload-only and are not treated as safe deletion targets without a backing executable or bundle match
- `force_kill_app()` refuses to terminate a process whose resolved name matches a known system process, and this guard runs before the entire pgrep/AppleScript/pkill escalation ladder, so a third-party app cannot weaponize it by setting a system-like `CFBundleExecutable`
- receipt payload removal is gated by `receipt_payload_path_is_allowlisted()`, which requires a well-formed reverse-DNS bundle ID and only allows files whose basename is anchored to that bundle ID under `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, or `/private/var/db/receipts`
- apps managed by an official vendor uninstaller are excluded from Mole's own removal list, so the vendor's uninstall flow remains authoritative
- shared XDG roots (`~/.cache`, `~/.config`, and `~/.local`) are protected centrally and case-insensitively during uninstall. App-specific children can still be considered through exact ownership evidence, but Mole never removes a whole shared root merely because a GUI app has a matching name. This prevents collateral removal of unrelated CLI state (issue #993, for example a CLI sharing a name with `Claude.app` or `OpenCode.app`)
- batch uninstall now displays system-level remnants for review instead of deleting them; the confirmation prompt is retained and any `launchctl unload`/`bootout` runs under dry-run and `MOLE_TEST_MODE` guards

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
- `mo history` (`lib/core/history.sh`) is read-only: it reads `operations.log` and `deletions.log` to surface recent cleanup activity and performs no deletion or out-of-bounds writes
- timeouts bound external commands so stalled discovery or uninstall operations do not silently hang the entire flow

Relevant timeout behavior includes:

- orphan and Spotlight checks: 2s
- LaunchServices rebuild during uninstall: bounded 10s and 15s steps
- Homebrew uninstall cask flow: 300s by default, extended for large apps when needed
- project scans and sizing operations: bounded to avoid whole-home stalls

## Optimize and System Maintenance Safety

Optimize tasks are maintenance actions rather than bulk deletion, but they still touch user-visible state, so they are bounded conservatively:

- Optimize never restarts Dock or deletes any `*.db` under `~/Library/Application Support/Dock`. Earlier implementations reset the user's wallpaper or disrupted the desktop session; Dock repair is no longer an automatic maintenance task (#995, #1300).
- Spotlight orphan rule cleanup operates only in the user domain through `defaults`, runs under a dry-run guard, removes only entries whose app is confirmed no longer installed (`bundle_has_installed_app`), requires a well-formed reverse-DNS bundle ID, and never touches `System.*` or `com.apple.*` rules.
- Font Cache Rebuild (`atsutil databases -remove`) was removed because clearing the font cache could corrupt font rendering with no reliable benefit.

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
- install-time verification of the GitHub Actions build-provenance attestation: `install.sh` runs `gh attestation verify` scoped to the exact `tw93/Mole` repository (with `--deny-self-hosted-runners`) on the downloaded asset when the GitHub CLI is available, and a mismatch is treated as fatal before checksums are read. This moves attestation from a release-side artifact to an install-side check.

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
- `tests/uninstall_safety.bats`
- `tests/uninstall_naming_variants.bats`
- `tests/path_validation_fuzz.bats`
- `tests/history.bats`
- `tests/core_timeout.bats`
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
- Touch ID PAM file permission enforcement (`tests/cli.bats`)
- bundle ID boundary matching and malformed-ID rejection (`tests/uninstall_safety.bats`)
- official-uninstaller exclusion and receipt payload allowlisting (`tests/uninstall_safety.bats`)
- uninstall behavior across localized and naming-variant app names (`tests/uninstall_naming_variants.bats`)
- property-style path validation fuzzing over the corpus in `tests/fuzz_corpus/` (`tests/path_validation_fuzz.bats`)
- read-only history rendering from operation logs (`tests/history.bats`)
- command timeout behavior including process-group cleanup (`tests/core_timeout.bats`)
- bash 3.2 empty-array nounset compatibility (`tests/uninstall_scan_bash32.bats`)
- live user-cache refusal while an owner process runs, an unreadable process table denying rather than allowing, and SQLite family members held by an open handle while an idle stale `-shm` companion remains cleanable (`tests/core_safe_functions.bats`, `tests/clean_core.bats`)
- system-service family protection during helper-app update gaps and before direct helper deletion (`tests/clean_apps.bats`)
- sibling-install evidence completeness: a newly installed package receipt invalidates the cached answer the shared-bundle-id guard reads as proof of absence (`tests/uninstall_scan_bash32.bats`)

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
- `mo history --json` escapes strings byte by byte under `LC_ALL=C` (`history_json_escape`) for portable behavior on bash 3.2. Printable multibyte bytes are emitted verbatim, so the emitted JSON stays valid UTF-8, but the escaper does not perform Unicode-aware codepoint iteration. This is a known display-layer detail, not a correctness issue.
- Planned follow-up work includes stronger destructive-command threat modeling, more regression coverage for high-risk paths, and continued hardening of release integrity and disclosure workflow.

For reporting procedures and supported versions, see [SECURITY.md](SECURITY.md).
