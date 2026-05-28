# Roomy API Stability Contract

`roomy api ...` is the compatibility layer between the shell/Go CLI engine and native clients such as RoomyUI. Treat it as a product contract, not as private shell output.

## Versioning Rules

- JSON responses that expose `schema_version` use integer schema versions.
- Additive fields are allowed without a version bump when existing fields keep type and meaning.
- Removing fields, renaming fields, changing field types, or changing event semantics is a breaking change.
- Breaking changes require a schema/version decision, Swift model updates, fixture updates, and release notes.
- New API domains must be added to `tests/fixtures/api/contracts.json` with contract tests.

## Response Rules

- Normal response bodies are JSON on stdout.
- Error responses are JSON on stderr with `{"error":{"code":"...","message":"..."}}`.
- Error messages must be escaped correctly for quotes, backslashes, tabs, and newlines.
- Filesystem paths returned to clients should be absolute when they represent executable targets or scan roots.
- Preview responses should include estimated bytes and item counts when the underlying command can provide them.
- Application inventory rows should include `uninstall_supported` and `uninstall_reason` when the backend knows an item should not be offered to destructive uninstall execution. Older clients may treat missing `uninstall_supported` as `true`.

## Execution Event Rules

Execution APIs emit NDJSON on stdout. Clients must be able to render these event names:

- `started`
- `progress`
- `warning`
- `skipped`
- `completed`
- `failed`

Every event must include `event` and `domain`. Events that refer to a target path should include `path`. Completion events should include summary fields such as `exit_code`, `item_count`, `removed_count`, or `bytes` when available.

## Execution Plan Rules

Execution plans must be explicit JSON files. State-changing plans require:

- `confirmed: true`
- Domain-specific target fields, such as `targets`, `apps`, `uninstall_names`, `patterns`, or `paths`
- `dry_run: true` when the caller is previewing execution

Malformed, partial, unconfirmed, or escaped-target plans must fail before actions start. Failure should be emitted as API JSON or NDJSON events depending on the endpoint.

## Test Anchors

The API stability gate is enforced by:

- `tests/api_contract.test.mjs`
- `tests/fixtures/api/contracts.json`
- Swift models in `macos/RoomyUI/Sources/RoomyUICore/Models.swift`
- API client decoding in `macos/RoomyUI/Sources/RoomyUICore/RoomyAPIClient.swift`

When the contract changes, update all anchors in the same change.
