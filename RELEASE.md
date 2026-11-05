# Mole CLI for Windows - Release Guide

A Windows release goes through three hands: CI builds the assets into a draft release, the maintainer signs them on Windows, and the signed files replace the draft's before it is published. The macOS CLI on `main` has its own `V*` tags and release workflow; the two never share a version number.

## Tags

| Tag | Result |
|---|---|
| `V1.31.0-windows` | Stable release |
| `V1.31.0-beta.1-windows` | Prerelease (any `-` left after removing `-windows`) |

Every Windows release keeps `make_latest: false`. The macOS installer and `mo update` resolve the stable macOS version through `releases/latest`, so a Windows release marked latest would break macOS updates. When editing a release by hand, leave "Set as the latest release" unchecked.

## Assets

| File | Purpose |
|---|---|
| `mole-<version>-x64.zip` | What winget and Scoop install; `mo.exe` at its root is what they put on PATH. Not advertised as a download of its own |
| `analyze-windows-x64.exe`, `status-windows-x64.exe` | TUIs that source installs download on first use |
| `SHA256SUMS.txt` | Checksums of the three files above; the TUI download refuses a file that does not match |

## 1. Prepare

1. CI is green on the `windows` commit you will tag: `Check` and `Validation`, including both PowerShell legs.
2. Bump the version in one commit: `VERSION` and `$script:MoleDefaultVersion` in `lib/core/version.ps1`.
3. `scripts/e2e_windows.py --host user@address` exits 0 from the Mac against the Parallels VM and the x64 ThinkPad at that commit (setup in `AGENTS.md`, "Windows e2e").

## 2. Tag

```powershell
git tag V1.31.0-windows
git push origin V1.31.0-windows
```

`.github/workflows/release-windows.yml` runs the tests, runs `scripts/build-release.ps1`, and creates a **draft** release with the unsigned assets.

## 3. Sign

On a Windows machine with the code-signing certificate available (for Certum, log in to SimplySign Desktop first; the session expires after a few idle hours):

```powershell
gh release download V1.31.0-windows --repo tw93/Mole --dir C:\mole-release
$env:MOLE_SIGN_PARAMS = "/fd sha256 /tr http://time.certum.pl /td sha256 /sha1 <thumbprint>"
.\scripts\sign-release.ps1 -Path C:\mole-release
```

The script needs an x64 `signtool.exe` (it finds the Windows SDK build tools or vpk's copy, or set `MOLE_SIGNTOOL`). It signs every `.ps1` and `.exe` in the zip and both TUI executables, verifies each signature and timestamp against the thumbprint, rebuilds the zip, and rewrites `SHA256SUMS.txt`. A timestamp or HSM hiccup is retried once; a second failure stops the script.

If the Windows machine has no `gh`, download and upload the files from another machine through a shared folder.

## 4. Publish

Every release title includes the version tag and a short codename, including Windows releases and prereleases.

```powershell
gh release upload V1.31.0-windows C:\mole-release\* --repo tw93/Mole --clobber
gh release edit V1.31.0-windows --repo tw93/Mole --title "V1.31.0-windows <CodeName>" --draft=false --latest=false
```

Right after publishing, add the six standard reactions as the maintainer, the same set every macOS release gets:

```bash
id=$(gh api repos/tw93/Mole/releases/tags/V1.31.0-windows --jq .id)
for c in +1 laugh heart hooray rocket eyes; do gh api -X POST repos/tw93/Mole/releases/$id/reactions -f content="$c"; done
```

Then check:

- `gh api repos/tw93/Mole/releases/latest --jq .tag_name` still prints the macOS tag.
- `gh api repos/tw93/Mole/releases/$id/reactions` lists all six reactions from `tw93`.
- A downloaded asset matches `SHA256SUMS.txt`, and `Get-AuthenticodeSignature` reports `Valid` for `mo.exe`.

## 5. Package managers

Render and submit the winget and Scoop manifests as described in `packaging/README.md`.

## 6. Antivirus check

A day or two after publishing, look up the SHA-256 of every executable the release ships (`mo.exe` from the zip, `analyze.exe` and `status.exe`) on VirusTotal at `https://www.virustotal.com/gui/file/<sha256>`. Look up by hash only and never upload the files. A hash VirusTotal has not seen yet is unknown, not clean, so look again within a week. When any engine flags a file, submit a false-positive report to that vendor (Kaspersky: a reanalysis request on opentip.kaspersky.com, signed in with a Kaspersky Account), and keep the user's issue open until a rescan shows the detection gone. Kaspersky flagged `analyze.exe` as `Trojan-PSW.Win32.Greedy` from 1.40.0 to 1.42.0 until such a report cleared it (#1919, 2026-11-04). Apply for Kaspersky's vendor allowlist only if detections come back on a later release.
