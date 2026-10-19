---
paths:
  - "tests/**"
  - "scripts/test.sh"
  - "scripts/e2e_macos.py"
  - "scripts/audit_bats_assertions.py"
  - ".github/workflows/*.yml"
  - "cmd/**/*_test.go"
---

# Tests and CI

Suite-level rules (summary line, `$TERM`, cancelled CI runs, never piping into `tail` / `head`) are in `AGENTS.md` (Verification).

- `tests/helpers/common.bash` is loaded by every Bats file: shared temp-`HOME` setup plus fail-loud `PATH` stubs for commands a test must never run for real. `tests/fuzz_corpus/` holds property-test corpora consumed by `path_validation_fuzz.bats`.
- `check.sh` does not lint `tests/`; the first step of `scripts/test.sh` runs `shellcheck --rcfile .shellcheckrc` over every test script, and CI's Validation job fails there. Run that shellcheck on new or changed test code before committing it, and annotate literal `$HOME`, `~/` or single-quoted shim bodies with `# shellcheck disable=SCxxxx  # reason`.
- **The core bats subset job does not build the Go helpers.** `.github/workflows/test.yml` runs `bats tests/cli.bats` and friends on macos-15/macos-26 without `make build`, so anything shelling out to `mo analyze` or `mo status` there reaches `bin/analyze.sh`'s missing-binary message instead of the Go flag parser. A local run after `make build` hides this and reports green. Assert on behavior both binaries share, or leave those two commands to `cmd/*/usage_test.go`.
- **A Bats case that `eval`s one function out of `bin/` degrades silently when that function gains a helper.** Bash does not abort on `x=$(missing_command)` even under `set -euo pipefail`: the variable is simply empty and the function keeps running, so the case still passes while exercising the pre-change fallback path. Extract the whole helper set the function calls, not just the function under test.
- **A bare `[[ ... ]]` inside a `run ... /bin/bash <<'EOF'` heredoc may assert nothing.** A later successful command can make the inner script return zero, so end meaningful in-heredoc assertions with `|| exit 1`, or print the value and assert on Bats `$output`. A final assertion and a line inside a mock may legitimately be bare; classify the call site before changing it.
  - The same holds in the test body itself, where Bats runs on macOS `/bin/bash` 3.2 and a failing bare `[[ ]]` before the last statement never trips errexit: end it with `|| return 1`. The same holds for a bare `(( a < b ))` comparison, which bash 3.2 also lets fall through.
  - `scripts/audit_bats_assertions.py` enforces all of this from `check.sh` in test bodies and `run ... bash <<EOF` script bodies; mock function bodies, data heredocs and a computation without a comparison such as `(( n++ ))` are exempt.
  - Every guard test must be observed red against the pre-fix path and green after restoration. The complete vacuous-test and shared-`HOME` checklist lives in `.claude/skills/bugs/references/test-validity-and-refusal-diagnostics.md`.
- Tests that intentionally replace `safe_clean` are a seam; see the `declare -f` shim rule in `.claude/rules/clean.md`.
- `scripts/e2e_macos.py` is the real-Mac release run (`.claude/skills/release-flow/SKILL.md` pre-flight step 7), not a CI job: it needs a logged-in user session, network and the user's real `~/Downloads`. Its first run found two defects that every unit test missed, an analyze cache that ignored directory changes for 30 minutes and `--help` refused by `update` and `remove`, so when a step fails, read its transcript before loosening the step. `--keep-going` permits only independent checks: failed build, download, integrity, install or launch steps cannot authorize dependent mutations, and a failed uninstall retains its installer. `tests/e2e_harness_test.py`, called from `tests/cli.bats`, locks this with mocked actions and network; it does not run the real fixture.
- Release preflight requires Check/Validation/CodeQL/Nix success on the tagged SHA. CodeQL and Nix ignore docs-only pushes, so the gate allows those two to be absent only when every changed file is `docs/**` or `*.md` and the nearest code-changing ancestor has both runs green; every required workflow also accepts `workflow_dispatch` so a missing run has a recovery path. A cancelled run is still not evidence.
