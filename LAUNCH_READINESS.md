# Roomy Launch Readiness

Updated: 2026-05-13

This file codifies the production launch goals that must stay true before a public launch tag is cut.

## Goal 1: Launch Scope Lock

Production launch scope: CLI

The production launch is scoped to the supported `roomy` command-line product distributed through Homebrew, the install script, and tagged GitHub releases. Release assets may include the CLI helper binaries, Homebrew tarballs, checksums, provenance/attestation metadata, and GitHub-generated source archives.

RoomyUI is excluded from production release until a separate native-app launch decision is made. It can remain in the repository for local development, UX validation, ad-hoc signed builds, and workflow smoke tests, but the production release workflow must not publish a `.app`, `.dmg`, or notarization zip for RoomyUI while this scope lock is active.

Scope-change rule: changing this launch scope requires updating this file and the launch-readiness preflight in the same change. The change must name the install, update, rollback, signing, notarization, and clean-machine QA gates for the newly included surface.

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
| Symlinks | Symlinked deletion bases and protected symlink targets are refused | `tests/core_safe_functions.bats`, `tests/installer.bats`, `tests/installer_fd.bats` |
| Sudo boundary | Test/no-auth modes do not invoke sudo, and denied sudo short-circuits | `tests/core_common.bats`, `tests/optimize.bats`, `tests/brew_uninstall.bats` |
| Restore and logs | Trash restore previews work and deletion/operation journals are written | `tests/cli.bats`, `tests/file_ops_roomy_delete.bats`, `tests/core_common.bats` |
| Unsafe raw deletion | Security workflow continues scanning for ungated `rm -rf` usage | `.github/workflows/test.yml` |

Launch acceptance requires the release preflight to pass, the safety matrix anchors to remain present, and the normal shell/API/native validation suites to pass for the launch commit.
