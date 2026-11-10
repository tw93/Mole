#!/usr/bin/env python3
"""Name the verification a change needs from the paths it touches, not from who wrote it.

    python scripts/risk_tier.py [path ...]

With no paths it reads the change not yet on the upstream branch: commits since the merge base with @{upstream}
(origin/windows when there is none) plus staged, unstaged and untracked files. Prints one line per tier the change
reaches, highest first, and nothing when only the default gate applies (`scripts/test.ps1`, which Validation runs
on every push). It is advice, never a failure: the gates it names run on a real PC or need the maintainer, where
CI cannot prove they ran.
"""
import fnmatch
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Highest first. A path takes every tier it matches.
TIERS = [
    ("release", "actionlint on workflow changes; tests/Release.Tests.ps1 on a staged build-release.ps1 run; "
                "scripts/e2e_windows.py on the VM and the ThinkPad; the maintainer's go-ahead (RELEASE.md)", [
        ".github/workflows/*", "scripts/build-release.ps1", "scripts/new-release-zip.ps1",
        "scripts/sign-release.ps1", "scripts/write-checksums.ps1", "scripts/render-packaging.ps1",
        "packaging/*", "VERSION", "lib/core/version.ps1",
    ]),
    ("install", "tests/Install.Tests.ps1, InstallLifecycle.Tests.ps1 and UpdateNotice.Tests.ps1 under both "
                "powershell and pwsh (scripts/test.ps1); scripts/e2e_windows.py on a real PC", [
        "install.ps1", "quick-install.ps1", "mole.ps1", "bin/update.ps1", "bin/remove.ps1",
        "lib/core/tui_binaries.ps1", "lib/core/update_check.ps1", "cmd/mo/*",
    ]),
    ("deletion", "a dry run first (mo <command> --dry-run); a Pester case red on the old code; "
                 "scripts/test.ps1 under Windows PowerShell 5.1; SECURITY_AUDIT.md claims rechecked", [
        "lib/core/base.ps1", "lib/core/file_ops.ps1", "lib/clean/*", "bin/clean.ps1", "bin/uninstall.ps1",
        "bin/purge.ps1", "bin/optimize.ps1", "cmd/analyze/delete.go", "cmd/analyze/oplog.go",
        "cmd/analyze/protect_windows.go", "cmd/analyze/recycle_guard_windows.go", "cmd/analyze/cleanable.go",
    ]),
]


def git(*args: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    return out.stdout.split("\n") if out.returncode == 0 else []


def pending_paths() -> list[str]:
    base = (git("merge-base", "HEAD", "@{upstream}") or git("merge-base", "HEAD", "origin/windows") or [""])[0]
    paths = set(git("diff", "--name-only", base)) if base else set()
    paths.update(git("ls-files", "--others", "--exclude-standard"))
    return sorted(p for p in paths if p)


def tiers_for(paths: list[str]) -> list[tuple[str, str, list[str]]]:
    hits = []
    for name, gates, patterns in TIERS:
        matched = [p for p in paths if any(fnmatch.fnmatchcase(p.replace("\\", "/"), pattern) for pattern in patterns)]
        if matched:
            hits.append((name, gates, matched))
    return hits


def main() -> int:
    paths = sys.argv[1:] or pending_paths()
    for name, gates, matched in tiers_for(paths):
        more = f" and {len(matched) - 1} more" if len(matched) > 1 else ""
        print(f"risk: {name} ({matched[0]}{more}) needs {gates}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
