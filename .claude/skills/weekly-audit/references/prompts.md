# Weekly Audit Prompts (CLI)

Fill `<MAIN_HEAD>`, `<WINDOWS_HEAD>`, `<WINDOW>` (per branch, from `docs/weekly-audit.md`, "Next window from")
and `<SCOPE>` (Phase 1). Every audit prompt starts with the shared header; every fix prompt with the fix header.
Fixed prompts keep coverage from drifting between runs (adapted from mole-mac and mole-windows, 2026-10-16).
Since 2026-11-10 the audit covers three trees: add the linux branch (checkout `~/www/mole-cli-linux`, or
`origin/linux` at `<LINUX_HEAD>`) to the shared header and every dimension, with its own `AGENTS.md`, `SYNC.md` and
`docs/ledger.md`; its code is bash 5 with GNU tools, cannot run on macOS, and is tested on the devbox. Windows keeps
per-command rules in `.claude/rules/` beside its `AGENTS.md`.

## Shared audit header

```
Read-only audit of Mole CLI: this checkout (macOS, main at <MAIN_HEAD>) and the windows branch
(its worktree from git worktree list, or origin/windows at <WINDOWS_HEAD>). Do NOT edit, stage, commit, run a
real cleanup or sudo; read, grep and git log only. Tests only with MOLE_TEST_NO_AUTH=1 against fixtures,
never with a worktree under /private/tmp. Exclude tests/tmp-*, .git, build output and other sessions'
worktrees from every grep. Scope: <SCOPE>. Read AGENTS.md on both branches first; before reporting a
candidate, grep AGENTS.md, .claude/rules/, SYNC.md and docs/ on both branches for its symbol, since the decision may be
recorded on the other branch. Read docs/weekly-audit.md: never report an item under "Decided, do not
re-report". For EACH candidate, try to refute it once (the guard that already blocks it, the test that
locks it, or the line recording the decision) and report only survivors. Check correctness across
TUI/JSON, live/completed/cached results, selection identity, empty/partial results, encoding, exit
status and cancellation. Route applicable cross-CLI fixes through the existing SYNC.md owner row.
Use raw output for complete counts; recheck frozen heads and flag concurrent changes. Discover
available native test hosts before assuming Windows execution is unavailable. Mark every number
as measured (say where) or reasoned (say from what).
Output (<= 800 words): ranked findings with branch:file:line, severity, concrete failure scenario, why
existing guards miss it, smallest fix, and any remaining product decision; then a short "checked and
fine" list. Distinguish reproduced, statically confirmed and unresolved claims, and name untested
modules, host/shell/source SHA and runtime boundaries. Helper evidence is not full-entrypoint evidence.
```

## 1. Unsafe

```
macOS: every removal goes through mole_delete / safe_clean / safe_remove or carries a same-line
# SAFE: reason; matching stays on exact bundle IDs or paths; timeouts mean unknown and keep the target;
dry-run lists exactly what a real run removes; every sudo, osascript and launchctl has a test-mode
guard; owner commands (brew, go clean, simctl, npm, nix) cannot mutate an unwhitelisted root and run
under run_with_timeout with an owner-planned dry-run.
Windows: every removal goes through Remove-Safe* / Clear-DirectoryContents and Test-SafePath; junction
and identity rechecks before the sink; uninstall leftovers only after Test-MoleInstallFolder.
Both: the Steam shape, a folder of irreplaceable content (game libraries, VMs, model weights, local-only
chat or clipboard databases, sessions) reachable as one cleanup or uninstall target. Name every launcher,
VM or model app you could not settle by reading, so the main session runs find_app_files against a
fixture HOME for it.
```

## 2. Over-design

```
Flags, environment variables or config keys added in <WINDOW> without a stated rejected default;
zero-caller functions (grep strings, eval, declare -f and dynamic names; tests alone are not callers);
same-body helpers scripts/audit_function_duplication.py --list misses; output lines that report
routine skips or a fixed zero. Never propose removing an existing flag.
```

## 3. Stale

```
First, the "latest stable" and "not released" lines in SYNC.md and AGENTS.md on both branches against
gh release list, exact tag ancestry and delivery receipts; source metadata is not proof of package
contents. Then every test named as a lock exists (grep -rn '@test "<name>"' tests on main,
It '<name>' in Pester on windows), versions, paths, make targets, commands, comments naming removed
functions. These files deliberately record removed and rejected things; read the context first.
Report counts: claims checked / stale / deliberate.
```

## 4. Performance

```
Forks per item inside loops that scale with app or file count (basename, tr, $(...), stat per entry),
repeated du or find over the same root, mdfind / system_profiler / pgrep not shared within a run,
unbounded waits, startup work on every command. Tie each to a count or a measured time and check
whether it is already cached, pooled or gated (tests/core_performance.bats).
```

## 5. Not yet codified

```
Window: git log <WINDOW>..<MAIN_HEAD|WINDOWS_HEAD> using each frozen audited head,
not a possibly lagging checkout HEAD. An area fixed twice, a behavior fix with no test touched,
a lesson living only in memory, an issue reply or one commit message, a rule repeated in several places
or grown more than 20% past the size recorded after its last compression in docs/weekly-audit.md, and fixes on one branch that SYNC.md should route to the other without a row.
Say where each lesson should live.
```

## Fix header (Phase 4)

```
Implement in the existing Mole CLI <main|windows> checkout after the main session synchronizes it.
Do not create branches/worktrees, restore files to HEAD, commit or push; the main session integrates
and commits/pushes the authorized scope under the current Git Safety contract.
Only touch: <files>. Other agents own: <files>.
Every behavior fix gets a test that fails on the old code, before editing or in an isolated source
snapshot/overlay outside /private/tmp. Preserve concurrent WIP. Run named fixture suites with
MOLE_TEST_NO_AUTH=1; the main session runs formatting and whole-tree checks once edits settle.
Windows native tests use available hosts under both powershell and pwsh; never infer native behavior
from a macOS cross-build. Return: files, test summaries, red-run evidence, source and host versions,
every deviation from this brief, and anything not done or outside your files.
```
