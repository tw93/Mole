# Mole Windows CLI Security Review

The 2026-10-26 review starts from `8bff8583` on the `windows` branch and covers the complete Mole CLI (Windows). Mole for Windows and Mole Mac are outside its scope. This is a maintainer review, not an independent security certification. The earlier complete review used `88cf57e8` on 2026-10-13; its dated follow-ups remain below.

## Review Scope and Evidence

| Surface | Boundary under review | Regression evidence |
| --- | --- | --- |
| Core file operations and protection | Literal/canonical paths, whitelist, junctions, identities, callbacks, descendants and recycle outcomes | `tests/Core.Tests.ps1`, `tests/CleanupBoundary.Tests.ps1`, `tests/Protection.Tests.ps1`, `tests/Recycle.Tests.ps1` |
| Automatic cleanup and owner commands | Disposable content, complete process/lock evidence, report age, protected stores and preview parity | `tests/AppCacheSafety.Tests.ps1`, `tests/CleanupTargets.Tests.ps1`, `tests/Clean.Tests.ps1`, `tests/DryRun.Tests.ps1` |
| Uninstall | Registration identity, current Store metadata, shared content, bounded vendor waiting and final leftover ownership | `tests/Uninstall.Tests.ps1`, `tests/UninstallWait.Tests.ps1` |
| Purge and optimize | Project/Git ownership, final checks, disk/power readiness, native command results and dry-run | `tests/PurgeBoundary.Tests.ps1`, `tests/Optimize.Tests.ps1`, `tests/DryRunEnvironment.Tests.ps1` |
| Analyze | Asynchronous selection, protected descendants, path identity and native shell recycling | `cmd/analyze/*_test.go` |
| Status and history | Partial/unknown measurements, credential-safe rendering, stored records and output encoding | `cmd/status/*_test.go`, `tests/History.Tests.ps1` |
| Router, launchers, install, update and remove | Argument/exit-status handling, owned installation files, native-tool freshness, provenance and channel notices | `tests/Router.Tests.ps1`, `tests/Install.Tests.ps1`, `tests/InstallLifecycle.Tests.ps1`, `tests/UpdateNotice.Tests.ps1`, `cmd/mo/*_test.go` |
| Tests, workflows and guidance | Nonempty passing test results, enforced/advisory gates, signed inventory and current safety claims | `tests/TestRunner.Tests.ps1`, `tests/Release.Tests.ps1`, `.github/workflows/`, `AGENTS.md` |

The matrix identifies scope; the executed checks are recorded in Verification Evidence. This source review fixes the confirmed batch-file replacement gap in `34f646c2`. Package signatures, real UAC/vendor-uninstaller behavior and physical-machine acceptance remain separate evidence.

### Changes Since the Previous Complete Review

The source adds several safety boundaries beyond the `88cf57e8` review:

- `d4eaffc4` preserves Poetry virtualenvs and Service Worker CacheStorage while adding exact application disk-cache leaves with process/lock, identity and exclusion checks. `b54d26ec` adds complete report-tree age checks and preserves Adobe Team Projects state. Regression coverage is in `tests/AppCacheSafety.Tests.ps1` and `tests/CleanupTargets.Tests.ps1`.
- `c1ee99eb` retains game-library and emulator content in registered install folders. `87f26494` keeps registered identity separate from cleanup eligibility and rechecks current Store package identity and protected metadata before removal. `tests/Uninstall.Tests.ps1` covers shared-content, ordinary-install and single-game cases.
- `ebc7e23a` still checks target-volume health when physical-disk inventory fails. `792e08dd` and `c0945edc` require complete battery evidence and avoid inferring Healthy from unknown capacity. Disk and power refusal cases live in `tests/Optimize.Tests.ps1`; native battery tests live in `cmd/status/`.

These changes reduce specific data-loss and misleading-result risks. The [development record](docs/development-record.md) retains their original failing regressions, native runs and release receipts. Those historical results do not replace this review's final verification or remove the race, vendor-process and filesystem limitations below.

### Earlier Bounded Follow-ups

Bounded follow-up on 2026-10-14: `0b78b46b` adds unreadable-whitelist retention and preserves Spotify stores; `3a7f8b7b` narrows the Proton Pass command exception. The affected claims below are updated. This is not a new full security audit; regression and delivery evidence is in the development record.

Bounded follow-up on 2026-10-16 from `c6ce917e`: generic screenshots and screen recordings are retained even with `-GameMedia`; config removal refuses root/ancestor junctions; a locked native launcher is rejected before any uninstall mutation; SFC uses owned scratch and checked exit status. Windows Update inspection uses a bounded local-catalog query and retains unknown results instead of reporting zero updates. Operation logs now cover actual removal/recycle outcomes and checked owner-process termination, and Analyze append failures reach the existing debug session. This is a scoped repair review, not a new certification or release; current runtime receipts are in the development record.

Bounded follow-up on 2026-10-25 from `9c408d72`, implemented in `87f26494` (uninstall), `ebc7e23a` (optimization) and `c0945edc` (status): registered directory identity is independent of recursive sizing and leftover eligibility, preserving distinct registrations without relaxing protected-root checks. Cached Store selections now require current package identity/metadata and reject known sparse packages, with Game Bar explicitly protected. Physical-disk inventory failure no longer prevents an independent target-volume health check. This is a scoped follow-up, not a new full audit; native regression receipts and their failed preliminary runs are recorded in the development record.

## Threat Surface

The primary risk is unintended local data loss. Relevant surfaces are automatic cleanup, project-artifact purge, application uninstallers and leftover recycling, Analyze deletion, system maintenance, installation and self-update. Read-only inspection and successful unit tests do not establish that every destructive operation is safe on every Windows installation.

## Destructive Operation Boundaries

| Surface | Current controls | Regression evidence |
| --- | --- | --- |
| PowerShell file removal | `Test-SafePath` applies protected paths and the whitelist. `Get-MolePathSnapshot` binds the target and ancestors to volume/file identities; incomplete inspection or replacement retains the target. Directory removal checks descendants and rechecks each entry before removal. | `tests/Core.Tests.ps1`, `tests/CleanupBoundary.Tests.ps1` |
| Links and shared roots | Linked ancestors are refused. Directory traversal does not follow junction targets. Supported leaf-link removal unlinks the entry without recursively deleting its target. | `tests/CleanupBoundary.Tests.ps1` |
| Whitelist | Literal paths, including brackets, protect their descendants before wildcard interpretation. Prefix siblings are not descendants. Missing user protection is empty; metadata/content read failure retains targets, and filenames are read literally. | `tests/CleanupBoundary.Tests.ps1` |
| Owner-managed caches | Owner commands resolve their actual roots, honor exclusions and recheck root identity. Unknown roots or failed commands never fall back to direct deletion. Automatic Docker builder pruning is excluded. | `tests/CleanupTargets.Tests.ps1` |
| Application disk caches | Browser, Teams, editor/notes and Poetry cache leaves use a complete process snapshot and applicable lock-file checks before preview and after sizing. Live or unknown owners retain targets. Poetry virtualenvs, Service Worker CacheStorage and Adobe Team Projects state are clean-protected, including shared-sink parent sweeps. Sublime Local and Roaming caches use the same owner guard. Adobe Common media/peak caches and Yarn Classic now share the owner guard, including the post-sizing recheck. Named Yarn Berry dependency stores stay clean-protected even through parent sweeps. The exact new Teams WebView disk-cache exception does not bypass user exclusions or allow package roots. | `tests/AppCacheSafety.Tests.ps1` |
| Error reports | Seven-day eligibility uses creation and write times across a complete bounded report tree. Recent, linked or unreadable reports are retained, including attachments arriving during sizing. WER collection roots are not removed. | `tests/AppCacheSafety.Tests.ps1` |
| Disk maintenance | Target-volume health is read independently even if physical-disk inventory fails; known Warning/Unhealthy targets are retained before optimization. Battery-equipped systems require complete external-power evidence, unknown power retains the drive, and a complete empty battery inventory permits a desktop. | `tests/Optimize.Tests.ps1` |
| Purge | Generic names require the matching project ecosystem. Git-tracked content, nested repositories and ambiguous probes retain the candidate; discovery and deletion recheck ownership. | `tests/PurgeBoundary.Tests.ps1` |
| Application leftovers | The registered uninstaller and its tracked descendants finish first. Its wait has a fixed 30-minute ceiling; timeout stops the batch without killing the vendor or recycling leftovers. Leftover recycling requires the selected registration to be gone and a complete inventory with no same, parent or child install-folder owner. Registered path identity survives protection for merging and display, with a separate restriction on recursive measurement. Preview and the removal guard both check ownership and bounded game-content markers in registered install roots; incomplete or redirected children retain the folder. | `tests/Uninstall.Tests.ps1`, `tests/UninstallWait.Tests.ps1` |
| Store uninstall | Game Bar and existing protected package metadata are excluded. Preview and the removal boundary re-read the exact current full package identity and reject protected metadata or a sparse, unreadable or incomplete manifest; unknown package inventory retains the selection. Discovery uses the same manifest rule, and app-cache v7 invalidates older rows. | `tests/Uninstall.Tests.ps1` |
| Leftover recovery | `ITransferSource.RecycleItem` is used on fixed local drives, with no permanent-delete fallback. Identity and descendant protection are rechecked. Recycled bytes do not count as freed disk space. | `tests/Recycle.Tests.ps1` |
| Analyze deletion | Explicit selection/confirmation, raw path validation, ancestor identity binding, protected-descendant inspection and a final recheck precede the native shell operation. A generic name such as `build` is not a cleanable hint without a valid cache tag. | `cmd/analyze/windows_test.go`, `cmd/analyze/cleanable_test.go` |
| CLI installation/removal | Known files are merged without clearing shared directories. Unknown files and nonempty Git metadata survive self-removal. Linked install/config roots and ancestors and unrelated nonempty install roots are refused. A locked native launcher is rejected before PATH, shortcut or file mutation, with a direct PowerShell removal command. | `tests/Install.Tests.ps1`, `tests/InstallLifecycle.Tests.ps1` |

Automatic cleanup generally deletes permanently. Third-party uninstallers retain their own data-removal semantics. Analyze uses `SHFileOperationW` with undo support on fixed local drives and requests a Windows warning if the shell would permanently delete instead; this is not the same API or guarantee as leftover-only recycling. Windows shell behavior and user confirmation still matter.

## Protected Data and Privilege

`lib/core/base.ps1` distinguishes protected prefixes from exact protected roots. Windows, Program Files and security-sensitive stores remain protected; the user-profile root is protected without prohibiting all supported child caches. Empty or unparsable paths are refused. During automatic cleanup, additional exclusions cover key/configuration stores, browser state and Claude/Codex transcripts. Spotify Data and Storage are not automatic cleanup targets because they may contain offline media. The native Analyze policy is implemented separately and tested separately, not inferred from the PowerShell helper.

Application owner checks are fresh observations, not a shared lock held throughout deletion. An application can start after the last check, and the profile-enumeration deadline is checked between filesystem calls rather than interrupting a blocked kernel call. These guards do not establish an atomic ownership lease.

Literal path handling, no-follow inspection and identity rechecks reduce accidental traversal and replacement risks. These are path-based operations, not an atomic security boundary against a hostile process continuously replacing directory components between the last check and the operating-system call.

Commands run with the caller's Windows permissions. Administrator-only maintenance checks the current token; elevation is not permission to bypass protected paths. Verification uses mocked system actions and disposable fixtures. It does not stop the user's services, uninstall real applications or exercise UAC/MSI flows unless that specific test is authorized.

## Preview, Results and Diagnostics

`--dry-run` and `MOLE_DRY_RUN=1` prevent cleanup, optimization and uninstall mutations. Preview can still create its local report files. Dry-run tests assert that uninstallers, package removal and service mutations are not invoked. `mo uninstall` rereads each registration right before launch and refuses a changed or unreadable command; an entry gone before any uninstaller in the batch ran is left behind, not counted as uninstalled; it exits 1 when an app fails, keeps its entry, is left behind or is skipped as ineligible, while `mo clean` keeps exit 0. `--system` removes `C:\NVIDIA\DisplayDriver` version folders only when every entry is a week old and no process runs from that folder, both rechecked at removal.

Owner-cache preview records the resolved root without treating the whole store as reclaimable. Real accounting uses complete before/after measurements only when root identity is unchanged. A successful owner command can count as activity without an invented byte total. Delivery Optimization is the one service-mediated exception: Mole never deletes inside its root under the protected `C:\Windows`; it asks the service to delete finished, unpinned files one id at a time, previews the bytes the service reports for those files, and in a real run counts only files the service no longer lists, by the service's own size field rather than a filesystem measurement. A whitelist row on, above or below the root, an unanswered provider or a value in another shape keeps everything. A wildcard whose literal prefix may overlap the root, including one without a fixed prefix, is checked against every ancestor and every entry below the root without entering links; a match, a link, an unreadable entry or a walk that does not finish keeps everything. Native failures are checked through exit status rather than assumed to raise PowerShell exceptions.

`lib/core/log.ps1` and `cmd/analyze/oplog.go` append real outcomes to `~\.config\mole\operations.log`, escape control bytes, retry held files briefly, and send failed appends to debug diagnostics. Dry runs write no operation rows, `MO_NO_OPLOG=1` disables them, and self-removal preserves them. The log is neither tamper-resistant nor a transaction or crash-recovery guarantee; a completed filesystem action can still lose its log row. Proxy rendering sanitizes environment and WinINet inputs; malformed values are not echoed, preventing embedded proxy credentials from appearing in Status.

## Installation and Release Integrity

`lib/core/tui_binaries.ps1` compares downloaded Analyze/Status executables with the asset's SHA-256 entry in the release checksum file. A mismatch aborts that path rather than falling back to compilation. Source updates refresh both native tools and use release binaries only when source equivalence is established; otherwise Go is required. Installation and update fetch tags needed for this comparison.

[RELEASE.md](RELEASE.md) defines signing and publication. Published asset signatures, checksum readback and package-manager delivery are separate verification steps; source tests cannot prove them. Checksums served alongside assets are integrity checks within the same distribution trust boundary, not independent provenance. This review did not publish or validate a new signed release.

## Residual Closure Follow-up

Frozen source `d1ab34a2`, paired with Mole CLI (macOS) `32b70a91`. Repairs are `3b6b0b0b` (Store eligibility) and `20d12930` (lint enforcement). Every original limitation below was rechecked; W06 was a concrete fail-open defect rather than an unavoidable platform limitation. `Test-RemovableAppxManifest` now serves discovery and the final preview/removal guard: unreadable, empty, non-XML, incomplete or unrecognized external-content evidence retains the package. A readable ordinary manifest with no external-content flag, or an explicit false/0 flag, remains eligible. The inventory cache moves to v7 so stale rows lose the old authorization assumption. No command, flag or setting was added.

The old-source native run passed 142 tests and failed 11, including discovery and five unknown-manifest variants in preview and real mode. The repaired Uninstall, Router and UninstallWait set passed all 205 tests on both PowerShell 5.1.26100.9711 and 7.6.7 with Pester 6.2.0, zero failures/skips. The subsequent full-suite launches lost the Parallels execution-result channel; neither completion nor failure can be established, and retries stopped. The earlier 681-test receipts below are historical, not this revision's full-suite result. [Validation at `954312b5`](https://github.com/tw93/Mole/actions/runs/40250384601) then passed: PowerShell 5.1.26100.33648 and 7.6.7 each passed 692 tests with zero failures, skips, inconclusive or not-run cases, with Pester 6.2.0. The native Go, security and build jobs also passed; [Check](https://github.com/tw93/Mole/actions/runs/40250384539) enforced and passed lint. The later `ffcc9047` changes only CONTRIBUTORS.svg and skips CI; it does not inherit a claim of its own test execution.

Windows-target ARM64 and AMD64 lint are clean after explicitly handling the read-only metadata-handle close result. The Check workflow now requires lint success; `actionlint` passes. This changes a validation gate, not the delete authorization policy. Heuristic security-pattern warnings remain advisory and do not establish a comprehensive security scan. Cross-build/native-test evidence and delivery boundaries are retained in [the development record](docs/development-record.md#2026-10-26-residual-closure).

## Verification Evidence

The 2026-10-26 repair is `34f646c2`, based on `8bff8583`. `Remove-SafeItems` now rechecks its original path snapshot after the final owner callback, before both dry-run accounting and file removal. The single-item and directory helpers already performed the equivalent check. Three old-source cases failed for replaced files in real/preview mode and a parent changed to a junction; the unchanged-file positive control passed. This is a medium-severity local data-loss boundary, not a demonstrated privilege escalation.

- Windows 11 ARM64 VM, Windows PowerShell 5.1.26100.9711 and PowerShell 7.6.7, Pester 6.2.0: `scripts/test.ps1 -NoGo` passed 681 tests on each engine, zero failed, skipped, inconclusive or not-run, exit 0.
- Both engines parsed all 58 PowerShell source files. All three ARM64 Go test binaries passed natively; macOS-hosted `go test ./...`, Windows ARM64 vet and x64/ARM64 production cross-builds passed.
- The native Go runner initially used the SYSTEM default temporary directory, which correctly triggered protected-system-root refusals. Setting its process-local `SystemTemp` to the owned fixture directory corrected the harness; no production guard was weakened.
- Exact-revision CI is tracked under [the repair commit checks](https://github.com/tw93/Mole/commit/34f646c2/checks). Local results do not establish package delivery. The latest published runtime remains V1.39.0-windows; no release was made in this review.

Cross-CLI review checked busy-input gating, protected descendants, Jupyter targets and owner-cache physical exclusions. Windows already has busy gating and bounded protected-descendant review, has no Jupyter runtime producer, and retains its existing owner-root requery/identity policy. No platform-specific macOS paths were copied. The current vendor-wait and Adobe synchronization rows now agree with the existing V1.39.0-windows receipt; release metadata and tag ancestry were rechecked, without repeating artifact-download acceptance.

Historical evidence at `88cf57e8`: [Check](https://github.com/tw93/Mole/actions/runs/38382721940) and [Validation](https://github.com/tw93/Mole/actions/runs/38382721936) completed successfully. Validation included PowerShell 5.1 and 7, Go tests, native builds and protected-path checks. Later local evidence, fixture red runs and exact batch scope are in the [development record](docs/development-record.md). These runs do not establish current-HEAD validation.

The checks have specific limits:

- Go formatting, PowerShell parsing and pinned `golangci-lint` are enforced. The 2026-10-26 closure fixed the remaining Windows-target handle-close warning and removed `continue-on-error`; exact-revision CI still needs its own successful result.
- The unsafe-removal and secret-pattern steps print findings without failing. They are review prompts, not enforced security gates or a comprehensive secret scanner.
- Most recycle and uninstall tests use mocked sinks. `TestRecycleBinIntegration` is opt-in and requires an explicit disposable fixture. It is skipped by default. A separate ThinkPad run passed the real file/junction/directory recycle cases and PowerShell preview/recycle/restore checks; exact scope is recorded in the [development record](docs/development-record.md).
- A Parallels run and a GitHub-hosted Windows run do not establish ThinkPad acceptance. Record the actual machine, tested revision, runtime versions, test summaries, exit codes and skipped cases before making that claim.
- Interactive shell/Recycle Bin behavior, real UAC and third-party uninstallers, Defender/SmartScreen and signed distribution remain separate acceptance surfaces.

## Known Limitations

The original ten entries are individually closed as a repair or an explicit retained boundary. They are not ten remaining implementation defects.

| ID | Disposition | Reason and current boundary |
| --- | --- | --- |
| W01 | No code change | Permanent cleanup has no general undo, and multi-file failure can leave partial completion. Switching every cleanup to recycling would change the existing reclaim-space contract. |
| W02 | No code change | Final path/owner rechecks close demonstrated stale-evidence gaps, but cannot make a filesystem or third-party owner action atomic. |
| W03 | No code change | Analyze checks a ten-second traversal budget and 100,000-entry cap. A blocking filesystem-provider call is not forcibly cancellable through that API; oversized or incomplete inspection retains the target. |
| W04 | No code change | Native recycling waits for the shell's result. A timer cannot safely turn an unknown in-flight operation into success or undo it. |
| W05 | No code change | Cache tags are owner declarations used for Analyze hints, not automatic deletion authorization or proof that contents are unimportant. |
| W06 | Fixed and regression-tested | Unknown Store manifest evidence no longer allows listing or removal. Discovery, preview and the final boundary share the conservative predicate; ordinary-package positive controls remain eligible. |
| W07 | No code change | Leftover ownership uses complete registered locations and current-user Appx inventory. Unregistered portable applications and missing vendor metadata have no exhaustive authoritative inventory; broad guesses would weaken protection. |
| W08 | No code change | Purge deliberately isolates Git configuration. A repository refused by Git keeps its artifacts even when the user's global safe.directory lists it. Accepting untrusted configuration to reclaim more would weaken the execution boundary. |
| W09 | No code change | Vendor waiting preserves process-tree semantics and stops the batch on timeout/cancellation without killing the vendor. Native process launch/UAC and detached services are outside that wait's cancellation guarantee; registration disappearance or idleness does not prove completion. |
| W10 | Ongoing verification | Controlled fixtures and hosted CI do not prove every filesystem provider, running application, real UAC/uninstaller, physical machine or signed package. Missing execution evidence stays unverified, including this follow-up's interrupted VM result channel. |

For private vulnerability reporting, see [SECURITY.md](SECURITY.md). Keep this review aligned with changed safety boundaries and retain dated runtime evidence in the development record.
