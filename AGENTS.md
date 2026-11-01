# Mole CLI (Linux) Agent Guide

This is the `linux` branch of `tw93/Mole`: **Mole CLI (Linux)**, a terminal cleaner for Linux desktops used by developers. It is developed like the `windows` branch (Mole CLI (Windows)): its own code, its own tests, its own release tags. Nothing here is shared with `main` (Mole CLI (macOS)) at runtime; the Go TUIs under `cmd/` were forked from `main` at the branch point and evolve independently. Rules, product values and safety contracts transfer by deliberate re-implementation, recorded in `SYNC.md`, never by importing macOS code (maintainer 2026-11-01: the two platforms clean different things and shared code breaks easily).

Status: pre-release. The branch stays unannounced until the first usable version (the MVP below) works on Omarchy; then README, release and the reply on tw93/Mole#1371 change together (maintainer 2026-11-01).

## Product names

Use **Mole Mac**, **Mole for Windows**, **Mole CLI (macOS)**, **Mole CLI (Windows)** and **Mole CLI (Linux)** exactly. Never an unqualified "CLI" or "Linux version" where the product is ambiguous.

## Scope

Six commands: `clean`, `uninstall`, `optimize`, `analyze`, `status`, `purge`.

- First target: Omarchy (Arch + Hyprland, Wayland). Other Arch-based systems come along. Debian/Ubuntu and Fedora rules come later; on those systems the package-manager items simply do not appear while user-level features work.
- MVP (first public version): `analyze`, `status`, `clean`, `purge`, `uninstall` usable on Omarchy. `optimize` follows in the next version.
- Not built: GUI, paid tier, background agents, schedulers, notifications, package upgrades, `autoremove`, emptying whole package caches, kernel removal, CPU governor / EPP / turbo / `platform_profile` / sysctl / `drop_caches` tuning. When TLP, power-profiles-daemon, tuned or auto-cpufreq is active, Mole only reports it.

## Safety contract

Every rule below is a design requirement for code that does not exist yet; each needs a test before the code that relies on it ships.

- **No root path deletion.** Mole never runs `rm`, `find -delete` or a move on an arbitrary path as root. Root-level cleanup happens only through the distribution's own command with a bounded scope: `paccache -rk2` (never `-rk0` or `pacman -Scc`), `journalctl --vacuum-time=` with a retention floor (never `--vacuum-size=1`), `flatpak uninstall --unused`. Package-manager locks (`/var/lib/pacman/db.lck`) present means the item is skipped.
- **Trash by default, XDG spec.** User files go to `$XDG_DATA_HOME/Trash` (default `~/.local/share/Trash`): write `info/<name>.trashinfo` with `O_EXCL` first to reserve the name, then rename into `files/`, and roll back the info file if the rename fails. Items on another filesystem go to that filesystem's `$topdir/.Trash-$uid` or are refused; never copy a tree across devices and delete the source. `gio trash` is a fallback, not the primary path. Permanent deletion is an explicit choice. One sink each: `internal/xdgtrash` (reached from bash through `bin/trash-go`, from analyze directly) for user files and uninstall leftovers, and `mole_remove_cache` in `lib/core/delete.sh` for the children of an allowlisted cache root in `lib/clean/rules.sh`, which are removed directly because moving a cache to the Trash frees nothing. Emptying the Trash is part of `clean`. A Trash move counts only on the helper's own `ok` line per path; a helper that cannot run is a failure, never a completed move.
- **Exact ownership only.** Clean deletes from an allowlist of known caches; unknown directories under `~/.cache` are listed, never selected. Uninstall leftovers match exact identifiers (`~/.config/<id>`, `~/.cache/<id>`, `~/.local/share/<id>`, `~/.var/app/<id>`, `<id>.desktop`, `~/.config/systemd/user/<id>.service`, `~/.config/autostart/<id>.desktop`), never substrings or vendor wildcards.
- **Running owners block deletion.** Every rule names its owning executable or lock file; while it runs, the rule is skipped. `/tmp` and `/var/tmp` cleanup touches only regular files owned by the user, on the same device, not open per `/proc/*/fd`.
- **Never touched:** live logs in `/var/log`, package databases and their locks, `~/.cache/doc` (Flatpak document portal), model stores (`~/.ollama`, `/var/lib/ollama`, `~/.cache/huggingface`, `~/.cache/lm-studio`) unless the user picks them in a review list, mount points, `/boot /usr /bin /sbin /lib* /etc /var/lib /proc /sys /dev /run /nix/store`.
- **Uninstall delegates removal of the package to its owner** (pacman, yay/AUR, flatpak, later apt/dnf/snap) for the one package the user picked, keeping the owner's own confirmation (no `--noconfirm`, no `-y`). Web apps (Omarchy's `.desktop` launchers plus icons) are listed as web apps, not packages. Config and data leftovers are unchecked by default; caches are checked.
- **Dry-run and log.** Every destructive command has a dry-run that lists exactly what the real run would touch, and every change appends one operations.log row.
- **Parse structure, not words.** Run external tools with `LC_ALL=C` before parsing their output, prefer exit codes and machine formats (`findmnt -J`, `--porcelain`), and never match localized error text: the Omarchy test VM runs in Chinese and `du` prints 「权限不够」.
- **GNU tools only.** This branch targets GNU coreutils and findutils; no BSD spellings (`stat -f`, `find -flags`, `du -I`, `sed -i ''`).
- **Refuse root.** Mole runs as the desktop user and asks for sudo only for the bounded root items above.

## Analyze and status

- Volumes come from `/proc/self/mountinfo`; skip pseudo filesystems, overlay, autofs and network mounts by fstype. On btrfs, decide "same filesystem" by mount source plus fstype, not `st_dev` (each subvolume has its own). Snapshots (`/.snapshots`, snapper, Timeshift) are counted, never scanned. Hardlinks are keyed by `(dev, ino)` and counted once.
- Status reads sysfs and procfs without root: `/sys/class/power_supply` (Battery and UPS, `energy_*` else `charge_*`), hwmon and `thermal_zone*` temperatures, `/sys/class/dmi/id` (treat `Default string`, `To be filled by O.E.M.`, `QEMU` as unknown), `/proc/pressure/memory` and swap for memory pressure. Health scoring must read memory pressure; a restart recommendation needs a Linux-specific basis or is not shown.

## Test environment

- LazyCat devbox (Debian 12 container, `linux-devbox` skill): run tests as the non-root user `mole` (`su mole -c "bats ..."`), since Mole refuses root. Go runs on the Mac: build with `GOOS=linux` (or `go test -c`) and execute the binary there.
- Omarchy: the Try Omarchy VM on the ThinkPad (lease `thinkpad`), reached from the Mac with `ssh -F ~/.config/mole-omarchy/config mole-omarchy` through the ThinkPad hop. The guest runs a user-level sshd (systemd user unit `mole-sshd`, port 2222, key only); the host-side forward `127.0.0.1:2222` is a runtime QMP `hostfwd_add n0 tcp:127.0.0.1:2222-:2222` and must be re-sent after every VM restart. No sudo password is available there: tests run as the desktop user, bats lives in `~/.local/bin`, Go binaries are cross-compiled on the Mac. The guest locale is Chinese, which is the point: parsing must survive it.
- CI: Linux runners only, Arch tests inside an `archlinux` container. No macOS jobs on this branch.

## Releases

Tags use a `linux-v*` prefix so they never trigger `main`'s `V*` release workflow. No release, tag or announcement without the maintainer's explicit go-ahead.

## Git

- Work on `linux` in the `~/www/mole-cli-linux` checkout; never merge `main` into it or `linux` into `main`.
- Commits by `Tw93 <hitw93@gmail.com>`, lowercase type prefixes, body explains why and how it was verified, no AI attribution trailers.
