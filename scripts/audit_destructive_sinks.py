#!/usr/bin/env python3
"""Require an explicit safety justification on raw recursive deletion commands."""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SAFE_MARKER = re.compile(r"\s#\s*SAFE:\s+\S")
RM_COMMAND = re.compile(r"(?<![A-Za-z0-9_])(?:(?:/usr)?/bin/)?r\\?m(?=\s)")
FIND_DELETE = re.compile(r"(?:^|\s)-delete(?=\s|[;&|)]|$)")
OUTPUT_ONLY_PREFIXES = ("echo ", "echo\t", "printf ", "printf\t", "log_")


def default_sources() -> list[Path]:
    sources = [PROJECT_ROOT / "mole", PROJECT_ROOT / "install.sh"]
    for directory in ("bin", "lib", "scripts"):
        sources.extend((PROJECT_ROOT / directory).rglob("*.sh"))
    return sorted({path.resolve() for path in sources if path.is_file()})


def shell_words(fragment: str) -> list[str]:
    try:
        lexer = shlex.shlex(fragment, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        return list(lexer)
    except ValueError:
        # A malformed or multi-line quoting context is still inspected by the
        # conservative token fallback rather than disappearing from the gate.
        return fragment.split()


def is_output_only_reference(command: str, match_start: int) -> bool:
    prefix = command[:match_start].lstrip()
    if not prefix.startswith(OUTPUT_ONLY_PREFIXES):
        return False
    # A command separator before the sink means the output helper finished and
    # the later rm/find is executable code, not prose inside its argument.
    return re.search(r"(?:;|&&|\|\||\||\$\()", prefix) is None


def has_recursive_force_rm(command: str) -> bool:
    for match in RM_COMMAND.finditer(command):
        if is_output_only_reference(command, match.start()):
            continue
        flags: set[str] = set()
        for token in shell_words(command[match.end() :]):
            if token in {";", "&&", "||", "|"}:
                break
            if token == "--":
                continue
            if token == "--force":
                flags.add("f")
                continue
            if token == "--recursive":
                flags.add("r")
                continue
            if token.startswith("-") and not token.startswith("--"):
                flags.update(token[1:])
                continue
            # Redirections can appear after the target. They do not change the
            # rm option set, but the first ordinary argv ends option parsing.
            if token[:1].isdigit() and ">" in token:
                continue
            # rm option parsing remains active until an explicit `--`; an
            # option-looking token after another operand is still dangerous.
            continue
        if "f" in flags and ("r" in flags or "R" in flags):
            return True
    return False


def has_find_delete(command: str) -> bool:
    return any(
        not is_output_only_reference(command, match.start())
        for match in FIND_DELETE.finditer(command)
    )


def has_unquoted_comment(line: str) -> bool:
    single_quoted = False
    double_quoted = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and not single_quoted:
            escaped = True
            continue
        if char == "'" and not double_quoted:
            single_quoted = not single_quoted
            continue
        if char == '"' and not single_quoted:
            double_quoted = not double_quoted
            continue
        if (
            char == "#"
            and not single_quoted
            and not double_quoted
            and (index == 0 or line[index - 1].isspace())
        ):
            return True
    return False


def logical_blocks(lines: list[str]) -> list[tuple[int, str, list[str]]]:
    blocks: list[tuple[int, str, list[str]]] = []
    start = 1
    physical: list[str] = []
    joined: list[str] = []
    for line_number, line in enumerate(lines, start=1):
        if not physical:
            start = line_number
        physical.append(line)
        stripped = line.rstrip()
        if stripped.endswith("\\") and not has_unquoted_comment(stripped):
            joined.append(stripped[:-1])
            continue
        joined.append(line)
        blocks.append((start, " ".join(joined), list(physical)))
        physical.clear()
        joined.clear()
    if physical:
        blocks.append((start, " ".join(joined), list(physical)))
    return blocks


def inspect_file(path: Path) -> list[tuple[int, str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return [(0, f"could not read source: {exc}")]

    findings: list[tuple[int, str]] = []
    for line_number, command, physical_lines in logical_blocks(lines):
        stripped = command.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        recursive_rm = has_recursive_force_rm(command)
        find_delete = has_find_delete(command)
        if not recursive_rm and not find_delete:
            continue
        if recursive_rm:
            annotated = any(
                RM_COMMAND.search(line) and SAFE_MARKER.search(line)
                for line in physical_lines
            )
        else:
            annotated = any(
                FIND_DELETE.search(line) and SAFE_MARKER.search(line)
                for line in physical_lines
            )
        if annotated:
            continue
        kind = "raw recursive rm" if recursive_rm else "raw find -delete"
        findings.append(
            (line_number, f"{kind} requires '# SAFE: <one-sentence reason>'")
        )
    return findings


def main(argv: list[str]) -> int:
    sources = [Path(arg).resolve() for arg in argv] if argv else default_sources()
    findings: list[tuple[Path, int, str]] = []
    for source in sources:
        if not source.is_file():
            findings.append((source, 0, "source file does not exist"))
            continue
        findings.extend((source, line, message) for line, message in inspect_file(source))

    if findings:
        for source, line, message in findings:
            print(f"{source}:{line}: {message}")
        return 1

    print(f"destructive-sink-audit-ok files={len(sources)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
