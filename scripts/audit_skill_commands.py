#!/usr/bin/env python3
"""Keep the published agent skill in step with both CLIs.

skills/mole tells other people's agents which `mo` commands and flags exist.
A flag that was renamed or never shipped sends those agents into a rejected
command at best and an improvised workaround at worst, so every `mo <command>
--flag` the skill names must still appear in that command's source:
SKILL.md against both CLIs, references/macos.md against this branch, and
references/windows.md against the Windows CLI read from a Git ref (default
origin/windows). Missing that ref skips the Windows side with a notice unless
--require-windows is passed, which CI does after fetching the branch.

Codex installs plugins by copying files and drops symbolic links, so
plugins/mole/skills/mole is a real copy of skills/mole; it must match byte for
byte.

A `version` in a Claude plugin manifest keeps users on their cached copy until
that string changes, and npm refuses to republish a version, so a skill change
must raise the one version plugins/mole/package.json and its Claude manifest
share. The version must differ from the one just before the latest skill commit.
The Check job deepens its shallow clone for this, since a commit whose parent is
out of reach cannot be judged and passes.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CATALOG_DESCRIPTION_LIMIT = 500
INLINE_CODE = re.compile(r"`([^`\n]+)`")
STOP_TOKENS = {"|", "||", "&&", ";", "#", "or", "then"}

MACOS_SOURCES = {
    "analyze": ["cmd/analyze/main.go", "cmd/analyze/json.go"],
    "status": ["cmd/status/main.go"],
    "update": ["lib/manage/update.sh"],
    "remove": ["lib/manage/remove.sh"],
}
WINDOWS_SOURCES = {
    "analyze": ["bin/analyze.ps1", "cmd/analyze/cli.go"],
    "status": ["bin/status.ps1", "cmd/status/main.go"],
}


def mo_commands(text: str) -> list[tuple[int, str, list[str]]]:
    """Return (line, command, flags) for every `mo ...` invocation in Markdown."""
    found: list[tuple[int, str, list[str]]] = []
    in_block = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_block = not in_block
            continue
        snippets = [line.strip()] if in_block else INLINE_CODE.findall(line)
        for snippet in snippets:
            # mo(?![\w-]) keeps "mole" and "mo-foo" from counting as commands.
            for match in re.finditer(r"(?:^|[\s(|])mo(?![\w-])((?:\s+\S+)*)", snippet):
                command = ""
                flags: list[str] = []
                for token in match.group(1).split():
                    if token in STOP_TOKENS or token.startswith("#"):
                        break
                    if token.startswith("--"):
                        flags.append(token.split("=", 1)[0].rstrip(".,)"))
                    elif not command and not flags and re.fullmatch(r"[a-z]+", token):
                        command = token
                found.append((number, command, flags))
    return found


def read_ref_file(ref: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(PROJECT_ROOT), "show", f"{ref}:{path}"],
        capture_output=True,
        text=True,
    )
    return result.stdout if result.returncode == 0 else None


class Platform:
    def __init__(self, name: str, reader, router: str, router_pattern: str, script: str, extra: dict):
        self.name = name
        self.reader = reader
        router_text = reader(router) or ""
        self.commands = {
            word
            for label in re.findall(router_pattern, router_text, re.MULTILINE)
            for word in re.findall(r'"([a-z]+)"', label)
        }
        self.router_text = router_text
        self.script = script
        self.extra = extra

    def source(self, command: str) -> str:
        if not command:
            return self.router_text
        paths = [self.script.format(command)] + self.extra.get(command, [])
        text = "\n".join(self.reader(path) or "" for path in paths)
        # A flag named only in a comment is not a flag the command accepts.
        return "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith(("#", "//"))
        )

    def problems(self, command: str, flags: list[str]) -> list[str]:
        if command and command not in self.commands:
            return [f"`mo {command}` is not a {self.name} command"]
        text = self.source(command)
        return [
            f"`mo {command} {flag}`".replace("  ", " ") + f" is not in the {self.name} source"
            for flag in flags
            if not re.search(re.escape(flag) + r"(?![\w-])", text)
        ]


def macos_platform() -> Platform:
    def reader(path: str) -> str | None:
        file = PROJECT_ROOT / path
        return file.read_text(encoding="utf-8") if file.is_file() else None

    return Platform(
        "macOS",
        reader,
        "mole",
        # Case labels in the dispatcher, plus history, which dispatches early.
        r'(?:^\s*|MOLE_CLI_ARGS\[0\]:-\}" == )("[a-z]+"(?:\s*\|\s*"[a-z]+")*)(?:\)|\s*\]\])',
        "bin/{}.sh",
        MACOS_SOURCES,
    )


def windows_platform(ref: str) -> Platform | None:
    if read_ref_file(ref, "mole.ps1") is None:
        return None
    return Platform(
        "Windows",
        lambda path: read_ref_file(ref, path),
        "mole.ps1",
        r"\$validCommands = @\(([^)]*)\)",
        "bin/{}.ps1",
        WINDOWS_SOURCES,
    )


def copy_problems(source: Path, copy: Path) -> list[str]:
    def files(root: Path) -> dict[str, bytes]:
        return {
            str(path.relative_to(root)): path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_file()
        }

    if not copy.is_dir():
        return [f"{copy}: missing"]
    expected, actual = files(source), files(copy)
    stale = sorted(name for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name))
    if not stale:
        return []
    fix = f"rm -rf {copy} && cp -R {source} {copy}"
    return [f"{copy}/{name}: differs from {source}" for name in stale] + [f"fix with: {fix}"]


def catalog_problems(skill_md: Path) -> list[str]:
    """plugins/mole/index.js joins these two fields; DeepSeek Harness cuts the result at 500 characters."""
    text = skill_md.read_text(encoding="utf-8")
    fields = [re.search(rf'^{key}: "(.*)"$', text, re.M) for key in ("description", "when_to_use")]
    if not all(fields):
        return [f"{skill_md}: description and when_to_use must be single-line quoted strings"]
    length = sum(len(field.group(1)) for field in fields) + len(" Triggers: ")
    if length > CATALOG_DESCRIPTION_LIMIT:
        return [f"{skill_md}: description and when_to_use join to {length} characters, over {CATALOG_DESCRIPTION_LIMIT}"]
    return []


def version_problems(root: Path) -> list[str]:
    package = "plugins/mole/package.json"
    manifest = "plugins/mole/.claude-plugin/plugin.json"
    versions = [json.loads((root / path).read_text(encoding="utf-8")).get("version") for path in (package, manifest)]
    if versions[0] is None or versions[0] != versions[1]:
        return [f"{package} has version {versions[0]} but {manifest} has {versions[1]}; they must match"]

    def git(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)

    skill_commit = git("log", "-1", "--format=%H", "--", "skills/mole").stdout.strip()
    before = git("show", f"{skill_commit}^:{manifest}") if skill_commit else None
    if before is None or before.returncode != 0 or json.loads(before.stdout).get("version") != versions[1]:
        return []
    return [
        f"skills/mole changed in {skill_commit[:8]} without a plugin version bump: "
        f"raise version in {package} and {manifest}, then npm publish from plugins/mole"
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--skill-dir", type=Path, default=PROJECT_ROOT / "skills" / "mole")
    parser.add_argument("--windows-ref", default="origin/windows")
    parser.add_argument("--require-windows", action="store_true")
    parser.add_argument("--plugin-copy", type=Path)
    args = parser.parse_args()
    if args.plugin_copy is None and args.skill_dir == PROJECT_ROOT / "skills" / "mole":
        args.plugin_copy = PROJECT_ROOT / "plugins" / "mole" / "skills" / "mole"

    macos = macos_platform()
    windows = windows_platform(args.windows_ref)
    if windows is None:
        if args.require_windows:
            print(f"Windows CLI ref {args.windows_ref} is not available", file=sys.stderr)
            return 1
        print(f"skill-commands-audit: {args.windows_ref} not available, Windows side skipped")

    targets = {
        "SKILL.md": [macos, windows],
        "references/macos.md": [macos],
        "references/windows.md": [windows],
    }
    failures: list[str] = []
    checked = 0
    for relative, platforms in targets.items():
        path = args.skill_dir / relative
        if not path.is_file():
            failures.append(f"{path}: missing")
            continue
        for line, command, flags in mo_commands(path.read_text(encoding="utf-8")):
            for platform in platforms:
                if platform is None:
                    continue
                checked += 1
                for problem in platform.problems(command, flags):
                    failures.append(f"{path}:{line}: {problem}")

    if args.plugin_copy is not None:
        failures += copy_problems(args.skill_dir, args.plugin_copy)
    if (args.skill_dir / "SKILL.md").is_file():
        failures += catalog_problems(args.skill_dir / "SKILL.md")
    if args.skill_dir == PROJECT_ROOT / "skills" / "mole":
        failures += version_problems(PROJECT_ROOT)

    if failures:
        print("\n".join(failures))
        return 1
    if checked == 0:
        print("skill-commands-audit: no `mo` commands found; the parser is broken", file=sys.stderr)
        return 1
    print(f"skill-commands-audit-ok ({checked} command checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
