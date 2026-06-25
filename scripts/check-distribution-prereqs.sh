#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

repo="jake-seo-cl/roomy"
tap_repo="jake-seo-cl/homebrew-tap"
check_network=1
check_remotes=1
check_secrets=0

usage() {
    cat << 'EOF'
Usage: scripts/check-distribution-prereqs.sh [options]

Checks external distribution prerequisites before a public launch tag.

Options:
  --repo OWNER/REPO       Canonical release repository
                           (default: jake-seo-cl/roomy)
  --tap OWNER/REPO        Homebrew tap repository
                           (default: jake-seo-cl/homebrew-tap)
  --check-secrets         Verify release secrets with gh secret list
  --skip-network          Skip gh repo/secret checks
  --skip-remotes          Skip local git remote checks
  --help                  Show this help
EOF
}

fail() {
    printf 'error: distribution prerequisites: %s\n' "$*" >&2
    exit 1
}

require_slug() {
    local label="$1"
    local value="$2"

    if ! [[ "$value" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        fail "${label} must be OWNER/REPO, got: ${value}"
    fi
}

require_tool() {
    local tool="$1"

    command -v "$tool" > /dev/null 2>&1 || fail "$tool is required for network checks; rerun with --skip-network to skip"
}

remote_matches() {
    local expected_https="https://github.com/${repo}.git"
    local expected_ssh="git@github.com:${repo}.git"
    local remote
    local url

    while IFS= read -r remote; do
        [[ -n "$remote" ]] || continue
        url="$(git remote get-url "$remote" 2> /dev/null || true)"
        if [[ "$url" == "$expected_https" || "$url" == "$expected_ssh" ]]; then
            return 0
        fi
    done < <(git remote)

    return 1
}

check_repo_exists() {
    local slug="$1"
    local label="$2"
    local resolved

    resolved="$(gh repo view "$slug" --json nameWithOwner --jq .nameWithOwner 2> /dev/null || true)"
    [[ "$resolved" == "$slug" ]] || fail "$label is not accessible through gh: $slug"
}

check_secret() {
    local secret="$1"

    if ! gh secret list --repo "$repo" 2> /dev/null | awk '{ print $1 }' | grep -Fxq "$secret"; then
        fail "missing GitHub Actions secret on ${repo}: ${secret}"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --repo"
            repo="$1"
            ;;
        --tap)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tap"
            tap_repo="$1"
            ;;
        --check-secrets)
            check_secrets=1
            ;;
        --skip-network)
            check_network=0
            check_secrets=0
            ;;
        --skip-remotes)
            check_remotes=0
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

require_slug "release repository" "$repo"
require_slug "Homebrew tap repository" "$tap_repo"

printf 'Checking distribution prerequisites...\n'
printf '  release repository: %s\n' "$repo"
printf '  Homebrew tap: %s\n' "$tap_repo"

if [[ "$check_remotes" -eq 1 ]]; then
    if ! remote_matches; then
        fail "no local git remote points at https://github.com/${repo}.git or git@github.com:${repo}.git"
    fi
    printf '  ok: local git remote points at canonical release repository\n'
else
    printf '  skipped: local git remote check\n'
fi

if [[ "$check_network" -eq 1 ]]; then
    require_tool gh
    check_repo_exists "$repo" "release repository"
    check_repo_exists "$tap_repo" "Homebrew tap repository"
    printf '  ok: release repository and Homebrew tap are accessible through gh\n'

    if [[ "$check_secrets" -eq 1 ]]; then
        check_secret PAT_TOKEN
        check_secret HOMEBREW_GITHUB_API_TOKEN
        printf '  ok: required release secrets exist on %s\n' "$repo"
    else
        printf '  skipped: GitHub Actions secret check\n'
    fi
else
    printf '  skipped: gh repository and secret checks\n'
fi

printf 'Distribution prerequisites passed.\n'
