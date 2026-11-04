# Incidents

Defects that reached a user or a published release, kept as the eval set for every review layer ("incidents are the
eval", from the Claude Code team's code review write-up, 2026-10-26). A row is added in the same change that fixes
the defect: the fix commit, the commit that introduced it when known, the earliest layer that should have caught it,
and the test or gate that catches it now. `scripts/audit_incidents.py` (run by `scripts/check.sh` and the Security
Checks job) fails a row whose commit does not resolve, whose layer is not one of the names below, or whose catcher is
not defined in the code.

A catcher is written in backticks and is one of: the exact name of a Bats `@test` under `tests/`, a Go `Test*`
function in a `_test.go` file, a Python `test_*` function under `tests/` or `scripts/`, or the repository path of a
gate script (for example `scripts/audit_timeout_status.py`). A Bats name that holds a `|` cannot sit in this table;
rename the test.

Layers, earliest first:

- `write-time`: the author's own check before committing, a sweep of same-shape sites and the source gates, plus the
  `.githooks/pre-commit` hook.
- `check`: `./scripts/check.sh --no-format` (ShellCheck, golangci-lint, the `scripts/audit_*.py` gates), locally and
  in the Check workflow.
- `unit`: the Bats suite through `./scripts/test.sh` and `go test ./...`, locally and in the Validation workflow on
  macos-26.
- `compat`: the Validation workflow's macos-15 Bats subset, the only lane that sees another macOS
  version's tool output.
- `review`: a diff review, the line-by-line review AGENTS.md requires for destructive sinks, or the weekly audit.
- `e2e`: `scripts/e2e_macos.py` on a real Mac before a release.
- `release`: the release-flow pre-flight and `release.yml` (minimum-OS check, Nix, Homebrew).
- `field`: only a real user's machine, network or configuration shows it.

When a review skill, its prompt or the model running it changes, rerun it on the files each fix touched as they were
at `<Fixed>^` and record which rows it finds (`.claude/skills/weekly-audit`, Phase 3). `Introduced` is a commit only
when it was confirmed by reading the history, otherwise `unknown`.

## Incidents

| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |
|---|---|---|---|---|---|---|
| I-01 | 2026-09-20 | Editor obsolete-extension cleanup found nothing on macOS 15, and a nested `.obsolete` key could be offered as an extension directory | 6e70669f | 04cb4947 | compat | `only a root-level .obsolete key marks an extension, never a nested one (#1512)`, `a .obsolete value must be boolean true, not 1 or the string true (#1512)` |
| I-02 | 2026-10-05 | `mo clean` removed project caches that Git tracks, leaving deleted tracked files in the user's clones | unknown | d929d156 | review | `clean_project_caches keeps project caches that Git tracks` |
| I-03 | 2026-10-05 | `mo clean` removed the `~/Library/Logs/DiagnosticReports` directory itself, so macOS could no longer save crash reports | unknown | 4ab50c73 | unit | `clean_user_essentials keeps the DiagnosticReports directory (#1689)` |
| I-04 | 2026-10-18 | `mo update` aborted with a connection error when the GitHub API was rate limited, although install.sh and nightly updates fell back to git tags | unknown | 2e88f475 | review | `stable discovery falls back to git release tags when HTTP API lookups fail` |
| I-05 | 2026-10-18 | Incomplete browser downloads were never found when the home folder name contained a space | cfa0a820 | d822ad0b | unit | `incomplete downloads scan discovers files when HOME contains spaces` |
| I-06 | 2026-10-22 | A shell PATH without `/usr/sbin` read total memory as 0 and refused `mo slim` on Apple Silicon | unknown | b03c0f54 | write-time | `sysctl never resolves through PATH (#1804)`, `get_memory_info reads total memory without /usr/sbin in PATH (#1804)` |
| I-07 | 2026-10-22 | `mo purge` refused every item under a `/System/Volumes/Data` path listed in purge_paths as a critical system path | unknown | 70d320e1 | unit | `validate_path_for_deletion judges a Data volume path by the root path that reaches it (#1814)` |
| I-08 | 2026-10-23 | `mo touchid` reported Touch ID as enabled when the only `pam_tid.so` line was commented out | unknown | 69d2a3c7 | unit | `check_touchid_support ignores a commented-out pam_tid line (#1815)`, `touchid enables the line sudo_local.template ships commented out (#1815)` |
| I-09 | 2026-10-27 | `mo optimize` reported Network Cache Refresh as failed on every run on macOS 27, which refuses `launchctl kill` on mDNSResponder even to root (#1867) | fb920811 | 29b9699d | field | `DNS refresh reports a macOS-refused service signal as skipped without a name fallback` |
| I-10 | 2026-10-27 | Dry-run find scans sized and recorded each candidate twice and returned 1 when no preview ledger was set up (#1865) | 70eed1b0 | a703eddc | review | `safe_find_delete dry run records each target once without removal fallthrough (#1865)`, `safe_sudo_find_delete dry run records targets once and tracks count (#1865)` |
| I-11 | 2026-10-27 | `mo clean` removed installed npx packages while running commands still needed their resources and modules (#1870) | unknown | f954e2fd | unit | `clean_dev_npm preserves installed npx packages in default and custom caches (#1870)` |
| I-12 | 2026-10-30 | `mo purge --debug` kept every node_modules as "Could not inspect" and exited 1, because `run_with_timeout`'s debug notice landed in the captured lsof output; found by the V1.66.0 release e2e | unknown | e4686b6e | unit | `run_with_timeout keeps its debug notice out of captured command output`, `purge node project process check reads an idle project as idle under --debug` |
| I-13 | 2026-10-26 | Cleaning Kitty's graphics-protocol cache broke image transfers in a running terminal session (#1856) | unknown | e7b15113 | review | `a custom whitelist still protects system caches, Kitty, Poetry virtualenvs, the renv cache, pnpm dlx and llama.cpp models` |
| I-14 | 2026-10-26 | Users whose network needed the macOS system proxy did not receive background update notices because curl connected directly | unknown | 2748db02 | field | `background update lookup waits longer and follows the system proxy while foreground lookups do not` |
| I-15 | 2026-10-26 | Old flat Analyze cache files remained for users who no longer ran Analyze, and a large accumulated directory froze tools that listed it | unknown | a152d651 | review | `legacy analyzer cache sweep removes only flat analyzer files from ~/.cache/mole`, `legacy analyzer cache sweep skips dry runs and a symlinked cache root`, `clean starts the legacy analyzer cache sweep in the background` |
| I-16 | 2026-10-30 | Simulator cleanup could treat failed optional metadata reads as an absent key and suppress cancellation, allowing a device leaf to be removed after an incomplete probe | 437227e1 | f8950db2 | unit | `simulator device metadata timeouts retain the device and signals stop later devices` |
| I-17 | 2026-10-30 | Darwin temporary-root pruning could discard an unreadable live registry and remove an old temporary file still owned by that process | ff2640de | f8950db2 | unit | `Darwin temp prune retains every candidate when a live registry cannot be read` |
| I-18 | 2026-10-30 | Emptying a Trash of about 17,000 small folders ran 18 minutes behind a bare "Emptying trash..." spinner with no count, which the user reported as stuck | unknown | 5b62cc12 | field | `emptying a large Trash reports its count every 100 items` |
| I-19 | 2026-10-28 | `mo optimize` pruned Spotlight's own `Custom.relatedContents` rule as an orphan, so Show Related Content turned itself back on (#1878) | unknown | ea7abfc9 | unit | `opt_prune_spotlight_orphan_rules keeps Spotlight's own switches (#1878)` |
| I-20 | 2026-10-31 | `mo clean` cleaned Chrome's and Brave's `~/Library/Caches` roots while the browser ran, although the Application Support leaves beside them already waited for it | unknown | 3aa4ed7f | write-time | `clean_browsers holds Chrome and Brave Caches roots while the browser runs` |
| I-21 | 2026-10-31 | `mo clean` cleaned Adobe's shared `Media Cache Files` while Premiere Pro, After Effects or another Adobe video app had them in use | unknown | ecf2f800 | review | `clean_design_tools holds Adobe media cache files while an Adobe video app runs` |
| I-22 | 2026-11-01 | Automatic cleanup removed Yarn Berry global archives that Plug'n'Play projects load as installed dependencies | 21d44166 | e59e7d60 | review | `clean_dev_npm keeps Yarn Berry dependencies and cleans only Yarn Classic`, `Yarn Berry producer and sink preserve dependencies with the default whitelist`, `Yarn Berry producer and sink preserve dependencies with a custom whitelist` |
| I-23 | 2026-11-01 | `mo uninstall` printed `[[: invalid regular expression: empty (sub)expression` under Bash 4+ (#1896): the NUL-byte check on decoded uninstall lists matched `$'\0'`, an empty regex, and never rejected anything on any Bash | 61644caf | 671f2c43 | unit | `decode_file_list rejects NUL bytes without an empty regex error`, `decode_bundle_id_list rejects NUL bytes without an empty regex error`, `decode_file_list keeps non-UTF-8 paths under a UTF-8 locale` |
| I-24 | 2026-11-02 | `mo uninstall` of a channel build (Zed Nightly) offered the stable app's base-name folders while the stable app was installed, and the stable app took folders a channel build still used | unknown | fadc47a7 | review | `find_app_files leaves the stable app's base-name folders to it while it is installed`, `find_app_files leaves the family's name folders to a channel build still installed`, `find_app_system_files leaves the family's system folders to another installed build`, `find_app_files accepts an empty family-filtered result under Bash 3.2 nounset` |
| I-25 | 2026-11-02 | `mo uninstall` exited 0 after an app failed to uninstall, so scripts read a failed removal as success | unknown | 4b548846 | unit | `by-name uninstall exits 1 when an app fails and 0 when none did`, `interactive uninstall still exits 1 when an app failed before the user quits with q`, `batch_uninstall_applications adds a failed app removal to MOLE_UNINSTALL_FAILED_APPS` |
| I-26 | 2026-11-02 | `mo clean` emptied `~/Library/Caches/Adobe` and `com.adobe.*` while Photoshop, Bridge or Lightroom Classic ran | unknown | 1191dfe2 | review | `clean_design_tools holds shared Adobe caches while an Adobe app runs but not for Creative Cloud residents` |
| I-27 | 2026-11-02 | `mo analyze` could move `~/Library/Mobile Documents`, an app's iCloud container or its `Documents` folder to the Trash, removing that store from every device on the account | unknown | 17d94dd5 | review | `TestAnalyzeDeleteRefusesICloudStructuralFoldersButNotTheirContents`, `TestAnalyzeDeleteRefusesICloudStructuralFoldersReachedThroughAnotherPath`, `TestAnalyzeDeleteAllowsICloudFilesAtStructuralDepths`, `TestAnalyzeDeleteRefusesParentsOfExistingICloudState` |
| I-28 | 2026-11-02 | With Touch ID enabled for sudo on macOS 27, `mo clean` opened the authorization dialog twice: Mole killed the first `sudo -v` after five seconds and started another, discarding a password typed into the first dialog | unknown | 80d88ea6 | unit | `request_sudo_access waits for one Touch ID dialog instead of opening a second` |
| I-29 | 2026-11-02 | `mo update` copied `bin/` and `lib/` with an unchecked `cp -r`, so a root-owned file or directory left by an earlier sudo install kept stale modules while the update printed success, and a 1.67.0 launcher ran beside July `remove.sh` and `catalog.sh` | unknown | e50a170a | unit | `install_files replaces read-only files an earlier sudo install left in the config tree`, `install_files keeps the pinned launcher and names a safe next step when a config directory refuses the copy` |
| I-30 | 2026-11-04 | On a Mac where Spotlight indexed the folder, `mo uninstall` listed a lone hidden bundle such as `.Solo.app` as `.Solo`, because the mdls fallback returns the bundle's file name; CI, with Spotlight off, read the plist name, so the #1791 case failed only on the maintainer's Mac | 68696564 | 94a8af5c | unit | `uninstall_resolve_display_name never shows a hidden bundle's file name (#1791)` |
| I-31 | 2026-11-04 | The shell timeout fallback installed its INT trap after starting the command, so a Ctrl-C in that window exited the shell and left the command running until the killer's deadline; CI saw it as `ORPHANED:plain` | fef4f3c6 | 9883c619 | review | `run_with_timeout shell fallback traps INT before the command starts`, `run_with_timeout shell fallback never starts a command after an early interrupt` |
| I-32 | 2026-11-04 | `mo analyze` printed sizes that round up to the next unit as `1000.0 kB` (999,999 B) where Finder shows 1 MB, because `units.BytesSI` picked the unit before rounding (#1914) | unknown | 2335f055 | unit | `TestBytesSI` |
| I-33 | 2026-11-04 | `mo status` shortened process names by bytes while its callers pass a display width, so a Korean, accented or curly-apostrophe name was cut while it still fit and a cut could split a UTF-8 rune into `�` (#1917) | unknown | c70d4731 | unit | `TestShorten` |
| I-34 | 2026-11-04 | `mo analyze` measured names with a hand-written rune table, so NFD accents, halfwidth kana, CJK punctuation such as `、` and joined emoji padded the name column one to nine cells off and pushed the size column out of line; Mole CLI (Windows) had moved to grapheme widths in 787b333f and the sync did not carry it back | unknown | 8098ac2c | review | `TestUnicodeColumnsPreserveGraphemes` |
| I-35 | 2026-11-04 | Under `bin/uninstall.sh`'s `LC_ALL=C`, `mo uninstall --list` byte-sliced and byte-padded the UNINSTALL NAME column, so a CJK name split a character and moved SIZE out of line, and spinner messages counted bytes or characters instead of cells, so a CJK app name overflowed or split | unknown | 5324a06e | review | `uninstall --list text table keeps the size column aligned for CJK uninstall names`, `format_spinner_message fits a CJK name by display width in both locales` |
