# Mole CLI (Windows) Agent Guide

This file is the source of truth for any AI agent working on the `windows` branch of `tw93/Mole` (Claude Code, Codex, etc.). `CLAUDE.md` routes here without copying policy, including on Windows checkouts without symlink support. The macOS CLI lives on `main` with its own guide; do not apply macOS rules (`/System`, Bash 3.2, Bats) here.

## Product synchronization

Use these exact names in synchronization records: **Mole Mac**, **Mole for Windows**, **Mole CLI (macOS)** and **Mole CLI (Windows)**. These identify existing products, not a product rename; never use an unqualified "Mac", "Windows" or "CLI" when the destination is ambiguous.

Every checkout uses root `SYNC.md` as its synchronization entry point. `AGENTS.md` owns the workflow, `SYNC.md` owns cross-product decisions, development records own test/install receipts, and security reviews own residual risks. Reuse an existing entry and ID; link its owner instead of copying the backlog. Preserve dated evidence, but correct an obsolete current-status claim in place.

Before a sync, freeze all available source HEADs, branches, worktree changes and remote heads. Read the owning entries and production consumers, then inspect commits since their last reviewed source. Classify each destination as `Pending`, `Implemented`, `Intentional difference` or `Not applicable`, with a reason and next check for anything unresolved. Record source commit/entry point, destination commit/entry point, verification evidence and delivery separately. Only a verified package/feed proves `Released`; pushed source, CI and a development installation do not. An unavailable checkout or missing evidence stays explicitly unverified.

Cover all four relationships when asked for a complete sync: the two apps, the two CLIs, Mole CLI (macOS) with Mole Mac, and Mole CLI (Windows) with Mole for Windows. Safety and correctness contracts transfer only after checking the destination's real consumer; platform APIs, GUI-only capabilities and private catalogs do not transfer automatically. No version bump, release, private-source disclosure or feature expansion is authorized merely by recording a row. Update the affected record and its source references in the same task, then verify every renamed path/link and report the remaining queue.

## Project

Mole CLI (Windows) is the free, open-source, terminal-first Windows maintenance CLI: PowerShell 5.1 scripts (`mole.ps1`, `bin/*.ps1`, `lib/**`), two Go TUIs (`cmd/analyze`, `cmd/status`) and the `mo.exe` launcher (`cmd/mo`) that package managers put on PATH. It is GPL-3.0, like `main`. Safety matters more than speed: a cleanup that deletes the wrong thing costs more than one that skips.

## Product Boundary

Mole for Windows, the paid native GUI, is a separate private product. This branch stays the narrower, scriptable CLI, the same relationship as the macOS CLI and Mole Mac: shared product values, no required feature parity.

Changes that come to this branch from the paid app:

- Safety fixes, such as a protected path or an over-broad match.
- Correctness fixes for a surface this CLI already has, such as uninstall sizes or duplicate entries.
- Public "never delete this" rules and exclusions.

Changes that stay out:

- GUI-only capabilities: third-party app updates, startup management, Doctor, tray, the treemap and MFT-based Analyze, deeper Status metrics, AI cleanup.
- The elevated batch protocol.
- The measured per-app uninstall leftover catalog.

A feature request asking for one of those gets a short "not planned for the CLI" answer, not a port. `mo update` remains Mole self-update; do not add package-manager upgrade wrappers or upgrade apps from `mo optimize` (maintainer decision 2026-10-25; rationale in `SYNC.md`, CLI-SYNC-08). Fixes found here, including community PRs, are an input for the paid app; route them through `SYNC.md`; keep private app implementation details in the app-owned record.

## Development continuity

Start resumed Windows CLI work with [the development record](docs/development-record.md), then verify the current branch, worktree, remote head and relevant CI. Its dated entries are evidence of past delivery, not current release status or authorization. Record completed batches with their scope, commits, verification and remaining delivery boundary; update an existing batch when new evidence arrives instead of starting a parallel ledger. Keep temporary runners, machine paths and raw logs out of this record.

Read [development pitfalls](docs/development-pitfalls.md) only when working on the matching PowerShell, launcher, Git, asynchronous TUI or Windows test boundary. Current policy stays in this guide; the reference explains failure mechanisms and points to regression tests. Add only a verified, non-obvious lesson or rejected alternative, preferably under an existing topic. Do not copy every small fix or successful check into permanent rules.

[Open-source research](docs/oss-research.md) lists the studied Windows tools with the upstream commit last read, the rejected directions and the open CLI candidates; read it before studying a tool again, read only the increment after its commit, and move the row when done.

[SECURITY_AUDIT.md](SECURITY_AUDIT.md) describes the Windows CLI safety model and verification limits. Update affected claims when deletion, ownership, privilege or distribution boundaries change. Keep CI, VM, physical-machine and signed-release evidence separate in the development record; an observed remote desktop or attempted command is not a completed hardware test. Machine connection details and raw diagnostics stay out of public documents.

Interactive size lists use `Format-SizeListEntry` for display-cell truncation and padding; .NET format widths and Windows ConsoleHost's width helper do not reliably count CJK cells. Store app display sizes use their read-only measurement, never deletion snapshots or elevated access. Neither a display measurement nor its cache grants deletion authority. Regression and ordinary-user evidence are in the development record.

The CLI itself is English-only and stays that way; only the README is translated. The README ships in nine languages: `README.md` plus `README_CN`, `README_TW`, `README_JA`, `README_KR`, `README_DE`, `README_FR`, `README_UA` and `README_RU`. Change the English text and every copy in the same task. Code blocks and sample output stay in English; only the `#` comments that explain commands are localized, and the Chinese copies follow the voice rules of the macOS README. Take shared wording (Community, Support, License) from the macOS translations in `tw93/Mole`. Each copy must keep the same headings, links, images and code blocks as the English one, and a new README file has to be added to `Get-MoleInstallEntries` in `install.ps1` or `mo remove` will not know it. Also include it in the release archive list in `scripts/build-release.ps1`; source-install ownership does not put files into the ZIP. `tests/Release.Tests.ps1` opens the staged ZIP and checks every linked README.

## Commands

```powershell
.\scripts\test.ps1                 # Pester tests and Go tests
Invoke-Pester -Path .\tests        # PowerShell tests only
go test ./cmd/...                  # Go tests only
go build -o bin\analyze.exe .\cmd\analyze
go build -o bin\status.exe .\cmd\status
$env:MOLE_DRY_RUN = "1"; .\mole.ps1 clean   # preview, no changes
.\mole.ps1 clean --dry-run
```

On macOS, `GOOS=windows go build ./cmd/...` and `gofmt -l cmd` check the Go side; PowerShell behavior needs Windows.

## Safety Rules

Area rules live in `.claude/rules/<area>.md`; each starts with `paths:` frontmatter, and Claude Code injects it only when a session touches matching files. **Codex and other runtimes that do not auto-load `.claude/rules` must open the matching file from this table before editing that area.** The rules below are the cross-cutting contract and apply to every area.

| File | Scope |
|---|---|
| `.claude/rules/clean.md` | `mo clean`: game media, Bun, Vesktop, Adobe, application and Chromium-family caches (Yarn Berry, NVIDIA, Sublime and the other exact leaves they name), `~/.gitconfig.lock`, system services, error reports, Delivery Optimization |
| `.claude/rules/uninstall.md` | `mo uninstall`: sizes, running each uninstaller once, Store eligibility, the charge-limit notice, identity rechecks before launch, exit codes (including `mo clean`'s), process waits, leftovers through the Recycle Bin |
| `.claude/rules/purge.md` | `mo purge`: artifacts in use, excluded and ecosystem-scoped artifact names |
| `.claude/rules/optimize.md` | `mo optimize`: Windows Update inspection, SFC, disk optimization and retrim, the battery aggregation `mo status` shares with it, what it never resets |
| `.claude/rules/install-update.md` | `install.ps1`, `mo update`, `mo remove`: the shared install folder, self-removal, package-manager installs, update notices |

- Delete only through `Remove-SafeItem`, `Remove-SafeItems`, `Remove-SafeDirectoryTree`, `Remove-OldFiles` and `Clear-DirectoryContents` in `lib/core/file_ops.ps1`. They go through `Test-SafePath` (protected paths and the whitelist) and honor dry-run mode. A raw `Remove-Item -Recurse -Force` is flagged by the Validation workflow.
- `Test-ProtectedPath` in `lib/core/base.ps1` fails closed: an empty or unparsable path counts as protected. Keep it that way.
- `$script:ProtectedPaths` (system roots such as `C:\Windows` and `C:\Program Files`) are protected with everything below them; `$script:ExactProtectedPaths` protects the user profile root itself while still allowing targeted cache cleanup under it (#1122). Add to these lists, never route around them.
- Every command that deletes or uninstalls (`clean`, `uninstall`, `purge`, `optimize`, `remove`) only reports in dry-run mode, whether set by `--dry-run` or `MOLE_DRY_RUN=1`; `remove` previews through `Uninstall-Mole -DryRun`, the same path as the real removal, and `bin/remove.ps1` refuses to preview with an installer that has no `-DryRun` parameter, since it would ignore the switch and uninstall. `install.ps1 -Uninstall` run directly previews only with its own `-DryRun` switch, not the environment variable. Locked by `Refuses to preview with an installer that cannot preview <_>` in `tests/Router.Tests.ps1`, `Previews removal through the real uninstall path` in `tests/Install.Tests.ps1` and `Previews Mole removal through <Shape><Label>` in `tests/Router.Tests.ps1`. `uninstall --dry-run` names the uninstaller it would run and starts none; `tests/DryRun.Tests.ps1` mocks `Invoke-MoleUninstallProcess` and `Remove-AppxPackage` to fail if called. Without a console (`Test-MoleInteractiveOutput` false), `purge --dry-run` previews every project and `uninstall --dry-run` prints the `--list` inventory, both exiting 0; a real run still needs the selection list. Locked by `Purge dry run without a console` in `tests/PurgeBoundary.Tests.ps1`, `Dry run without a console` in `tests/Uninstall.Tests.ps1` and `Previews the uninstall inventory without a console through <_>` in `tests/Router.Tests.ps1`.
- `~\.config\mole\operations.log` answers which command changed which path, when, and whether it went to the Recycle Bin. `Remove-SafeItem` and `Remove-SafeItems` append each real removal, recycle and failure (a partial folder with how many entries went and where it stopped), and a folder refused before anything was removed as `SKIPPED` with its reason, which `mo history` counts as skipped, `mo uninstall` each app outcome with its install folder, registry key and uninstaller command, `mo optimize` one `OPTIMIZED` or `FAILED` row per state change (Optimize-Volume, DNS flush, ARP clear, sfc), and `mo analyze` (Go, `cmd/analyze/oplog.go`) `RECYCLED`, `FAILED`, or `REMOVED` when the Recycle Bin did not grow after the shell's too-large prompt. All use the macOS CLI's line format with control characters escaped and the run from `_MOLE_OPLOG_RUN_COMMAND` / `_MOLE_OPLOG_RUN_ID`. Dry runs write nothing, `MO_NO_OPLOG=1` turns it off, a write failure never fails the removal (a held file is retried, a lost line goes to `--debug`), the log moves to `.old` past 5 MB, and `mo remove` keeps `operations.log*` when it deletes the config folder. Owner-cache commands record one `OWNER` outcome with the resolved root and command, or `FAILED` when incomplete, including whether `taskkill` confirmed process-tree termination, failed, or timed out; a successful command does not imply any particular file was removed. A new deletion sink records through the same format. Locked by the `Operation log` cases in `tests/Core.Tests.ps1`, `tests/Optimize.Tests.ps1`, `tests/Install.Tests.ps1` and `cmd/analyze/oplog_test.go`.
- The bulk delete helpers write nothing to the pipeline and count dry-run results too, so the clean summary and `clean-list.txt` match the preview. A caller that ignores `Remove-SafeItem`'s boolean assigns it to `$null`.
- The native spinner writes Unicode through `WriteConsoleW` on a real console, preserving the user's code page. Keep redirected output and explicit `Console.SetOut` capture working; do not repair missing Braille by changing global encoding. The console-buffer regression in `tests/UI.Tests.ps1` exercises the actual glyphs.
- Verify cleanup and uninstall changes with dry-run first; tests must not need a real UAC prompt.
- Tree and config-folder removal deletes each directory non-recursively (`[IO.Directory]::Delete($path, $false)`). `Remove-Item` without `-Recurse` on a folder that gained entries after the walk prompts to delete them, and a Yes removes unvalidated content. Locked by `Never deletes a folder recursively when it gained entries after the walk` in `tests/Core.Tests.ps1` and its config-folder twin in `tests/Install.Tests.ps1`.
- Content cleanup rejects a junction root or ancestor. Bind paths to Windows volume/file IDs before enumeration and sizing, and recheck after the final owner/guard callback before preview accounting or removal; a replaced file or directory is not the reviewed target. A leaf junction may be unlinked without traversing its target. Unknown identities and incomplete walks keep the target. Locked by the owner-check replacement and junction cases in `tests/CleanupBoundary.Tests.ps1`.
- A missing whitelist file is empty; unreadable metadata or content retains every target. Read its literal filename, including brackets, with terminating errors. Never turn unknown user protection into an empty list. Locked by `tests/CleanupBoundary.Tests.ps1`.
- A literal directory whitelist entry, including names containing brackets, covers its descendants but not prefix siblings. Check literal spelling before interpreting wildcard syntax. Every canonical whitelist row keeps its pattern, literal root, prefix and wildcard flag associated; mixed-rule sink regressions live in `tests/CleanupBoundary.Tests.ps1`. Native owner commands resolve their actual cache root, honor root and descendant exclusions, and recheck before mutation; an unknown root or failed owner command never falls back to direct deletion. Docker builder pruning stays off automatic cleanup because its remote or VM roots cannot be constrained by the local whitelist. Preserve Gradle transaction locks.
- `Test-ProtectedPath` refuses secret-store segments (`Microsoft\Credentials`, `Protect`, `Crypto`, `Vault`, `SystemCertificates`, `Start Menu`) for every command, and during `mo clean` also key folders (`.ssh`, `.aws`, `.azure`, `.kube`, `.docker`, `.gnupg`), browser profile stores and `.claude` / `.codex` transcripts, matching the Mole for Windows app's path guard. `GetFullPath` already expands 8.3 short names (`C:\PROGRA~1`) and trailing-dot aliases of a protected tree, and those cases pass on code that predates final-path resolution; existing paths also resolve to their final spelling so a junction or symbolic link into a protected tree is refused, and a path that exists but cannot be resolved counts as protected; nonexistent candidates keep the lexical answer so planning works. A whitelist root that is itself a junction is matched in both its typed and final spelling, and a candidate is checked against the whitelist and the protected rules in both spellings; otherwise moving `%USERPROFILE%\.cargo` to another drive would delete the protected cache, and a linked `Microsoft\Credentials` or `.ssh` folder would lose its segment guard. Clean never targets Zoom `data`, Teams databases and storage, Recent items and jump lists, Office and Outlook file caches, sync-client folders, cloud CLI credentials, installed toolchain packages (Stack `programs`, Cabal `store` and `packages`, Hex `packages`), Spotify `Data` and `Storage`, or dumps and logs at the profile root. Locked by `tests/Protection.Tests.ps1` and the `Test-ProtectedPath` cases in `tests/Core.Tests.ps1`.

## Compatibility

- The target is Windows PowerShell 5.1 on Windows 10 and 11. CI runs Pester under both Windows PowerShell 5.1 and pwsh 7; code that only works in pwsh 7 (`??`, `?.`, ternary, `-Parallel`) is a bug.
- `mo.exe` starts Windows PowerShell first and falls back to `pwsh.exe` only when that host cannot start, such as when policy blocks `powershell.exe`. A host that starts is never retried on the other host, so a command cannot run twice. The installer and `quick-install.ps1` run and generate `mo.cmd`, `mole.cmd` and the Start Menu shortcut with the host that invoked them, so a blocked `powershell.exe` is not reintroduced; a pwsh host writes the `pwsh.exe` on PATH, because a Store install's `$PSHOME` is a versioned folder its next update deletes. Keep `mole.ps1` runnable under both; do not use `Get-WmiObject`, which re-invokes `powershell.exe` through implicit remoting under PowerShell 7.
- Keep scripts ASCII or UTF-8 with BOM; Windows PowerShell 5.1 reads BOM-less non-ASCII text through the legacy code page.
- Go: the toolchain is pinned once, by `toolchain` in `go.mod`, and every workflow reads it through `go-version-file`.
- Analyze keeps every directly browsable child through live completion, cache returns and filtering. Recursive child summaries may remain bounded, but entering one must refresh it before claiming complete results. Restoring a selected path also clamps its viewport. Scan-time path indexes are invalidated after reorder, deletion, cancellation and completion; the existing display tick batches sorting/filtering without dropping completed results or cache updates. Locked by `cmd/analyze/directory_browsing_test.go` and `cmd/analyze/live_update_test.go`.
- Analyze registers scan identity before asynchronous dispatch and accepts only the current request, including when two requests use the same path. A deletion in progress ignores further action keys while retaining quit. Locked by `cmd/analyze/lifecycle_test.go`. Its Windows recycle guard also checks protected descendants and path identities immediately before the sink; incomplete walks keep the selection. A directory name alone is not proof it is cleanable; retain only explicit cache-tag evidence for that hint.
- Analyze sizes files by what they occupy (`cmd/analyze/disk_size.go`): an online-only cloud placeholder (RECALL_ON_OPEN, or RECALL_ON_DATA_ACCESS with OFFLINE) counts 0 with no call; partly downloaded placeholders, sparse and NTFS-compressed files use `GetCompressedFileSizeW`, capped at the length. Every other file keeps the listing's length with no extra call. Locked by `cmd/analyze/disk_size_test.go` and `disk_size_windows_test.go`.

The installed `.cmd` launcher keeps PowerShell's `-File` invocation. Resolve a PATH-provided pwsh through CMD's explicit PATH search, without embedding a non-ASCII host path in the ASCII batch or searching the caller's working folder; keep the shortcut's concrete host path separate. That call binds `--debug` to the router's common `Debug` parameter; translate it back into the existing command arguments before loading modules, and suppress PowerShell's own debug stream. The native launcher uses quoted argument literals with `-Command`. Verify both call shapes create a fresh session log; `tests/Router.Tests.ps1` locks them.

Parsed command arguments are data: do not strip literal quote characters a second time. Propagate native TUI exit codes and reset stale native status for help-only calls. Status proxy rendering never falls back to raw environment or registry values, which may contain credentials.

## CI

- `Check`: `gofmt -l` must be clean, PowerShell syntax must parse, the pinned golangci-lint check must pass. CI never commits on its own.
- Run `actionlint` on workflow changes before pushing; a step's `shell:` cannot read the matrix, which GitHub rejects before any job starts.
- `Validation`: Pester on both PowerShell versions, Go tests, binary build, security checks.
- `scripts/test.ps1` requires Pester's explicit passing result with at least one passed test. Missing results, empty or entirely skipped suites and failed Go probes are not success; only an explicit `-NoGo` skips Go. Locked by `tests/TestRunner.Tests.ps1`.
- Actions are pinned by commit SHA, the same versions `main` uses.
- CI runs only for changes it can judge (maintainer 2026-11-01): a push or PR that changes only documentation, images, `CONTRIBUTORS.svg`, `LICENSE` or issue templates runs neither Check nor Validation. The one-line `paths` lists keep `docs/incidents.md` (Check) and every root `README*.md` (Validation, packed by `Release.Tests`) in scope. A docs-only commit that adds, renames or deletes a file under `docs/`, `.github/` or the root still changes the install inventory that `Install.Tests` checks, so update `Get-MoleInstallNestedFiles` or `Get-MoleInstallEntries` in that commit; the next code push and the release workflow's own test run catch a miss.
- Incidents and risk (2026-10-26): a fix for a defect a user or a published release met adds its `docs/incidents.md` row in the same commit, naming the earliest layer that should have caught it and the test that catches it now; `scripts/check_incidents.py` (Check) fails a row whose commits, layer or catcher do not hold, and a changed review prompt is rescored against the table. The verification a change needs follows its paths, not its author: `python scripts/risk_tier.py` names the extra gates for release, install/update and deletion paths, and a commit in those tiers says in its body how it was verified. `tests/review_gates_test.py` (Validation) locks both.

Installer copies merge known source files without clearing shared destination directories. Reject unrelated nonempty roots and linked roots or ancestors. Keep the installer itself in copied installations. Whenever adding a shipped file, update `Get-MoleInstallNestedFiles` and run the install inventory test, including documentation-only changes. Source installation and update fetch release tags so native source-equivalence checks can use them; changed native source still requires Go.

## Windows e2e

`scripts/e2e_windows.py` runs on the maintainer's Mac and drives a real PC over SSH with a real terminal (`ssh -tt`, ConPTY on the PC): it deploys this checkout's HEAD with Go tools cross-built for the PC into a temporary folder, installs WinMerge's per-user setup after checking its GitHub digest and Authenticode signature, launches it, uninstalls it through `mo uninstall` by searching and selecting it, deletes the setup file from `mo analyze`, and runs every other command read-only. The PC's own Mole install is not touched. It refuses a PC that already has WinMerge or its settings, and writes `%LOCALAPPDATA%\mole-e2e\fixture.json` before installing so `--cleanup` removes only a fixture a failed run left. What its first runs found is in [development pitfalls](docs/development-pitfalls.md#cmd-launchers-and-powershell-binding).

- Preflight pins a full source commit; both the PowerShell files and Go binaries come from that commit's archive, never a mixture with uncommitted Go files. A failed prerequisite blocks dependent installation or mutation even with `--keep-going`; only independent checks may continue. `tests/e2e_harness_test.py` exercises these boundaries with mocks and runs in Validation, without SSH or a real install.
- One-time PC setup, in an administrator PowerShell: `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, `Set-Service sshd -StartupType Automatic`, `Start-Service sshd`, and append the Mac's `~/.config/mole-e2e/id_ed25519.pub` to `C:\ProgramData\ssh\administrators_authorized_keys` (ACL: Administrators and SYSTEM only). The built-in firewall rule covers only Private networks; add an inbound TCP 22 rule scoped with `-RemoteAddress` to the Mac's subnet instead of opening Public networks.
- Existing cmd.exe and PowerShell SSH default shells are supported; do not change the host shell for acceptance.
- The SSH session of an administrator holds an elevated token, so uninstallers that request elevation (WinMerge's does) run without a UAC prompt; the same uninstaller started from a normal desktop session waits on UAC.
- Run `scripts/e2e_windows.py --host user@address` on the Parallels VM (Parallels host-only rule `10.211.55.0/24`) and on the x64 ThinkPad before a release. Transcripts and `report.json` land in `~/Library/Logs/mole-e2e/windows-<run>/` on the Mac.

## Release

Read `RELEASE.md` before any release work. In short:

- Tags are `V<version>-windows`; a version with a pre-release segment publishes a prerelease. The version lives in `VERSION` and `lib/core/version.ps1`; bump both together.
- The workflow creates a draft. `scripts/sign-release.ps1` signs every `.ps1` and `.exe` on a Windows machine with the code-signing certificate (CI never has the key), then the signed files replace the draft's and it is published. Attestations are not used, because signing replaces the bytes CI built.
- Every Windows release keeps `make_latest: false`, because the macOS installer and `mo update` resolve stable versions through `releases/latest`.
- After publishing, add the six standard reactions (+1, laugh, heart, hooray, rocket, eyes) to the release as `tw93`, as every macOS release has; `RELEASE.md` has the command (maintainer, 2026-10-12).
- `scripts/build-release.ps1` produces every asset and calls `scripts/write-checksums.ps1`; `SHA256SUMS.txt` must list the zip and both TUI executables, since `lib/core/tui_binaries.ps1` refuses a download it cannot match and never falls back to building after a mismatch.
- Package-manager manifests are templates in `packaging/`, filled by `scripts/render-packaging.ps1` from the published `SHA256SUMS.txt`.
- Source updates refresh both native tools. First use with a missing binary in a source install checks the same source equivalence. A verified release binary may replace them only when the relevant local source matches that release; otherwise build the current source into a temporary output and retain the previous binary on failure. Report failure when the refresh cannot complete. One exception: with no copy of the tool installed and no successful build, a clean source whose HEAD descends from that release tag uses the verified release binary and says so, because every `cmd/` commit after a tag otherwise left Go-less fresh installs without status and analyze until the next release (mail report 2026-11-12, V1.44.0-windows); uncommitted edits and an existing older copy keep the build-only rule. Locked by `tests/InstallLifecycle.Tests.ps1`.
- Releases, tags and package-manager submissions need the maintainer's explicit go-ahead.

## GitHub

- Windows issues and PRs live in `tw93/Mole`; PRs target the `windows` branch. Prefer reviewing and merging a contributor PR over landing an equivalent fix yourself.
- Never point users to the private paid-app repository. Reply in the reporter's language, start with `@reporter`, and give the exact command to update: `mo update` for source installs.
