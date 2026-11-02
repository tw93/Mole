# Open-source research for the Windows CLI

What Mole CLI (Windows) learns from open-source Windows cleanup, uninstall, maintenance and disk tools: rules and failure modes, never code. Mole for Windows ran these studies from 2026-09-24 for its own surfaces and keeps its notes in its own record; this file holds the public, CLI-side reading of the same repositories. Current policy stays in [AGENTS.md](../AGENTS.md), cross-product decisions in [SYNC.md](../SYNC.md); this file is the evidence and the queue.

## Repositories and baselines

The commit is the upstream head last read; the tag is the newest release it already contains. Read only the increment after this commit next time, and move the row when done.

| Repository | Commit | Read on | Release | Area |
| --- | --- | --- | --- | --- |
| BCUninstaller/Bulk-Crap-Uninstaller | `30da609` | 2026-10-29 | v6.3 | uninstall |
| Devolutions/UniGetUI | `10412d1` | 2026-10-31 | v2026.3.3 | updates |
| Romanitho/Winget-AutoUpdate | `19786f9` | 2026-10-24 | v2.12.0 | updates |
| MoscaDotTo/Winapp2 | `53ae419` | 2026-10-24 | v260915 | clean |
| bleachbit/bleachbit | `ace5da3` | 2026-10-31 | v6.0.6 | clean |
| qarmin/czkawka | `74c24a1` | 2026-10-31 | 12.0.2 | clean, analyze |
| ChrisTitusTech/winutil | `b521c90` | 2026-10-31 | 26.10.28 | clean, optimize, updates |
| farag2/Sophia-Script-for-Windows | `e35cf9d` | 2026-10-31 | 8.0.0 | optimize |
| hellzerg/optimizer | `cc88a0e` | 2026-10-24 | 16.7 | optimize (archived) |
| Raphire/Win11Debloat | `5d88bfe` | 2026-10-31 | 2026.08.24 | uninstall, optimize |
| memstechtips/Winhance | `db80ecf` | 2026-10-29 | v26.06.12 | optimize |
| Teraskull/PyDebloatX | `76869bb` | 2026-10-24 | 1.12.0 | uninstall |
| winsiderss/systeminformer | `fdd415a` | 2026-10-31 | v4.0.26241.138 | status |
| LibreHardwareMonitor/LibreHardwareMonitor | `1d74d0e` | 2026-10-29 | v0.9.6 | status |
| namazso/PawnIO | `9d52965` | 2026-10-24 | 2.2.0 | status |
| zhongyang219/TrafficMonitor | `930f175` | 2026-10-24 | V1.86 | status |
| prometheus-community/windows_exporter | `de024ce` | 2026-10-31 | v0.32.1 | status |
| rainmeter/rainmeter | `54df773` | 2026-10-29 | v5.0.0.5293 | status |
| windirstat/windirstat | `aa92f34` | 2026-10-31 | release/v2.9.3 | analyze |
| dundee/gdu | `b723b70` | 2026-10-29 | v5.38.0 | analyze |
| bootandy/dust | `b6c6d8d` | 2026-10-31 | v1.2.5 | analyze |
| bmrf/tron | `552aa36` | 2026-10-31 | v13.0.0 | optimize |
| ios12checker/Windows-Maintenance-Tool | `939b856` | 2026-10-24 | v6.7 | optimize |
| Chuyu-Team/Dism-Multi-language | `875bce3` | 2026-10-24 | v10.1.1002.2 | clean |
| BluePointLilac/ContextMenuManager | `5550715` | 2026-10-24 | 3.3.3.1 | context menu |
| microsoft/PowerToys (FileLocksmith only) | `8827f84` | 2026-10-31 | v0.103.3012 | file locks |
| alienator88/Pearcleaner | `7724df7` | 2026-10-24 | 5.4.3 | uninstall (macOS) |
| velopack/velopack | `59d55ca` | 2026-10-24 | 1.3.39 | self update |
| harry0703/MangoDisk | `4285d46` | 2026-10-29 | v1.2.1 | all surfaces |
| builtbybel/FluentCleaner | `8515c52` | 2026-10-31 | 26.09.01 | clean |
| Kiowx/c_cleaner_plus | `db4839f` | 2026-10-31 | v0.8.2 | clean, analyze |
| Atlas-OS/Atlas | `1ed9630` | 2026-10-29 | 0.5.0-hotfix | optimize |
| zoicware/RemoveWindowsAI | `3ac2a95` | 2026-10-31 | - | optimize, uninstall |
| lostindark/DriverStoreExplorer | `545271a` | 2026-10-29 | v1.0.36 | driver store |
| henrypp/memreduct | `04402de` | 2026-10-29 | v.3.5.2 | memory |
| itsfatduck/optimizerDuck | `c4f2f50` | 2026-10-29 | v2.29.0 | optimize, clean |

Licenses differ (GPL, MPL, CC-BY-SA for Winapp2's database). Copyleft rule sets are leads only: each path is measured on Windows and written by hand, and no rule text is imported.

## Criteria that held across every study

- Rule databases (Winapp2, BleachBit CleanerML, Dism++ `Data.xml`) are written for unticked or tiered rows. Mole's clean rows run by default, so a path from them needs a Windows measurement and an owner guard before it becomes a target.
- Maintenance scripts (Tron, Windows-Maintenance-Tool) elevate up front and run every repair without a symptom. What transfers is their guards, such as no disk writes on a failing disk and no long jobs on low battery, not the actions.
- Uninstallers agree on one floor: remove only what is provably the program's. Mole's ownership checks and Recycle-only leftovers are stricter than BCU's exclusion lists and Revo's bold rows.
- Status tools teach sampling engineering (one collector per source, a missing counter is no value, not a failure) more than new readings.

## Directions already rejected

Restore points, parallel or auto-clicked uninstall wizards, running everything elevated, killing user processes or closing their handles, deleting folders instead of uninstalling, generic registry cleaning, clearing event logs and update history, installer caches (`Installer`, `Package Cache`, `MSOCache`, ClickToRun), WinSxS ResetBase, CompactOS, driver-store cleanup, Prefetch and thumbnail or icon caches, telemetry, Defender, UAC, SmartScreen, service and power-plan toggles, removing provisioned packages for all users, extension-wide disk sweeps, cloud-drive caches, chat history and login state, memory "cleaning", Docker `prune`. Reopen one only with a new measured reason.

## 2026-11-02 CLI-angle pass

Baseline: this branch at `541bea53`. Earlier studies read these repositories against the app; this pass reads them against the CLI's own code. Gaps 1 and 3 to 6 and the candidates were implemented the same day; each item says what landed and what did not.

### Gaps found in the CLI

1. Analyze counts OneDrive online-only files at full size. `cmd/analyze/scanner.go:337` and `live_scan.go` add `info.Size()` for every file, so a placeholder that occupies no disk can lead the largest-files list and push totals past the volume's used bytes. Check `FILE_ATTRIBUTE_RECALL_ON_OPEN` (`0x40000`) and `RECALL_ON_DATA_ACCESS` (`0x400000`) from the attributes `FindNextFile` already returned, and never open such a file, since opening recalls it. gdu (`pkg/analyze/dir_other.go`) treats them as 0 but uses `0x100000`, which is `UNPINNED`; do not copy that constant. dust groups the same bits as `IS_PROBABLY_ONEDRIVE`. Landed in `cmd/analyze/disk_size.go`: online-only files count 0 with no call, partly downloaded ones use their allocation.
2. `C:\Windows\SystemTemp` is never cleaned. In `lib/clean/system.ps1` the "System temp (different from Windows temp)" branch reads `$env:SYSTEMROOT\Temp`, which is the same folder as `$env:WINDIR\Temp`, so the branch never runs. Since 24H2, SYSTEM services write to `SystemTemp`. Not done: `C:\Windows` is in `$script:ProtectedPaths` and AGENTS.md forbids routing around that list, so `SystemTemp` stays out of reach; only the dead branch was removed.
3. `mo clean` and `mo uninstall` exit 0 after a partial failure. `mole.ps1` copies `$LASTEXITCODE` only for analyze, status and history; `bin/uninstall.ps1` prints "Uninstall incomplete" but sets no exit code. Scripts cannot tell a complete run from an incomplete one. Decided: `mo uninstall` now exits 1 when an app fails or keeps its uninstall entry. `mo clean` keeps exit 0, because locked files skipped on a recurring run are normal and would read as failures.
4. The uninstall command is not reread before launch. `bin/uninstall.ps1` builds the launch from the strings captured at inventory; a registration rewritten between selection and launch runs unreviewed. The window is short in a CLI, but the app already refuses a changed command. Landed: the entry is reread right before launch and a changed command is logged as failed and not run.
5. Retrim covers only the system drive (`bin/optimize.ps1`, `Optimize-Volume -DriveLetter $systemDriveLetter`). Windows-Maintenance-Tool and the app trim every fixed SSD volume and skip hard disks. Failure is already reported as failure. Landed: other lettered fixed NTFS or ReFS volumes are retrimmed when they sit on one partition of a healthy SSD; any inventory failure adds nothing.
6. Sparse and NTFS-compressed files (VHDX, WSL images, CompactOS trees) are shown at apparent size. Read `GetCompressedFileSize` only when the SPARSE or COMPRESSED attribute is set, through a `FILE_READ_ATTRIBUTES` handle so Defender does not scan the file (the dust approach). Hard links are counted per link, the same gap gdu and dust have; dedup only where it changes what the user sees. Landed for sparse and compressed files through `GetCompressedFileSizeW`; hard links are still counted per link.

### Clean target candidates (measure first, owner guard required)

- Electron leaves beside the existing Discord and Slack caches: `DawnGraphiteCache` and `DawnWebGPUCache` (BleachBit `discord.xml`, `slack.xml`, `docker.xml`). Not `Shared Dictionary`, `Local Storage`, `Session Storage`, `Network Persistent State` or cookies, which are persistent state. Not done for stable Discord and Slack: not measured there yet.
- Discord PTB and Canary (`discordptb`, `discordcanary`), Chrome Beta and Canary, Edge Beta and Dev, each guarded by its own process. Landed, the preview channels guarded by the stable browser's image.
- Apps the app measured on Windows on 2026-10-24: Kiro, CodeBuddy, Qoder, Trae (cache and week-old logs), Tencent Meeting, Baidu Netdisk and Docker Desktop logs, WPS logs, 360 Chrome, Quark, JianyingPro and CapCut, QQ NT, Feishu and Lark. Landed as cache leaves and week-old top-level log files. Not done: Trae and Qoder logs, which keep one folder per session that `Remove-OldFiles` does not reach; Docker and WPS keep most logs in subfolders, so their rows reach little.
- Delivery Optimization files through the service's own interface, never by deleting the folder; `C:\NVIDIA\DisplayDriver` extraction folders older than seven days, administrator only, never the rest of `C:\NVIDIA`. Landed in `lib/clean/system.ps1` under `--system`.

### Checked and already handled

- Junctions, symlinks and cycles in Analyze: `cmd/analyze/platform_windows.go:isLinkEntry` labels name surrogates and the walk only descends into directories; the recycle guard binds volume and file IDs without following reparse points. Stricter than gdu, which deletes with no guard.
- Worker cap and inline fallback (`cmd/analyze/scanner.go`), access-denied folders marked incomplete, display-cell widths for CJK names.
- Uninstall detection against BCU: MSI product codes with `REBOOT=ReallySuppress`, Inno `unins###.exe` plus `.dat`, NSIS markers, and success judged by the registration disappearing rather than the exit code, so 3010 and 1641 cannot be misread. BCU's fuzzy `QuietUninstallString_hidden` read and junk-confidence scoring are not taken.
- Personal data BleachBit deletes and Mole refuses: VS Code `User\History` and `.claude\projects` are protected segments in `lib/core/base.ps1`, locked by `tests/Protection.Tests.ps1`; Recent items are protected; Thunderbird `signons` and cookies, Office Recent and Zoom recordings under Documents are not targets. A future Thunderbird or Zoom row takes only cache leaves.
- `wmic` and `Get-WmiObject`: absent from production scripts (Tron still depends on `wmic`, which Windows 11 no longer installs by default). The ban in `tests/Core.Tests.ps1` now names `wmic` and `gwmi` too.
- Get Help stays protected in uninstall; every protected segment the app's path guard lists is in `Test-ProtectedPath`.

### Open for measurement

- Recycle Bin icon: the app now notifies Explorer after a handle move; the CLI recycles through `ITransferSource::RecycleItem`, which may already refresh. Recycle one file into an empty bin with the desktop visible before deciding.
- Whether `Remove-SafeItem` reports a sharing violation (error 32) as in use rather than a generic failure.
- Winget-AutoUpdate v3.0.0 final release; Opera named profiles and Dawn leaves once Opera installs in the VM.
