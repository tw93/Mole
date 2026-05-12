# RoomyUI macOS Preview

RoomyUI is a native SwiftUI preview for Roomy. It keeps `roomy` as the execution engine and talks to it through `roomy api ...` JSON/NDJSON adapters.

## Product Status

RoomyUI is currently a prototype/preview, not the primary released Roomy product. The supported release today remains the `roomy` command-line tool plus the Darwin helper binaries published for Homebrew and tagged GitHub releases.

The app bundle produced by this directory is intended for local development and UX validation. By default `scripts/build-app.sh` applies an ad-hoc signature so local Gatekeeper checks and helper validation behave more like a real bundle, but the app is not uploaded by the release workflow. It also embeds a `RoomyCLI` payload under `Contents/Resources` and points the app at that bundled copy when opened from Finder.

## Included Today

- SwiftUI app shell for Roomy workflows.
- `roomy api ...` JSON/NDJSON integration for command execution.
- A bundled `RoomyPrivilegedHelper` launch daemon scaffold for admin cleanup
  through `SMAppService`, with a narrow `roomy api <domain> execute --plan ...`
  allowlist.
- Local `.app` assembly through `scripts/build-app.sh` / `npm run macos:build`.
- Unsigned local `.dmg` packaging through `scripts/build-dmg.sh` / `npm run macos:dmg`,
  backed by [DMGMaker](https://github.com/saihgupr/DMGMaker).
- Permission-aware onboarding for Full Disk Access, explicit scan-scope
  presets, and a recent activity view backed by the structured operation
  journal.
- Optional Developer ID signing and notarization hooks through environment variables.
- Generated local app icon when `iconutil` is available.
- Swift unit tests and Playwright UX smoke coverage.

## Not Included Yet

- Release workflow upload rules for the app bundle.
- Install/update guidance for users who do not have a source checkout.
- Release-grade validation of Developer ID credentials and helper deployment in a clean CI keychain.

## Run Locally

From the repository root:

```bash
npm run macos:build
open .build/RoomyUI.app
```

For development:

```bash
swift run --package-path macos/RoomyUI RoomyUI
```

`npm run macos:build` creates `.build/RoomyUI.app` for this checkout only. It should not be treated as a redistributable release artifact.

To create an unsigned local DMG:

```bash
npm run macos:dmg
```

The DMG script clones or reuses DMGMaker under `.build/DMGMaker`, builds an unsigned `.build/Roomy.app` bundle by default, writes `.build/Roomy.dmg`, verifies it with `hdiutil` when available, and writes `.build/Roomy.dmg.sha256`.

For a Developer ID build, provide the signing identity and notarization credentials:

```bash
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
NOTARIZE_APP=1 \
NOTARIZATION_PROFILE=roomy-notary \
npm run macos:build
```

`NOTARIZATION_PROFILE` should point at a `notarytool` keychain profile. Instead of a profile, the script also accepts `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`. Use `SKIP_SIGN=1` only for local debugging.

The Settings view can register the bundled privileged helper. Registration uses
macOS Service Management and may require approval in System Settings. Once
enabled, destructive admin flows route through the helper instead of displaying
password dialogs inside RoomyUI. The helper only accepts Roomy API execute
commands backed by a plan file and only runs the Roomy CLI associated with the
app bundle.

RoomyUI uses a privacy-safe startup flow. Launch loads only a lightweight system
snapshot; cleanup previews, storage scans, installer searches, application
inventory, and Settings inventory run only after the user clicks the relevant
button. For complete scans without repeated macOS folder prompts, grant the app
Full Disk Access from the Home or Settings permission controls. If macOS denies
a scan path, RoomyUI summarizes that as a permissions issue instead of surfacing
raw shell output, and users can continue with a narrower folder or open Full
Disk Access directly.

## Verify

```bash
scripts/bootstrap-dev.sh
npm ci
npm run test:api
swift test --package-path macos/RoomyUI
npm run test:ux
npm run macos:build
npm run macos:dmg
scripts/test.sh
```

For the stricter local preflight used before native UI/API changes, run:

```bash
scripts/check.sh --no-format --strict
```

## Release Workflow Notes

`.github/workflows/release.yml` currently builds and publishes CLI/helper assets for tagged releases, then updates Homebrew formulae. The validation workflow builds and verifies the local app bundle, while release upload rules for the unsigned RoomyUI DMG remain intentionally separate until install and update guidance are finalized.
