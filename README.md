<p align="right"><a href="https://github.com/tw93/Mole">macOS</a> · <a href="https://github.com/tw93/Mole/tree/windows">Windows</a> · <b>Linux</b></p>

<div align="center">
  <h1>Mole CLI for Linux</h1>
  <p><b>Clean caches, uninstall apps, optimize, analyze disk and watch your system from one terminal command. Free and open source.</b></p>
</div>

This is the Linux edition of [Mole](https://github.com/tw93/Mole). It lives on its own branch with its own code, built for Linux paths and tools; the look, the keys and the safety rules match the macOS edition. The first target is [Omarchy](https://omarchy.org) and other Arch-based systems. On other distributions the user-level parts work and the pacman items simply do not appear.

## Features

- **Clean**: removes caches apps rebuild by themselves (browser and browser-profile caches, Electron apps such as VS Code, Cursor, Obsidian, Discord and Slack, thumbnails, shader caches, about 50 developer tools, old versions of AI coding agents, Flatpak app caches), empties the Trash, removes unused runtimes of your own Flatpak installation, trims old pacman packages and journal logs through pacman's and systemd's own tools, and reports core dumps, container space and large caches it does not know. Anything you want kept goes in `mo clean --whitelist`
- **Uninstall**: removes pacman, AUR and Flatpak apps, Omarchy web and terminal apps and AppImages, shows each app's size and last use, stops its background services, then moves its leftovers to the Trash, matched by the app's exact ID only and never while the app is running
- **Optimize**: refreshes the font, icon and app launcher caches, compacts browser and Thunderbird databases while they are closed, and points out failed services, launchers, autostart and Hyprland start commands whose program is gone, root-owned files in your home, orphan packages, a leftover pacman lock, TRIM switched off on an SSD and power managers that fight each other. It needs no sudo and never touches CPU, power or kernel settings
- **Analyze**: an interactive disk map of your volumes, home, caches and package cache; deleting from it moves items to the Trash
- **Status**: live CPU, memory pressure, disks, network, temperatures, battery and processes, with a health score

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/linux/install.sh | bash
```

Mole installs into `~/.local/share/mole` and links `mo` into `~/.local/bin`. It needs no sudo to install and runs as your own user; the only steps that ask for sudo are `paccache` and `journalctl` in `mo clean` and the package removal in `mo uninstall`, and pacman keeps its own confirmation there.

```bash
mo update      # install the latest release
mo update --force  # reinstall it
mo remove      # remove Mole and its own files
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
```

In the menus: arrow keys or `j`/`k` to move, `Space` to select, `Enter` to confirm, `/` to filter, `q` to quit.

## Safety

- Files you could want back go to the freedesktop Trash, with a `.trashinfo` so your file manager can restore them. Only caches from a fixed list are removed directly, since moving a cache to the Trash frees nothing.
- A cache is skipped while the app that owns it is running.
- Uninstall leftovers are matched by the app's exact ID, never by part of a name. Caches are selected by default; settings and data are not.
- Mole refuses to run as root, never removes system folders, mount points or other users' files, and never runs `pacman -Scc`, `--noconfirm` or `autoremove`.
- Every change is written to `~/.local/state/mole/operations.log`.

## License

GPL-3.0, like the rest of Mole.
