<div align="center">
  <h1>Mole</h1>
  <p><em>Deep clean and optimize your Mac.</em></p>
</div>

<p align="center">
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+GclQS9ZnxyI2ODQ1"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</p>

<p align="center">
  <img src="https://cdn.tw93.fun/img/mole.jpeg" alt="Mole - 95.50GB freed" width="1000" />
</p>

## Features

- **All-in-one toolkit**: CleanMyMac, AppCleaner, DaisyDisk, and iStat Menus combined into a **single binary**
- **Deep cleaning**: Scans and removes caches, logs, and browser leftovers to **reclaim gigabytes of space**
- **Smart uninstaller**: Thoroughly removes apps along with launch agents, preferences, and **hidden remnants**
- **Disk insights**: Visualizes usage, manages large files, **rebuilds caches**, and refreshes system services
- **Live monitoring**: Real-time stats for CPU, GPU, memory, disk, and network to **diagnose performance issues**

## Quick Start

**Install via Homebrew — recommended:**

```bash
brew install mole
```

**Or via script — for older macOS versions or latest code:**

```bash
# Add '-s latest' for the latest, '-s dev' for development, or '-s 1.17.0' for a specific version.
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**Run:**

```bash
mo                           # Interactive menu
mo clean                     # Deep cleanup
mo uninstall                 # Remove apps + leftovers
mo optimize                  # Refresh caches & services
mo analyze                   # Visual disk explorer
mo status                    # Live system health dashboard
mo purge                     # Clean project build artifacts
mo installer                 # Find and remove installer files

mo touchid                   # Configure Touch ID for sudo
mo completion                # Set up shell tab completion
mo update                    # Update Mole
mo remove                    # Remove Mole from system
mo --help                    # Show help
mo --version                 # Show installed version

mo clean --dry-run           # Preview the cleanup plan
mo clean --whitelist         # Manage protected caches
mo clean --dry-run --debug   # Detailed preview with risk levels and file info

mo optimize --dry-run        # Preview optimization actions
mo optimize --debug          # Run with detailed operation logs
mo optimize --whitelist      # Manage protected optimization rules
mo purge --paths             # Configure project scan directories
```

## Tips

- **Terminal**: iTerm2 has known compatibility issues; we recommend Alacritty, kitty, WezTerm, Ghostty, or Warp.
- **Safety**: Built with strict protections. See [Security Audit](SECURITY_AUDIT.md). Preview changes with `mo clean --dry-run`.
- **Debug Mode**: Use `--debug` for detailed logs (e.g., `mo clean --debug`). Combine with `--dry-run` for comprehensive preview including risk levels and file details.
- **Navigation**: Supports arrow keys and Vim bindings (`h/j/k/l`).
- **Configuration**: Run `mo touchid` for Touch ID sudo, `mo completion` for shell tab completion, `mo clean --whitelist` to manage protected paths.

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

Use `mo optimize --whitelist` to exclude specific optimizations.
```

### Disk Space Analyzer

```bash
$ mo analyze

Analyze Disk  ~/Documents  |  Total: 156.8GB

 ▶  1. ███████████████████  48.2%  |  📁 Library                     75.4GB  >6mo
    2. ██████████░░░░░░░░░  22.1%  |  📁 Downloads                   34.6GB
    3. ████░░░░░░░░░░░░░░░  14.3%  |  📁 Movies                      22.4GB
    4. ███░░░░░░░░░░░░░░░░  10.8%  |  📁 Documents                   16.9GB
    5. ██░░░░░░░░░░░░░░░░░   5.2%  |  📄 backup_2023.zip              8.2GB

  ↑↓←→ Navigate  |  O Open  |  F Show  |  ⌫ Delete  |  L Large files  |  Q Quit
```

### Live System Status

Real-time dashboard with system health score, hardware info, and performance metrics.

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
Down    ▮▮▯▯▯  3.2 MB/s                  Code       ▮▮▮▮▯  42.1%
Up      ▮▯▯▯▯  0.8 MB/s                  Chrome     ▮▮▮▯▯  28.3%
Proxy   HTTP · 192.168.1.100             Terminal   ▮▯▯▯▯  12.5%
```

Health score based on CPU, memory, disk, temperature, and I/O load. Color-coded by range. Press `k` to hide/show cat, `q` to quit.

### Project Artifact Purge

Clean old build artifacts (`node_modules`, `target`, `build`, `dist`, etc.) from your projects to free up disk space.

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
  ● backend-service    2.5GB | node_modules
```

> **Use with caution:** This will permanently delete selected artifacts. Review carefully before confirming. Recent projects — less than 7 days old — are marked and unselected by default.

<details>
<summary><strong>Custom Scan Paths</strong></summary>

Run `mo purge --paths` to configure which directories to scan, or edit `~/.config/mole/purge_paths` directly:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

When custom paths are configured, only those directories are scanned. Otherwise, it defaults to `~/Projects`, `~/GitHub`, `~/dev`, etc.

</details>

### Installer Cleanup

Find and remove large installer files scattered across Downloads, Desktop, Homebrew caches, iCloud, and Mail. Each file is labeled by source to help you know where the space is hiding.

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

Launch Mole commands instantly from Raycast or Alfred:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

Adds 5 commands: `clean`, `uninstall`, `optimize`, `analyze`, `status`.

Mole automatically detects your terminal, or set `MO_LAUNCHER_APP=<name>` to override. For Raycast users: if this is your first script directory, add it via Raycast Extensions → Add Script Directory, then run "Reload Script Directories".

## Community Love

Mole wouldn't be possible without these amazing contributors. They've built countless features that make Mole what it is today. Go follow them! ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" width="1000" />
</a>

Join thousands of users worldwide who trust Mole to keep their Macs clean and optimized.

<img src="https://cdn.tw93.fun/pic/lovemole.jpeg" alt="Community feedback on Mole" width="1000" />

## Support

- If Mole saved you disk space, consider starring the repo or [sharing it](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) with friends.
- Have ideas or fixes? Check our [Contributing Guide](CONTRIBUTING.md), then open an issue or PR to help shape Mole's future.
- Love Mole? <a href="https://miaoyan.app/cats.html?name=Mole" target="_blank">Buy Tw93 an ice-cold Coke</a> to keep the project alive and kicking! 🥤

<details>
<summary><strong>Friends who bought me Coke</strong></summary>
<br/>
<a href="https://miaoyan.app/cats.html?name=Mole"><img src="https://miaoyan.app/assets/sponsors.svg" width="1000" /></a>
</details>

## License

MIT License — feel free to enjoy and participate in open source.
