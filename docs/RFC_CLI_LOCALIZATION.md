# RFC: Localized terminal output for Mole CLI (macOS)

Status: proposal, not accepted. No code in this change.

## Summary

Mole for Mac already lets users pick an interface language; Mole CLI (macOS) prints English only, and every README
translation keeps its sample output in English for that reason (`.claude/rules/readme.md`). This RFC proposes
localizing the human-readable terminal text of `mo`, starting with Polish, while keeping every machine-readable surface
in English. It asks the maintainer for a yes or no on the approach before any implementation PR is opened.

## Scope

Localized:

- Section titles, item labels, confirmations, prompts, summaries and help text printed to a terminal.
- Menu labels and key hints in the interactive menu, `lib/ui/` selectors and the `analyze` / `status` TUIs.

Never localized (stable contracts that scripts, Mole for Mac and the support diagnostic parse):

- JSON and NDJSON output (`mo status --json`, `--watch`, `mo analyze --json`, `mo history --json`,
  `mo uninstall --list`), including field names and enum values such as `scan_status`.
- `~/Library/Logs/mole/operations.log` rows, deletion-log TSV fields and fixed `SKIPPED` reasons.
- Command names, flags, whitelist and `purge_paths` file formats, exit codes.
- `--debug` diagnostics, so bug reports stay readable by the maintainer.

## Language selection

No new flag or config key. Mole follows the macOS interface language:

1. Read the first entry of `defaults read -g AppleLanguages` once at startup, before any script exports `LC_ALL=C`
   (`bin/installer.sh`, `bin/optimize.sh` and others do this today for numeric parsing).
2. If a catalog exists for that language, use it; otherwise use English.
3. Non-interactive output (stdout not a TTY) and `MOLE_TEST_MODE` always use English, so pipes, CI and the Bats suite
   see the text they see today.

A user who wants English on a Polish Mac would set `LANG=en_US.UTF-8` for the call, which needs no Mole-specific knob.
A dedicated `MOLE_LANG` variable is rejected unless the maintainer prefers an explicit override; per `AGENTS.md` a new
environment variable carries the weight of a new setting.

## Implementation sketch

Shell (Bash 3.2, so no associative arrays and no `gettext`, which stock macOS does not ship):

- `lib/core/i18n.sh` defines `mole_t <key> [printf args...]`, which looks up the key in a `case` statement generated
  from the active catalog and falls back to the English text when a key is missing.
- Catalogs live in `lib/i18n/en.sh` and `lib/i18n/pl.sh` as plain `key=text` data, sourced once. English is the
  source of truth; a missing translation never blocks output.
- Call sites change from `log_success "Cleanup complete"` to `log_success "$(mole_t clean.complete)"`. Interpolated
  values (sizes, counts, paths) stay `printf` arguments so word order can differ per language.

Go (`cmd/analyze`, `cmd/status`):

- A small `internal/i18n` package with embedded per-language maps and the same fallback rule; the Go binaries receive
  the resolved language from the shell entry point so both halves always agree.

Gates:

- A `scripts/audit_i18n.py` check that every key used in code exists in `en`, and reports (without failing) keys
  missing from other catalogs.
- Column alignment: localized labels in fixed-width rows (`mo status`, `mo analyze`, selectors) are measured by display
  width, and the gate fails a catalog entry that overflows its column.

## Measured surface

Counted on `main` at 06e96164:

| Surface | Count |
|---|---|
| `echo` / `printf` / logging call lines in `mole`, `bin/`, `lib/` | about 2,000 |
| `note_activity`, `log_error`, `log_warning`, `start_section`, `log_info`, `log_success` calls | 412 |
| Capitalized string literals in `cmd/analyze/view.go` and `cmd/status/view.go` | 71 |
| Bats assertions that match `$output` text | about 2,700 |

Because tests and non-TTY runs stay English, the Bats assertions keep working unchanged; only new tests that force a
catalog need to be added.

## Rollout

1. Infrastructure only: `mole_t`, the English catalog for one command (`mo clean` summary and section titles), the audit
   gate and tests proving English output is byte-identical to today.
2. Polish catalog for that command.
3. Remaining commands one per PR, each with its catalog keys and a PTY test of the localized frame.
4. Go TUIs last, after the shell side has settled the key naming.

Each step is reviewable alone and can stop without leaving half-translated screens: a command is either fully
cataloged or untouched.

## Product decision filter (`AGENTS.md`)

1. Belongs to existing commands; no new command or surface.
2. Safe by default: no change to what Mole deletes, logs or reports in machine formats; English stays the fallback.
3. Verifiable: `--dry-run` and JSON behave exactly as today.
4. Not applicable (no new cleanup target).
5. Alternative considered: leaving localization to Mole for Mac only. That remains a valid answer, and this RFC should
   be closed if the maintainer prefers it.

## Costs and risks

- Every future user-facing string needs a catalog key, which slows small fixes and adds review load.
- Translations can drift from English meaning; the fallback hides missing keys but not stale ones.
- Wider labels can break the dense one-screen layouts the CLI is built around.
- Support threads would see localized screenshots; `--debug` stays English to limit this.

## Open questions for the maintainer

1. Is localized CLI output in scope at all, or should it stay a Mole for Mac capability?
2. Follow `AppleLanguages` only, or also accept an explicit `MOLE_LANG`?
3. Should the Windows CLI follow the same design, recorded in `SYNC.md`, or stay English?
