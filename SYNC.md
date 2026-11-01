# Synchronization

Mole CLI (Linux) re-implements Mole's product values and safety contracts for Linux; it imports no code from other branches. This file records what was carried over, what is intentionally different, and what is still pending, for two relationships:

- Mole CLI (macOS) (`main`) and Mole CLI (Linux) (`linux`)
- Mole CLI (Windows) (`windows`) and Mole CLI (Linux) (`linux`)

Each row names the source (branch, commit or entry), the Linux status (`Pending`, `Implemented`, `Intentional difference` or `Not applicable`) with a reason, and the verification. Only a published `linux-v*` release proves `Released`.

## Intentional differences

| Contract | Status | Reason |
| --- | --- | --- |
| Shared bash core (`lib/core/file_ops.sh`) | Intentional difference | Re-implemented for GNU tools; the macOS core pins BSD `/usr/bin/stat`, whose `-f` means something else under GNU coreutils (maintainer 2026-11-01). |
| Privileged Trash staging under `/Library` | Not applicable | Linux Mole never deletes or moves arbitrary paths as root; root cleanup runs only through distribution commands. |
| Finder, TCC, LaunchServices, APFS clone handling | Not applicable | macOS-only mechanisms. |

## Pending

| Contract | Source | Status | Next check |
| --- | --- | --- | --- |
| Trash by default, operations.log row per change, dry-run lists exactly what runs | `main` `docs/SECURITY_DESIGN.md` | Pending | Implement with the XDG Trash writer; bats on devbox as user `mole`. |
| Running-owner check before every cache deletion | `main` `lib/core/file_ops.sh` | Pending | Per-rule owner executable or lock file. |
| Exact-evidence uninstall leftovers, no vendor wildcards | `main` `AGENTS.md` | Pending | Uninstall phase. |
