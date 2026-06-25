# Roomy Launch Readiness

Updated: 2026-06-25

This file codifies the production launch goals that must stay true before a public launch tag is promoted to stable/latest.

## Goal 1: Launch Scope Lock

Production launch scope: CLI

The production launch is scoped to the supported `roomy` command-line product distributed through Homebrew, the install script, and tagged GitHub releases. Release assets may include the CLI helper binaries, Homebrew tarballs, checksums, provenance/attestation metadata, and GitHub-generated source archives.

RoomyUI is excluded from production release until a separate native-app launch decision is made. It can remain in the repository for local development, UX validation, ad-hoc signed builds, and workflow smoke tests, but the production release workflow must not publish a `.app`, `.dmg`, or notarization zip for RoomyUI while this scope lock is active.

Scope-change rule: changing this launch scope requires updating this file and the launch-readiness preflight in the same change. The change must name the install, update, rollback, signing, notarization, and clean-machine QA gates for the newly included surface.

## Goal 2: Clean-Machine CLI Release Drill

Clean-machine gate: before a public launch tag is promoted to stable/latest, validate the supported CLI install, update, rollback/remove, and first-run flows on a fresh macOS environment using the runbook in `docs/launch/clean-machine-cli-drill.md`.

The drill must cover Homebrew installation, script installation, checksum verification, first-run dry-run commands, update behavior, and removal/reinstall behavior. Any skipped step must be recorded with the launch decision because skipped install or rollback coverage is a release risk, not a cosmetic gap.

## Goal 3: Release Integrity Manifest

Release integrity gate: every public tag must have curated release notes, a recorded release manifest, SHA-256 checksums, artifact attestations, corresponding source availability, and Homebrew formula verification as described in `docs/release/release-integrity.md`.

The manifest is the human-readable bridge between CI output and user trust. It must identify the exact tag, assets, source archive checksum, helper binary checksums, Homebrew tarball checksums, attestation status, and formula update status.

The GitHub release must remain a draft until release assets, checksums, and attestations exist. It may then be staged as a prerelease so Homebrew and install-script URLs are publicly downloadable before formula publication and the clean-machine drill. The final stable/latest promotion must run after the formula update and install-channel gates, so a failed formula update or drill cannot leave a public stable release with a stale install path.

## Goal 4: Safety Regression Matrix

Safety gate: every destructive command must keep dry-run, protected-path, path traversal/symlink, sudo-boundary, and restore/logging coverage.

Roomy is a local maintenance tool, so the launch blocker is unintended local damage. The safety matrix below maps launch-critical hazards to regression coverage that must remain present and must run through normal validation.

| Area | Required coverage | Current regression anchor |
| --- | --- | --- |
| Clean dry-run | `roomy clean --dry-run` reports candidates without deleting files | `tests/clean_core.bats` |
| Uninstall dry-run | API-driven uninstall plans can execute in dry-run mode | `tests/api_contract.test.mjs` |
| Optimize dry-run | Optimization tasks report dry-run work without applying changes | `tests/optimize.bats` |
| Purge dry-run | `roomy purge --dry-run` previews project artifacts | `tests/purge.bats` |
| Installer dry-run | Installer cleanup accepts dry-run and keeps files untouched | `tests/installer.bats` |
| Remove dry-run | `roomy remove --dry-run` keeps installed binaries and caches | `tests/uninstall.bats` |
| Completion dry-run | Shell completion changes are previewable before writing config | `tests/completion.bats` |
| Touch ID dry-run | Touch ID setup previews sudo/PAM changes before writing config | `tests/cli.bats` |
| Update dry-run | Update execution can stream dry-run events | `tests/api_contract.test.mjs` |
| Storage Trash dry-run | UI storage actions can dry-run Trash operations and reject escapes | `tests/api_contract.test.mjs` |
| Launcher dry-run | Quick launcher installation can dry-run script/workflow writes | `tests/api_contract.test.mjs` |
| Plan confirmation | API execute plans reject unconfirmed, malformed, or partial plans | `tests/api_contract.test.mjs` |
| Protected paths | Protected roots and high-risk categories remain refused or skipped | `tests/core_safe_functions.bats`, `tests/clean_user_core.bats`, `tests/purge.bats` |
| Path traversal | Deletion validation rejects traversal components | `tests/core_safe_functions.bats` |
| Symlinks | Symlinked deletion bases, protected symlink targets, and protected symlinked parents are refused | `tests/core_safe_functions.bats`, `tests/installer.bats`, `tests/installer_fd.bats` |
| Sudo boundary | Test/no-auth modes do not invoke sudo, and denied sudo short-circuits | `tests/core_common.bats`, `tests/optimize.bats`, `tests/brew_uninstall.bats` |
| Restore and logs | Trash restore previews work and deletion/operation journals are written | `tests/cli.bats`, `tests/file_ops_roomy_delete.bats`, `tests/core_common.bats` |
| Unsafe raw deletion | Security workflow continues scanning for ungated recursive rm, find-delete, and xargs-rm usage | `.github/workflows/test.yml` |

## Goal 5: Destructive Workflow UX Gate

Destructive workflow gate: user-facing destructive flows must explain preview state, admin requirements, skipped protected paths, confirmation, recovery limits, and operation logging without exposing raw implementation noise. The copy and interaction expectations live in `docs/ux/destructive-workflows.md`.

The gate applies to `clean`, `uninstall`, `purge`, `installer`, `restore`, `optimize`, `completion`, `touchid`, `update`, `remove`, and Roomy API execution events consumed by native clients.

## Goal 6: Roomy API Stability Contract

API stability gate: RoomyUI-facing JSON and NDJSON contracts must stay versioned, additive by default, and covered by `tests/api_contract.test.mjs` plus `tests/fixtures/api/contracts.json`. The stability rules live in `docs/api/stability-contract.md`.

Breaking API changes require an explicit schema/version decision, matching Swift model updates, fixture updates, and release notes that name the compatibility impact.

## Goal 7: RoomyUI Release Decision

Native app gate: RoomyUI remains preview-only until the native app release decision in `docs/macos/roomyui-release-decision.md` is changed and the launch scope lock is updated in the same change.

Shipping RoomyUI as a downloadable macOS product requires install, update, rollback, Developer ID signing, notarization, privileged helper deployment, clean-machine QA, and support documentation gates before release workflow upload rules can publish app or DMG artifacts.

## Goal 8: Performance Baselines

Performance gate: launch validation must keep baseline measurements for large filesystem scans, app inventory, uninstall metadata, project purge, analyzer traversal, status collection, and API previews. The baseline plan lives in `docs/performance/baselines.md`.

Performance regressions that affect launch-critical flows must be triaged before tagging, even when functional tests pass.

## Goal 9: Sales Launch Surface

Sales gate: the public launch surface must sell the current supported product, not an unreleased native app. The static landing page in `site/` must present Roomy as a CLI-first Mac maintenance product, embed the generated demo media, link to install/readiness material, and avoid claiming that RoomyUI is production-ready while the scope lock excludes native app artifacts.

The market position must stay grounded in `docs/marketing/competitor-benchmark.md` and `docs/marketing/pricing-strategy.md`, and the landing page smoke check must run in CI through `npm run site:check` so desktop/mobile layout, required sections, GPL-friendly pricing, and demo assets remain present.

The final launch review must use `docs/launch/go-no-go-audit.md` to map the release candidate to evidence instead of relying only on proxy signals.

## Goal 10: Open Source Compliance And Namespace

Compliance gate: Roomy must launch as a GPL-3.0 Roomy-branded fork, not as an MIT project and not as a Mole-branded public product. The source repository, Homebrew tap, release workflow, README, site, release notes, and support/security docs must point to the Roomy namespace and preserve upstream attribution.

The compliance checklist lives in `docs/legal/open-source-compliance.md`, and the automation/distribution assumptions live in `docs/launch/distribution-automation.md`. `scripts/check-license-compliance.sh` must pass as part of release preflight.

Launch acceptance requires the release preflight to pass, the clean-machine drill record for the tag to validate, the safety matrix anchors to remain present, the license compliance gate to pass, the sales launch surface smoke check to pass, and the normal shell/API/native validation suites to pass for the launch commit.
