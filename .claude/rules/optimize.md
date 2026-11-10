---
paths:
  - "bin/optimize.ps1"
  - "tests/Optimize.Tests.ps1"
  - "cmd/status/platform_names.go"
  - "cmd/status/metrics_windows.go"
  - "cmd/status/metrics_health.go"
---

# Optimize rules (Mole CLI (Windows))

Moved verbatim from the Safety Rules of `AGENTS.md` on 2026-11-10; the cross-cutting safety contract stays there and applies here too.

- SFC redirects stdout to a uniquely created temporary file, deletes only that file in `finally`, and records success only with both a zero native exit code and a recognized result. sfc.exe prints its own display language, so when its English summary is absent and it exited 0, `Read-SfcCbsVerdict` reads the `[SR]` lines CBS.log gained since the scan started (never localized; Microsoft documents `findstr /c:"[SR]"`): any `Cannot repair member file` is unrepairable, otherwise a finished `Repair complete` pass with `Repairing N components` totals decides clean or repaired (#1915, zh-CN). A log that is unreadable, shorter than at the start (rotated) or without a finished pass proves nothing and still points to CBS.log without claiming success. Locked by `SFC verdict from CBS.log (#1915)` in `tests/Optimize.Tests.ps1`.
- Disk optimization reads target-volume health before writing, keeps a known Warning/Unhealthy target, and requires external power for battery-equipped machines. Unknown power retains the drive; a complete empty battery inventory allows a desktop. A failed physical-disk inventory must still query the target volume independently. Unknown health is not a critical fault, and raw startup registration counts are not health failures. Locked by `tests/Optimize.Tests.ps1`. Status aggregates capacities only after every present system battery is known; empty bays are excluded and cycles describe the oldest pack when every count is known, independently of whether capacities are comparable. Unknown capacity never implies Healthy from cycles alone; preserve independent cycle warnings and a known system condition.
- Besides the system drive, Optimize retrims only lettered fixed NTFS or ReFS volumes that report Healthy, on exactly one partition of a disk and physical disk that both report Healthy, with the physical disk an SSD. Any inventory failure adds no volume, and a failed extra retrim is reported as failed. Locked by `tests/Optimize.Tests.ps1`.
- `mo optimize` does not reset Winsock or rebuild the Search index, icon, font or Store caches: each drops state the user has to rebuild or reconnect for little gain. Locked by `tests/Optimize.Tests.ps1`.
- Windows Update inspection queries only the local catalog in a bounded job. An incomplete, failed or timed-out query is unknown, never zero updates; stop and remove the owned job on every exit. Do not make maintenance previews wait for an online update search. Locked by `tests/Optimize.Tests.ps1`.
