# Weekly Audit Log

One entry per run of `.claude/skills/weekly-audit`, newest first, covering Mole CLI (macOS) on `main`, Mole CLI (Windows) on `windows` and, since 2026-11-10, Mole CLI (Linux) on `linux`. The next run reads the newest entry for its commit window (`Next window from`), for the items it must not report again (`Decided, do not re-report`), and rechecks `Open` first. Facts here are a run record; lasting invariants live in `AGENTS.md` on each branch.

## 2026-11-10 Three-CLI whole review

- Frozen sources: main `1baecd15`, windows `075215a8`, linux `cf42a724` (first audit of Mole CLI (Linux)). Scope: all three trees whole, at the maintainer's request, in six read-only passes: macOS deletion safety, Windows and Linux deletion safety, command and flag matrix, performance (measured on macOS, by reading elsewhere), over-design and design, stale guidance and codification.
- Landed: main `2ed8427b`, `5cbe27b7`, `0afbb83c`, `59c274a4`, `543a6574`, `dfd0e583`; linux `210e3932`, `c80d3da5`, `e1593dff`, `954da7d7`, `15e995aa`; windows `06b07a9d`, `75ce2f7a`, `cd60e200`, `16c78ee7`, `bec984bb`, `147eef15`, `46c53900`. The per-change table is in SYNC.md under 2026-11-10.
- Next window from: main `dfd0e583`, windows `bec984bb`, linux `15e995aa`.

| Item | Disposition | Evidence |
| --- | --- | --- |
| Linux: Flatpak and Snap app caches skipped native narrowing (JetBrains LocalHistory, Lutris sign-in state) | Fixed | One table for listing and sink; red on the previous code; devbox 252 of 252 bats. |
| Linux: sudo gate read a typed password as a skip and leaked the rest to the shell | Fixed | PTY test with a stand-in sudo; not run in a real session with a password. |
| Linux: dangling whitelist link, `COREPACK_HOME` and `XDG_CACHE_HOME` making data folders rule roots, missing holdbacks, env path seams | Fixed | Red on the previous code. The second reviewer found the `COREPACK_HOME=~/Documents` case the first fix missed. |
| macOS: seven cleanup-root test seams honored in real runs; validator skipped protection when the rules were not loaded | Fixed | I-64; full `./scripts/test.sh` and `check.sh --no-format` pass. |
| macOS: uninstall removed Buzz models; `--with-data` preselected UTM and VirtualBuddy disks | Fixed | I-65, I-66; helper-level reproduction before, tests after. |
| macOS: `mo history` and `mo status --json` cost | Fixed | 5 MB log 4.15s to 0.80s, output byte-identical on 80 files and 300 random logs; status 0.53s to 0.44s. |
| All three: `truncateMiddle` one cell over budget on wide characters | Fixed | I-67; found during the Linux port. |
| Linux: byte step-up, grapheme width, status resize guidance never ported | Fixed | `c80d3da5`. |
| Windows: dry-run preview without a console, `analyse`, one owner check per preview, MSI scripts removed | Fixed | ThinkPad: nine new cases red on the previous source on both hosts; four changed test files 420 of 420 on both. |
| Stale release lines (five on main, one on windows), eight issue-numbered fixes without incident rows | Fixed | Six rows added (I-58 to I-63); #1955 is a capability and #1889 a hint text, not defects. Windows #1948 was defensive, not user-met, so it gets no row. |
| Lessons fixed repeatedly without a rule: display width, future-dated stamps, a helper flipping errexit | Codified | `go-tuis.md`, `shell.md`, `core.md`. |
| Windows: `mo remove --dry-run` (maintainer: do it) | Fixed | `bec984bb`: a `-DryRun` switch on `Uninstall-Mole`; 17 new cases red on the previous source on both hosts, install-tier files 197 of 199 on both, the ThinkPad's user PATH byte-identical before and after. The second reviewer found the first "changes nothing" snapshots skipped every file. `scripts/e2e_windows.py` not run. |
| Linux: three environment switches without a recorded reason (maintainer: remove) | Fixed | `954da7d7`. |
| Linux: `mo history` appended every record to Bash arrays | Fixed | `15e995aa`: 5 MB log 1.8 s to 0.1 s on the devbox, output byte-identical. |
| Windows AGENTS.md past the 20% trigger (maintainer: compress) | Fixed | `147eef15`: dedupe found 113 bytes, so 27 per-command Safety Rules bullets moved verbatim into five `.claude/rules` files; 41,451 to 27,480 bytes. The second reviewer found six loading gaps, all closed. |

### Decided, do not re-report

- Exit code 2 for an unknown command on Windows and the per-platform `mo history --json` keys are intentional differences.
- `installer`, `slim`, `touchid` and `completion` stay off Windows and Linux; `clean --dry-run` gets no JSON output. No user asked for them.
- `Test-MoleInteractiveOutput` false (redirected, a non-ConsoleHost host, `TERM=dumb`) is the meaning of "without a console" for the Windows dry-run preview.
- The Windows `Get-MoleInstallNestedFiles` list keeps the two removed MSI script names, so `mo remove` still deletes them from older installs.
- `clean --dry-run` at about 60s and `purge --dry-run` at about 26s on the audit Mac are `du` over 29 GB and the live `lsof` recheck the purge rule requires; not findings.

### Open

- Windows performance by reading only, no baseline measured, so not changed: `bin/uninstall.ps1` builds the registry and Appx inventory twice per selected app; `bin/purge.ps1` walks one artifact four to five times. Measure on a Windows host first.
- Windows: a real `purge` or `uninstall` without a console ends on the raw `ReadKey` exception instead of a refusal that names the cause and the next command.
- Windows: `Remove-FromUserPath` reads the user PATH expanded and writes it back when it removes the install folder, which on Windows PowerShell 5.1 probably turns `%VAR%` entries into literals (by reading, not run). It no longer writes when the folder is not in the PATH.
- Windows: something in the complete suite leaves `Microsoft\Windows\PowerShell\ModuleAnalysisCache` in the test tree when run from a desktop session; the four changed test files do not.
- Linux performance by reading only: `report_unknown_caches` repeats `du` over `~/.cache`, owner checks run `pgrep` per name and scan `/proc` per Snap rule, gopsutil runs `lsb_release` each status tick. A real Trash run still forks `date` and two subshells per entry in `log_operation`.
- The published `mole` skill and `llms.txt` cover macOS and Windows only, and `skills/mole/references/windows.md` still describes the old dry-run workaround and has no `mo remove --dry-run`. Maintainer 2026-11-10: leave them until a user asks.
- `MOLE_LSREGISTER_PATH` in `lib/core/base.sh` picks the binary `lsregister` calls run as the user and is read outside test mode; not a deletion root, left as is.
- Delivery receipts are missing for V1.68.0 to V1.70.0, V1.41.0 to V1.43.0-windows and V0.5.0-linux.

Rule volume after this run: main AGENTS.md 36,446 bytes, AGENTS.md plus `.claude/rules` 178,785 bytes (18.8% over the 150,543 recorded on 2026-10-30); Windows AGENTS.md 27,480 bytes after the split, its five `.claude/rules` files 17,462 together (the new baseline; it was 41,451 before, 24% over 33,315); Linux AGENTS.md 21,963 bytes, with rules 34,135. On Windows two duplicate sentences were removed and one incident sentence moved; no constraint was removed on any branch.

## 2026-10-30 Dual CLI post-release review

- Frozen review windows: Mole CLI (macOS) `79e255a8..2c065181`, Mole CLI (Windows) `V1.38.0-windows..dd034c31`. Both checkouts were synchronized before repair; the final pre-review differences were contributors-only commits.
- Scope: both CLI source trees and their current guidance, with detailed checks of the changed cleanup, owner-cache, temporary-file, timeout, launcher, update, Analyze and Status paths and their consumers. The desktop apps and a new package release are outside this task.
- Behavior repairs: main `f8950db2`, windows `3d2db78f`. The eight-item queue below is implemented and locally verified. The Windows development record owns complete dual-engine Pester verification; targeted native fixtures do not replace it.
- Next window from: main `f8950db2`, windows `3d2db78f`. These are behavior baselines; the following record-only commits belong to the next review's documentation delta, avoiding a self-referential record commit.

| Item | Disposition | Evidence |
| --- | --- | --- |
| Simulator metadata failures and cancellation | Fixed in source, locally verified | One successful XML snapshot distinguishes an absent optional key from an unreadable plist. Timeouts retain the device; signals propagate through discovery and the sink before later devices. The old source failed the new regression; repaired source passes the complete macOS suite. |
| Unreadable live temporary registry | Fixed in source, locally verified | Temporary-root pruning requires a complete read of live registries before filtering candidates. A failed read retains the entire candidate set. The old-source fixture removed the owned file; the repaired fixture retains it. |
| VS Code developer-cleanup bypass | Fixed in source, locally verified | Both cleanup entries use the same owner guard for the six existing leaves. Running or unknown owners retain the cache in preview and real-mode fixtures. |
| Junction above the self-removal cache root | Fixed in source, locally verified | Self-removal checks every cache ancestor before traversal. The native junction fixture fails on the old source and passes after the repair. |
| Bun owner-cache boundary | Fixed in source, locally verified | The configured root and bounded owner command use the shared cleanup policy; failed or unknown roots/commands retain data. Only an unavailable/unusable Bun with an idle owner permits guarded default-root cleanup. Existing CLI-SYNC-17 owns the cross-CLI status and delivery boundary. |
| Update worker's PowerShell host | Fixed in source, locally verified | The worker uses the current host, so a successful PowerShell 7 fallback no longer starts a policy-blocked Windows PowerShell executable. The native fixture reverses from failure to pass. |
| Vesktop release status | Record corrected | Its CLI cleanup is present in the V1.66.0 tag and covered by the existing release receipt. The Mole Mac row retains its separate unreleased status. No new asset publication was performed. |
| Missing incident records | Record corrected | Mac I-13 through I-15 add the Kitty, system-proxy update notice and legacy Analyze-cache incidents with their existing catchers. Mac I-16/I-17 and Windows I-11 through I-14 record this review's six behavior fixes and their new regressions. |

### Verification and remaining delivery boundary

The integrated macOS `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` exited 0 and reported its own `All tests passed!` summary. `scripts/check.sh --no-format` also exited 0. Independent review of both repaired diffs reported zero remaining findings. On Windows PowerShell 5.1.26100.9711, the same isolated native fixture runner reported 13 failures before the repair and 13 passes after it; all 13 outcomes reversed. This is targeted native evidence, not a complete Pester result. The first [Windows Validation](https://github.com/tw93/Mole/actions/runs/40981356671) PowerShell 7 leg reported 709 passed and one failed: the new update-host Pester case received a null context. Diagnostic run 40981948137 identified an unmatched Join-Path mock under Pester 6; Windows test fix `04b8ea81` forwards ordinary joins while retaining the old-host rejection. The Windows development record owns the follow-up. Exact-final-head CI must be read separately after the record commits are pushed.

The follow-up [Windows Validation](https://github.com/tw93/Mole/actions/runs/40982596815) passed on `efcc6dea`: PowerShell 5.1 and 7 each reported 710 passed, zero failed and zero skipped. The [macOS validation](https://github.com/tw93/Mole/actions/runs/40982594938) passed its full suite and security jobs but failed five simulator cases on macOS 15; fail-fast cancelled macOS 26. Its optional-key gate depended on failed `plutil -extract` output. The compatibility follow-up reads root-dictionary XML types directly, preserving missing optional keys while rejecting wrong types and nested lookalikes. Its new type regression failed against the prior source, and its probe matrix covers ordinary failure, timeout and signals at discovery and deletion. The exact macOS 15 diagnostic text was not captured and is not claimed as a verified cause; the revised code must pass both compatibility jobs before closeout.

No command, flag, setting or public output field was added. Normal cache targets are unchanged; the visible differences are retention on uncertain or active ownership, cancellation before later simulator work, and update notices using the working host. The review does not claim a new quantitative performance improvement. Project prefetch keeps one manifest, bounded workers and final checks; Analyze keeps its indexed updates and existing display tick; Status retains its expensive-probe caches. No real user cleanup, third-party uninstall, new release or package/device acceptance was performed in this repair batch.

Rule volume after repair: main AGENTS.md 34,192 bytes; AGENTS.md plus `.claude/rules` 150,543 bytes; Windows AGENTS.md 33,315 bytes. The macOS total exceeds the 99,723-byte split baseline's 20% review trigger. `uninstall.md` is 14,457 bytes against its 10,140-byte split baseline; `install-update.md` is 11,479 bytes against its later 10,353-byte compression baseline, below that file's trigger. Growth includes effective safety constraints and regression anchors, so size alone does not justify deleting rules. This task compressed or removed zero effective constraints.

Decided, do not re-report: preserve the earlier recorded non-atomic filesystem, cache-identity, platform and product-scope boundaries unless new evidence changes them. Windows native fixture success is not dual-engine full-suite or signed-package proof. Keep the existing owner-command policy and no new controls.

Open: no known source repair remains in this eight-item queue. The host-test fixture correction is `04b8ea81`, and complete Windows PowerShell 5.1/7 CI is verified above. Final macOS full-suite and macOS 15/26 compatibility CI are required at task closeout; their run results remain separate from local fixture evidence. Releases and package acceptance require their separate authorization and evidence.

## 2026-10-26 Residual closure

- Frozen follow-up sources: main `32b70a91` and windows `d1ab34a2`, both matching their remote branches. The earlier complete review remains the module baseline; this follow-up covers its residual entries and affected callers.
- Queue: all 24 original limitation entries, M01-M14 in the [macOS audit](../SECURITY_AUDIT.md#known-limitations-and-future-work) and W01-W10 in the [Windows audit](https://github.com/tw93/Mole/blob/windows/SECURITY_AUDIT.md#known-limitations). Two are fixed, 22 retain explicitly explained product/system/evidence boundaries. Two additional concrete gaps found during closure are also fixed below. No entry was silently dropped.
- Source repairs: main `bc3d642a` and `79e255a8`; windows `3b6b0b0b` and `20d12930`, with review record `954312b5`.
- Next window from: main `79e255a8`, windows `954312b5`.

| Item | Disposition | Evidence |
| --- | --- | --- |
| M13: malformed history JSON | Fixed | The shared Bash 3.2 encoder validates scalar sequences and replaces each invalid byte with U+FFFD only in JSON. Helper and actual-router old-source tests fail; valid UTF-8 and raw stored logs remain intact. |
| W06: unreadable Store manifest | Fixed | Discovery, preview and removal require readable manifest evidence, not just readable package inventory. Sparse/unknown manifests retain the package; ordinary manifests remain eligible. App-cache v7 invalidates rows created under the old rule. Old-source native tests: 142 passed, 11 failed; both PowerShell engines pass the 205-test affected set. |
| Physical owner-root resolution cancellation | Fixed | A failed resolution subshell returns its original status. Real owner-caller fixture tests cover cd/pwd interruption, ordinary refusal and success; the old source loses the signal. |
| Advisory Windows Go lint | Fixed | The remaining read-only handle-close warning is explicitly handled without changing identity authorization. Windows-target ARM64/AMD64 lint passes, and Check no longer ignores lint failure. `actionlint` passes. Heuristic source-pattern warnings remain review aids, not a comprehensive security gate. |

Verification: the follow-up complete `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` passed with exit 0 and the runner's `All tests passed!` summary, including Go, module-loading, integration and isolated installation checks. Formatting, `check.sh --no-format` and ShellCheck for both changed Bats files pass. Windows native PowerShell 5.1.26100.9711 and 7.6.7, Pester 6.2.0, each pass 205 targeted tests with zero failures/skips. Subsequent full-suite launches lost the Parallels guest-exec result channel (`PrlJob_GetRetCode: Invalid argument`); execution and results cannot be confirmed, and retries stopped. Do not substitute the earlier 681-test receipts or cross-builds for this revision's native full suite. A successful final-head Windows CI run must supply the remaining native full-suite evidence, independently of local targeted results. No real app uninstall, new package or release is part of this follow-up.

Cross-CLI disposition is recorded in existing CLI-SYNC-04, CLI-SYNC-12 and CLI-SYNC-16 rows. Windows history decodes into .NET strings before `ConvertTo-Json`, so it does not share the Bash byte-emission defect. Windows owner-root queries keep their existing checked-result contract, and macOS has no Appx manifest consumer. No platform-specific policy was copied into an unrelated consumer.

Decided, do not re-report: retain the 22 documented boundaries with their individual reasons. This supersedes the earlier decision to defer malformed history JSON. No new command, flag, setting or public output field was added. The visible changes are valid JSON for malformed logs, cancellation after interrupted physical-root resolution and retention of Store packages with unknown manifest evidence.

Open: no confirmed defect in this follow-up is left without a repair. The integrated macOS suite passed; exact-head CI results are verified separately at task closeout. Package and physical-machine acceptance remain separate.

## 2026-10-26 Whole dual CLI safety review

- Initial complete-tree sources: main `ec968fc8` (production identical to `00f8279e`) and windows `8bff8583`. Incremental windows were `70eed1b0..ec968fc8` and `e5257672..8bff8583`; complete scope was not limited to them. Concurrent main commits `0f9c0df4`, `4f9abf8b` and `c8fe24f1` were preserved, reviewed and included in final integration; `502b3483` only updates contributors.
- Scope: both complete CLIs, safety/correctness, performance/lifecycle and stale rules/docs, plus four adversarial passes. Both desktop apps, releases, real vendor uninstall and privileged cleanup are outside this task. The [macOS audit](../SECURITY_AUDIT.md) and [Windows audit](https://github.com/tw93/Mole/blob/windows/SECURITY_AUDIT.md) own module matrices and residual risks.
- Merged PR inventory from 2026-10-24: six IDs, #1833, #1835, #1838, #1840, #1842 and #1852. The older same-day items precede the recorded repair baseline; #1852 is included in `00f8279e`. This is a review inventory, not authorization to reply or close threads.
- Source repairs: `541690b5` (Analyze) and `16f5c5d7` (developer cleanup), plus Windows `34f646c2`; Windows review record `d1e199c0`.
- Next window from: main `16f5c5d7`, windows `d1e199c0`.

### Queue disposition

| Item | Result | Evidence |
| --- | --- | --- |
| Analyze hidden input during deletion | Fixed | Busy mode refuses navigation and confirmation while preserving quit and the existing refresh path. Old input assertions failed; `lifecycle_test.go` and refresh/delete interleavings pass. |
| Protected runtime moved through its parent | Fixed | Docker/OrbStack existing roots protect their parents and aliases. Darwin user/cache structural roots preserve EDR state. Six parent/alias, five structural and one linked-runtime physical-parent assertion failed before repair; empty-container and normal-cache controls pass. |
| Owner-cache physical whitelist bypass | Fixed | Both configured and physical roots are checked, including linked ancestors, absent leaves and all Conda package roots. Four production producer fixtures use mocked owner mutation, with ordinary and allowed-link controls; signals propagate. Ten helper call sites were inspected, eight real owners inherit the new guard and two placeholder calls retain their separate contracts. |
| Jupyter runtime cleanup | Fixed | Remove the Python producer and protect the runtime root/children at the shared clean sink; explicit uninstall remains separate. Producer/sink red-green fixtures and ordinary-cache controls pass. |
| Windows post-owner identity gap | Fixed | `34f646c2` checks the original snapshot after the final callback, for both preview and removal. Three old-source cases fail; final dual-host Pester runs each pass 681 tests. Three sibling removal helpers were checked, one changed and two already had this boundary. |
| Review claims and stale delivery rows | Updated | Correct the shared-helper, attestation, log encoding, Slim and non-atomic guarantees. Existing Windows vendor-wait/Adobe rows now agree with V1.39.0-windows ancestry and the dated package receipt; artifacts were not downloaded again. |
| Asynchronous test teardown | Fixed in test | The valid live-scan fixture waits for its background cache publication before removing HOME. The observed race failure is recorded, and 100 focused race repetitions plus the full race package pass. No production synchronization layer was added. |

### Verification and evidence boundaries

The first isolated complete macOS `scripts/test.sh` run exited 0 with `All tests passed!`. Final integrated suite: passed with exit 0 and the runner's `All tests passed!` summary; the final linked-runtime Go follow-up was then checked with the full Go/race/build/lint gates. Formatting, `check.sh --no-format`, native build, Go and race tests pass. Windows native PowerShell 5.1.26100.9711 and 7.6.7, Pester 6.2.0: 681 passed, zero failures/skips on each engine. All 58 scripts parse under both engines; all three ARM64 Go test packages pass natively, and Windows x64/ARM64 builds plus ARM64 vet pass. The Windows Go runner's initial SYSTEM temporary-root refusals were corrected by isolating `SystemTemp`, without weakening product checks. Exact-commit CI is checked separately from source tests and recorded in the final task result.

Eight isolated launcher fixtures cover Steam, Epic, GOG, Battle.net, Parallels, UTM, Ollama and LM Studio. Their exact cache leaves remain automatic, personal state remains default-kept, and shared Steam/Epic roots are excluded. This does not establish real-installed-app or custom-library acceptance. The two-CLI comparison found existing Windows busy, protected-descendant and owner-root guards; no Windows Jupyter runtime producer exists. No macOS-only path was copied into Windows.

Test-isolation correction: two initial Jupyter red runs actually invoked `pip3 cache purge` and `uv cache prune`, because an external timeout process did not inherit shell-function mocks. HOME was disposable, and subsequent read-only root queries in the same layout stayed inside it, but original owner output/effective roots were not captured. External-cache impact cannot be ruled out or quantified. The timeout dispatcher is now mocked and all subsequent runs use that corrected fixture. This is not described as entirely mocked verification.

### Decided, do not re-report

- Keep path-based final checks and document their remaining non-atomic window; owner internal locking and configuration rereads are not proven by Mole's preflight.
- Keep the existing attestation availability policy and unpinned installer URL. A generic moving-URL signal is not a new integrity regression; the actual checksum/mismatch abort path remains enforced.
- Superseded by the residual-closure follow-up above: malformed UTF-8 is repaired in rendered JSON, while stored log bytes remain unchanged. The original reproduction was not a deletion incident.
- Generic audit signals about hotspot sizes, Windows test discovery and packaging are not verified defects: the scanner omits PowerShell from its source inventory, while real Pester/install gates exist. Do not split the deliberately large safety hotspots based on line count.
- No new quantitative performance improvement is claimed. Mounted-volume overview cache identity remains path-based and kernel filesystem calls are not all interruptible; neither observation authorizes a new deletion path.

Open: no unrepaired reproduced safety finding remains in this review. Package/release delivery, real-application acceptance and the stated architectural limitations remain separate; this task does not publish a version.

## 2026-10-24 Dual CLI release review and cancellation repairs

- Release baselines: `V1.62.0` and `V1.37.0-windows`. Frozen repair source: main `1c244a2a`, windows `e5257672`; the macOS checkout was fast-forwarded over its contributors-only update before editing.
- Source repair: main `70eed1b0`. The Windows runtime implementation is unchanged; acceptance-runner repairs and final machine receipts belong to its [development record](https://github.com/tw93/Mole/blob/windows/docs/development-record.md).
- Next window from: main `70eed1b0`, windows `e5257672`.

### Fixed and verified

- CrashReporter and Cursor Agent log-scan signals now stop their callers before later cache groups. The sibling sweep checked 14 caller sites, repaired three, and retained the eleven system-cache callers that already propagate signals.
- Both find/delete helpers now preserve cancellation from scanning, sizing, previews and privileged preflight. Pending cancellation prevents new work; a privileged validator signal discards the accumulated batch. Ordinary refusals and read-only timeouts retain their per-target behavior. Fifteen helper cases and three caller cases cover signals and their neighboring success, refusal and timeout paths; the signal regressions failed against the previous implementations before passing with the fix.
- Three stale `SYNC.md` delivery rows now say `Released (V1.62.0)`. The public tag archive's browser-clone and app-cache source files were downloaded and compared byte-for-byte with the tag, in addition to checking the three source commits' ancestry and the stable installer consumer.

`check.sh --format`, `check.sh --no-format`, `make build` and the complete `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 MOLE_TEST_JOBS=2 ./scripts/test.sh` exited 0 with Go 1.26.10. The full test runner reported `All tests passed!`, including Bats, Go, module loading, integration and isolated installation. Two existing area rules now pin the cancellation and timeout boundary; no effective constraint was removed. The visible change is that interrupted cleanup stops before later work. No flag, configuration key or normal output was added.

Candidate `65ea37cc` passed Check, [Validation](https://github.com/tw93/Mole/actions/runs/40086448438), CodeQL and Nix, including the macOS 15 and 26 compatibility jobs. With the maintainer's explicit authorization, macOS 27.0.1 arm64 acceptance run `20261024-183649` passed all 10 steps and 23 smoke commands. IINA 1.5.0 passed digest, signature and Gatekeeper checks, launched, and was uninstalled through Mole; the app, three fixture leftovers and its DMG reached the Trash, and history matched the actions. The final fixture remainder list was empty. The preflight dirty marker came only from an import-generated, untracked Python bytecode file, which was removed; tracked candidate source remained unchanged. The later contributors-only update changed no tested CLI code.

### Authorized publication

The maintainer separately approved GitHub stable releases for both CLIs and the macOS workflow's Homebrew core PR, with no winget or Scoop submission. Release-note item lead-ins are plain text. After the maintainer requested names for both CLIs and unnamed historical releases, all 83 titles were reviewed: the two current titles and nine historical Windows titles received codenames, leaving zero unnamed releases. Existing bodies, assets, tag references and release/prerelease states were preserved.

Mole CLI (macOS) [V1.63.0 Reach](https://github.com/tw93/Mole/releases/tag/V1.63.0), tag source `a7c4c84e265802a8323a887b8e244bf272a3a633`, passed Check, [Validation](https://github.com/tw93/Mole/actions/runs/40094044066), CodeQL and Nix on that exact commit, including both Darwin architectures. The version-only change passed 102 focused CLI/version/checksum cases and the full source checks; the preceding full Bats/Go/integration/installation run remains applicable. Fresh native acceptance at the tag candidate passed all 10 steps and 23 smoke commands: IINA, four fixture leftovers and its DMG reached the Trash, with no fixture remainders.

All seven public assets were downloaded and their attestations tied to this tag, source commit and release workflow. Payload checksums, archive/raw byte equality, both architectures and minimum macOS 12.0 passed, as did native Analyze/Status JSON probes. An isolated script installation updated from 1.62.0 to 1.63.0, retained the stable channel and an unknown canary file, matched the public native binaries and changed tagged shell sources, then reported current on a second update. The existing Mole installation was preserved. Published bilingual notes contain no bold item lead-ins, and all six standard reactions were read back.

[Homebrew core PR #320952](https://github.com/Homebrew/homebrew-core/pull/320952) merged on 2026-10-24. The core formula now targets the V1.63.0 archive with the release workflow's verified source checksum; the public formula API still reported 1.62.0 at this check. Index rollout and an installed Homebrew upgrade remain unverified. Mole CLI (Windows) package, upgrade and machine receipts belong to its linked development record. The final live queue contains #1836 and #1834, with no open PRs or new items.

### Decided, do not re-report

- The local Windows VM's initial two failures on each PowerShell host occurred while creating symbolic-link fixtures, before the product assertions. The same two cases then passed natively through the existing authorized SSH session on PowerShell 5.1 and 7.6.8, with zero failures or skips and no system-setting change. Keep the assertions and production behavior. Full [Windows Validation](https://github.com/tw93/Mole/actions/runs/40086930353) independently passed all 567 Pester tests on both PowerShell hosts.
- Do not attribute #1836 to the repaired cancellation paths. The isolated 129-plist non-terminal fixture completed with both timeout backends; it did not reproduce the reporter's filesystem or full-command hang.

### Open

- #1836 still needs the relevant, sanitized main-thread stack from the exact hung `clean.sh` process. The thread already requests that evidence; no speculative production change or duplicate reply was made.
- #1834 concerns Mole Mac and remains outside the CLI release. Neither open report is claimed fixed by these releases. Windows acceptance remains owned by the linked branch record rather than inferred from the macOS run.

## 2026-10-23 Safety and performance follow-up

- Next window from: main `44386098`, windows `923e1b2a`, unchanged from the last complete dual CLI review below.

The two same-shape Optimize signal sites now address launchd services instead of process names. NotificationCenter uses the current GUI domain; DNS reads the fixed system plist and permits only the original or `.reloaded` label. Existing SQL, VPN, dry-run and privilege behavior remains. Two NotificationCenter regressions and three DNS regressions failed against the old implementations, the four Optimize suites passed all 141 tests, and the full check and test workflows exited 0. No live system-service signal was sent. Source is ready for delivery; no version or release changed. The app-owned record carries the cross-product comparison, without copying private source here.

The subsequent review of main `fb920811` and windows `e5257672` found three remaining items. Seven direct/staging Trash commands now use the existing per-command disk deadline, preserving staged data and completed-path accounting on timeout; all eight real-helper timeout regressions failed before the fix and passed after it. PR #1830 was repaired on its existing branch in `24f9a326`, preserving the contributor's commit: an execution-trace contract replaces text matching, and the complete 16-test performance suite passes, including harmful and harmless syntax fixtures. That PR remains unmerged. The newest entry now explicitly inherits the last complete review's next-window baseline above. The Windows recycle implementation uses a separate COM boundary, so this shell fix does not establish a Windows recycle deadline. Real authorization, cross-volume movement, reporter resolution and release delivery remain unverified.

The Trash follow-up passed `check.sh --format`, `check.sh --no-format` and the complete `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh`, which exited 0 and reported `All tests passed!`. Six legacy mover mocks were converted from shell functions to executable fixtures so the external timeout backend still exercises their intended failures. The first full run exposed the last of these in the uninstall access-denial test; that case and the complete rerun passed after its fixture update.

## 2026-10-23 (whole dual CLI review and skill update)

- Frozen review window: main `8b49a13a..176df15b` (68 commits), windows `9b010223..b3c3a622` (27 commits). Both repair checkouts were fast-forwarded to these reviewed remote heads before editing, with no unrelated worktree changes. The concurrent Windows contributors-only commit `6a7d2c3c` was inspected and retained.
- Merged PR set since 2026-10-18, rechecked before delivery: 25, with no additions or missing IDs: #1764, #1765, #1766, #1768, #1769, #1772, #1774, #1776, #1784, #1785, #1786, #1790, #1799, #1803, #1806, #1807, #1808, #1809, #1812, #1816, #1817, #1819, #1821, #1822, #1828.
- Scope: both complete CLI trees, including core safety, cleanup, uninstall, purge/installer, optimize, slim where present, routers, installation/update/removal, Analyze/Status, tests, workflows and guidance. Both desktop apps remain outside this audit.
- Next window from: main `44386098`, windows `923e1b2a`.

### Approved queue disposition

| Item | Result | Evidence |
| --- | --- | --- |
| 1. Installer EOF accepted as Enter | Fixed | `d5a2d34d`; selection and final confirmation now cancel on failed reads, with EOF and explicit Enter regressions in `tests/installer.bats`. |
| 2. Partial external-volume metadata could authorize cleanup | Fixed | `b81e6e85`; require successful `diskutil info -plist`, a typed false `Internal` and a nonempty local protocol. Failure, timeout, malformed/type-confused and network cases retain the target; signals propagate. Helper and real CLI fixtures pass. |
| 3. Windows completed Analyze list lost children after row 30 | Fixed | Windows `b5ec4858`; full directly browsable results, cached navigation, selection/viewport and wide row indexes are covered by `directory_browsing_test.go`. Recursive summaries remain bounded and refresh when entered. No Windows disk-cache schema exists to invalidate. |
| 4. Fractional timeout mapped early SIGKILL to timeout | Fixed | `f7b7afc0`; use the existing native kill grace when interpreting status 137. Both early SIGKILL and actual escalation are covered; all 35 timeout tests pass. |
| 5. Both Analyze implementations repeatedly searched and sorted full lists | Fixed | Main `44386098`, Windows `b5ec4858`; scan-local path indexes and existing 100 ms display ticks batch sorting/filtering, while totals and completion/cache updates remain immediate. Full Go and Analyze race tests pass on macOS; Windows native results are owned by its development record. |
| 6. Slim predictable output suffix and closed confirmation input | Fixed defensively | `50cd1135`; exclusively created temporary output cannot reuse a pre-existing suffix symlink, and EOF cancels. The real lipo helper fixture preserves the linked victim. This proves the helper boundary, not a full Developer ID bundle exploit or signed-app acceptance run. |
| 7. PowerShell 7 WMI compatibility concern | No production change needed on tested hosts | `49e14d08` adds unmocked health queries. The initial native matrix passed that test on PowerShell 5.1 and 7.6.6; its sole failure on each host was the new Go files missing from the install inventory, fixed in `923e1b2a`. The ARM64 VM resolved `Get-WmiObject` through a Windows compatibility proxy, so absence as a native cmdlet alone does not prove a broken query. |
| 8. Weekly skill and stale synchronization evidence | Updated | Skill 1.3.0 freezes heads/PR sets and whole-tree scope, distinguishes evidence layers, requires correctness/cross-CLI checks, preserves concurrent work and verifies final-head CI. Existing CLI-SYNC-02/04/15 now reflect verified release ancestry and dated delivery receipts; CLI-SYNC-05 owns this Analyze adaptation. |

### Verification and boundaries

The final complete `TERM=xterm-256color MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` exited 0 and reported `All tests passed!`, including Bats, Go, module loading, integration and isolated installation. The first full run exposed one legacy text-format diskutil fixture in `tests/cli.bats`; after updating it to the plist contract, the targeted case and complete rerun passed. `check.sh --format`, `check.sh --no-format`, test ShellCheck, `make build`, both branches' full Go tests, Analyze race tests and the Windows cross-build/vet passed. Regressions were first observed failing against the previous implementations. Windows source `923e1b2a` passed native Check and Validation, including both PowerShell hosts, Go, Build and Security; receipts are in its existing development record. Final branch-head CI is checked separately from these local results.

The 10,000-child in-memory update fixture plus one display tick measured main 649.377 ms before and 0.895 ms after, Windows 328.791 ms before and 0.879 ms after. These are single samples on the same Mac/Go host, excluding filesystem scanning and View rendering, not end-to-end speed claims.

The three changed skill files passed schema validation, independent semantic review, 13 local path checks and command-option checks. No effective safety constraint was deleted or compressed. Existing area rules now lock EOF cancellation, typed completed probes, fractional timeout status, exclusive slim output and batched complete Analyze results.

### Decided, do not re-report

- Preserve the PowerShell implementation on the tested hosts; keep the native unmocked health test so future incompatibility is detected instead of inferred from command deprecation alone.
- Preserve bounded recursive summaries and existing feature scope. No new public flag, configuration key or dependency was added. Visible changes are cancellation on EOF, refusal of unknown external volumes, complete Windows directory browsing and sorting/filtering on the existing display tick.
- CLI-SYNC-06 and CLI-SYNC-09 remain their existing product-decision queue, outside this repair batch. Rule-size growth alone does not justify removing effective constraints.

### Open

No remaining confirmed source defect in this eight-item queue. Source and CI do not establish release delivery: no tag, release, package publication, real cleanup, real app uninstall or new physical ThinkPad acceptance was performed. The local VM command channel was intermittent; native matrix results must not be described as physical-device acceptance.

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
