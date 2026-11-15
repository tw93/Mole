"""Run the Mole CLI for the window: every rule, check and removal stays in the
CLI, the GUI only reads its JSON or plain-text output and asks it to act."""

import json
import os
import re
import shlex
import shutil
import signal

from gi.repository import Gio, GLib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOLE = os.path.join(ROOT, "mole")

# Plain output: no colors, no spinners, no terminal width guesses.
_ENV = {"NO_COLOR": "1", "TERM": "dumb", "LC_ALL": "C.UTF-8"}
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def _launcher(merge_stderr=False):
    flags = Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDIN_PIPE
    flags |= Gio.SubprocessFlags.STDERR_MERGE if merge_stderr else Gio.SubprocessFlags.STDERR_PIPE
    launcher = Gio.SubprocessLauncher.new(flags)
    for key, value in _ENV.items():
        launcher.setenv(key, value, True)
    launcher.set_cwd(GLib.get_home_dir())
    return launcher


def _spawn(launcher, argv):
    # Its own process group, so stop() also ends the helpers mo starts
    # (analyze-go, du, find), not only the router's bash.
    return launcher.spawnv(["setsid", *argv])


def stop(proc):
    """End a command started by run or stream, with everything it started."""
    pid = proc.get_identifier()
    if pid:
        try:
            os.killpg(int(pid), signal.SIGTERM)
        except ProcessLookupError:
            pass


def run(args, callback, cancellable=None):
    """Run `mo <args>` and call callback(ok, stdout, stderr) on the main loop.
    Cancelling ends the command too."""
    try:
        proc = _spawn(_launcher(), [MOLE, *args])
    except GLib.Error as err:
        callback(False, "", err.message)
        return None
    if cancellable is not None:
        cancellable.connect(lambda *_: stop(proc))

    def done(p, result):
        try:
            _, out, err = p.communicate_utf8_finish(result)
        except GLib.Error as e:
            callback(False, "", e.message)
            return
        callback(p.get_successful(), out or "", err or "")

    proc.communicate_utf8_async(None, cancellable, done)
    return proc


def run_json(args, callback, cancellable=None):
    """Run `mo <args>` and call callback(data or None, error text)."""

    def done(ok, out, err):
        try:
            data = json.loads(out)
        except ValueError:
            callback(None, (err or out).strip() or "Mole printed no report")
            return
        callback(data, "")

    return run(args, done, cancellable)


def stream(argv, on_line, on_exit):
    """Run argv (a full command) and call on_line(text) per output line, then
    on_exit(ok). stdin is /dev/null, so the CLI never waits for a key."""
    try:
        launcher = _launcher(merge_stderr=True)
        launcher.set_flags(Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)
        proc = _spawn(launcher, argv)
    except GLib.Error as err:
        on_line(err.message)
        on_exit(False)
        return None
    data = Gio.DataInputStream.new(proc.get_stdout_pipe())

    def read(stream_, result):
        try:
            line, _ = stream_.read_line_finish_utf8(result)
        except GLib.Error:
            line = None
        if line is None:
            proc.wait_async(None, lambda p, r: (p.wait_finish(r), on_exit(p.get_successful())))
            return
        on_line(strip(line))
        stream_.read_line_async(GLib.PRIORITY_DEFAULT, None, read)

    data.read_line_async(GLib.PRIORITY_DEFAULT, None, read)
    return proc


def strip(text):
    return _ANSI.sub("", text).replace("\r", "")


_SECTION = "➤ "
_GLYPHS = {"✓": "ok", "○": "dry", "⊙": "review", "◎": "attention", "☻": "error", "●": "ok"}
_SIZE = re.compile(r"(\d+(?:\.\d+)?)(B|KB|MB|GB|TB)\b")
_UNITS = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}


def parse_report(text):
    """Split clean/optimize output into sections of items.

    Lines look like "➤ Section", "  ✓ Label · detail", "    ↳ sub item" or an
    indented hint. Returns ([{title, items: [{kind, label, detail, bytes,
    subs, hints}]}], summary lines)."""
    sections, summary, item = [], [], None
    in_summary = False
    for raw in strip(text).splitlines():
        line = raw.rstrip()
        if line.startswith("====="):
            in_summary = not in_summary
            continue
        if in_summary:
            if line.strip():
                summary.append(line.strip())
            continue
        if line.startswith(_SECTION):
            sections.append({"title": line[len(_SECTION):].strip(), "items": []})
            item = None
            continue
        if not sections or not line.strip():
            continue
        body = line.strip()
        glyph = body[:1]
        if line.startswith("  ") and not line.startswith("    ") and glyph in _GLYPHS:
            label, _, detail = body[1:].strip().partition(" · ")
            kind = _GLYPHS[glyph]
            if kind == "dry" and ("skipped" in detail or "would skip" in detail):
                kind = "skipped"
            if detail.endswith(" dry"):
                detail = detail[:-4]
            item = {"kind": kind, "label": label, "detail": detail, "bytes": size_bytes(detail), "subs": [], "hints": []}
            sections[-1]["items"].append(item)
        elif item is not None and body.startswith("↳"):
            item["subs"].append(body[1:].strip())
        elif item is not None:
            item["hints"].append(body)
    return sections, summary


def size_bytes(text):
    m = _SIZE.search(text or "")
    return int(float(m.group(1)) * _UNITS[m.group(2)]) if m else 0


def human(n):
    """Bytes the way the CLI prints them (decimal units)."""
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1000
    return ""


def trash(paths, callback):
    """Move paths to the Trash through the CLI's own sink (mole_trash), which
    refuses protected paths and writes the operations log."""
    script = ('SCRIPT_DIR="$1"; source "$1/lib/core/common.sh"; shift; rc=0; mole_trash analyze "$@" || rc=$?; '
              'printf "%s\\n" "${MOLE_TRASH_ERRORS[@]}"; exit $rc')
    try:
        proc = _launcher().spawnv(["bash", "-c", script, "mole", ROOT, *paths])
    except GLib.Error as err:
        callback(False, err.message)
        return

    def done(p, result):
        try:
            _, out, err = p.communicate_utf8_finish(result)
        except GLib.Error as e:
            callback(False, e.message)
            return
        callback(p.get_successful(), (out or err or "").strip())

    proc.communicate_utf8_async(None, None, done)


_TERMINALS = (
    ("xdg-terminal-exec", []),
    ("ptyxis", ["--"]),
    ("gnome-terminal", ["--"]),
    ("kgx", ["-e"]),
    ("konsole", ["-e"]),
    ("xfce4-terminal", ["-x"]),
    ("alacritty", ["-e"]),
    ("kitty", []),
    ("foot", []),
    ("x-terminal-emulator", ["-e"]),
)


def in_terminal(command):
    """Open a terminal running command (a shell string): for steps that need
    sudo or the package manager's own confirmation. Returns False when no
    terminal is installed."""
    script = f"{command}; echo; read -rsn1 -p 'Press any key to close'"
    for name, prefix in _TERMINALS:
        path = shutil.which(name)
        if path:
            try:
                Gio.Subprocess.new([path, *prefix, "bash", "-c", script], Gio.SubprocessFlags.NONE)
                return True
            except GLib.Error:
                continue
    return False


def mo_command(*args):
    """A shell command that runs this Mole with args, for in_terminal."""
    return shlex.join([MOLE, *args])


def config_path(name):
    """A file in Mole's config folder ($XDG_CONFIG_HOME/mole), as the CLI reads it."""
    base = os.environ.get("XDG_CONFIG_HOME") or ""
    if not base.startswith("/"):
        base = os.path.join(GLib.get_home_dir(), ".config")
    return os.path.join(base.rstrip("/"), "mole", name)


def read_config(path):
    """The lines of a config file the CLI reads; [] when there is none. A
    broken link raises, as the CLI refuses it: writing a new file in its place
    would drop what the linked file holds."""
    if os.path.islink(path) and not os.path.exists(path):
        raise OSError(2, "broken link", path)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return []


def is_entry(line):
    return bool(line.strip()) and not line.strip().startswith("#")


def merge_entries(lines, entries):
    """The file's lines with only `entries` left: comments and blank lines stay
    where they were, dropped entries go, new ones are added at the end."""
    kept = [ln for ln in lines if not is_entry(ln) or ln.strip() in entries]
    present = {ln.strip() for ln in kept if is_entry(ln)}
    return kept + [e for e in entries if e not in present]


def write_config(path, lines):
    """Replace the file in one rename. A linked file is written where the link
    points, so the link (a dotfiles checkout) keeps working."""
    target = os.path.realpath(path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = f"{target}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("".join(line + "\n" for line in lines))
        os.replace(tmp, target)
    except OSError:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
