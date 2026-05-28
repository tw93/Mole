# Performance Baselines

Roomy touches large filesystems. Launch validation must include performance baselines so a correct change does not ship as a frustratingly slow one.

## Baseline Record

Record these fields for every measured run:

```text
Date:
Commit:
macOS version:
CPU architecture:
Disk type and free space:
Home directory size:
Command:
Dataset or scan root:
Warm or cold cache:
Elapsed time:
Peak memory when available:
Notes:
```

## Launch-Critical Measurements

Measure these flows before a launch tag or after scanner logic changes:

- `roomy clean --dry-run`
- `roomy uninstall --dry-run`
- `roomy purge --dry-run`
- `roomy installer --dry-run`
- `roomy analyze --json "$HOME"`
- `roomy status`
- `roomy api clean preview --json`
- `roomy api apps list --json`
- `roomy api purge preview --json`
- `roomy api installer preview --json`

## Regression Policy

- Compare against the most recent launch baseline on similar hardware.
- Treat large regressions in dry-run latency, analyzer traversal, app inventory, uninstall metadata, or status collection as launch risks.
- Prefer targeted scanner fixes over broad cache invalidation changes.
- Keep safety checks enabled during performance testing; disabling validation does not produce a launch-relevant number.

## Existing Automated Anchors

The CI and test suite already include focused performance and timeout checks:

- `tests/performance_uninstall_scan.sh`
- `tests/core_performance.bats`
- `tests/clean_system_maintenance.bats`
- Timeout coverage in `tests/core_timeout.bats`
- CI thresholds such as `ROOMY_PERF_BYTES_TO_HUMAN_LIMIT_MS` and `ROOMY_PERF_GET_FILE_SIZE_LIMIT_MS`

Manual launch baselines complement those tests by measuring realistic filesystem shape and install state.
