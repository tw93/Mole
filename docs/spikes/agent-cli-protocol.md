# Agent CLI protocol spike

Status: five iterations and final proof complete. This is an experiment log,
not a shipped interface specification.

## Baseline

- `mo analyze --json [path]` emits one indented JSON document after the scan.
- `mo status --watch` emits unversioned metric snapshots as NDJSON.
- `mo history --json` emits one JSON document.
- Destructive commands support dry-run, but their preview output is human text;
  `clean` additionally writes a path list outside stdout.
- The human TUI and existing human-readable output are compatibility surfaces
  and remain unchanged by this spike.

The initial read-only sample against a large local repository tree completed in
0.57s. It returned 69 top-level entries and 20 large-file records: 14,969 bytes
indented, or 11,280 bytes compacted. This is small enough that scan latency does
not yet justify streaming, but large enough that explicit result bounding may
materially reduce agent context.

## Current proposed contract

The current analysis proposal is additive:

`mo analyze --json [--limit N] [--compact] [path]`

- scan totals continue to describe the complete scope;
- `entries` contains at most the largest `N` top-level entries;
- `schema_version`, `entries_total`, `entries_returned`, and
  `entries_truncated` make the bounded response explicit;
- `large_files` retains its existing independently bounded semantics;
- omitting `--limit` preserves the existing entry set;
- the flag is rejected outside JSON mode.
- `--compact` changes encoding only; the decoded document is identical.

No run ID, durable storage, or apply path is proposed.

The current preview proposal covers:

`mo clean --dry-run --json`

`mo purge --dry-run --json`

```json
{
  "schema_version": 1,
  "command": "clean",
  "mode": "preview",
  "dry_run": true,
  "apply_supported": false,
  "scope": {"system_included": false, "external_path": null},
  "summary": {
    "status": "complete",
    "candidate_groups": 2,
    "items": 37,
    "potential_bytes": 5120
  },
  "warnings": [
    {
      "code": "system_scope_excluded",
      "message": "System-level candidates require a pre-authorized sudo session and were not scanned."
    }
  ],
  "candidates": [
    {
      "path": "<absolute path>",
      "action": "remove",
      "recoverability": "permanent",
      "safety": "eligible_after_runtime_validation"
    }
  ]
}
```

Structured preview data is stdout-only; the existing human dry-run rendering is
sent to stderr. JSON without `--dry-run` is rejected before cleanup starts.

## Iterations

| Iteration | Hypothesis and acceptance check | Evidence | Decision / next hypothesis |
| --- | --- | --- | --- |
| 1 | A JSON-only `--limit N` can reduce response volume without hiding full-scan totals. Accept if focused tests prove stable metadata and top-N ordering, the TUI is untouched, and the real sample is materially smaller. | Focused JSON tests passed. The real `--limit 10` sample returned 10/69 entries with unchanged totals in 0.50s and shrank from 14,969 to 5,362 bytes (64%). Using `--limit` without `--json` exited 2 with a direct diagnostic. | Keep the limit and explicit truncation metadata. Next test whether native compact encoding removes avoidable whitespace without changing the document contract. |
| 2 | Native `--compact` JSON can remove avoidable formatting tokens while preserving the exact schema and human TUI. Accept if compact and indented documents decode identically, invalid non-JSON use is rejected, completions expose the option, and the real bounded sample shrinks materially. | Focused Go tests and all 19 completion tests passed. Canonicalized real documents matched. Compact output reduced the bounded sample from 5,362 to 4,215 bytes (21%); non-JSON use exited 2. | Keep the opt-in encoder to preserve default formatting. Further analyzer controls are lower value than the missing machine-readable preview contract. |
| 3 | A versioned `clean --dry-run --json` document can expose the authoritative preview list on stdout without terminal scraping. Accept if JSON is impossible without dry-run, stdout is parseable and prose-free, diagnostics stay on stderr, candidates carry stable path/action/safety fields, tests prove no fixture is removed, and a temp-HOME CLI probe exercises the real command. | Two focused Bats tests and all completion tests passed. A normal temp-HOME dry-run emitted one 596-byte JSON line on stdout and 107 human-diagnostic lines on stderr, reported 2 candidate groups/37 items, and preserved the cache fixture. The non-dry-run negative control exited 2 with empty stdout. | Keep the stdout/stderr split and fail-closed flag dependency. Next test whether the same envelope generalizes to `purge` without erasing its rebuildable-artifact semantics. |
| 4 | The preview envelope can cover `purge --dry-run --json` with shared top-level fields but command-specific recoverability and scope. Accept if a temp project fixture yields parseable stdout-only JSON, candidate paths come from the immutable purge selection, recoverability is `rebuild`, non-dry-run JSON is rejected, and focused tests prove the artifact remains. | Two focused Bats tests and all completion tests passed. A temp-project dry-run emitted one 455-byte JSON line plus 11 stderr lines, reported one 4 KiB validated artifact, and preserved it. The non-dry-run negative control exited 2. The real bounded analysis sample remained 4,215 bytes in iterations 3 and 4. | Keep the shared envelope and command-specific recoverability. NUL-delimited internal capture avoids corrupting unusual candidate paths. Next determine whether a plan ID provides real correlation without implying apply authority. |
| 5 | Observation rejected a content-derived `plan_id`: hashing is portable, but without stored plans, status lookup, or apply receipts the ID would be decorative and could imply authority it does not have. The refined hypothesis is that structured safety warnings add more value. Accept if both preview commands expose a stable `warnings` array, excluded clean system scope has a machine code, purge can return an empty array, tests cover both shapes, and stale/cancel/failure semantics are documented without adding storage or apply. | Focused clean and purge JSON tests passed. Clean returns coded `system_scope_excluded` when sudo scope is absent; purge returns an empty stable array. The iteration-5 real analysis sample remained 4,215 bytes. | Keep structured warnings. Reject plan/run IDs, NDJSON streaming, durable state, and apply semantics in this spike. Use each final JSON document plus process exit as the complete receipt. |

## Commands and compact evidence

### Baseline

```text
./mole --help
./mole analyze --help
./mole clean --help
./mole purge --help
./mole installer --help
./mole optimize --help
./mole analyze --json <large-local-tree>
MOLE_TEST_NO_AUTH=1 go test ./cmd/analyze -run 'JSON|Limit' -count=1
make build
./mole analyze --json --limit 10 <large-local-tree>
./mole analyze --limit 2 <temporary-directory>
MOLE_TEST_NO_AUTH=1 go test ./cmd/analyze -run 'JSON|Limit|Compact' -count=1
MOLE_TEST_NO_AUTH=1 bats tests/completion.bats
./mole analyze --json --limit 10 --compact <large-local-tree>
MOLE_TEST_NO_AUTH=1 bats --filter 'clean.*json' tests/clean_core.bats
MOLE_TEST_NO_AUTH=1 bats --filter 'purge.*json' tests/purge.bats
./mole analyze --json --limit 10 --compact <large-local-tree>
./mole analyze --compact <temporary-directory>
MOLE_TEST_NO_AUTH=1 bats --filter 'clean.*json' tests/clean_core.bats
HOME=<temporary-home> MOLE_TEST_NO_AUTH=1 MOLE_TEST_MODE=0 \
  ./mole clean --dry-run --json
HOME=<temporary-home> MOLE_TEST_NO_AUTH=1 ./mole clean --json
MOLE_TEST_NO_AUTH=1 bats --filter 'purge.*json' tests/purge.bats
HOME=<temporary-home> MOLE_TEST_NO_AUTH=1 \
  ./mole purge --dry-run --json < /dev/null
./mole analyze --json --limit 10 --compact <large-local-tree>
```

The real analysis was redirected to a temporary proof directory before being
summarized. No repository inventory was printed or written to this document.

## Token-volume observations

- Indented JSON adds about 33% over the compact byte count in the initial
  sample.
- Top-level entries, rather than summary fields, dominate the response.
- The existing 20-record `large_files` list is already bounded internally but
  does not disclose that policy in the command contract.
- `--limit 10` reduced the indented real sample by 9,607 bytes (64%) while
  preserving complete scan totals and the independently bounded large-file list.
- Compact encoding removed another 1,147 bytes (21%) from the bounded sample
  without changing its decoded document.

## Safety findings

- Read-only analysis does not modify the sampled repository tree.
- A limit must affect presentation only, never scan accounting or deletion
  selection.
- A result bound must state that truncation occurred; silently slicing paths
  would be unsafe for follow-up cleanup decisions.
- Machine JSON is accepted only with dry-run; a format flag cannot activate a
  removal path.
- Clean candidates use `recoverability: "permanent"` because the normal clean
  deletion funnel is not recoverable through Trash.
- The preview path list groups some underlying files by parent. The document
  therefore distinguishes `candidate_groups` from `items`.
- Purge candidates are captured only after the configured-root safety
  revalidation and use NUL-delimited internal records, so whitespace in a path
  does not become a candidate boundary.
- `recoverability` is command-specific: `clean` is `permanent`; `purge` is
  `rebuild`.
- No destructive Mole command has been executed.

## Rejected or deferred ideas

- An `mo agent` subsystem: outside product direction and unnecessary.
- Streaming analysis/events: rejected for this spike. All five real samples
  completed quickly enough that a bounded final document was simpler, and
  stdout-only receipts eliminate polling without a progress protocol.
- Plan/run IDs: rejected. A hash is technically portable, but without durable
  plan storage, lookup, or an apply receipt it adds no follow-up capability and
  risks implying authorization.
- Apply commands: rejected. Preview identifiers and documents never authorize
  deletion.
- Replacing stderr diagnostics with structured progress: deferred. The 107-line
  temp-HOME clean trace is noisy, but stdout already remains parseable and the
  scan completed without polling.

## Remaining limitations

- Installer, uninstall, and optimize previews remain human-oriented; this spike
  covers only clean and purge.
- Analyze JSON remains indented by default for compatibility; agents must opt
  into `--compact`.
- Analysis has no minimum-size filter or pagination.
- Cancellation and failures are process-level behavior, not structured events.
- Preview documents are snapshots, not stored plans. They become stale as soon
  as the filesystem changes; consumers must rerun the dry-run before any
  separately authorized destructive invocation.
- Cancellation exits 130 and may produce no final JSON receipt. Other failures
  exit nonzero with diagnostics on stderr; consumers must not treat partial or
  absent stdout as a plan.
- There is no follow-up status lookup because there is no durable run state.

## Final proof and readiness

Fresh final proof:

```text
./scripts/check.sh --format
env -u NO_COLOR MOLE_TEST_NO_AUTH=1 bats \
  tests/clean_core.bats tests/clean_apps.bats \
  tests/clean_system_caches.bats tests/purge.bats \
  tests/purge_config_paths.bats tests/completion.bats tests/cli.bats
env -u NO_COLOR MOLE_SKIP_FINDER_TESTS=1 MOLE_TEST_NO_AUTH=1 make verify
HOME=<temporary-home> MOLE_TEST_NO_AUTH=1 MOLE_TEST_MODE=0 \
  ./mole clean --dry-run --json
HOME=<temporary-home> MOLE_TEST_NO_AUTH=1 \
  ./mole purge --dry-run --json < /dev/null
./mole analyze --json --limit 10 --compact <large-local-tree>
git diff --check
git status --short
```

- Formatting completed cleanly.
- All 232 touched-surface Bats tests passed. `NO_COLOR` was removed because two
  existing tests intentionally assert ANSI-colored glyphs.
- `make verify` passed ShellCheck, shell syntax, golangci-lint, and all Go
  packages. Finder-dependent Trash tests used their documented skip flag; this
  spike does not change deletion behavior.
- The final temp-HOME clean receipt was one 803-byte JSON line with two
  candidates and a structured excluded-system warning. A path containing the
  human preview delimiter round-tripped exactly through the separate
  NUL-delimited machine stream. The fixture remained.
- The final temp-HOME purge receipt was one 483-byte JSON line with one
  validated rebuildable candidate. The fixture remained.
- The final real analysis completed in 0.49s and emitted 4,215 bytes, returning
  10 of 69 entries with complete totals for 465,251 files.

Readiness: **implementation-ready as a spike**, confidence **8/10**. The branch
has clean local proof and real safe CLI evidence. Confidence is below 10
because only `clean` and `purge` exercise the shared preview shape; a
pre-authorized system-scope clean was intentionally not run; Finder deletion
integration was skipped as unrelated and unsafe; and the streaming decision is
based on one real repository tree rather than a deliberately slow volume.

Recommendation: **narrowly promote**, not broadly standardize yet. Keep the
analysis bounds and the common clean/purge preview envelope, then review the
schema before extending it to installer, uninstall, or optimize. Do not add
run IDs, durable plan storage, status lookup, or apply semantics without a
separate product decision and safety design.

## Proof caveats

- Two attempts at the broad `go test ./cmd/analyze` suite, including the
  required `MOLE_TEST_NO_AUTH=1` environment, hit existing 30/60-second Finder
  Trash timeouts in `TestDeletePathWithProgress`, `TestTrashPathWithProgress`,
  and `TestDeleteMultiplePathsCmdHandlesParentChild`. These runs are not cited
  as iteration proof and no expectations were changed. The touched JSON surface
  was rerun cleanly with a focused test selection.
