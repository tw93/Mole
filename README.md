<div align="center">
  <h1>Mole</h1>
  <p><b>Deep clean, uninstall apps, optimize, analyze disk, and monitor your Mac. Free open-source CLI, plus a native Mac app.</b></p>
  <p>English · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Mole cleanup results" width="1000" />
</p>

> 💡 This repo is the free open-source CLI (`mo`). Prefer a native app? [Mole for Mac](https://mole.fit/) is a separate download with review-before-delete cleanup, tested leftovers for 800+ apps, maintenance, disk drill-downs, live status, and fan controls on supported Macs. `brew install mole` installs the CLI only.

## Features

- **All-in-one CLI toolkit**: Combines CleanMyMac, AppCleaner, DaisyDisk, and iStat Menus style workflows in one terminal command
- **Deep clean**: Removes caches, logs, leftovers, and orphaned app data to reclaim disk space
- **Smart uninstaller**: Removes apps together with LaunchAgents, preferences, and leftovers
- **Disk analyzer**: Visualizes disk usage with an interactive TUI, finds large files, and navigates directories
- **System maintenance**: Flushes DNS, refreshes QuickLook/icons, and optimizes system databases
- **Live monitoring**: Shows real-time CPU, memory, disk I/O, network traffic, and process stats

## Quick Start

Mole requires macOS 12 or newer and supports both Intel and Apple Silicon Macs. If Homebrew no longer supports your macOS version, use the script install instead. An experimental Windows version lives in the [windows branch](https://github.com/tw93/Mole/tree/windows).

**Install via Homebrew**

```bash
brew install mole
```

**Or via script**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**Run**

```bash
mo                           # Interactive menu
mo clean                     # Deep cleanup + already-uninstalled app leftovers
mo uninstall                 # Remove installed apps + their leftovers
mo optimize                  # Refresh caches & services
mo analyze                   # Visual disk explorer (or 'mo analyse')
mo status                    # Live system health dashboard
mo purge                     # Clean project build artifacts
mo installer                 # Find and remove installer files

mo touchid                   # Configure Touch ID for sudo
mo completion                # Set up shell tab completion
mo update                    # Update Mole
mo update --nightly          # Update to latest unreleased main build, script install only
mo remove                    # Remove Mole from system
mo --help                    # Show help
mo --version                 # Show installed version
```

**Preview safely**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Preview + detailed logs
mo optimize --whitelist      # Manage protected optimization rules
mo clean --whitelist         # Manage protected caches
mo purge --paths             # Configure project scan directories
mo analyze /Volumes          # Analyze external drives only
mo analyze /private/tmp      # Review user-owned temporary directories
```

<details>
<summary><strong>Other install options</strong></summary>

To install a specific release, pass any tag from the [releases page](https://github.com/tw93/mole/releases), with or without its leading `V`. To track the development branch instead, pass `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` installs unreleased code from the default branch, so expect rough edges. `latest` still works as a legacy alias for `main`; despite the name it does not install the newest stable release.

The script normally installs to `/usr/local/bin`, which may ask for an administrator password. Install into a user-owned directory if you want future `mo update` runs to stay password-free:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Add the same `PATH` export to `~/.zshrc` or your shell profile for new terminals. Mole updates the installation you invoked, so it keeps using this directory. Commands that change system-owned files may still request administrator access.

**Nix**

On macOS, Nix users can install the flake from `main`, which contains unreleased changes:

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

For a declarative installation, add `github:tw93/mole/main` as a flake input and use its `packages.${system}.mole` package. Update or remove Mole through Nix; `mo update` and `mo remove` leave Nix-managed installations unchanged.

</details>

## Safety

Mole can remove files, so it validates paths, protects shared and system-owned locations, and asks for confirmation when an action needs it. When Mole cannot prove an item is safe to change, it skips or refuses it.

- `clean`, `uninstall`, `purge`, `installer`, and `remove` can delete files, so review them with `--dry-run` first and add `--debug` when needed
- Run Mole without `sudo`; it requests administrator access only when needed
- `mo analyze` moves selected items to Trash after confirmation
- Cleanup activity is recorded in `~/Library/Logs/mole/operations.log`; review it with `mo history` or disable it with `MO_NO_OPLOG=1`
- Protect caches with `mo clean --whitelist`, or maintenance items with `mo optimize --whitelist`

Review [SECURITY.md](SECURITY.md) and [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for reporting guidance, safety boundaries, and current limitations.

## Features in Detail

The examples below are shortened. Available items, sizes, and skip reasons depend on your Mac.

### Clean

`mo clean` reviews known-safe caches, logs, temporary files, developer artifacts, and leftovers from apps that are no longer installed. It empties the Trash by default; to keep it, select Trash in `mo clean --whitelist`, the same menu that protects caches you want to keep. Selections persist in `~/.config/mole/whitelist`. Before adding custom paths, open the menu and press Enter to save the selections, then append one path per line. An existing file replaces the optional defaults; built-in safety protections still apply.

```text
$ mo clean

Clean Your Mac

⚙ Apple Silicon | Free space: 219.0GB

➤ User essentials
  ✓ User app cache · 18 items, 2.4GB
  ✓ User app logs · 7 items, 12.8MB
  ✓ Trash · emptied, 9 items

➤ App caches
  ✓ App Store cache · 8 items, 248.5MB

➤ Browsers
  ✓ Safari cache · 24 items, 642.1MB
  ✓ Chrome cache · 31 items, 1.2GB

➤ Developer tools
  ✓ npm cache · cleaned
  ◎ pnpm cache · skipped (pnpm busy)

======================================================================
Cleanup complete
Tracked cleanup: 4.5GB | Items cleaned: 97 | Categories: 4
Free space: 223.5GB (+4.5GB)
======================================================================
```

### Uninstall

`mo uninstall` removes an installed app together with related files that Mole can tie back to that app. It keeps shared data when another installed copy still uses it. If the app is already gone, use `mo clean` to look for leftovers.

```text
$ mo uninstall

Select Apps to Remove  1/3 selected

➤ ● Photoshop 2024                4.20GB | 2mo ago
  ○ IntelliJ IDEA                 2.80GB | 3d ago
  ○ Premiere Pro                  3.40GB | 2w ago

Files to be removed:

✓ Photoshop 2024, 12.80GB
  ✓ /Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app
  ✓ ~/Library/Application Support/Adobe/Adobe Photoshop 2024
  ✓ ~/Library/Preferences/com.adobe.Photoshop.plist

======================================================================
Uninstall complete
Removed 1 app, freed 12.80GB: Photoshop 2024
======================================================================
```

### Optimize

`mo optimize` runs bounded maintenance for supported Finder, network, database, and macOS services. Tasks that are unnecessary, unsafe at the moment, or unavailable are skipped with a reason. Use `mo optimize --whitelist` to exclude tasks or path patterns, such as a long-lived mounted disk image at `/Volumes/mail` that should not show up as a detach candidate.

```text
$ mo optimize

Optimize

⚙ System  18/32 GB RAM | 616/926 GB Disk | Uptime 6d

PERFORMANCE DIAGNOSIS
  ✓ No sustained high-CPU bottleneck detected

➤ DNS & Spotlight Check
  → DNS cache flushed
  → Spotlight index verified

➤ Finder Cache Refresh
  → QuickLook thumbnails refreshed
  → Icon services cache rebuilt

➤ Database Optimization
  ◎ Close these apps before database optimization: Safari

➤ Disk Health
  → Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)

======================================================================
Optimization Complete
Applied 3 optimizations
14 unchanged | 3 skipped | 1 unavailable
======================================================================
```

### Analyze

`mo analyze` opens a terminal disk explorer. It supports arrow keys and Vim navigation, filtering, multi-selection, Finder preview, and confirmed moves to Trash. External drives are skipped from the default overview; inspect them with `mo analyze /Volumes` or a specific mount path. Use `mo analyze /private/tmp` to review user-owned temporary files without turning them into automatic cleanup targets.

A size ending in `+` contains measured bytes from a partial scan; `unknown` means the size could not be measured. Results cut short by temporary failures such as timeouts do not replace complete cached measurements, and a later refresh can recover the missing data. Folders macOS will not let the terminal read stay partial until access changes. The terminal list keeps the 30 largest entries, so an unreadable entry may fall outside that list; the total still indicates a partial scan. Directory JSON output includes all scanned entries.

`mo analyze --json /path` includes `scan_status` on the result and each entry: `complete`, `partial`, or `unavailable`. Numeric sizes contain measured bytes; a zero with `unavailable` does not mean an empty directory. Partial scans still exit successfully, so automation should inspect `scan_status`. Completeness applies within Mole's existing scan exclusions and does not promise an atomic filesystem snapshot.

```text
$ mo analyze

Analyze Disk  (302.1GB free)
Select a location to explore:

 ▶  1. ████████████████████████  47.9%  |  Home                       75.4GB
    2. ███████████               22.0%  |  User Library               34.6GB
    3. ███████                   14.2%  |  Applications               22.4GB
    4. █████                     10.7%  |  System Library             16.9GB
    5. ███                        5.2%  |  Old Downloads (90d+)       8.2GB  >3mo
```

### Status

`mo status` is a read-only dashboard for hardware, system pressure, disk activity, network traffic, power, and processes.

When the IPv4 default route uses a tunnel, network graphs use that interface’s rates to avoid counting the same traffic again on its physical carrier. JSON retains per-interface rates, including the routed tunnel; idle non-default tunnels stay hidden.

```text
$ mo status

Mole Status  Health ● 92  MacBook Pro · M4 Pro · 32GB · macOS 26

⚙ CPU                                    ▦ Memory
Total   ████████████░░░░░░░  45.2%       Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (8 cores)     Total   18.7 / 32.0 GB
Core 1  ███████████████░░░░  78.3%       Free    ████████░░░░░░░░░░  41.6%
Core 2  ████████████░░░░░░░  62.1%       Avail   13.3 GB

▤ Disk                                   ⚡ Power
Used    █████████████░░░░░░  67.2%       Level   ██████████████████  100%
Free    156.3 GB                         Status  Charged
Read    ▮▯▯▯▯  2.1 MB/s                  Health  Normal · 423 cycles
Write   ▮▮▮▯▯  18.3 MB/s                 Temp    58°C · 1200 RPM

⇅ Network                                ▶ Processes
Down    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s      Zombies 3 · Chrome (4242) ×3
Up      ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s      Code       ▮▮▮▮▯  42.1%
Proxy   HTTP · 192.168.1.100             Chrome     ▮▮▮▯▯  28.3%
```

The health score combines CPU, memory, disk capacity, SMART status, I/O, thermals, battery state, and uptime, with color-coded ranges. Press `k` to toggle the cat, `c` to cycle the number of CPU cores shown, or `q` to quit; display preferences are saved.

<details>
<summary><strong>JSON, NDJSON, and process alerts</strong></summary>

- `mo analyze --json ~/Documents` returns a one-time disk report as JSON
- `mo status --json` returns a one-time status snapshot as JSON
- `mo status | jq '.health_score'` switches to JSON automatically when output is piped
- `mo status --watch --interval 2s` streams newline-delimited JSON from a warm collector
- `mo history --json` returns cleanup activity as JSON. Sessions include `run_id` (an opaque string, empty when no identity was logged) and `attribution`: `run` for identified runs, `command` for legacy command-based grouping, or `ambiguous` when legacy markers cannot distinguish interruption from overlapping runs. Recorded actions remain available; ambiguous counts cannot be assigned reliably to individual runs. An empty `ended_at` means no end marker was recorded

```text
$ mo analyze --json ~/Documents
{
  "path": "/Users/you/Documents",
  "overview": false,
  "entries": [
    { "name": "Library", "path": "...", "size": 80939438080, "is_dir": true }
  ],
  "large_files": [
    { "name": "backup.zip", "path": "...", "size": 8796093022 }
  ],
  "total_size": 168393441280,
  "total_files": 42187
}

$ mo status --json
{
  "host": "MacBook-Pro",
  "health_score": 92,
  "cpu": { "usage": 45.2, "logical_cpu": 8 },
  "memory": { "total": 34359738368, "used": 20078972109, "used_percent": 58.4 },
  "disks": [],
  "process_collected_at": "2026-08-29T12:30:00Z",
  "process_stale": false,
  "zombie_count": 3,
  "zombie_parents": [
    { "pid": 4242, "name": "Google Chrome for Testing", "count": 3 }
  ],
  "zombie_parents_complete": true,
  "uptime": "3d 12h 45m"
}
```

Zombie diagnostics are read-only and do not affect the health score or terminate processes. Before
Mole has a successful process sample, `process_collected_at`, `process_stale`, `zombie_count`, and
`zombie_parents_complete` are omitted and `zombie_parents` is `null`. Later fast/watch snapshots
reuse the latest successful sample with its original `process_collected_at` and set
`process_stale: true`; a live process sample sets it to `false`. A count of `0` means Mole measured
no zombies. Parent summaries contain at most three known owners;
`zombie_parents_complete: false` means attribution was unavailable, incomplete, or truncated.

If one collector fails, `mo status --json` still prints the metrics that were collected, reports the
failure on stderr, and exits successfully, the same way `--watch` keeps streaming. It exits 1
when none of CPU, memory, disk, or process metrics are available, or when JSON output fails.

Status also supports read-only alerts for processes that stay above a CPU threshold. Use `--proc-cpu-threshold`, `--proc-cpu-window`, or `--proc-cpu-alerts=false` to tune or disable them.

</details>

### Purge

`mo purge` finds rebuildable project artifacts such as `node_modules`, `target`, `.build`, `build`, and `dist`. It groups artifacts by project and permanently deletes only the items you confirm. Artifacts with file activity in the last 7 days, or activity Mole cannot verify, are unselected by default. Mole uses `fd` when available and falls back to `find`, and protects directories containing deployment keypair files, nested Git repositories, or Git-tracked files. Non-interactive runs require `mo purge --yes`; use `mo purge --dry-run` to review the candidates first.

Use Page Up/Down or `h`/`l` to move a page, `[`/`]` to jump between projects, and `X` to skip a project and advance. `/` searches project paths and artifact names, `n` finds the next match without changing selections, and Enter opens the final path review. Reported space is an estimate; unmeasured artifacts and incomplete scans are identified explicitly.

<details>
<summary><strong>Purge example output</strong></summary>

```text
$ mo purge

Purge Project Artifacts

Select Artifacts to Purge
6.00GB, 2 selected

➤ ● ┌ ~/Projects/website        3.80GB | node_modules | 28d
  ○ └ ~/Projects/website         186MB | dist         | <1d
  ● ┌ ~/Projects/rust-app       2.20GB | target       | 2mo
  ○ └ ~/Projects/rust-app         22MB | dist         | <7d

======================================================================
Purge complete
Estimated space freed: 6.00GB | Items: 2 | Free: 223.5GB
======================================================================
```

</details>

<details>
<summary><strong>Custom Scan Paths</strong></summary>

Run `mo purge --paths` to configure scan directories, or edit `~/.config/mole/purge_paths` directly:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

When custom paths are configured, Mole scans only those directories. Otherwise, it uses defaults like `~/Projects`, `~/GitHub`, `~/dev`, and supported agent worktree containers. Discovery does not save an incomplete result. Artifact scans reach six levels below each configured root; add a nearer root for deeper projects. Purge removes rebuildable artifacts inside worktrees, never the worktrees themselves.

</details>

### Installer

`mo installer` finds DMG, PKG, MPKG, ISO, XIP, and installer ZIP files in Downloads, Desktop, Homebrew caches, iCloud, Mail, Telegram, and other supported locations, and shows each item's size and source before removal. Discovery has a cumulative time limit: if a scan or metadata probe fails or times out, Mole discards the list and exits without selecting files. Corrupt and unreadable ZIP archives are skipped, symlinked scan roots are supported but symlinks beneath them are not followed, and selected files are checked again against their confirmed identity at the deletion boundary.

<details>
<summary><strong>Installer example output</strong></summary>

```text
$ mo installer

Select Installers to Remove, 3.83GB, 5 selected

➤ ● Photoshop_2024.dmg          1.20GB | Downloads
  ● IntelliJ_IDEA.dmg          850.6MB | Downloads
  ● Illustrator_Setup.pkg      920.4MB | Downloads
  ● PyCharm_Pro.dmg            640.5MB | Homebrew
  ● Acrobat_Reader.dmg         220.4MB | Downloads
  ○ AppCode_Legacy.zip         410.6MB | Downloads

======================================================================
Installers cleaned
Removed 5 installers, freed 3.83GB
======================================================================
```

</details>

## Quick Launchers

<details>
<summary><strong>Raycast and Alfred setup</strong></summary>

Install five launchers for Clean, Uninstall, Optimize, Analyze, and Status:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

The script adds Raycast commands and, when Alfred preferences are present, matching Alfred workflows with the keywords `clean`, `uninstall`, `optimize`, `analyze`, and `status`.

Raycast needs one manual setup:

1. Open **Raycast Settings > Extensions > Script Commands**.
2. Add `~/Library/Application Support/Raycast/script-commands` as a script directory.
3. Run **Reload Script Directories** in Raycast.

The launchers auto-detect Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm, and Warp. Set `MO_LAUNCHER_APP=<name>` to choose one; you can also run Mole directly in [Kaku](https://github.com/tw93/Kaku).

</details>

## Community

Thanks to everyone who helped build Mole. Go follow them. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole contributors" width="1000" />
</a>

<br/><br/>
Real feedback from users who shared Mole on X.

<img src="./docs/img/mole-love.png" alt="Community feedback on Mole" width="1000" />

Watch the [Mole tutorial video](https://www.youtube.com/watch?v=UEe9-w4CcQ0) by PAPAYA 電腦教室.

## Support

- Getting [Mole for Mac](https://mole.fit) is the most direct way to support Mole's development
- If Mole helped you, give it a star, [share it](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.), or open an issue or PR
- I have two cats, TangYuan and Coke, and if Mole makes your life a little easier, feel free to treat them to <a href="https://cats.tw93.fun?name=Mole" target="_blank">canned food 🥩</a>

<details>
<summary>These lovely people already did 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="Mole supporters" width="1000" loading="lazy" /></a>
</details>

## License

Mole is open source under GPL-3.0; see [LICENSE](LICENSE). Any modified version you share must remain under the same license. If you fork Mole, please use a distinct name and credit Mole as the upstream source. [Mole for Mac](https://mole.fit) is a separate proprietary app, and Mole is here for the long run.
