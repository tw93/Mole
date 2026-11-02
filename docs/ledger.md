# Mole CLI (Linux) ledger

What has been decided, shipped, verified and left open for Mole CLI (Linux), in one place. Contracts live in `AGENTS.md`, cross-product rows in `SYNC.md`, studies in `docs/oss-research.md`; this file links them by date and does not repeat them. Add a line here whenever a release, a maintainer decision, a measurement or an open item changes.

## Decisions (maintainer)

| Date | Decision | Rejected alternative |
|---|---|---|
| 2026-11-01 | Name: Mole CLI (Linux), matching Mole CLI (Windows). Free and open source, no GUI, no paid tier. | A paid Linux edition: Linux users pay rarely, and the value is reach among developers. |
| 2026-11-01 | Its own `linux` branch, like `windows`, re-implementing rules rather than sharing `main`'s code. | One branch with per-platform dispatch: any BSD/GNU difference (`stat -f` above all) could silently disable a safety check, and devbox tests showed it. |
| 2026-11-01 | First target Omarchy (Arch + Hyprland), then other Arch systems; apt, dnf and zypper rules come later, and on those systems the package items simply do not appear. | Debian/Ubuntu first. |
| 2026-11-01 | Scope: clean, uninstall, optimize, analyze, status; purge deferred. `completion` and `history` left out; `mo update` required. | Shipping purge in the first release. |
| 2026-11-01 | Go public once the first usable version is done, with optimize inside it ("without it the product is not complete"). | Releasing clean, uninstall, analyze and status first and optimize in the next version. |
| 2026-11-02 | Publish V0.1.0-linux with Flatpak verified only against a fake `flatpak` as a known residual. | Waiting for a machine with real Flatpak (it was verified later in CI). |
| 2026-11-02 | 0.2.0: everything from the second study round (snapshot honesty, cache rules, xdg-ninja leftovers, optimize reports, status grouping). | Splitting it over several minor versions. |
| 2026-11-02 | No logo on the macOS README (it already has a large header image); the Windows and Linux READMEs show the round app logo. | Adding the logo to all three. |
| 2026-11-02 | AUR package `mole-cli-bin`: prepared, then held because AUR registration is paused. | Homebrew on Linux (the `mole` formula is macOS-only), AUR names `mole` and `mole-bin` (taken by an unrelated SSH tunnel tool that ships `/usr/bin/mole`). |

## Releases

| Tag | Commit | Date | Title | What it carried |
|---|---|---|---|---|
| `V0.1.0-linux` | `417e4c2d` | 2026-11-02 | (tag name only) | clean, uninstall, optimize, analyze, status, update and remove; x86_64 and aarch64 archives with `SHA256SUMS.txt`. |
| `V0.2.0-linux` | `30e358d7` | 2026-11-02 | Candid | btrfs snapshot honesty, new cache rules, about 60 more apps' leftovers, optimize reports, app grouping and btrfs allocation in status. |

Both are published with `--latest=false`; `releases/latest` stays a macOS tag. Release notes follow the macOS and Windows format (header, numbered Changelog, 更新日志 with one sentence per item, Install).

## Verification record

- **Omarchy VM** (Try Omarchy, Arch, ext4, Chinese locale): every 0.1.0 and 0.2.0 command run for real, each safety guard red-run, the full bats and Go gates run natively; 0.1.0 installed from the public `install.sh` into a fresh home, and `mo update` moved it to 0.2.0; 0.2.0 installed the same way on 2026-11-02 (archive passed in with `--archive`, since github.com release downloads were reset on the ThinkPad's network), every command exiting 0 through `mo remove --yes`.
- **Devbox** (Debian 12 container): GNU tool behaviour and sudo password flows with a throwaway sudoers entry.
- **Real btrfs and snapper** (2026-11-02, throwaway VM with Omarchy's subvolumes and snapper config): 231 MB of old packages freed 0 MiB until the snapshot holding them was deleted, then 220 MiB; clean, uninstall, analyze and status all said so; a separate `@pkg` subvolume showed no note.
- **Real Flatpak and Snap** (2026-11-02, `real-tools.yml` on Ubuntu 24.04): a user Flatpak app listed, removed through flatpak with its data kept and then listed as an orphan, its cache cleaned, 2.11 GB of unused runtime freed; Snap's `hello-world` cache found, skipped while running in its snap scope, cleaned afterwards. Runs again whenever clean, uninstall or delete code changes.
- **CI** (`test.yml`): shellcheck, Go tests and bats in an `archlinux` container, plus a release archive installed, run and removed for a fresh user; aarch64 archive checked on an ARM runner.
- Not yet on real hardware: per-process GPU memory on a real GPU, AMD GPU sysfs names, every battery driver's fields.

## Measurements (2026-11-01)

- A fresh Omarchy install has little system junk: pacman cache 421 MB with one version per package (so `paccache -rk2` finds nothing), journald 225 MB, `~/.cache` 114 MB. The real space is in developer folders, mise (654 MB) and project build output, so Mole is not described as freeing tens of GB of system junk.
- On the devbox a single Rust project's `target` was 8.8 GB against 614 MB of toolchains: the case for purge when it comes.
- Before the port, `main`'s status on Linux scored a 72%-memory, swapping VM as 98 "Excellent", since memory pressure was empty there; the Linux status reads PSI and swap.

## Install channels (researched 2026-11-02)

- Today: `install.sh` from this branch, `mo update`, `mo remove`.
- AUR: `mole-cli-bin` installing to `/usr/lib/mole-cli` and linking only `/usr/bin/mo`, conflicting with `mo-bin`; `mo update` and `mo remove` would point to the package manager when pacman owns the copy. The package, its CI check and that update/remove change passed CI on 2026-11-02 and are kept off this branch until AUR registration reopens.
- Omarchy's own package repository needs the Omarchy maintainers; not asked.
- deb, rpm and Nix come with Debian/Ubuntu and Fedora support.

## Open

- AUR `mole-cli-bin`, once registration reopens.
- Purge, waiting for the maintainer.
- apt, dnf and zypper rules.
- `mo uninstall --yes` run outside a terminal cannot remove a Flatpak app, because flatpak answers its own prompt with "n"; Mole reports it as not removed. Kept, since package managers keep their own confirmation.
- Hardware checks listed under Verification record.
- Networks that reset github.com release downloads (seen 2026-11-02 from the ThinkPad's network, API reachable) make `install.sh` and `mo update` fail; the installer's `--archive`/`--sums` is the workaround.
