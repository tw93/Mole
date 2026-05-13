#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    printf 'error: launch readiness: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local file="$1"

    [[ -f "$file" ]] || fail "missing required file: $file"
}

require_match() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    require_file "$file"
    if ! grep -Eq "$pattern" "$file"; then
        fail "$label ($file)"
    fi
}

require_absent() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    require_file "$file"
    if grep -Eq "$pattern" "$file"; then
        fail "$label ($file)"
    fi
}

check_anchor() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    require_match "$file" "$pattern" "missing safety regression anchor: $label"
    printf '  ok: %s\n' "$label"
}

printf 'Checking launch scope lock...\n'
require_match "LAUNCH_READINESS.md" '^Production launch scope: CLI$' "production launch scope must stay explicit"
require_match "LAUNCH_READINESS.md" 'RoomyUI is excluded from production release' "RoomyUI exclusion must stay explicit"
require_match "LAUNCH_READINESS.md" 'Scope-change rule:' "scope-change rule must be documented"
require_absent ".github/workflows/release.yml" 'RoomyUI\.app|Roomy\.dmg|\.dmg|notarization\.zip' "release workflow must not publish RoomyUI artifacts while launch scope is CLI-only"
printf 'Launch scope lock passed.\n\n'

printf 'Checking safety regression matrix...\n'
require_match "LAUNCH_READINESS.md" '^## Goal 4: Safety Regression Matrix$' "safety regression matrix must be documented"
require_match "LAUNCH_READINESS.md" 'Safety gate: every destructive command must keep dry-run, protected-path, path traversal/symlink, sudo-boundary, and restore/logging coverage\.' "safety gate must be documented"

check_anchor "clean dry-run" "tests/clean_core.bats" 'roomy clean --dry-run'
check_anchor "uninstall dry-run" "tests/api_contract.test.mjs" 'const uninstallPlan'
check_anchor "optimize dry-run" "tests/optimize.bats" 'dry-run'
check_anchor "purge dry-run" "tests/purge.bats" 'roomy purge: accepts --dry-run flag'
check_anchor "installer dry-run" "tests/installer.bats" 'installer\.sh accepts --dry-run option'
check_anchor "remove dry-run" "tests/uninstall.bats" 'remove_roomy dry-run keeps manual binaries and caches'
check_anchor "completion dry-run" "tests/completion.bats" 'completion --dry-run previews changes without writing config'
check_anchor "touchid dry-run" "tests/cli.bats" 'touchid enable --dry-run does not modify pam file'
check_anchor "update dry-run" "tests/api_contract.test.mjs" 'const updatePlan'
check_anchor "storage trash dry-run" "tests/api_contract.test.mjs" 'storage execute dry-runs Trash actions'
check_anchor "launcher dry-run" "tests/api_contract.test.mjs" 'const launcherPlan'
check_anchor "plan confirmation" "tests/api_contract.test.mjs" 'execute plan schemas reject malformed and partial plans'
check_anchor "protected paths" "tests/core_safe_functions.bats" 'rejects protected extension paths'
check_anchor "path traversal" "tests/core_safe_functions.bats" 'rejects path traversal'
check_anchor "protected symlink target" "tests/core_safe_functions.bats" 'rejects symlink to protected system path'
check_anchor "sudo symlink refusal" "tests/core_safe_functions.bats" 'safe_sudo_remove refuses symlink paths'
check_anchor "no-auth sudo boundary" "tests/core_common.bats" 'sudo helpers do not invoke sudo in no-auth test mode'
check_anchor "denied sudo boundary" "tests/optimize.bats" 'sudo-required optimize tasks short-circuit without invoking sudo when access denied'
check_anchor "brew dry-run sudo boundary" "tests/brew_uninstall.bats" 'skips brew sudo pre-auth in dry-run mode'
check_anchor "restore preview" "tests/cli.bats" 'roomy restore previews a restorable Trash item'
check_anchor "deletion audit log" "tests/file_ops_roomy_delete.bats" 'writes a tab-separated log line per call'
check_anchor "operation journal" "tests/core_common.bats" 'writes structured operation journal JSONL'
check_anchor "unsafe rm workflow" ".github/workflows/test.yml" 'Check for unsafe rm usage'

printf 'Safety regression matrix passed.\n'
