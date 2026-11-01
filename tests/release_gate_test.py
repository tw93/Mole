#!/usr/bin/env python3
"""Tests for scripts/release_workflow_gate.py.

Two halves: the gate's decisions against scripted GitHub data, and a lock that
the gate's skip rules match the `paths` filters of the four required workflows
for every tracked file, so neither side can drift alone.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True  # loading the gate must not leave scripts/__pycache__
spec = importlib.util.spec_from_file_location("gate", ROOT / "scripts" / "release_workflow_gate.py")
gate = importlib.util.module_from_spec(spec)
sys.modules["gate"] = gate
spec.loader.exec_module(gate)

WORKFLOW_FILES = {
    "Check": "check.yml",
    "Validation": "test.yml",
    "CodeQL": "codeql.yml",
    "Nix": "nix.yml",
}

GREEN = {"event": "push", "status": "completed", "conclusion": "success"}
RED = {"event": "push", "status": "completed", "conclusion": "failure"}
CANCELLED = {"event": "push", "status": "completed", "conclusion": "cancelled"}


def all_green() -> list[dict]:
    return [{"name": w, **GREEN} for w in gate.REQUIRED]


def secrets_only() -> list[dict]:
    return [{"name": "Secrets", **GREEN}]


class FakeApi:
    """First-parent history newest first: each entry is (sha, files, runs)."""

    def __init__(self, history):
        self.history = history
        self.by_sha = {sha: (files, runs) for sha, files, runs in history}
        shas = [h[0] for h in history]
        self.parent = {sha: (shas[i + 1] if i + 1 < len(shas) else None) for i, sha in enumerate(shas)}

    def runs_for(self, repo, sha):
        return self.by_sha[sha][1]

    def commit_for(self, repo, sha):
        return self.by_sha[sha][0], self.parent[sha]


def evaluate(history):
    return gate.evaluate("tw93/Mole", history[0][0], api=FakeApi(history))


class GateDecisions(unittest.TestCase):
    def test_green_runs_on_the_tag_pass_without_walking(self):
        notes, problems = evaluate([("t", ["mole"], all_green())])
        self.assertEqual(problems, [])

    def test_docs_only_tag_inherits_every_workflow_from_the_code_parent(self):
        notes, problems = evaluate([
            ("t", ["AGENTS.md", ".claude/rules/clean.md"], secrets_only()),
            ("c", ["lib/clean/user.sh"], all_green()),
        ])
        self.assertEqual(problems, [])
        self.assertEqual(len(notes), 4)

    def test_secrets_has_no_filter_so_it_must_run_on_the_tag(self):
        runs = [r for r in all_green() if r["name"] != "Secrets"]
        notes, problems = evaluate([("t", ["AGENTS.md"], runs), ("c", ["mole"], all_green())])
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Secrets", problems[0])

    def test_a_pull_request_run_is_not_evidence(self):
        runs = [dict(r, event="pull_request") for r in all_green()]
        notes, problems = evaluate([("t", ["mole"], runs), ("c", ["mole"], all_green())])
        self.assertEqual(len(problems), 5, problems)

    def test_a_rerun_by_dispatch_recovers_a_red_push_run(self):
        runs = all_green() + [{"name": "Nix", **RED}]
        runs[3] = {"name": "Nix", "event": "workflow_dispatch", "status": "completed", "conclusion": "success"}
        notes, problems = evaluate([("t", ["mole"], runs)])
        self.assertEqual(problems, [])

    def test_source_under_a_docs_folder_is_code(self):
        notes, problems = evaluate([("t", ["docs/tools/fix.sh"], secrets_only()), ("c", ["mole"], all_green())])
        self.assertEqual(len(problems), 4, problems)

    def test_a_merge_without_runs_blocks(self):
        notes, problems = evaluate([("t", ["SYNC.md"], secrets_only()), ("m", None, []), ("c", ["mole"], all_green())])
        self.assertEqual(len(problems), 4, problems)
        self.assertIn("merge", problems[0])

    def test_an_unreadable_run_list_blocks_with_a_next_action(self):
        def broken(*_):
            raise RuntimeError("HTTP 403")
        saved = gate.runs_for
        gate.runs_for = broken
        try:
            import io, contextlib, os
            os.environ.update(GITHUB_REPOSITORY="tw93/Mole", TARGET_SHA="t" * 40, TAG="V0.0.0")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                status = gate.main()
        finally:
            gate.runs_for = saved
        self.assertEqual(status, 1)
        self.assertIn("Next action:", out.getvalue())

    def test_a_red_run_on_an_intermediate_docs_commit_blocks(self):
        # README.md is read by Check, so Check ran there and failed.
        notes, problems = evaluate([
            ("t", ["SYNC.md"], secrets_only()),
            ("r", ["README.md"], [{"name": "Check", **RED}, {"name": "Validation", **GREEN}]),
            ("c", ["mole"], all_green()),
        ])
        self.assertTrue(any(p.startswith("Check on r") for p in problems), problems)

    def test_code_without_a_run_blocks_even_behind_docs(self):
        notes, problems = evaluate([
            ("t", ["SYNC.md"], secrets_only()),
            ("s", ["lib/core/file_ops.sh"], []),  # pushed with [skip ci]
            ("c", ["mole"], all_green()),
        ])
        self.assertEqual(len(problems), 4, problems)
        self.assertIn("lib/core/file_ops.sh", problems[0])

    def test_a_file_the_workflow_reads_without_its_run_blocks(self):
        # Check reads docs/*.md; CodeQL and Nix do not.
        notes, problems = evaluate([
            ("t", ["docs/weekly-audit.md"], [{"name": "Check", **GREEN}, *secrets_only()]),
            ("c", ["mole"], all_green()),
        ])
        self.assertEqual(problems, [])
        notes, problems = evaluate([
            ("t", ["docs/weekly-audit.md"], [{"name": "Validation", **GREEN}, *secrets_only()]),
            ("c", ["mole"], all_green()),
        ])
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Check has no run on t", problems[0])

    def test_a_cancelled_ancestor_run_is_not_evidence(self):
        notes, problems = evaluate([
            ("t", ["SYNC.md"], secrets_only()),
            ("b", ["lib/clean/dev.sh"], [{"name": w, **CANCELLED} for w in gate.REQUIRED]),
            ("c", ["mole"], all_green()),
        ])
        self.assertEqual(len(problems), 4, problems)

    def test_a_non_green_run_on_the_tag_itself_blocks(self):
        runs = all_green()
        runs[1] = {"name": "Validation", **CANCELLED}
        notes, problems = evaluate([("t", ["mole"], runs), ("c", ["mole"], all_green())])
        self.assertEqual(len(problems), 1, problems)

    def test_unreadable_or_truncated_file_lists_block(self):
        notes, problems = evaluate([("t", None, secrets_only()), ("c", ["mole"], all_green())])
        self.assertEqual(len(problems), 4, problems)

    def test_no_run_anywhere_in_the_window_blocks(self):
        notes, problems = evaluate([("t", ["SYNC.md"], secrets_only()), ("d", ["AGENTS.md"], [])])
        self.assertEqual(len(problems), 4, problems)


def glob_to_regex(pattern: str) -> re.Pattern:
    """GitHub Actions path glob: ** spans directories, * and ? stay inside one."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(.*/)?")  # GitHub lets **/ match zero directories
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def triggers(patterns: list[str], path: str) -> bool:
    included = False
    for pattern in patterns:
        negated = pattern.startswith("!")
        if glob_to_regex(pattern.lstrip("!")).match(path):
            included = not negated
    return included


def path_filters(workflow_file: str) -> dict[str, list[str]]:
    """The one-line `paths: [...]` list under each of push and pull_request."""
    text = (ROOT / ".github" / "workflows" / workflow_file).read_text()
    filters = {}
    for event in ("push", "pull_request"):
        block = re.search(rf"^  {event}:\n((?:    .*\n)+)", text, re.M)
        if not block:
            continue
        line = re.search(r"^    paths: \[(.*)\]$", block.group(1), re.M)
        if line is None:
            raise AssertionError(f"{workflow_file} {event} has no one-line paths list")
        filters[event] = [p.strip().strip("'\"") for p in line.group(1).split(",")]
    if not re.search(r"^  workflow_dispatch:", text, re.M):
        raise AssertionError(f"{workflow_file} lost workflow_dispatch, the recovery path for a missing run")
    return filters


class FiltersMatchTheGate(unittest.TestCase):
    def test_glob_emulation_follows_github(self):
        self.assertTrue(triggers(["**/mole"], "mole"))
        self.assertTrue(triggers(["**/mole"], "a/b/mole"))
        self.assertFalse(triggers(["docs/*.md"], "docs/sub/x.md"))
        self.assertTrue(triggers(["**", "!docs/**", "docs/incidents.md"], "docs/incidents.md"))
        self.assertFalse(triggers(["**", "!docs/**", "docs/incidents.md"], "docs/x.md"))
        self.assertTrue(triggers(["**"], ".claude/rules/x.md"))

    def sample_paths(self) -> list[str]:
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True,
                                 text=True, check=True).stdout.split()
        synthetic = ["docs/img/new.png", "docs/new-note.md", "docs/sub/deep.md", "skills/mole/new.md",
                     ".claude/rules/new.md", ".claude/hooks/new.sh", ".claude/skills/x/run.sh",
                     ".github/ISSUE_TEMPLATE/new.yml", ".github/workflows/new.yml", "lib/new/x.sh",
                     "tests/new.bats", "cmd/x/new.go", "README_XX.md", "plugins/mole/x.json",
                     "docs/tools/fix.sh", ".claude/skills/new/SKILL.md", ".claude/skills/new",
                     ".claude/rules/x.py", "skills/mole/SKILL.md", "docs/mole"]
        return sorted(set(tracked + synthetic))

    def test_every_required_workflow_filters_push_and_pull_request(self):
        for workflow, workflow_file in WORKFLOW_FILES.items():
            filters = path_filters(workflow_file)
            self.assertEqual(set(filters), {"push", "pull_request"}, workflow_file)
            self.assertEqual(filters["push"], filters["pull_request"], workflow_file)
            for pattern in filters["push"]:
                # The emulation knows *, ** and a leading !; GitHub also treats
                # + [ ] ? as special, so a pattern using them needs it extended.
                self.assertRegex(pattern, r"^!?[A-Za-z0-9_./*-]+$", workflow_file)
        self.assertEqual(set(WORKFLOW_FILES) | {"Secrets"}, set(gate.REQUIRED))

    def test_secrets_runs_on_every_change(self):
        text = (ROOT / ".github" / "workflows" / "secrets.yml").read_text()
        self.assertNotRegex(text, r"(?m)^\s+paths(-ignore)?:")
        self.assertRegex(text, r"(?m)^name: Secrets$")
        for path in self.sample_paths():
            self.assertFalse(gate.skippable("Secrets", path))

    def test_filters_and_gate_agree_on_every_path(self):
        paths = self.sample_paths()
        for workflow, workflow_file in WORKFLOW_FILES.items():
            patterns = path_filters(workflow_file)["push"]
            mismatched = [p for p in paths if triggers(patterns, p) == gate.skippable(workflow, p)]
            self.assertEqual(mismatched, [], f"{workflow_file} and the gate disagree")

    def test_code_always_triggers_and_plain_docs_never_do(self):
        for workflow, workflow_file in WORKFLOW_FILES.items():
            patterns = path_filters(workflow_file)["push"]
            for path in ("mole", "lib/core/file_ops.sh", "cmd/analyze/main.go", "tests/cli.bats",
                         ".github/workflows/release.yml", "scripts/release_workflow_gate.py"):
                self.assertTrue(triggers(patterns, path), f"{workflow_file} skips {path}")
            for path in ("AGENTS.md", "SYNC.md", ".claude/rules/clean.md", "CONTRIBUTORS.svg"):
                self.assertFalse(triggers(patterns, path), f"{workflow_file} runs for {path}")


if __name__ == "__main__":
    unittest.main(verbosity=1)
