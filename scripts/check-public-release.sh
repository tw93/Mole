#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
    cat << 'EOF'
Usage: scripts/check-public-release.sh --tag TAG [options]

Runs the public release gate for a tag before GitHub release publication.

Required:
  --tag TAG       Release tag, for example V1.39.0

Options:
  --notes PATH    Override release notes path
  --record PATH   Override clean-machine drill record path
  --evidence PATH Override clean-machine drill evidence path, archive, or URL
  --roomy PATH    Override Roomy CLI path for version checks
  --skip-site     Skip the landing page smoke check
  --skip-clean-machine
                  Skip clean-machine record validation for pre-asset draft staging
  --allow-dirty   Allow uncommitted or untracked files in local dry-runs
  --full          Also run the full local test script
  --final         Run the final public-release gate: disallow skipped/dirty
                  gates and run the full local test script
  --help          Show this help

Local environment:
  CLI release gates do not load .env files. Homebrew publishing secrets must be
  configured in GitHub Actions, and native app signing/notarization variables
  are only for preview RoomyUI builds outside the current CLI release scope.
EOF
}

fail() {
    printf 'error: public release gate: %s\n' "$*" >&2
    exit 1
}

record_failure() {
    printf 'error: public release gate: %s\n' "$*" >&2
    gate_failed=1
}

run_site_check_with_retry() {
    local attempts="${ROOMY_SITE_CHECK_RETRIES:-2}"
    local delay="${ROOMY_SITE_CHECK_RETRY_DELAY_SEC:-2}"

    [[ "$attempts" =~ ^[0-9]+$ && "$attempts" -ge 1 ]] || attempts=2
    [[ "$delay" =~ ^[0-9]+$ ]] || delay=2

    local attempt
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if npm run site:check; then
            return 0
        fi
        if [[ "$attempt" -lt "$attempts" ]]; then
            printf 'warning: site smoke check failed; retrying (%s/%s)\n' "$attempt" "$attempts" >&2
            sleep "$delay"
        fi
    done

    return 1
}

warn_local_env_files() {
    local -a files=()
    local file

    for file in .env .env.*; do
        [[ -e "$file" ]] || continue
        files+=("$file")
    done

    [[ "${#files[@]}" -eq 0 ]] || {
        printf 'warning: local .env files are ignored by CLI release gates: %s\n' "${files[*]}" >&2
        printf 'warning: use GitHub Actions secrets for publishing; use signing env vars only for preview RoomyUI builds\n' >&2
    }
}

tag=""
notes=""
record=""
evidence=""
roomy_path=""
head_sha=""
skip_site=0
skip_clean_machine=0
allow_dirty=0
run_full=0
final_gate=0
gate_failed=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tag"
            tag="$1"
            ;;
        --notes)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --notes"
            notes="$1"
            ;;
        --record)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --record"
            record="$1"
            ;;
        --evidence)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --evidence"
            evidence="$1"
            ;;
        --roomy)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --roomy"
            roomy_path="$1"
            ;;
        --skip-site)
            skip_site=1
            ;;
        --skip-clean-machine)
            skip_clean_machine=1
            ;;
        --allow-dirty)
            allow_dirty=1
            ;;
        --full)
            run_full=1
            ;;
        --final)
            final_gate=1
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
    shift
done

[[ -n "$tag" ]] || fail "provide --tag"
if [[ "$final_gate" -eq 1 ]]; then
    [[ "$allow_dirty" -eq 0 ]] || fail "--final cannot be combined with --allow-dirty"
    [[ "$skip_site" -eq 0 ]] || fail "--final cannot be combined with --skip-site"
    [[ "$skip_clean_machine" -eq 0 ]] || fail "--final cannot be combined with --skip-clean-machine"
    run_full=1
fi

printf 'Running Roomy public release gate for %s...\n' "$tag"
warn_local_env_files

git update-index -q --refresh || true
head_sha="$(git rev-parse HEAD 2> /dev/null || true)"

if [[ "$allow_dirty" -eq 0 ]]; then
    dirty_worktree="$(
        git status --porcelain --untracked-files=all -- \
            . \
            ':(exclude)node_modules/**' \
            ':(exclude)test-results/**' \
            ':(exclude)playwright-report/**' \
            ':(exclude).cache/**'
    )"
    if [[ -n "$dirty_worktree" ]]; then
        printf '%s\n' "$dirty_worktree" >&2
        record_failure "worktree has uncommitted or untracked source changes; commit or stash before tagging"
    fi
fi

if ! scripts/release-preflight.sh; then
    record_failure "release preflight failed"
fi

version_args=(--tag "$tag")
if [[ -n "$roomy_path" ]]; then
    version_args+=(--roomy "$roomy_path")
fi
if ! scripts/check-release-version.sh "${version_args[@]}"; then
    record_failure "release version check failed"
fi

notes_args=(--tag "$tag")
if [[ -n "$notes" ]]; then
    notes_args+=(--notes "$notes")
fi
if ! scripts/check-release-notes.sh "${notes_args[@]}"; then
    record_failure "release notes check failed"
fi

if [[ "$skip_clean_machine" -eq 0 ]]; then
    record_args=(--tag "$tag")
    if [[ -n "$record" ]]; then
        record_args+=(--record "$record")
    fi
    if [[ -n "$evidence" ]]; then
        record_args+=(--evidence "$evidence")
    fi
    if [[ -n "$head_sha" ]]; then
        record_args+=(--commit "$head_sha")
    fi
    if ! scripts/check-clean-machine-drill-record.sh "${record_args[@]}"; then
        record_failure "clean-machine drill record check failed"
    fi
else
    printf 'Skipping clean-machine drill record check for pre-asset draft staging.\n'
fi

if [[ "$skip_site" -eq 0 ]]; then
    if ! run_site_check_with_retry; then
        record_failure "landing page smoke check failed"
    fi
fi

if [[ "$run_full" -eq 1 ]]; then
    if ! scripts/test.sh; then
        record_failure "full test script failed"
    fi
fi

if [[ "$gate_failed" -ne 0 ]]; then
    fail "one or more public release checks failed"
fi

printf 'Public release gate passed for %s.\n' "$tag"
