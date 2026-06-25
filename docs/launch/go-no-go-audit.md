# Launch Go/No-Go Audit

Use this checklist before promoting a public release tag to stable/latest. It maps the launch goal to concrete evidence that must exist for the release commit.

Run the source gate before release assets are created:

```bash
scripts/check-public-release.sh --tag <TAG> --full --skip-clean-machine
```

Local `.env` files are not required for the CLI release path. The release gate does not load them; Homebrew publishing credentials must live in GitHub Actions secrets, and native signing/notarization environment variables only apply to RoomyUI preview builds while the launch scope is CLI.

## Release Candidate

- Release tag: `V<major>.<minor>.<patch>`
- Release commit: `<full commit SHA>`
- Previous stable tag tested for update flow: `V<major>.<minor>.<patch>`
- Launch scope: CLI

## Required Evidence

| Requirement | Evidence | Pass rule |
| --- | --- | --- |
| Release worktree is clean | `git status --short` | No uncommitted or untracked source files remain before tagging. Generated local tool output such as `node_modules` or `test-results` is not release evidence. |
| CLI-only launch scope is locked | `LAUNCH_READINESS.md`, `.github/workflows/release.yml` | Release workflow does not publish RoomyUI `.app`, `.dmg`, or notarization artifacts. |
| Release tag matches CLI version | `roomy` | `scripts/check-release-version.sh --tag <TAG>` passes. |
| Existing tag is not being reused | Git tag refs | If `<TAG>` already exists, it points at the release commit. |
| Clean-machine install/update/remove drill completed | `docs/launch/records/<TAG>.md` or release asset `clean-machine-drill-<TAG>.md` | `scripts/check-clean-machine-drill-record.sh --tag <TAG> --record <record> --commit <release commit>` passes. |
| Source release gate passes | Command transcript | `scripts/check-public-release.sh --tag <TAG> --full --skip-clean-machine` passes before assets are created. |
| Final public release gate passes | Command transcript | `scripts/check-public-release.sh --tag <TAG> --final --record <record> --evidence <archive-or-dir>` passes after the install-channel drill. |
| Safety and release hygiene gates pass | Command transcript | `scripts/release-preflight.sh` passes on the release commit. |
| Static/lint checks pass | Command transcript | `scripts/check.sh --no-format` passes on the release commit. |
| Shell/API/integration/install tests pass | Command transcript | `scripts/test.sh` passes on the release commit. |
| API contracts are stable | Command transcript, `tests/fixtures/api/contracts.json` | `npm run test:api` passes and any schema change is documented. |
| Go helper binaries are healthy | Command transcript | `go test ./...` passes before release assets are built. |
| Sales page is shippable | `site/`, `test-results/site/` | `npm run site:check` passes and screenshots show no broken desktop/mobile layout. |
| Public release notes are curated | `docs/release/notes/<TAG>.md`, `RELEASE_BODY.md` | `scripts/check-release-notes.sh --tag <TAG>` passes, the uploaded release body starts with the curated notes, and the appended manifest names the release commit. |
| Release integrity is preserved | `docs/release/release-integrity.md`, release workflow output | Manifest includes tag, commit, checksums, attestation status, Homebrew status, clean-machine record, and rollback/remove notes. |
| Open-source compliance is preserved | `LICENSE`, `NOTICE`, `docs/legal/open-source-compliance.md`, release workflow output | `scripts/check-license-compliance.sh` passes, release assets preserve GPL-3.0 license/notice text, and public copy identifies Roomy as a modified and renamed fork without implying upstream endorsement. |
| Distribution prerequisites exist | Local command transcript | `scripts/check-distribution-prereqs.sh --check-secrets` passes against `jake-seo-cl/roomy` and `jake-seo-cl/homebrew-tap`. |
| Homebrew publishing runs from the canonical repository | Release workflow output | Public tap and Homebrew core publishing only run when `GITHUB_REPOSITORY` resolves to `jake-seo-cl/roomy`. |
| Formula publishing secrets are validated before public staging | Release workflow output | `PAT_TOKEN` and `HOMEBREW_GITHUB_API_TOKEN` are present before the draft release is staged as a public prerelease. |
| Local environment is not release-critical | `scripts/check-public-release.sh`, local shell transcript | No local `.env` file is required or loaded for the CLI release gate; any local `.env` warning is informational only. |
| Homebrew update path is ready | Release workflow and tap update output | The GitHub release is created as a draft, staged as a prerelease before formula publication, the personal tap update succeeds, the Homebrew core update succeeds, and stable/latest promotion happens only after the drill record passes. |
| Clean-machine evidence is attached and validated | GitHub release assets, release workflow output | The final public release gate validates the generated local evidence before upload; then `clean-machine-drill-<TAG>.md` and `clean-machine-drill-<TAG>-evidence.tar.gz` are visible release assets, and the workflow validates the downloaded evidence archive contents before stable/latest promotion. Public evidence URLs are downloaded and inspected by the verifier when no local `--evidence` override is supplied. The record's transcript/results SHA-256 fields must match the evidence files. |
| Uploaded release assets match the release commit | GitHub release assets, release workflow output | Before stable/latest promotion, the workflow rejects missing or unexpected uploaded assets, verifies the downloaded `RELEASE_MANIFEST.md` tag and commit, validates the manifest source archive checksum, compares manifest helper/tarball checksums with `SHA256SUMS`, and runs `sha256sum --check SHA256SUMS` against the downloaded helper binaries and Homebrew tarballs. |
| Buyer-facing privacy and support docs are published | `PRIVACY.md`, `SUPPORT.md`, `README.md`, `site/index.html` | Public docs state local data handling, log-sharing guidance, support channels, and commercial inquiry path. |
| Support/positioning is honest | `README.md`, `docs/marketing/competitor-benchmark.md`, `site/index.html` | Public copy sells the CLI product, names RoomyUI as preview-only, and avoids unsupported native-app claims. |

## No-Go Conditions

- Missing or placeholder clean-machine drill record for the tag before stable/latest promotion.
- Uncommitted or untracked source files are present when the public release gate runs.
- `scripts/check-public-release.sh --final` is combined with `--allow-dirty`, `--skip-site`, or `--skip-clean-machine`.
- The requested release tag already exists at a different commit.
- Any required gate in `docs/launch/records/<TAG>.md` is not `pass`.
- Release workflow would publish native app artifacts while launch scope is CLI.
- `scripts/release-preflight.sh`, `scripts/check.sh --no-format`, `scripts/test.sh`, or `npm run site:check` fails.
- Installer checksum verification is skipped, waived, or unverifiable.
- Public copy claims production support for RoomyUI before the native release decision changes.
- Release notes omit known destructive-workflow, install/update/remove, compatibility, or rollback impacts.
- `LICENSE`, `NOTICE`, README, site, or release notes contradict the GPL-3.0 fork posture.
- Public launch still uses `jake-seo-cl/Mole`, the Mole name, Mole assets, or upstream Mole support channels for Roomy distribution.
- `scripts/check-distribution-prereqs.sh --check-secrets` cannot access the canonical repository, Homebrew tap, or required release secrets.
- Homebrew publishing is attempted from a fork, renamed repository, or any repository other than `jake-seo-cl/roomy`.
- Formula publishing secrets are missing when the release is about to be staged as a public prerelease.
- A local `.env` file is treated as proof that release publishing credentials exist in CI.
- The generated clean-machine evidence fails the final public release gate, the record or evidence archive is missing from release assets, or the downloaded evidence archive fails validation before stable/latest promotion.
- Uploaded release assets are missing, unexpected, checksum-invalid, or have a release manifest whose tag/commit does not match the workflow ref.
- Privacy or support guidance is missing from public docs or the landing page.
- The workflow promotes the GitHub release to stable/latest before the Homebrew formula update gate and install-channel drill complete.
- A failed install-channel drill is converted to stable/latest instead of remaining a staged prerelease for diagnosis.

## Decision

Launch decision: `<go|no-go>`

Decision notes: `<summary and links>`
