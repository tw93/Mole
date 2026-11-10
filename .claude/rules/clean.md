---
paths:
  - "bin/clean.ps1"
  - "lib/clean/*.ps1"
  - "lib/core/file_ops.ps1"
  - "tests/Clean.Tests.ps1"
  - "tests/CleanupBoundary.Tests.ps1"
  - "tests/CleanupTargets.Tests.ps1"
  - "tests/AppCacheSafety.Tests.ps1"
  - "tests/GitProxy.Tests.ps1"
  - "lib/core/base.ps1"
  - "mole.ps1"
---

# Clean rules (Mole CLI (Windows))

Moved verbatim from the Safety Rules of `AGENTS.md` on 2026-11-10; the cross-cutting safety contract stays there and applies here too.

- `-GameMedia` never selects generic `Pictures\Screenshots` or `Videos\Screen Recordings`; age does not prove that personal media is disposable. Existing app/game-specific opt-in targets keep their separate policy (CLI-SYNC-09).
- Bun cleanup resolves the usable owner's `bun pm cache` root and runs `bun pm cache rm` through the shared owner pipeline. Running or unknown `bun`/`bunx` processes retain caches, including a fresh boundary check. Unknown roots and failed owner cleanup never fall back to recursive deletion; an unavailable/unusable Bun permits only the guarded default cache. Locked by `tests/AppCacheSafety.Tests.ps1` and `tests/CleanupBoundary.Tests.ps1`.
- Vesktop cache cleanup owns only the measured `sessionData` Cache, Code Cache and GPUCache leaves, guarded by `vesktop`; settings and persistent session siblings stay outside the target set.
- Adobe Common media and peak caches use the shared owner guard for Premiere Pro, After Effects, Media Encoder and Audition; live or unknown owners retain them, including after sizing. Yarn Classic uses the same guard for Node. Yarn Berry `.yarn\cache`, `.yarn\berry\cache` and `%LOCALAPPDATA%\Yarn\Berry\cache` hold dependencies read directly by applications and are clean-protected, including parent sweeps; do not treat them as disposable Classic cache. Locked by `tests/AppCacheSafety.Tests.ps1`.
- Application cache cleanup keeps Poetry virtualenvs and Service Worker CacheStorage. Use `Clear-MoleAppCache` for the browser, Teams, editor and notes cache leaves it owns: running or unknown owners and held/unknown lock files retain them in preview and real runs, including a fresh check after sizing. Both VS Code cleanup entries and Code Insiders use this guard; the shared C++ extension cache checks both channels. Packages remain protected except the exact new Teams WebView profile Cache, Code Cache and GPUCache leaves during automatic clean; user exclusions still win. Profile discovery is one level, capped at 128 directories with a two-second checkpoint budget, and discards incomplete results. Locked by `tests/AppCacheSafety.Tests.ps1`.
- The Chromium preview channels, 360 Chrome, Quark and the Electron and CEF apps in `Clear-AppCaches` (Trae, Qoder, Kiro, CodeBuddy, Discord PTB and Canary, QQ, Feishu, Lark, Jianying Pro, CapCut) own only the measured cache leaves, each through `Clear-MoleAppCache` with its own image (Qoder under both `Qoder` and `Qoder IDE` until its image is measured); a preview channel is guarded by the stable browser's image. Storage, cookies, sessions, projects and the effects and models under Jianying and CapCut `User Data\Cache` stay. App logs go through `Remove-OldFiles` as week-old top-level files only. Locked by `tests/AppCacheSafety.Tests.ps1`.
- `~/.gitconfig.lock` is never deleted: Git holds it while it writes the config, and neither age nor an idle git process proves the write is over (same rule as `main`).
- System cleanup does not stop FontCache or Windows Update for targets the Windows path policy refuses. Preserve service state instead of weakening that policy. Owner cache previews list the actual root without estimating whole-store savings for selective pruning; real-mode statistics use only a complete before/after measurement of the same root. An unmeasured successful owner command is activity, not proof the system was already clean. Locked by `tests/CleanupTargets.Tests.ps1` and `tests/Clean.Tests.ps1`.
- Error reports keep seven days by the newest creation/write time throughout each complete report, not the WER collection directory's timestamp. Recheck bounded complete visibility after sizing, and retain recent, redirected or unreadable reports. Sublime caches in Local and Roaming use the shared owner guard. Clean preserves Adobe Team Projects state at discovery and the shared clean sink, including parent sweeps; it is not proven disposable media cache. Locked by `tests/AppCacheSafety.Tests.ps1`.
- Delivery Optimization files are never deleted by Mole: under `--system` it asks the service through `MSFT_DeliveryOptimizationFile.Delete` for finished (Status 1 or 2), unpinned files with a well-formed id, and counts only files the service no longer lists afterwards, by the service's size field (an intentional exception to before/after measurement). An unanswered provider, an unknown cache root, a value in another shape or a whitelist row on, above or below the root keeps everything (a wildcard row that may reach the root is checked against the ancestors and the tree, and an unreadable tree or a link inside it keeps everything), and dry run calls no Delete. `C:\NVIDIA\DisplayDriver` version folders go only when every entry is a week old and no process runs from that folder by its CIM image path (an unreadable process list keeps everything), both rechecked at the removal boundary; the rest of `C:\NVIDIA` is never a target. `C:\Windows\SystemTemp` stays out because `C:\Windows` is protected. Locked by `tests/AppCacheSafety.Tests.ps1`.
- `mo clean` keeps exit 0 when locked files are skipped; the sentence and its reason sit with the uninstall exit-code rule in `.claude/rules/uninstall.md` (the "Right before launch" bullet), and `mole.ps1` passes each command's status on.
