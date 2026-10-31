#!/usr/bin/env python3
"""Release end-to-end run of Mole CLI (Windows) on a real PC, driven from a Mac.

Over SSH with a real terminal (ssh -tt, ConPTY on the PC), it installs a
throwaway app (WinMerge's per-user setup, verified against its GitHub digest
and Authenticode signature), launches it, uninstalls it through `mo uninstall`
by searching and selecting it like a user, deletes its setup file from
`mo analyze`, then runs every other command read-only.

The candidate is this checkout's HEAD plus Go tools cross-built for the PC,
unpacked into a temporary folder; the PC's own Mole install is not touched.
Only the fixture app and its setup file are changed, clean, optimize and
purge run as dry runs, and the run refuses a PC that already has WinMerge.

The PC needs the OpenSSH server with this Mac's key; see "Windows e2e" in
AGENTS.md. Usage:
  scripts/e2e_windows.py --host user@address [--identity KEY] [--keep-going]
Report: ~/Library/Logs/mole-e2e/windows-<run>/report.json plus transcripts.
"""

import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_REPO = "WinMerge/winmerge"
FIXTURE_APP = "WinMerge"
FIXTURE_ASSET = re.compile(r"-x64-PerUser-Setup\.exe$")
DEFAULT_KEY = Path.home() / ".config/mole-e2e/id_ed25519"
ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>]")
# Written before the fixture setup runs, so --cleanup can tell an app this run
# installed from one the user installed.
MARKER = r"(Join-Path $env:LOCALAPPDATA 'mole-e2e\fixture.json')"
UNINSTALL_KEYS = r"""
$roots = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
         'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
         'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$entries = @(foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'WinMerge*' }
})
"""


class Refused(Exception):
    pass


class StepFailed(Exception):
    pass


def plain(data):
    return ANSI.sub(b"", data).decode("utf-8", "replace").replace("\r", "")


class Remote:
    def __init__(self, target, key, log_dir):
        self.target = target
        self.key = key
        self.known = key.parent / "known_hosts"
        self.log_dir = log_dir

    def ssh(self, tty=False):
        args = ["ssh", "-i", str(self.key), "-o", "IdentitiesOnly=yes",
                "-o", f"UserKnownHostsFile={self.known}", "-o", "StrictHostKeyChecking=accept-new",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30"]
        return args + (["-tt"] if tty else []) + [self.target]

    def ps(self, script, timeout=900):
        script = ("$ProgressPreference = 'SilentlyContinue'\n"
                  "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding\n"
                  "$OutputEncoding = [Console]::OutputEncoding\n" + script)
        encoded = base64.b64encode(script.encode("utf-16-le")).decode()
        return subprocess.run(self.ssh() + [f"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded}"],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=timeout)

    def ps_json(self, script, timeout=900):
        result = self.ps("& {\n" + script + "\n} | ConvertTo-Json -Compress -Depth 4", timeout)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        if result.returncode or not lines:
            raise StepFailed(f"remote script failed ({result.returncode}): {(result.stderr or result.stdout).strip()[-400:]}")
        return json.loads(lines[-1])

    def put(self, local, remote_path):
        dest = f"{self.target}:{remote_path.replace(chr(92), '/')}"
        result = subprocess.run(["scp", "-q", "-i", str(self.key), "-o", "IdentitiesOnly=yes",
                                 "-o", f"UserKnownHostsFile={self.known}", "-o", "BatchMode=yes",
                                 str(local), dest], capture_output=True, text=True, timeout=600)
        if result.returncode:
            raise StepFailed(f"scp failed: {result.stderr.strip()}")


class Terminal:
    """One remote command on a local pseudo-terminal carried by ssh -tt."""

    def __init__(self, argv, log_path, exit_token, cols=160, rows=48):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.buf = b""
        self.log_path = log_path
        self.exit_marker = f"MOLE_EXIT={exit_token}:"

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(argv, stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                     env=dict(os.environ, TERM="xterm-256color"), preexec_fn=own_terminal)

    def _pump(self, wait):
        if select.select([self.master], [], [], wait)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return False
            self.buf += chunk
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

    def send(self, data, settle=0.4):
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
        codes = re.findall(re.escape(self.exit_marker) + r"(-?\d+)(?:\n|$)", plain(self.buf))
        if not codes:
            raise StepFailed("terminal ended without this run's command status; inspect its transcript")
        code = int(codes[-1])
        if code:
            raise StepFailed(f"remote Mole command exited {code}")
        if self.proc.returncode:
            raise StepFailed(f"ssh exited {self.proc.returncode} after the command status")
        return 0

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


class Run:
    def __init__(self, args):
        self.id = time.strftime("%Y%m%d-%H%M%S")
        self.dir = Path.home() / "Library/Logs/mole-e2e" / f"windows-{self.id}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.remote = Remote(args.host, Path(args.identity).expanduser(), self.dir)
        self.keep_going = args.keep_going
        self.token = f"mole-e2e-{self.id}"
        self.steps = []
        self.failed = False
        self.info = {}
        self.setup = None
        self.install_location = None

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
        except (StepFailed, subprocess.SubprocessError, OSError, ValueError, KeyError) as exc:
            detail = str(exc) or type(exc).__name__
            status = "failed"
            self.failed = True
        seconds = round(time.monotonic() - start, 1)
        self.steps.append({"name": name, "status": status, "seconds": seconds, "detail": detail})
        print(f"  {'PASS' if status == 'passed' else 'FAIL'}  {name} ({seconds}s){': ' + detail if detail else ''}")
        return status == "passed"

    def log(self, name):
        return self.dir / f"{len(self.steps) + 1:02d}-{name}.log"

    def mole(self, *args, terminal=False):
        quoted = " ".join("'" + value.replace("'", "''") + "'" for value in (self.info["mole"], *args))
        # Only ASCII command syntax crosses the SSH shell. The inner process
        # retains -File parameter binding and its native exit status.
        script = ("$ErrorActionPreference = 'Stop'\n"
                  f"& powershell.exe -NoProfile -ExecutionPolicy Bypass -File {quoted}\n")
        if terminal:
            # Windows OpenSSH can return zero for every ConPTY command. Keep
            # the actual -File exit code in this run's transcript instead.
            script += ("$moleExit = $LASTEXITCODE\n"
                       "[Console]::Out.WriteLine('')\n"
                       f"[Console]::Out.WriteLine('MOLE_EXIT={self.token}:' + $moleExit)\n"
                       "exit $moleExit")
        else:
            script += "exit $LASTEXITCODE"
        encoded = base64.b64encode(script.encode("utf-16-le")).decode()
        return f"powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}"

    def oplog_offset(self):
        return self.remote.ps_json(r"""
$log = Join-Path $env:USERPROFILE '.config\mole\operations.log'
if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }""")

    def oplog_since(self, offset):
        result = self.remote.ps(rf"""
$log = Join-Path $env:USERPROFILE '.config\mole\operations.log'
if (Test-Path -LiteralPath $log) {{
    $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try {{ $null = $stream.Seek({offset}, 'Begin'); (New-Object IO.StreamReader($stream)).ReadToEnd() }} finally {{ $stream.Dispose() }}
}}""")
        return result.stdout


def preflight(run):
    info = run.remote.ps_json(UNINSTALL_KEYS + r"""
[pscustomobject]@{
    user = $env:USERNAME
    profile = $env:USERPROFILE
    temp = [IO.Path]::GetTempPath().TrimEnd('\')
    arch = $env:PROCESSOR_ARCHITECTURE
    os = (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [Environment]::OSVersion.Version
    installed = @($entries | ForEach-Object { $_.DisplayName })
    settings = Test-Path 'HKCU:\Software\Thingamahoochie\WinMerge'
    folder = Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\WinMerge')
    marker = Test-Path """ + MARKER + r"""
}""", timeout=120)
    if info["installed"] or info["folder"] or info["settings"]:
        if info["marker"]:
            raise Refused(f"an earlier e2e run left {FIXTURE_APP} on {run.remote.target}; rerun with --cleanup first")
        raise Refused(f"{FIXTURE_APP} or its settings already exist on {run.remote.target}; this run only removes what it installed")
    run.info.update(info)
    run.info["goarch"] = {"AMD64": "amd64", "ARM64": "arm64"}.get(info["arch"])
    if not run.info["goarch"]:
        raise Refused(f"unsupported architecture {info['arch']}")
    run.info["work"] = f"{info['temp']}\\mole-e2e-{run.id}"
    run.info["mole"] = f"{run.info['work']}\\mole\\mole.ps1"
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    run.info["commit"] = sha
    note = " (uncommitted changes are not deployed)" if dirty else ""
    return f"{info['user']} on {info['os']} {info['arch']}, candidate {sha}{note}"


def deploy(run):
    with tempfile.TemporaryDirectory(prefix="mole-e2e-") as tmp:
        bundle = Path(tmp) / "mole.zip"
        subprocess.run(["git", "archive", "--format=zip", "--prefix=mole/", "-o", str(bundle), run.info["commit"]], cwd=ROOT, check=True)
        # Build the source being deployed, not uncommitted Go files in ROOT.
        # The pinned archive also survives HEAD changing after preflight.
        with zipfile.ZipFile(bundle) as archive:
            archive.extractall(tmp)
        source = Path(tmp) / "mole"
        env = dict(os.environ, GOOS="windows", GOARCH=run.info["goarch"], CGO_ENABLED="0", GOWORK="off")
        with zipfile.ZipFile(bundle, "a") as archive:
            for tool in ("analyze", "status"):
                exe = Path(tmp) / f"{tool}.exe"
                build = subprocess.run(["go", "build", "-o", str(exe), f"./cmd/{tool}/"], cwd=source, env=env, capture_output=True, text=True)
                if build.returncode:
                    raise StepFailed(f"go build {tool} failed: {build.stderr.strip()[-300:]}")
                archive.write(exe, f"mole/bin/{tool}.exe")
        prepared = run.remote.ps(f"$ErrorActionPreference = 'Stop'; New-Item -ItemType Directory -Force -Path '{run.info['work']}' | Out-Null")
        if prepared.returncode:
            raise StepFailed(f"could not prepare candidate folder: {prepared.stderr.strip()[-300:]}")
        run.remote.put(bundle, f"{run.info['work']}\\mole.zip")
    unpacked = run.remote.ps_json(rf"""
$ErrorActionPreference = 'Stop'
Expand-Archive -LiteralPath '{run.info['work']}\mole.zip' -DestinationPath '{run.info['work']}' -Force
Test-Path -LiteralPath '{run.info['mole']}'""")
    if unpacked is not True:
        raise StepFailed("candidate entrypoint is missing after extraction")
    result = run.remote.ps(f"& {run.mole('--version')}")
    version = result.stdout.strip().splitlines()
    if result.returncode or not version:
        detail = (result.stderr or result.stdout).strip()[-400:]
        raise StepFailed(f"candidate version probe failed ({result.returncode}): {detail}")
    return f"{run.info['goarch']} tools, {version[0]}"


def latest_release():
    api = f"https://api.github.com/repos/{FIXTURE_REPO}/releases/latest"
    try:
        with urllib.request.urlopen(urllib.request.Request(api, headers={"Accept": "application/vnd.github+json"}), timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        # Anonymous API calls share the egress IP's 60/hour, which a proxy
        # exhausts; a signed-in gh has its own quota.
        if err.code not in (403, 429) or not shutil.which("gh"):
            raise
    result = subprocess.run(["gh", "api", f"repos/{FIXTURE_REPO}/releases/latest"], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise StepFailed(f"release lookup rate limited and gh api failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def download(run):
    release = latest_release()
    asset = next(a for a in release["assets"] if FIXTURE_ASSET.search(a["name"]))
    digest = (asset.get("digest") or "").removeprefix("sha256:")
    if not digest:
        raise StepFailed(f"{asset['name']} has no published sha256 digest")
    run.setup = f"{run.info['profile']}\\Downloads\\{FIXTURE_APP}-{run.token}-Setup.exe"
    result = run.remote.ps_json(rf"""
$out = '{run.setup}'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri '{asset['browser_download_url']}' -OutFile $out
$sig = Get-AuthenticodeSignature -LiteralPath $out
[pscustomobject]@{{ hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash; signature = [string]$sig.Status; signer = $sig.SignerCertificate.Subject }}""")
    if result["hash"].lower() != digest.lower():
        raise StepFailed(f"sha256 mismatch for {asset['name']}")
    if result["signature"] != "Valid":
        raise StepFailed(f"Authenticode status {result['signature']}")
    return f"{release['tag_name']} {asset['name']}, signed by {result['signer']}"


def install(run):
    result = run.remote.ps_json(rf"""
$marker = {MARKER}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
[pscustomobject]@{{ run = '{run.id}'; setup = '{run.setup}' }} | ConvertTo-Json | Set-Content -LiteralPath $marker
$p = Start-Process -FilePath '{run.setup}' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/CURRENTUSER' -Wait -PassThru
""" + UNINSTALL_KEYS + r"""
[pscustomobject]@{ exit = $p.ExitCode; names = @($entries | ForEach-Object { $_.DisplayName }); location = @($entries | ForEach-Object { $_.InstallLocation })[0] }""", timeout=600)
    if result["exit"] != 0 or not result["names"]:
        raise StepFailed(f"setup exited {result['exit']} and registered {result['names']}")
    run.install_location = (result["location"] or "").rstrip("\\")
    return f"{', '.join(result['names'])} at {run.install_location}"


def launch(run):
    result = run.remote.ps_json(rf"""
$exe = Get-ChildItem -LiteralPath '{run.install_location}' -Filter 'WinMerge*.exe' | Select-Object -First 1
$p = Start-Process -FilePath $exe.FullName -PassThru
Start-Sleep -Seconds 8
$alive = -not $p.HasExited
if ($alive) {{ $p | Stop-Process -Force -ErrorAction SilentlyContinue }}
Start-Sleep -Seconds 1
[pscustomobject]@{{ ran = $alive; settings = Test-Path 'HKCU:\Software\Thingamahoochie\WinMerge' }}""")
    if not result["ran"]:
        raise StepFailed(f"{FIXTURE_APP} exited right after launch")
    run.info["settings_after_launch"] = result["settings"]
    return "ran 8s" + (", wrote its settings" if result["settings"] else "")


def uninstall(run):
    offset = run.oplog_offset()
    term = Terminal(run.remote.ssh(tty=True) + [run.mole("uninstall", terminal=True)], run.log("uninstall"), run.token)
    try:
        term.expect(r"Select Applications to Uninstall", 300)
        term.send(b"/")
        term.expect(r"Search:", 15)
        term.send(FIXTURE_APP.encode() + b"\r", settle=1)
        matches = term.expect(r"Search:\s*" + FIXTURE_APP + r" \((\d+) matches\)", 30).group(1)
        if matches != "1":
            term.send(b"q")
            raise StepFailed(f"search matched {matches} apps; quit without selecting")
        term.send(b" ")
        term.expect(r"Selected:\s*1 app\b", 15)
        mark = len(term.buf)
        term.send(b"\r")
        term.expect(r"Continue\? \(y/N\)", 60, since=mark)
        listed = plain(term.buf[mark:])
        if FIXTURE_APP not in listed:
            term.send(b"n\r")
            raise StepFailed("the confirmation does not list the fixture; cancelled")
        term.send(b"y\r")
        outcome = term.expect(r"Uninstall (complete|incomplete)", 600, since=mark).group(1)
        term.finish(60)
    finally:
        term.close()
    if outcome != "complete":
        raise StepFailed("mo uninstall reported an incomplete uninstall")
    state = run.remote.ps_json(UNINSTALL_KEYS + rf"""
[pscustomobject]@{{ entries = @($entries).Count; folder = Test-Path -LiteralPath '{run.install_location}'; settings = Test-Path 'HKCU:\Software\Thingamahoochie\WinMerge' }}""")
    if state["entries"]:
        raise StepFailed("the uninstall registry entry is still there")
    if state["folder"]:
        raise StepFailed(f"{run.install_location} is still there")
    rows = run.oplog_since(offset)
    if "UNINSTALLED" not in rows or FIXTURE_APP not in rows:
        raise StepFailed("operations.log has no UNINSTALLED row for the fixture")
    run.info["settings_after_uninstall"] = state["settings"]
    note = ", its HKCU settings stay (Windows uninstall removes only the install folder)" if state["settings"] else ""
    return "registry entry and install folder gone" + note


def history(run):
    result = run.remote.ps(f"& {run.mole('history')}")
    if result.returncode or FIXTURE_APP not in plain(result.stdout.encode()):
        raise StepFailed("mo history does not show the uninstall")


def analyze(run):
    offset = run.oplog_offset()
    name = run.setup.rsplit("\\", 1)[1]
    term = Terminal(run.remote.ssh(tty=True) + [run.mole("analyze", f"{run.info['profile']}\\Downloads", terminal=True)], run.log("analyze"), run.token)
    try:
        term.expect(re.escape(name[:40]), 300)
        quiet_since = time.monotonic()
        deadline = quiet_since + 300
        while time.monotonic() - quiet_since < 3:
            if time.monotonic() > deadline:
                raise StepFailed("the Downloads scan never finished")
            mark = len(term.buf)
            term._pump(0.2)
            if "Scanning" in plain(term.buf[mark:]):
                quiet_since = time.monotonic()
        term.send(b"/")
        term.send(run.token.encode(), settle=0.8)
        term.send(b"\r")
        term.expect(r"Filter: " + re.escape(run.token) + r"\s+\(1 matches\)", 20)
        mark = len(term.buf)
        term.send(b"\x1b[3~")
        confirm = term.expect(r"Delete: ([^\n]*?), ", 20, since=mark).group(1)
        if run.token not in confirm:
            term.send(b"\x1b")
            raise StepFailed(f"the delete prompt targets {confirm!r}; cancelled")
        term.send(b"\r", settle=2)
        deadline = time.monotonic() + 60
        while run.remote.ps_json(f"Test-Path -LiteralPath '{run.setup}'"):
            if time.monotonic() > deadline:
                raise StepFailed("the setup file is still in Downloads")
            term._pump(1)
        term.send(b"q", settle=1)
        term.finish(30)
    finally:
        term.close()
    rows = run.oplog_since(offset)
    if run.token not in rows:
        raise StepFailed("operations.log has no row for the setup file")
    action = re.search(r"\] (\w+) [^\n]*" + re.escape(run.token), rows)
    return f"{name} {action.group(1) if action else 'logged'}"


SMOKE = [
    (["--version"], r"\d+\.\d+"),
    (["--help"], r"mo clean"),
    *[([cmd, "--help"], r"\S") for cmd in (
        "clean", "uninstall", "analyze", "status", "optimize", "purge", "history", "update", "remove")],
    (["history"], r"\S"),
    (["clean", "--dry-run"], r"Dry run"),
    (["optimize", "--dry-run"], r"\S"),
    (["purge", "--dry-run"], r"\S"),
]


def smoke(run):
    failures, log = [], []
    for args, pattern in SMOKE:
        result = run.remote.ps(f"& {run.mole(*args)} 2>&1 | Out-String -Width 200; 'MOLE_EXIT=' + $LASTEXITCODE")
        out = plain(result.stdout.encode())
        code = re.search(r"MOLE_EXIT=(-?\d*)", out)
        code = int(code.group(1)) if code and code.group(1) else -999
        log.append(f"$ mo {' '.join(args)}  (exit {code})\n{out}\n")
        if code != 0:
            failures.append(f"mo {' '.join(args)} exited {code}")
        elif not re.search(pattern, out.split("MOLE_EXIT=")[0]):
            failures.append(f"mo {' '.join(args)} printed no {pattern!r}")
    run.log("smoke").write_text("\n".join(log))
    if failures:
        raise StepFailed("; ".join(failures))
    return f"{len(SMOKE)} commands"


def cleanup(run):
    state = run.remote.ps_json(UNINSTALL_KEYS + rf"""
Remove-Item -LiteralPath '{run.info['work']}' -Recurse -Force -ErrorAction SilentlyContinue
[pscustomobject]@{{
    entries = @($entries | ForEach-Object {{ $_.DisplayName }})
    folder = $(if ('{run.install_location or ''}') {{ Test-Path -LiteralPath '{run.install_location or 'C:\\nonexistent'}' }} else {{ $false }})
    setup = $(if ('{run.setup or ''}') {{ Test-Path -LiteralPath '{run.setup or 'C:\\nonexistent'}' }} else {{ $false }})
    work = Test-Path -LiteralPath '{run.info['work']}'
}}""")
    left = list(state["entries"])
    if state["folder"]:
        left.append(run.install_location)
    if state["setup"]:
        left.append(run.setup)
    if not left:
        run.remote.ps(f"Remove-Item -LiteralPath {MARKER} -ErrorAction SilentlyContinue")
    if state["work"]:
        left.append(run.info["work"])
    return left


def reclaim(remote):
    """Remove a fixture an earlier run left behind, only when its marker exists."""
    return remote.ps_json(rf"""
$marker = {MARKER}
if (-not (Test-Path -LiteralPath $marker)) {{ return [pscustomobject]@{{ marker = $false; left = @() }} }}
$m = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json
{UNINSTALL_KEYS}
foreach ($e in $entries) {{
    if ($e.UninstallString -match '^"?([^"]+\.exe)"?') {{
        Start-Process -FilePath $Matches[1] -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait
    }}
}}
Start-Sleep -Seconds 2
# Preflight refused any PC that already had these settings, so the run wrote them.
Remove-Item -LiteralPath 'HKCU:\Software\Thingamahoochie\WinMerge' -Recurse -ErrorAction SilentlyContinue
if (-not (Get-ChildItem -LiteralPath 'HKCU:\Software\Thingamahoochie' -ErrorAction SilentlyContinue)) {{
    Remove-Item -LiteralPath 'HKCU:\Software\Thingamahoochie' -ErrorAction SilentlyContinue
}}
if ($m.setup -and (Test-Path -LiteralPath $m.setup)) {{ Remove-Item -LiteralPath $m.setup -Force }}
{UNINSTALL_KEYS}
$left = @($entries | ForEach-Object {{ $_.DisplayName }})
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\WinMerge')) {{ $left += (Join-Path $env:LOCALAPPDATA 'Programs\WinMerge') }}
if (-not $left) {{ Remove-Item -LiteralPath $marker }}
[pscustomobject]@{{ marker = $true; run = $m.run; left = $left }}""", timeout=600)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--host", required=True, help="ssh target, user@address")
    parser.add_argument("--identity", default=str(DEFAULT_KEY), help="ssh private key")
    parser.add_argument("--keep-going", action="store_true", help="continue independent checks after a failure")
    parser.add_argument("--cleanup", action="store_true", help="remove the fixture an earlier run left, then exit")
    args = parser.parse_args()
    run = Run(args)
    if args.cleanup:
        result = reclaim(run.remote)
        if not result["marker"]:
            print("No fixture marker on the PC; nothing an e2e run installed is left.")
            sys.exit(0)
        print(f"Cleaned the fixture from run {result['run']}" + (f"; still left: {', '.join(result['left'])}" if result["left"] else ""))
        sys.exit(1 if result["left"] else 0)
    print(f"Mole Windows e2e {run.id} on {run.remote.target}, report in {run.dir}")
    try:
        run.step("preflight", lambda: preflight(run))
    except Refused as exc:
        print(f"  REFUSED  {exc}")
        sys.exit(2)
    if run.failed:
        sys.exit(1)
    deployed = run.step("deploy candidate", lambda: deploy(run))
    # Failed deployment or integrity checks cannot authorize later mutations.
    # Keep the setup file if uninstall failed, so recovery retains its fixture.
    downloaded = run.step("download fixture", lambda: download(run), ready=deployed)
    installed = run.step("install fixture", lambda: install(run), ready=downloaded)
    launched = run.step("launch fixture", lambda: launch(run), ready=installed)
    removed = run.step("mo uninstall", lambda: uninstall(run), ready=launched)
    run.step("mo history", lambda: history(run), ready=removed)
    run.step("mo analyze delete", lambda: analyze(run), ready=removed)
    run.step("smoke commands", lambda: smoke(run), ready=deployed)
    left = cleanup(run) if run.info.get("work") else []
    report = {"run": run.id, "host": run.remote.target, "info": run.info, "steps": run.steps, "not_cleaned_up": left}
    (run.dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    passed = sum(s["status"] == "passed" for s in run.steps)
    print(f"{passed}/{len(run.steps)} steps passed")
    if left:
        print("Left on the PC: " + ", ".join(left))
    sys.exit(1 if run.failed else 0)


if __name__ == "__main__":
    main()
