#!/usr/bin/env python3
"""Release gate: every required workflow passed for the tagged commit.

Check, Validation, CodeQL and Nix carry path filters, so a commit that only
changes files a workflow never reads has no run of it. For such a workflow the
gate walks back to the nearest ancestor the workflow did run on and requires
that run to be green, with every commit on the way changing only files the same
workflow skips. A red, cancelled or still-running run is never evidence, and a
commit that changes a file the workflow reads but has no run (a [skip ci]
message, an outage) blocks the release.

Only push, workflow_dispatch and schedule runs count: a pull_request run tests
a merge ref, not the tagged tree. The walk follows first parents, the history
main actually moved through.

The skip rules below must describe the `paths` filters in the workflow files
exactly; tests/release_gate_test.py compares them over every tracked path.
Secrets has no filter, so it needs a run on the tagged commit itself.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

REQUIRED = ("Check", "Validation", "CodeQL", "Nix", "Secrets")
EVIDENCE_EVENTS = {"push", "workflow_dispatch", "schedule"}

# Source in any directory is code, even under docs/ or .claude/: shfmt,
# treefmt and goimports match these by name across the whole tree.
CODE = re.compile(r"\.(sh|bash|bats|go|nix|py|ps1)$|(^|/)(mole|mo)$")

# Files no workflow needs to see: documentation, images, agent guidance and
# packaging metadata that no check, test or build reads.
NON_CODE = re.compile(
    r"\.md$"
    r"|^docs/"
    r"|^CONTRIBUTORS\.svg$"
    r"|^LICENSE$"
    r"|^llms\.txt$"
    r"|^\.claude/"
    r"|^\.agents/"
    r"|^\.cursor/"
    r"|^\.github/ISSUE_TEMPLATE/"
    r"|^\.github/CODEOWNERS$"
    r"|^skills/"
    r"|^plugins/"
)

# Non-code files a workflow still reads, so a change to them must run it.
READS = {
    # check.sh: diagnostic placement scans README, CONTRIBUTING, docs/*.md and
    # the issue templates; the incident ledger and skill command audits read
    # docs/incidents.md, skills/ and the plugin copy.
    "Check": re.compile(
        r"^README\.md$"
        r"|^CONTRIBUTING\.md$"
        r"|^docs/[^/]*\.md$"
        r"|^\.github/ISSUE_TEMPLATE/"
        r"|^skills/"
        r"|^plugins/"
    ),
    # tests/scripts.bats reads README, CONTRIBUTING and the release-notes skill,
    # tests/format_on_edit_hook.bats the hook, the .agents links and the
    # SKILL.md each link resolves to, and Security Checks the incident ledger.
    "Validation": re.compile(
        r"^README\.md$"
        r"|^CONTRIBUTING\.md$"
        r"|^docs/incidents\.md$"
        r"|^\.claude/hooks/"
        r"|^\.agents/"
        r"|^\.claude/skills/[^/]+$"
        r"|^\.claude/skills/[^/]+/SKILL\.md$"
        r"|^\.claude/skills/release-notes/"
        r"|^skills/mole/SKILL\.md$"
    ),
    "CodeQL": None,
    "Nix": None,
}


def skippable(workflow: str, path: str) -> bool:
    """True when a change to path alone does not trigger workflow."""
    if workflow not in READS or CODE.search(path) or not NON_CODE.search(path):
        return False
    reads = READS[workflow]
    return not (reads and reads.search(path))


def _gh(args: list[str]) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def runs_for(repo: str, sha: str) -> list[dict]:
    out = _gh(["run", "list", "--repo", repo, "--commit", sha, "--limit", "100",
               "--json", "name,event,status,conclusion"])
    return json.loads(out or "[]")


def commit_for(repo: str, sha: str) -> tuple[list[str] | None, str | None]:
    """(changed files, first parent) of one commit.

    Files are None when the list cannot prove a skip: unreadable, empty (a
    merge or an empty commit), or cut at the API's 300-file limit.
    """
    try:
        out = _gh(["api", f"repos/{repo}/commits/{sha}"])
    except RuntimeError:
        return None, None
    data = json.loads(out or "{}")
    rows = data.get("files") or []
    parents = data.get("parents") or []
    parent = parents[0].get("sha") if parents else None
    if not rows or len(rows) >= 300:
        return None, parent
    files = []
    for row in rows:
        filename = row.get("filename")
        previous = row.get("previous_filename")
        if not isinstance(filename, str) or not filename:
            return None, parent
        files.append(filename)
        # Removing code needs its workflow just as adding code does. GitHub
        # supplies the old name separately when a file crosses path filters.
        if row.get("status") == "renamed" and (not isinstance(previous, str) or not previous):
            return None, parent
        if previous:
            if not isinstance(previous, str):
                return None, parent
            files.append(previous)
    return files, parent


def _evidence(runs: list[dict], workflow: str) -> list[dict]:
    return [r for r in runs if r.get("name") == workflow and r.get("event") in EVIDENCE_EVENTS]


def _passed(runs: list[dict], workflow: str) -> bool:
    return any(r.get("status") == "completed" and r.get("conclusion") == "success"
               for r in _evidence(runs, workflow))


def evaluate(repo: str, target: str, api=None, limit: int = 100) -> tuple[list[str], list[str]]:
    """Return (notes, problems) for the tagged commit."""
    api = api or sys.modules[__name__]
    run_cache: dict[str, list[dict]] = {}
    commit_cache: dict[str, tuple[list[str] | None, str | None]] = {}

    def runs(sha: str) -> list[dict]:
        if sha not in run_cache:
            run_cache[sha] = api.runs_for(repo, sha)
        return run_cache[sha]

    def commit(sha: str) -> tuple[list[str] | None, str | None]:
        if sha not in commit_cache:
            commit_cache[sha] = api.commit_for(repo, sha)
        return commit_cache[sha]

    notes: list[str] = []
    problems: list[str] = []
    for workflow in REQUIRED:
        if _passed(runs(target), workflow):
            continue
        sha: str | None = target
        for _ in range(limit):
            if sha is None:
                problems.append(f"{workflow} has no run anywhere in the first-parent history of {target[:12]}")
                break
            if _evidence(runs(sha), workflow):
                if sha == target or not _passed(runs(sha), workflow):
                    problems.append(f"{workflow} on {sha[:12]} did not pass (failed, cancelled or still running)")
                else:
                    notes.append(f"{workflow} skipped {target[:12]} by its path filter; inherits green from {sha[:12]}")
                break
            changed, parent = commit(sha)
            if changed is None:
                problems.append(f"{workflow} has no run on {sha[:12]}, and its changed files cannot show the "
                                "skip was a path filter (a merge, an empty commit or an unreadable list)")
                break
            read = [f for f in changed if not skippable(workflow, f)]
            if read:
                problems.append(f"{workflow} has no run on {sha[:12]}, which changes {read[0]}")
                break
            sha = parent
        else:
            problems.append(f"{workflow} has no run within {limit} first-parent commits of {target[:12]}")
    return notes, problems


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    target = os.environ["TARGET_SHA"]
    tag = os.environ.get("TAG", "<tag>")
    try:
        notes, problems = evaluate(repo, target)
    except RuntimeError as error:
        print(f"::error::Release blocked: the gate could not read workflow runs ({error}).")
        print("Next action: confirm `gh run list` works with this job's token (actions: read), "
              "then re-run this release workflow.")
        return 1
    for note in notes:
        print(note)
    if problems:
        for problem in problems:
            print(f"::error::Release blocked: {problem}.")
        print(f"Next action: run the missing workflow with workflow_dispatch on tag {tag} "
              f"(or on a branch at {target}), wait for it to finish green at "
              f"https://github.com/{repo}/commit/{target}/checks, then re-run this release workflow. "
              "A cancelled, skipped or missing run is not release evidence.")
        return 1
    print(f"Required workflows all passed for {target} (path-filtered skips inherit from the nearest run)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
