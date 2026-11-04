<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <a href="https://github.com/tw93/Mole/tree/windows#readme">Windows</a> · <b>Linux</b></p>

<div align="center">
  <img src="./docs/img/mole-logo.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Linux</h1>
  <p><b>Deep clean, uninstall apps, optimize, analyze disk, and monitor your Linux desktop. Free open-source CLI.</b></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases?q=linux"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-linux&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/linux"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/linux?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-linux.png" alt="Mole CLI for Linux menu" width="1000" />
</p>

Mole CLI for Linux is an early version, and the latest release is [V0.4.0-linux](https://github.com/tw93/Mole/releases/tag/V0.4.0-linux). Issues and feedback are welcome. It is built first for [Omarchy](https://omarchy.org) and other Arch-based systems, and covers Debian and Ubuntu with apt and Snap. On other distributions the user-level parts work and the package-manager items do not appear.

This branch has its own code, written for Linux paths and tools. The look, the keys and the safety rules match the macOS CLI on the [main branch](https://github.com/tw93/Mole#readme).

## Features

- **Clean**: Removes caches apps rebuild by themselves, empties the Trash, and trims old packages and journal logs through pacman's, apt's and systemd's own tools
- **Uninstall**: Removes pacman, AUR, apt, Snap, Flatpak and AppImage apps with their leftovers, matched by the app's exact ID
- **Optimize**: Refreshes font, icon and launcher caches, compacts closed browser databases, and reports problems with the command to fix them
- **Analyze**: Explores disk usage in an interactive map that stays on local disks and follows btrfs subvolumes
- **Purge**: Removes build output such as `node_modules` and `target` from projects untouched for a week
- **History**: Lists what Mole removed, moved to the Trash or skipped, by run
- **Status**: Shows live CPU, memory, disks, network, temperatures, GPU and battery with a health score

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/linux/install.sh | bash
```

Mole runs on x86_64 and aarch64, installs into `~/.local/share/mole` and links `mo` into `~/.local/bin`, with no sudo. Only `paccache`, `apt-get autoclean` and `journalctl` in `mo clean` and the package removal in `mo uninstall` ask for sudo, and pacman and apt keep their own confirmation.

```bash
mo update            # install the latest release
mo update --force    # reinstall it
mo update --nightly  # install the latest unreleased build
mo remove            # remove Mole and its own files
```

## Usage

```bash
mo                         # main menu
mo clean                   # clean caches and the Trash
mo clean --dry-run         # preview, nothing removed
mo clean --whitelist       # choose what clean keeps
mo uninstall               # pick apps to remove
mo uninstall --list        # apps and the names mo uninstall accepts
mo uninstall --dry-run zoom
mo optimize                # refresh caches and check the system
mo optimize --dry-run      # preview
mo analyze                 # disk map
mo analyze /mnt/data
mo status                  # live system status
mo status --json           # one machine-readable snapshot
mo purge                   # pick project build output to remove
mo purge --dry-run         # preview
mo purge --paths           # folders purge scans
mo history                 # what Mole changed, by run
mo history --json
```

In the menus: arrow keys or `j`/`k` to move, `Space` to select, `Enter` to confirm, `/` to filter, `q` to quit.

## Safety

- Files you could want back go to the freedesktop Trash, with a `.trashinfo` so your file manager can restore them. Only caches from a fixed list are removed directly, since moving a cache to the Trash frees nothing.
- A cache is skipped while the app that owns it is running, and when Mole cannot tell whether it runs.
- Uninstall leftovers are matched by the app's exact ID, never by part of a name. Caches are selected by default; settings and data are not, and browser profiles are never preselected.
- Mole refuses to run as root, never removes system folders, mount points or other users' files, and never runs `pacman -Scc`, `apt-get clean`, `--noconfirm`, `-y` or `autoremove`.
- Purge removes build output directly, after checking each folder again right before it goes: still the same folder, below the project folder through real folders only, yours, and not a mount point.
- Every change is written to `~/.local/state/mole/operations.log`, and `mo history` reads it back.

## Features in Detail

The screenshots below come from an Omarchy test machine. Available items and sizes depend on your system.

### Clean

```bash
mo clean --dry-run
```

<img src="./docs/img/clean-linux.png" alt="mo clean --dry-run preview" width="1000" />

Covers browser caches, Electron apps such as VS Code, Cursor, Obsidian, Discord and Slack, Thunderbird, Telegram, about 50 developer tools, old versions of AI coding agents, and Flatpak and Snap app caches. Caches whose app is running are skipped and named. GPU shader caches (Mesa, NVIDIA, Steam, Lutris) go only with `mo clean --gpu-shaders`, since every game compiles them again on its next launch.

Large folders under `~/.cache` that Mole does not know, core dumps and container space are listed under Not cleaned, never removed. The space Snap keeps for rolling back is reported, not removed, and on a snapper btrfs root old packages free their space only as snapshots rotate.

### Uninstall

```bash
mo uninstall
```

<img src="./docs/img/uninstall-linux.png" alt="mo uninstall app list" width="1000" />

Lists pacman, AUR, apt, Snap, Flatpak, AppImage, Omarchy web and terminal apps with their size and last use. Picked apps are removed by their own package manager, with its own confirmation where it has one (Snap has none, so Mole's confirmation is the last step), and their leftovers go to the Trash.

Before apt runs, Mole names any other package apt would remove with it, such as a desktop metapackage. `mo uninstall --dry-run` shows everything that would happen without running anything.

### Optimize

```bash
mo optimize --dry-run
```

<img src="./docs/img/optimize-linux.png" alt="mo optimize --dry-run preview" width="520" />

Needs no sudo and never touches CPU, power or kernel settings. These problems are reported with the command to run:

- Failed services, and launchers, autostart entries and Hyprland start commands whose program is gone
- Orphan packages, leftover apt configuration, pending `.pacnew` and `.dpkg-dist` merges, AUR packages that need a rebuild, files no package owns and a stale pacman lock
- Root-owned files in your home and broken links
- TRIM switched off and power managers that fight each other

### Analyze

```bash
mo analyze
mo analyze /mnt/data
```

<img src="./docs/img/analyze-linux.png" alt="mo analyze overview" width="1000" />

An interactive disk explorer with the same layout as the macOS version. Network, FUSE and container mounts are shown but not scanned.

### Status

```bash
mo status
```

<img src="./docs/img/status-linux.png" alt="mo status dashboard" width="1000" />

A live dashboard with a health score, CPU, memory, disk, power, network, and the busiest apps, with processes grouped by app. `mo status --json` prints one snapshot for scripts.

### Purge

```bash
mo purge
mo purge --paths
```

<img src="./docs/img/purge-linux.png" alt="mo purge project list" width="1000" />

Scans `~/www`, `~/dev`, `~/Projects`, `~/code` and similar folders, plus any home folder that holds a project, or only the folders listed in `~/.config/mole/purge_paths`. Folders changed in the last 7 days and projects a program works in start unselected; the rest start selected. Outside a terminal, `--yes` removes only what is older than 7 days.

## Community

Thanks to everyone who helped build Mole. Go follow them. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole contributors" width="1000" />
</a>

## Support

- If Mole helped you, give it a star, [share it](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/linux&text=Mole%20-%20Deep%20clean%20your%20Linux%20desktop.), or open an issue or PR
- Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first
- I have two cats, TangYuan and Coke, and if Mole makes your life a little easier, feel free to treat them to <a href="https://cats.tw93.fun?name=Mole" target="_blank">canned food 🥩</a>

## License

Mole is open source under GPL-3.0; see [LICENSE](LICENSE). Any modified version you share must remain under the same license. If you fork Mole, please use a distinct name and credit Mole as the upstream source; see [TRADEMARK.md](TRADEMARK.md).
