# Mole Security Design

This document describes the safety mechanisms that prevent Mole from
destroying data it shouldn't. It is written for reviewers, contributors,
and anyone evaluating Mole for production use.

The corresponding implementation lives in `lib/core/file_ops.sh`,
`lib/core/app_protection.sh`, and `lib/core/app_protection_data.sh`. Path
validation has machine-checked fuzz tests in `cmd/analyze/delete_fuzz_test.go`
and `tests/path_validation_fuzz.bats`.

## Threat model

Mole is a user-invoked CLI that performs three classes of destructive
operations on the local machine:

1. **Cleanup**: remove caches, logs, and temp data the OS or apps regenerate.
2. **Uninstall**: remove an app bundle and its data directories.
3. **Trash routing**: move user-selected files in `mo analyze` to Trash.

We assume:
- The invoking user has shell access and runs mole intentionally.
- The user is **not** trying to attack their own machine.
- The user **does** make mistakes (typo a path, click wrong menu, run
  cleanup with stale config).
- Third-party apps writing into `~/Library` may have arbitrary names and
  may not follow Apple naming conventions.

We are **not** defending against:
- A user who runs `sudo mole` with malicious flags they typed in deliberately.
- A compromised macOS host where SIP is disabled and `/System` is writable.
- Supply-chain compromise of the mole binary itself (covered separately
  by signed releases + SHA256SUMS attestations in `release.yml`).

The lines we will not cross, regardless of input:
- Never delete a path inside `/System`, `/bin`, `/sbin`, `/usr` (except
  `/usr/local`, where Homebrew and user software live), `/etc`,
  `/Library/Extensions`, or `/var/db` (system databases). Under
  `/System/Volumes/Data`, where the Data volume is mounted, an entry the
  root reaches as the same directory (`/Users` through a firmlink, `/src`
  through a `synthetic.conf` link) gets that root path's verdict instead;
  every other entry on the volume stays inside `/System`.
- Never delete a bare top-level root itself, even when children are
  deletable: `/Applications`, `/Library`, `/Library/Application Support`,
  `/Volumes`, `/opt`, `/Users`, a user home root `/Users/<name>`, or
  `/var/root`. This blocks the empty-variable collapse where `"$dir/$name"`
  with an empty `$name` resolves to the parent root.
- Never delete a path that resolves (after symlink chasing) into one of
  the above.
- Never uninstall a `com.apple.*` system app, except the explicit list
  of App Store / developer-portal Apple apps that users actually buy
  (Xcode, Final Cut Pro, Logic, GarageBand, iWork, MainStage, etc.).

## Layer 1: `validate_path_for_deletion`

Every cleanup and app-data removal in mole funnels through `mole_delete` /
`safe_remove` / `safe_sudo_remove`, which all call
`validate_path_for_deletion` before touching the filesystem. Raw `rm` is
limited to the annotated bypasses of Layer 2 and to mole's own files:
`install.sh` removes its staged and temporary files (its `safe_rm` refuses
anything outside temp roots), and `mo remove` unlinks launchers that passed
its launcher-signature check with plain `rm -f` and removes the Mole-owned
cache and log directories with `rm -rf` annotated `# SAFE:`. The validator
applies six independent checks. Any one rejecting kills the operation.

Location: `validate_path_for_deletion` in `lib/core/file_ops.sh`.

1. **Non-empty + absolute.** Empty paths and any path not starting with
   `/` are rejected. Eliminates ambiguity from relative paths interacting
   with caller `$PWD`.

2. **Symlink resolution.** If the path is itself a symlink, the validator
   reads the link target, resolves it to an absolute path, and re-checks
   the target against the protected-path list. Prevents an attacker (or
   an accidental config bug) from pointing `/tmp/foo` at `/System` and
   getting the validator to wave it through.

3. **Ancestor symlink resolution.** Check 2 only inspects the leaf. If an
   *ancestor* component is a symlink, the literal path string matches
   nothing dangerous while the actual `rm` follows the link into the real
   target: a redirected `~/Library/Caches` would let a cache sweep walk
   into `~/Documents` or a system tree. So the validator canonicalizes the
   parent (a physical `cd` resolves every ancestor link) and re-runs the
   deny predicates on the resolved leaf. Two properties matter here:
   - **Deny-only.** A resolved path never *grants* permission the literal
     path lacked, so legitimate targets keep their existing verdict. This
     is why `/var` is deliberately not in the fuzz test's critical-root
     list: `/var/folders` temp trees are cleanable literally, so they must
     stay cleanable through a link too.
   - **Runs before the allow-list** in check 6, which would otherwise
     early-return past this gate for `/private/*` paths.

   The common case stays fork-free: ancestors are walked with the `[[ -L ]]`
   builtin and the canonicalizing subshell is only paid for when one of them
   really is a symlink. Doing it unconditionally cost ~2ms per call, about
   +23% on validation, on a function that runs once per deletion candidate.

4. **Path traversal.** `..` is rejected only when it appears as a full
   path component (`/foo/../bar`, `/..`, `../bar`, `foo/..`). This is
   tighter than naive substring matching: it allows legitimate names
   like Firefox's `name..files` directory while still blocking
   `/Users/me/Library/../../etc`.

5. **Control characters.** Any path containing `\n`, `\t`, or other
   `[[:cntrl:]]` bytes is rejected. Defends against log-injection and
   surprising-shell-interpretation scenarios.

6. **Allow-then-deny match.**
   - First, explicit allow-list for known-safe subtrees under `/private`
     (`/private/tmp`, `/private/var/log`, `/private/var/folders`,
     `/private/var/db/diagnostics`, etc.) and `/System/Library/Caches/com.apple.coresymbolicationd/data` (rebuildable).
   - Then, deny-list for `/`, `/bin*`, `/sbin*`, `/usr*`, `/System*`,
     `/Library/Extensions*`, `/etc*`, `/var/db*`, `/private`, and
     `/private/etc*`.
   - Finally, calls `should_protect_path` (Layer 2) for fine-grained
     bundle / app / data protection.

The allow-then-deny ordering matters: rebuildable system caches we
*want* to clean live under paths we'd otherwise block. Listing them
first means a maintainer adding a new safe path doesn't have to surgically
weaken the deny rules.

## Layer 2: `# SAFE: <reason>` contract for raw `rm`

The validator is opt-in: a contributor could bypass it by writing `rm -rf`
directly. To make that bypass loud and reviewable,
`scripts/audit_destructive_sinks.py`, run from `scripts/check.sh` and from the
CI security job in `.github/workflows/test.yml`, requires an explicit
annotation on every raw recursive deletion:

```bash
rm -rf "$temp_file" # SAFE: created by mktemp in this function, never user input
```

The audit rejects any recursive forced `rm` (`rm -rf` and its spelled-out
equivalents) or `find ... -delete` that is not either:
- A pure documentation line (comment-only or echoed help text), or
- Annotated with `# SAFE: <one-sentence reason>` on the same line.

The validated wrappers are not exempt: the `rm -rf` inside `safe_remove` and
`safe_sudo_remove` carries the annotation too.

Every annotated bypass in the codebase currently has a reason that
constrains the input: confined to `$temp_file` from `mktemp`, confined
to a stub container we just created, confined to `tests/tmp-*` from a
test runner. The annotation forces the author to articulate the constraint
before the code can land.

For current uses, grep `# SAFE:`. Anchored by symbol rather than line number,
because line refs rot: `_remove_verified_container_stub` in `lib/clean/apps.sh`,
`cleanup_temp_files` and the Mole-temp-root sweeps in `lib/core/base.sh`, and
the orphan-tmp cleanup in `scripts/test.sh`.

`_remove_verified_container_stub` is the one bypass worth understanding before
you "fix" it: it *must* use raw `rm`, because `should_protect_path` blankets
`~/Library/Containers`, so routing it through `safe_remove` would have the
validator refuse both stub paths and silently kill the feature. That reasoning
is pinned by a test in `tests/clean_apps.bats`.

## Layer 3: App protection, split fast vs. detailed lists

Uninstall and per-app cleanup decisions go through
`should_protect_from_uninstall` and `should_protect_data` in
`lib/core/app_protection.sh`. They consult the data lists kept in
`lib/core/app_protection_data.sh` plus a wildcard fast path written inline in
`should_protect_data`:

| List | Used by | Shape | Purpose |
|---|---|---|---|
| Inline `case` patterns in `should_protect_data` | Cleanup paths (`should_protect_data`) | Wildcard patterns | Fast `com.apple.*` and family-pattern guards. Misses are acceptable here; cleanup of an unknown system component just means leftover files, not deletion of a live app. |
| `SYSTEM_CRITICAL_BUNDLES` | Uninstall (`should_protect_from_uninstall`) and path protection (`should_protect_path`) | Explicit bundle IDs | Detailed list of every `/System/Applications` and Apple system service. Must be exhaustive: a miss here would let a user uninstall Finder. |
| `APPLE_UNINSTALLABLE_APPS` | Uninstall | Explicit bundle IDs | Allow-list of Apple-developed apps the user actually installed (Xcode, FCP, Logic, etc.). Required because `com.apple.*` cannot be a blanket block. |
| `DATA_PROTECTED_BUNDLES` | Cleanup (`should_protect_data`, `should_protect_path`) | Wildcard patterns | Third-party apps with sensitive state (1Password, JetBrains, IM tools, VPNs, etc.) whose caches must not be touched. |

The deliberate redundancy between the inline patterns and CRITICAL is **not** a bug:
- The inline patterns are a wildcard fast-path used in tight loops during
  cleanup, where a `com.apple.*` blanket is correct.
- CRITICAL is the detailed allow-list used at uninstall time, where the
  blanket is wrong (it would block Xcode uninstall) so individual bundles
  must be enumerated.

### Keeping the lists honest

A new macOS major release can ship new system apps and daemons. The
monthly `.github/workflows/bundle_audit.yml` job runs
`scripts/audit_bundle_drift.sh` against the latest `macos-latest`
runner. The script enumerates every `.app` under `/System/Applications`,
computes its `CFBundleIdentifier`, and reports any bundle ID not matched
by CRITICAL + DATA_PROTECTED. Any miss opens a tracking issue.

Each macOS major release should also get a human pass over: bundle
drift, mdls timeout regression, SIP path changes, and CI matrix updates.

## Layer 4: Trash routing default

`mo analyze` and `mo uninstall` (default since #723) route deletions to the
macOS Trash. `mo analyze` (`moveToTrash` in `cmd/analyze/delete.go`) tries
Apple's `/usr/bin/trash` first, then an atomic no-overwrite rename into the
per-volume Trash, and uses Finder AppleScript only as the last fallback.
This gives users the standard Apple-native "Put Back" recovery flow.
`mo clean`'s batched cleanup path, `mo purge`, and `mo installer` delete
permanently; `mo uninstall --permanent` opts out of Trash, and
`mo analyze` always uses Trash.

The `trash` and `osascript` calls use a 30-second timeout (`trashTimeout`)
so a hung Finder can't wedge the binary, and the Finder path escapes both
`\\` and `"` in the path before substituting into the AppleScript
literal. Defense in depth: `validateTrashTarget` (which wraps
`validatePath`) runs on the raw path and again on the resolved absolute path
before any of the three routes, so even if escape logic missed a case, a
path containing `..` or null bytes is rejected before it reaches Finder.

## Layer 5: Test mode + dry run + property tests

Three orthogonal mechanisms make the safety claims testable and
prevent live-machine test runs from doing real damage:

- `MOLE_DRY_RUN=1`: every safe-remove logs what it would do and
  returns 0 without touching the filesystem. Used in CI for the
  no-mock path coverage and recommended before any local cleanup.
- `MOLE_TEST_NO_AUTH=1`: refuses to call `sudo`, `osascript`,
  `launchctl`, or any path that would prompt the user. Required for
  bats and the integration tests. Enforced by `scripts/test.sh` PATH
  stubs that fail loudly when called.
- `tests/path_validation_fuzz.bats` and `cmd/analyze/delete_fuzz_test.go`
  harden the validators. The bats test asserts that every line in
  `tests/fuzz_corpus/dangerous_paths.txt` (96 adversarial paths today)
  is rejected. The Go fuzz target runs its seed corpus during normal
  `go test`; maintainers can run `go test -fuzz=FuzzValidatePath ./cmd/analyze`
  when changing path validation. It asserts the invariant:
  anything accepted must be absolute, free of null bytes, and free of
  `..` components.

If you add a new way to bypass these layers, you are expected to add
a corresponding test that fails before your code lands.

## What this design intentionally does not do

- **No code signing of the cleanup config.** We rely on filesystem
  permissions to protect the protection lists from tampering. If a
  user can edit `lib/core/app_protection_data.sh` they can already
  edit `mole` itself; the threat model says we don't defend that.
- **No anti-rollback.** A user who restores an old mole binary or
  installs a forked build with weaker lists gets weaker protection.
  We address this through release signing, not runtime checks.
- **No protection for arbitrary user paths.** `~/Documents/important`
  has no special status. The user is responsible for selecting safe
  cleanup targets; mole only guarantees system integrity.
- **No telemetry.** We never report what was scanned, deleted, or
  attempted. Mistakes are diagnosed locally via the operation log
  `~/Library/Logs/mole/operations.log` (`MO_NO_OPLOG=1` disables it) and
  the deletions log `~/Library/Logs/mole/deletions.log` that `mole_delete`
  appends to.

## When to update this document

- A new layer (e.g., a notarization check, a per-volume policy) is added.
- The validator gains a new check class or relaxes an existing one.
- A new app protection list is introduced.

Last reviewed: 2026-10-08 (mole V1.59.0).
