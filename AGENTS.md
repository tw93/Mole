# Mole Agent Guide

This file is the shared source of truth for any AI agent working on this repo (Claude Code, Codex, etc.). `CLAUDE.md` is a symlink to this file. Put machine-specific or personal overrides in `AGENTS.local.md` / `CLAUDE.local.md`; both are gitignored.

## Project

Mole is a macOS system cleanup and optimization tool with shell and Go components. It performs file cleanup, app protection checks, and maintenance tasks, so safety rules matter more than speed.

## Product Direction

Mole is a terminal-first macOS maintenance toolkit. Its core job is to help power users inspect reclaimable space, remove known-safe leftovers, uninstall apps safely, run bounded maintenance, and check health from a CLI, script, or compact TUI. It is not a general Mac control center, package manager, background monitor, or GUI feature mirror.

### What Mole Should Do

- Make cleanup and uninstall actions boring, reviewable, logged, protected by path/app rules, and dry-run capable.
- Prefer reversible user-facing removals through Trash where the command surface expects recoverability.
- Keep `clean`, `uninstall`, `purge`, and `installer` focused on reclaimable files, app leftovers, rebuildable caches, installer artifacts, and exact known cleanup targets.
- Keep `analyze` as a disk explorer and ad hoc cleanup surface. Optimize first paint, navigation, sorting, filtering, and safe deletion before adding dashboard-style features.
- Keep `status` as a compact read-only health dashboard plus stable JSON/NDJSON automation output. It may surface actionable signals, but should not become an iStat clone, alerting daemon, or configurable metrics workbench.
- Keep `optimize` focused on explicit, bounded maintenance tasks that can be explained before execution and tested without real authorization prompts.
- Keep command UX dense and terminal-native: short labels, stable alignment, predictable shortcuts, one-screen summaries, then optional drill-down.
- Keep Mole Mac references as a cross-link or support path. The CLI and Mac app can share product values without requiring feature parity.

### What Mole Should Not Do

- Do not add broad system modification, privacy reset, package management, app bundle patching, or device-management features just because they are technically possible.
- Do not remove or rewrite third-party app bundle contents, signed resources, user documents, credentials, sessions, active databases, or active developer-tool state.
- Do not add background agents, persistent monitoring, notifications, schedulers, menu bar behavior, or GUI-like state unless explicitly requested and justified as CLI scope.
- Do not broaden leftover matching from exact app or bundle evidence into vendor-wide, TeamID-prefix, generic-name, or fallback wildcard deletion.
- Do not turn `status` into a noisy dashboard. Extra rows, live alerts, and tuning controls need a common user action, not just an available metric.
- Do not add prompts, preferences, or output modes to solve every edge case. Prefer quieter defaults, preview/read-only guidance, or declining unsupported operations.
- Do not treat Mole Mac features as required CLI gaps. The CLI should stay narrower, scriptable, and safety-first when parity would add complexity or ambiguity.

### Product Decision Filter

Before accepting a new feature, answer these questions in the PR, issue, or review notes when the fit is not obvious:

1. Does it clearly belong to clean, uninstall, analyze, optimize, status, purge, history, installer, update, completion, touchid, or remove?
2. Is it safe by default, previewable where destructive, testable without real auth, and explainable in one terminal screen?
3. Can the user verify what will change before Mole changes it?
4. Is the target data locally rebuildable, disposable, or backed by exact app/bundle evidence?
5. Would this be better as Mole Mac UI, documentation, a warning, or an explicit "not supported" answer?

If the answer is no or unclear, decline the feature, narrow it, or park it until the product value beats the added surface area.

## Repository Map

- `AGENTS.md` is the cross-agent source of truth. `CLAUDE.md` must remain a symlink to it so Claude and Codex receive the same project contract.
- `.claude/skills/` is the canonical home for project skills. `.agents/skills/` contains relative symlinks for Codex discovery; do not maintain copied skill bodies.
- `.claude/agents/` contains focused Claude review profiles. They must read the current contract from this file instead of copying a frozen version of the safety or portability rules.
- `mole` - the CLI entrypoint. It is a **router only**: it parses args, renders the menu, and dispatches. Business logic does not belong here. Self-update lives in `lib/manage/update.sh` and self-removal in `lib/manage/remove.sh`; both are `source`d (not `exec`d) because the interactive menu and the update banner call them in-process. `VERSION=` stays in `mole` because `install.sh` reads it out of this file with `sed`.
- `lib/core/` - shared shell safety, UI, file operations, operation logs, app protection logic, and centralized timeout constants (`timeouts.sh`).
- `lib/core/app_protection_data.sh` - readonly bundle ID and pattern arrays consumed by `app_protection.sh`. Data only, no logic.
- `cmd/analyze/` - Go disk-analysis TUI. `main.go` is bootstrap only; `model.go` holds types and accessor methods; `update.go` holds the Bubble Tea Update chain.
- `lib/clean/purge_worktrees.sh` - git worktree policy for purge: registration discovery, the five reclaimability guards, the `is_safe_purge_worktree` revalidation gate, and the Trash-mode removal plus registry prune. Read it against the "worktree staleness is not decidable" rule below, which it is the answer to: purge's other targets are authorized by NAME (hence the nested-inside-a-project rule), while a worktree is authorized by its parent repo's `git worktree list` registration, so this file never consults the search-root depth rule. That rule rejects the direct children of a search root, where agent worktrees usually sit, and clears the deeper ones on depth alone, which proves nothing about a checkout, so neither verdict is usable here. Every guard proves a negative and any one of them keeps the worktree; the ignored-entry guard is the load-bearing one, because it is the whitelist check against `MOLE_PURGE_TARGETS` that separates a gitignored `.env` from a gitignored `node_modules`. Keep git calls read-only and wrapped in `run_with_timeout`, and fail closed when one errors or times out: a timed-out `git status` returns no output, which reads exactly like a clean tree.
- `tests/fuzz_corpus/` holds property-test corpora consumed by `path_validation_fuzz.bats`.
- `scripts/` - check, test, build, and release helpers. `audit_bundle_drift.sh` backs the monthly bundle audit; per-PR perf is covered by `tests/core_performance.bats`.
- `docs/SECURITY_DESIGN.md` - design doc for the path validation / app protection / # SAFE annotation contract.
- `SECURITY_AUDIT.md` - security review notes.

## Commands

```bash
./scripts/check.sh --format
MOLE_TEST_NO_AUTH=1 ./scripts/test.sh
MOLE_TEST_NO_AUTH=1 bats tests/clean_core.bats
MOLE_DRY_RUN=1 ./mole clean
MOLE_TEST_NO_AUTH=1 ./mole clean --dry-run
MOLE_TEST_NO_AUTH=1 ./mole purge --dry-run
MOLE_TEST_NO_AUTH=1 ./mole installer --dry-run
find bin lib -name '*.sh' -print0 | xargs -0 -n1 bash -n
make build
go test ./...
```

Public docs and examples should prefer the installed `mo` command. Use `./mole` in this repository when verifying source-tree behavior before installation. `analyze` and `analyse` are both accepted command spellings.

## Critical Safety Rules

- Route deletion through the safe helpers in `lib/core/file_ops.sh`. Raw `rm -rf` and `find -delete` are allowed only with a `# SAFE: <one-sentence reason>` annotation on the same line, which is the contract `docs/SECURITY_DESIGN.md` Layer 2 defines and `.github/workflows/test.yml` enforces by whitelist; nine call sites use it today for paths the function itself created. Do not route a mktemp scratch path through `mole_delete`: that adds Trash routing and an operation-log entry to a temp file.
- Use `mole_delete` from `lib/core/file_ops.sh` for removals so Trash routing, operation logs, dry-run behavior, and path protection stay consistent.
- Never modify protected paths such as `/System`, `/Library/Apple`, or `com.apple.*`.
- Route user-facing cleanup through Trash where the project expects recoverability, especially for analyze-driven ad hoc cleanup.
- Never let verification block on sudo, AppleScript, or macOS authorization prompts unless the task explicitly targets auth behavior.
- Use `MOLE_DRY_RUN=1` before destructive cleanup flows.
- Use `MOLE_TEST_NO_AUTH=1` for tests, manual repro, and verification unless real auth behavior is being tested.
- Any new direct use of `sudo`, `osascript`, or `launchctl` must have a `MOLE_TEST_MODE` / `MOLE_TEST_NO_AUTH` guard or be fully mocked in tests.
- Do not change ESC timeout behavior in `lib/core/ui.sh` unless explicitly requested.
- Preserve operation logging to the project log path unless the user explicitly asks to change `MO_NO_OPLOG` behavior.
- **AI-generated PRs touching destructive sinks need line-by-line review.** Any PR touching `find_app_files`, `mole_delete`, `remove_file_list`, Group Container / `~/Library/Containers` traversal, `TeamID.*.prefix*` style wildcards, or any `find` recursion that ends in deletion must be audited per branch (fallback branches often regress to broad globs even when the primary branch looks correct), per protected-path coverage (does `should_protect_path` already include the new entry point?), and per user-confirmation step (does the PR silently skip an existing prompt?). When the PR is plausibly AI-generated, raise the bar: ask the contributor to narrow matchers to the exact bundle ID or app path before merge; do not approve "this looks fine." PR #874 (Group Container + diagnostic discovery) and PR #875 (interactive file selector) were merged and then reverted (`6ea1987`, `b4e9205`) precisely because a TeamID-prefix wildcard in a fallback branch matched far more than intended. Same shape, same revert risk.

## Working Rules

- Use helpers from `lib/core/file_ops.sh` for deletion logic.
- Check `should_protect_path()` before adding cleanup behavior.
- Check app protection helpers before adding app cache, uninstall, or leftover cleanup behavior.
- Keep AI-tool cache cleanup conservative. Claude Code, opencode, Copilot CLI, Zed, Warp, Ghostty, and similar developer tools may have active versions, config, credentials, or session state that must not be removed accidentally.
- Do not clean tiny macOS UI state just because it is rebuildable. Wallpaper previews, preference thumbnails, and similar cover/state caches can create visible blank or cloud-download UI while reclaiming only a few MB; keep them unless there is strong user value and a regression test.
- Homebrew cleanup must be preview-first. Show the exact `brew autoremove` candidates before removal, preserve dry-run behavior, and keep tests on mocked `brew`; do not let a cleanup path execute real package-manager removals in verification.
- Sudo gates must not treat typed password characters as "skip". Only an explicit skip key should skip privileged cleanup; direct typed input must proceed into the real sudo prompt and have a regression test.
- Long cleanup scans need both an overall wall-clock budget and inner-loop checkpoints. If a project/artifact scan times out, degrade to partial or skipped-slow-scan output instead of appearing hung.
- System-service orphan scans must parse plist `Program` / `ProgramArguments` values as absolute paths only. Use non-interactive sudo for unreadable root-owned plists when needed, reject PlistBuddy error text as data, and keep CI tests on `/Library/LaunchDaemons` rather than relying on `/Library/PrivilegedHelperTools`.
- Uninstall leftover expansion must stay exact and boring: bundle ID or app-name variants only, reject generic/common words, keep short-name floors, skip broad locations like `Preferences/ByHost`, and only remove helper remnants after the parent app is confirmed gone and protected-path checks pass.
- Any new uninstall teardown path (launch services, login items, cask zap, helper bootout) must route through the shared-bundle-id sibling guard, covering `/Volumes` copies, inverse-name, and shared-identity variants, with a bats regression per variant. Five consecutive fixes converged on this invariant in 2026-06/07; do not add a teardown branch that bypasses the guard.
- Preference repair and optimize cleanup must skip protected and whitelisted plists before attempting removal.
- **Git worktree staleness is not decidable; do not build a feature that claims it is.** Clean the rebuildable artifacts inside a worktree, never the worktree itself. Four measured reasons, each reproducible with the commands named here. (1) Git's own expiry covers only registrations whose directory is already gone: `git worktree prune --expire` ignores live worktrees, so it reclaims zero bytes. (2) The industry heuristic (branch merged, remote branch deleted) does not apply, because agent-created worktrees are detached HEAD; 12 of 14 were on a sampled dev machine. (3) `git status --porcelain` reports a worktree holding a gitignored `.env` as clean, so a "clean plus old" rule deletes the only copy of a secret; only `--ignored` reveals it, and nothing can separate a `.env` from a `node_modules` automatically except an explicit whitelist check against `MOLE_PURGE_TARGETS`. (4) `git log --branches --not --remotes` misses unpushed commits sitting on a detached HEAD; the per-worktree form is `git log HEAD --not --remotes`. Sampling a heavy agent user found 215.6G of worktrees of which 168.7G (78%) was rebuildable artifacts and only 46.9G was checkout content, so the artifact side carries the value and needs no staleness proof at all. If a worktree state column is ever added, report blockers only (dirty, unpushed, locked, ignored entries outside the purge whitelist) and never emit a "safe to delete" verdict: the negative is provable, the positive is not.
- Purge discovery cannot see dot-directory containers. `discover_project_dirs` globs `"$HOME"/*/`, which skips dot directories, and `is_project_container` returns 1 for any basename starting with a dot, so a container like `~/.codex/worktrees` must be listed explicitly in `MOLE_PURGE_DEFAULT_SEARCH_PATHS`. Add exact container paths only; widening discovery to dot directories in general would pull in `~/Library` and similar. The scan layer needs no change: fd runs with `--hidden` and the find branch does not prune dot directories, so `<project>/.claude/worktrees` is already reachable once its parent container is discovered. Separately, `is_project_container "$dir" 2` probes only two levels, so a container whose project roots sit deeper (Conductor-style `~/conductor/<repo>/<workspace>/`) is still missed by design.
- Keep shell code formatted with `./scripts/check.sh --format`.
- Prefer targeted Bats tests during development; run the full suite before committing.
- Do not add AI attribution trailers to commits.
- `start_section` / `end_section` / `note_activity` have three intentionally different implementations in `lib/core/base.sh`, `bin/clean.sh`, and `bin/purge.sh`. Source order decides which one wins, and the wording, color, and dry-run export semantics differ on purpose. Read the cross-reference comment in `lib/core/base.sh` before changing any of them.
- **Test-orphan pattern: grep the whole repo including top-level entry scripts before declaring a function dead.** Mole has a recurring shape where a helper is defined in `lib/core/base.sh` (or similar core lib), has full bats coverage in `tests/`, and is referenced by zero production callers. Past instances, all since removed from the repo: `is_sip_enabled`, `is_darwin_ge`, `get_invoking_user`, `get_brand_name`, `get_mole_temp_root`, `scan_external_volumes`, `clean_dev_editors`, `perform_updates`, `format_brew_update_label`, `brew_has_outdated`. A "zero callers" verdict requires three checks: (1) grep across `lib`, `bin`, `cmd`, `scripts`, `tests`, AND the top-level entry (`mole` shim, install/uninstall scripts), not just core lib dirs; (2) check for string-built call sites (`eval`, `declare -f`, `compgen`); (3) re-grep after removal to confirm nothing was hand-wired. When deleting a write-only helper, also trace every variable it wrote and every config it read; the entire data path may be orphaned. Sub-agent "dead code" reports are starting points, not verdicts.

## Hotspot Ownership

These files are intentionally large. Do not start by splitting them. Keep edits narrow, preserve local safety boundaries, and run the listed tests when touching each area.

- `lib/clean/user.sh` owns user-level cleanup flows, browser caches, cloud/app support cleanup, device firmware, and Apple Silicon caches. Run `MOLE_TEST_NO_AUTH=1 bats tests/clean_user_core.bats tests/clean_browser_versions.bats tests/clean_app_caches.bats tests/clean_cached_device_firmware.bats` when touching this area, or `MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` if behavior crosses sections. Chrome / Edge / Brave old-version cleanup is one table-driven helper (`_clean_chromium_old_versions`) plus three thin public wrappers; the wrapper names are the test surface, so keep them. `clean_edge_updater_old_versions` is deliberately NOT part of it: it prunes staged updater payloads strictly older than the installed Edge (falling back to keep-latest by `sort -V` when the installed version is unreadable), has no `Current` symlink, and never escalates to a sudo removal, so folding it in would silently change its semantics.
- `lib/core/app_protection.sh` owns uninstall/data/path protection policy and bundle matching; `lib/core/app_protection_data.sh` owns the protected app category lists. Run `MOLE_TEST_NO_AUTH=1 bats tests/uninstall_safety.bats tests/uninstall_naming_variants.bats tests/bundle_resolver.bats`.
- `lib/clean/project.sh` owns purge discovery, project artifact filtering, purge menus, and purge config; git worktree policy lives in `lib/clean/purge_worktrees.sh`, and the two delete branches in `clean_project_artifacts` must each keep their own last-mile revalidation (`is_safe_configured_purge_artifact` for named artifacts, `is_safe_purge_worktree` for worktrees). Worktrees stay out of the non-interactive auto-selection on purpose. Run `MOLE_TEST_NO_AUTH=1 bats tests/purge.bats tests/purge_config_paths.bats`.
- `bin/uninstall.sh` owns uninstall command orchestration, app inventory, metadata refresh, and list/json output. Run `MOLE_TEST_NO_AUTH=1 bats tests/uninstall.bats tests/uninstall_scan_bash32.bats`.
- `lib/uninstall/batch.sh` owns batch uninstall execution, the shared-bundle-id sibling guard, launch service and login item teardown, and brew cask removal routing. Run `MOLE_TEST_NO_AUTH=1 bats tests/uninstall.bats tests/brew_uninstall.bats tests/uninstall_remove_file_list.bats`.
- `lib/clean/dev.sh` owns developer-tool cleanup, language/toolchain caches, AI agent caches, and Codex runtime handling. Run `MOLE_TEST_NO_AUTH=1 bats tests/clean_dev_caches.bats tests/dev_extended.bats`.
- `lib/optimize/tasks.sh` owns optimize task registration and system maintenance actions. Run `MOLE_TEST_NO_AUTH=1 bats tests/optimize.bats tests/optimize_db.bats`.
- `bin/clean.sh` owns clean command orchestration, section output, and safe cleanup execution. Run `MOLE_TEST_NO_AUTH=1 bats tests/clean_core.bats tests/clean_apps.bats tests/cli.bats`. Section output follows one fixed rhythm: title → loading state → content → one trailing blank line, for every section. When touching any step of it, re-run the command and read the whole rendered output (column alignment, block spacing, icon consistency) instead of patching the one step that was reported.
- `cmd/analyze/update.go` owns the Bubble Tea `Update` chain and message handlers (Init, scanCmd, updateKey, goBack, switchToOverviewMode, enterSelectedDir). This is the largest file in `cmd/analyze/` and the natural landing spot for new key bindings, message types, or navigation behavior. Run `go test ./cmd/analyze`. `cmd/analyze/main.go` is bootstrap only (flag parsing, `main()`, helpers); `cmd/analyze/model.go` holds types and the model struct.
- `cmd/analyze/analyze_test.go` and `cmd/status/view_test.go` are test hotspots. Add new cases near related behavior; split later only when touching many adjacent cases. Run `go test ./cmd/...`.
- `lib/core/file_ops.sh` owns the deletion funnel, Trash/permanent routing, operation-log outcomes, size accounting, and last-mile path validation. `lib/core/base.sh` owns shared shell primitives and source-order-sensitive section helpers. Keep policy in the existing protection helpers rather than adding a second delete path. Run `MOLE_TEST_NO_AUTH=1 bats tests/file_ops_mole_delete.bats tests/file_ops_size.bats tests/file_ops_safe_remove_symlink.bats tests/user_file_ops.bats tests/core_safe_functions.bats`.
- `cmd/analyze/scanner.go` owns disk traversal, Spotlight integration, cancellation, and all scan concurrency budgets. Treat its semaphores as independent resource limits and measure before changing them. Run `go test ./cmd/analyze`.
- `lib/clean/apps.sh` owns application-data cleanup, orphan service discovery, and the narrow verified-container-stub exception. `lib/clean/hints.sh` is read-only guidance and must stay bounded, timeout-aware, and non-destructive. Run `MOLE_TEST_NO_AUTH=1 bats tests/clean_apps.bats tests/clean_hints.bats`.
- `lib/ui/menu_paginated.sh` owns the shared Bash 3.2-compatible selection UI and terminal restoration. Preserve trap chaining, TTY restoration, and empty-selection behavior. Run `MOLE_TEST_NO_AUTH=1 bats tests/menu_trap_restore.bats tests/uninstall.bats`.
- `cmd/status/view.go` owns status rendering only; collection and JSON/NDJSON contracts live elsewhere in `cmd/status/`. Keep narrow-terminal layout and automation output independent. Run `go test ./cmd/status` and `MOLE_TEST_NO_AUTH=1 bats tests/cli.bats` when command routing changes.
- `bin/installer.sh` owns installer discovery, immutable delete-plan validation, the paginated selection flow, and incomplete-cleanup exit semantics. Run `MOLE_TEST_NO_AUTH=1 bats tests/installer.bats tests/installer_fd.bats tests/installer_zip.bats`.

## Verification

- Shell changes: run `./scripts/check.sh --format`, then the relevant Bats test or `MOLE_TEST_NO_AUTH=1 ./scripts/test.sh`.
- Go changes: run `go test ./...`.
- Cleanup behavior: verify with dry-run or test mode first.
- File operation changes: run `MOLE_TEST_NO_AUTH=1 bats tests/file_ops_mole_delete.bats tests/user_file_ops.bats`.
- Installer changes: run `MOLE_TEST_NO_AUTH=1 bats tests/installer.bats tests/installer_fd.bats tests/installer_zip.bats`.
- Purge changes: run `MOLE_TEST_NO_AUTH=1 bats tests/purge.bats tests/purge_config_paths.bats`.
- Whitelist or management changes: run `MOLE_TEST_NO_AUTH=1 bats tests/manage_whitelist.bats tests/manage_sudo.bats`.
- Uninstall changes: run `MOLE_TEST_NO_AUTH=1 bats tests/uninstall.bats tests/uninstall_remove_file_list.bats`.
- Documentation-only changes: check links and commands.

`make check`, `make format`, `make test`, `make test-go`, and `make verify` are wrappers around the scripts above. `make verify` intentionally runs `check` plus Go tests only; use the full Bats suite before risky cleanup, uninstall, or release work.

If `golangci-lint` reports issues from deleted temporary worktrees or non-existent paths, clear its local cache and rerun the linter:

```bash
golangci-lint cache clean
golangci-lint run ./cmd/...
```

## GitHub Operations

- Re-read the live issue or PR title, body, comments, state, labels, and author language before any public reply or closeout.
- Keep CLI issues and Mole Mac app issues separate. A fix in `mole-mac` does not imply a close in this CLI repo, and a CLI fix does not prove a Mac app issue is fixed unless the Mac app release path is verified.
- When closing a fixed bug or shipped feature, use project wording from the issue context and include the expected release path only when confirmed.
- **Remote diagnostics for unreproducible reports**: when an issue needs runtime evidence from the reporter's machine, ask them to run `curl -fsSL 'https://mole.fit/downloads/Mole-Diagnose.command' | bash` and email the resulting `Mole-Diagnose-*.zip` from their Desktop to the support address. The script is read-only (process samples, recent logs, crash reports) and lives in the `mole-mac` repo at `site/downloads/Mole-Diagnose.command`; it targets the Mole Mac app, so for CLI-only issues prefer asking for the relevant `mo` command output or `mo status` JSON instead. The zip contains local paths and logs: have reporters email it, never attach it to a public issue.
- **Default issue closeout pipeline** once a fix is confirmed: commit lands on `main` (that alone makes it installable via nightly), verify the fix is actually on `main`, then reply in the reporter's language, opening with `@reporter`, in short paragraphs rather than one block, with the concrete update command: `mo update --nightly` now, the next stable release only when that path is confirmed. Closing is the maintainer's call: propose the close and wait for confirmation, and the closing comment should invite reopening if the problem persists.

## Release

Tag-driven flow via `release.yml` on capital-`V` tag pushes. The full release runbook (distribution channels, pre-flight checklist, tag/publish commands, curated notes handoff, release-only pitfalls) lives in `.claude/skills/release-flow/SKILL.md`; read it before starting any release-flavored task. Notes formatting stays owned by `.claude/skills/release-notes/SKILL.md`. One rule that always applies: restate which distribution channels a release-flavored run will touch and confirm with the maintainer before acting; channel scope is specified by the maintainer, never inferred.

## Shell and Test Pitfalls (cumulative)

These are real bugs hit on this codebase. Each one cost time. Re-read before touching the same area.

- **`BASH_SOURCE` / `$0` change meaning when a function moves files**: they name the file the code *lives in*, so a pure copy-paste extraction is not behavior-preserving. `resolve_mole_source_path` read `${BASH_SOURCE[0]:-$0}` to find the invoked `mole`; once it moved into the sourced `lib/manage/update.sh`, it resolved to that lib file, so self-update would have reinstalled over the wrong target. Fix: `mole` captures `MOLE_ENTRY_SCRIPT="${BASH_SOURCE[0]}"` before sourcing anything, and the update flow reads that. Caught by `tests/update.bats` ("targets the invoked manual install"). Before extracting any function, grep it for `BASH_SOURCE`, `$0`, and `FUNCNAME`.
- **Every `du -s` must run under `run_with_timeout`**: `du` has no internal bound, and callers wrap it in a command substitution that simply waits, so one stalled SMB/FUSE mount or one enormous tree wedges the whole scan. Use `MOLE_TIMEOUT_DISK_VERIFY_SEC`. A source-invariant test in `tests/core_timeout.bats` greps `lib/` and `bin/` and fails on any unbounded `du -s`, so a new sizing call site cannot regress this silently.
- **bash 3.2 nounset on empty arrays**: macOS default bash raises "unbound variable" when expanding `"${arr[@]}"` on an empty array under `set -u`. Always guard with `[[ ${#arr[@]} -gt 0 ]]` before expansion. Hit for `DEFAULT_OPTIMIZE_WHITELIST_PATTERNS`, declared in `lib/core/base.sh` and consumed in `lib/manage/whitelist.sh`, which already guards it.
- **`fn || handler` disables errexit inside `fn` for its entire body**: same bash rule as if-guards, but on a whole function it silently converts every unchecked failure inside into a no-op. `install_files || {...}` in the update flow let eight consecutive uncached `sudo -n` copies fail while the installer still reported success, leaving `/usr/local/bin/mole` at 1.45.0 with a 1.47.0 payload ("Updated to latest version, 1.45.0"). Safety-critical steps inside any function that a caller might invoke with `||` or `if` must use explicit `if ! cmd; then return 1; fi` checks, never rely on `set -e`; and installers must verify the installed version matches the just-installed source before claiming success. Fixed in `install.sh` for V1.47.1; regression tests in `tests/install_checksum.bats` reproduce the exact `|| caller` shape.
- **`[[ -n "$var" ]] && cmd` returns 1 when var is empty**: under `set -e` (or any caller that reads the exit code), this short-circuit form propagates exit 1 from the test, even though the intent was "skip silently". If the surrounding compound command relies on exit 0 (for example a `{...} > file ||` redirect), the optional cmd silently breaks the success path. Use plain `if/fi` whenever the conditional sits inside an exit-code-sensitive block. Hit in `install.sh` `write_install_channel_metadata` (stable channel always tripped the warning).
- **bats heredoc steals bytes from `read -n1`**: when the inner script runs via `bash <<'EOF' ... EOF`, a `read -r -s -n1` in the function under test consumes the next byte from the heredoc source itself, corrupting the next command (e.g. `echo` becomes `cho`, exit 127). Fix is to redirect the function's stdin from `/dev/null` inside the test.
- **`script -q /dev/null` dies when stdin is a socket**: macOS script(1) only falls back to a plain pipe when its `tcgetattr`/`ioctl` probe fails with `ENOTTY`; a socket returns `ENOTSUP`, so it exits 1 with "tcgetattr/ioctl: Operation not supported on socket" and never starts the child. A PTY-based bats helper must redirect stdin from `/dev/null` (the child still gets the allocated pty, so `[[ -t 0 ]]` stays true). Without it the harness silently runs nothing and any assertion that only checks for absence passes vacuously. Fixed in `_run_in_pty` in `tests/purge.bats`.
- **`run_with_timeout` execs the binary, bypassing bash function mocks**: gtimeout/timeout exec the real PATH binary, so a shell-function override of (e.g.) `osascript` is invisible. Tests must use a PATH stub directory and prepend it to `PATH`, not function shadowing.
- **CI runners lack `/Library/PrivilegedHelperTools`**: `clean_orphaned_system_services` guards that scan with `[[ -d /Library/PrivilegedHelperTools ]]`, which is false on GitHub macOS runners, so a test that feeds an orphan helper through that path finds zero orphans in CI even though it passes locally (the dir exists on dev machines). Route orphan-service tests through `/Library/LaunchDaemons`, which always exists on macOS. Hit fixing #1082.
- **A test can pass vacuously when the function early-returns**: `clean_apps.bats` `setup_file` exports `MOLE_TEST_MODE=1`, and `clean_orphaned_system_services` returns immediately under that flag, leaving `$output` empty. A test whose *last* assertion is a `[[ "$output" != *"..."* ]]` (true on empty) then passes green while its real `==` assertion in the middle is silently swallowed (same shape as #886). Always end each assertion with `|| return 1`, and override `MOLE_TEST_MODE=0` (plus a `sudo -n true` mock) when the test needs the function body to actually run.
- **BSD grep has no GNU `-Z`/`--null` output mode**: on stock macOS `grep -Z` means `--decompress` (ugrep aliases treat it as fuzzy matching), so `grep -rlZ ... | while read -d ''` consumes nothing and the loop is silently dead. Enumerate with `find ... -print0` and probe each file with `grep -qF` instead. The path-referenced LaunchAgent unload in `stop_launch_services` shipped dead this way from #816 until 2026-07.
- **PlistBuddy announces file creation on stdout**: `/usr/libexec/PlistBuddy -c "Add ..."` against a missing file prints `File Doesn't Exist, Will Create: <path>` to stdout, which lands in bats `$output` and trips negative `[[ "$output" != *"<name>"* ]]` assertions. Redirect stdout too (`> /dev/null 2>&1`) when creating plist fixtures.
- **macOS 14's /bin/bash fires errexit through if-guarded mock functions**: the macos-14 runner's bash 3.2.57 build kills a `set -e` script when an exported shell-function `sudo` mock returns nonzero inside an `if fn; then` condition with a `2> /dev/null` redirect; the same bash version on macOS 15+ and dev machines does not, so the failure reproduces on no local machine. Symptom: a bats inner script exits 1 with empty output at the first failing mock probe. Fix pattern: disable errexit before the first sudo probe inside the helper (see `safe_sudo_find_delete`) and restore it before each validation-gate return. When a test fails only on one runner image, make the test print exit status, captured output, and a mock call trace on failure instead of a bare rc assertion; that evidence trail is how this one was pinned. Hit fixing test 31 of `core_safe_functions.bats`, 2026-07.
