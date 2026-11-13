# Mole CLI (Windows)

Written against Mole CLI (Windows) 1.43.0. `mo analyze --json` and
`mo uninstall --list` arrived in 1.37.0; on 1.36.0 or older either flag is
rejected as an unknown option, so fall back to `mo status --json`,
`mo history --json` and `mo clean --dry-run`.

## Install

```powershell
scoop install mole
```

Without Scoop, point the user to the install script in the README
(https://github.com/tw93/Mole/tree/windows#quick-start) and let them run it; do
not pipe a download into a shell yourself. The script install needs Git, and Go
when it has to build the native tools.
Mole runs in Windows PowerShell 5.1 or PowerShell 7. A winget or Scoop install
is updated and removed through that package manager; `mo update` and
`mo remove` print the right command.

## Commands

| Command | Without a console (how an agent runs it) | Who runs the real thing |
|---|---|---|
| `mo analyze --json [path]` | Read-only JSON | Agent |
| `mo status --json` / `mo status --watch --interval=1s` | Read-only JSON / NDJSON; write the interval with `=`, which 1.36.0 and older also parse | Agent |
| `mo history --json --limit N` | Read-only JSON, N is 1-200 | Agent |
| `mo uninstall --list` | Read-only JSON app inventory | Agent |
| `mo clean --dry-run` | Preview, writes the path list | Agent |
| `mo clean` | **Starts immediately, no confirmation.** User-level cleanup only | Agent after consent |
| `mo clean --system` | Needs an Administrator PowerShell, for the preview too: without it `mo clean --system --dry-run` shows only the user-level part | User, in an elevated PowerShell: `mo clean --system --dry-run`, then `mo clean --system` |
| `mo clean --game-media`, `mo clean --gpu-shaders` | Opt-in extras: game replays, screenshots and recordings older than 90 days; GPU shader caches that games rebuild on next launch | Agent after consent, only when the user asked for them |
| `mo optimize --dry-run` | Preview of maintenance tasks | Agent |
| `mo optimize` | **Starts immediately, no confirmation.** It ends with a y/N question about System File Checker, which takes minutes | Agent after consent; SFC is the user's call in their own console |
| `mo purge --dry-run` | Prints the project count and total, then opens a selection list that reads keys from a console; without one it errors out or waits | User. `mo purge --help` lists the folders it scans, and the agent may run that |
| `mo purge` | Selection list and a y/N confirmation | User |
| `mo installer --dry-run` | 1.45.0 and newer. Preview of `.msi` installers in Downloads that are at least 14 days old; without a console it previews them all, with one it opens a selection list | Agent |
| `mo installer` | 1.45.0 and newer. Selection list and a y/N confirmation; chosen files go to the Recycle Bin | User |
| `mo uninstall --dry-run` | Selection list, needs a console | User |
| `mo uninstall` | Selection list, then each app's own uninstaller | User |
| `mo clean --whitelist` | Opens the whitelist in Notepad and waits | User, or edit the file (below) |
| `mo purge --paths` | Interactive editor | User |

`mo uninstall` takes no app name. After `--list`, tell the user which entry to
pick by its `name`; the selection list supports type-to-search. Ask them to run
`mo uninstall --dry-run` first, which names the uninstaller each app would use.
The vendor's uninstaller decides what it removes inside its own folder, such as
a game library or local saves; warn the user when the app keeps data there. There is no
`--yes` on any Windows command, and no slim command.

Administrator steps belong to the user: they open PowerShell with "Run as
administrator" and run the command there. The agent never tries to elevate. If
the administrator account is a different user, that shell has its own
`%USERPROFILE%`, so its whitelist, logs and path list are separate.
Some uninstallers show their own UAC prompt or wizard.

## What a removal can be undone

- `mo clean`, `mo purge` and `mo optimize` delete permanently. `mo clean` does
  not empty the Recycle Bin.
- `mo uninstall` runs the app's registered uninstaller, which behaves as that
  vendor wrote it. Afterwards Mole moves a verified leftover install folder to
  the Recycle Bin, never deleting it permanently.
- Files deleted inside the interactive `mo analyze` go to the Recycle Bin.
- `mo installer` moves the `.msi` files the user picks to the Recycle Bin.
- `mo purge` targets build output and dependency folders (`node_modules`,
  `target`, `build`, `dist`, `venv` and similar). Build output rebuilds
  offline; dependency folders need a download. Git-tracked content and nested
  repositories are kept.

## JSON surfaces

**`mo analyze --json [path]`.** One object: `scan_status`, `path`, `overview`,
`total_size`, `total_files`, `large_files[]` of `{name, path, size}`, and
`entries[]` of `{scan_status, name, path, size, is_dir, insight, cleanable,
last_access}`, the same fields as macOS. Sizes are bytes. `scan_status` is
`complete`, `partial` or `unavailable`; a `partial` size is a lower bound and
an `unavailable` one is unknown, not zero. Without a path it returns the
overview of user folders and drives with `overview: true` and an empty `path`;
read `overview`, not `path`. `insight: true` marks known heavy locations such
as old Downloads, Temp and package-manager caches. `cleanable: true` needs a
`CACHEDIR.TAG` and is never set for folders `mo clean` already covers. Put
`--json` before the path, for example `mo analyze --json D:\`.

**`mo status --json`.** One snapshot with `health_score`, `health_score_msg`,
`cpu`, `memory`, `disks[]`, `disk_io`, `network[]`, `batteries[]`,
`top_processes[]` (`cpu` is a percent of one logical CPU, so it can exceed
100; `memory` is a percent of physical memory) and host and hardware fields.
There are no temperature or fan readings on Windows; say so instead of
guessing. `--watch` prints one object per
line; bound it (for example `mo status --watch --interval=1s | Select-Object
-First 10`) and never leave it running.

**`mo history --json --limit N`.** `logs.operations` (the log path), `limit`,
`sessions[]` of `{command, run_id, started_at, operation_count, actions}` where
`actions` counts removed, recycled, uninstalled, skipped, failed and other, and
`operations[]` of `{timestamp, command, run_id, action, path, detail}`.
`action` is the logged verb in lower case, such as `removed`, `recycled`,
`uninstalled`, `skipped` or `failed`, and `detail` holds the reason or count
when there is one. Dry runs write nothing to the log, so previews never
appear. The log is `%USERPROFILE%\.config\mole\operations.log`; `MO_NO_OPLOG=1`
turns it off, so an empty history can also mean logging was off.

**`mo uninstall --list`.** When stdout is redirected it prints a JSON array of
`{name, id, source, version, publisher, path, size, size_bytes}`. `source` is
`Registry` or `WindowsStore`; `id` is the selection key with a `registry:`,
`package:` or `name:` prefix; `path` is empty when the install location is
unknown; `size` is a display string, and `size_bytes` is null when the size
was never measured (shown as `Unknown`). Non-ASCII names arrive as `\uXXXX`
escapes, which any JSON parser decodes. The list reuses the app cache for 24
hours; `mo uninstall --list --rescan` refreshes it.

**`mo clean --dry-run` path list.** Every candidate path goes to
`%USERPROFILE%\.config\mole\clean-list.txt`. It is a snapshot; the real run
rescans.

## Protecting a path

`%USERPROFILE%\.config\mole\whitelist.txt` holds one full path or wildcard
pattern per line, `#` starting a comment, matched without regard to case. Every
removing command honors it. After the user agrees you may create it or append
to it; there are no built-in defaults that a new file would replace. Write it
as UTF-8 with a BOM (`Add-Content -Encoding UTF8` in Windows PowerShell 5.1),
since 5.1 reads a file without one in the ANSI code page, and make sure the
existing last line ends with a newline first. A directory entry also protects
everything below it. If the file
exists but cannot be read, Mole keeps every target rather than cleaning
without it. Confirm with a fresh `mo clean --dry-run`.

## Gotchas

- `--debug` prints detailed logs; use it when a command did nothing.
- `mo update` and `mo remove` change Mole itself. Run them only when asked.
