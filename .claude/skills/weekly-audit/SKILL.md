---
name: weekly-audit
description: >-
  Audit both Mole CLI branches for safety, correctness, performance and stale
  guidance, then land authorized fixes. Use for weekly or whole-CLI reviews.
  Not for a single defect or individual PR review.
metadata:
  version: "1.4.0"
  internal: true
  when_to_use: "每周体检、全面检查 CLI、审查 macOS 和 Windows CLI"
---

# Weekly Audit (CLI)

Adapted from Mole Mac's weekly audit (mole-mac `.claude/skills/weekly-audit`).
The first run (2026-10-16, main `eb531ba2`, windows `159657d5`) found `mo clean`
deleting Nix profile generations older than 30 days with no timeout or real
preview, the whole `~/Library/Application Support/Steam` game library offered as
one uninstall data row on macOS while Windows already refuses Steam libraries,
a dozen undocumented tuning variables, dead Windows cleanup stubs with tests that
cannot fail, per-app forks in `mo uninstall <name>` and `--list`, and five stale
release lines. Most of the tree was fine; the value is in the few findings that
survive refutation. Run it once a week and keep the report short.

## Phase 1: Freeze and scope

- For each branch record `git rev-parse HEAD`, the remote head, `git status
  --short --branch -uall`, and `git log --oneline <base>..<audited-head>`. `main` is this checkout; `windows`
  is its own worktree (`git worktree list`), never checked out over `main`. Fetch
  the remote branch read-only (`git fetch origin windows`) and audit
  `origin/windows` when no clean worktree is at its head. Freeze the merged PR
  IDs and count for the same window. Use raw output or structured results for
  counts, test summaries and complete coverage; RTK summaries may omit entries.
- Read the newest entry of `docs/weekly-audit.md` on `main`: its "Next window
  from" commits are this run's base per branch, its "Decided, do not re-report"
  list goes to every agent, and its "Open" items are rechecked first. The codify
  dimension reads that window; the others follow the scope selected below.
- Exclude `tests/tmp-*`, `.git`, build output and other sessions' worktrees from
  every grep.
- Mole CLI (Linux) is the third audited tree since 2026-11-10: the `linux`
  branch, checked out at `~/www/mole-cli-linux` (bash 5, GNU tools, Go). Freeze
  and fetch it like `windows`, and give every dimension its head. Its contract
  is the Safety contract in its own `AGENTS.md`; its run record is
  `docs/ledger.md` and its `SYNC.md`, and it has no incident table. Bats and Go
  tests run on the LazyCat devbox as the user `mole` (`linux-devbox` skill),
  never on macOS. Where this file says "both branches", read all three.
- Mole CLI (Windows) keeps its per-command rules in `.claude/rules/` since
  2026-11-10 (`147eef15`); the stale and rule-volume checks read those five
  files with its `AGENTS.md`, whose baseline is in `docs/weekly-audit.md`.
- An explicit whole-codebase request takes precedence over incremental defaults.
  Otherwise audit both branches whole on the first run, after a release, or when the
  window touched more than about 40 source files; otherwise incremental: the files
  changed in each branch's window, their direct callers, and every Open item. Mole
  for Windows' first whole-tree run cost about 1.15M sub-agent tokens for 18 findings,
  most in code untouched for weeks.
- Read-only until Phase 4. "看看 / 检查 / 跑一遍" never authorizes a write.
- Record coverage by module and evidence level. Before reporting or writing,
  recheck both heads and worktrees; review new commits and preserve concurrent
  edits. Reconcile the frozen PR set and list newly merged PRs separately.

## Phase 2: Five read-only audits in parallel

Assign each dimension to a sub-agent, batching assignments to fit available
slots. Start from the matching prompt in
`references/prompts.md` (shared header plus dimension body) so coverage does not
drift between runs, each covering both branches and naming which branch
every finding belongs to. Read-only: no edit, commit, build, real cleanup or
`sudo`. Tests may run only with `MOLE_TEST_NO_AUTH=1` against isolated fixtures.
Discover available test hosts: shared Go tests may run on macOS; PowerShell
behavior needs a Windows host, an available VM or native CI. Record the host,
shell version and source SHA. Do not change machine settings or install tools
without authorization. Each agent must try to refute every candidate once (find the guard
that already blocks it, the test that locks it, or the AGENTS.md / `.claude/rules/` / SYNC.md line
recording the decision, which may sit on the other branch, so grep both before
reporting) and report only survivors, with `branch:file:line`, a concrete failure
scenario and the smallest fix.

Correctness is mandatory across the five dimensions: compare TUI and JSON,
initial/live/completed/cached results, selection identity, empty and partial
results, encoding, exit status and cancellation. A bounded recursive summary
must not truncate a directly browsable child list. For each repaired contract,
inspect the other CLI's actual consumer and route applicable gaps through an
existing SYNC.md row before adding a new one.

1. **Unsafe.** macOS: every removal goes through `mole_delete` / `safe_clean` /
   `safe_remove` or carries a same-line `# SAFE:` reason; matching stays on exact
   bundle IDs or paths (no vendor prefix, TeamID or common-word globs); timeouts
   mean unknown and keep the target, signals cancel; dry-run lists exactly what a
   real run would remove; every `sudo`, `osascript` and `launchctl` has a test-mode
   guard; owner commands (`brew`, `go clean`, `simctl`, npm) cannot mutate an
   unwhitelisted root. Windows: every removal goes through `Remove-Safe*` /
   `Clear-DirectoryContents` and `Test-SafePath`; junction and identity rechecks
   before the sink; uninstall leftovers only after `Test-MoleInstallFolder`.
   Both: hunt for the Steam shape, a folder of irreplaceable user content (game
   libraries, VMs, model weights, local-only chat or clipboard databases, sessions)
   reachable as one cleanup or uninstall target. Do not stop at reading: run
   `find_app_files <bundle-id> <name>` against a fixture `HOME` for launchers that
   hold such content (Steam, Epic, GOG, Battle.net, Parallels, UTM, Ollama, LM
   Studio) and check what `should_protect_data` says; the first run's Steam row
   was missed by reading alone. List every `clean_tool_cache` owner command and
   check it has `run_with_timeout`, a dry-run that plans with the owner, and a
   recovery contract that only removes rebuildable state (Nix generations are not).
2. **Over-design.** New flags, environment variables or config keys added without
   a stated rejected default (AGENTS.md treats each as a setting); zero-caller
   functions (grep strings, `eval`, `declare -f` and dynamic names too; tests
   alone are not callers); same-body helpers `scripts/audit_function_duplication.py
   --list` misses because they are written differently; output lines that report
   routine skips. Existing flags are never proposed for removal without the
   maintainer.
3. **Stale.** Current-state claims in AGENTS.md and `.claude/rules/` (both branches), SYNC.md,
   `.claude/skills/**`, docs and README copies against the code: every test named
   as a lock exists (`grep -rn '@test "<name>"' tests` on main, `It '<name>'` in
   Pester on windows), versions, paths, make targets and commands still exist,
   comments naming removed functions. The "latest stable" and "not released"
   lines in SYNC.md on both branches go stale with every release; check them
   against `gh release list`, tag ancestry and delivery receipts first.
   Published metadata and source ancestry do not prove asset contents; mark
   package delivery unverified when receipts are missing. These files deliberately record removed and
   rejected things; read the context before calling a line stale.
4. **Performance.** Forks per item inside loops that scale with app or file count
   (`basename`, `tr`, `$(...)`, `stat` per entry), repeated `du` or `find` over the
   same root, `mdfind` / `system_profiler` / `pgrep` calls not shared within a run,
   unbounded waits, startup work on every command. Tie each to a count or a
   measured time, and check whether it is already cached, pooled or gated by a
   test such as `tests/core_performance.bats`.
5. **Not yet codified.** In the commit window: an area fixed twice, a behavior
   fix with no test touched, a lesson living only in memory, an issue reply or
   one commit message, a rule repeated in several places or grown more than 20% past the size recorded after
   its last compression (`references/rule-compression.md`), and
   fixes on one branch that SYNC.md should route to the other (a safety or
   correctness contract the other CLI shares) without a row there. A fix in
   the window for something a user or a published release met with no
   `docs/incidents.md` row is a finding, and so is a layer that keeps appearing
   in that table (three `unit` rows in a week mean the write-time sweeps are
   being skipped).

## Phase 3: Report

One merged report ranked by actual risk. Each row: branch, what, where,
evidence, smallest fix, and any product decision or authorization still needed.
Label findings reproduced, statically confirmed or unresolved, and name
uncovered modules or runtime boundaries. A helper reproduction does not prove
the full signed-app or deletion entrypoint is reachable. Routine repairs within
an authorized batch do not need a second approval. Verify the weakest high-severity claim yourself before
reporting it: read the code, or reproduce with a fixture `HOME` and
`MOLE_TEST_NO_AUTH=1`. End with what was checked and found fine, and the
questions only the maintainer can answer. Mole for Windows (the paid app) and
Mole Mac are out of scope here; note a cross-product item only as a SYNC.md
candidate.

When this skill's prompts (`references/prompts.md`) or the model running them
changed since the last run, rescore first: for each `docs/incidents.md` row,
check out `<Fixed>^` in a detached worktree and run the matching dimension's
prompt on the files the fix touched. Record in `docs/weekly-audit.md` how many
rows it found and which it missed, so a prompt change that loses recall shows
up before it is trusted on new code.

## Phase 4: Land what the maintainer approves

- Work on the existing `main` and `windows` branches under the current Git Safety
  contract. Synchronize first without discarding WIP, assign non-overlapping
  files, and let the main session integrate, commit and push the authorized scope.
  Do not require temporary branches, detached worktrees or draft PRs. Start each
  agent from the fix header in `references/prompts.md`. Do not put a fixture checkout you run Bats in under
  `/private/tmp`: `validate_path_for_deletion` allows that tree before
  `should_protect_path`, so sink tests there fail on clean code (the first run's
  agents each reported three such false reds). Run the full suite on the
  integrated branch state after confirming ownership of every changed file.
  Do not use unsettled edits from another session as evidence for this repair.
- Every behavior fix carries a test that fails on the old code (red-run by
  adding the test before the fix, or using an isolated source snapshot/overlay;
  never restore old source over another session's edits) and, when it states a new invariant,
  the AGENTS.md or `.claude/rules/` line on that branch.
- macOS: `./scripts/check.sh --no-format`, shellcheck on changed tests, then the
  full `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` on the integrated
  result before pushing `main`. Windows: `gofmt -l cmd`, `GOOS=windows go build
  ./cmd/...` locally, then native fixtures under both `powershell` and `pwsh`
  on an available Windows host or CI. A shared Go fixture, cross-build, native
  Pester run and package acceptance are separate evidence. Red-run before the
  fix locally where possible; otherwise use an isolated native snapshot.
  Do not require a public test-only PR. If a host is unavailable, report the
  missing layer. `mo update` follows the `windows` head for source installs,
  so PowerShell that has never run on Windows is not pushed for CI to judge:
  run both hosts on the VM, or on the ThinkPad when the VM's host is leased
  (the route is in the `windows` branch's `docs/development-pitfalls.md`),
  then push. Linux: the complete `bats tests/`, the Go tests and shellcheck on
  the devbox as the user `mole` before pushing `linux`. When the test reaches into a
  helper the fix introduced (Pester extracting a function from the script),
  restoring the old file fails the whole test file at discovery, which proves
  nothing; break only the judged condition in the new code instead and check
  that exactly that `It` fails. The first run's junction test was proven that
  way after the fact (draft PR #1754).
- Every fix diff that touches a deletion, privilege, install or update path gets
  a second review by an agent that sees only the diff, the requirement and the
  files to read, before it is pushed. On 2026-11-10 that review found the worst
  miss on each branch after the fixing agent's own tests were green: a
  `COREPACK_HOME=~/Documents` cache root on Linux, "changes nothing" snapshots
  that skipped every file on Windows, and a history condenser that disagreed
  with the old parser in GBK and Shift-JIS locales on macOS.
- Agent reports are leads. Before integration, read each agent's deviations from its
  brief and accept or undo each one, verify every "this does nothing" or "baseline
  already fails" claim yourself, and close each agent's "not done / outside my
  files" list in the integration commit. In the first run one agent called
  `opt_diag_memory_pressure` a no-op (it prints a warning) and three reported
  `/private/tmp` false reds as baseline failures.
- Items marked "needs maintainer: no" are fixed in the run that reports them once
  the maintainer approves the batch; only items waiting on a decision carry over in
  Open, each with the question it waits on.
- Commit identity and push follow the global Git Safety rules; contributor PRs
  keep their own review path.
- After pushing either branch, inspect required CI through structured status and
  conclusion at its exact remote SHA. Native fixtures supplement this check;
  cancelled or absent jobs do not count as passing.
- An approved rule compression or split follows `references/rule-compression.md`; its second-agent meaning
  review is part of the fix, since the mechanical gates passed while 73 real losses remained (2026-10-17).
- Prepend the run to `docs/weekly-audit.md` (audited and landed commits per
  branch, next window, rule volume, fixed / decided / open) in the last `main` commit of the
  run.

## Output

The report, then after landing: commits per branch, push status, worktree
leftovers, each finding's state (fixed and verified / decided not to fix with
reason / blocked and what is missing), and each branch's base commit for next
week's window, all also written to `docs/weekly-audit.md`.
