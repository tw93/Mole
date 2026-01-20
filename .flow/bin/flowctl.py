#!/usr/bin/env python3
"""
flowctl - CLI for managing .flow/ task tracking system.

All task/epic state lives in JSON files. Markdown specs hold narrative content.
Agents must use flowctl for all writes - never edit .flow/* directly.
"""

import argparse
import json
import os
import re
import subprocess
import shlex
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any, Optional


# --- Constants ---

SCHEMA_VERSION = 2
SUPPORTED_SCHEMA_VERSIONS = [1, 2]
FLOW_DIR = ".flow"
META_FILE = "meta.json"
EPICS_DIR = "epics"
SPECS_DIR = "specs"
TASKS_DIR = "tasks"
MEMORY_DIR = "memory"
CONFIG_FILE = "config.json"

EPIC_STATUS = ["open", "done"]
TASK_STATUS = ["todo", "in_progress", "blocked", "done"]

TASK_SPEC_HEADINGS = [
    "## Description",
    "## Acceptance",
    "## Done summary",
    "## Evidence",
]


# --- Helpers ---


def get_repo_root() -> Path:
    """Find git repo root."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(result.stdout.strip())
    except subprocess.CalledProcessError:
        # Fallback to current directory
        return Path.cwd()


def get_flow_dir() -> Path:
    """Get .flow/ directory path."""
    return get_repo_root() / FLOW_DIR


def ensure_flow_exists() -> bool:
    """Check if .flow/ exists."""
    return get_flow_dir().exists()


def get_default_config() -> dict:
    """Return default config structure."""
    return {"memory": {"enabled": False}}


def load_flow_config() -> dict:
    """Load .flow/config.json, returning defaults if missing."""
    config_path = get_flow_dir() / CONFIG_FILE
    defaults = get_default_config()
    if not config_path.exists():
        return defaults
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else defaults
    except (json.JSONDecodeError, Exception):
        return defaults


def get_config(key: str, default=None):
    """Get nested config value like 'memory.enabled'."""
    config = load_flow_config()
    for part in key.split("."):
        if not isinstance(config, dict):
            return default
        config = config.get(part, {})
        if config == {}:
            return default
    return config if config != {} else default


def set_config(key: str, value) -> dict:
    """Set nested config value and return updated config."""
    config_path = get_flow_dir() / CONFIG_FILE
    if config_path.exists():
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, Exception):
            config = get_default_config()
    else:
        config = get_default_config()

    # Navigate/create nested path
    parts = key.split(".")
    current = config
    for part in parts[:-1]:
        if part not in current or not isinstance(current[part], dict):
            current[part] = {}
        current = current[part]

    # Set the value (handle type conversion for common cases)
    if isinstance(value, str):
        if value.lower() == "true":
            value = True
        elif value.lower() == "false":
            value = False
        elif value.isdigit():
            value = int(value)

    current[parts[-1]] = value
    atomic_write_json(config_path, config)
    return config


def json_output(data: dict, success: bool = True) -> None:
    """Output JSON response."""
    result = {"success": success, **data}
    print(json.dumps(result, indent=2, default=str))


def error_exit(message: str, code: int = 1, use_json: bool = True) -> None:
    """Output error and exit."""
    if use_json:
        json_output({"error": message}, success=False)
    else:
        print(f"Error: {message}", file=sys.stderr)
    sys.exit(code)


def now_iso() -> str:
    """Current timestamp in ISO format."""
    return datetime.utcnow().isoformat() + "Z"


def require_rp_cli() -> str:
    """Ensure rp-cli is available."""
    rp = shutil.which("rp-cli")
    if not rp:
        error_exit("rp-cli not found in PATH", use_json=False, code=2)
    return rp


def run_rp_cli(
    args: list[str], timeout: Optional[int] = None
) -> subprocess.CompletedProcess:
    """Run rp-cli with safe error handling and timeout.

    Args:
        args: Command arguments to pass to rp-cli
        timeout: Max seconds to wait. Default from FLOW_RP_TIMEOUT env or 1200s (20min).
    """
    if timeout is None:
        timeout = int(os.environ.get("FLOW_RP_TIMEOUT", "1200"))
    rp = require_rp_cli()
    cmd = [rp] + args
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        error_exit(f"rp-cli timed out after {timeout}s", use_json=False, code=3)
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or e.stdout or str(e)).strip()
        error_exit(f"rp-cli failed: {msg}", use_json=False, code=2)


def normalize_repo_root(path: str) -> list[str]:
    """Normalize repo root for window matching."""
    root = os.path.realpath(path)
    roots = [root]
    if root.startswith("/private/tmp/"):
        roots.append("/tmp/" + root[len("/private/tmp/") :])
    elif root.startswith("/tmp/"):
        roots.append("/private/tmp/" + root[len("/tmp/") :])
    return list(dict.fromkeys(roots))


def parse_windows(raw: str) -> list[dict[str, Any]]:
    """Parse rp-cli windows JSON."""
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return data
        if (
            isinstance(data, dict)
            and "windows" in data
            and isinstance(data["windows"], list)
        ):
            return data["windows"]
    except json.JSONDecodeError as e:
        if "single-window mode" in raw:
            return [{"windowID": 1, "rootFolderPaths": []}]
        error_exit(f"windows JSON parse failed: {e}", use_json=False, code=2)
    error_exit("windows JSON has unexpected shape", use_json=False, code=2)


def extract_window_id(win: dict[str, Any]) -> Optional[int]:
    for key in ("windowID", "windowId", "id"):
        if key in win:
            try:
                return int(win[key])
            except Exception:
                return None
    return None


def extract_root_paths(win: dict[str, Any]) -> list[str]:
    for key in ("rootFolderPaths", "rootFolders", "rootFolderPath"):
        if key in win:
            val = win[key]
            if isinstance(val, list):
                return [str(v) for v in val]
            if isinstance(val, str):
                return [val]
    return []


def parse_builder_tab(output: str) -> str:
    match = re.search(r"Tab:\s*([A-Za-z0-9-]+)", output)
    if not match:
        error_exit("builder output missing Tab id", use_json=False, code=2)
    return match.group(1)


def parse_chat_id(output: str) -> Optional[str]:
    match = re.search(r"Chat\s*:\s*`([^`]+)`", output)
    if match:
        return match.group(1)
    match = re.search(r"\"chat_id\"\s*:\s*\"([^\"]+)\"", output)
    if match:
        return match.group(1)
    return None


def build_chat_payload(
    message: str,
    mode: str,
    new_chat: bool = False,
    chat_name: Optional[str] = None,
    selected_paths: Optional[list[str]] = None,
) -> str:
    payload: dict[str, Any] = {
        "message": message,
        "mode": mode,
    }
    if new_chat:
        payload["new_chat"] = True
    if chat_name:
        payload["chat_name"] = chat_name
    if selected_paths:
        payload["selected_paths"] = selected_paths
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def is_supported_schema(version: Any) -> bool:
    """Check schema version compatibility."""
    try:
        return int(version) in SUPPORTED_SCHEMA_VERSIONS
    except Exception:
        return False


def atomic_write(path: Path, content: str) -> None:
    """Write file atomically via temp + rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def atomic_write_json(path: Path, data: dict) -> None:
    """Write JSON file atomically with sorted keys."""
    content = json.dumps(data, indent=2, sort_keys=True) + "\n"
    atomic_write(path, content)


def load_json(path: Path) -> dict:
    """Load JSON file."""
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_json_or_exit(path: Path, what: str, use_json: bool = True) -> dict:
    """Load JSON file with safe error handling."""
    if not path.exists():
        error_exit(f"{what} missing: {path}", use_json=use_json)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        error_exit(f"{what} invalid JSON: {path} ({e})", use_json=use_json)
    except Exception as e:
        error_exit(f"{what} unreadable: {path} ({e})", use_json=use_json)


def read_text_or_exit(path: Path, what: str, use_json: bool = True) -> str:
    """Read text file with safe error handling."""
    if not path.exists():
        error_exit(f"{what} missing: {path}", use_json=use_json)
    try:
        return path.read_text(encoding="utf-8")
    except Exception as e:
        error_exit(f"{what} unreadable: {path} ({e})", use_json=use_json)


def parse_id(id_str: str) -> tuple[Optional[int], Optional[int]]:
    """Parse ID into (epic_num, task_num). Returns (epic, None) for epic IDs."""
    match = re.match(r"^fn-(\d+)(?:\.(\d+))?$", id_str)
    if not match:
        return None, None
    epic = int(match.group(1))
    task = int(match.group(2)) if match.group(2) else None
    return epic, task


def normalize_epic(epic_data: dict) -> dict:
    """Apply defaults for optional epic fields."""
    if "plan_review_status" not in epic_data:
        epic_data["plan_review_status"] = "unknown"
    if "plan_reviewed_at" not in epic_data:
        epic_data["plan_reviewed_at"] = None
    if "branch_name" not in epic_data:
        epic_data["branch_name"] = None
    if "depends_on_epics" not in epic_data:
        epic_data["depends_on_epics"] = []
    return epic_data


def normalize_task(task_data: dict) -> dict:
    """Apply defaults for optional task fields."""
    if "priority" not in task_data:
        task_data["priority"] = None
    return task_data


def task_priority(task_data: dict) -> int:
    """Priority for sorting (None -> 999)."""
    try:
        if task_data.get("priority") is None:
            return 999
        return int(task_data.get("priority"))
    except Exception:
        return 999


def is_epic_id(id_str: str) -> bool:
    """Check if ID is an epic ID (fn-N)."""
    epic, task = parse_id(id_str)
    return epic is not None and task is None


def is_task_id(id_str: str) -> bool:
    """Check if ID is a task ID (fn-N.M)."""
    epic, task = parse_id(id_str)
    return epic is not None and task is not None


def epic_id_from_task(task_id: str) -> str:
    """Extract epic ID from task ID. Raises ValueError if invalid."""
    epic, task = parse_id(task_id)
    if epic is None or task is None:
        raise ValueError(f"Invalid task ID: {task_id}")
    return f"fn-{epic}"


# --- Context Hints (for codex reviews) ---


def get_changed_files(base_branch: str) -> list[str]:
    """Get files changed between base branch and HEAD."""
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", base_branch],
            capture_output=True,
            text=True,
            check=True,
            cwd=get_repo_root(),
        )
        return [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
    except subprocess.CalledProcessError:
        return []


def extract_symbols_from_file(file_path: Path) -> list[str]:
    """Extract exported/defined symbols from a file (functions, classes, consts).

    Returns empty list on any error - never crashes.
    """
    try:
        if not file_path.exists():
            return []
        content = file_path.read_text(encoding="utf-8", errors="ignore")
        if not content:
            return []

        symbols = []
        ext = file_path.suffix.lower()

        # Python: def/class definitions
        if ext == ".py":
            for match in re.finditer(r"^(?:def|class)\s+(\w+)", content, re.MULTILINE):
                symbols.append(match.group(1))
            # Also catch exported __all__
            all_match = re.search(r"__all__\s*=\s*\[([^\]]+)\]", content)
            if all_match:
                for s in re.findall(r"['\"](\w+)['\"]", all_match.group(1)):
                    symbols.append(s)

        # JS/TS: export function/class/const
        elif ext in (".js", ".ts", ".jsx", ".tsx", ".mjs"):
            for match in re.finditer(
                r"export\s+(?:default\s+)?(?:function|class|const|let|var)\s+(\w+)",
                content,
            ):
                symbols.append(match.group(1))
            # Named exports: export { foo, bar }
            for match in re.finditer(r"export\s*\{([^}]+)\}", content):
                for s in re.findall(r"(\w+)", match.group(1)):
                    symbols.append(s)

        # Go: func/type definitions
        elif ext == ".go":
            for match in re.finditer(r"^func\s+(\w+)", content, re.MULTILINE):
                symbols.append(match.group(1))
            for match in re.finditer(r"^type\s+(\w+)", content, re.MULTILINE):
                symbols.append(match.group(1))

        # Rust: pub fn/struct/enum/trait, also private fn for references
        elif ext == ".rs":
            for match in re.finditer(r"^(?:pub\s+)?fn\s+(\w+)", content, re.MULTILINE):
                symbols.append(match.group(1))
            for match in re.finditer(
                r"^(?:pub\s+)?(?:struct|enum|trait|type)\s+(\w+)",
                content,
                re.MULTILINE,
            ):
                symbols.append(match.group(1))
            # impl blocks: impl Name or impl Trait for Name
            for match in re.finditer(
                r"^impl(?:<[^>]+>)?\s+(\w+)", content, re.MULTILINE
            ):
                symbols.append(match.group(1))

        # C/C++: function definitions, structs, typedefs, macros
        elif ext in (".c", ".h", ".cpp", ".hpp", ".cc", ".cxx"):
            # Function definitions: type name( at line start (simplified)
            for match in re.finditer(
                r"^[a-zA-Z_][\w\s\*]+\s+(\w+)\s*\([^;]*$", content, re.MULTILINE
            ):
                symbols.append(match.group(1))
            # struct/enum/union definitions
            for match in re.finditer(
                r"^(?:typedef\s+)?(?:struct|enum|union)\s+(\w+)",
                content,
                re.MULTILINE,
            ):
                symbols.append(match.group(1))
            # #define macros
            for match in re.finditer(r"^#define\s+(\w+)", content, re.MULTILINE):
                symbols.append(match.group(1))

        # Java: class/interface/method definitions
        elif ext == ".java":
            for match in re.finditer(
                r"^(?:public|private|protected)?\s*(?:static\s+)?"
                r"(?:class|interface|enum)\s+(\w+)",
                content,
                re.MULTILINE,
            ):
                symbols.append(match.group(1))
            # Method definitions
            for match in re.finditer(
                r"^\s*(?:public|private|protected)\s+(?:static\s+)?"
                r"[\w<>\[\]]+\s+(\w+)\s*\(",
                content,
                re.MULTILINE,
            ):
                symbols.append(match.group(1))

        return list(set(symbols))
    except Exception:
        # Never crash on parse errors - just return empty
        return []


def find_references(
    symbol: str, exclude_files: list[str], max_results: int = 3
) -> list[tuple[str, int]]:
    """Find files referencing a symbol. Returns [(path, line_number), ...]."""
    repo_root = get_repo_root()
    try:
        result = subprocess.run(
            [
                "git",
                "grep",
                "-n",
                "-w",
                symbol,
                "--",
                # Python
                "*.py",
                # JavaScript/TypeScript
                "*.js",
                "*.ts",
                "*.tsx",
                "*.jsx",
                "*.mjs",
                # Go
                "*.go",
                # Rust
                "*.rs",
                # C/C++
                "*.c",
                "*.h",
                "*.cpp",
                "*.hpp",
                "*.cc",
                "*.cxx",
                # Java
                "*.java",
            ],
            capture_output=True,
            text=True,
            cwd=repo_root,
        )
        refs = []
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            # Format: file:line:content
            parts = line.split(":", 2)
            if len(parts) >= 2:
                file_path = parts[0]
                # Skip excluded files (the changed files themselves)
                if file_path in exclude_files:
                    continue
                try:
                    line_num = int(parts[1])
                    refs.append((file_path, line_num))
                except ValueError:
                    continue
            if len(refs) >= max_results:
                break
        return refs
    except subprocess.CalledProcessError:
        return []


def gather_context_hints(base_branch: str, max_hints: int = 15) -> str:
    """Gather context hints for code review.

    Returns formatted hints like:
    Consider these related files:
    - src/auth.ts:15 - references validateToken
    - src/types.ts:42 - references User
    """
    changed_files = get_changed_files(base_branch)
    if not changed_files:
        return ""

    # Limit to avoid processing too many files
    if len(changed_files) > 50:
        changed_files = changed_files[:50]

    repo_root = get_repo_root()
    hints = []
    seen_files = set(changed_files)

    # Extract symbols from changed files and find references
    for changed_file in changed_files:
        file_path = repo_root / changed_file
        symbols = extract_symbols_from_file(file_path)

        # Limit symbols per file
        for symbol in symbols[:10]:
            refs = find_references(symbol, changed_files, max_results=2)
            for ref_path, ref_line in refs:
                if ref_path not in seen_files:
                    hints.append(f"- {ref_path}:{ref_line} - references {symbol}")
                    seen_files.add(ref_path)
                    if len(hints) >= max_hints:
                        break
            if len(hints) >= max_hints:
                break
        if len(hints) >= max_hints:
            break

    if not hints:
        return ""

    return "Consider these related files:\n" + "\n".join(hints)


# --- Codex Backend Helpers ---


def require_codex() -> str:
    """Ensure codex CLI is available. Returns path to codex."""
    codex = shutil.which("codex")
    if not codex:
        error_exit("codex not found in PATH", use_json=False, code=2)
    return codex


def get_codex_version() -> Optional[str]:
    """Get codex version, or None if not available."""
    codex = shutil.which("codex")
    if not codex:
        return None
    try:
        result = subprocess.run(
            [codex, "--version"],
            capture_output=True,
            text=True,
            check=True,
        )
        # Parse version from output like "codex 0.1.2" or "0.1.2"
        output = result.stdout.strip()
        match = re.search(r"(\d+\.\d+\.\d+)", output)
        return match.group(1) if match else output
    except subprocess.CalledProcessError:
        return None


def run_codex_exec(
    prompt: str,
    session_id: Optional[str] = None,
    sandbox: str = "read-only",
    model: Optional[str] = None,
) -> tuple[str, Optional[str]]:
    """Run codex exec and return (output, thread_id).

    If session_id provided, tries to resume. Falls back to new session if resume fails.
    Model: FLOW_CODEX_MODEL env > parameter > default (gpt-5.2 + high reasoning).
    """
    codex = require_codex()
    # Model priority: env > parameter > default (gpt-5.2 + high reasoning = GPT 5.2 High)
    effective_model = os.environ.get("FLOW_CODEX_MODEL") or model or "gpt-5.2"

    if session_id:
        # Try resume first (model already set in original session)
        cmd = [codex, "exec", "resume", session_id, prompt]
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=600,
            )
            output = result.stdout
            # For resumed sessions, thread_id stays the same
            return output, session_id
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            # Resume failed - fall through to new session
            pass

    # New session with model + high reasoning effort
    cmd = [
        codex,
        "exec",
        "--model",
        effective_model,
        "-c",
        'model_reasoning_effort="high"',
        "--sandbox",
        sandbox,
        "--json",
        prompt,
    ]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
            timeout=600,
        )
        output = result.stdout
        thread_id = parse_codex_thread_id(output)
        return output, thread_id
    except subprocess.TimeoutExpired:
        error_exit("codex exec timed out (600s)", use_json=False, code=2)
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or e.stdout or str(e)).strip()
        error_exit(f"codex exec failed: {msg}", use_json=False, code=2)


def parse_codex_thread_id(output: str) -> Optional[str]:
    """Extract thread_id from codex --json output.

    Looks for: {"type":"thread.started","thread_id":"019baa19-..."}
    """
    for line in output.split("\n"):
        if not line.strip():
            continue
        try:
            data = json.loads(line)
            if data.get("type") == "thread.started" and "thread_id" in data:
                return data["thread_id"]
        except json.JSONDecodeError:
            continue
    return None


def parse_codex_verdict(output: str) -> Optional[str]:
    """Extract verdict from codex output.

    Looks for <verdict>SHIP</verdict> or <verdict>NEEDS_WORK</verdict>
    """
    match = re.search(r"<verdict>(SHIP|NEEDS_WORK|MAJOR_RETHINK)</verdict>", output)
    return match.group(1) if match else None


def build_review_prompt(
    review_type: str,
    spec_content: str,
    context_hints: str,
    diff_summary: str = "",
) -> str:
    """Build XML-structured review prompt for codex.

    review_type: 'impl' or 'plan'

    Uses same Carmack-level criteria as RepoPrompt workflow to ensure parity.
    """
    # Context gathering preamble - same for both review types
    context_preamble = """## Context Gathering (do this first)

Before reviewing, explore the codebase to understand the full impact:

**Cross-boundary checks:**
- Frontend change? Check the backend API it calls
- Backend change? Check frontend consumers and other callers
- Schema/type change? Find all usages across the codebase
- Config change? Check what reads it

**Related context:**
- Similar features elsewhere (patterns to follow or break)
- Tests covering this area (are they sufficient?)
- Shared utilities/hooks this code should use
- Error handling patterns in adjacent code

The context_hints below are a starting point. Read additional files as needed -
a thorough review requires understanding the system, not just the diff.

"""

    if review_type == "impl":
        instruction = (
            context_preamble
            + """Conduct a John Carmack-level review of this implementation.

## Review Criteria

1. **Correctness** - Matches spec? Logic errors?
2. **Simplicity** - Simplest solution? Over-engineering?
3. **DRY** - Duplicated logic? Existing patterns?
4. **Architecture** - Data flow? Clear boundaries?
5. **Edge Cases** - Failure modes? Race conditions?
6. **Tests** - Adequate coverage? Testing behavior?
7. **Security** - Injection? Auth gaps?

## Output Format

For each issue found:
- **Severity**: Critical / Major / Minor / Nitpick
- **File:Line**: Exact location
- **Problem**: What's wrong
- **Suggestion**: How to fix

Be critical. Find real issues.

**REQUIRED**: End your response with exactly one verdict tag:
<verdict>SHIP</verdict> - Ready to merge
<verdict>NEEDS_WORK</verdict> - Has issues that must be fixed
<verdict>MAJOR_RETHINK</verdict> - Fundamental approach problems

Do NOT skip this tag. The automation depends on it."""
        )
    else:  # plan
        instruction = (
            context_preamble
            + """Conduct a John Carmack-level review of this plan.

## Review Criteria

1. **Completeness** - All requirements covered? Missing edge cases?
2. **Feasibility** - Technically sound? Dependencies clear?
3. **Clarity** - Specs unambiguous? Acceptance criteria testable?
4. **Architecture** - Right abstractions? Clean boundaries?
5. **Risks** - Blockers identified? Security gaps? Mitigation?
6. **Scope** - Right-sized? Over/under-engineering?
7. **Testability** - How will we verify this works?

## Output Format

For each issue found:
- **Severity**: Critical / Major / Minor / Nitpick
- **Location**: Which task or section
- **Problem**: What's wrong
- **Suggestion**: How to fix

Be critical. Find real issues.

**REQUIRED**: End your response with exactly one verdict tag:
<verdict>SHIP</verdict> - Plan is solid, ready to implement
<verdict>NEEDS_WORK</verdict> - Plan has gaps that need addressing
<verdict>MAJOR_RETHINK</verdict> - Fundamental approach problems

Do NOT skip this tag. The automation depends on it."""
        )

    parts = []

    if context_hints:
        parts.append(f"<context_hints>\n{context_hints}\n</context_hints>")

    if diff_summary:
        parts.append(f"<diff_summary>\n{diff_summary}\n</diff_summary>")

    parts.append(f"<spec>\n{spec_content}\n</spec>")
    parts.append(f"<review_instructions>\n{instruction}\n</review_instructions>")

    return "\n\n".join(parts)


def get_actor() -> str:
    """Determine current actor for soft-claim semantics.

    Priority:
    1. FLOW_ACTOR env var
    2. git config user.email
    3. git config user.name
    4. $USER env var
    5. "unknown"
    """
    # 1. FLOW_ACTOR env var
    if actor := os.environ.get("FLOW_ACTOR"):
        return actor.strip()

    # 2. git config user.email (preferred)
    try:
        result = subprocess.run(
            ["git", "config", "user.email"], capture_output=True, text=True, check=True
        )
        if email := result.stdout.strip():
            return email
    except subprocess.CalledProcessError:
        pass

    # 3. git config user.name
    try:
        result = subprocess.run(
            ["git", "config", "user.name"], capture_output=True, text=True, check=True
        )
        if name := result.stdout.strip():
            return name
    except subprocess.CalledProcessError:
        pass

    # 4. $USER env var
    if user := os.environ.get("USER"):
        return user

    # 5. fallback
    return "unknown"


def scan_max_epic_id(flow_dir: Path) -> int:
    """Scan .flow/epics/ to find max epic number. Returns 0 if none exist."""
    epics_dir = flow_dir / EPICS_DIR
    if not epics_dir.exists():
        return 0

    max_n = 0
    for epic_file in epics_dir.glob("fn-*.json"):
        match = re.match(r"^fn-(\d+)\.json$", epic_file.name)
        if match:
            n = int(match.group(1))
            max_n = max(max_n, n)
    return max_n


def scan_max_task_id(flow_dir: Path, epic_id: str) -> int:
    """Scan .flow/tasks/ to find max task number for an epic. Returns 0 if none exist."""
    tasks_dir = flow_dir / TASKS_DIR
    if not tasks_dir.exists():
        return 0

    max_m = 0
    for task_file in tasks_dir.glob(f"{epic_id}.*.json"):
        match = re.match(rf"^{re.escape(epic_id)}\.(\d+)\.json$", task_file.name)
        if match:
            m = int(match.group(1))
            max_m = max(max_m, m)
    return max_m


def require_keys(obj: dict, keys: list[str], what: str, use_json: bool = True) -> None:
    """Validate dict has required keys. Exits on missing keys."""
    missing = [k for k in keys if k not in obj]
    if missing:
        error_exit(
            f"{what} missing required keys: {', '.join(missing)}", use_json=use_json
        )


# --- Spec File Operations ---


def create_epic_spec(id_str: str, title: str) -> str:
    """Create epic spec markdown content."""
    return f"""# {id_str} {title}

## Overview
TBD

## Scope
TBD

## Approach
TBD

## Quick commands
<!-- Required: at least one smoke command for the repo -->
- `# e.g., npm test, bun test, make test`

## Acceptance
- [ ] TBD

## References
- TBD
"""


def create_task_spec(id_str: str, title: str, acceptance: Optional[str] = None) -> str:
    """Create task spec markdown content."""
    acceptance_content = acceptance if acceptance else "- [ ] TBD"
    return f"""# {id_str} {title}

## Description
TBD

## Acceptance
{acceptance_content}

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
"""


def patch_task_section(content: str, section: str, new_content: str) -> str:
    """Patch a specific section in task spec. Preserves other sections.

    Raises ValueError on invalid content (duplicate/missing headings).
    """
    # Check for duplicate headings first (defensive)
    pattern = rf"^{re.escape(section)}\s*$"
    matches = len(re.findall(pattern, content, flags=re.MULTILINE))
    if matches > 1:
        raise ValueError(
            f"Cannot patch: duplicate heading '{section}' found ({matches} times)"
        )

    lines = content.split("\n")
    result = []
    in_target_section = False
    section_found = False

    for i, line in enumerate(lines):
        if line.startswith("## "):
            if line.strip() == section:
                in_target_section = True
                section_found = True
                result.append(line)
                # Add new content
                result.append(new_content.rstrip())
                continue
            else:
                in_target_section = False

        if not in_target_section:
            result.append(line)

    if not section_found:
        raise ValueError(f"Section '{section}' not found in task spec")

    return "\n".join(result)


def get_task_section(content: str, section: str) -> str:
    """Get content under a task section heading."""
    lines = content.split("\n")
    in_target = False
    collected = []
    for line in lines:
        if line.startswith("## "):
            if line.strip() == section:
                in_target = True
                continue
            if in_target:
                break
        if in_target:
            collected.append(line)
    return "\n".join(collected).strip()


def validate_task_spec_headings(content: str) -> list[str]:
    """Validate task spec has required headings exactly once. Returns errors."""
    errors = []
    for heading in TASK_SPEC_HEADINGS:
        # Use regex anchored to line start to avoid matching inside code blocks
        pattern = rf"^{re.escape(heading)}\s*$"
        count = len(re.findall(pattern, content, flags=re.MULTILINE))
        if count == 0:
            errors.append(f"Missing required heading: {heading}")
        elif count > 1:
            errors.append(f"Duplicate heading: {heading} (found {count} times)")
    return errors


# --- Commands ---


def cmd_init(args: argparse.Namespace) -> None:
    """Initialize .flow/ directory structure."""
    flow_dir = get_flow_dir()

    if flow_dir.exists():
        if args.json:
            json_output({"message": ".flow/ already exists", "path": str(flow_dir)})
        else:
            print(f".flow/ already exists at {flow_dir}")
        return

    # Create directory structure
    (flow_dir / EPICS_DIR).mkdir(parents=True)
    (flow_dir / SPECS_DIR).mkdir(parents=True)
    (flow_dir / TASKS_DIR).mkdir(parents=True)
    (flow_dir / MEMORY_DIR).mkdir(parents=True)

    # Create meta.json
    meta = {"schema_version": SCHEMA_VERSION, "next_epic": 1}
    atomic_write_json(flow_dir / META_FILE, meta)

    # Create config.json with defaults
    atomic_write_json(flow_dir / CONFIG_FILE, get_default_config())

    if args.json:
        json_output({"message": ".flow/ initialized", "path": str(flow_dir)})
    else:
        print(f".flow/ initialized at {flow_dir}")


def cmd_detect(args: argparse.Namespace) -> None:
    """Check if .flow/ exists and is valid."""
    flow_dir = get_flow_dir()
    exists = flow_dir.exists()
    valid = False
    issues = []

    if exists:
        meta_path = flow_dir / META_FILE
        if not meta_path.exists():
            issues.append("meta.json missing")
        else:
            try:
                meta = load_json(meta_path)
                if not is_supported_schema(meta.get("schema_version")):
                    issues.append(
                        f"schema_version unsupported (expected {', '.join(map(str, SUPPORTED_SCHEMA_VERSIONS))})"
                    )
            except Exception as e:
                issues.append(f"meta.json parse error: {e}")

        # Check required subdirectories
        for subdir in [EPICS_DIR, SPECS_DIR, TASKS_DIR, MEMORY_DIR]:
            if not (flow_dir / subdir).exists():
                issues.append(f"{subdir}/ missing")

        valid = len(issues) == 0

    if args.json:
        result = {
            "exists": exists,
            "valid": valid,
            "path": str(flow_dir) if exists else None,
        }
        if issues:
            result["issues"] = issues
        json_output(result)
    else:
        if exists and valid:
            print(f".flow/ exists and is valid at {flow_dir}")
        elif exists:
            print(f".flow/ exists but has issues at {flow_dir}:")
            for issue in issues:
                print(f"  - {issue}")
        else:
            print(".flow/ does not exist")


def cmd_config_get(args: argparse.Namespace) -> None:
    """Get a config value."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    value = get_config(args.key)
    if args.json:
        json_output({"key": args.key, "value": value})
    else:
        if value is None:
            print(f"{args.key}: (not set)")
        elif isinstance(value, bool):
            print(f"{args.key}: {'true' if value else 'false'}")
        else:
            print(f"{args.key}: {value}")


def cmd_config_set(args: argparse.Namespace) -> None:
    """Set a config value."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    set_config(args.key, args.value)
    new_value = get_config(args.key)

    if args.json:
        json_output({"key": args.key, "value": new_value, "message": f"{args.key} set"})
    else:
        print(f"{args.key} set to {new_value}")


MEMORY_TEMPLATES = {
    "pitfalls.md": """# Pitfalls

Lessons learned from NEEDS_WORK feedback. Things models tend to miss.

<!-- Entries added automatically by hooks or manually via `flowctl memory add` -->
""",
    "conventions.md": """# Conventions

Project patterns discovered during work. Not in CLAUDE.md but important.

<!-- Entries added manually via `flowctl memory add` -->
""",
    "decisions.md": """# Decisions

Architectural choices with rationale. Why we chose X over Y.

<!-- Entries added manually via `flowctl memory add` -->
""",
}


def cmd_memory_init(args: argparse.Namespace) -> None:
    """Initialize memory directory with templates."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    # Check if memory is enabled
    if not get_config("memory.enabled", False):
        if args.json:
            json_output(
                {
                    "error": "Memory not enabled. Run: flowctl config set memory.enabled true"
                },
                success=False,
            )
        else:
            print("Error: Memory not enabled.")
            print("Enable with: flowctl config set memory.enabled true")
        sys.exit(1)

    flow_dir = get_flow_dir()
    memory_dir = flow_dir / MEMORY_DIR

    # Create memory dir if missing
    memory_dir.mkdir(parents=True, exist_ok=True)

    created = []
    for filename, content in MEMORY_TEMPLATES.items():
        filepath = memory_dir / filename
        if not filepath.exists():
            atomic_write(filepath, content)
            created.append(filename)

    if args.json:
        json_output(
            {
                "path": str(memory_dir),
                "created": created,
                "message": "Memory initialized"
                if created
                else "Memory already initialized",
            }
        )
    else:
        if created:
            print(f"Memory initialized at {memory_dir}")
            for f in created:
                print(f"  Created: {f}")
        else:
            print(f"Memory already initialized at {memory_dir}")


def require_memory_enabled(args) -> Path:
    """Check memory is enabled and return memory dir. Exits on error."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not get_config("memory.enabled", False):
        if args.json:
            json_output(
                {
                    "error": "Memory not enabled. Run: flowctl config set memory.enabled true"
                },
                success=False,
            )
        else:
            print("Error: Memory not enabled.")
            print("Enable with: flowctl config set memory.enabled true")
        sys.exit(1)

    memory_dir = get_flow_dir() / MEMORY_DIR
    required_files = ["pitfalls.md", "conventions.md", "decisions.md"]
    missing = [f for f in required_files if not (memory_dir / f).exists()]
    if missing:
        if args.json:
            json_output(
                {"error": "Memory not initialized. Run: flowctl memory init"},
                success=False,
            )
        else:
            print("Error: Memory not initialized.")
            print("Run: flowctl memory init")
        sys.exit(1)

    return memory_dir


def cmd_memory_add(args: argparse.Namespace) -> None:
    """Add a memory entry manually."""
    memory_dir = require_memory_enabled(args)

    # Map type to file
    type_map = {
        "pitfall": "pitfalls.md",
        "pitfalls": "pitfalls.md",
        "convention": "conventions.md",
        "conventions": "conventions.md",
        "decision": "decisions.md",
        "decisions": "decisions.md",
    }

    filename = type_map.get(args.type.lower())
    if not filename:
        error_exit(
            f"Invalid type '{args.type}'. Use: pitfall, convention, or decision",
            use_json=args.json,
        )

    filepath = memory_dir / filename
    if not filepath.exists():
        error_exit(
            f"Memory file {filename} not found. Run: flowctl memory init",
            use_json=args.json,
        )

    # Format entry
    from datetime import datetime

    today = datetime.utcnow().strftime("%Y-%m-%d")

    # Normalize type name
    type_name = args.type.lower().rstrip("s")  # pitfalls -> pitfall

    entry = f"""
## {today} manual [{type_name}]
{args.content}
"""

    # Append to file
    with filepath.open("a", encoding="utf-8") as f:
        f.write(entry)

    if args.json:
        json_output(
            {"type": type_name, "file": filename, "message": f"Added {type_name} entry"}
        )
    else:
        print(f"Added {type_name} entry to {filename}")


def cmd_memory_read(args: argparse.Namespace) -> None:
    """Read memory entries."""
    memory_dir = require_memory_enabled(args)

    # Determine which files to read
    if args.type:
        type_map = {
            "pitfall": "pitfalls.md",
            "pitfalls": "pitfalls.md",
            "convention": "conventions.md",
            "conventions": "conventions.md",
            "decision": "decisions.md",
            "decisions": "decisions.md",
        }
        filename = type_map.get(args.type.lower())
        if not filename:
            error_exit(
                f"Invalid type '{args.type}'. Use: pitfalls, conventions, or decisions",
                use_json=args.json,
            )
        files = [filename]
    else:
        files = ["pitfalls.md", "conventions.md", "decisions.md"]

    content = {}
    for filename in files:
        filepath = memory_dir / filename
        if filepath.exists():
            content[filename] = filepath.read_text(encoding="utf-8")
        else:
            content[filename] = ""

    if args.json:
        json_output({"files": content})
    else:
        for filename, text in content.items():
            if text.strip():
                print(f"=== {filename} ===")
                print(text)
                print()


def cmd_memory_list(args: argparse.Namespace) -> None:
    """List memory entry counts."""
    memory_dir = require_memory_enabled(args)

    counts = {}
    for filename in ["pitfalls.md", "conventions.md", "decisions.md"]:
        filepath = memory_dir / filename
        if filepath.exists():
            text = filepath.read_text(encoding="utf-8")
            # Count ## entries (each entry starts with ## date)
            entries = len(re.findall(r"^## \d{4}-\d{2}-\d{2}", text, re.MULTILINE))
            counts[filename] = entries
        else:
            counts[filename] = 0

    if args.json:
        json_output({"counts": counts, "total": sum(counts.values())})
    else:
        total = 0
        for filename, count in counts.items():
            print(f"  {filename}: {count} entries")
            total += count
        print(f"  Total: {total} entries")


def cmd_memory_search(args: argparse.Namespace) -> None:
    """Search memory entries."""
    memory_dir = require_memory_enabled(args)

    pattern = args.pattern

    # Validate regex pattern
    try:
        re.compile(pattern)
    except re.error as e:
        error_exit(f"Invalid regex pattern: {e}", use_json=args.json)

    matches = []

    for filename in ["pitfalls.md", "conventions.md", "decisions.md"]:
        filepath = memory_dir / filename
        if not filepath.exists():
            continue

        text = filepath.read_text(encoding="utf-8")
        # Split into entries
        entries = re.split(r"(?=^## \d{4}-\d{2}-\d{2})", text, flags=re.MULTILINE)

        for entry in entries:
            if not entry.strip():
                continue
            if re.search(pattern, entry, re.IGNORECASE):
                matches.append({"file": filename, "entry": entry.strip()})

    if args.json:
        json_output({"pattern": pattern, "matches": matches, "count": len(matches)})
    else:
        if matches:
            for m in matches:
                print(f"=== {m['file']} ===")
                print(m["entry"])
                print()
            print(f"Found {len(matches)} matches")
        else:
            print(f"No matches for '{pattern}'")


def cmd_epic_create(args: argparse.Namespace) -> None:
    """Create a new epic."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    flow_dir = get_flow_dir()
    meta_path = flow_dir / META_FILE
    load_json_or_exit(meta_path, "meta.json", use_json=args.json)

    # MU-1: Scan-based allocation for merge safety
    # Scan existing epics to determine next ID (don't rely on counter)
    max_epic = scan_max_epic_id(flow_dir)
    epic_num = max_epic + 1
    epic_id = f"fn-{epic_num}"

    # Double-check no collision (shouldn't happen with scan-based allocation)
    epic_json_path = flow_dir / EPICS_DIR / f"{epic_id}.json"
    epic_spec_path = flow_dir / SPECS_DIR / f"{epic_id}.md"
    if epic_json_path.exists() or epic_spec_path.exists():
        error_exit(
            f"Refusing to overwrite existing epic {epic_id}. "
            f"This shouldn't happen - check for orphaned files.",
            use_json=args.json,
        )

    # Create epic JSON
    epic_data = {
        "id": epic_id,
        "title": args.title,
        "status": "open",
        "plan_review_status": "unknown",
        "plan_reviewed_at": None,
        "branch_name": args.branch if args.branch else epic_id,
        "depends_on_epics": [],
        "spec_path": f"{FLOW_DIR}/{SPECS_DIR}/{epic_id}.md",
        "next_task": 1,
        "created_at": now_iso(),
        "updated_at": now_iso(),
    }
    atomic_write_json(flow_dir / EPICS_DIR / f"{epic_id}.json", epic_data)

    # Create epic spec
    spec_content = create_epic_spec(epic_id, args.title)
    atomic_write(flow_dir / SPECS_DIR / f"{epic_id}.md", spec_content)

    # NOTE: We no longer update meta["next_epic"] since scan-based allocation
    # is the source of truth. This reduces merge conflicts.

    if args.json:
        json_output(
            {
                "id": epic_id,
                "title": args.title,
                "spec_path": epic_data["spec_path"],
                "message": f"Epic {epic_id} created",
            }
        )
    else:
        print(f"Epic {epic_id} created: {args.title}")


def cmd_task_create(args: argparse.Namespace) -> None:
    """Create a new task under an epic."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_epic_id(args.epic):
        error_exit(
            f"Invalid epic ID: {args.epic}. Expected format: fn-N", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epic_path = flow_dir / EPICS_DIR / f"{args.epic}.json"

    load_json_or_exit(epic_path, f"Epic {args.epic}", use_json=args.json)

    # MU-1: Scan-based allocation for merge safety
    # Scan existing tasks to determine next ID (don't rely on counter)
    max_task = scan_max_task_id(flow_dir, args.epic)
    task_num = max_task + 1
    task_id = f"{args.epic}.{task_num}"

    # Double-check no collision (shouldn't happen with scan-based allocation)
    task_json_path = flow_dir / TASKS_DIR / f"{task_id}.json"
    task_spec_path = flow_dir / TASKS_DIR / f"{task_id}.md"
    if task_json_path.exists() or task_spec_path.exists():
        error_exit(
            f"Refusing to overwrite existing task {task_id}. "
            f"This shouldn't happen - check for orphaned files.",
            use_json=args.json,
        )

    # Parse dependencies
    deps = []
    if args.deps:
        deps = [d.strip() for d in args.deps.split(",")]
        # Validate deps are valid task IDs within same epic
        for dep in deps:
            if not is_task_id(dep):
                error_exit(
                    f"Invalid dependency ID: {dep}. Expected format: fn-N.M",
                    use_json=args.json,
                )
            if epic_id_from_task(dep) != args.epic:
                error_exit(
                    f"Dependency {dep} must be within the same epic ({args.epic})",
                    use_json=args.json,
                )

    # Read acceptance from file if provided
    acceptance = None
    if args.acceptance_file:
        acceptance = read_text_or_exit(
            Path(args.acceptance_file), "Acceptance file", use_json=args.json
        )

    # Create task JSON (MU-2: includes soft-claim fields)
    task_data = {
        "id": task_id,
        "epic": args.epic,
        "title": args.title,
        "status": "todo",
        "priority": args.priority,
        "depends_on": deps,
        "assignee": None,
        "claimed_at": None,
        "claim_note": "",
        "spec_path": f"{FLOW_DIR}/{TASKS_DIR}/{task_id}.md",
        "created_at": now_iso(),
        "updated_at": now_iso(),
    }
    atomic_write_json(flow_dir / TASKS_DIR / f"{task_id}.json", task_data)

    # Create task spec
    spec_content = create_task_spec(task_id, args.title, acceptance)
    atomic_write(flow_dir / TASKS_DIR / f"{task_id}.md", spec_content)

    # NOTE: We no longer update epic["next_task"] since scan-based allocation
    # is the source of truth. This reduces merge conflicts.

    if args.json:
        json_output(
            {
                "id": task_id,
                "epic": args.epic,
                "title": args.title,
                "depends_on": deps,
                "spec_path": task_data["spec_path"],
                "message": f"Task {task_id} created",
            }
        )
    else:
        print(f"Task {task_id} created: {args.title}")


def cmd_dep_add(args: argparse.Namespace) -> None:
    """Add a dependency to a task."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_task_id(args.task):
        error_exit(
            f"Invalid task ID: {args.task}. Expected format: fn-N.M", use_json=args.json
        )

    if not is_task_id(args.depends_on):
        error_exit(
            f"Invalid dependency ID: {args.depends_on}. Expected format: fn-N.M",
            use_json=args.json,
        )

    # Validate same epic
    task_epic = epic_id_from_task(args.task)
    dep_epic = epic_id_from_task(args.depends_on)
    if task_epic != dep_epic:
        error_exit(
            f"Dependencies must be within the same epic. Task {args.task} is in {task_epic}, dependency {args.depends_on} is in {dep_epic}",
            use_json=args.json,
        )

    flow_dir = get_flow_dir()
    task_path = flow_dir / TASKS_DIR / f"{args.task}.json"

    task_data = load_json_or_exit(task_path, f"Task {args.task}", use_json=args.json)

    if args.depends_on not in task_data["depends_on"]:
        task_data["depends_on"].append(args.depends_on)
        task_data["updated_at"] = now_iso()
        atomic_write_json(task_path, task_data)

    if args.json:
        json_output(
            {
                "task": args.task,
                "depends_on": task_data["depends_on"],
                "message": f"Dependency {args.depends_on} added to {args.task}",
            }
        )
    else:
        print(f"Dependency {args.depends_on} added to {args.task}")


def cmd_show(args: argparse.Namespace) -> None:
    """Show epic or task details."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    flow_dir = get_flow_dir()

    if is_epic_id(args.id):
        epic_path = flow_dir / EPICS_DIR / f"{args.id}.json"
        epic_data = normalize_epic(
            load_json_or_exit(epic_path, f"Epic {args.id}", use_json=args.json)
        )

        # Get tasks for this epic
        tasks = []
        tasks_dir = flow_dir / TASKS_DIR
        if tasks_dir.exists():
            for task_file in sorted(tasks_dir.glob(f"{args.id}.*.json")):
                task_data = normalize_task(
                    load_json_or_exit(
                        task_file, f"Task {task_file.stem}", use_json=args.json
                    )
                )
                if "id" not in task_data:
                    continue  # Skip artifact files (GH-21)
                tasks.append(
                    {
                        "id": task_data["id"],
                        "title": task_data["title"],
                        "status": task_data["status"],
                        "priority": task_data.get("priority"),
                        "depends_on": task_data["depends_on"],
                    }
                )

        # Sort tasks by numeric suffix (safe via parse_id)
        def task_sort_key(t):
            _, task_num = parse_id(t["id"])
            return task_num if task_num is not None else 0

        tasks.sort(key=task_sort_key)

        result = {**epic_data, "tasks": tasks}

        if args.json:
            json_output(result)
        else:
            print(f"Epic: {epic_data['id']}")
            print(f"Title: {epic_data['title']}")
            print(f"Status: {epic_data['status']}")
            print(f"Spec: {epic_data['spec_path']}")
            print(f"\nTasks ({len(tasks)}):")
            for t in tasks:
                deps = (
                    f" (deps: {', '.join(t['depends_on'])})" if t["depends_on"] else ""
                )
                print(f"  [{t['status']}] {t['id']}: {t['title']}{deps}")

    elif is_task_id(args.id):
        task_path = flow_dir / TASKS_DIR / f"{args.id}.json"
        task_data = normalize_task(
            load_json_or_exit(task_path, f"Task {args.id}", use_json=args.json)
        )

        if args.json:
            json_output(task_data)
        else:
            print(f"Task: {task_data['id']}")
            print(f"Epic: {task_data['epic']}")
            print(f"Title: {task_data['title']}")
            print(f"Status: {task_data['status']}")
            print(f"Depends on: {', '.join(task_data['depends_on']) or 'none'}")
            print(f"Spec: {task_data['spec_path']}")

    else:
        error_exit(
            f"Invalid ID: {args.id}. Expected format: fn-N (epic) or fn-N.M (task)",
            use_json=args.json,
        )


def cmd_epics(args: argparse.Namespace) -> None:
    """List all epics."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epics_dir = flow_dir / EPICS_DIR

    epics = []
    if epics_dir.exists():
        for epic_file in sorted(epics_dir.glob("fn-*.json")):
            epic_data = normalize_epic(
                load_json_or_exit(
                    epic_file, f"Epic {epic_file.stem}", use_json=args.json
                )
            )
            # Count tasks
            tasks_dir = flow_dir / TASKS_DIR
            task_count = 0
            done_count = 0
            if tasks_dir.exists():
                for task_file in tasks_dir.glob(f"{epic_data['id']}.*.json"):
                    task_data = load_json_or_exit(
                        task_file, f"Task {task_file.stem}", use_json=args.json
                    )
                    task_count += 1
                    if task_data.get("status") == "done":
                        done_count += 1

            epics.append(
                {
                    "id": epic_data["id"],
                    "title": epic_data["title"],
                    "status": epic_data["status"],
                    "tasks": task_count,
                    "done": done_count,
                }
            )

    # Sort by epic number
    def epic_sort_key(e):
        epic_num, _ = parse_id(e["id"])
        return epic_num if epic_num is not None else 0

    epics.sort(key=epic_sort_key)

    if args.json:
        json_output({"success": True, "epics": epics, "count": len(epics)})
    else:
        if not epics:
            print("No epics found.")
        else:
            print(f"Epics ({len(epics)}):\n")
            for e in epics:
                progress = f"{e['done']}/{e['tasks']}" if e["tasks"] > 0 else "0/0"
                print(
                    f"  [{e['status']}] {e['id']}: {e['title']} ({progress} tasks done)"
                )


def cmd_tasks(args: argparse.Namespace) -> None:
    """List tasks."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    flow_dir = get_flow_dir()
    tasks_dir = flow_dir / TASKS_DIR

    tasks = []
    if tasks_dir.exists():
        pattern = f"{args.epic}.*.json" if args.epic else "fn-*.json"
        for task_file in sorted(tasks_dir.glob(pattern)):
            # Skip if it's not a task file (must have . in the name before .json)
            stem = task_file.stem
            if "." not in stem:
                continue
            task_data = normalize_task(
                load_json_or_exit(task_file, f"Task {stem}", use_json=args.json)
            )
            if "id" not in task_data:
                continue  # Skip artifact files (GH-21)
            # Filter by status if requested
            if args.status and task_data["status"] != args.status:
                continue
            tasks.append(
                {
                    "id": task_data["id"],
                    "epic": task_data["epic"],
                    "title": task_data["title"],
                    "status": task_data["status"],
                    "priority": task_data.get("priority"),
                    "depends_on": task_data["depends_on"],
                }
            )

    # Sort tasks by epic number then task number
    def task_sort_key(t):
        epic_num, task_num = parse_id(t["id"])
        return (
            epic_num if epic_num is not None else 0,
            task_num if task_num is not None else 0,
        )

    tasks.sort(key=task_sort_key)

    if args.json:
        json_output({"success": True, "tasks": tasks, "count": len(tasks)})
    else:
        if not tasks:
            scope = f" for epic {args.epic}" if args.epic else ""
            status_filter = f" with status '{args.status}'" if args.status else ""
            print(f"No tasks found{scope}{status_filter}.")
        else:
            scope = f" for {args.epic}" if args.epic else ""
            print(f"Tasks{scope} ({len(tasks)}):\n")
            for t in tasks:
                deps = (
                    f" (deps: {', '.join(t['depends_on'])})" if t["depends_on"] else ""
                )
                print(f"  [{t['status']}] {t['id']}: {t['title']}{deps}")


def cmd_list(args: argparse.Namespace) -> None:
    """List all epics and their tasks."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epics_dir = flow_dir / EPICS_DIR
    tasks_dir = flow_dir / TASKS_DIR

    # Load all epics
    epics = []
    if epics_dir.exists():
        for epic_file in sorted(epics_dir.glob("fn-*.json")):
            epic_data = normalize_epic(
                load_json_or_exit(
                    epic_file, f"Epic {epic_file.stem}", use_json=args.json
                )
            )
            epics.append(epic_data)

    # Sort epics by number
    def epic_sort_key(e):
        epic_num, _ = parse_id(e["id"])
        return epic_num if epic_num is not None else 0

    epics.sort(key=epic_sort_key)

    # Load all tasks grouped by epic
    tasks_by_epic = {}
    all_tasks = []
    if tasks_dir.exists():
        for task_file in sorted(tasks_dir.glob("fn-*.json")):
            stem = task_file.stem
            if "." not in stem:
                continue
            task_data = normalize_task(
                load_json_or_exit(task_file, f"Task {stem}", use_json=args.json)
            )
            if "id" not in task_data:
                continue  # Skip artifact files (GH-21)
            epic_id = task_data["epic"]
            if epic_id not in tasks_by_epic:
                tasks_by_epic[epic_id] = []
            tasks_by_epic[epic_id].append(task_data)
            all_tasks.append(
                {
                    "id": task_data["id"],
                    "epic": task_data["epic"],
                    "title": task_data["title"],
                    "status": task_data["status"],
                    "priority": task_data.get("priority"),
                    "depends_on": task_data["depends_on"],
                }
            )

    # Sort tasks within each epic
    for epic_id in tasks_by_epic:
        tasks_by_epic[epic_id].sort(key=lambda t: parse_id(t["id"])[1] or 0)

    if args.json:
        epics_out = []
        for e in epics:
            task_list = tasks_by_epic.get(e["id"], [])
            done_count = sum(1 for t in task_list if t["status"] == "done")
            epics_out.append(
                {
                    "id": e["id"],
                    "title": e["title"],
                    "status": e["status"],
                    "tasks": len(task_list),
                    "done": done_count,
                }
            )
        json_output(
            {
                "success": True,
                "epics": epics_out,
                "tasks": all_tasks,
                "epic_count": len(epics),
                "task_count": len(all_tasks),
            }
        )
    else:
        if not epics:
            print("No epics or tasks found.")
            return

        total_tasks = len(all_tasks)
        total_done = sum(1 for t in all_tasks if t["status"] == "done")
        print(
            f"Flow Status: {len(epics)} epics, {total_tasks} tasks ({total_done} done)\n"
        )

        for e in epics:
            task_list = tasks_by_epic.get(e["id"], [])
            done_count = sum(1 for t in task_list if t["status"] == "done")
            progress = f"{done_count}/{len(task_list)}" if task_list else "0/0"
            print(f"[{e['status']}] {e['id']}: {e['title']} ({progress} done)")

            for t in task_list:
                deps = (
                    f" (deps: {', '.join(t['depends_on'])})" if t["depends_on"] else ""
                )
                print(f"    [{t['status']}] {t['id']}: {t['title']}{deps}")
            print()


def cmd_cat(args: argparse.Namespace) -> None:
    """Print markdown spec for epic or task."""
    if not ensure_flow_exists():
        error_exit(".flow/ does not exist. Run 'flowctl init' first.", use_json=False)

    flow_dir = get_flow_dir()

    if is_epic_id(args.id):
        spec_path = flow_dir / SPECS_DIR / f"{args.id}.md"
    elif is_task_id(args.id):
        spec_path = flow_dir / TASKS_DIR / f"{args.id}.md"
    else:
        error_exit(
            f"Invalid ID: {args.id}. Expected format: fn-N (epic) or fn-N.M (task)",
            use_json=False,
        )
        return

    content = read_text_or_exit(spec_path, f"Spec {args.id}", use_json=False)
    print(content)


def cmd_epic_set_plan(args: argparse.Namespace) -> None:
    """Set/overwrite entire epic spec from file."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_epic_id(args.id):
        error_exit(
            f"Invalid epic ID: {args.id}. Expected format: fn-N", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epic_path = flow_dir / EPICS_DIR / f"{args.id}.json"

    # Verify epic exists (will be loaded later for timestamp update)
    if not epic_path.exists():
        error_exit(f"Epic {args.id} not found", use_json=args.json)

    # Read content from file
    content = read_text_or_exit(Path(args.file), "Input file", use_json=args.json)

    # Write spec
    spec_path = flow_dir / SPECS_DIR / f"{args.id}.md"
    atomic_write(spec_path, content)

    # Update epic timestamp
    epic_data = load_json_or_exit(epic_path, f"Epic {args.id}", use_json=args.json)
    epic_data["updated_at"] = now_iso()
    atomic_write_json(epic_path, epic_data)

    if args.json:
        json_output(
            {
                "id": args.id,
                "spec_path": str(spec_path),
                "message": f"Epic {args.id} spec updated",
            }
        )
    else:
        print(f"Epic {args.id} spec updated")


def cmd_epic_set_plan_review_status(args: argparse.Namespace) -> None:
    """Set plan review status for an epic."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_epic_id(args.id):
        error_exit(
            f"Invalid epic ID: {args.id}. Expected format: fn-N", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epic_path = flow_dir / EPICS_DIR / f"{args.id}.json"

    if not epic_path.exists():
        error_exit(f"Epic {args.id} not found", use_json=args.json)

    epic_data = normalize_epic(
        load_json_or_exit(epic_path, f"Epic {args.id}", use_json=args.json)
    )
    epic_data["plan_review_status"] = args.status
    epic_data["plan_reviewed_at"] = now_iso()
    epic_data["updated_at"] = now_iso()
    atomic_write_json(epic_path, epic_data)

    if args.json:
        json_output(
            {
                "id": args.id,
                "plan_review_status": epic_data["plan_review_status"],
                "plan_reviewed_at": epic_data["plan_reviewed_at"],
                "message": f"Epic {args.id} plan review status set to {args.status}",
            }
        )
    else:
        print(f"Epic {args.id} plan review status set to {args.status}")


def cmd_epic_set_branch(args: argparse.Namespace) -> None:
    """Set epic branch name."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_epic_id(args.id):
        error_exit(
            f"Invalid epic ID: {args.id}. Expected format: fn-N", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epic_path = flow_dir / EPICS_DIR / f"{args.id}.json"

    if not epic_path.exists():
        error_exit(f"Epic {args.id} not found", use_json=args.json)

    epic_data = normalize_epic(
        load_json_or_exit(epic_path, f"Epic {args.id}", use_json=args.json)
    )
    epic_data["branch_name"] = args.branch
    epic_data["updated_at"] = now_iso()
    atomic_write_json(epic_path, epic_data)

    if args.json:
        json_output(
            {
                "id": args.id,
                "branch_name": epic_data["branch_name"],
                "message": f"Epic {args.id} branch_name set to {args.branch}",
            }
        )
    else:
        print(f"Epic {args.id} branch_name set to {args.branch}")


def cmd_task_set_description(args: argparse.Namespace) -> None:
    """Set task description section."""
    _task_set_section(args.id, "## Description", args.file, args.json)


def cmd_task_set_acceptance(args: argparse.Namespace) -> None:
    """Set task acceptance section."""
    _task_set_section(args.id, "## Acceptance", args.file, args.json)


def _task_set_section(
    task_id: str, section: str, file_path: str, use_json: bool
) -> None:
    """Helper to set a task spec section."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=use_json
        )

    if not is_task_id(task_id):
        error_exit(
            f"Invalid task ID: {task_id}. Expected format: fn-N.M", use_json=use_json
        )

    flow_dir = get_flow_dir()
    task_json_path = flow_dir / TASKS_DIR / f"{task_id}.json"
    task_spec_path = flow_dir / TASKS_DIR / f"{task_id}.md"

    # Verify task exists
    if not task_json_path.exists():
        error_exit(f"Task {task_id} not found", use_json=use_json)

    # Read new content
    new_content = read_text_or_exit(Path(file_path), "Input file", use_json=use_json)

    # Load task JSON first (fail early before any writes)
    task_data = load_json_or_exit(task_json_path, f"Task {task_id}", use_json=use_json)

    # Read current spec
    current_spec = read_text_or_exit(
        task_spec_path, f"Task {task_id} spec", use_json=use_json
    )

    # Patch section
    try:
        updated_spec = patch_task_section(current_spec, section, new_content)
    except ValueError as e:
        error_exit(str(e), use_json=use_json)

    # Write spec then JSON (both validated above)
    atomic_write(task_spec_path, updated_spec)
    task_data["updated_at"] = now_iso()
    atomic_write_json(task_json_path, task_data)

    if use_json:
        json_output(
            {
                "id": task_id,
                "section": section,
                "message": f"Task {task_id} {section} updated",
            }
        )
    else:
        print(f"Task {task_id} {section} updated")


def cmd_ready(args: argparse.Namespace) -> None:
    """List ready tasks for an epic."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_epic_id(args.epic):
        error_exit(
            f"Invalid epic ID: {args.epic}. Expected format: fn-N", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epic_path = flow_dir / EPICS_DIR / f"{args.epic}.json"

    if not epic_path.exists():
        error_exit(f"Epic {args.epic} not found", use_json=args.json)

    # MU-2: Get current actor for display (marks your tasks)
    current_actor = get_actor()

    # Get all tasks for epic
    tasks_dir = flow_dir / TASKS_DIR
    if not tasks_dir.exists():
        error_exit(
            f"{TASKS_DIR}/ missing. Run 'flowctl init' or fix repo state.",
            use_json=args.json,
        )
    tasks = {}
    for task_file in tasks_dir.glob(f"{args.epic}.*.json"):
        task_data = normalize_task(
            load_json_or_exit(task_file, f"Task {task_file.stem}", use_json=args.json)
        )
        if "id" not in task_data:
            continue  # Skip artifact files (GH-21)
        tasks[task_data["id"]] = task_data

    # Find ready tasks (status=todo, all deps done)
    ready = []
    in_progress = []
    blocked = []

    for task_id, task in tasks.items():
        # MU-2: Track in_progress tasks separately
        if task["status"] == "in_progress":
            in_progress.append(task)
            continue

        if task["status"] == "done":
            continue

        if task["status"] == "blocked":
            blocked.append({"task": task, "blocked_by": ["status=blocked"]})
            continue

        # Check all deps are done
        deps_done = True
        blocking_deps = []
        for dep in task["depends_on"]:
            if dep not in tasks:
                deps_done = False
                blocking_deps.append(dep)
            elif tasks[dep]["status"] != "done":
                deps_done = False
                blocking_deps.append(dep)

        if deps_done:
            ready.append(task)
        else:
            blocked.append({"task": task, "blocked_by": blocking_deps})

    # Sort by numeric suffix
    def sort_key(t):
        _, task_num = parse_id(t["id"])
        return (
            task_priority(t),
            task_num if task_num is not None else 0,
            t.get("title", ""),
        )

    ready.sort(key=sort_key)
    in_progress.sort(key=sort_key)
    blocked.sort(key=lambda x: sort_key(x["task"]))

    if args.json:
        json_output(
            {
                "epic": args.epic,
                "actor": current_actor,
                "ready": [
                    {"id": t["id"], "title": t["title"], "depends_on": t["depends_on"]}
                    for t in ready
                ],
                "in_progress": [
                    {"id": t["id"], "title": t["title"], "assignee": t.get("assignee")}
                    for t in in_progress
                ],
                "blocked": [
                    {
                        "id": b["task"]["id"],
                        "title": b["task"]["title"],
                        "blocked_by": b["blocked_by"],
                    }
                    for b in blocked
                ],
            }
        )
    else:
        print(f"Ready tasks for {args.epic} (actor: {current_actor}):")
        if ready:
            for t in ready:
                print(f"  {t['id']}: {t['title']}")
        else:
            print("  (none)")
        if in_progress:
            print("\nIn progress:")
            for t in in_progress:
                assignee = t.get("assignee") or "unknown"
                marker = " (you)" if assignee == current_actor else ""
                print(f"  {t['id']}: {t['title']} [{assignee}]{marker}")
        if blocked:
            print("\nBlocked:")
            for b in blocked:
                print(
                    f"  {b['task']['id']}: {b['task']['title']} (by: {', '.join(b['blocked_by'])})"
                )


def cmd_next(args: argparse.Namespace) -> None:
    """Select the next plan/work unit."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    flow_dir = get_flow_dir()

    # Resolve epics list
    epic_ids: list[str] = []
    if args.epics_file:
        data = load_json_or_exit(
            Path(args.epics_file), "Epics file", use_json=args.json
        )
        epics_val = data.get("epics")
        if not isinstance(epics_val, list):
            error_exit(
                "Epics file must be JSON with key 'epics' as a list", use_json=args.json
            )
        for e in epics_val:
            if not isinstance(e, str) or not is_epic_id(e):
                error_exit(f"Invalid epic ID in epics file: {e}", use_json=args.json)
            epic_ids.append(e)
    else:
        epics_dir = flow_dir / EPICS_DIR
        if epics_dir.exists():
            for epic_file in sorted(epics_dir.glob("fn-*.json")):
                match = re.match(r"^fn-(\d+)\.json$", epic_file.name)
                if match:
                    epic_ids.append(f"fn-{match.group(1)}")
        epic_ids.sort(key=lambda e: parse_id(e)[0] or 0)

    current_actor = get_actor()

    def sort_key(t: dict) -> tuple[int, int]:
        _, task_num = parse_id(t["id"])
        return (task_priority(t), task_num if task_num is not None else 0)

    blocked_epics: dict[str, list[str]] = {}

    for epic_id in epic_ids:
        epic_path = flow_dir / EPICS_DIR / f"{epic_id}.json"
        if not epic_path.exists():
            if args.epics_file:
                error_exit(f"Epic {epic_id} not found", use_json=args.json)
            continue

        epic_data = normalize_epic(
            load_json_or_exit(epic_path, f"Epic {epic_id}", use_json=args.json)
        )
        if epic_data.get("status") == "done":
            continue

        # Skip epics blocked by epic-level dependencies
        blocked_by: list[str] = []
        for dep in epic_data.get("depends_on_epics", []) or []:
            if dep == epic_id:
                continue
            dep_path = flow_dir / EPICS_DIR / f"{dep}.json"
            if not dep_path.exists():
                blocked_by.append(dep)
                continue
            dep_data = normalize_epic(
                load_json_or_exit(dep_path, f"Epic {dep}", use_json=args.json)
            )
            if dep_data.get("status") != "done":
                blocked_by.append(dep)
        if blocked_by:
            blocked_epics[epic_id] = blocked_by
            continue

        if args.require_plan_review and epic_data.get("plan_review_status") != "ship":
            if args.json:
                json_output(
                    {
                        "status": "plan",
                        "epic": epic_id,
                        "task": None,
                        "reason": "needs_plan_review",
                    }
                )
            else:
                print(f"plan {epic_id} needs_plan_review")
            return

        tasks_dir = flow_dir / TASKS_DIR
        if not tasks_dir.exists():
            error_exit(
                f"{TASKS_DIR}/ missing. Run 'flowctl init' or fix repo state.",
                use_json=args.json,
            )

        tasks: dict[str, dict] = {}
        for task_file in tasks_dir.glob(f"{epic_id}.*.json"):
            task_data = normalize_task(
                load_json_or_exit(
                    task_file, f"Task {task_file.stem}", use_json=args.json
                )
            )
            if "id" not in task_data:
                continue  # Skip artifact files (GH-21)
            tasks[task_data["id"]] = task_data

        # Resume in_progress tasks owned by current actor
        in_progress = [
            t
            for t in tasks.values()
            if t.get("status") == "in_progress" and t.get("assignee") == current_actor
        ]
        in_progress.sort(key=sort_key)
        if in_progress:
            task_id = in_progress[0]["id"]
            if args.json:
                json_output(
                    {
                        "status": "work",
                        "epic": epic_id,
                        "task": task_id,
                        "reason": "resume_in_progress",
                    }
                )
            else:
                print(f"work {task_id} resume_in_progress")
            return

        # Ready tasks by deps + priority
        ready: list[dict] = []
        for task in tasks.values():
            if task.get("status") != "todo":
                continue
            if task.get("status") == "blocked":
                continue
            deps_done = True
            for dep in task.get("depends_on", []):
                dep_task = tasks.get(dep)
                if not dep_task or dep_task.get("status") != "done":
                    deps_done = False
                    break
            if deps_done:
                ready.append(task)

        ready.sort(key=sort_key)
        if ready:
            task_id = ready[0]["id"]
            if args.json:
                json_output(
                    {
                        "status": "work",
                        "epic": epic_id,
                        "task": task_id,
                        "reason": "ready_task",
                    }
                )
            else:
                print(f"work {task_id} ready_task")
            return

    if args.json:
        payload = {"status": "none", "epic": None, "task": None, "reason": "none"}
        if blocked_epics:
            payload["reason"] = "blocked_by_epic_deps"
            payload["blocked_epics"] = blocked_epics
        json_output(payload)
    else:
        if blocked_epics:
            print("none blocked_by_epic_deps")
            for epic_id, deps in blocked_epics.items():
                print(f"  {epic_id}: {', '.join(deps)}")
        else:
            print("none")


def cmd_start(args: argparse.Namespace) -> None:
    """Start a task (set status to in_progress)."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_task_id(args.id):
        error_exit(
            f"Invalid task ID: {args.id}. Expected format: fn-N.M", use_json=args.json
        )

    flow_dir = get_flow_dir()
    task_path = flow_dir / TASKS_DIR / f"{args.id}.json"

    task_data = load_json_or_exit(task_path, f"Task {args.id}", use_json=args.json)

    # MU-2: Soft-claim semantics
    current_actor = get_actor()
    existing_assignee = task_data.get("assignee")

    # Cannot start done task
    if task_data["status"] == "done":
        error_exit(
            f"Cannot start task {args.id}: status is 'done'.", use_json=args.json
        )

    # Blocked requires --force
    if task_data["status"] == "blocked" and not args.force:
        error_exit(
            f"Cannot start task {args.id}: status is 'blocked'. Use --force to override.",
            use_json=args.json,
        )

    # Check if claimed by someone else (unless --force)
    if not args.force and existing_assignee and existing_assignee != current_actor:
        error_exit(
            f"Cannot start task {args.id}: claimed by '{existing_assignee}'. "
            f"Use --force to override.",
            use_json=args.json,
        )

    # Validate task is in todo status (unless --force or resuming own task)
    if not args.force and task_data["status"] != "todo":
        # Allow resuming your own in_progress task
        if not (
            task_data["status"] == "in_progress" and existing_assignee == current_actor
        ):
            error_exit(
                f"Cannot start task {args.id}: status is '{task_data['status']}', expected 'todo'. "
                f"Use --force to override.",
                use_json=args.json,
            )

    # Validate all dependencies are done (unless --force)
    if not args.force:
        for dep in task_data.get("depends_on", []):
            dep_path = flow_dir / TASKS_DIR / f"{dep}.json"
            dep_data = load_json_or_exit(
                dep_path, f"Dependency {dep}", use_json=args.json
            )
            if dep_data["status"] != "done":
                error_exit(
                    f"Cannot start task {args.id}: dependency {dep} is '{dep_data['status']}', not 'done'. "
                    f"Complete dependencies first or use --force to override.",
                    use_json=args.json,
                )

    # Set status and claim fields
    task_data["status"] = "in_progress"
    if not existing_assignee:
        task_data["assignee"] = current_actor
        task_data["claimed_at"] = now_iso()
    if args.note:
        task_data["claim_note"] = args.note
    elif args.force and existing_assignee and existing_assignee != current_actor:
        # Force override: note the takeover
        task_data["assignee"] = current_actor
        task_data["claimed_at"] = now_iso()
        if not args.note:
            task_data["claim_note"] = f"Taken over from {existing_assignee}"
    task_data["updated_at"] = now_iso()
    atomic_write_json(task_path, task_data)

    # NOTE: We no longer update epic timestamp on task start/done.
    # Epic timestamp only changes on epic-level operations (set-plan, close).
    # This reduces merge conflicts in multi-user scenarios.

    if args.json:
        json_output(
            {
                "id": args.id,
                "status": "in_progress",
                "message": f"Task {args.id} started",
            }
        )
    else:
        print(f"Task {args.id} started")


def cmd_done(args: argparse.Namespace) -> None:
    """Complete a task with summary and evidence."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_task_id(args.id):
        error_exit(
            f"Invalid task ID: {args.id}. Expected format: fn-N.M", use_json=args.json
        )

    flow_dir = get_flow_dir()
    task_json_path = flow_dir / TASKS_DIR / f"{args.id}.json"
    task_spec_path = flow_dir / TASKS_DIR / f"{args.id}.md"

    # Load task JSON (fail early before any writes)
    task_data = load_json_or_exit(task_json_path, f"Task {args.id}", use_json=args.json)

    # MU-2: Require in_progress status (unless --force)
    if not args.force and task_data["status"] != "in_progress":
        error_exit(
            f"Cannot complete task {args.id}: status is '{task_data['status']}', expected 'in_progress'. "
            f"Use --force to override.",
            use_json=args.json,
        )

    # MU-2: Prevent cross-actor completion (unless --force)
    current_actor = get_actor()
    existing_assignee = task_data.get("assignee")
    if not args.force and existing_assignee and existing_assignee != current_actor:
        error_exit(
            f"Cannot complete task {args.id}: claimed by '{existing_assignee}'. "
            f"Use --force to override.",
            use_json=args.json,
        )

    # Read summary from file
    summary = read_text_or_exit(
        Path(args.summary_file), "Summary file", use_json=args.json
    )

    # Read evidence from JSON file
    evidence_raw = read_text_or_exit(
        Path(args.evidence_json), "Evidence file", use_json=args.json
    )
    try:
        evidence = json.loads(evidence_raw)
    except json.JSONDecodeError as e:
        error_exit(f"Evidence file invalid JSON: {e}", use_json=args.json)
    if not isinstance(evidence, dict):
        error_exit(
            "Evidence JSON must be an object with keys: commits/tests/prs",
            use_json=args.json,
        )

    # Format evidence as markdown (coerce to strings, handle string-vs-array)
    def to_list(val: Any) -> list:
        if val is None:
            return []
        if isinstance(val, str):
            return [val] if val else []
        return list(val)

    evidence_md = []
    commits = [str(x) for x in to_list(evidence.get("commits"))]
    tests = [str(x) for x in to_list(evidence.get("tests"))]
    prs = [str(x) for x in to_list(evidence.get("prs"))]
    evidence_md.append(f"- Commits: {', '.join(commits)}" if commits else "- Commits:")
    evidence_md.append(f"- Tests: {', '.join(tests)}" if tests else "- Tests:")
    evidence_md.append(f"- PRs: {', '.join(prs)}" if prs else "- PRs:")
    evidence_content = "\n".join(evidence_md)

    # Read current spec
    current_spec = read_text_or_exit(
        task_spec_path, f"Task {args.id} spec", use_json=args.json
    )

    # Patch sections
    try:
        updated_spec = patch_task_section(current_spec, "## Done summary", summary)
        updated_spec = patch_task_section(updated_spec, "## Evidence", evidence_content)
    except ValueError as e:
        error_exit(str(e), use_json=args.json)

    # All validation passed - now write (spec, task)
    atomic_write(task_spec_path, updated_spec)

    task_data["status"] = "done"
    task_data["updated_at"] = now_iso()
    task_data["evidence"] = evidence  # Store raw evidence dict for programmatic access
    atomic_write_json(task_json_path, task_data)

    # NOTE: We no longer update epic timestamp on task done.
    # This reduces merge conflicts in multi-user scenarios.

    if args.json:
        json_output(
            {"id": args.id, "status": "done", "message": f"Task {args.id} completed"}
        )
    else:
        print(f"Task {args.id} completed")


def cmd_block(args: argparse.Namespace) -> None:
    """Block a task with a reason."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_task_id(args.id):
        error_exit(
            f"Invalid task ID: {args.id}. Expected format: fn-N.M", use_json=args.json
        )

    flow_dir = get_flow_dir()
    task_json_path = flow_dir / TASKS_DIR / f"{args.id}.json"
    task_spec_path = flow_dir / TASKS_DIR / f"{args.id}.md"

    task_data = normalize_task(
        load_json_or_exit(task_json_path, f"Task {args.id}", use_json=args.json)
    )

    if task_data["status"] == "done":
        error_exit(
            f"Cannot block task {args.id}: status is 'done'.", use_json=args.json
        )

    reason = read_text_or_exit(
        Path(args.reason_file), "Reason file", use_json=args.json
    ).strip()
    if not reason:
        error_exit("Reason file is empty", use_json=args.json)

    current_spec = read_text_or_exit(
        task_spec_path, f"Task {args.id} spec", use_json=args.json
    )
    summary = get_task_section(current_spec, "## Done summary")
    if summary.strip().lower() in ["tbd", ""]:
        new_summary = f"Blocked:\n{reason}"
    else:
        new_summary = f"{summary}\n\nBlocked:\n{reason}"

    try:
        updated_spec = patch_task_section(current_spec, "## Done summary", new_summary)
    except ValueError as e:
        error_exit(str(e), use_json=args.json)

    atomic_write(task_spec_path, updated_spec)

    task_data["status"] = "blocked"
    task_data["updated_at"] = now_iso()
    atomic_write_json(task_json_path, task_data)

    if args.json:
        json_output(
            {"id": args.id, "status": "blocked", "message": f"Task {args.id} blocked"}
        )
    else:
        print(f"Task {args.id} blocked")


def cmd_epic_close(args: argparse.Namespace) -> None:
    """Close an epic (all tasks must be done)."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    if not is_epic_id(args.id):
        error_exit(
            f"Invalid epic ID: {args.id}. Expected format: fn-N", use_json=args.json
        )

    flow_dir = get_flow_dir()
    epic_path = flow_dir / EPICS_DIR / f"{args.id}.json"

    if not epic_path.exists():
        error_exit(f"Epic {args.id} not found", use_json=args.json)

    # Check all tasks are done
    tasks_dir = flow_dir / TASKS_DIR
    if not tasks_dir.exists():
        error_exit(
            f"{TASKS_DIR}/ missing. Run 'flowctl init' or fix repo state.",
            use_json=args.json,
        )
    incomplete = []
    for task_file in tasks_dir.glob(f"{args.id}.*.json"):
        task_data = load_json_or_exit(
            task_file, f"Task {task_file.stem}", use_json=args.json
        )
        if task_data["status"] != "done":
            incomplete.append(f"{task_data['id']} ({task_data['status']})")

    if incomplete:
        error_exit(
            f"Cannot close epic: incomplete tasks - {', '.join(incomplete)}",
            use_json=args.json,
        )

    epic_data = load_json_or_exit(epic_path, f"Epic {args.id}", use_json=args.json)
    epic_data["status"] = "done"
    epic_data["updated_at"] = now_iso()
    atomic_write_json(epic_path, epic_data)

    if args.json:
        json_output(
            {"id": args.id, "status": "done", "message": f"Epic {args.id} closed"}
        )
    else:
        print(f"Epic {args.id} closed")


def validate_flow_root(flow_dir: Path) -> list[str]:
    """Validate .flow/ root invariants. Returns list of errors."""
    errors = []

    # Check meta.json exists and is valid
    meta_path = flow_dir / META_FILE
    if not meta_path.exists():
        errors.append(f"meta.json missing: {meta_path}")
    else:
        try:
            meta = load_json(meta_path)
            if not is_supported_schema(meta.get("schema_version")):
                errors.append(
                    "schema_version unsupported in meta.json "
                    f"(expected {', '.join(map(str, SUPPORTED_SCHEMA_VERSIONS))}, got {meta.get('schema_version')})"
                )
        except json.JSONDecodeError as e:
            errors.append(f"meta.json invalid JSON: {e}")
        except Exception as e:
            errors.append(f"meta.json unreadable: {e}")

    # Check required subdirectories exist
    for subdir in [EPICS_DIR, SPECS_DIR, TASKS_DIR, MEMORY_DIR]:
        if not (flow_dir / subdir).exists():
            errors.append(f"Required directory missing: {subdir}/")

    return errors


def validate_epic(
    flow_dir: Path, epic_id: str, use_json: bool = True
) -> tuple[list[str], list[str], int]:
    """Validate a single epic. Returns (errors, warnings, task_count)."""
    errors = []
    warnings = []

    epic_path = flow_dir / EPICS_DIR / f"{epic_id}.json"

    if not epic_path.exists():
        errors.append(f"Epic {epic_id} not found")
        return errors, warnings, 0

    epic_data = normalize_epic(
        load_json_or_exit(epic_path, f"Epic {epic_id}", use_json=use_json)
    )

    # Check epic spec exists
    epic_spec = flow_dir / SPECS_DIR / f"{epic_id}.md"
    if not epic_spec.exists():
        errors.append(f"Epic spec missing: {epic_spec}")

    # Validate epic dependencies
    deps = epic_data.get("depends_on_epics", [])
    if deps is None:
        deps = []
    if not isinstance(deps, list):
        errors.append(f"Epic {epic_id}: depends_on_epics must be a list")
    else:
        for dep in deps:
            if not isinstance(dep, str) or not is_epic_id(dep):
                errors.append(f"Epic {epic_id}: invalid depends_on_epics entry '{dep}'")
                continue
            if dep == epic_id:
                errors.append(f"Epic {epic_id}: depends_on_epics cannot include itself")
                continue
            dep_path = flow_dir / EPICS_DIR / f"{dep}.json"
            if not dep_path.exists():
                errors.append(f"Epic {epic_id}: depends_on_epics missing epic {dep}")

    # Get all tasks
    tasks_dir = flow_dir / TASKS_DIR
    tasks = {}
    if tasks_dir.exists():
        for task_file in tasks_dir.glob(f"{epic_id}.*.json"):
            task_data = normalize_task(
                load_json_or_exit(
                    task_file, f"Task {task_file.stem}", use_json=use_json
                )
            )
            if "id" not in task_data:
                continue  # Skip artifact files (GH-21)
            tasks[task_data["id"]] = task_data

    # Validate each task
    for task_id, task in tasks.items():
        # Validate status
        if task.get("status") not in TASK_STATUS:
            errors.append(f"Task {task_id}: invalid status '{task.get('status')}'")

        # Check task spec exists
        task_spec_path = flow_dir / TASKS_DIR / f"{task_id}.md"
        if not task_spec_path.exists():
            errors.append(f"Task spec missing: {task_spec_path}")
        else:
            # Validate task spec headings
            try:
                spec_content = task_spec_path.read_text(encoding="utf-8")
            except Exception as e:
                errors.append(f"Task {task_id}: spec unreadable ({e})")
                continue
            heading_errors = validate_task_spec_headings(spec_content)
            for he in heading_errors:
                errors.append(f"Task {task_id}: {he}")

        # Check dependencies exist and are within epic
        for dep in task["depends_on"]:
            if dep not in tasks:
                errors.append(f"Task {task_id}: dependency {dep} not found")
            if not dep.startswith(epic_id + "."):
                errors.append(
                    f"Task {task_id}: dependency {dep} is outside epic {epic_id}"
                )

    # Cycle detection using DFS
    def has_cycle(task_id: str, visited: set, rec_stack: set) -> list[str]:
        visited.add(task_id)
        rec_stack.add(task_id)

        for dep in tasks.get(task_id, {}).get("depends_on", []):
            if dep not in visited:
                cycle = has_cycle(dep, visited, rec_stack)
                if cycle:
                    return [task_id] + cycle
            elif dep in rec_stack:
                return [task_id, dep]

        rec_stack.remove(task_id)
        return []

    visited = set()
    for task_id in tasks:
        if task_id not in visited:
            cycle = has_cycle(task_id, visited, set())
            if cycle:
                errors.append(f"Dependency cycle detected: {' -> '.join(cycle)}")
                break

    # Check epic done status consistency
    if epic_data["status"] == "done":
        for task_id, task in tasks.items():
            if task["status"] != "done":
                errors.append(
                    f"Epic marked done but task {task_id} is {task['status']}"
                )

    return errors, warnings, len(tasks)


def cmd_prep_chat(args: argparse.Namespace) -> None:
    """Prepare JSON payload for rp-cli chat_send. Handles escaping safely."""
    # Read message from file
    message = read_text_or_exit(Path(args.message_file), "Message file", use_json=False)
    json_str = build_chat_payload(
        message=message,
        mode=args.mode,
        new_chat=args.new_chat,
        chat_name=args.chat_name,
        selected_paths=args.selected_paths,
    )

    if args.output:
        atomic_write(Path(args.output), json_str)
        print(f"Wrote {args.output}", file=sys.stderr)
    else:
        print(json_str)


def cmd_rp_windows(args: argparse.Namespace) -> None:
    result = run_rp_cli(["--raw-json", "-e", "windows"])
    raw = result.stdout or ""
    if args.json:
        windows = parse_windows(raw)
        print(json.dumps(windows))
    else:
        print(raw, end="")


def cmd_rp_pick_window(args: argparse.Namespace) -> None:
    repo_root = args.repo_root
    roots = normalize_repo_root(repo_root)
    result = run_rp_cli(["--raw-json", "-e", "windows"])
    windows = parse_windows(result.stdout or "")
    if len(windows) == 1 and not extract_root_paths(windows[0]):
        win_id = extract_window_id(windows[0])
        if win_id is None:
            error_exit("No window matches repo root", use_json=False, code=2)
        if args.json:
            print(json.dumps({"window": win_id}))
        else:
            print(win_id)
        return
    for win in windows:
        win_id = extract_window_id(win)
        if win_id is None:
            continue
        for path in extract_root_paths(win):
            if path in roots:
                if args.json:
                    print(json.dumps({"window": win_id}))
                else:
                    print(win_id)
                return
    error_exit("No window matches repo root", use_json=False, code=2)


def cmd_rp_ensure_workspace(args: argparse.Namespace) -> None:
    window = args.window
    repo_root = os.path.realpath(args.repo_root)
    ws_name = os.path.basename(repo_root)

    list_cmd = [
        "--raw-json",
        "-w",
        str(window),
        "-e",
        f"call manage_workspaces {json.dumps({'action': 'list'})}",
    ]
    list_res = run_rp_cli(list_cmd)
    try:
        data = json.loads(list_res.stdout)
    except json.JSONDecodeError as e:
        error_exit(f"workspace list JSON parse failed: {e}", use_json=False, code=2)

    def extract_names(obj: Any) -> set[str]:
        names: set[str] = set()
        if isinstance(obj, dict):
            if "workspaces" in obj:
                obj = obj["workspaces"]
            elif "result" in obj:
                obj = obj["result"]
        if isinstance(obj, list):
            for item in obj:
                if isinstance(item, str):
                    names.add(item)
                elif isinstance(item, dict):
                    for key in ("name", "workspace", "title"):
                        if key in item:
                            names.add(str(item[key]))
        return names

    names = extract_names(data)

    if ws_name not in names:
        create_cmd = [
            "-w",
            str(window),
            "-e",
            f"call manage_workspaces {json.dumps({'action': 'create', 'name': ws_name, 'folder_path': repo_root})}",
        ]
        run_rp_cli(create_cmd)

    switch_cmd = [
        "-w",
        str(window),
        "-e",
        f"call manage_workspaces {json.dumps({'action': 'switch', 'workspace': ws_name, 'window_id': window})}",
    ]
    run_rp_cli(switch_cmd)


def cmd_rp_builder(args: argparse.Namespace) -> None:
    window = args.window
    summary = args.summary
    cmd = [
        "-w",
        str(window),
        "-e",
        f"builder {json.dumps(summary)}",
    ]
    res = run_rp_cli(cmd)
    output = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
    tab = parse_builder_tab(output)
    if args.json:
        print(json.dumps({"window": window, "tab": tab}))
    else:
        print(tab)


def cmd_rp_prompt_get(args: argparse.Namespace) -> None:
    cmd = ["-w", str(args.window), "-t", args.tab, "-e", "prompt get"]
    res = run_rp_cli(cmd)
    print(res.stdout, end="")


def cmd_rp_prompt_set(args: argparse.Namespace) -> None:
    message = read_text_or_exit(Path(args.message_file), "Message file", use_json=False)
    payload = json.dumps({"op": "set", "text": message})
    cmd = [
        "-w",
        str(args.window),
        "-t",
        args.tab,
        "-e",
        f"call prompt {payload}",
    ]
    res = run_rp_cli(cmd)
    print(res.stdout, end="")


def cmd_rp_select_get(args: argparse.Namespace) -> None:
    cmd = ["-w", str(args.window), "-t", args.tab, "-e", "select get"]
    res = run_rp_cli(cmd)
    print(res.stdout, end="")


def cmd_rp_select_add(args: argparse.Namespace) -> None:
    if not args.paths:
        error_exit("select-add requires at least one path", use_json=False, code=2)
    quoted = " ".join(shlex.quote(p) for p in args.paths)
    cmd = ["-w", str(args.window), "-t", args.tab, "-e", f"select add {quoted}"]
    res = run_rp_cli(cmd)
    print(res.stdout, end="")


def cmd_rp_chat_send(args: argparse.Namespace) -> None:
    message = read_text_or_exit(Path(args.message_file), "Message file", use_json=False)
    payload = build_chat_payload(
        message=message,
        mode="chat",
        new_chat=args.new_chat,
        chat_name=args.chat_name,
        selected_paths=args.selected_paths,
    )
    cmd = [
        "-w",
        str(args.window),
        "-t",
        args.tab,
        "-e",
        f"call chat_send {payload}",
    ]
    res = run_rp_cli(cmd)
    output = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
    chat_id = parse_chat_id(output)
    if args.json:
        print(json.dumps({"chat": chat_id}))
    else:
        print(res.stdout, end="")


def cmd_rp_prompt_export(args: argparse.Namespace) -> None:
    cmd = [
        "-w",
        str(args.window),
        "-t",
        args.tab,
        "-e",
        f"prompt export {shlex.quote(args.out)}",
    ]
    res = run_rp_cli(cmd)
    print(res.stdout, end="")


def cmd_rp_setup_review(args: argparse.Namespace) -> None:
    """Atomic setup: pick-window + builder.

    Returns W=<window> T=<tab> on success, exits non-zero on failure.
    Writes state file for ralph-guard to verify pick-window ran.

    Note: ensure-workspace removed - if user opens RP on a folder, workspace
    already exists. pick-window matches by folder path.
    """
    import hashlib

    repo_root = os.path.realpath(args.repo_root)
    summary = args.summary

    # Step 1: pick-window
    roots = normalize_repo_root(repo_root)
    result = run_rp_cli(["--raw-json", "-e", "windows"])
    windows = parse_windows(result.stdout or "")

    win_id: Optional[int] = None

    # Single window with no root paths - use it
    if len(windows) == 1 and not extract_root_paths(windows[0]):
        win_id = extract_window_id(windows[0])

    # Otherwise match by root
    if win_id is None:
        for win in windows:
            wid = extract_window_id(win)
            if wid is None:
                continue
            for path in extract_root_paths(win):
                if path in roots:
                    win_id = wid
                    break
            if win_id is not None:
                break

    if win_id is None:
        error_exit("No RepoPrompt window matches repo root", use_json=False, code=2)

    # Write state file for ralph-guard verification
    repo_hash = hashlib.sha256(repo_root.encode()).hexdigest()[:16]
    state_file = Path(f"/tmp/.ralph-pick-window-{repo_hash}")
    state_file.write_text(f"{win_id}\n{repo_root}\n")

    # Step 2: builder
    builder_cmd = [
        "-w",
        str(win_id),
        "-e",
        f"builder {json.dumps(summary)}",
    ]
    builder_res = run_rp_cli(builder_cmd)
    output = (builder_res.stdout or "") + (
        "\n" + builder_res.stderr if builder_res.stderr else ""
    )
    tab = parse_builder_tab(output)

    if not tab:
        error_exit("Builder did not return a tab id", use_json=False, code=2)

    # Output
    if args.json:
        print(json.dumps({"window": win_id, "tab": tab, "repo_root": repo_root}))
    else:
        print(f"W={win_id} T={tab}")


# --- Codex Commands ---


def cmd_codex_check(args: argparse.Namespace) -> None:
    """Check if codex CLI is available and return version."""
    codex = shutil.which("codex")
    available = codex is not None
    version = get_codex_version() if available else None

    if args.json:
        json_output({"available": available, "version": version})
    else:
        if available:
            print(f"codex available: {version or 'unknown version'}")
        else:
            print("codex not available")


def build_standalone_review_prompt(
    base_branch: str, focus: Optional[str], diff_summary: str
) -> str:
    """Build review prompt for standalone branch review (no task context)."""
    focus_section = ""
    if focus:
        focus_section = f"""
## Focus Areas
{focus}

Pay special attention to these areas during review.
"""

    return f"""# Implementation Review: Branch Changes vs {base_branch}

Review all changes on the current branch compared to {base_branch}.
{focus_section}
## Diff Summary
```
{diff_summary}
```

## Review Criteria (Carmack-level)

1. **Correctness** - Does the code do what it claims?
2. **Reliability** - Can this fail silently or cause flaky behavior?
3. **Simplicity** - Is this the simplest solution?
4. **Security** - Injection, auth gaps, resource exhaustion?
5. **Edge Cases** - Failure modes, race conditions, malformed input?

## Output Format

For each issue found:
- **Severity**: Critical / Major / Minor / Nitpick
- **File:Line**: Exact location
- **Problem**: What's wrong
- **Suggestion**: How to fix

Be critical. Find real issues.

**REQUIRED**: End your response with exactly one verdict tag:
- `<verdict>SHIP</verdict>` - Ready to merge
- `<verdict>NEEDS_WORK</verdict>` - Issues must be fixed first
- `<verdict>MAJOR_RETHINK</verdict>` - Fundamental problems, reconsider approach
"""


def cmd_codex_impl_review(args: argparse.Namespace) -> None:
    """Run implementation review via codex exec."""
    task_id = args.task
    base_branch = args.base
    focus = getattr(args, "focus", None)

    # Standalone mode (no task ID) - review branch without task context
    standalone = task_id is None

    if not standalone:
        # Task-specific review requires .flow/
        if not ensure_flow_exists():
            error_exit(".flow/ does not exist", use_json=args.json)

        # Validate task ID
        if not is_task_id(task_id):
            error_exit(f"Invalid task ID: {task_id}", use_json=args.json)

        # Load task spec
        flow_dir = get_flow_dir()
        task_spec_path = flow_dir / TASKS_DIR / f"{task_id}.md"

        if not task_spec_path.exists():
            error_exit(f"Task spec not found: {task_spec_path}", use_json=args.json)

        task_spec = task_spec_path.read_text(encoding="utf-8")

    # Get diff summary
    try:
        diff_result = subprocess.run(
            ["git", "diff", "--stat", base_branch],
            capture_output=True,
            text=True,
            cwd=get_repo_root(),
        )
        diff_summary = diff_result.stdout.strip()
    except subprocess.CalledProcessError:
        diff_summary = ""

    # Build prompt
    if standalone:
        prompt = build_standalone_review_prompt(base_branch, focus, diff_summary)
    else:
        # Get context hints for task-specific review
        context_hints = gather_context_hints(base_branch)
        prompt = build_review_prompt("impl", task_spec, context_hints, diff_summary)

    # Check for existing session in receipt
    receipt_path = args.receipt if hasattr(args, "receipt") and args.receipt else None
    session_id = None
    if receipt_path:
        receipt_file = Path(receipt_path)
        if receipt_file.exists():
            try:
                receipt_data = json.loads(receipt_file.read_text(encoding="utf-8"))
                session_id = receipt_data.get("session_id")
            except (json.JSONDecodeError, Exception):
                pass

    # Run codex
    output, thread_id = run_codex_exec(prompt, session_id=session_id)

    # Parse verdict
    verdict = parse_codex_verdict(output)

    # Determine review id (task_id for task reviews, "branch" for standalone)
    review_id = task_id if task_id else "branch"

    # Write receipt if path provided (Ralph-compatible schema)
    if receipt_path:
        receipt_data = {
            "type": "impl_review",  # Required by Ralph
            "id": review_id,  # Required by Ralph
            "mode": "codex",
            "base": base_branch,
            "verdict": verdict,
            "session_id": thread_id,
            "timestamp": now_iso(),
            "review": output,  # Full review feedback for fix loop
        }
        if focus:
            receipt_data["focus"] = focus
        Path(receipt_path).write_text(
            json.dumps(receipt_data, indent=2) + "\n", encoding="utf-8"
        )

    # Output
    if args.json:
        json_output(
            {
                "type": "impl_review",
                "id": review_id,
                "verdict": verdict,
                "session_id": thread_id,
                "mode": "codex",
                "standalone": standalone,
                "review": output,  # Full review feedback for fix loop
            }
        )
    else:
        print(output)
        print(f"\nVERDICT={verdict or 'UNKNOWN'}")


def cmd_codex_plan_review(args: argparse.Namespace) -> None:
    """Run plan review via codex exec."""
    if not ensure_flow_exists():
        error_exit(".flow/ does not exist", use_json=args.json)

    epic_id = args.epic

    # Validate epic ID
    if not is_epic_id(epic_id):
        error_exit(f"Invalid epic ID: {epic_id}", use_json=args.json)

    # Load epic spec
    flow_dir = get_flow_dir()
    epic_spec_path = flow_dir / SPECS_DIR / f"{epic_id}.md"

    if not epic_spec_path.exists():
        error_exit(f"Epic spec not found: {epic_spec_path}", use_json=args.json)

    epic_spec = epic_spec_path.read_text(encoding="utf-8")

    # Get context hints (from main branch for plans)
    base_branch = args.base if hasattr(args, "base") and args.base else "main"
    context_hints = gather_context_hints(base_branch)

    # Build prompt
    prompt = build_review_prompt("plan", epic_spec, context_hints)

    # Check for existing session in receipt
    receipt_path = args.receipt if hasattr(args, "receipt") and args.receipt else None
    session_id = None
    if receipt_path:
        receipt_file = Path(receipt_path)
        if receipt_file.exists():
            try:
                receipt_data = json.loads(receipt_file.read_text(encoding="utf-8"))
                session_id = receipt_data.get("session_id")
            except (json.JSONDecodeError, Exception):
                pass

    # Run codex
    output, thread_id = run_codex_exec(prompt, session_id=session_id)

    # Parse verdict
    verdict = parse_codex_verdict(output)

    # Write receipt if path provided (Ralph-compatible schema)
    if receipt_path:
        receipt_data = {
            "type": "plan_review",  # Required by Ralph
            "id": epic_id,  # Required by Ralph
            "mode": "codex",
            "verdict": verdict,
            "session_id": thread_id,
            "timestamp": now_iso(),
            "review": output,  # Full review feedback for fix loop
        }
        Path(receipt_path).write_text(
            json.dumps(receipt_data, indent=2) + "\n", encoding="utf-8"
        )

    # Output
    if args.json:
        json_output(
            {
                "type": "plan_review",
                "id": epic_id,
                "verdict": verdict,
                "session_id": thread_id,
                "mode": "codex",
                "review": output,  # Full review feedback for fix loop
            }
        )
    else:
        print(output)
        print(f"\nVERDICT={verdict or 'UNKNOWN'}")


def cmd_validate(args: argparse.Namespace) -> None:
    """Validate epic structure or all epics."""
    if not ensure_flow_exists():
        error_exit(
            ".flow/ does not exist. Run 'flowctl init' first.", use_json=args.json
        )

    # Require either --epic or --all
    if not args.epic and not getattr(args, "all", False):
        error_exit("Must specify --epic or --all", use_json=args.json)

    flow_dir = get_flow_dir()

    # MU-3: Validate all mode
    if getattr(args, "all", False):
        # First validate .flow/ root invariants
        root_errors = validate_flow_root(flow_dir)

        epics_dir = flow_dir / EPICS_DIR

        # Find all epics (if epics dir exists)
        epic_ids = []
        if epics_dir.exists():
            for epic_file in sorted(epics_dir.glob("fn-*.json")):
                match = re.match(r"^fn-(\d+)\.json$", epic_file.name)
                if match:
                    epic_ids.append(f"fn-{match.group(1)}")

        # Start with root errors
        all_errors = list(root_errors)
        all_warnings = []
        total_tasks = 0
        epic_results = []

        for epic_id in epic_ids:
            errors, warnings, task_count = validate_epic(
                flow_dir, epic_id, use_json=args.json
            )
            all_errors.extend(errors)
            all_warnings.extend(warnings)
            total_tasks += task_count
            epic_results.append(
                {
                    "epic": epic_id,
                    "valid": len(errors) == 0,
                    "errors": errors,
                    "warnings": warnings,
                    "task_count": task_count,
                }
            )

        valid = len(all_errors) == 0

        if args.json:
            json_output(
                {
                    "valid": valid,
                    "root_errors": root_errors,
                    "epics": epic_results,
                    "total_epics": len(epic_ids),
                    "total_tasks": total_tasks,
                    "total_errors": len(all_errors),
                    "total_warnings": len(all_warnings),
                },
                success=valid,
            )
        else:
            print("Validation for all epics:")
            print(f"  Epics: {len(epic_ids)}")
            print(f"  Tasks: {total_tasks}")
            print(f"  Valid: {valid}")
            if all_errors:
                print("  Errors:")
                for e in all_errors:
                    print(f"    - {e}")
            if all_warnings:
                print("  Warnings:")
                for w in all_warnings:
                    print(f"    - {w}")

        # Exit with non-zero if validation failed
        if not valid:
            sys.exit(1)
        return

    # Single epic validation
    if not is_epic_id(args.epic):
        error_exit(
            f"Invalid epic ID: {args.epic}. Expected format: fn-N", use_json=args.json
        )

    errors, warnings, task_count = validate_epic(
        flow_dir, args.epic, use_json=args.json
    )
    valid = len(errors) == 0

    if args.json:
        json_output(
            {
                "epic": args.epic,
                "valid": valid,
                "errors": errors,
                "warnings": warnings,
                "task_count": task_count,
            },
            success=valid,
        )
    else:
        print(f"Validation for {args.epic}:")
        print(f"  Tasks: {task_count}")
        print(f"  Valid: {valid}")
        if errors:
            print("  Errors:")
            for e in errors:
                print(f"    - {e}")
        if warnings:
            print("  Warnings:")
            for w in warnings:
                print(f"    - {w}")

    # Exit with non-zero if validation failed
    if not valid:
        sys.exit(1)


# --- Main ---


def main() -> None:
    parser = argparse.ArgumentParser(
        description="flowctl - CLI for .flow/ task tracking",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # init
    p_init = subparsers.add_parser("init", help="Initialize .flow/ directory")
    p_init.add_argument("--json", action="store_true", help="JSON output")
    p_init.set_defaults(func=cmd_init)

    # detect
    p_detect = subparsers.add_parser("detect", help="Check if .flow/ exists")
    p_detect.add_argument("--json", action="store_true", help="JSON output")
    p_detect.set_defaults(func=cmd_detect)

    # config
    p_config = subparsers.add_parser("config", help="Config commands")
    config_sub = p_config.add_subparsers(dest="config_cmd", required=True)

    p_config_get = config_sub.add_parser("get", help="Get config value")
    p_config_get.add_argument("key", help="Config key (e.g., memory.enabled)")
    p_config_get.add_argument("--json", action="store_true", help="JSON output")
    p_config_get.set_defaults(func=cmd_config_get)

    p_config_set = config_sub.add_parser("set", help="Set config value")
    p_config_set.add_argument("key", help="Config key (e.g., memory.enabled)")
    p_config_set.add_argument("value", help="Config value")
    p_config_set.add_argument("--json", action="store_true", help="JSON output")
    p_config_set.set_defaults(func=cmd_config_set)

    # memory
    p_memory = subparsers.add_parser("memory", help="Memory commands")
    memory_sub = p_memory.add_subparsers(dest="memory_cmd", required=True)

    p_memory_init = memory_sub.add_parser("init", help="Initialize memory templates")
    p_memory_init.add_argument("--json", action="store_true", help="JSON output")
    p_memory_init.set_defaults(func=cmd_memory_init)

    p_memory_add = memory_sub.add_parser("add", help="Add memory entry")
    p_memory_add.add_argument(
        "--type", required=True, help="Type: pitfall, convention, or decision"
    )
    p_memory_add.add_argument("content", help="Entry content")
    p_memory_add.add_argument("--json", action="store_true", help="JSON output")
    p_memory_add.set_defaults(func=cmd_memory_add)

    p_memory_read = memory_sub.add_parser("read", help="Read memory entries")
    p_memory_read.add_argument(
        "--type", help="Filter by type: pitfalls, conventions, or decisions"
    )
    p_memory_read.add_argument("--json", action="store_true", help="JSON output")
    p_memory_read.set_defaults(func=cmd_memory_read)

    p_memory_list = memory_sub.add_parser("list", help="List memory entry counts")
    p_memory_list.add_argument("--json", action="store_true", help="JSON output")
    p_memory_list.set_defaults(func=cmd_memory_list)

    p_memory_search = memory_sub.add_parser("search", help="Search memory entries")
    p_memory_search.add_argument("pattern", help="Search pattern (regex)")
    p_memory_search.add_argument("--json", action="store_true", help="JSON output")
    p_memory_search.set_defaults(func=cmd_memory_search)

    # epic create
    p_epic = subparsers.add_parser("epic", help="Epic commands")
    epic_sub = p_epic.add_subparsers(dest="epic_cmd", required=True)

    p_epic_create = epic_sub.add_parser("create", help="Create new epic")
    p_epic_create.add_argument("--title", required=True, help="Epic title")
    p_epic_create.add_argument("--branch", help="Branch name to store on epic")
    p_epic_create.add_argument("--json", action="store_true", help="JSON output")
    p_epic_create.set_defaults(func=cmd_epic_create)

    p_epic_set_plan = epic_sub.add_parser("set-plan", help="Set epic spec from file")
    p_epic_set_plan.add_argument("id", help="Epic ID (fn-N)")
    p_epic_set_plan.add_argument("--file", required=True, help="Markdown file")
    p_epic_set_plan.add_argument("--json", action="store_true", help="JSON output")
    p_epic_set_plan.set_defaults(func=cmd_epic_set_plan)

    p_epic_set_review = epic_sub.add_parser(
        "set-plan-review-status", help="Set plan review status"
    )
    p_epic_set_review.add_argument("id", help="Epic ID (fn-N)")
    p_epic_set_review.add_argument(
        "--status",
        required=True,
        choices=["ship", "needs_work", "unknown"],
        help="Plan review status",
    )
    p_epic_set_review.add_argument("--json", action="store_true", help="JSON output")
    p_epic_set_review.set_defaults(func=cmd_epic_set_plan_review_status)

    p_epic_set_branch = epic_sub.add_parser("set-branch", help="Set epic branch name")
    p_epic_set_branch.add_argument("id", help="Epic ID (fn-N)")
    p_epic_set_branch.add_argument("--branch", required=True, help="Branch name")
    p_epic_set_branch.add_argument("--json", action="store_true", help="JSON output")
    p_epic_set_branch.set_defaults(func=cmd_epic_set_branch)

    p_epic_close = epic_sub.add_parser("close", help="Close epic")
    p_epic_close.add_argument("id", help="Epic ID (fn-N)")
    p_epic_close.add_argument("--json", action="store_true", help="JSON output")
    p_epic_close.set_defaults(func=cmd_epic_close)

    # task create
    p_task = subparsers.add_parser("task", help="Task commands")
    task_sub = p_task.add_subparsers(dest="task_cmd", required=True)

    p_task_create = task_sub.add_parser("create", help="Create new task")
    p_task_create.add_argument("--epic", required=True, help="Epic ID (fn-N)")
    p_task_create.add_argument("--title", required=True, help="Task title")
    p_task_create.add_argument("--deps", help="Comma-separated dependency IDs")
    p_task_create.add_argument(
        "--acceptance-file", help="Markdown file with acceptance criteria"
    )
    p_task_create.add_argument(
        "--priority", type=int, help="Priority (lower = earlier)"
    )
    p_task_create.add_argument("--json", action="store_true", help="JSON output")
    p_task_create.set_defaults(func=cmd_task_create)

    p_task_desc = task_sub.add_parser("set-description", help="Set task description")
    p_task_desc.add_argument("id", help="Task ID (fn-N.M)")
    p_task_desc.add_argument("--file", required=True, help="Markdown file")
    p_task_desc.add_argument("--json", action="store_true", help="JSON output")
    p_task_desc.set_defaults(func=cmd_task_set_description)

    p_task_acc = task_sub.add_parser("set-acceptance", help="Set task acceptance")
    p_task_acc.add_argument("id", help="Task ID (fn-N.M)")
    p_task_acc.add_argument("--file", required=True, help="Markdown file")
    p_task_acc.add_argument("--json", action="store_true", help="JSON output")
    p_task_acc.set_defaults(func=cmd_task_set_acceptance)

    # dep add
    p_dep = subparsers.add_parser("dep", help="Dependency commands")
    dep_sub = p_dep.add_subparsers(dest="dep_cmd", required=True)

    p_dep_add = dep_sub.add_parser("add", help="Add dependency")
    p_dep_add.add_argument("task", help="Task ID (fn-N.M)")
    p_dep_add.add_argument("depends_on", help="Dependency task ID (fn-N.M)")
    p_dep_add.add_argument("--json", action="store_true", help="JSON output")
    p_dep_add.set_defaults(func=cmd_dep_add)

    # show
    p_show = subparsers.add_parser("show", help="Show epic or task")
    p_show.add_argument("id", help="Epic (fn-N) or task (fn-N.M) ID")
    p_show.add_argument("--json", action="store_true", help="JSON output")
    p_show.set_defaults(func=cmd_show)

    # epics
    p_epics = subparsers.add_parser("epics", help="List all epics")
    p_epics.add_argument("--json", action="store_true", help="JSON output")
    p_epics.set_defaults(func=cmd_epics)

    # tasks
    p_tasks = subparsers.add_parser("tasks", help="List tasks")
    p_tasks.add_argument("--epic", help="Filter by epic ID (fn-N)")
    p_tasks.add_argument(
        "--status",
        choices=["todo", "in_progress", "blocked", "done"],
        help="Filter by status",
    )
    p_tasks.add_argument("--json", action="store_true", help="JSON output")
    p_tasks.set_defaults(func=cmd_tasks)

    # list
    p_list = subparsers.add_parser("list", help="List all epics and tasks")
    p_list.add_argument("--json", action="store_true", help="JSON output")
    p_list.set_defaults(func=cmd_list)

    # cat
    p_cat = subparsers.add_parser("cat", help="Print spec markdown")
    p_cat.add_argument("id", help="Epic (fn-N) or task (fn-N.M) ID")
    p_cat.set_defaults(func=cmd_cat)

    # ready
    p_ready = subparsers.add_parser("ready", help="List ready tasks")
    p_ready.add_argument("--epic", required=True, help="Epic ID (fn-N)")
    p_ready.add_argument("--json", action="store_true", help="JSON output")
    p_ready.set_defaults(func=cmd_ready)

    # next
    p_next = subparsers.add_parser("next", help="Select next plan/work unit")
    p_next.add_argument("--epics-file", help="JSON file with ordered epic list")
    p_next.add_argument(
        "--require-plan-review",
        action="store_true",
        help="Require plan review before work",
    )
    p_next.add_argument("--json", action="store_true", help="JSON output")
    p_next.set_defaults(func=cmd_next)

    # start
    p_start = subparsers.add_parser("start", help="Start task")
    p_start.add_argument("id", help="Task ID (fn-N.M)")
    p_start.add_argument(
        "--force", action="store_true", help="Skip status/dependency/claim checks"
    )
    p_start.add_argument("--note", help="Claim note (e.g., reason for taking over)")
    p_start.add_argument("--json", action="store_true", help="JSON output")
    p_start.set_defaults(func=cmd_start)

    # done
    p_done = subparsers.add_parser("done", help="Complete task")
    p_done.add_argument("id", help="Task ID (fn-N.M)")
    p_done.add_argument(
        "--summary-file", required=True, help="Done summary markdown file"
    )
    p_done.add_argument("--evidence-json", required=True, help="Evidence JSON file")
    p_done.add_argument("--force", action="store_true", help="Skip status checks")
    p_done.add_argument("--json", action="store_true", help="JSON output")
    p_done.set_defaults(func=cmd_done)

    # block
    p_block = subparsers.add_parser("block", help="Block task with reason")
    p_block.add_argument("id", help="Task ID (fn-N.M)")
    p_block.add_argument(
        "--reason-file", required=True, help="Markdown file with block reason"
    )
    p_block.add_argument("--json", action="store_true", help="JSON output")
    p_block.set_defaults(func=cmd_block)

    # validate
    p_validate = subparsers.add_parser("validate", help="Validate epic or all")
    p_validate.add_argument("--epic", help="Epic ID (fn-N)")
    p_validate.add_argument(
        "--all", action="store_true", help="Validate all epics and tasks"
    )
    p_validate.add_argument("--json", action="store_true", help="JSON output")
    p_validate.set_defaults(func=cmd_validate)

    # prep-chat (for rp-cli chat_send JSON escaping)
    p_prep = subparsers.add_parser(
        "prep-chat", help="Prepare JSON for rp-cli chat_send"
    )
    p_prep.add_argument(
        "id", nargs="?", help="(ignored) Epic/task ID for compatibility"
    )
    p_prep.add_argument(
        "--message-file", required=True, help="File containing message text"
    )
    p_prep.add_argument(
        "--mode", default="chat", choices=["chat", "ask"], help="Chat mode"
    )
    p_prep.add_argument("--new-chat", action="store_true", help="Start new chat")
    p_prep.add_argument("--chat-name", help="Name for new chat")
    p_prep.add_argument(
        "--selected-paths", nargs="*", help="Files to include in context"
    )
    p_prep.add_argument("--output", "-o", help="Output file (default: stdout)")
    p_prep.set_defaults(func=cmd_prep_chat)

    # rp (RepoPrompt wrappers)
    p_rp = subparsers.add_parser("rp", help="RepoPrompt helpers")
    rp_sub = p_rp.add_subparsers(dest="rp_cmd", required=True)

    p_rp_windows = rp_sub.add_parser(
        "windows", help="List RepoPrompt windows (raw JSON)"
    )
    p_rp_windows.add_argument("--json", action="store_true", help="JSON output (raw)")
    p_rp_windows.set_defaults(func=cmd_rp_windows)

    p_rp_pick = rp_sub.add_parser("pick-window", help="Pick window by repo root")
    p_rp_pick.add_argument("--repo-root", required=True, help="Repo root path")
    p_rp_pick.add_argument("--json", action="store_true", help="JSON output")
    p_rp_pick.set_defaults(func=cmd_rp_pick_window)

    p_rp_ws = rp_sub.add_parser(
        "ensure-workspace", help="Ensure workspace and switch window"
    )
    p_rp_ws.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_ws.add_argument("--repo-root", required=True, help="Repo root path")
    p_rp_ws.set_defaults(func=cmd_rp_ensure_workspace)

    p_rp_builder = rp_sub.add_parser("builder", help="Run builder and return tab")
    p_rp_builder.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_builder.add_argument("--summary", required=True, help="Builder summary")
    p_rp_builder.add_argument("--json", action="store_true", help="JSON output")
    p_rp_builder.set_defaults(func=cmd_rp_builder)

    p_rp_prompt_get = rp_sub.add_parser("prompt-get", help="Get current prompt")
    p_rp_prompt_get.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_prompt_get.add_argument("--tab", required=True, help="Tab id or name")
    p_rp_prompt_get.set_defaults(func=cmd_rp_prompt_get)

    p_rp_prompt_set = rp_sub.add_parser("prompt-set", help="Set current prompt")
    p_rp_prompt_set.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_prompt_set.add_argument("--tab", required=True, help="Tab id or name")
    p_rp_prompt_set.add_argument("--message-file", required=True, help="Message file")
    p_rp_prompt_set.set_defaults(func=cmd_rp_prompt_set)

    p_rp_select_get = rp_sub.add_parser("select-get", help="Get selection")
    p_rp_select_get.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_select_get.add_argument("--tab", required=True, help="Tab id or name")
    p_rp_select_get.set_defaults(func=cmd_rp_select_get)

    p_rp_select_add = rp_sub.add_parser("select-add", help="Add files to selection")
    p_rp_select_add.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_select_add.add_argument("--tab", required=True, help="Tab id or name")
    p_rp_select_add.add_argument("paths", nargs="+", help="Paths to add")
    p_rp_select_add.set_defaults(func=cmd_rp_select_add)

    p_rp_chat = rp_sub.add_parser("chat-send", help="Send chat via rp-cli")
    p_rp_chat.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_chat.add_argument("--tab", required=True, help="Tab id or name")
    p_rp_chat.add_argument("--message-file", required=True, help="Message file")
    p_rp_chat.add_argument("--new-chat", action="store_true", help="Start new chat")
    p_rp_chat.add_argument("--chat-name", help="Chat name (with --new-chat)")
    p_rp_chat.add_argument(
        "--selected-paths", nargs="*", help="Override selected paths"
    )
    p_rp_chat.add_argument(
        "--json", action="store_true", help="JSON output (no review text)"
    )
    p_rp_chat.set_defaults(func=cmd_rp_chat_send)

    p_rp_export = rp_sub.add_parser("prompt-export", help="Export prompt to file")
    p_rp_export.add_argument("--window", type=int, required=True, help="Window id")
    p_rp_export.add_argument("--tab", required=True, help="Tab id or name")
    p_rp_export.add_argument("--out", required=True, help="Output file")
    p_rp_export.set_defaults(func=cmd_rp_prompt_export)

    p_rp_setup = rp_sub.add_parser(
        "setup-review", help="Atomic: pick-window + workspace + builder"
    )
    p_rp_setup.add_argument("--repo-root", required=True, help="Repo root path")
    p_rp_setup.add_argument("--summary", required=True, help="Builder summary")
    p_rp_setup.add_argument("--json", action="store_true", help="JSON output")
    p_rp_setup.set_defaults(func=cmd_rp_setup_review)

    # codex (Codex CLI wrappers)
    p_codex = subparsers.add_parser("codex", help="Codex CLI helpers")
    codex_sub = p_codex.add_subparsers(dest="codex_cmd", required=True)

    p_codex_check = codex_sub.add_parser("check", help="Check codex availability")
    p_codex_check.add_argument("--json", action="store_true", help="JSON output")
    p_codex_check.set_defaults(func=cmd_codex_check)

    p_codex_impl = codex_sub.add_parser("impl-review", help="Implementation review")
    p_codex_impl.add_argument(
        "task",
        nargs="?",
        default=None,
        help="Task ID (fn-N.M), optional for standalone",
    )
    p_codex_impl.add_argument("--base", required=True, help="Base branch for diff")
    p_codex_impl.add_argument(
        "--focus", help="Focus areas for standalone review (comma-separated)"
    )
    p_codex_impl.add_argument(
        "--receipt", help="Receipt file path for session continuity"
    )
    p_codex_impl.add_argument("--json", action="store_true", help="JSON output")
    p_codex_impl.set_defaults(func=cmd_codex_impl_review)

    p_codex_plan = codex_sub.add_parser("plan-review", help="Plan review")
    p_codex_plan.add_argument("epic", help="Epic ID (fn-N)")
    p_codex_plan.add_argument("--base", default="main", help="Base branch for context")
    p_codex_plan.add_argument(
        "--receipt", help="Receipt file path for session continuity"
    )
    p_codex_plan.add_argument("--json", action="store_true", help="JSON output")
    p_codex_plan.set_defaults(func=cmd_codex_plan_review)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
