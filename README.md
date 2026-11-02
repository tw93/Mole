<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <img src="https://cdn.tw93.fun/pic/cole.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Windows</h1>
  <p><b>Deep clean, uninstall apps, optimize, analyze disk, and monitor your Windows PC. Free open-source CLI.</b></p>
  <p>English · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Mole CLI for Windows menu" width="736" />
</p>

> 💡 This branch is the free open-source Windows CLI (`mo`). Prefer a native app? [Mole for Windows](https://mole.fit/windows) is a separate download with review-before-delete cleanup, app updates, startup management, disk drill-downs, and live status. The macOS CLI lives on the [main branch](https://github.com/tw93/Mole#readme).

## Features

- **All-in-one CLI toolkit**: Combines CCleaner, IObit Uninstaller, WinDirStat, and Task Manager style workflows in one terminal command
- **Deep clean**: Removes temp files, caches, logs, and browser leftovers to reclaim disk space
- **Smart uninstaller**: Removes apps together with their leftover install folders
- **Disk analyzer**: Explores disk usage with an interactive TUI and finds large files
- **System maintenance**: Flushes DNS, optimizes the system drive, and checks disk health
- **Live monitoring**: Shows real-time CPU, memory, disk, network, and process stats

## Quick Start

Mole runs on Windows 10 and 11 with the built-in Windows PowerShell 5.1. The script install needs Git and, when the source differs from the latest release, Go to build the native tools. It installs into `%LOCALAPPDATA%\Programs\mole-cli`, and adds `mo` and `mole` to your PATH.

**Install via Scoop**

```powershell
scoop install mole
```

**Or via script**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole is only distributed through this GitHub repository, Scoop, and [mole.fit](https://mole.fit/windows) for the Windows app. Sites offering a "Mole-based" app or asking you to paste an encoded command into a terminal are not affiliated with Mole.

**With an AI agent**

Tell your agent:

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

Or install the skill yourself. With it, Claude Code, Codex, Cursor and other agents show every cleanup with `--dry-run` before anything is removed, and leave app uninstalls and administrator steps to you. Update with `npx skills update -g -y`.

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

As a host plugin: `/plugin marketplace add tw93/Mole` then `/plugin install mole@mole` in Claude Code, or `codex plugin marketplace add tw93/Mole` then `codex plugin add mole@mole` in Codex.

**Run**

```powershell
mo                           # Interactive menu
mo clean                     # Deep cleanup
mo uninstall                 # Remove installed apps + their leftovers
mo optimize                  # Refresh caches & services
mo analyze                   # Visual disk explorer
mo status                    # Live system health dashboard
mo purge                     # Clean project build artifacts

mo update                    # Update Mole
mo remove                    # Remove Mole from this PC
mo --help                    # Show help
mo --version                 # Show installed version
```

**Preview safely**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Preview + detailed logs
mo clean --whitelist         # Manage protected paths
mo clean --system            # Include system-level cleanup (run as administrator)
mo purge --paths             # Configure project scan directories
mo analyze D:\               # Analyze another drive
mo uninstall --list          # List installed apps, JSON when piped
mo analyze --json D:\        # Disk report as JSON
```

<details>
<summary><strong>Other install options</strong></summary>

To review the code before installing, clone the `windows` branch and run the installer in place. It keeps `.git`, so `mo update` works later:

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

Add `-CreateShortcut` for a Start Menu entry. To uninstall, run `mo remove`.

</details>

## Safety

Mole can delete files, so it validates paths and protects system and profile locations. `uninstall`, `purge`, and `remove` ask for confirmation before removing anything. When Mole cannot prove an item is safe to change, it skips it.

- `clean`, `uninstall`, and `purge` can delete files, so review them with `--dry-run` first and add `--debug` when needed
- `clean` and `purge` delete permanently; verified `uninstall` leftovers go to the Recycle Bin, the app's own uninstaller keeps its own behavior, and files deleted in `mo analyze` go to the Recycle Bin
- Run Mole as your normal user; system-level steps are skipped unless PowerShell runs as administrator
- Protect paths with `mo clean --whitelist`
- Cleanup activity is recorded in `%USERPROFILE%\.config\mole\operations.log`; review it with `mo history` or disable it with `MO_NO_OPLOG=1`
- `C:\Windows`, `C:\Program Files`, Windows Defender folders, and your profile root are never touched

Review [SECURITY.md](SECURITY.md) for reporting guidance and safety boundaries.

## Features in Detail

The screenshots below come from a test PC. Available items and sizes depend on your PC.

### Clean

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="mo clean --dry-run preview" width="736" />

The detailed list holds every path the preview found. Copy any of them into the whitelist to keep it.

### Uninstall

```powershell
mo uninstall
```

Lists installed programs from the registry and Windows Apps, largest first, then removes the ones you pick with their own uninstaller and cleans the leftover install folder. `mo uninstall --dry-run` shows which uninstaller each app would use and what would be removed, without running anything.

<img src="./docs/img/uninstall-windows.png" alt="mo uninstall app list" width="736" />

### Optimize

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="mo optimize --dry-run preview" width="736" />

Steps such as disk optimization and the ARP cache flush need administrator access and are skipped otherwise; run PowerShell as administrator to include them.

### Analyze

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="mo analyze overview" width="807" />

An interactive disk explorer with the same layout as the macOS version: arrow keys move through folders, `Backspace` goes back, `T` lists the largest files, and `Del` moves the selected items to the Recycle Bin after a confirmation.

### Status

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="mo status dashboard" width="1000" />

A live dashboard with a health score, CPU, memory, disk, power, network, and the busiest processes.

### Purge

```powershell
mo purge --dry-run
```

Finds build artifacts (`node_modules`, `target`, `build`, `dist`, `venv`, and more) in your project folders and lets you pick which projects to clean; nothing is selected until you choose. Configure the scanned folders with `mo purge --paths`.

## Community

Thanks to everyone who helped build Mole. Go follow them. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole contributors" width="1000" />
</a>

## Support

- Getting [Mole for Windows](https://mole.fit/windows) is the most direct way to support Mole's development
- If Mole helped you, give it a star, [share it](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.), or open an issue or PR
- Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first
- I have two cats, TangYuan and Coke, and if Mole makes your life a little easier, feel free to treat them to <a href="https://cats.tw93.fun?name=Mole" target="_blank">canned food 🥩</a>

## License

Mole is open source under GPL-3.0; see [LICENSE](LICENSE). Any modified version you share must remain under the same license. If you fork Mole, please use a distinct name and credit Mole as the upstream source; see [TRADEMARK.md](TRADEMARK.md).
