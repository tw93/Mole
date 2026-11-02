# Mole Security Audit

This document describes Mole CLI (macOS), updated for V1.68.0 on 2026-11-02, with the 2026-10-26 review starting from `ec968fc8` on `main` (the code is unchanged from `00f8279e`). It covers safety boundaries, destructive-operation controls, release integrity signals, and known limitations. This is a maintainer review, not an independent security certification. Mole Mac and Mole for Windows are outside its scope.

## 2026-11-01 Yarn Berry dependency boundary

`e59e7d60` removes automatic cleanup of the global Berry archive store and protects it at shared clean sinks, including custom-whitelist runs and direct store-root/descendant attempts. Classic cache cleanup and explicit uninstall keep their existing policies. The producer and real-sink regressions fail on the prior source; the full no-authorization check and test scripts pass, and an independent review found no production defect. The defect was present in V1.67.0, and the repair ships in V1.68.0.

## Review Scope and Evidence

The review covers the complete CLI, rather than only changes since V1.64.0. Concurrent work was initially excluded, then the committed Slim/whitelist, mounted-volume overview and fixture changes (`0f9c0df4`, `4f9abf8b`, `c8fe24f1`) received an incremental review and integration run. The subsequent `502b3483` changes only the contributors image. The following matrix identifies the reviewed boundaries and their regression suites; listing a suite does not claim that it passed in this review.

| Surface | Boundary under review | Regression evidence |
| --- | --- | --- |
| Core filesystem and privilege helpers | Path protection, physical identity, whitelist, cancellation, timeout classification, sudo and Trash staging | `tests/core_safe_functions.bats`, `tests/file_ops_mole_delete.bats`, `tests/manage_sudo.bats` |
| Automatic cleanup and developer caches | Disposable content, live/unknown owners, SQLite families, logs, external volumes and owner commands | `tests/clean_app_caches.bats`, `tests/clean_developer_state.bats`, `tests/clean_user_core.bats`, `tests/clean_dev_caches.bats` |
| Uninstall | Exact ownership, sibling installs, metadata rechecks, user-data selection, process handling and final removal | `tests/uninstall_safety.bats`, `tests/uninstall_remove_file_list.bats`, `tests/uninstall_timeout.bats`, `tests/uninstall_process_pattern.bats` |
| Purge and installer cleanup | Project boundaries, Git ownership, recent/live projects, incomplete scans and confirmation | `tests/purge.bats`, `tests/installer.bats`, `tests/installer_fd.bats` |
| Optimize | Bounded maintenance, database recovery, scoped service actions, unknown results and cancellation | `tests/optimize_db.bats`, `tests/optimize_catalog.bats`, `tests/optimize_removal_outcomes.bats` |
| Slim | Candidate ownership, signed resource seals, verified copies, running apps and replacement | `tests/slim.bats` |
| Analyze | Asynchronous selection identity, confirmation, protected paths and the independent native Trash implementation | `cmd/analyze/*_test.go` |
| Status and history | Read-only collection, partial/unknown data, output encoding and operation records | `cmd/status/*_test.go`, `tests/history.bats` |
| Install, update and remove | Bootstrap trust, checksum/provenance verification, install locks and owned-file removal | `tests/install_checksum.bats`, `tests/update.bats`, `tests/uninstall.bats` |
| Router, completion and Touch ID | Privileged entry rejection, argument handling, confirmation, shell-file ownership and PAM permissions | `tests/cli.bats`, `tests/completion.bats`, `tests/manage_sudo.bats` |
| Tests, workflows and guidance | Enforced versus advisory gates, shipped inventory, release trust and current safety claims | `scripts/check.sh`, `scripts/test.sh`, `.github/workflows/`, `AGENTS.md`, `.claude/rules/` |

### Findings Repaired in This Review

Source repairs: `541690b5` for Analyze and `16f5c5d7` for developer cleanup.

| Finding | Impact and repair | Regression evidence |
| --- | --- | --- |
| Hidden Analyze actions while deletion is active | Medium: hidden navigation/confirmation could dispatch another deletion without its prompt being visible. Busy mode now accepts quit and the existing safe refresh action only. | Old input cases failed; `lifecycle_test.go` pins selection, confirmation, dispatch and quit behavior. Refresh/delete lifecycle tests remain green. |
| Moving a parent bypassed protected runtime leaves | Medium: moving Library/Containers or Group Containers could include protected Docker/OrbStack state. Existing state roots now protect their ancestors and aliases; Darwin user/cache structural roots protect EDR descendants. Empty containers and unrelated cache leaves remain eligible. | Six parent/alias assertions, five Darwin structural assertions and a linked-runtime physical-parent case failed before the fix. An initial overbroad empty-container refusal was reproduced and narrowed before delivery. |
| Owner-cache commands followed a protected physical root | Medium: a configured symlink could bypass a physical whitelist entry before the tool cleaned it. Configured and physical roots now receive path/whitelist checks, including absent leaves and every Conda package root. | Four production owner-producer fixtures with mocked mutations and Conda multi-root coverage reject linked/protected roots while allowing ordinary roots and unprotected aliases. Signals propagate. |
| Jupyter runtime was treated as disposable cache | Medium: the Python producer nominated [active connection metadata](https://docs.jupyter.org/en/latest/use/jupyter-directories.html#runtime-files). It no longer emits this target, and the shared clean boundary protects its root and children. Explicit uninstall keeps its separate policy. | Producer and final-sink fixtures fail on old source, pass after repair, and preserve the ordinary Python cache positive control. |

The underlying file operations remain path-based. These changes reduce demonstrated authorization gaps; they do not create an atomic lease against concurrent hostile replacement. No command, flag, setting or new output mode was added. User-visible changes are refusal of the unsafe targets and ignored hidden busy-state actions.

### Residual Closure Follow-up

The follow-up freezes `main` at `32b70a91` and `windows` at `d1ab34a2`, rechecks every limitation below and repairs two further macOS defects in `bc3d642a` (history JSON) and `79e255a8` (owner interruption). The Windows review owns its Store-manifest and lint-gate fixes. This is an incremental closure of the complete review, not a new release or certification.

| Finding | Repair and visible change | Regression evidence |
| --- | --- | --- |
| Invalid UTF-8 made history output invalid JSON | `history_json_escape` preserves valid scalar sequences and replaces each malformed byte with U+FFFD in JSON only. Raw logs, text mode and action paths remain unchanged. No new flag or output field. | Both the byte-level helper and the real history router failed on old source. Tests cover every nonzero byte, canonical scalar boundaries, overlong/surrogate/out-of-range/truncated encodings, deterministic mixed-byte inputs, valid multilingual text and unchanged log bytes. |
| Physical cache-root lookup swallowed interruption | `owner_cache_root_is_safe` preserves the failing subshell status instead of collapsing it to an ordinary refusal. An interrupted lookup now cancels later cleanup; an ordinary lookup failure still skips only that cache. | The real `clean_uv_cache` caller failed on old source. Executable fixture owners and probes cover interrupted, failed and successful `cd`/`pwd` paths without invoking a real cache command. |

Follow-up verification is recorded in [the audit log](docs/weekly-audit.md#2026-10-26-residual-closure). The original verification and its test-isolation correction below remain historical evidence, not a claim that every earlier test was mocked.

### Verification Receipt

The original isolated source plus this review's fixes passed the complete `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh`, exit 0 with the runner's `All tests passed!` summary. Final integration on `c8fe24f1` plus the owned patch: passed with exit 0 and the runner's `All tests passed!` summary; the final linked-runtime Go follow-up was then checked with the full Go/race/build/lint gates. Formatting, `check.sh --no-format`, `make build`, full Go tests and Analyze race tests passed. An existing asynchronous-cache test cleanup race surfaced during validation; its test now waits for the completed cache publication instead of tearing down its temporary HOME while the writer is active. The focused race test passed 100 repetitions.

The launcher matrix used eight isolated fixtures: Steam, Epic, GOG, Battle.net, Parallels, UTM, Ollama and LM Studio. Only exact cache leaves were classified as automatic leftovers; application-support/container data stayed personal and default-kept, and shared Steam/Epic roots were excluded. Fixture identifiers are explicit inputs, not evidence of real installed-app or custom-library acceptance. Cross-CLI review found Windows already has the corresponding busy and protected-descendant boundaries, no Jupyter runtime cleanup target, and a separate guarded owner-root policy; its batch identity repair is recorded in that branch's security review.

Test-isolation correction: the first two Jupyter red runs used shell-function owner mocks that the external timeout process did not inherit, so real `pip3 cache purge` and `uv cache prune` commands ran. HOME was a disposable fixture; subsequent read-only queries in the same layout resolved both default cache roots inside it. The original owner output and effective roots were not retained, so external-cache impact cannot be ruled out or quantified from that run. The fixture now mocks the timeout dispatch itself, and subsequent targeted and complete runs use that corrected isolation. No real application uninstall, privileged cleanup, new release or package acceptance was performed.

GitHub CI must be read at the final pushed revision, separately from these local receipts. Published V1.64.0 does not contain this review's repairs.

### Changes Since the Recorded CLI Review Baseline

Compared with the `70eed1b0` baseline recorded in [the audit log](docs/weekly-audit.md), the source now includes:

- `797a484c`: exact UUID-container metadata and NativeMessaging manifest ownership, with identity/content checks at the removal boundary. JetBrains selectors remain bound to the reviewed app metadata. The new cases are in `tests/uninstall_safety.bats` and `tests/uninstall_remove_file_list.bats`.
- `52c5a7fa` and `9c33da94`: named application caches recheck their owner at the final sink without refreshing away the original path identity. Purge requires stronger node-project evidence and checks activity again before removal. Neighboring idle, live, unknown and replacement cases are covered in `tests/clean_app_caches.bats` and `tests/purge.bats`.
- `530cc2b7`: Slim preserves files hashed by an enclosing resource seal and excludes originals Gatekeeper explicitly rejects. `0f9c0df4` also checks whitelist protection during discovery and again before replacement. Signature acceptance still does not prove compatibility with an application's own integrity checks.

These are specific improvements to ownership and deletion authorization. A lower finding count or a passing test suite alone would not establish that every cleanup target is safe. The remaining boundaries are listed below, and the repair evidence is recorded above.

## Executive Summary

Mole is a local system maintenance tool. Its main risk surface is not remote code execution; it is unintended local damage caused by cleanup, uninstall, optimize, purge, installer cleanup, or other destructive operations.

The project is designed around safety-first defaults:

- destructive paths are validated before deletion
- critical system roots and sensitive user-data categories are protected
- sudo use is bounded and additional restrictions apply when elevated deletion is required
- symlink handling is conservative
- preview, confirmation, timeout, and operation logging are used to make destructive behavior more visible and auditable

Mole prioritizes safety over aggressive deletion. When in doubt, the tool skips, refuses, or requires explicit confirmation rather than widening deletion scope.

Key areas of ongoing security focus:

- Release integrity and public verification signals
- Targeted regression coverage for high-risk paths
- Clear documentation of privilege boundaries and known limitations

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
- deletion routes to Trash rather than direct permanent removal, through the native `trash` utility, a no-overwrite filesystem move, or Finder as the final fallback

## Destructive Operation Boundaries

Cleanup and app-data removal use guarded helpers in `lib/core/file_ops.sh`. Installation and self-removal also perform narrowly scoped file operations.

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
- `mo clean` does not touch the LaunchServices database. A per-record removal is not implementable: `lsregister -u` resolves the path before unregistering, so on macOS 15 and later it returns `-10814` for exactly the records whose app is already gone. No command offers a domain rescan either: `mo optimize` no longer re-registers LaunchServices because the rebuild made a running Network Extension VPN read as reinstalled, and uninstall only unregisters the removed bundle with `lsregister -u` and compacts with `lsregister -gc`, never a domain-wide rebuild. A catalog test refuses any `lsregister -r` call in `lib` and `bin` (`tests/optimize_catalog.bats`)
- uninstall leftover removal is gated by a shared-bundle-id sibling guard: when another install that shares the bundle id is still present, shared leftovers are kept and only the selected bundle is removed. The guard also treats an independent bundle whose id continues the selected one after a dot, in either direction, and a channel-stripped same-name product such as a Nightly build beside the stable app, as the same family. Ownership is checked again at the leftover boundary after the app move: a replacement at the original app path, a surviving family member or an incomplete inventory keeps the whole family, the refusal carries through defaults, ByHost and helper bootout, and the summary names the cause once instead of listing every path as protected. Absence of a sibling must be proven, not assumed, so the scan reports three states and only a complete "no other install" result unlocks full leftover removal; a timeout, an unreadable volume, or an unreadable bundle degrades to the narrowed plan. The one volume left out is a network share whose mount point reports that it no longer exists, such as a stopped virtual machine's drive, because nothing on it can be a live install; a slow or reconnecting share still counts as unknown. The package-receipt half of that evidence is cached on disk keyed by a checksum of the installed receipt list rather than by time alone, because a TTL cannot prove completeness and a package installed after the last write would otherwise stay invisible to the guard
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
- `/private/var/db/powerlog`, except the live `Current*` database of every `PerfPowerTelemetry` store and its `-wal` / `-shm` files
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
- `/private/var/db/powerlog`, except the live `Current*` database of every `PerfPowerTelemetry` store and its `-wal` / `-shm` files
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

Shell file-removal helpers are centralized in `lib/core/file_ops.sh`:

- `validate_path_for_deletion()` - Empty, relative, traversal checks
- `should_protect_path()` - Prefix and pattern matching
- `safe_remove()`, `safe_find_delete()`, `safe_sudo_remove()` - Guarded operations

Owner-managed cleanup commands in `lib/clean/dev.sh`, maintenance actions, and the Go Analyze implementation have separate execution paths. They require their own scope, preview, timeout and result checks; the presence of a guard in `file_ops.sh` does not prove those paths are protected.

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
- user log and standalone diagnostic-report sweeps refuse symlinked roots or ancestors below HOME, preserve the DiagnosticReports directory, and recheck root identities after sizing and at the deletion sink

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
- Optimize's NotificationCenter and DNS refresh signals target fixed launchd services, never every process with a matching name. DNS accepts only the two known labels from its SIP-protected system plist; failed discovery or signalling never falls back to a PID or process-name kill. NotificationCenter is scoped to the current user's GUI domain, DNS to the system domain with the existing privilege gate.
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
- analyzer delete uses its native utility, filesystem move or Finder Trash path rather than direct permanent removal
- operation logs are written to `~/Library/Logs/mole/operations.log` unless disabled with `MO_NO_OPLOG=1`
- `mole_delete` Trash and permanent deletion attempts are also recorded by the file-operation layer with result status, target path, and error context where available
- `mo history` (`lib/core/history.sh`) is read-only: it reads `operations.log` and `deletions.log` to surface recent cleanup activity and performs no deletion or out-of-bounds writes
- operation-log records and deletion-log fields escape control bytes as `\n`, `\r`, `\t` or `\xHH` before append, including batched records, so filenames cannot forge history entries; backslashes stay literal so `mo history` shows names as they are on disk, and its text output escapes the raw control bytes that older logs may still hold
- timeouts bound external commands so stalled discovery or uninstall operations do not silently hang the entire flow. Direct Trash moves, privileged staging moves, permission/ownership handoff and final user moves each use the disk-operation deadline; a timed-out stage retains its payload, stops later candidates and preserves completed-path accounting. This is a per-command bound, not a whole-uninstall deadline or real-machine acceptance claim
- Purge preserves interruption statuses through content probes, parallel discovery, review, and deletion; a read timeout remains unknown and keeps the target
- project-cache cleanup rechecks tracked files and nested repositories after sizing and at the final deletion boundary; the discovery Git index alone never authorizes deletion

Relevant timeout behavior includes:

- orphan app lookups through Spotlight (`mdfind`): 5s
- plist and binary probes, and installed-app resolution by bundle ID: 2s
- LaunchServices steps during uninstall: `lsregister -u` 5s and `lsregister -gc` 10s
- Homebrew uninstall cask flow: 300s by default, extended for large apps when needed
- project scans and sizing operations: bounded to avoid whole-home stalls

## Optimize and System Maintenance Safety

Optimize tasks are maintenance actions rather than bulk deletion, but they still touch user-visible state, so they are bounded conservatively:

- Optimize never restarts Dock or deletes any `*.db` under `~/Library/Application Support/Dock`. Earlier implementations reset the user's wallpaper or disrupted the desktop session; Dock repair is no longer an automatic maintenance task (#995, #1300).
- Spotlight orphan rule cleanup operates only in the user domain through `defaults`, runs under a dry-run guard, removes only entries whose app is confirmed no longer installed (`bundle_has_installed_app`), requires a well-formed reverse-DNS bundle ID, and never touches `System.*` or `com.apple.*` rules. It parses a complete typed snapshot before app resolution and verifies that snapshot again before writing; malformed, partial, or changed data is retained.
- Font Cache Rebuild (`atsutil databases -remove`) was removed because clearing the font cache could corrupt font rendering with no reliable benefit.

## Slim and Signed Application Contents

`mo slim` is the explicit exception to the rule against modifying third-party app bundles. It removes Intel slices from eligible universal apps on Apple Silicon, without sudo. Candidates are limited to supported application roots and one ordinary directory below them, must be owned by the invoking user with owned contents and a writable parent, and must carry a Developer ID signature. System, App Store, unsigned, ad-hoc, Rosetta-preferred and protected apps are excluded. A running app is retained when processing begins and checked again before replacement.

The command modifies a staging copy. It preserves resource files and any executable an enclosing signature seals by a plain content hash, verifies the remaining Apple Silicon slices, performs deep strict signature verification, checks the Team ID, and requires Gatekeeper acceptance of the copy. It does not re-sign the bundle. The narrowly accepted FinderInfo/ResourceFork repair applies only to the copy and must pass verification before thinning proceeds.

Only a verified copy may replace the original, which is moved to Trash through the identity-bound `mole_delete` path. INT and TERM are deferred across that move and the final rename. If the rename fails, the original remains in Trash and the command reports that state; this is not an atomic swap or an automatic rollback. Signature and Gatekeeper checks cannot establish compatibility with every vendor's runtime integrity checks. App updates can restore the removed slices. `tests/slim.bats` covers the controlled replacement and refusal paths; real-app compatibility is a separate acceptance surface.

## Release Integrity and Continuous Security Signals

Mole treats release trust as part of its security posture, not just a packaging detail.

Repository-level signals include:

- weekly Dependabot updates for Go modules and GitHub Actions
- pre-commit hook that mirrors GitHub CI checks locally (shell syntax, shfmt, shellcheck, Go vet)
- CI checks for unsafe `rm -rf` usage patterns and core protection behavior
- targeted tests for path validation, purge boundaries, symlink behavior, dry-run flows, and destructive helpers
- the full Bats suite on macOS 26 in parallel and serial shards, the core Bats subset on macOS 15 for compatibility, and the security and protection checks on Linux
- Nix package build plus profile install, upgrade, and removal checks on Apple Silicon and Intel macOS 15 runners
- CodeQL scanning for Go and GitHub Actions workflows, with workflow permission hardening
- curated changelog-driven release notes for user-visible changes
- published SHA-256 checksums for release assets
- GitHub artifact attestations for release assets
- install-time verification of the GitHub Actions build-provenance attestation: when the GitHub CLI is installed and authenticated, `install.sh` verifies the downloaded `SHA256SUMS` file with `gh attestation verify`, scoped to `tw93/Mole` and `--deny-self-hosted-runners`. Each binary is then checked against that file. A failed attestation or checksum aborts instead of falling back to a source build. If `gh` is absent or unauthenticated, the default is checksum-only verification; `MOLE_REQUIRE_ATTESTATION=1` refuses that unavailable-verification state.

These controls do not eliminate all supply-chain risk, but they make release changes easier to review and verify.

Installers serialize custom configuration paths as literal shell data in the C locale before embedding the launcher assignment, so the launcher stays ASCII. Self-removal recognizes released Mole launcher signatures without executing discovered files, reading them as bytes so launchers pinned to non-ASCII paths by earlier builds still count, and checks them again after confirmation; an unrelated command named `mo` or `mole` is retained.

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
- `tests/slim.bats`
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

The 14 entries from the initial report were individually rechecked. M13 is repaired; the other 13 retain the stated product, operating-system or verification boundary rather than representing an unimplemented patch.

| ID | Disposition | Reason and current boundary |
| --- | --- | --- |
| M01 | No code change | Permanent cleanup has no general undo. Changing every cleanup to Trash would change its existing reclaim-space contract. |
| M02 | No code change | Final path/owner checks reduce replacement risks but do not hold an atomic lease across a filesystem or third-party owner action. An owner can start after its last idle check. |
| M03 | No code change | Multi-file operations can stop after partial completion. Synchronous logs retain known outcomes, not a transaction or crash-recovery guarantee. Slim likewise retains the original in Trash if final replacement fails; automatically restoring over a concurrently created target would be unsafe. |
| M04 | No code change | Analyze explicitly uses Trash; other confirmed cleanup remains permanent. These command-specific recovery semantics are intentional. |
| M05 | No code change | Uninstall Trash operations still depend on macOS permissions, volume behavior and Trash availability; failures preserve remaining targets rather than falling back to permanent deletion. |
| M06 | No code change | Generic orphan cleanup's 30-day threshold is only one guard. It is limited to caches, logs and saved application state, requires complete installed-app evidence and rechecks bundle ownership and identity. A nonstandard installation invisible to that inventory remains a discovery limit. |
| M07 | No code change | Claude VM orphan cleanup requires seven days, absent exact bundle ownership, no live/unknown owner and a final ownership recheck. The age alone is not authorization; invisible installations remain a discovery limit. |
| M08 | No code change | Time Machine windows intentionally use conservative hour-based retention; there is no demonstrated unsafe boundary requiring a finer unit. |
| M09 | No code change | Bundle IDs and localized metadata are preferred, but incomplete metadata or nonstandard installation locations can still defeat name-based discovery. Broader guessed-name deletion would weaken ownership. |
| M10 | No code change | Immediate app-data removal belongs to the separately confirmed uninstall flow, not shortening automatic orphan retention. |
| M11 | No code change | Checksums and available attestations do not eliminate bootstrap or downstream distribution trust. A second hash from the same source would not resolve that boundary. |
| M12 | No code change | Control bytes cannot forge extra records, but literal backslash escapes can display like escaped control bytes. Logs are user-writable, not tamper-resistant evidence; adding a same-user signature would not establish independent trust. |
| M13 | Fixed and regression-tested | History JSON now validates UTF-8 and renders malformed bytes as U+FFFD, preserving valid text and stored log bytes. See the follow-up above. |
| M14 | Ongoing verification | Threat modeling, regression coverage and release/disclosure hardening are continuing review duties, not a specific unresolved defect. Fixtures and source checks do not prove every installed application, signed package or machine. |

For reporting procedures and supported versions, see [SECURITY.md](SECURITY.md).
