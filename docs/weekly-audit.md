# Weekly Audit Log

One entry per run of `.claude/skills/weekly-audit`, newest first, covering Mole CLI (macOS) on `main` and Mole CLI (Windows) on `windows`. The next run reads the newest entry for its commit window (`Next window from`), for the items it must not report again (`Decided, do not re-report`), and rechecks `Open` first. Facts here are a run record; lasting invariants live in `AGENTS.md` on each branch.

## 2026-10-18 (dual CLI post-release audit)

- Frozen source: main `3041d86c`, windows `7b2da730`, both clean and matching their remote heads. Release comparison: `V1.61.0` and `V1.36.0-windows`. Both desktop apps were outside this review.
- Source repairs pushed through: main `8b49a13a`, windows `9b010223`; the initial delivery heads were `7ef8e8f0` and `eccdbb8c`.
- Next window from: main `8b49a13a`, windows `9b010223`.

### Fixed and verified

| Branch | Finding | Commit | Regression surface |
| --- | --- | --- | --- |
| windows | Canonical whitelist aliases misaligned parallel rule metadata, missing later rules or indexing past the list | `d44b1e70` | `tests/CleanupBoundary.Tests.ps1`, mixed rules through `Remove-SafeItem` |
| main | Completion normalization and self-removal could erase user commands that merely mention completion | `332d879f` | `tests/completion.bats`, `tests/uninstall.bats`, byte-preserved quoted and mixed commands |
| main | Failed owner-root discovery could still authorize cache mutation; Conda omitted configured package roots | `e9fbcf8e` | `tests/clean_dev_caches.bats`, uv/npm/pip/mise discovery failures and every Conda `pkgs_dirs` entry |
| main | Delayed same-path scans and cached results could replace newer Analyze requests | `8f2671cd` | `cmd/analyze/analyze_test.go`, pre-dispatch cancellation, fresh/bypass scans and cached results |
| both | E2E `--keep-going` bypassed failed prerequisites | `8b49a13a`, `9b010223` | `tests/e2e_harness_test.py` on each branch, integrity rejection and dependent-action assertions |
| windows | E2E combined committed PowerShell with Go built from the dirty checkout | `9b010223` | Frozen-commit archive and build-cwd provenance assertions |
| windows | The canonical-path comment incorrectly attributed existing 8.3/trailing-dot normalization to the handle resolver | `d44b1e70` | Corrected to distinguish `GetFullPath` normalization from junction/symlink resolution |

Sibling review covered ten owner-cache consumer families, changing five; Corepack, pnpm, Nix, GitHub CLI and Go had no matching failed-query/default-root authorization path. Completion uses the shared pattern at five rewrite sites. The Windows whitelist review checked five association sites and changed only the constructor. Analyze review covered seven dispatch entrypoints and all three scan APIs, including ordinary, stale and warmed cache paths; the Windows request lifecycle was already correct.

Local verification: `check.sh --format`, `check.sh --no-format`, and the complete `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` all exited 0; the runner reported `All tests passed!`, including Go and isolated installation checks. Targeted Analyze race tests passed. Mocked E2E suites passed 5 macOS and 9 Windows tests; workflow syntax and the Windows cross-build passed. Red runs exercised the old implementations for the repaired ownership, scan identity, whitelist and E2E failures. Windows native receipts are in `docs/development-record.md` on `windows`: both PowerShell hosts passed 37 CleanupBoundary tests, and each full suite reported 514 passed, 2 failed, 0 skipped. The two failures require symbolic-link privilege and reproduced on the original HEAD before product assertions; they are not recorded as passing.

### Codified and simplified

- Existing area rules now lock complete owner-root evidence, every Conda root, pre-dispatch scan identity, cached-result identity, recent-directory mtime invalidation, and E2E prerequisite/provenance checks. Windows `AGENTS.md` and `docs/development-pitfalls.md` retain canonical rule associations and empty/single/multiple-result boundaries.
- `install-update.md` merges two overlapping shell-integration bullets into one; zero effective constraints were deleted. Independent semantic review preserved rc paths, full symlink chains, target mode, Fish files, dry-run, all log categories, failure exits and existing test locks. The intentional ownership correction is matching whole generated lines rather than mentions. The file changed from 10,340 to 10,353 bytes and 1,413 to 1,399 words; new regression anchors account for the byte increase. Frontmatter is unchanged. AGENTS.md plus area rules total 108,264 bytes, below the 20% trigger from the 99,723-byte split baseline.
- The existing Windows CLI-SYNC-04 entry owns the Analyze backport; CLI-SYNC-02 records the whitelist follow-up. Source implementation is separate from release delivery.

### Decided, do not re-report

- Keep existing features, flags and safety checks; this review found no evidence that restoring previously removed dead helpers would improve behavior. No new product flag or dependency was added.
- Keep the current explicit media-selection boundary; CLI-SYNC-09 remains the owner of the broader recording-policy decision. The prior DeviceSupport menu, memory-pressure helper and dry-run logging decisions remain unchanged.
- Canonical-path probing stays despite its measured cost because junction and symlink protection consumes it. Consolidating a duplicated rule does not authorize removing its constraints.

### Open

- The source-push blocker is closed. After two SSH closures, the maintainer authorized resumption on 2026-10-18; both branches pushed successfully and remote SHAs matched the initial delivery heads above. CI is a separate gate checked at the final pushed heads, including the two privilege-limited Windows fixtures. No tag, package, release, real application E2E or user-data cleanup was performed.

## 2026-10-17 (review remediation, not a weekly run)

- Audited read-only: main `d7980364`, windows `78e537bb`. Landed through: main `7f09d2a4`, windows `4fa94339`.
- Next window from: main `7f09d2a4`, windows `4fa94339`.
- Fixed: executable-name probes now escape ERE metacharacters before every `pgrep`/`pkill` (`7c2713c7`, `tests/uninstall_process_pattern.bats`); broken-preference repair lints through `/usr/bin/plutil` and retains unreadable plists instead of permanently deleting them (`f7916075`); `mo clean --external` keeps a volume Trash and the Finder-metadata row now covers AppleDouble `._*` (`4285c82f`); wrong UTM bundle id corrected (`87a50062`); `MOLE_TEST_TRASH_DIR` requires a test flag (`e51c32ae`); installer reports a conflicting Homebrew Mole instead of uninstalling it and caches release checksums/attestation per tag (`49a138cd`); `mo remove` clears shell completion, names failed paths and exits nonzero, and by-name uninstall asks once, and the batch preview/summary names are terminal-safe (`8bba89b8`, `81aa95f1`); `mo status` reads one diskutil plist per volume and CloudStorage roots are prechecked (`8ee1d254`); READMEs and SECURITY_DESIGN now state the real Trash routing (`db412b36`, `697be923`); CI runs the fd installer suite, serializes the three flaky suites, tightens child-shell perf budgets, and macOS/Windows release gates preflight the tag and required runs (`47636abb`, `f770a926`, `f7d5368f`); Windows protected paths resolve existing 8.3/trailing-dot aliases, scans are bounded, and `mo remove` drops the cache (`901ce2d4`); Windows README/SYNC/TRADEMARK corrected (`8adda1f2`).
- Post-review fixes (same day, after `ed594a28`): non-interactive `mo uninstall` now refuses a missing terminal instead of confirming, the release preflight allows docs-only commits to lack CodeQL/Nix and every required workflow accepts `workflow_dispatch`, the release-tag ruleset has a repository-admin bypass for recovery, Windows keeps whitelisted junction roots protected and logs cache removal, the completion regex needs a command boundary, multi-level rc symlink chains survive `mo remove`, rc/fish/cache removals write operations.log rows, and the `get_file_size` budget is 400ms local / 600ms CI. Windows `update.ps1` no longer says only source installs can update and then suggest a ZIP. Tests: `tests/uninstall_review.bats`, `tests/uninstall.bats`, `tests/core_performance.bats`, Windows Pester junction/cache cases; CI green on `5f7d50b5` and `d3976cc2` (a later `TestDrive` teardown artifact in the first Windows run was fixed in `d3976cc2`).
- Third-pass fixes after the next review: non-interactive refusal now exits 1 with a next step, only `MOLE_TEST_MODE` may pipe the confirmation, and the docs-only release exemption requires green CodeQL/Nix on the nearest code-changing ancestor; `mo completion` preserves rc symlink chains; launcher removals write operations.log; `get_file_size` is compared with its stat reference so one added fork is caught; Windows `Test-SafePath` reuses the resolved path and adds a junction-to-protected test plus an incomplete-scan caller test. Landed through main `aac88e4a`, windows `7960f39c`.
- Fourth-pass fixes: `mo completion` and `mo remove` share one completion-line pattern and one rc link resolver in `lib/core/base.sh`, so the "already installed" check no longer takes `gizmo completion` for Mole and an unresolvable rc link names the file (`fb0d658d`, `tests/completion.bats`); the docs-only release preflight walks past `[skip ci]` contributors commits to the real code ancestor (`7f09d2a4`, stub-`gh` checked for inherited green, ancestor Nix failure, failed run listing and code targets); Windows `Test-SafePath` judges the typed spelling against the protected rules too and checks an unlinked path once (`4fa94339`). Windows 11 VM, PowerShell 5.1 and pwsh 7: 496 Pester cases pass outside `UI.Tests.ps1` with the 2 known non-admin symlink failures, the new linked-segment case fails on `7960f39c`, the 8.3 and trailing-dot cases also pass on `78e537bb` (so `GetFullPath` already covered them; AGENTS.md corrected), and 1500 `Test-SafePath` calls take 1.54s/1.01s against 2.06s/1.27s before this pass and 0.51s/0.76s on `78e537bb`.
- Deferred: `docs/img/big-mole.png` is a collage of real cleanup results whose summary wording predates the current `Cleanup complete` output, so refreshing it needs new real screenshots rather than a generated image; Homebrew `info --cask` prefetch stays because the #1558 timeout/cancellation contract requires the batch probe; `install.ps1 -Uninstall` now removes `~\.cache\mole` like `mo remove` (windows `bcf0b7a4`); rulesets protect branch deletion/force-push and `V*` tag update/deletion, and required status checks stay off because the maintainer and the contributors bot push to `main` directly and the bot's `[skip ci]` commits would never satisfy them, while the release preflight already requires the checks on the tagged commit; `Test-SafePath` stays about 2x slower than `78e537bb` because every existing path now gets one final-path handle probe, which the link and alias protection needs.
- Rule volume after this batch: AGENTS.md 31,054 bytes, AGENTS.md plus `.claude/rules` 103,829 bytes (+4,106 over the 2026-10-17 split baseline, below the 20% trigger).

## 2026-10-17 (rule split, not a weekly run)

- Next window from: unchanged, main `e78caf97` and windows `9bbebb89` from the 2026-10-16 entry below.
- `cb32af9f` moved area sections of AGENTS.md (89.7 KB to 30.5 KB) into 12 path rules. A second-agent review found no lost sentence but six loading gaps, fixed in `d531a0c4`: `github.md` was read only at reply time, after a fix already existed, and three rules sat under globs that miss their code.
- Rule volume after the split, the baseline for the 20% trigger in `.claude/skills/weekly-audit/references/rule-compression.md` (bytes): AGENTS.md 30,745, `clean.md` 15,486, `uninstall.md` 10,140, `install-update.md` 7,979; AGENTS.md plus `.claude/rules` 99,723.

## 2026-10-16 (first run)

- Audited: main `eb531ba2`, windows `159657d5`.
- Landed through: main `e78caf97`, windows `9bbebb89` (PR #1751).
- Next window from: main `e78caf97`, windows `9bbebb89`.

### Fixed and verified

| Branch | Finding | Commit | Lock |
| --- | --- | --- | --- |
| main | `mo clean` ran `nix-collect-garbage --delete-older-than`, deleting profile and home-manager generations, with no timeout or owner-planned preview | `c0ea3d48` | `clean_dev_nix collects only unreachable store paths under a timeout` |
| main | Uninstall offered the whole `~/Library/Application Support/Steam` game library as one data row | `6c777967` | `uninstall never offers the Steam library root or anything inside it` |
| windows | `mo remove` recursed through a junction in the config folder into its target | `53b94f11` | `Unlinks a junction in the config folder and keeps its target's files` (CI only, see Open) |
| main | npm cache clean had no owner-command timeout | `22bb8a43` | `clean_dev_npm runs npm cache clean under the owner-command timeout` |
| main | macOS and xrOS DeviceSupport never pruned | `17c74457` | `clean covers every DeviceSupport platform the Xcode uninstall sweep knows` |
| main | Whitelisted Xcode cache entries counted as skipped protected | `ba08ab8f` | `... keeps whitelisted entries out of the skipped count` in `tests/dev_extended.bats` |
| main | `mo uninstall <name>` lowercased per app, `--list` ran `brew info` per cask, report and bundle scans forked per file | `3cc7aa86`, `107d4a83`, `07d78dea` | existing uninstall suites; 9.44 s to 0.059 s and 7.15 s to 2.68 s measured |
| windows | Validated trees walked twice to size | `7b92e1d9` | Windows CI |
| both | Thirteen undocumented tuning env vars on main, `MOLE_ANALYZE_LIVE_SORT` on windows | `654fcef4`, `165d79fd`, `ba791f85` | `removed tuning environment variables are not read again` |
| both | Dead helpers (4 on main, 32 on windows) and two Pester tests that could not fail | `885cb6e0`, `180b62f6`, `754fcb43`, `5904e4d5` | existing suites |
| both | Uncodified oplog contract, recognizer parity, dataless probing, launcher signal stories, nightly-verified issues; stale SYNC release lines, comments and unpinned actions | `5a210db4`, `b9223ebf`, `e78caf97`, `945adbea`, `003157c4` | AGENTS.md, SYNC.md |

### Decided, do not re-report

- macOS and xrOS DeviceSupport get no whitelist rows: only iOS has one, and watchOS, tvOS and visionOS have none either; adding all five clutters the menu.
- `opt_diag_memory_pressure` stays: it prints the memory pressure warning and top processes, so it is not a no-op (an agent claimed otherwise).
- Mole CLI (Windows) writes no operation-log rows in dry runs; recorded as an intentional difference in SYNC.md.
- Existing flags are never proposed for removal without the maintainer.

### Closed after the run (same day)

- windows: `Clear-TempFiles` had three callers but nothing ever registered a temp file, so it only emptied empty lists; removed with its exit event and the two finally blocks in `c6ce917e` (PR #1753).
- windows: the junction test in `53b94f11` is now proven. Restoring the pre-fix `install.ps1` only failed the file at discovery, because the test extracts the new `Remove-MoleConfigEntry`; disabling just its reparse-point branch failed `Unlinks a junction in the config folder and keeps its target's files` on both `powershell` and `pwsh` (draft PR #1754, closed).
- main: GNU coreutils or findutils first in `PATH` aborted `mo clean` (#1752) and silently misread mtimes elsewhere; every `stat` now goes through `$STAT_BSD`, BSD `date -r/-j` through `$_DATE_CMD`, purge's dataless probe and walks through `/usr/bin/find`, and Service Worker discovery uses `-mindepth/-maxdepth` (`c0705ac0`, `66bd98a3`). A source gate refuses new bare forms.
- main: `firmware guard detects a real open file and permits it after close` failed about half the time under the parallel suite because real lsof outlived the 2 s probe budget; the case now runs with 30 s (`420cb224`).
- main: a full run with Homebrew `coreutils findutils gnu-sed grep gawk` first in `PATH` (every command dry-run against the BSD baseline, then `scripts/test.sh` and `go test ./...`) found two continued-line `stat` calls, GNU find error quoting and a File Provider mount failure, byte-wise GNU `tr` case folding, `\-` regex escapes and GNU `du` lacking `-I`; all routed to the system binaries and both suites pass under that `PATH` (`d7e9f6fc`). The same run exposed that an unreadable AI agent versions folder cancelled every later developer cleanup (`5422a73d`).

### Open

- None.
