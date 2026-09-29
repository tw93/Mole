# Test validity and refusal diagnostics

Read this reference when a regression passes unexpectedly, fails only in the full suite or CI, mocks an external command, or changes a gate with multiple refusal causes.

## 11. A test that cannot fail

Several Mole regressions were "covered" by assertions that passed on the pre-fix implementation. Prove the test reaches production code and observe it fail before applying the fix.

### Assertion and branch traps

- A non-final bare `[[ ... ]]` can be swallowed when a later command succeeds. End every meaningful assertion with `|| return 1`; inside an inner script use `|| exit 1`.
- A non-final bare `! cmd` asserts nothing in any bash, because a negated pipeline never trips errexit. Write `! cmd || return 1`, or `|| exit 1` inside an inner script. `scripts/audit_bats_assertions.py` flags it in test bodies and in `run bash <<'EOF'` script bodies.
- `MOLE_TEST_MODE=1` can make the function under test return early. A final negative assertion over empty output then passes. Override the mode and mock authorization when the body must run.
- A function mock can choose a different branch from a PATH executable. `run_with_timeout` execs binaries, so timeout and external-command paths require a PATH stub.
- A timeout test that accepts status 0 does not prove timeout propagation. Assert the exact status, discarded partial output, and a positive trace from the production branch.
- A negative assertion for a string that never exists proves nothing. Confirm the current production label or symbol first.

Minimal bracket repro:

```bash
cat > tests/zz_min.bats <<'EOF'
@test "non-final [[ ]] false" { [[ 1 -eq 2 ]]; [[ 1 -eq 1 ]]; }
@test "non-final [ ] false"  { [ 1 -eq 2 ];  [ 1 -eq 1 ];  }
EOF
bats tests/zz_min.bats
```

Remove the temporary fixture after the experiment. Count ineffective assertions per test block, not per line, and treat any count as a live diagnostic rather than durable documentation.

### Isolation and CI parity

A case that passes alone and fails in the suite usually exposes shared state or a different runner contract before it exposes production behavior.

- `setup_file` shares `HOME` across tests in one Bats file. Tests asserting absence, exact file count, cache freshness, or "only X" use a dedicated child `HOME` or remove only fixtures they created.
- Discovery fixtures must also isolate fallback roots: stubbing Spotlight while leaving real `/Applications` scans active makes matching tests depend on the host's app inventory and scan budget. Keep real traversal inside each test's fixture roots.
- Mutable shell counters do not survive command substitution because it runs in a subshell. Persist call state in a test-owned file when the production path captures stdout.
- A sink may intentionally suppress a mock's stdout. Write a positive call trace to a test-owned file; an empty captured output cannot prove the sink was never reached.
- Physical discovery can turn a fixture's `/var/...` HOME into `/private/var/...`. When the assertion depends on `~` abbreviation, canonicalize the fixture HOME with `pwd -P` inside the test and retain the exact assertion. Do not weaken it to accept any path or change production rendering to satisfy a symlink alias.
- Match CI through `MOLE_TEST_NO_AUTH=1 ./scripts/test.sh`. If a narrow reproduction needs Bats jobs, preserve `--no-parallelize-within-files`; raw `bats --jobs 6 file.bats` changes the shared-state contract.
- Timing failures need the same worker load as CI. A one-second deadline based on whole `SECONDS` can expire almost immediately; project timeout constants stay at two seconds or more.
- Source-invariant greps skip comment lines and fail when the intended target matches zero code lines. Otherwise a comment can look like a forbidden call, or a renamed target can make the guard vacuously green (`73f89841`).

Known examples include a stale cache inherited through shared `HOME`, an `xcrun` function mock that bypassed the executable path, and a Maven test that asserted the absence of the wrong label. The mirror defect is a timing assertion that required `mdls` to run even when the legitimate deadline had already expired (`e95dd750`).

The acceptance bar is red-green: run the new test against the pre-fix code, see the intended assertion fail, then restore the fix and see it pass. For a dirty candidate, copy only the new tests into a clean worktree at the relevant pre-fix commit; a setup error or missing helper is not the expected red result. Record skipped cases separately from passes. A skipped PTY case needs its raw capability-probe error checked before calling terminal support unavailable; the macOS `script(1)` probe contract is in [Bounds, Shell, TTY, and parsing](shell-and-test-pitfalls.md).

A cancellation test has one extra positive-control requirement: a later candidate must be eligible without the sticky stop. If every candidate independently returns the same timeout, the negative assertion for the later sink passes both before and after the fix.

Every Bats file loads `tests/helpers/common.bash`, which owns the temp-`HOME` setup (`mole_test_setup_home` keeps the `tests/tmp-*` prefix `scripts/test.sh` sweeps) and puts fail-loud stubs for `sudo`, `osascript`, `launchctl`, `mdfind`, `brew`, and `xcrun` first on `PATH`: an unmocked call prints `UNSTUBBED <cmd>` and exits 97 instead of reading the host. A shell-function mock still wins, but `run_with_timeout` execs an external timeout binary that never sees shell functions, so a command run through it needs a PATH-level fake (`mole_test_fake_command`). `pgrep` and `lsof` are not stubbed because some tests use them for real; about 50 tests still reach production `pgrep` guards unmocked, which is host-dependent and worth its own pass. Test the whole script, not one extracted function: `bin/uninstall.sh` and `install.sh` are sourced whole (`install.sh` dispatches only when executed or piped). The four remaining single-function extractions are `bin/optimize.sh`, which calls `main` unguarded, and `scripts/check.sh`, which runs checks at the top level. Known flake: `update_progress_if_needed updates spinner text without restarting it` in `tests/core_common.bats` failed once on the macos-15 Validation job (run 36080480680) and once in about 100 local runs, including runs under CPU load; widening its 0.2s wait did not change the rate. It now prints the raw PTY capture on failure, so read that before changing the test.

## 12. A gate that cannot explain refusal

A gate with several independent causes and one catch-all message forces the reporter to reverse-engineer the source and causes maintainers to fix whichever wording was quoted.

`acquire_install_lock` has encountered unsafe ancestors, denied `sudo -n`, unusable lock directories, planted symlink or FIFO lock paths, unavailable lock primitives, and genuine contention. These causes need stable reason codes and distinct next actions.

Three recurring failures:

- The reporter did the triage because the message exposed no cause, as in #1335.
- A new gate ran before an older actionable check and downgraded "cache credentials with `sudo -v`" into a false busy-lock diagnosis (`d4a4b80c`, `e2020772`).
- A source-invariant test pinned a vague catch-all string, turning the diagnostic regression into a requirement (`926c2efa`).

For each reachable refusal, write down:

| Cause | Stable reason | User-visible explanation | Next command or action |
|---|---|---|---|
| exact branch condition | machine-readable code | one factual line | one cause-specific next step |

Two causes sharing one message is a defect when their remedies differ. "Reinstall" is not a remedy when reinstalling re-enters the same gate. When a new gate moves earlier in the flow, compare it with the old failure message and preserve at least the same actionability.

The next action must fail on the broken state. `#1579` aborted a multi-app uninstall when `brew info --cask` could not parse a binary-only cask. The hint said `brew list --cask`, which never loads a cask definition and still lists the broken cask as healthy. `#1580` kept the refusal and changed only the text: name the app the gate could not classify, and send the user to `brew info --cask`. Accepting a name-only cask match would have removed the message by weakening ownership, which `#1558` already forbids.

A multi-item batch that shares one refusal line must name which item hit the gate. An empty subject (`'' matches a Homebrew cask`) or a stage name alone (`Homebrew ownership check`) leaves the reporter guessing.

Check three properties for every new refusal:

1. The named cause is the branch that actually returned.
2. The suggested command or action is red on the failing input and green after the user repairs that input.
3. The cheaper-looking fix does not relax the evidence rule that created the gate.

Swallowed stderr can hide the only differentiating evidence. Use a controlled differential probe during diagnosis, then map the structured result to a reason code instead of permanently exposing raw privileged stderr.

```bash
command grep -c 'return 1' install.sh
command grep -c 'log_error' install.sh
command grep -rn 'sudo .*2> */dev/null' install.sh lib/
```

Pin reason-code routing and next-step branches in tests. Do not pin the catch-all prose.

## 17. A publication gate trusts ambiguous or pre-existing state

Publication turns parsed source and remote names into immutable public state, so loose matching and check-then-create races must fail closed.

Use three exact contracts:

1. Extract one non-empty source version and require the triggering tag to equal `V<source-version>` exactly. A prefix match or best-effort fallback can publish the wrong commit under a plausible tag.
2. When rewriting a generated package formula, require exactly one intended top-level source URL and one paired source checksum. Zero matches means the layout drifted; multiple matches means the rewrite target is ambiguous. Do not count bottle checksums as source fields.
3. Refuse to overwrite a pre-existing release branch, then close the race between that read and push with an expected-absence lease such as `--force-with-lease=refs/heads/<branch>:`. A read-only precheck alone is not concurrency control.

The gate's failure should name the mismatched value or occupied ref and tell the maintainer what to inspect before rerunning. Tests should falsify empty, mismatched, duplicate, and pre-existing cases against an isolated fixture. A grep proving guard text exists is useful as a source invariant, but it does not prove the shell branch rejects the bad state.

This pattern applies to publication safety defects in workflows and scripts. Release planning, version naming, notes, and announcement copy remain outside the `bugs` skill.
