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

## Implemented on `linux` (2026-11-01, not released)

| Contract | Source | Status | Verification |
| --- | --- | --- | --- |
| Trash by default, operations.log row per change, dry-run lists exactly what runs | `main` `docs/SECURITY_DESIGN.md` | Implemented | `internal/xdgtrash` + `bin/trash-go`, `lib/core/delete.sh`; Go tests and a real fixture uninstall on the Omarchy VM, incl. a broken-helper red run. Caches in Clean's allowlist are removed directly (see `AGENTS.md`). |
| Running-owner check before every cache deletion | `main` `lib/core/file_ops.sh` | Implemented | Owner process names per rule in `lib/clean/rules.sh` (Flatpak app caches ask `flatpak ps`); an unrunnable probe counts as running. `tests/clean.bats`, red-run on the VM. |
| Exact-evidence uninstall leftovers, no vendor wildcards | `main` `AGENTS.md` | Implemented | `lib/uninstall/inventory.sh` (package id, desktop ids, and a `StartupWMClass` only one launcher declares); data rows unchecked by default. `tests/uninstall.bats`, red-run on the VM. |
| Main menu, colors, icons, key bindings, paginated multi-select | `main` `mole`, `lib/core/ui.sh`, `lib/ui/menu_paginated.sh` | Implemented | Menu copied as is; frame captured on the VM. |
| Developer cache list | `main` `lib/clean/dev.sh` | Implemented | Mapped to each tool's Linux cache folder in `lib/clean/rules.sh`; macOS-only apps and download stores without a cache folder have no row. |
| analyze and status TUIs | `main` `cmd/analyze`, `cmd/status` | Implemented | Forked and ported (mountinfo, GNU `du --exclude`, sysfs, PSI health); 245 and 209 tests pass on the VM. |
