# Product synchronization

This is the synchronization entry point for **Mole CLI (macOS)**, branch `main` of `tw93/Mole`. Workflow and the four canonical product names are in [AGENTS.md](AGENTS.md#product-synchronization). Source review baseline: `3fdf4040`, 2026-10-14, Asia/Singapore. This is a source/record review, not a new full runtime audit or a release.

## Ownership

- The two CLIs: the [Windows branch SYNC.md](https://github.com/tw93/Mole/blob/windows/SYNC.md) owns the shared CLI adaptation queue; the macOS entry links to it rather than duplicating rows.
- Mole CLI (macOS) with Mole Mac: the app's root `SYNC.md` owns the detailed comparison.
- Mole CLI (Windows) with Mole for Windows, and the two apps: Mole for Windows' root `SYNC.md` owns the detailed comparison.
- App-owned records remain private. Public CLI records contain public behavior, source and tests only; never copy private catalogs, implementation details, support data or repository links here.

## Current disposition

| Topic | Status | Source and next check |
| --- | --- | --- |
| Log-root traversal and late Git ownership | Implemented | `8811fcbd` and follow-ups `61756c27`, `f5b5a335`, `a5ba6e79`, `1c323dba`; `lib/clean/user.sh` and `lib/clean/caches.sh` recheck roots/ownership. The app-owned comparison must no longer call these unfixed. This record does not re-certify the full test suite. |
| Offline and generated media | Implemented | `b364d17d`, `lib/clean/app_caches.sh`; preserve data that a user cannot regenerate from the cache alone. Windows paths require their own policy review, tracked by CLI-SYNC-01 (Spotify, implemented) and CLI-SYNC-09 (recordings, pending) on `windows`. |
| Uninstall review and configuration references | Implemented | `eb21fff1`, `lib/uninstall/config_refs.sh`; Windows adaptation remains pending, not an instruction to copy macOS paths. |
| Process CPU denominator | Intentional difference | `cmd/status/metrics_process.go` consumes macOS `ps` process CPU; both CLIs use one logical CPU as 100%. Do not divide by machine CPU count just to match a GUI. |
| GUI-only capabilities | Not applicable | Menu/tray, app bulk updates and private leftover catalogs are not CLI parity requirements. |

Delivery: GitHub's latest macOS stable checked on 2026-10-14 is `V1.59.1`; source after that tag must not be called released. Consult the live release and exact commit ancestry before replying to users.
