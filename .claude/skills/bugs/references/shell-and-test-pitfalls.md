# Bounds, Shell, TTY, and parsing

Read this reference when changing Shell code, Bats tests, update/install flows, timeout wrappers, TTY handling, plist fixtures, or macOS-version-specific CI behavior. The defect classes and repo-wide probes stay in the parent `bugs` skill.

## 4. An external command or its consumer is unbounded

`du`, `mdfind`, `find`, `xcrun simctl`, `system_profiler`, `ioreg`, and package tools can stall on a healthy but slow machine. Every production `du -s` route stays behind `run_with_timeout` with `MOLE_TIMEOUT_DISK_VERIFY_SEC`; `tests/core_timeout.bats` pins the class across `lib/` and `bin/`.

Check more than the obvious command:

- Put checkpoints in every nested loop, not just each outer root (`edb214c0`).
- Tune against the slowest healthy case. CoreSimulatorService needed a warm-up retry after a two-second bound falsely reported it unavailable (`35d856f1`).
- Materialize a bounded producer completely and discard its output on nonzero status. Process substitution plus `|| true` must not feed a partial `find` prefix into deletion.
- Keep probe and action pattern, type, age, and depth identical.
- Time producer and consumer separately before raising a timeout. A 2.3-second `lsregister` dump followed by one command substitution per input line still becomes minutes.
- Bound installed-binary `--version` and `--help` verification. Broken executables are the ones most likely to hang.
- Keep install and update single-flight per target directory so one process cannot verify another generation.
- The self-update bootstrap on a user's machine (temp file, registry, exec) is frozen at whatever version installed it, so a broken installed version cannot repair itself. That is why `_update_self_heal_reinstall` streams `install.sh` from `main` into bash with no local temp files (#1297). V1.47.1 shipped the false-success shape the bounded version check now prevents: update success read from installer output instead of from the installed binary.
- The single-flight mutex prefers absolute `/usr/bin/lockf` because the kernel drops that lock even if the holder is killed. `lockf` only ships with newer macOS, and requiring it made install and update exit before writing a file on every older release (#1348); the `mkdir` fallback exists for those releases. The lock wrapper is not a shell array because the empty array is the fallback path, and an empty array under `set -u` is an unbound-variable error on Bash 3.2 (section 5).

```bash
for command_name in 'du -s' mdfind xcrun system_profiler ioreg brew; do
    printf '%-16s total=%-4s wrapped=%s\n' "$command_name" \
        "$(command grep -rn -- "$command_name" lib/ bin/ | wc -l | tr -d ' ')" \
        "$(command grep -rn -- "$command_name" lib/ bin/ | command grep -c run_with_timeout)"
done
```

## 5. Bash 3.2, errexit, and pipefail change meaning

macOS ships Bash 3.2 and Mole runs with nounset.

- Guard `"${arr[@]}"` with `[[ ${#arr[@]} -gt 0 ]]`; an empty array under `set -u` can abort a scan and orphan its spinner (`893b4e6f`, `2c06cb91`).
- `fn || handler` disables errexit inside `fn` for the whole function. Safety-critical steps use explicit `if ! command; then return 1; fi` (`a33a0b51`). Installers must also verify the installed binary's reported version before claiming success; `tests/install_checksum.bats` covers the exact caller shape.
- Do not rely on a caller's temporary `set +e` window for graceful degradation. Capture the status where the command runs.
- Optional `[[ -n "$value" ]] && action` returns 1 when absent. Use `if/fi` inside status-sensitive blocks.
- Fixing a branch that Bash 3.2 silently skipped is a behavior change for every caller. `read -t 0.01` fails on 3.2, so `drain_pending_input` never drained there; `ed02a6aa` made it flush the terminal queue after every menu key, and a pasted search term kept only its first character. Before enabling such a branch, list its callers and check each for text entry, call the system tool by absolute path (a version-manager `perl` shim can fail or add startup latency per key), and never fall back to a one-second integer read on a terminal.

```bash
command grep -rn '\$\{[a-z_]*\[@\]\}' lib/ bin/
```

## 6. Background work steals TTY, stdin, or process groups

The Perl timeout fallback can hand the controlling terminal to its child. A background metadata worker then stopped the foreground uninstall prompt with SIGTTIN (`c93afca3`). BSD `mv` and `cp` can also prompt on stderr and read stdin when a destination is unwritable (`63030e3a`).

Every background worker that calls `run_with_timeout` closes stdin with `< /dev/null`. Commands that can prompt also use their noninteractive or force option. Menu and scan traps save and restore the caller's traps; `lib/ui/menu_paginated.sh` is the reference.

## 7. System command output is treated as an API

macOS command output is localized, drifts between releases, and can print errors where data is expected.

- Force `LC_ALL=C` for parsed metric subprocesses (`51b352a2`, `fa05b8cc`, `4e83743b`).
- Validate field shape before trusting it: absolute path, numeric value, expected key, or exact enum.
- Keep `DTSDKBuild` build identifiers separate from `DTPlatformVersion` versions (`f0896d03`).
- Reject PlistBuddy's missing-file prose as data.
- Use stock macOS semantics when checking flags. BSD `grep -Z` means `--decompress`; a developer alias may hide that.
- Prefer exit codes, plist keys, and machine-readable output over prose matching.
- Join records on the machine identifier, never on a heading or display string. `simctl runtime list` titles each image with the image version (`iOS 26.4.1`) while `simctl list devices` groups under the runtime short name (`iOS 26.4`). A name join calls every point release an orphan and offers `simctl runtime delete` for a runtime its simulators still bind (`#1505`). `mdls -name kMDItemDisplayName` returns the on-disk file name, not Finder's localized name, so it always differed from `app_name` and always won the old selection, leaving the `CFBundleDisplayName` and `CFBundleName` branches unreachable and shipping folder names like `VideoFusion-macOS` (`#1520`).
- `plutil -p` is documented by `man plutil` as unstable and not designed for machine parsing. macOS 15 prints a JSON boolean true as `1` while macOS 26 and 27 print `true`, so a filter pinned to one spelling silently cleaned nothing on the other: `#1512` was fixed and then regressed for eight days with CI green. Where a boolean prints as `1` nothing can tell it from the integer 1. The rendering is also depth-blind, so `{"outer":{"inner":true}}` offered a directory named `inner` for deletion, a wrong deletion rather than a missed one. That is why `tests/clean_app_caches.bats` runs on the macos-15 compatibility job.

Use `command grep` when flag behavior matters, because the interactive environment may alias it.

## 15. Cancellation is local unless orchestration makes it sticky

Classify a timeout at its source before propagating it. Signal-derived cancellation and safety-guard timeouts that the caller treats as cancellation must remain sticky across the remaining command. Status `124` alone does not define the scope. Read the probe's product contract first:

| Contract | Typical `124` | Typical `>=128` |
|---|---|---|
| Safety guard, owner unknown, or cancellation the caller already established | Sticky stop; later mutation and later sections must not start | Sticky stop |
| Per-item sizing or removal of an otherwise eligible candidate | Skip or fail that item; later items may continue (`#1374`, `#1384`, `#1576`) | Sticky stop |
| Review-only or advisory listing that never deletes | Skip that advice; later cleanup sections continue (`#1571`) | Sticky stop |
| Cooperative section budget | Stop the rest of that section, report partial, continue later sections (`#1513`) | Sticky stop |

- In `bin/clean.sh`, a final delete guard returning `124` cancels later work, while an individual `safe_remove` timeout is a reported failed removal and later items may continue. Timed-out sizing contributes an unknown/partial total, not false reclaimed bytes. Large-files Mail / Downloads / Updates rows follow the review-only skip: a size timeout omits that row, and a signal still cancels (`#1576`, `#1344`).
- The orphaned-runtime review is advisory. A cold `simctl` that returns `124` skips the review and must not cancel later `mo clean` sections. Skip the review entirely when the unavailable-simulator listing already timed out after its warm-up retry (`#1571`, `04e658d2`).
- Orphan leftover probe and sizing timeouts (`mdfind` in `is_bundle_orphaned` / `is_claude_vm_bundle_orphaned` / `_container_stub_app_exists`, plus `get_path_size_kb` and candidate snapshots) fail closed for that item and later leftovers plus later `mo clean` sections continue. A `safe_clean_guarded` 124 at the sink stays sticky (`#1584`). Do not cache a timed-out Spotlight miss as "not installed".
- Cloud & Office uses a cooperative section deadline: stop the remaining items in that section, preserve parent counters, report partial completion, and continue later sections. Do not restore its removed outer timeout worker or the file-backed deferred-family replay that existed only for that worker.
- Purge discovery discards incomplete root scans and marks the run incomplete. An authored-content probe returning `2` keeps and visibly reports that candidate; deletion-phase activity or removal timeouts cancel the run. Unknown evidence never permits deletion.

The inverse defect is as common as a missed sticky cancel. Treating a review-only `124` as command-level cancellation skips every later section. Treating a safety-guard `124` as a local skip deletes with unknown evidence.

Once the caller establishes cancellation, carry that decision through every boundary:

- A best-effort loop must check a pending cancellation before probing or registering the next candidate.
- A helper that reports ordinary misses as success must return a pending cancellation before starting the next family.
- Command substitution, subshells, and background workers do not mutate the parent's shell variables. Return the status, or use an explicit parent-readable channel, then record it again in the parent.
- A parallel coordinator stops and reaps peer workers, preserves cancellation over ordinary failures, and prevents the next rendered section from starting.
- Dry-run uses the same cancellation contract as real cleanup. A preview ledger is still downstream work and must not continue after safety evidence becomes unavailable.

The regression shape matters. Make the first candidate's safety guard return 124 or 130 and make the second candidate succeed if reached. Assert the exact top-level status plus the absence of a positive trace from the second probe, preview registration, sink, and later section. If both candidates independently time out, the test cannot prove cancellation was sticky. Separately preserve the removal-timeout and cooperative-section-budget continuation cases in `tests/clean_core.bats`.

Do not hide a cancelled safety probe behind `|| true`, a warning plus `return 0`, or a worker-local exported variable. Those shapes turn a global stop into a local skip.

Name the question instead of spelling the numbers: `mole_rc_timeout` and `mole_rc_timeout_or_signal` in `lib/core/timeout.sh` are the only places that compare a status against 124, and `scripts/audit_timeout_status.py` rejects a raw comparison anywhere else in `check.sh`. A per-item size whose number only feeds totals goes through `mole_item_size_continues` in `lib/core/file_ops.sh`: a timeout or failure keeps the item with an unknown size and marks the freed total partial, a signal records the cancellation and stops. Choosing between those helpers is still the caller's contract decision from the table above; the helper only makes the choice visible in review.

A third predicate, `mole_rc_signal`, is true only for a status above 127 that `kill -l` names. A mutating owner command can exit with an errno-derived code such as npm's 243, which is an ordinary failure, so the owner-command wrappers (`clean_tool_cache`, `bun pm cache rm`, `simctl delete unavailable`, `brew cleanup`, the tart prune and `go clean`) cancel only on it and skip that one command on 124 (`clean_tool_cache treats non-signal high owner statuses as failures (#1695)`, `clean_tool_cache keeps valid signal statuses sticky (#1695)`, `clean_dev_go treats an errno-derived go clean exit as a failure, not an interrupt`). A timed-out `go env` lookup skips only the Go caches because nothing was attempted yet, while the `gh` probe and clear, the automation-browser `ps` listing and the clang cache resolver stay sticky (`clean_dev_cloud stops on GitHub CLI probe or clear cancellation`).

## Focused pitfalls

- **A PTY read loop must end on an empty read, an `OSError`, or a deadline.** After the child exits, a macOS pty master can stay readable and return `b''` forever, so a `while select(...)` drain with no exit spins until the job times out; Linux raises `EIO` instead. `tests/sudo_adoption_pty.py` hung this way on #1747 (fixed in the squash `eb531ba2`); the other `tests/*_pty.py` loops are deadline-bounded.

- **Launcher signal stories behind the `lib/manage/update.sh` rules in `.claude/rules/install-update.md`**: a tty7 pane can inherit the daemon's blocked TERM mask, so a child launched without unblocking it left uninstall waiting forever for its spinner and made Ctrl-C cleanup hang. Bash prints a signalled child's job-status line (`Killed: 9 ... perl ...`) from whichever command finishes first after the child dies, so a runner that stalls the router for a few milliseconds leaked it at random until the launch, readiness wait and `wait` shared one `2> /dev/null` group. And Bash 3.2 can discard an INT received inside a USR1 trap entered from the `wait` builtin, which is why the readiness notification settles before `wait` starts.
- **A `find` primary newer than the oldest supported macOS needs a probe, and dataless folders must not be listed**: listing a dataless CloudStorage folder makes File Provider fetch it over the network (`77050616`), an older `find` rejects `-flags +dataless` and fails the whole walk (`8dccb160`), and the capability probe itself must pass signals through (`df2f5e06`). Probe once per process: unknown means walk without the primary, a signal cancels, and never descend into a dataless folder.
- **`BASH_SOURCE` / `$0` change meaning when a function moves files**: they name the file the code lives in, so copy-paste extraction is not behavior-preserving. `mole` captures `MOLE_ENTRY_SCRIPT="${BASH_SOURCE[0]}"` before sourcing anything, and update code reads that stable entrypoint. Before extracting a function, grep it for `BASH_SOURCE`, `$0`, and `FUNCNAME`. Regression coverage lives in `tests/update.bats`.
- **Bats heredocs share stdin with `read -n1`**: an inner `read -r -s -n1` can consume the next byte of the heredoc source. Redirect the function under test from `/dev/null`.
- **macOS `script(1)` rejects socket-backed stdin**: PTY test helpers must redirect the wrapper's stdin from `/dev/null` or `script` can fail before starting the child. Capability probes use `/usr/bin/true`, not the absent `/bin/true`; inspect the actual failure before classifying it as unavailable TTY support, or live terminal tests silently skip.
- **`run_with_timeout` execs the binary and bypasses shell-function mocks**: tests must use a PATH stub directory for commands such as `osascript`.
- **CI runners may lack `/Library/PrivilegedHelperTools`**: orphan-service tests should exercise `/Library/LaunchDaemons`, which exists on GitHub macOS runners.
- **A test can pass vacuously after an early return**: `MOLE_TEST_MODE=1` can leave `$output` empty, and a final negative assertion then passes. End assertions with `|| return 1`, override test mode when the body must run, and add a positive control proving the output path executed. In an inner heredoc script use `|| exit 1`. Confirm the bracket behavior with a minimal repro when it matters: a non-final `[[ ]]` can be swallowed while `[ ]` still gates.
- **A large payload piped into `grep -q` leaks a broken-pipe line into user output**: `grep -q` exits on its first match, and the `printf` still writing into that closed pipe takes SIGPIPE, which bash reports as `printf: write error: Broken pipe` on stderr. The live-cache owner probe fed the whole process table that way and the message landed mid-run in `mo clean`. Pass the data by here-string instead. Small variables holding a few lines of command output finish in one write and are unaffected, so the existing `echo "$var" | grep -q` sites are fine.
- **Normalize with `10#` before any numeric comparison**: `[[ a -le b ]]` evaluates arithmetically, so a leading zero is read as octal and `0123` ranks below `100`, while `08` and `09` are not valid octal at all and abort the test with a bash error on stderr. A `^[0-9]+$` guard does not prevent either. Codex build numbers compared this way could have called a newer staged build superseded.
- **`SECONDS` advances in whole seconds, so a 1s budget is not a second**: a deadline built as `SECONDS + 1` really means "until the next second boundary" and can collapse to almost nothing, making `_mole_timeout_with_deadline` return 124 before the command ever runs. Every timeout constant is 2 or more for this reason. A test of clamp arithmetic invokes the helper directly after resetting `SECONDS`; an exact value asserted across command substitution still races the fork on a loaded runner even with a larger window. When the fork is the behavior under test, assert a safe range or property instead of one remaining-second literal.
- **BSD grep has no GNU null-output `-Z` contract**: on stock macOS it means `--decompress`. Enumerate files with `find ... -print0`, then probe each file with `grep -qF`.
- **PlistBuddy reports missing-file creation on stdout**: redirect both stdout and stderr when creating plist fixtures so diagnostic prose does not pollute Bats `$output`.
- **macOS 14 Bash can fire errexit through an if-guarded exported mock**: a failing exported `sudo` function inside an `if fn; then` path may terminate a `set -e` script on that runner while passing locally. Around the first sudo probe, disable errexit only for the probe and restore it before validation-gate returns. CI-only failures must print exit status, output, and a mock call trace rather than a bare return-code assertion.
- **Expected capability absence is not probe failure**: keep `ready`, `not applicable`, and `misconfigured or unknown` distinct. A Mac with standalone Command Line Tools and no Xcode app has no simulator surface, so missing `simctl` is a quiet skip; an explicit invalid `DEVELOPER_DIR` remains actionable. Tests prove the not-applicable path does not invoke the unavailable owner command or emit warning activity.
- **Fixed-width prefixes may have a free-form remainder**: after validating numeric and enum columns, join the remaining fields instead of assigning semantic meaning to one whitespace token. Darwin process `comm` values can contain spaces; trimming them to the first word destroyed zombie-parent attribution for helper apps. Keep primary and fallback formats separate when their fields carry different semantics.
