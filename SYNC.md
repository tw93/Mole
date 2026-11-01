# Synchronization

Mole CLI (Linux) re-implements Mole's product values and safety contracts for Linux; it imports no code from other branches. This file records what was carried over, what is intentionally different, and what is still pending, for two relationships:

- Mole CLI (macOS) (`main`) and Mole CLI (Linux) (`linux`)
- Mole CLI (Windows) (`windows`) and Mole CLI (Linux) (`linux`)

Each row names the source (branch, commit or entry), the Linux status (`Pending`, `Implemented`, `Intentional difference` or `Not applicable`) with a reason, and the verification. Only a published `V*-linux` release proves `Released`.

## Intentional differences

| Contract | Status | Reason |
| --- | --- | --- |
| Shared bash core (`lib/core/file_ops.sh`) | Intentional difference | Re-implemented for GNU tools; the macOS core pins BSD `/usr/bin/stat`, whose `-f` means something else under GNU coreutils (maintainer 2026-11-01). |
| Privileged Trash staging under `/Library` | Not applicable | Linux Mole never deletes or moves arbitrary paths as root; root cleanup runs only through distribution commands. |
| Finder, TCC, LaunchServices, APFS clone handling | Not applicable | macOS-only mechanisms. |

## Implemented on `linux` (2026-11-01, released in V0.1.0-linux on 2026-11-02)

Released: tag `V0.1.0-linux` on `417e4c2d`, x86_64 and aarch64 archives with `SHA256SUMS.txt`, installed from the public `install.sh` into a fresh home on the Omarchy VM and `mo update` reporting 0.1.0 as latest. Known residual: the Flatpak inventory, uninstall and unused-runtime paths are verified only against a fake `flatpak`; check them on a machine with real Flatpak (the maintainer accepted shipping with this, 2026-11-02).

| Contract | Source | Status | Verification |
| --- | --- | --- | --- |
| Trash by default, operations.log row per change, dry-run lists exactly what runs | `main` `docs/SECURITY_DESIGN.md` | Implemented | `internal/xdgtrash` + `bin/trash-go`, `lib/core/delete.sh`; Go tests and a real fixture uninstall on the Omarchy VM, incl. a broken-helper red run. Caches in Clean's allowlist are removed directly (see `AGENTS.md`). |
| Running-owner check before every cache deletion | `main` `lib/core/file_ops.sh` | Implemented | Owner process names per rule in `lib/clean/rules.sh` (Flatpak app caches ask `flatpak ps`); an unrunnable probe counts as running. `tests/clean.bats`, red-run on the VM. |
| Exact-evidence uninstall leftovers, no vendor wildcards | `main` `AGENTS.md` | Implemented | `lib/uninstall/inventory.sh` (package id, desktop ids, and a `StartupWMClass` only one launcher declares); data rows unchecked by default. `tests/uninstall.bats`, red-run on the VM. |
| Main menu, colors, icons, key bindings, paginated multi-select | `main` `mole`, `lib/core/ui.sh`, `lib/ui/menu_paginated.sh` | Implemented | Menu copied as is; frame captured on the VM. |
| Developer cache list | `main` `lib/clean/dev.sh` | Implemented | Mapped to each tool's Linux cache folder in `lib/clean/rules.sh`; macOS-only apps and download stores without a cache folder have no row. |
| analyze and status TUIs | `main` `cmd/analyze`, `cmd/status` | Implemented | Forked and ported (mountinfo, GNU `du --exclude`, sysfs, PSI health); 245 and 209 tests pass on the VM. |
| optimize: task catalog, one outcome per task, dry run, summary block | `main` `bin/optimize.sh`, `lib/optimize/outcomes.sh` | Implemented | `bin/optimize.sh`, `lib/optimize/tasks.sh` with Linux tasks (fontconfig, launcher index, browser SQLite VACUUM after an integrity check, failed units, broken launchers and autostart, pacman orphans and lock, TRIM, power-manager conflicts); no sudo. `tests/optimize.bats`, each guard red-run on the VM; real run on the Omarchy VM. Unused Flatpak runtimes stay Pending until a machine with Flatpak can test it. |
| sudo asked once, before work, on Mole's own prompt line | `main` `bin/clean.sh` `prompt_for_system_clean`, `lib/core/sudo.sh` | Implemented | `mole_sudo_ready` / `mole_sudo_end` in `lib/core/common.sh`: sudo still reads the password, Touch ID has no Linux counterpart. `tests/clean.bats`, password flows on the devbox. |
| clean: browser profile caches, Electron app caches and logs, developer caches, AI agent old versions, editor `.obsolete` extensions | `main` `lib/clean/user.sh`, `lib/clean/app_caches.sh`, `lib/clean/dev.sh` | Implemented | `lib/clean/rules.sh` with owners per rule; not ported: Spotify (offline music), Zoom and podman tmp (layout unconfirmed), ms-playwright and Gradle `caches`/`daemon` (Mac whitelists them), copilot CLI, curl/wget, Steam shadercache. `paccache -ruk0` waits for the maintainer. |
| clean: JetBrains, Deno, uv, Bazel narrowed; dry run sizes only what a real run removes | `main` `lib/core/base.sh` JetBrains protection, `lib/clean/user.sh` DENO_DIR, `lib/clean/dev.sh` `uv cache prune` | Implemented | `tests/clean.bats`, each guard red-run on the VM. |
| clean `--whitelist` | `main` `bin/clean.sh`, `lib/core/base.sh` | Intentional difference | Linux stores rule labels as well as paths, because one label covers many profile folders; a path also keeps a single child of a rule, so `~/.npm/_cacache/*` works as on Mac. |
| clean: unused Flatpak runtimes, core dump and container reports | `main` `lib/clean/system.sh`, `lib/clean/dev.sh` Docker row | Implemented | Only the user installation is cleaned; the system one is reported with its command when it holds runtimes, and uninstall removes system and custom installations through sudo. Flatpak verified only with a fake `flatpak`; needs one run on a machine with Flatpak before release. |
| uninstall: running check for long and wrapped process names, key drain, user units stopped, launcher index refresh, profiles held back, last used, deeper leftovers, `--list` JSON, back to list | `main` `bin/uninstall.sh`, `lib/uninstall/batch.sh`, `review.sh` | Implemented | `tests/uninstall*.bats`; key drain also checked in tmux. |
| optimize: more browser DBs, Thunderbird, broken start commands, root-owned files, icon cache | `main` `lib/optimize/tasks.sh` SQLite, login items | Implemented | Cookies and Login Data never opened. |
| analyze: mount rule, noatime-aware unused label, Flatpak/Steam/Podman/journal/core dump rows | `main` `cmd/analyze` | Implemented | Go tests with fake mountinfo (btrfs Omarchy layout, sshfs, overlay, separate ext4 `/home`). |
| status: power draw, zram, CPU clock, P/E cores, peripheral batteries, per-card NVIDIA, sleeping dGPU left asleep, Intel busy | `main` `cmd/status` | Implemented | Peripherals also shown on the Power card (Mac: JSON only). |
| update: `--force`, prerelease skip, installed-copy guard, menu notice | `main` `mole` update notice, `bin/update` | Implemented | Versions compare by their X.Y.Z core, so a prerelease updates to its stable release and a broken VERSION is repaired; no downgrade, `--force` included; the notice shows only in the installed tree. `--nightly` not applicable (no Linux nightly channel); `completion` and `history` left out (maintainer 2026-11-01). |
