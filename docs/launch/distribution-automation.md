# Distribution Automation

Last reviewed: 2026-06-25

## Launch Assumption

Public distribution assumes the fork is renamed before launch:

- Canonical source repository: `jake-seo-cl/roomy`
- Personal Homebrew tap: `jake-seo-cl/homebrew-tap`
- Tap install command: `brew install jake-seo-cl/tap/roomy`
- Product name: Roomy
- Upstream attribution: modified fork of `tw93/mole`

Do not run a public launch from `jake-seo-cl/Mole`. The upstream trademark policy asks forks not to market under the Mole name, and the current launch copy is built around Roomy.

## Automated Path

The normal public release should be tag-driven:

1. Maintainer creates a clean release commit and curated notes under `docs/release/notes/<TAG>.md`.
2. Maintainer runs `scripts/check-public-release.sh --tag <TAG> --full --skip-clean-machine`.
3. Maintainer pushes tag `V<major>.<minor>.<patch>`.
4. GitHub Actions runs release preflight, tests, site checks, binary builds, checksum generation, release manifest generation, and artifact attestations.
5. The release workflow creates a draft release and keeps it hidden until assets, checksums, manifest, release body, and attestations exist.
6. The workflow stages the release as a public prerelease so Homebrew and script-install URLs are reachable.
7. The workflow updates `jake-seo-cl/homebrew-tap`, opens the Homebrew core update when credentials allow it, and then runs the clean-machine install-channel drill.
8. The workflow uploads the clean-machine drill record and evidence archive.
9. The workflow validates downloaded release assets, source archive checksum, manifest checksums, and clean-machine evidence before stable/latest promotion.

## Manual Inputs That Remain

- Choosing the final tag and release notes.
- Confirming `jake-seo-cl/roomy` and `jake-seo-cl/homebrew-tap` exist and are owned by the launch account.
- Configuring GitHub Actions secrets: `PAT_TOKEN` and `HOMEBREW_GITHUB_API_TOKEN`.
- Reviewing the Homebrew core PR if Homebrew core publication is desired.
- Responding to failed clean-machine drill evidence.
- Making the final go/no-go decision from `docs/launch/go-no-go-audit.md`.

## Launch Blockers

- Repository still named `Mole` at public launch.
- `LICENSE` is not GPL-3.0.
- `NOTICE` is missing from the source archive.
- README, site, or release notes describe Roomy as MIT-licensed.
- Public copy implies endorsement by Mole, tw93, or Mole for Mac.
- Homebrew formula URLs point to upstream Mole or an unavailable Roomy repository.
- Release workflow publishes a stable/latest release before the clean-machine drill passes.
- Pricing copy sells proprietary CLI feature unlocks without a GPL-compatible source and distribution plan.
