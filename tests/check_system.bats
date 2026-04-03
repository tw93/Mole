#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-checksys.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "check_disk_smart reports Verified status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
diskutil() {
    echo "   SMART Status:             Verified"
}
export -f diskutil
check_disk_smart
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMART Verified"* ]]
}

@test "check_disk_smart reports Failing status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
diskutil() {
    echo "   SMART Status:             Failing"
}
export -f diskutil
check_disk_smart
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMART Failing"* ]]
    [[ "$output" == *"back up immediately"* ]]
}

@test "check_disk_smart handles missing diskutil gracefully" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
export PATH="/nonexistent"
check_disk_smart
echo "survived"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "check_disk_smart handles unknown SMART status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
diskutil() {
    echo "   SMART Status:             Not Supported"
}
export -f diskutil
check_disk_smart
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMART: Not Supported"* ]]
}
