# Clean-Machine CLI Release Drill

This drill validates the supported Roomy product: the `roomy` command-line tool distributed through Homebrew, the install script, and tagged GitHub releases. Run it before promoting a public release to stable/latest or when release/install logic changes.

For manual drills, copy `docs/launch/clean-machine-cli-drill-record-template.md` to `docs/launch/records/<TAG>.md`, complete it with command evidence, and validate it. Release tags must use the `V<major>.<minor>.<patch>` format, for example `V1.39.0`.

```bash
scripts/check-clean-machine-drill-record.sh --tag <TAG>
```

The public release gate also checks that the record's `Commit SHA` matches the
commit being promoted. When the generated evidence is still local, pass it to
the final gate with `--evidence <archive-or-dir>` so the same verifier checks
the transcript and `results.tsv` before upload.

To automate the drill on the fresh Mac, run:

```bash
scripts/run-clean-machine-cli-drill.sh --tag <TAG> --previous-tag <PREVIOUS_TAG> --fresh-environment --tester <NAME> --yes
```

When validating immediately after the release workflow updates the project tap
and before Homebrew core has merged, test that channel explicitly:

```bash
scripts/run-clean-machine-cli-drill.sh --tag <TAG> --previous-tag <PREVIOUS_TAG> --fresh-environment --tester <NAME> --homebrew-tap tw93/tap --homebrew-package tw93/tap/roomy --yes
```

The automated runner also requires `--fresh-environment`; pass it only after
confirming the drill is running on a clean macOS user account, VM, or reset
snapshot with no existing Roomy installation.
The `--record` and `--evidence-dir` output paths must not include parent
traversal or symlinked path components; the runner refuses unsafe evidence
destinations before writing transcript or record files.
Tester, evidence location, Homebrew tap, and Homebrew package metadata must not
contain tabs or newlines because those values are written into Markdown,
transcripts, and TSV command evidence.
The record verifier also rejects tab or carriage-return characters in record
metadata such as `Tester`, `macOS version`, and `Evidence location`.

The runner records observed Full Disk Access, admin-group membership, and
network reachability in the tag record instead of assuming those permissions.
Every install, update, and reinstall version probe must match the release tag
being validated; installing the previous public version is a failed gate, even
when the command itself exits successfully.

The tag release workflow runs a source gate before assets exist, creates a draft release, stages it as a prerelease once assets and checksums exist, updates the Homebrew formula channels against those public URLs, runs this drill against the release tap, uploads the generated record, and only then promotes the GitHub release to stable/latest.

## Required Environment Record

Record these values with the launch notes:

- Release tag and commit SHA.
- macOS version and CPU architecture.
- Install path tested: Homebrew, install script, or both.
- Existing Roomy state before install: absent.
- Whether Full Disk Access, admin privileges, and network access were available.

## Preflight

From a checkout of the release candidate:

```bash
scripts/release-preflight.sh
go test ./...
ROOMY_SKIP_API_TESTS=1 scripts/test.sh
npm run test:api
```

If the release changes native UI or API behavior, also run:

```bash
scripts/check.sh --no-format --strict
```

## Fresh Homebrew Install

On a clean macOS user account or VM:

```bash
brew tap tw93/tap # use when Homebrew core propagation is pending
brew update
brew install tw93/tap/roomy # or `brew install roomy` after Homebrew core is live
roomy --version
roomy clean --dry-run
roomy uninstall --dry-run
roomy purge --dry-run
roomy installer --dry-run
roomy optimize --dry-run
roomy status
roomy analyze --json "$HOME"
```

Acceptance:

- Install finishes without extra source checkout requirements.
- `roomy --version` matches the release tag.
- Every dry-run command explicitly previews work without changing files.
- `status` and `analyze --json` find their helper binaries.
- Any sudo denial is reported as skipped or denied work, not as unsafe fallback behavior.

## Fresh Script Install

On a separate clean user account, VM snapshot, or reset machine:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/roomy/<TAG>/install.sh | ROOMY_VERSION=<TAG> bash
roomy --version
roomy clean --dry-run
roomy uninstall --dry-run
roomy update --dry-run
roomy remove --dry-run
```

Acceptance:

- The script downloads only release assets that pass checksum verification.
- Stable installs do not warn about missing nightly metadata.
- Update preview explains the source and target version.
- Remove preview lists the installed paths it would affect.

## Update And Rollback/Remove

Validate at least one upgrade path from the previous stable release:

```bash
roomy --version
ROOMY_VERSION=<TAG> bash <TAG-install.sh> --update
roomy --version
roomy remove --dry-run
```

Then validate removal and reinstall through the same channel:

```bash
roomy remove
brew install roomy
roomy --version
```

If Homebrew formula propagation is not complete yet, use the personal tap. Do
not mark the Homebrew install gate as `pass` until one tested Homebrew formula
installs the release tag and the transcript names the formula that was used.

## Evidence To Keep

Keep the command transcript or CI job links in the tag-specific drill record. For each failure, record:

- Command and install channel.
- Exit code and user-facing output.
- Whether data was changed.
- Fix commit or explicit launch waiver.

For local or generated evidence directories and `.tar.gz` archives, keep the
generated `transcript.txt` and `results.tsv` files.
`scripts/check-clean-machine-drill-record.sh` rejects local evidence when
either file is missing, empty, symlinked, or when `results.tsv` contains any
row that is not exactly `label<TAB>status` with a zero command status. The
verifier also requires the generated `results.tsv` to include the core drill command labels for preflight, Go tests, shell/API tests, Homebrew install,
first-run dry-runs, script install, update, remove, and Homebrew reinstall
coverage. Local evidence archives are checked for unsafe absolute or parent-traversal paths before extraction. Archives may contain only regular files and directories; symlinks, hardlinks, devices, and other special entry types are rejected.
The drill record must also include `Transcript SHA-256` and `Results SHA-256`
fields that match the exact `transcript.txt` and `results.tsv` files being
validated.

When validating downloaded release assets, pass the downloaded archive with
`--evidence <archive>` so the verifier checks the exact evidence archive being
promoted, even if the record's `Evidence location` points at the public release
URL. Public evidence URLs must use the canonical tag-specific asset:
`https://github.com/tw93/roomy/releases/download/<TAG>/clean-machine-drill-<TAG>-evidence.tar.gz`.
When no local `--evidence` override is supplied for a public evidence URL, the
verifier downloads that canonical URL and validates the archive contents before
passing the record. During pre-upload staging, validate the generated local
evidence directory with `--evidence <dir>` while keeping the record's public
`Evidence location` set to the canonical release asset URL.

The launch decision should remain `no-go` until every required gate in the drill record is `pass`.
