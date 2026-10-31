"""Mock-only tests of the Mac-hosted Windows release runner."""

from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "e2e_windows", Path(__file__).resolve().parents[1] / "scripts/e2e_windows.py")
E2E = importlib.util.module_from_spec(SPEC)
# Windows CI exercises orchestration, never the Unix terminal implementation.
with patch.dict("sys.modules", {name: Mock() for name in ("fcntl", "pty", "termios")}):
    SPEC.loader.exec_module(E2E)


class RemoteTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "remote PowerShell runs in Windows Validation")
    def test_candidate_command_uses_executable_despite_a_bare_name_collision(self):
        shell = shutil.which("powershell.exe")
        self.assertIsNotNone(shell)
        with tempfile.TemporaryDirectory() as tmp:
            entry = Path(tmp) / "mole.ps1"
            entry.write_text('param([switch]$Version)\nWrite-Output "MOLE_FIXTURE:$Version"\n')
            run = object.__new__(E2E.Run)
            run.info = {"mole": str(entry)}
            script = "$ErrorActionPreference = 'Stop'\nfunction powershell { throw 'bare shell collision' }\n& " + run.mole("--version")
            encoded = E2E.base64.b64encode(script.encode("utf-16-le")).decode()
            result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "MOLE_FIXTURE:True")

    @unittest.skipUnless(os.name == "nt", "remote PowerShell runs in Windows Validation")
    def test_remote_output_survives_a_chinese_console_code_page(self):
        shell = shutil.which("powershell.exe")
        self.assertIsNotNone(shell)
        remote = object.__new__(E2E.Remote)
        remote.ssh = Mock(return_value=["mock-ssh"])
        native_run = subprocess.run

        def local_transport(argv, **kwargs):
            # Execute the actual generated remote script under a legacy code
            # page, without SSH or changing the machine's locale.
            encoded = argv[-1].rsplit(" ", 1)[1]
            script = "[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936)\n" + E2E.base64.b64decode(encoded).decode("utf-16-le")
            encoded = E2E.base64.b64encode(script.encode("utf-16-le")).decode()
            return native_run([shell, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], **kwargs)

        with patch.object(E2E.subprocess, "run", side_effect=local_transport):
            result = remote.ps("Write-Output '\u4e2d\u6587'", timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "\u4e2d\u6587")

    @unittest.skipUnless(os.name == "nt", "remote PowerShell runs in Windows Validation")
    def test_terminal_shells_preserve_literal_paths_arguments_and_exit_codes(self):
        powershell = shutil.which("powershell.exe")
        cmd = shutil.which("cmd.exe")
        self.assertIsNotNone(powershell)
        self.assertIsNotNone(cmd)
        values = ["plain", "two words", "O'Brien", "$env:USERNAME", "100%PATH%", "a`b", "semi; & | (x)", "tail\\"]
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "Bob's tools $cash & 100% path"
            folder.mkdir()
            entry = folder / "mole fixture.ps1"
            entry.write_text('param([int]$Code, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Values)\n'
                             'ConvertTo-Json -InputObject @($Values) -Compress\nexit $Code\n')
            run = object.__new__(E2E.Run)
            run.info = {"mole": str(entry)}
            run.token = "fixture-command-status"
            for shell, prefix in (("cmd", [cmd, "/d", "/s", "/c"]),
                                  ("powershell", [powershell, "-NoProfile", "-NonInteractive", "-Command"])):
                for code in (0, 37):
                    with self.subTest(shell=shell, code=code):
                        result = subprocess.run(prefix + [run.mole(str(code), *values, terminal=True)],
                                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
                        # PowerShell's -Command shell maps a nonzero native exit
                        # to 1; the per-run marker must retain the original code.
                        self.assertEqual(result.returncode, code if shell == "cmd" else int(code != 0), result.stderr)
                        lines = [line for line in result.stdout.splitlines() if line.strip()]
                        self.assertEqual(json.loads(lines[0]), values)
                        self.assertEqual(lines[-1], f"MOLE_EXIT={run.token}:{code}")


class TerminalTests(unittest.TestCase):
    def terminal(self, output, transport_code=0):
        term = object.__new__(E2E.Terminal)
        term.exit_marker = "MOLE_EXIT=current-run:"
        term.buf = output.encode()
        term.proc = Mock(returncode=transport_code)
        term.proc.poll.return_value = transport_code
        term._pump = Mock(return_value=False)
        return term

    def test_finish_requires_this_runs_marker_not_ssh_success(self):
        for output in ("", "MOLE_EXIT=old-run:0\n", "MOLE_EXIT=current-run:unknown\n"):
            with self.subTest(output=output):
                with self.assertRaisesRegex(E2E.StepFailed, "without this run's command status"):
                    self.terminal(output).finish(1)
        self.assertEqual(self.terminal("MOLE_EXIT=old-run:37\nMOLE_EXIT=current-run:0\n").finish(1), 0)
        # ConPTY can encode a preceding newline as a cursor move, which plain()
        # strips; the completion marker can follow earlier output directly.
        self.assertEqual(self.terminal("previous outputMOLE_EXIT=current-run:0\n").finish(1), 0)

    def test_finish_rejects_actual_failure_even_when_ssh_returns_zero(self):
        with self.assertRaisesRegex(E2E.StepFailed, "exited 37"):
            self.terminal("MOLE_EXIT=current-run:37\n").finish(1)
        with self.assertRaisesRegex(E2E.StepFailed, "ssh exited 255"):
            self.terminal("MOLE_EXIT=current-run:0\n", 255).finish(1)

    def test_finish_keeps_its_timeout_boundary(self):
        term = self.terminal("")
        term.proc.poll.return_value = None
        with patch.object(E2E.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(E2E.StepFailed, "still running"):
                term.finish(1)


class DependencyTests(unittest.TestCase):
    def run_candidate(self, failed=None, keep_going=True, download_fixture=None):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            run = object.__new__(E2E.Run)
            run.id, run.dir = "fixture", Path(tmp)
            run.keep_going, run.steps, run.failed = keep_going, [], False
            run.info, run.remote = {"work": "fixture", "profile": "fixture"}, Mock(target="fixture")
            run.token = "fixture"
            calls = []
            real_download = E2E.download
            for name in ("preflight", "deploy", "download", "install", "launch", "uninstall", "history", "analyze", "smoke"):
                def action(_run, name=name):
                    calls.append(name)
                    if name == "download" and download_fixture:
                        return real_download(_run)
                    if name == failed:
                        raise E2E.StepFailed("injected failure: " + name)
                stack.enter_context(patch.object(E2E, name, side_effect=action))
            stack.enter_context(patch.object(E2E, "Run", return_value=run))
            stack.enter_context(patch.object(E2E, "cleanup", return_value=[]))
            stack.enter_context(patch.object(E2E.subprocess, "run", side_effect=AssertionError("real process")))
            stack.enter_context(patch.object(E2E.subprocess, "Popen", side_effect=AssertionError("real terminal")))
            stack.enter_context(patch.object(E2E.urllib.request, "urlopen", side_effect=AssertionError("real network")))
            if download_fixture:
                asset = {"name": "WinMerge-x64-PerUser-Setup.exe", "browser_download_url": "https://fixture.invalid/setup.exe",
                         "digest": "sha256:" + "a" * 64}
                response = io.BytesIO(json.dumps({"assets": [asset]}).encode())
                stack.enter_context(patch.object(E2E.urllib.request, "urlopen", return_value=response))
                run.remote.ps_json.return_value = {"hash": "b" * 64 if download_fixture == "checksum" else "a" * 64,
                                                   "signature": "Invalid" if download_fixture == "signature" else "Valid"}
                if download_fixture == "network":
                    run.remote.ps_json.side_effect = E2E.StepFailed("download interrupted")
            stack.enter_context(patch("sys.argv", ["e2e", "--host", "fixture"] + (["--keep-going"] if keep_going else [])))
            with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_result:
                E2E.main()
            self.assertEqual(exit_result.exception.code, 1 if failed else 0)
            return calls

    def test_failed_prerequisites_block_dependent_actions_with_keep_going(self):
        expected = {
            "preflight": ["preflight"],
            "deploy": ["preflight", "deploy"],
            "download": ["preflight", "deploy", "download", "smoke"],
            "install": ["preflight", "deploy", "download", "install", "smoke"],
            "launch": ["preflight", "deploy", "download", "install", "launch", "smoke"],
            "uninstall": ["preflight", "deploy", "download", "install", "launch", "uninstall", "smoke"],
        }
        for failed, wanted in expected.items():
            with self.subTest(failed=failed):
                self.assertEqual(self.run_candidate(failed), wanted)

    def test_read_only_failure_keeps_independent_analyze_and_smoke(self):
        self.assertEqual(self.run_candidate("history")[-3:], ["history", "analyze", "smoke"])

    def test_default_stops_after_first_failure(self):
        self.assertEqual(self.run_candidate("download", keep_going=False), ["preflight", "deploy", "download"])

    def test_failed_transfer_checksum_and_signature_block_installation(self):
        for failure in ("network", "checksum", "signature"):
            with self.subTest(failure=failure):
                self.assertEqual(self.run_candidate("download", download_fixture=failure),
                                 ["preflight", "deploy", "download", "smoke"])

    def test_success_keeps_the_full_flow(self):
        self.assertEqual(self.run_candidate(), ["preflight", "deploy", "download", "install", "launch", "uninstall", "history", "analyze", "smoke"])


class DeploymentTests(unittest.TestCase):
    def deploy_fixture(self, *, unpacked=True, mkdir_code=0, version_code=0, version_text="Mole 1.36.0", build_failure=None):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            root = Path(tmp)
            (root / "source.txt").write_text("dirty working source")
            run = object.__new__(E2E.Run)
            commit = "1" * 40
            run.info = {"goarch": "amd64", "work": "fixture", "mole": "fixture/mole.ps1", "commit": commit}
            run.remote = Mock()
            run.remote.ps.side_effect = [
                subprocess.CompletedProcess([], mkdir_code, "", "mkdir failed"),
                subprocess.CompletedProcess([], version_code, version_text, "version failed"),
            ]
            run.remote.ps_json.return_value = unpacked
            refs, builds, uploads = [], [], []

            def process(argv, **kwargs):
                if argv[:2] == ["git", "archive"]:
                    refs.append(argv[-1])
                    with zipfile.ZipFile(argv[argv.index("-o") + 1], "w") as archive:
                        archive.writestr("mole/source.txt", "committed source")
                        archive.writestr("mole/mole.ps1", "committed script")
                elif argv[:2] == ["go", "build"]:
                    source = (Path(kwargs["cwd"]) / "source.txt").read_text()
                    builds.append((source, kwargs["env"].get("GOWORK")))
                    if argv[-1] == build_failure:
                        return subprocess.CompletedProcess(argv, 1, "", "build failed")
                    Path(argv[argv.index("-o") + 1]).write_text(source)
                else:
                    self.fail(f"unexpected process: {argv}")
                return subprocess.CompletedProcess(argv, 0, "", "")

            def put(local, _remote):
                with zipfile.ZipFile(local) as archive:
                    uploads.append({name: archive.read(name).decode() for name in (
                        "mole/mole.ps1", "mole/bin/analyze.exe", "mole/bin/status.exe")})

            run.remote.put.side_effect = put
            stack.enter_context(patch.object(E2E, "ROOT", root))
            stack.enter_context(patch.object(E2E.subprocess, "run", side_effect=process))
            error = None
            try:
                E2E.deploy(run)
            except E2E.StepFailed as exc:
                error = exc
            return refs, builds, uploads, run.remote, error

    def test_archive_uses_the_preflight_commit_despite_head_changes(self):
        refs, _, _, _, error = self.deploy_fixture()
        self.assertIsNone(error)
        self.assertEqual(refs, ["1" * 40])

    def test_binaries_and_scripts_share_the_archive_despite_dirty_workspace(self):
        _, builds, uploads, _, error = self.deploy_fixture()
        self.assertIsNone(error)
        self.assertEqual(builds, [("committed source", "off")] * 2)
        self.assertEqual(uploads, [{"mole/mole.ps1": "committed script",
                                   "mole/bin/analyze.exe": "committed source",
                                   "mole/bin/status.exe": "committed source"}])

    def test_failed_deployment_does_not_report_success(self):
        for failure in ({"unpacked": False}, {"mkdir_code": 1}, {"version_code": 1}, {"version_text": ""}):
            with self.subTest(failure=failure):
                _, _, _, remote, error = self.deploy_fixture(**failure)
                self.assertIsNotNone(error)
                if "mkdir_code" in failure:
                    remote.put.assert_not_called()

    def test_either_failed_native_build_prevents_upload(self):
        for tool in ("analyze", "status"):
            with self.subTest(tool=tool):
                _, _, uploads, remote, error = self.deploy_fixture(build_failure=f"./cmd/{tool}/")
                self.assertIsNotNone(error)
                self.assertEqual(uploads, [])
                remote.ps.assert_not_called()

    def test_failed_version_probe_keeps_the_actual_error(self):
        _, _, _, _, error = self.deploy_fixture(version_code=1)
        self.assertIn("version failed", str(error))


class UninstallTests(unittest.TestCase):
    def test_singular_selected_app_reaches_only_fixture_confirmation(self):
        run = Mock(install_location=r"C:\fixture", info={})
        run.remote.ssh.return_value = []
        run.remote.ps_json.return_value = {"entries": 0, "folder": False, "settings": True}
        run.oplog_since.return_value = "UNINSTALLED WinMerge"
        term = Mock(buf=b"")
        term.finish.return_value = 0
        frames = iter((
            "Select Applications to Uninstall", "Search:", "Search: WinMerge (1 matches)",
            "Selected: 1 app (67.8MB)", "WinMerge\nContinue? (y/N)", "Uninstall complete",
        ))

        def expect(pattern, *_args, **_kwargs):
            frame = next(frames)
            term.buf += frame.encode()
            match = E2E.re.search(pattern, frame)
            self.assertIsNotNone(match, f"{pattern!r} did not match {frame!r}")
            return match

        term.expect.side_effect = expect
        with patch.object(E2E, "Terminal", return_value=term):
            self.assertIn("registry entry and install folder gone", E2E.uninstall(run))
        self.assertIn(((b"y\r",), {}), term.send.call_args_list)
        self.assertTrue(run.info["settings_after_uninstall"])
        term.close.assert_called_once()


class LaunchTests(unittest.TestCase):
    @staticmethod
    def process_fixture(script, state):
        # Execute the generated script, with no registry access or real processes.
        return r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:owned = [pscustomobject]@{ Id = 101; ProcessName = 'WinMergeU'; HasExited = __EXITED__ }
$script:bystander = [pscustomobject]@{ Id = 202; ProcessName = 'WinMergeU'; HasExited = $false }
$script:stopped = @()
function Get-ChildItem { [pscustomobject]@{ FullName = 'C:\fixture\WinMergeU.exe' } }
function Start-Process { $script:owned }
function Start-Sleep { }
function Test-Path { $true }
function Get-Process {
    param($Name)
    @($script:owned, $script:bystander) | Where-Object { $_.ProcessName -like $Name -and -not $_.HasExited }
}
function Stop-Process {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process {
        if ($null -eq $InputObject) { throw 'missing process object' }
        if (__RACE__ -and $InputObject.Id -eq $script:owned.Id) {
            $InputObject.HasExited = $true
            Write-Error 'process already exited'
            return
        }
        if ($InputObject.HasExited) { throw 'attempted to stop an exited process' }
        $script:stopped += $InputObject.Id
        $InputObject.HasExited = $true
    }
}
$result = & {
""".replace("__EXITED__", "$true" if state == "exited" else "$false").replace(
            "__RACE__", "$true" if state == "race" else "$false") + script + r"""
}
[pscustomobject]@{ result = $result; stopped = @($script:stopped); bystanderAlive = -not $script:bystander.HasExited } |
    ConvertTo-Json -Compress -Depth 4
"""

    @unittest.skipUnless(os.name == "nt", "generated PowerShell runs in Windows Validation")
    def test_launch_only_stops_its_own_process_and_handles_exit(self):
        shell = shutil.which("powershell")
        self.assertIsNotNone(shell, "Windows PowerShell is required for the launch regression")
        for state in ("running", "exited", "race"):
            with self.subTest(state=state):
                run = Mock(install_location=r"C:\fixture", info={})
                receipts = []

                def execute(script):
                    encoded = E2E.base64.b64encode(self.process_fixture(script, state).encode("utf-16-le")).decode()
                    result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")
                    receipt = json.loads(result.stdout)
                    receipts.append(receipt)
                    return receipt["result"]

                run.remote.ps_json.side_effect = execute
                if state == "exited":
                    with self.assertRaisesRegex(E2E.StepFailed, "exited right after launch"):
                        E2E.launch(run)
                    self.assertEqual(run.info, {})
                else:
                    self.assertEqual(E2E.launch(run), "ran 8s, wrote its settings")
                    self.assertTrue(run.info["settings_after_launch"])
                self.assertEqual(len(receipts), 1)
                self.assertTrue(receipts[0]["bystanderAlive"])
                self.assertEqual(receipts[0]["stopped"], [101] if state == "running" else [])


class ReleaseLookupTests(unittest.TestCase):
    def test_rate_limited_lookup_falls_back_to_signed_in_gh(self):
        limited = E2E.urllib.error.HTTPError("https://api.github.com", 403, "rate limit exceeded", {}, None)
        gh = E2E.subprocess.CompletedProcess(["gh"], 0, stdout=json.dumps({"tag_name": "v1", "assets": []}), stderr="")
        with patch.object(E2E.urllib.request, "urlopen", side_effect=limited), \
                patch.object(E2E.shutil, "which", return_value="/usr/local/bin/gh"), \
                patch.object(E2E.subprocess, "run", return_value=gh) as run:
            self.assertEqual(E2E.latest_release()["tag_name"], "v1")
        self.assertEqual(run.call_args.args[0][:2], ["gh", "api"])


if __name__ == "__main__":
    unittest.main()
