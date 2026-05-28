#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

printf 'Running Roomy release preflight...\n'

git diff --check

scripts/check-launch-readiness.sh
scripts/check-unsafe-rm.sh

if [[ -f package.json && ! -f package-lock.json ]]; then
    fail "package.json is present but package-lock.json is missing"
fi

tracked_generated=$(git ls-files -- .cache .build .roomy-ui node_modules test-results playwright-report awesome-design-md)
if [[ -n "$tracked_generated" ]]; then
    printf '%s\n' "$tracked_generated" >&2
    fail "generated, local runtime, or reference directories are tracked"
fi

tracked_release_artifacts=$(git ls-files -- '*.dmg' '*.dmg.sha256' '*.notarization.zip')
if [[ -n "$tracked_release_artifacts" ]]; then
    printf '%s\n' "$tracked_release_artifacts" >&2
    fail "generated release artifacts are tracked"
fi

if find . \
    -path './.git' -prune -o \
    -path './node_modules' -prune -o \
    -path './.build' -prune -o \
    -name '.DS_Store' -print | grep -q .; then
    fail ".DS_Store files are present"
fi

if [[ -n "$(git ls-files --others --exclude-standard -- . ':(exclude)awesome-design-md/**')" ]]; then
    printf 'warning: untracked files remain; review them before tagging a release\n' >&2
    git ls-files --others --exclude-standard -- . ':(exclude)awesome-design-md/**' >&2
fi

printf 'Release preflight passed.\n'
