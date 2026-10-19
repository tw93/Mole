#!/usr/bin/env python3
"""Release end-to-end run of Mole CLI (macOS) on a real Mac, driven like a user.

Installs a throwaway app (IINA, verified against its GitHub digest and Apple
notarization), launches it so it writes real leftovers, uninstalls it with
`mo uninstall` through a real terminal, finds its DMG with `mo installer` and
deletes it from `mo analyze`, then runs every other command read-only.

Only the fixture app, its leftovers and its DMG are changed; clean, optimize,
purge and the rest run as dry runs, and nothing asks for a password. The run
refuses to start when the Mac already has the fixture app or any of its data,
so it never removes something the user owns. Removed items go to the Trash.

Usage: scripts/e2e_macos.py [--skip-build] [--keep-going]
Report: ~/Library/Logs/mole-e2e/<run>/report.json plus one transcript per step.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MOLE = ROOT / "mole"
HOME = Path.home()
FIXTURE_REPO = "iina/iina"
FIXTURE_APP = "IINA"
FIXTURE_BUNDLE = "com.colliderli.iina"
APP_PATH = Path("/Applications") / f"{FIXTURE_APP}.app"
OPLOG = HOME / "Library/Logs/mole/operations.log"
TRASH = HOME / ".Trash"
LEFTOVER_ROOTS = [
    "Library/Preferences", "Library/Application Support", "Library/Caches",
    "Library/HTTPStorages", "Library/Saved Application State", "Library/WebKit",
    "Library/Containers", "Library/Group Containers", "Library/Logs",
    "Library/Cookies", "Library/LaunchAgents",
]
ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>]")
PASSWORD = re.compile(rb"Password:|password for ", re.I)


class Refused(Exception):
    """The Mac is not in a state where the run can change anything safely."""


class StepFailed(Exception):
    pass


def plain(data):
    return ANSI.sub(b"", data).decode("utf-8", "replace").replace("\r", "")


def run_env():
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("MOLE_TEST") and k not in ("MO_NO_OPLOG", "MOLE_DRY_RUN")}
    env["TERM"] = "xterm-256color"
    return env


class Terminal:
    """One command on its own pseudo-terminal, read like a user would."""

    def __init__(self, argv, log_path, cols=160, rows=48):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.buf = b""
        self.log_path = log_path

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(argv, cwd=ROOT, stdin=self.slave, stdout=self.slave,
                                     stderr=self.slave, env=run_env(), preexec_fn=own_terminal)

    def _pump(self, wait):
        if select.select([self.master], [], [], wait)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return False
            self.buf += chunk
            if PASSWORD.search(chunk):
                raise StepFailed("asked for a password; the run must stay unattended")
            return bool(chunk)
        return False

    def expect(self, pattern, timeout, since=0):
        regex = re.compile(pattern)
        deadline = time.monotonic() + timeout
        while True:
            match = regex.search(plain(self.buf[since:]))
            if match:
                return match
            if time.monotonic() > deadline:
                raise StepFailed(f"timed out after {timeout}s waiting for {pattern!r}")
            if not self._pump(0.05) and self.proc.poll() is not None:
                self._pump(0.2)
                match = regex.search(plain(self.buf[since:]))
                if match:
                    return match
                raise StepFailed(f"exited {self.proc.returncode} before {pattern!r}")

    def wait_for_key_read(self, timeout=15):
        # Bash prompts drain pending input and then read with echo off; a key
        # sent before that would be drained on purpose.
        deadline = time.monotonic() + timeout
        while termios.tcgetattr(self.slave)[3] & termios.ECHO:
            if time.monotonic() > deadline:
                raise StepFailed("the prompt never started reading a key")
            self._pump(0.02)
        self._pump(0.1)

    def send(self, data, settle=0.15):
        os.write(self.master, data)
        end = time.monotonic() + settle
        while time.monotonic() < end:
            self._pump(0.02)

    def finish(self, timeout):
        deadline = time.monotonic() + timeout
        while self.proc.poll() is None:
            if time.monotonic() > deadline:
                raise StepFailed(f"still running after {timeout}s")
            self._pump(0.05)
        while self._pump(0.05):
            pass
        return self.proc.returncode

    def close(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait(timeout=5)
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass
        self.log_path.write_text(plain(self.buf))

    def text(self):
        return plain(self.buf)


class Run:
    def __init__(self, keep_going):
        self.id = time.strftime("%Y%m%d-%H%M%S")
        self.dir = HOME / "Library/Logs/mole-e2e" / self.id
        self.dir.mkdir(parents=True, exist_ok=True)
        self.keep_going = keep_going
        self.steps = []
        self.token = f"mole-e2e-{self.id}"
        self.started = time.strftime("%Y-%m-%d %H:%M:%S")
        self.dmg = None
        self.leftovers = []
        self.failed = False

    def step(self, name, func, ready=True):
        if not ready or (self.failed and not self.keep_going):
            detail = "a required step did not pass" if not ready else "an earlier step failed"
            self.steps.append({"name": name, "status": "skipped", "detail": detail})
            print(f"  SKIP  {name}")
            return False
        start = time.monotonic()
        try:
            detail = func() or ""
            status = "passed"
        except Refused:
            raise
        except (StepFailed, subprocess.SubprocessError, OSError, ValueError, AssertionError) as exc:
            detail = str(exc) or type(exc).__name__
            status = "failed"
            self.failed = True
        seconds = round(time.monotonic() - start, 1)
        self.steps.append({"name": name, "status": status, "seconds": seconds, "detail": detail})
        print(f"  {'PASS' if status == 'passed' else 'FAIL'}  {name} ({seconds}s){': ' + detail if detail else ''}")
        return status == "passed"

    def log(self, name):
        return self.dir / f"{len(self.steps) + 1:02d}-{name}.log"


def capture(argv, timeout=600, **kwargs):
    return subprocess.run(argv, cwd=ROOT, env=run_env(), stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=timeout, **kwargs)


def fixture_traces():
    """Every path under the user Library that names the fixture app."""
    found = []
    needles = (FIXTURE_BUNDLE.lower(), FIXTURE_APP.lower())
    for rel in LEFTOVER_ROOTS:
        root = HOME / rel
        try:
            entries = list(root.iterdir())
        except OSError:
            continue
        for entry in entries:
            name = entry.name.lower()
            if name.startswith(needles[0]) or name in (needles[1], needles[1] + ".plist"):
                found.append(str(entry))
    return sorted(found)


def fixture_pids():
    out = capture(["/usr/bin/pgrep", "-f", f"{APP_PATH}/Contents/MacOS/"]).stdout
    return [int(p) for p in out.split()]


def oplog_size():
    try:
        return OPLOG.stat().st_size
    except OSError:
        return 0


def oplog_since(offset):
    try:
        with OPLOG.open("rb") as handle:
            handle.seek(offset)
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return ""


def trashed(prefix):
    try:
        return sorted(p.name for p in TRASH.iterdir() if p.name.startswith(prefix))
    except OSError as exc:
        raise StepFailed(f"cannot read the Trash ({exc}); grant Full Disk Access to this terminal") from exc


def preflight(run):
    if not MOLE.is_file():
        raise Refused(f"{MOLE} not found")
    if APP_PATH.exists() or fixture_pids():
        raise Refused(f"{APP_PATH} already exists or runs; this run only removes an app it installed")
    hits = capture(["/usr/bin/mdfind", f"kMDItemCFBundleIdentifier == '{FIXTURE_BUNDLE}'"]).stdout.split("\n")
    hits = [h for h in hits if h and "/.Trash/" not in h]
    if hits:
        raise Refused(f"{FIXTURE_APP} is installed at {hits[0]}; pick another Mac or remove it first")
    traces = fixture_traces()
    if traces:
        raise Refused(f"this Mac already has {FIXTURE_APP} data ({traces[0]}); the uninstall would remove it")
    sha = capture(["git", "rev-parse", "--short", "HEAD"]).stdout.strip()
    dirty = bool(capture(["git", "status", "--porcelain"]).stdout.strip())
    version = capture([str(MOLE), "--version"]).stdout.split("\n")
    return f"{sha}{' (dirty)' if dirty else ''}, {' '.join(v for v in version if v).strip()}"


def build(run):
    result = capture(["make", "build"], timeout=900)
    run.log("build").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise StepFailed(f"make build exited {result.returncode}")


def download(run):
    api = f"https://api.github.com/repos/{FIXTURE_REPO}/releases/latest"
    with urllib.request.urlopen(urllib.request.Request(api, headers={"Accept": "application/vnd.github+json"}), timeout=30) as resp:
        release = json.load(resp)
    asset = next(a for a in release["assets"] if a["name"].endswith(".dmg"))
    digest = asset.get("digest") or ""
    if not digest.startswith("sha256:"):
        raise StepFailed(f"{asset['name']} has no published sha256 digest")
    run.dmg = HOME / "Downloads" / f"{FIXTURE_APP}-{run.token}.dmg"
    sha = hashlib.sha256()
    with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as resp, run.dmg.open("wb") as out:
        for chunk in iter(lambda: resp.read(1 << 20), b""):
            sha.update(chunk)
            out.write(chunk)
    if sha.hexdigest() != digest.split(":", 1)[1]:
        raise StepFailed(f"sha256 mismatch for {asset['name']}")
    return f"{release['tag_name']} {asset['name']} -> {run.dmg.name}"


def install(run):
    mount = Path(tempfile.mkdtemp(prefix="mole-e2e-mnt-"))
    attach = capture(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen",
                      "-mountpoint", str(mount), str(run.dmg)])
    if attach.returncode:
        raise StepFailed(f"hdiutil attach failed: {attach.stderr.strip()}")
    try:
        source = mount / f"{FIXTURE_APP}.app"
        verify = capture(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)])
        if verify.returncode:
            raise StepFailed(f"codesign rejected the app: {verify.stderr.strip()}")
        assess = capture(["/usr/sbin/spctl", "--assess", "--type", "execute", str(source)])
        if assess.returncode:
            raise StepFailed(f"Gatekeeper rejected the app: {assess.stderr.strip()}")
        copy = capture(["/usr/bin/ditto", str(source), str(APP_PATH)])
        if copy.returncode:
            raise StepFailed(f"ditto failed: {copy.stderr.strip()}")
    finally:
        capture(["/usr/bin/hdiutil", "detach", str(mount), "-force"])
        os.rmdir(mount)
    team = re.search(r"TeamIdentifier=(\S+)", capture(["/usr/bin/codesign", "-dv", str(APP_PATH)]).stderr)
    return f"installed {APP_PATH}, notarized, team {team.group(1) if team else 'unknown'}"


def launch(run):
    capture(["/usr/bin/open", "-g", str(APP_PATH)])
    deadline = time.monotonic() + 30
    while not fixture_pids():
        if time.monotonic() > deadline:
            raise StepFailed(f"{FIXTURE_APP} never started")
        time.sleep(0.5)
    time.sleep(10)
    for pid in fixture_pids():
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while fixture_pids():
        if time.monotonic() > deadline:
            for pid in fixture_pids():
                os.kill(pid, signal.SIGKILL)
            break
        time.sleep(0.5)
    time.sleep(2)
    run.leftovers = fixture_traces()
    if not run.leftovers:
        raise StepFailed(f"{FIXTURE_APP} left nothing behind, so the uninstall has nothing to prove")
    return f"{len(run.leftovers)} leftovers: " + ", ".join(Path(p).name for p in run.leftovers)


def uninstall(run):
    offset = oplog_size()
    term = Terminal([str(MOLE), "uninstall", FIXTURE_APP], run.log("uninstall"))
    try:
        term.expect(r"Matched \d+ app", 180)
        matched = term.expect(r"Matched (\d+) app", 1).group(1)
        term.expect(r"ESC cancel:", 300)
        if matched != "1" or str(APP_PATH) not in term.text():
            term.wait_for_key_read()
            term.send(b"\x1b")
            raise StepFailed(f"preview matched {matched} apps or did not list {APP_PATH}; cancelled")
        # Personal data is kept by default; review it and take all of it, the
        # way a user removing an app for good would.
        term.wait_for_key_read()
        mark = len(term.buf)
        term.send(b"d")
        term.expect(r"Q Cancel", 15, since=mark)
        term.send(b"a", settle=0.3)
        term.expect(r"(\d+)/\1 selected", 15, since=mark)
        mark = len(term.buf)
        term.send(b"\r", settle=0.3)
        term.expect(r"ESC cancel:", 60, since=mark)
        if "Personal data kept" in plain(term.buf[mark:]):
            term.wait_for_key_read()
            term.send(b"\x1b")
            raise StepFailed("selecting all personal data still kept some; cancelled")
        term.wait_for_key_read()
        term.send(b"\r")
        rc = term.finish(300)
    finally:
        term.close()
    if rc != 0:
        raise StepFailed(f"mo uninstall exited {rc}")
    if APP_PATH.exists():
        raise StepFailed(f"{APP_PATH} is still there")
    remaining = [p for p in fixture_traces() if p in run.leftovers]
    if remaining:
        raise StepFailed("leftovers kept: " + ", ".join(remaining))
    if f"{FIXTURE_APP}.app" not in " ".join(trashed(FIXTURE_APP)):
        raise StepFailed("the app is not in the Trash")
    rows = oplog_since(offset)
    if str(APP_PATH) not in rows:
        raise StepFailed("operations.log has no row for the app")
    return f"app and {len(run.leftovers)} leftovers moved to the Trash, {rows.count(chr(10))} log rows"


def history(run):
    result = capture([str(MOLE), "history", "--json", "--limit", "50"])
    if result.returncode:
        raise StepFailed(f"mo history --json exited {result.returncode}")
    sessions = json.loads(result.stdout).get("sessions", [])
    if not any(s.get("command") == "uninstall" and s.get("started_at", "") >= run.started
               and s.get("actions", {}).get("trashed", 0) > 0 for s in sessions):
        raise StepFailed("mo history --json has no uninstall from this run that moved items to the Trash")
    text = capture([str(MOLE), "history", "--limit", "20"])
    if text.returncode or FIXTURE_APP not in text.stdout:
        raise StepFailed("mo history text does not show the uninstall")


def installer(run):
    term = Terminal([str(MOLE), "installer", "--dry-run"], run.log("installer"), cols=220)
    try:
        term.expect(r"Q Quit", 300)
        found = run.dmg.name in term.text()
        term.send(b"q")
        rc = term.finish(30)
    finally:
        term.close()
    if not found:
        raise StepFailed(f"{run.dmg.name} is not listed")
    if rc != 0:
        raise StepFailed(f"mo installer --dry-run exited {rc}")
    if not run.dmg.exists():
        raise StepFailed("a dry run removed the DMG")


def analyze(run):
    offset = oplog_size()
    term = Terminal([str(MOLE), "analyze", str(HOME / "Downloads")], run.log("analyze"))
    try:
        # The scan is done once the "Scanning:" line stops being redrawn.
        term.expect(re.escape(run.dmg.name), 300)
        quiet_since = time.monotonic()
        deadline = quiet_since + 300
        while time.monotonic() - quiet_since < 3:
            if time.monotonic() > deadline:
                raise StepFailed("the Downloads scan never finished")
            mark = len(term.buf)
            term._pump(0.2)
            if "Scanning:" in plain(term.buf[mark:]):
                quiet_since = time.monotonic()
        term.send(b"/")
        term.send(run.token.encode(), settle=0.5)
        term.send(b"\r")
        term.expect(r"Filter: " + re.escape(run.token) + r"\s+\(1 matches\)", 15)
        mark = len(term.buf)
        term.send(b"\x7f")
        confirm = term.expect(r"Delete: ([^\n]*?), ", 15, since=mark).group(1)
        if run.token not in confirm:
            term.send(b"\x1b")
            raise StepFailed(f"the delete prompt targets {confirm!r}; cancelled")
        term.send(b"\r")
        deadline = time.monotonic() + 60
        while run.dmg.exists():
            if time.monotonic() > deadline:
                raise StepFailed("the DMG is still in Downloads")
            term._pump(0.2)
        term.send(b"q", settle=0.5)
        rc = term.finish(30)
    finally:
        term.close()
    if rc != 0:
        raise StepFailed(f"mo analyze exited {rc}")
    if run.dmg.name not in trashed(run.dmg.stem):
        raise StepFailed("the DMG is not in the Trash")
    if run.dmg.name not in oplog_since(offset):
        raise StepFailed("operations.log has no row for the DMG")
    return f"{run.dmg.name} moved to the Trash"


SMOKE = [
    (["--version"], r"Mole version"),
    (["--help"], r"Usage|COMMANDS|Commands"),
    *[([cmd, "--help"], r"Usage") for cmd in (
        "clean", "uninstall", "analyze", "status", "optimize", "purge", "installer",
        "history", "completion", "touchid", "update", "remove")],
    (["status", "--json"], None),
    (["uninstall", "--list"], r"\S"),
    (["completion", "--dry-run"], r"\S"),
    (["remove", "--dry-run"], r"\S"),
    (["touchid", "status"], r"Touch ID"),
    (["optimize", "--dry-run"], r"\S"),
    (["purge", "--dry-run"], r"\S"),
    (["clean", "--dry-run"], r"Dry run complete"),
]


def smoke(run):
    failures = []
    log = []
    for args, pattern in SMOKE:
        try:
            result = capture([str(MOLE), *args], timeout=900)
            out = result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            failures.append(f"mo {' '.join(args)} timed out")
            continue
        log.append(f"$ mo {' '.join(args)}  (exit {result.returncode})\n{plain(out.encode())}\n")
        if result.returncode != 0:
            failures.append(f"mo {' '.join(args)} exited {result.returncode}")
        elif PASSWORD.search(out.encode()):
            failures.append(f"mo {' '.join(args)} asked for a password")
        elif args == ["status", "--json"]:
            json.loads(result.stdout)
        elif pattern and not re.search(pattern, plain(out.encode())):
            failures.append(f"mo {' '.join(args)} printed no {pattern!r}")
    analyze_json = capture([str(MOLE), "analyze", "--json", str(ROOT / "docs")])
    log.append(f"$ mo analyze --json docs  (exit {analyze_json.returncode})\n")
    try:
        json.loads(analyze_json.stdout)
    except ValueError:
        failures.append("mo analyze --json printed invalid JSON")
    run.log("smoke").write_text("\n".join(log))
    if failures:
        raise StepFailed("; ".join(failures))
    return f"{len(SMOKE) + 1} commands"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--skip-build", action="store_true", help="use the existing bin/*-go builds")
    parser.add_argument("--keep-going", action="store_true", help="continue independent checks after a failure")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        sys.exit("macOS only")
    run = Run(args.keep_going)
    print(f"Mole e2e {run.id}, report in {run.dir}")
    try:
        ready = run.step("preflight", lambda: preflight(run))
    except Refused as exc:
        print(f"  REFUSED  {exc}")
        sys.exit(2)
    if not args.skip_build:
        ready = run.step("build", lambda: build(run), ready=ready)
    # A failed digest or install is never permission for the next mutation,
    # even with --keep-going. Keep the fixture when uninstall did not finish.
    downloaded = run.step("download fixture", lambda: download(run), ready=ready)
    installed = run.step("install fixture", lambda: install(run), ready=downloaded)
    launched = run.step("launch fixture", lambda: launch(run), ready=installed)
    removed = run.step("mo uninstall", lambda: uninstall(run), ready=launched)
    run.step("mo history", lambda: history(run), ready=removed)
    run.step("mo installer --dry-run", lambda: installer(run), ready=downloaded)
    run.step("mo analyze delete", lambda: analyze(run), ready=removed)
    run.step("smoke commands", lambda: smoke(run), ready=ready)

    leftover = [str(APP_PATH)] if APP_PATH.exists() else []
    leftover += fixture_traces()
    if run.dmg and run.dmg.exists():
        leftover.append(str(run.dmg))
    report = {
        "run": run.id, "macos": platform.mac_ver()[0], "arch": platform.machine(),
        "steps": run.steps, "not_cleaned_up": leftover,
    }
    (run.dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    passed = sum(s["status"] == "passed" for s in run.steps)
    print(f"{passed}/{len(run.steps)} steps passed")
    if leftover:
        print("Left on this Mac: " + ", ".join(leftover))
    sys.exit(1 if run.failed else 0)


if __name__ == "__main__":
    main()
