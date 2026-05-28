# Destructive Workflow UX

Roomy can remove local files. User-facing destructive flows must make the current state and risk visible before work starts, during execution, and after completion.

## Applies To

This gate applies to:

- `roomy clean`
- `roomy uninstall`
- `roomy purge`
- `roomy installer`
- `roomy restore`
- `roomy optimize`
- `roomy completion`
- `roomy touchid`
- `roomy update`
- `roomy remove`
- `roomy api <domain> execute`

## Copy Requirements

Every destructive or state-changing flow must make these points clear when relevant:

- Preview state: dry-run output must say that no files were changed.
- Scope: output must identify the category, scan root, app, or target set.
- Size and count: output should include item counts and byte estimates when available.
- Admin boundary: sudo-required work must be named before prompting or skipped when unavailable.
- Protected paths: skipped protected paths must be presented as intentional safety behavior.
- Confirmation: high-risk operations must require explicit confirmation or a confirmed execution plan.
- Recovery limits: output must distinguish Trash-backed actions from permanent deletion.
- Audit trail: successful destructive actions should mention the operation log or journal when useful.

## Interaction Requirements

- Dry-run must be available before real execution for launch-critical destructive flows.
- Failure output must preserve the safe default: skip, refuse, or stop instead of widening scope.
- Timeouts must produce understandable output instead of hanging indefinitely.
- API event streams must use `started`, `progress`, `warning`, `skipped`, `completed`, and `failed` consistently enough for native clients to show progress.
- Raw shell errors can be included in debug logs, but primary user output should explain the user decision or next action.

## Review Matrix

Before a launch tag, spot-check the wording for these situations:

| Flow | Required scenario |
| --- | --- |
| clean | Dry-run shows categories, estimate, protected skips, and no-change language |
| uninstall | Dry-run or plan shows app targets, remnants, LaunchAgent behavior, and Trash/permanent distinction |
| purge | Recent projects and ambiguous paths are not selected silently |
| installer | Unsupported or unsafe installer targets are skipped with reason |
| restore | Preview distinguishes restorable Trash items from unavailable entries |
| optimize | Sudo-required tasks explain denial or skip behavior |
| completion | Dry-run previews shell config writes |
| touchid | Dry-run previews PAM changes without modifying files |
| update | Dry-run explains source channel and target version |
| remove | Dry-run lists installed paths and caches before removal |
