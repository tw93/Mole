#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home postman-cache
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    export POSTMAN_TEST_HOME="$HOME/case-$BATS_TEST_NUMBER"
    local root="$POSTMAN_TEST_HOME/Library/Application Support/Postman"
    local partition leaf
    for partition in alpha beta; do
        for leaf in Cache 'Code Cache'; do
            mkdir -p "$root/Partitions/$partition/$leaf/.hidden"
            printf cache > "$root/Partitions/$partition/$leaf/data"
            printf hidden > "$root/Partitions/$partition/$leaf/.hidden/data"
        done
        for leaf in IndexedDB 'Local Storage' 'Session Storage' Network 'Service Worker' WebStorage GPUCache; do
            mkdir -p "$root/Partitions/$partition/$leaf"
            printf state > "$root/Partitions/$partition/$leaf/keep"
        done
        printf cookie > "$root/Partitions/$partition/Cookies"
    done
    mkdir -p "$root/collections/Cache" "$root/Cache" "$root/history" "$POSTMAN_TEST_HOME/custom-postman/Partitions/alpha/Cache"
    printf collection > "$root/collections/Cache/keep"
    printf default > "$root/Cache/keep"
    printf history > "$root/history/keep"
    printf config > "$root/config.json"
    printf custom > "$POSTMAN_TEST_HOME/custom-postman/Partitions/alpha/Cache/keep"
}

@test "Postman cleanup removes only two cache leaves in each partition in one row through the real sink" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
MOLE_CURRENT_COMMAND=clean
root="$HOME/Library/Application Support/Postman"
clean_dev_api_tools
for partition in alpha beta; do
    for leaf in Cache 'Code Cache'; do
        [[ -d "$root/Partitions/$partition/$leaf" && ! -e "$root/Partitions/$partition/$leaf/data" && ! -e "$root/Partitions/$partition/$leaf/.hidden" ]] || exit 1
    done
    for leaf in IndexedDB 'Local Storage' 'Session Storage' Network 'Service Worker' WebStorage GPUCache; do
        [[ "$(cat "$root/Partitions/$partition/$leaf/keep")" == state ]] || exit 1
    done
    [[ "$(cat "$root/Partitions/$partition/Cookies")" == cookie ]] || exit 1
done
for kept in "$root/collections/Cache/keep" "$root/Cache/keep" "$root/history/keep" "$root/config.json" \
    "$HOME/custom-postman/Partitions/alpha/Cache/keep"; do
    [[ -f "$kept" ]] || exit 1
done
[[ "$files_cleaned" == 8 ]] || exit 1
grep -q 'REMOVED.*Partitions/' "$HOME/Library/Logs/mole/operations.log" || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | grep -c 'Postman partition')" -eq 1 ] || { echo "$output"; return 1; }
}

@test "Postman preview leaves every cache unchanged" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=true
MOLE_DRY_RUN=1
clean_postman_partition_caches
for partition in alpha beta; do
    for leaf in Cache 'Code Cache'; do
        root="$HOME/Library/Application Support/Postman/Partitions/$partition/$leaf"
        [[ -f "$root/data" && -f "$root/.hidden/data" ]] || exit 1
    done
done
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Postman partition"* && "$output" == *dry* ]] || return 1
}

@test "Postman cleanup keeps caches when its owner is busy or unknown" {
    for process_rc in 0 2; do
        run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" PROCESS_RC="$process_rc" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return "$PROCESS_RC"; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$HOME/Library/Application Support/Postman/Partitions/alpha/Cache/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Postman cleanup is dispatched by the API tool cleaner" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
safe_clean() { :; }
clean_postman_partition_caches() { echo POSTMAN_DISPATCHED; }
clean_dev_api_tools
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *POSTMAN_DISPATCHED* ]] || return 1
}

@test "Postman process probe covers main and helper processes without unrelated matches" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() {
    case "$1" in
        -x) printf '%s\n' "$process_name" | grep -Exq "$2" ;;
        -f) printf '%s\n' "$process_command" | grep -Eq "$2" ;;
        *) return 2 ;;
    esac
}
process_name=Postman
process_command='/custom/bin/Postman'
postman_desktop_process_state || exit 1
process_name=helper
for process_command in '/Applications/Postman.app/Contents/Frameworks/helper' \
    '/custom/Postman Copy.app/Contents/MacOS/Postman Helper (Renderer) --type=renderer' \
    '/custom/Postman Helper --type=gpu-process'; do
    postman_desktop_process_state || exit 1
done
process_name=Postmaniac
process_command='/Applications/Other.app/Contents/MacOS/postman-cli'
rc=0
postman_desktop_process_state || rc=$?
[[ "$rc" == 1 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Postman cleanup honors app partition leaf and child whitelist entries" {
    for scope in app partition leaf child; do
        run env HOME="$POSTMAN_TEST_HOME/$scope" PROJECT_ROOT="$PROJECT_ROOT" SCOPE="$scope" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
app="$HOME/Library/Application Support/Postman"
root="$app/Partitions/alpha/Cache"
mkdir -p "$root/keep" "$root/remove"
printf state > "$root/keep/data"
printf cache > "$root/remove/data"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
case "$SCOPE" in
    app) WHITELIST_PATTERNS=("$app/*") ;;
    partition) WHITELIST_PATTERNS=("$app/Partitions/alpha/*") ;;
    leaf) WHITELIST_PATTERNS=("$root/*") ;;
    child) WHITELIST_PATTERNS=("$root/keep") ;;
esac
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$root/keep/data" ]] || exit 1
if [[ "$SCOPE" == child ]]; then [[ ! -e "$root/remove" ]] || exit 1; else [[ -f "$root/remove/data" && "$files_cleaned" == 0 ]] || exit 1; fi
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Postman cleanup refuses links at every path component and keeps linked entries" {
    for component in library support app partitions partition cache child; do
        run env HOME="$POSTMAN_TEST_HOME/$component" PROJECT_ROOT="$PROJECT_ROOT" COMPONENT="$component" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
app="$HOME/Library/Application Support/Postman"
root="$app/Partitions/alpha/Cache"
mkdir -p "$root" "$HOME/elsewhere"
printf cache > "$root/data"
printf personal > "$HOME/elsewhere/keep"
case "$COMPONENT" in
    library) link="$HOME/Library" ;;
    support) link="$HOME/Library/Application Support" ;;
    app) link="$app" ;;
    partitions) link="$app/Partitions" ;;
    partition) link="$app/Partitions/alpha" ;;
    cache) link="$root" ;;
    child) link=""; ln -s "$HOME/elsewhere" "$root/link" ;;
esac
if [[ -n "$link" ]]; then mv "$link" "$HOME/original"; ln -s "$HOME/original" "$link"; fi
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ "$(cat "$HOME/elsewhere/keep")" == personal ]] || exit 1
if [[ "$COMPONENT" == child ]]; then
    [[ -L "$root/link" && ! -e "$root/data" ]] || exit 1
else
    [[ -f "$root/data" && "$files_cleaned" == 0 ]] || exit 1
fi
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Postman cleanup retains directory replacements during probes sizing and final removal" {
    for seam in probe sizing final; do
        for component in app partitions partition cache; do
            run env HOME="$POSTMAN_TEST_HOME/$seam-$component" PROJECT_ROOT="$PROJECT_ROOT" SEAM="$seam" COMPONENT="$component" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
app="$HOME/Library/Application Support/Postman"
root="$app/Partitions/alpha/Cache"
mkdir -p "$root"
printf cache > "$root/data"
source "$PROJECT_ROOT/bin/clean.sh"
postman_test_swap() {
    [[ ! -e "$HOME/swapped" ]] || return 0
    touch "$HOME/swapped"
    case "$COMPONENT" in
        app) moved="$app" ;;
        partitions) moved="$app/Partitions" ;;
        partition) moved="$app/Partitions/alpha" ;;
        cache) moved="$root" ;;
    esac
    mv "$moved" "$HOME/original"
    mkdir -p "$root"
    printf replacement > "$root/data"
}
pgrep() { if [[ "$SEAM" == probe ]]; then postman_test_swap; fi; return 1; }
if [[ "$SEAM" == sizing ]]; then get_cleanup_path_size_kb() { postman_test_swap; echo 1; }; fi
if [[ "$SEAM" == final ]]; then _MOLE_SAFE_REMOVE_FINAL_GUARD=postman_test_swap; fi
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$HOME/swapped" && "$(cat "$root/data")" == replacement && "$files_cleaned" == 0 ]] || exit 1
EOF
            [ "$status" -eq 0 ] || { echo "$seam/$component: $output"; return 1; }
        done
    done
}

@test "Postman cleanup notices an owner starting after sizing in preview and real mode" {
    for dry_run in true false; do
        run env HOME="$POSTMAN_TEST_HOME/$dry_run" PROJECT_ROOT="$PROJECT_ROOT" TEST_DRY_RUN="$dry_run" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
root="$HOME/Library/Application Support/Postman/Partitions/alpha/Cache"
mkdir -p "$root"
printf cache > "$root/data"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ -f "$HOME/started" ]]; }
get_cleanup_path_size_kb() { touch "$HOME/started"; echo 1; }
DRY_RUN="$TEST_DRY_RUN"
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$HOME/started" && -f "$root/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Postman cleanup repeats the owner check after an outer final guard" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ -f "$HOME/started" ]]; }
postman_test_final_guard() { touch "$HOME/started"; return 0; }
_MOLE_SAFE_REMOVE_FINAL_GUARD=postman_test_final_guard
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$HOME/started" && -f "$HOME/Library/Application Support/Postman/Partitions/alpha/Cache/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Postman cleanup refuses foreign ownership and unknown identity" {
    for failure in owner identity; do
        run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" FAILURE="$failure" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
if [[ "$FAILURE" == owner ]]; then get_invoking_uid() { echo 999999; }; else _mole_snapshot_path_identity() { return 1; }; fi
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$HOME/Library/Application Support/Postman/Partitions/alpha/Cache/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Postman cleanup counts only successful removals" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
root="$HOME/Library/Application Support/Postman/Partitions/alpha/Cache"
eval "$(declare -f safe_remove | sed '1s/safe_remove/postman_test_safe_remove/')"
safe_remove() { [[ "$1" != "$root/data" ]] || return 1; postman_test_safe_remove "$@"; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$root/data" && ! -e "$root/.hidden" && "$files_cleaned" == 7 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Postman cleanup skips absent and empty partitions without an owner probe" {
    run env HOME="$POSTMAN_TEST_HOME/empty" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { touch "$HOME/probed"; return 2; }
clean_postman_partition_caches
mkdir -p "$HOME/Library/Application Support/Postman/Partitions/alpha/Cache"
clean_postman_partition_caches
[[ ! -e "$HOME/probed" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Postman cleanup propagates a sink cancellation before later caches" {
    run env HOME="$POSTMAN_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
safe_remove() { touch "$HOME/sink-reached"; return 130; }
DRY_RUN=false
MOLE_DRY_RUN=0
rc=0
clean_postman_partition_caches || rc=$?
[[ -f "$HOME/sink-reached" && "$rc" == 130 && -f "$HOME/Library/Application Support/Postman/Partitions/beta/Cache/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Postman cleanup retains a cache entry replaced after sizing or at the final sink" {
    for seam in sizing final; do
        run env HOME="$POSTMAN_TEST_HOME/$seam" PROJECT_ROOT="$PROJECT_ROOT" SEAM="$seam" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
root="$HOME/Library/Application Support/Postman/Partitions/alpha/Cache"
mkdir -p "$root"
printf cache > "$root/data"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
postman_test_replace_entry() {
    [[ ! -e "$HOME/swapped" ]] || return 0
    touch "$HOME/swapped"
    mv "$root/data" "$HOME/original"
    printf replacement > "$root/data"
}
if [[ "$SEAM" == sizing ]]; then
    get_cleanup_path_size_kb() { postman_test_replace_entry; echo 1; }
else
    _MOLE_SAFE_REMOVE_FINAL_GUARD=postman_test_replace_entry
fi
DRY_RUN=false
MOLE_DRY_RUN=0
clean_postman_partition_caches
[[ -f "$HOME/swapped" && "$(cat "$root/data")" == replacement && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$seam: $output"; return 1; }
    done
}
