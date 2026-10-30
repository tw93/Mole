# Incidents

Defects that reached a user or a published Mole CLI (Windows) release, kept as the eval set for every review layer
("incidents are the eval"). A row is added in the same change that fixes the defect: the fix commit, the commit that
introduced it when confirmed, the earliest layer that should have caught it, and the test that catches it now.
`Reported` is the issue or PR date, or the fix date when nothing was filed. `scripts/check_incidents.py` (run by the
Check workflow) fails a row whose commit does not resolve, whose layer is not one of the names below, or whose
catcher is not defined in the code.

A catcher is written in backticks exactly as the code names it: a Pester `It` name as written in `tests/*.ps1`
(a template such as `Never offers <_>` included), a Go `Test...` function under `cmd/`, a Python `test_...` method
under `tests/`, or a PowerShell function for a source gate.

Layers, earliest first:

- `write-time`: the author's own check before committing (a grep of same-shape sites, a dry run).
- `unit`: `scripts/test.ps1` (Pester under Windows PowerShell 5.1 and pwsh 7, `go test ./cmd/...`) and the Python
  tests, as the Validation workflow runs them.
- `lint`: the Check workflow (gofmt, golangci-lint, the PowerShell parse under Windows PowerShell 5.1).
- `review`: a diff review or security audit before merging.
- `e2e`: `scripts/e2e_windows.py` against the Parallels VM and the x64 ThinkPad.
- `release`: building, signing and package-manager validation of the release assets (`RELEASE.md`).
- `field`: only a real user's machine, network or policy shows it.

When a review prompt or its model changes, rerun it on the files each fix touched as they were at `<Fixed>^` and
record which rows it finds.

## Incidents

| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |
|---|---|---|---|---|---|---|
| I-01 | 2026-10-11 | A dry-run `mo uninstall` still ran msiexec, each app's uninstaller and Remove-AppxPackage | unknown | 01e7940f | unit | `Runs no uninstaller for MSI, EXE or Store apps` |
| I-02 | 2026-10-11 | winget's archive scan rejected the signed release zip, whose entry names used backslashes | 07e2fc1a | 611069e5 | release | `Stores entry names with forward slashes, as winget's archive check requires`, `Is the only way the release scripts build a zip` |
| I-03 | 2026-10-12 | An elevated `mo optimize` reset Winsock and deleted the Windows Search index without asking | unknown | 721d18f5 | review | `Never resets Winsock or rebuilds search, icon, font or Store caches when elevated` |
| I-04 | 2026-10-12 | Default `mo clean` rows emptied Zoom's chat database, Teams storage and Recent items as caches | unknown | 73be7858 | review | `Never offers <_>` |
| I-05 | 2026-10-13 | A fresh script install could not fetch the status and analyze tools once api.github.com rate-limited a shared IP | unknown | 5914ebeb | field | `Downloads the checksum and binary from the release URLs, not the API` |
| I-06 | 2026-10-13 | Install and `mo update` failed at git clone on a PC that reaches GitHub only through the system proxy | unknown | 3cdfeb71 | field | `Passes the system proxy to git when GitHub goes through it` |
| I-07 | 2026-10-15 | `mo update` started from a PowerShell 7 terminal could not refresh analyze and status | unknown | f8803958 | field | `Verifies the checksum without Get-FileHash (#1744)`, `Drops PowerShell 7 module folders inherited by Windows PowerShell and keeps the rest` |
| I-08 | 2026-10-18 | The uninstall menu crashed under Windows PowerShell 5.1 when a search matched exactly one app | unknown | 0e9d06b4 | unit | `selects the only app a search matches` |
| I-09 | 2026-10-26 | `mo.exe` could not run any command where policy blocks powershell.exe | e8fd407d | a56c6a40 | field | `TestRunPowerShellFallsBackWhenTheFirstHostCannotStart` |
| I-10 | 2026-10-09 | `mo analyze C:\` reported 101 GB of 830 GB used: directory sizes stopped three levels deep and skipped folders whose names start with a dot | 3653900e | 4a9838af | unit | `TestDirectorySizesCountDeepAndHiddenDirs` |
| I-11 | 2026-10-30 | The developer-tools cleanup reached six VS Code cache leaves without the owner checks used by the app-cache entry, allowing an active editor's cache to be removed | unknown | 3d2db78f | review | `Keeps both VS Code cleanup entries guarded for <Owner> in preview <Preview>` |
| I-12 | 2026-10-30 | Self-removal could traverse a junction in an ancestor of the cache root and remove cache contents at the redirected destination | unknown | 3d2db78f | unit | `Keeps the cache when its ancestor is a junction` |
| I-13 | 2026-10-30 | Bun cache cleanup removed the default cache directly without checking running owners or the root configured by Bun | unknown | 3d2db78f | review | `Keeps an unavailable Bun cache for a running or unknown owner: <Owner>`, `Uses the configured Bun root and never falls back after a failed owner command`, `Keeps the default Bun cache when a usable owner returns an unknown root`, `Previews the configured Bun root without starting cleanup`, `Rechecks Bun activity before its owner command` |
| I-14 | 2026-10-30 | Automatic update lookup still launched Windows PowerShell when policy blocked it, even after the native launcher successfully fell back to PowerShell 7 | 59664dca | 3d2db78f | review | `Starts update lookup with the current PowerShell host` |
