# RoomyUI Release Decision

Current decision: RoomyUI is preview-only and must not be published by the production release workflow.

The supported launch product is the `roomy` CLI. RoomyUI can remain in the repository for local development, UX validation, ad-hoc signed builds, DMG smoke tests, and API contract validation.

## Scope-Change Rule

Changing RoomyUI from preview-only to downloadable product requires the same change to update:

- `LAUNCH_READINESS.md`
- `scripts/check-launch-readiness.sh`
- `.github/workflows/release.yml`
- RoomyUI install/update/remove documentation
- Clean-machine QA instructions for the native app

## Required Gates Before Publishing

Do not upload a `.app`, `.dmg`, or notarization zip from the production release workflow until these are defined and validated:

- Install path for users without a source checkout.
- Update path from one signed app release to the next.
- Rollback or remove path, including helper cleanup.
- Developer ID signing identity handling in CI.
- Notarization credentials in a clean CI keychain.
- Privileged helper registration, upgrade, and unregister behavior.
- Full Disk Access onboarding and denied-permission behavior.
- Clean-machine QA on macOS 14 and macOS 15, including Apple Silicon and Intel coverage where practical.
- Support and troubleshooting documentation for Gatekeeper, Full Disk Access, and helper registration failures.

## Preview Acceptance

While preview-only, RoomyUI should keep passing:

- Swift unit tests.
- Playwright UX smoke tests.
- Local app bundle build and ad-hoc signature verification.
- API contract tests for the CLI bridge.

Preview builds may be useful for demos and validation, but they are not release artifacts.
