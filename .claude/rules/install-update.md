---
paths:
  - "install.ps1"
  - "quick-install.ps1"
  - "bin/remove.ps1"
  - "bin/update.ps1"
  - "lib/core/update_check.ps1"
  - "lib/core/version.ps1"
  - "tests/Install.Tests.ps1"
  - "tests/InstallLifecycle.Tests.ps1"
  - "tests/UpdateNotice.Tests.ps1"
  - "mole.ps1"
  - "tests/Router.Tests.ps1"
  - "tests/Commands.Tests.ps1"
---

# Install, update and remove rules (Mole CLI (Windows))

Moved verbatim from the Safety Rules of `AGENTS.md` on 2026-11-10; the cross-cutting safety contract stays there and applies here too.

- `%LOCALAPPDATA%\Mole` is the Mole for Windows app's data folder (license, settings, registry backups). New installs default to `%LOCALAPPDATA%\Programs\mole-cli`; an existing source install there keeps updating in place. `install.ps1 -Uninstall` removes only listed top-level files and the exact nested files from `Get-MoleInstallNestedFiles`, retains unknown files and nonempty Git metadata, refuses an unrecognized install, and never falls back to another folder. After a removal it also deletes `~\.cache\mole` without following links, so `mo remove` and a direct `install.ps1 -Uninstall` leave the same state; `tests/Install.Tests.ps1` locks this.
- Self-removal checks the native launcher is not in use before modifying PATH, shortcuts or files. A running `mo.exe` cannot remove itself synchronously on Windows; give the quoted PowerShell removal command instead of scheduling detached deletion. Reject linked cache roots and ancestors before enumeration. Reject linked config roots and ancestors before enumeration and before each top-level removal, while preserving operation logs.
- Package-manager installs are never removed or updated by deleting their files. `mo update` and `mo remove` recognize a winget or Scoop install folder and print that manager's own command (`winget upgrade tw93.MoleCLI`, `scoop update mole`, `winget uninstall tw93.MoleCLI`, `scoop uninstall mole`); package-manager guidance precedes the Git prerequisite. Locked by `tests/InstallLifecycle.Tests.ps1`.
- Automatic update notices query the installation's own channel in a short-lived background process using the current `$PSHOME` host, cache successful lookups for one day and failed attempts for one hour, and never install anything. Keep redirected output, help/version, structured output and dry runs free of notices and lookup writes. GitHub tags must be stable Windows CLI tags; release titles and macOS tags are not versions. Locked by `tests/UpdateNotice.Tests.ps1`.
