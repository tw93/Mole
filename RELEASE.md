# Mole for Windows (CLI) - Release Guide

Releases are built and published by `.github/workflows/release-windows.yml` when a Windows tag is pushed from this branch. The macOS CLI on `main` has its own `V*` tags and release workflow; the two never share a version number.

## Tags

| Tag | Result |
|---|---|
| `V1.31.0-windows` | Stable GitHub release |
| `V1.31.0-beta.1-windows` | Prerelease (any `-` left after removing `-windows`) |

Every Windows release is created with `make_latest: false`. The macOS installer and `mo update` resolve the stable macOS version through `releases/latest`, so a Windows release marked latest would break macOS updates. Never publish a Windows release by hand without unchecking "Set as the latest release".

## Before tagging

1. CI is green on the `windows` commit you will tag: `Check` and `Validation`, including both PowerShell legs (Windows PowerShell 5.1 and pwsh 7).
2. Bump the version in both places, in one commit:
   - `VERSION`
   - `$script:MoleDefaultVersion` in `lib/core/version.ps1`
3. Run `.\scripts\test.ps1` locally on Windows.

## Publish

```powershell
git tag V1.31.0-windows
git push origin V1.31.0-windows
```

The workflow runs the tests, builds `mole-<version>-x64.zip`, the optional `mole-<version>-x64.exe` launcher, `analyze-windows-x64.exe`, `status-windows-x64.exe` and `SHA256SUMS.txt`, attests them, and creates the release. Edit the notes afterwards with `gh release edit`.

## After publishing

- Confirm `gh api repos/tw93/Mole/releases/latest --jq .tag_name` still prints the macOS tag.
- Verify an asset: `gh attestation verify mole-1.31.0-x64.zip --repo tw93/Mole`.
- Installs from `quick-install.ps1` and `mo update` follow the `windows` branch source, not release assets.

## Package managers

The manifests under `packaging/` (winget, Scoop, Chocolatey) still describe the original contributor fork and are not published. Updating their identifiers, URLs, license and hashes is a separate decision, made before the first submission.
