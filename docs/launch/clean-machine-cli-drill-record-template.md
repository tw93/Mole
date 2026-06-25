# Clean-Machine CLI Drill Record: <TAG>

Copy this file to `docs/launch/records/<TAG>.md` for manual drills, or let the release workflow generate `clean-machine-drill-<TAG>.md` before stable/latest promotion. Release tags must use the `V<major>.<minor>.<patch>` format, for example `V1.39.0`. Fill every field with release-specific evidence, then run:

```bash
scripts/check-clean-machine-drill-record.sh --tag <TAG>
```

When this record is used by the public release gate, the `Commit SHA` must
match the commit being promoted.

## Environment

Release tag: <TAG>
Commit SHA: <FULL_RELEASE_COMMIT_SHA>
Drill date: <YYYY-MM-DD>
Tester: <NAME_OR_HANDLE>
macOS version: <VERSION_AND_BUILD>
CPU architecture: <arm64_or_x86_64>
Fresh environment: <yes>
Existing Roomy state: <absent>
Full Disk Access: <available|not-available>
Admin privileges: <available|not-available>
Network access: <available>

## Required Gate Results

Preflight: <pass>
Homebrew install: <pass>
Script install: <pass>
Checksum verification: <pass>
First-run dry-runs: <pass>
Update behavior: <pass>
Rollback/remove/reinstall: <pass>

## Evidence

Evidence location: <LINK_OR_ARCHIVED_TRANSCRIPT_PATH>
Transcript SHA-256: <SHA256_OF_TRANSCRIPT_TXT>
Results SHA-256: <SHA256_OF_RESULTS_TSV>

Include command transcripts or links that cover:

- `scripts/release-preflight.sh`
- `go test ./...`
- `ROOMY_SKIP_API_TESTS=1 scripts/test.sh`
- `npm run test:api`
- `brew install roomy` or the explicit release tap formula, for example `brew install jake-seo-cl/tap/roomy`
- `roomy --version`
- `roomy clean --dry-run`
- `roomy uninstall --dry-run`
- `roomy purge --dry-run`
- `roomy installer --dry-run`
- `roomy optimize --dry-run`
- `roomy status`
- `roomy analyze --json "$HOME"`
- Script install from the public `install.sh`
- `roomy update --dry-run`
- `roomy remove --dry-run`
- Removal and reinstall through the tested channel

When the evidence location is a local or generated evidence directory or
`.tar.gz` archive, keep non-empty regular `transcript.txt` and `results.tsv`
files. Every status in `results.tsv` must be zero before the record can be
accepted, and the file must include the generated drill command labels for
preflight, Go tests, shell/API tests, Homebrew install, first-run dry-runs,
script install, update, remove, and Homebrew reinstall coverage. Local archives
must not contain absolute paths, parent-traversal entries, symlinks, hardlinks,
devices, or other special entry types.
The `Transcript SHA-256` and `Results SHA-256` fields must match the exact
`transcript.txt` and `results.tsv` files inside the evidence directory or
archive.

For downloaded release assets, validate the record with
`scripts/check-clean-machine-drill-record.sh --tag <TAG> --record <record> --evidence <archive>`.
If no local `--evidence` override is supplied and the record points at the
canonical public evidence URL, the verifier downloads that URL and validates the
archive contents.

## Failures, Skips, Or Waivers

Record every skipped or failed command. Public launch should not proceed while any required gate above is not `pass`.

## Launch Decision

Launch decision: <go|no-go>
Decision notes: <SUMMARY>
