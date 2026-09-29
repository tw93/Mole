#!/usr/bin/env python3
"""Reject Bats assertions that cannot fail.

Bats runs test bodies under `set -e`, but bash 3.2, which is /bin/bash on
macOS and what `env bash` resolves to there, does not trigger errexit for a
failing `[[ ]]`. Only the last statement's status decides the test, so a bare
`[[ ]]` anywhere before it asserts nothing.

A `!`-negated pipeline never triggers errexit in any bash, so a bare `! cmd`
before the last statement asserts nothing either. That rule also covers the
body of a heredoc fed to a shell (`run bash <<'EOF'`), which is judged only by
its own last statement. Function bodies are mocks rather than assertions, and
other heredocs are data, so both are skipped. The bare `[[ ]]` rule still
skips heredoc bodies. A statement runs across line continuations and open
quotes, so a multi-line `bash -c "..."` script is one statement of its test.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TEST_START = re.compile(r"^@test\s.*\{\s*$")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
FUNCTION_START = re.compile(r"^(?:function\s+)?[A-Za-z_][A-Za-z0-9_:.-]*\s*\(\)\s*\{")
SHELL_COMMAND = re.compile(r"(?:^|[\s/=(])(?:ba)?sh(?:\s|$)")
CONTINUATION = ("\\", "|", "&&")


def is_bare_assertion(statement: str) -> bool:
    return statement.startswith("[[") and statement.endswith("]]")


def is_bare_negation(statement: str) -> bool:
    return statement.startswith("! ") and "||" not in statement


def scan_quotes(line: str, open_quotes: tuple[str, ...]) -> tuple[str, ...]:
    """Return the quoting still open after `line`, innermost last.

    Each entry is a quote (`'`, `$'`, `"`) or a command substitution (`$(`),
    which starts a fresh unquoted context inside double quotes.
    """
    stack = list(open_quotes)
    index = 0
    while index < len(line):
        char = line[index]
        top = stack[-1] if stack else ""
        if top == "'":
            if char == "'":
                stack.pop()
        elif top == "$'":
            if char == "\\":
                index += 1
            elif char == "'":
                stack.pop()
        elif top == '"':
            if char == "\\":
                index += 1
            elif char == '"':
                stack.pop()
            elif line.startswith("$(", index):
                stack.append("$(")
                index += 1
        elif char == "\\":
            index += 1
        elif char == "#" and (index == 0 or line[index - 1].isspace()):
            break
        elif line.startswith("$'", index):
            stack.append("$'")
            index += 1
        elif line.startswith("$(", index):
            stack.append("$(")
            index += 1
        elif char in "'\"":
            stack.append(char)
        elif top and char == "(":
            stack.append("(")
        elif top and char == ")":
            stack.pop()
        index += 1
    return tuple(stack)


class Body:
    """Top-level statements of a test body or of a shell heredoc body."""

    def __init__(self, shell_heredoc: bool) -> None:
        self.shell_heredoc = shell_heredoc
        self.statements: list[tuple[int, str]] = []
        self.buffer: list[str] = []
        self.buffer_start = 0
        self.quote: tuple[str, ...] = ()
        self.function_depth = 0
        self.terminator = ""
        self.child: Body | None = None

    def idle(self) -> bool:
        return self.child is None and not self.terminator and not self.buffer and not self.function_depth

    def findings(self) -> list[tuple[int, str]]:
        earlier = self.statements[:-1]
        found = [(line, "negation") for line, text in earlier if is_bare_negation(text)]
        if not self.shell_heredoc:
            found += [(line, "bracket") for line, text in earlier if is_bare_assertion(text)]
        return found

    def feed(self, number: int, raw: str, findings: list[tuple[int, str]]) -> None:
        stripped = raw.strip()
        if self.child is not None:
            if stripped == self.terminator:
                findings.extend(self.child.findings())
                self.child = None
                self.terminator = ""
            else:
                self.child.feed(number, raw, findings)
            return
        if self.terminator:
            if stripped == self.terminator:
                self.terminator = ""
            return
        if not self.buffer and (not stripped or stripped.startswith("#")):
            return

        if not self.buffer:
            self.buffer_start = number
        self.buffer.append(stripped)
        self.quote = scan_quotes(stripped, self.quote)
        heredoc = HEREDOC.search(stripped)
        if heredoc:
            # The heredoc body starts on the next line even when the command
            # that reads it, such as `x="$(bash <<'EOF'`, continues after it.
            self.terminator = heredoc.group(2)
            opener = " ".join(self.buffer)
            opener = opener[: opener.find("<<")]
            if not self.function_depth and SHELL_COMMAND.search(opener) and not opener.startswith("cat "):
                self.child = Body(shell_heredoc=True)
        if self.quote or stripped.endswith(CONTINUATION):
            return

        statement = " ".join(self.buffer)
        self.buffer = []
        if self.function_depth:
            if statement.endswith("{"):
                self.function_depth += 1
            elif statement.startswith("}"):
                self.function_depth -= 1
            return
        if FUNCTION_START.match(statement):
            if not statement.endswith("}"):
                self.function_depth = 1
            return
        self.statements.append((self.buffer_start, statement))


def inspect_file(path: Path) -> list[tuple[int, str]]:
    findings: list[tuple[int, str]] = []
    body: Body | None = None

    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if body is not None and body.terminator:
            body.feed(number, raw, findings)
            continue
        if TEST_START.match(raw):
            if body is not None:
                findings.append((number, "unparsed"))
            body = Body(shell_heredoc=False)
            continue
        if body is None:
            continue
        if raw == "}" and body.idle():
            findings.extend(body.findings())
            body = None
            continue
        body.feed(number, raw, findings)
    return sorted(findings)


MESSAGES = {
    "bracket": "bare [[ ]] before the last statement never fails on bash 3.2; append '|| return 1'",
    "unparsed": "the previous test never closed; an unbalanced quote, heredoc, or function body hid it from this audit",
    "negation": "bare '! cmd' before the last statement never fails; append '|| return 1', or '|| exit 1' in a heredoc script",
}


def main(argv: list[str]) -> int:
    sources = [Path(arg).resolve() for arg in argv] if argv else sorted((PROJECT_ROOT / "tests").glob("*.bats"))
    findings = [(source, line, kind) for source in sources for line, kind in inspect_file(source)]
    if findings:
        for source, line, kind in findings:
            print(f"{source}:{line}: {MESSAGES[kind]}")
        return 1
    print(f"bats-assertion-audit-ok files={len(sources)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
