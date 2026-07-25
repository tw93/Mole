<div align="center">
  <h1>Mole</h1>
  <p><em>🐹 Clean, uninstall, analyze, optimize, and monitor your Mac from the terminal.</em></p>
</div>

<p align="center">
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</p>

<p align="center">
  <img src="https://gw.alipayobjects.com/zos/k/ro/ZzF8e8.png" alt="Mole - 95.50GB freed" width="1000" />
</p>

> 💡 The CLI is free and open source. Prefer a native Mac app? [Mole for Mac](https://mole.fit) adds visual cleanup review, app updates, uninstall, maintenance, disk maps, live status, and a menu bar HUD. One license covers 2 Macs, with lifetime updates and a 14-day refund.

## Features

- **All-in-one toolkit**: Combines CleanMyMac, AppCleaner, DaisyDisk, and iStat Menus in a **single binary**
- **Deep cleaning**: Removes caches, logs, leftovers, and orphaned app data to **reclaim gigabytes of space**
- **Smart uninstaller**: Removes apps plus launch agents, preferences, and **hidden remnants**
- **Disk insights**: Visualizes usage, finds large files, **rebuilds caches**, and refreshes system services
- **Live monitoring**: Shows real-time CPU, GPU, memory, disk, and network stats

## Quick Start

**Install via Homebrew**

```bash
brew install mole
```

Homebrew follows Homebrew's supported macOS tiers. Use macOS 14 or later for the Homebrew path; older macOS versions should use the script installer below on a best-effort basis.

**Or via script**

```bash
# Optional args: -s latest for main branch code, -s 1.17.0 for specific version
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

> Note: Mole is built for macOS. An experimental Windows version is available in the [windows branch](https://github.com/tw93/Mole/tree/windows) for early adopters.

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
mo history
mo history --json
mo purge --dry-run

# Also works with: optimize, installer, remove, completion, touchid enable
mo clean --dry-run --debug   # Preview + detailed logs
mo optimize --whitelist      # Manage protected optimization rules
mo clean --whitelist         # Manage protected caches
mo purge --paths             # Configure project scan directories
mo analyze /Volumes          # Analyze external drives only
mo analyze /private/tmp      # Review user-owned temporary directories
```

Selections made with `mo clean --whitelist` persist in `~/.config/mole/whitelist`.

## Security & Safety Design

Mole is a local system maintenance tool, and some commands can perform destructive local operations.

Mole uses safety-first defaults: path validation, protected-directory rules, conservative cleanup boundaries, and explicit confirmation for higher-risk actions. When risk or uncertainty is high, Mole skips, refuses, or requires stronger confirmation rather than broadening deletion scope.

`mo analyze` is safer for ad hoc cleanup because it moves files to Trash through Finder instead of deleting them directly.

Review [SECURITY.md](SECURITY.md) and [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for reporting guidance, safety boundaries, and current limitations.

## Tips

- Video tutorial: Watch the [Mole tutorial video](https://www.youtube.com/watch?v=UEe9-w4CcQ0), thanks to PAPAYA 電腦教室.
- Safety and logs: `clean`, `uninstall`, `purge`, `installer`, and `remove` are destructive. Review with `--dry-run` first, and add `--debug` when needed. File operations are logged to `~/Library/Logs/mole/operations.log` and can be reviewed with `mo history`. Disable with `MO_NO_OPLOG=1`. Review [SECURITY.md](SECURITY.md) and [SECURITY_AUDIT.md](SECURITY_AUDIT.md).
- App leftovers: use `mo clean` when the app is already uninstalled, and `mo uninstall` when the app is still installed.
- Navigation: Mole supports arrow keys and Vim bindings `h/j/k/l`.

## Features in Detail

### Deep System Cleanup

```bash
$ mo clean

Scanning cache directories...

  ✓ User app cache                                           45.2GB
  ✓ Browser cache (Chrome, Safari, Firefox)                  10.5GB
  ✓ Developer tools (Xcode, Node.js, npm)                    23.3GB
  ✓ System logs and temp files                                3.8GB
  ✓ App-specific cache (Spotify, Dropbox, Slack)              8.4GB
  ✓ Trash                                                    12.3GB

====================================================================
Space freed: 95.5GB | Free space now: 223.5GB
====================================================================
```

Note: In `mo clean` -> Developer tools, Mole removes unused CoreSimulator `Volumes/Cryptex` entries and skips `IN_USE` items.

### Smart App Uninstaller

```bash
$ mo uninstall

Select Apps to Remove
═══════════════════════════
▶ ☑ Photoshop 2024            (4.2G) | Old
  ☐ IntelliJ IDEA             (2.8G) | Recent
  ☐ Premiere Pro              (3.4G) | Recent

Uninstalling: Photoshop 2024

  ✓ Removed application
  ✓ Cleaned 52 related files across 12 locations
    - Application Support, Caches, Preferences
    - Logs, WebKit storage, Cookies
    - Extensions, Plugins, Launch daemons

Note: On macOS 15 and later, Local Network permission entries can outlive app removal. Mole warns when an uninstalled app declares Local Network usage, but it does not auto-reset `/Volumes/Data/Library/Preferences/com.apple.networkextension*.plist` because that reset is global and requires Recovery mode.

====================================================================
Space freed: 12.8GB
====================================================================
```

### System Optimization

```bash
$ mo optimize

System: 5/32 GB RAM | 333/460 GB Disk (72%) | Uptime 6d

  ✓ Rebuild system databases and clear caches
  ✓ Reset network services
  ✓ Refresh Finder and Dock
  ✓ Clean diagnostic and crash logs
  ✓ Remove swap files and restart dynamic pager
  ✓ Rebuild launch services and spotlight index

====================================================================
System optimization completed
====================================================================

Use `mo optimize --whitelist` to exclude specific optimizations. Path patterns work too, so you can keep a long-lived mounted disk image around (for example `/Volumes/mail`) without it showing up as a detach candidate.
```

### Disk Space Analyzer

> Note: By default, Mole skips external drives under `/Volumes` for faster startup. To inspect them, run `mo analyze /Volumes` or a specific mount path.

Developer tools may leave large temporary directories under `/private/tmp`. Review user-owned entries with `mo analyze /private/tmp`; selected entries move to Trash only after confirmation. Mole does not automatically delete third-party temporary directories because build markers and age alone cannot prove that a checkout or worktree is disposable.

```bash
$ mo analyze

Analyze Disk  (302.1GB free)
Select a location to explore:

 ▶  1. ████████████████████████  47.9%  |  Home                       75.4GB
    2. ███████████               22.0%  |  User Library               34.6GB
    3. ███████                   14.2%  |  Applications               22.4GB
    4. █████                     10.7%  |  System Library             16.9GB
    5. ███                        5.2%  |  Old Downloads (90d+)       8.2GB  >3mo

↑↓→ | Enter | R Refresh | O Open | P Preview | F File | Esc/Q Quit
```

### Live System Status

Real-time dashboard with health score, hardware info, and performance metrics.

```bash
$ mo status

Mole Status  Health ● 92  MacBook Pro · M4 Pro · 32GB · macOS 14.5

⚙ CPU                                    ▦ Memory
Total   ████████████░░░░░░░  45.2%       Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (8 cores)     Total   14.2 / 24.0 GB
Core 1  ███████████████░░░░  78.3%       Free    ████████░░░░░░░░░░  41.6%
Core 2  ████████████░░░░░░░  62.1%       Avail   9.8 GB

▤ Disk                                   ⚡ Power
Used    █████████████░░░░░░  67.2%       Level   ██████████████████  100%
Free    156.3 GB                         Status  Charged
Read    ▮▯▯▯▯  2.1 MB/s                  Health  Normal · 423 cycles
Write   ▮▮▮▯▯  18.3 MB/s                 Temp    58°C · 1200 RPM

⇅ Network                                ▶ Processes
Down    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s      Code       ▮▮▮▮▯  42.1%
Up      ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s      Chrome     ▮▮▮▯▯  28.3%
Proxy   HTTP · 192.168.1.100             Terminal   ▮▯▯▯▯  12.5%
```

Health score is based on CPU, memory, disk, temperature, and I/O load, with color-coded ranges.

Shortcuts: In `mo status`, press `k` to toggle the cat, `c` to cycle how many CPU cores the card lists (2, 4, 8, all), and `q` to quit. Both preferences are saved.

When enabled, `mo status` shows a read-only alert banner for processes that stay above the configured CPU threshold for a sustained window. Use `--proc-cpu-threshold`, `--proc-cpu-window`, or `--proc-cpu-alerts=false` to tune or disable it.

#### Machine-Readable Output

Both `mo analyze` and `mo status` support a `--json` flag for scripting and automation.

`mo status` also auto-detects when its output is piped (not a terminal) and switches to JSON automatically.

```bash
# Disk analysis as JSON
$ mo analyze --json ~/Documents
{
  "path": "/Users/you/Documents",
  "overview": false,
  "entries": [
    { "name": "Library", "path": "...", "size": 80939438080, "is_dir": true },
    ...
  ],
  "large_files": [
    { "name": "backup.zip", "path": "...", "size": 8796093022 }
  ],
  "total_size": 168393441280,
  "total_files": 42187
}

# System status as JSON
$ mo status --json
{
  "host": "MacBook-Pro",
  "health_score": 92,
  "cpu": { "usage": 45.2, "logical_cpu": 8, ... },
  "memory": { "total": 25769803776, "used": 15049334784, "used_percent": 58.4 },
  "disks": [ ... ],
  "uptime": "3d 12h 45m",
  ...
}

# Auto-detected JSON when piped
$ mo status | jq '.health_score'
92
```

### Project Artifact Purge

Clean old build artifacts such as `node_modules`, `target`, `.build`, `build`, and `dist` to free up disk space. Stale git worktrees are offered too, including the throwaway checkouts AI coding agents leave behind: `mo purge` asks every repo under your scan paths for its registrations, so it finds them wherever they live.

```bash
mo purge

Select Categories to Clean - 18.5GB (8 selected)

➤ ● my-react-app       3.2GB | node_modules
  ● old-project        2.8GB | node_modules
  ● rust-app           4.1GB | target
  ● next-blog          1.9GB | node_modules
  ○ current-work       856MB | node_modules  | Recent
  ● django-api         2.3GB | venv
  ● vue-dashboard      1.7GB | node_modules
  ○ ~/dev/api-agent-run  789MB | worktree     | 22d
```

> Note: We recommend installing `fd` on macOS.
> `brew install fd`

> Safety: This permanently deletes selected build artifacts; worktrees are the one exception and go to the Trash. Review carefully before confirming. Projects newer than 7 days are marked and unselected by default.

> Worktrees: only offered when git can prove the checkout is restorable, meaning no uncommitted changes, nothing unpushed, a remote to restore from, no git activity for 7 days, and no ignored file that is not itself a known build artifact, so a gitignored `.env` keeps the whole worktree. They are never selected for you, they go to the Trash rather than being deleted outright, and the parent repo's stale registration is pruned afterwards.

<details>
<summary><strong>Custom Scan Paths</strong></summary>

Run `mo purge --paths` to configure scan directories, or edit `~/.config/mole/purge_paths` directly:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

When custom paths are configured, Mole scans only those directories. Otherwise, it uses defaults like `~/Projects`, `~/GitHub`, and `~/dev`.

</details>

### Installer Cleanup

Find and remove large installer files across Downloads, Desktop, Homebrew caches, iCloud, and Mail. Each file is labeled by source.

```bash
mo installer

Select Installers to Remove - 3.8GB (5 selected)

➤ ● Photoshop_2024.dmg     1.2GB | Downloads
  ● IntelliJ_IDEA.dmg       850.6MB | Downloads
  ● Illustrator_Setup.pkg   920.4MB | Downloads
  ● PyCharm_Pro.dmg         640.5MB | Homebrew
  ● Acrobat_Reader.dmg      220.4MB | Downloads
  ○ AppCode_Legacy.zip      410.6MB | Downloads
```

## Quick Launchers

Launch Mole commands from Raycast or Alfred:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

Adds 5 commands: `Mole Clean`, `Mole Uninstall`, `Mole Optimize`, `Mole Analyze`, `Mole Status`.

### Raycast Setup

After running the script, complete these steps in Raycast:

1. Open Raycast Settings (⌘ + ,)
2. Go to **Extensions** → **Script Commands**
3. Click **"Add Script Directory"** (or **"+"**)
4. Add path: `~/Library/Application Support/Raycast/script-commands`
5. Search in Raycast for: **"Reload Script Directories"** and run it
6. Done! Search for `Mole Clean` or `clean`, `Mole Optimize`, or `Mole Status` to use the commands

> **Note**: The script creates the commands, but Raycast still requires a one-time manual script directory setup.

### Terminal Detection

Mole auto-detects your terminal app. iTerm2 has known compatibility issues. We highly recommend [Kaku](https://github.com/tw93/Kaku). Other good options are Alacritty, kitty, WezTerm, Ghostty, and Warp. To override, set `MO_LAUNCHER_APP=<name>`.

## Community Love

Thanks to everyone who helped build Mole. Go follow them. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" width="1000" />
</a>

<br/><br/>
Real feedback from users who shared Mole on X.

<img src="https://gw.alipayobjects.com/zos/k/dl/lovemole.jpeg" alt="Community feedback on Mole" width="1000" />

## Support

- Getting [Mole for Mac](https://mole.fit) is the most direct way to support Mole's development.
- If Mole helped you, give it a star, [share it](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.), or open an issue or PR.
- I have two cats, TangYuan and Coke. If you think Mole delights your life, you can feed them <a href="https://cats.tw93.fun?name=Mole" target="_blank">canned food 🥩</a>.

<details>
<summary>These lovely people already did 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" width="1000" loading="lazy" /></a>
</details>

## License

Mole is open source under GPL-3.0, see [LICENSE](LICENSE). A version you modify and share stays open under the same license, and if you fork Mole into your own product, to avoid confusion please give it a different name and credit Mole as the source. [Mole for Mac](https://mole.fit) is a separate, proprietary app, and Mole is here for the long run.
