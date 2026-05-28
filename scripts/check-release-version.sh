#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
    cat << 'EOF'
Usage: scripts/check-release-version.sh --tag TAG [--roomy PATH]

Validates that the release tag matches the VERSION declared by the Roomy CLI.
If the tag already exists locally, it must point at the current commit.
EOF
}

fail() {
    printf 'error: release version: %s\n' "$*" >&2
    exit 1
}

is_release_tag() {
    local value="$1"
    [[ "$value" =~ ^V[0-9]+[.][0-9]+[.][0-9]+$ ]]
}

tag=""
roomy_path="roomy"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tag"
            tag="$1"
            ;;
        --roomy)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --roomy"
            roomy_path="$1"
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
is_release_tag "$tag" || fail "--tag must use V<major>.<minor>.<patch> format"
[[ -f "$roomy_path" ]] || fail "missing Roomy CLI file: $roomy_path"

version="$(sed -n 's/^VERSION="\([0-9][0-9]*[.][0-9][0-9]*[.][0-9][0-9]*\)"$/\1/p' "$roomy_path" | head -n 1)"
[[ -n "$version" ]] || fail "could not read VERSION from $roomy_path"

expected="${tag#V}"
if [[ "$version" != "$expected" ]]; then
    fail "tag $tag does not match roomy VERSION=\"$version\""
fi

head_sha="$(git rev-parse HEAD 2> /dev/null || true)"
tag_sha="$(git rev-parse --verify -q "${tag}^{commit}" 2> /dev/null || true)"
if [[ -n "$head_sha" && -n "$tag_sha" && "$tag_sha" != "$head_sha" ]]; then
    fail "tag $tag already exists at $tag_sha, not current commit $head_sha"
fi

printf 'Release version passed: %s matches VERSION="%s"\n' "$tag" "$version"
