---
paths:
  - "bin/purge.ps1"
  - "lib/core/file_ops.ps1"
  - "tests/PurgeBoundary.Tests.ps1"
---

# Purge rules (Mole CLI (Windows))

Moved verbatim from the Safety Rules of `AGENTS.md` on 2026-11-10; the cross-cutting safety contract stays there and applies here too.

- Purge never offers or removes an artifact in use, and never renames one to find out. `Get-PurgeArtifactHold` reads the process list (an image inside the artifact, or its full path on a command line) and asks for delete access with no sharing on every entry, plus write access on plain files because only that fails on a loaded library. It is read-only, so a dry run answers the same as a real run; an unknown process list or a refused probe retains the artifact and names the cause. A relative or 8.3 path on a command line with nothing held open and a loaded library that is read-only or denies write cannot be seen; a hard-linked file held elsewhere retains. The probe opens each entry with no sharing for an instant, so a build writing at that moment could see one sharing violation. Locked by the `Purge leaves an artifact in use alone` block in `tests/PurgeBoundary.Tests.ps1`.
- Purge excludes `.idea`, scopes generic artifact names to the matching build ecosystem, and keeps Git-tracked content and nested repositories. Discovery and the final post-sizing guard use the same policy, literal case-insensitive Git pathspecs and isolated Git environment. A failed probe keeps the candidate. Locked by `tests/PurgeBoundary.Tests.ps1`.
