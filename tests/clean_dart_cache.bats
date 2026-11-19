#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home dart-cache
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    export DART_TEST_HOME="$HOME/case-$BATS_TEST_NUMBER"
    local root="$DART_TEST_HOME/.dartServer"
    mkdir -p "$root/.analysis-driver/ab" "$root/.analysis-driver/.hidden" \
        "$root/.analysis-cache" "$root/plugins" "$DART_TEST_HOME/.pub-cache" \
        "$DART_TEST_HOME/fvm/versions/sdk" "$DART_TEST_HOME/custom-state/.analysis-driver"
    printf cache > "$root/.analysis-driver/ab/data"
    printf hidden > "$root/.analysis-driver/.hidden/data"
    printf state > "$root/plugins/state"
    printf state > "$root/.analysis-cache/state"
    printf package > "$DART_TEST_HOME/.pub-cache/package"
    printf sdk > "$DART_TEST_HOME/fvm/versions/sdk/dart"
    printf custom > "$DART_TEST_HOME/custom-state/.analysis-driver/state"
}

@test "Dart cleanup removes only analysis-driver contents through the real sink" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
MOLE_CURRENT_COMMAND=clean
clean_dart_analysis_cache
root="$HOME/.dartServer"
[[ -d "$root/.analysis-driver" && ! -e "$root/.analysis-driver/ab" && ! -e "$root/.analysis-driver/.hidden" ]] || exit 1
for kept in "$root/plugins/state" "$root/.analysis-cache/state" "$HOME/.pub-cache/package" \
    "$HOME/fvm/versions/sdk/dart" "$HOME/custom-state/.analysis-driver/state"; do
    [[ -f "$kept" ]] || { echo "LOST:$kept"; exit 1; }
done
[[ "$files_cleaned" == 2 ]] || exit 1
grep -q 'REMOVED.*\.analysis-driver/' "$HOME/Library/Logs/mole/operations.log" || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Dart cleanup preview reports cache contents and changes nothing" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=true
MOLE_DRY_RUN=1
clean_dart_analysis_cache
[[ -f "$HOME/.dartServer/.analysis-driver/ab/data" && -f "$HOME/.dartServer/.analysis-driver/.hidden/data" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Dart analysis cache"* && "$output" == *dry* ]] || return 1
}

@test "Dart cleanup respects root and child whitelist entries" {
    for scope in root child; do
        run env HOME="$DART_TEST_HOME/$scope" PROJECT_ROOT="$PROJECT_ROOT" SCOPE="$scope" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
root="$HOME/.dartServer/.analysis-driver"
mkdir -p "$root/keep" "$root/remove"
printf data > "$root/keep/data"
printf data > "$root/remove/data"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
if [[ "$SCOPE" == root ]]; then WHITELIST_PATTERNS=("$root/*"); else WHITELIST_PATTERNS=("$root/keep"); fi
clean_dart_analysis_cache
[[ -f "$root/keep/data" ]] || exit 1
if [[ "$SCOPE" == root ]]; then [[ -f "$root/remove/data" ]] || exit 1; else [[ ! -e "$root/remove" ]] || exit 1; fi
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Dart cleanup retains caches while process state is busy or unknown" {
    for process_rc in 0 2; do
        run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" PROCESS_RC="$process_rc" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return "$PROCESS_RC"; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$HOME/.dartServer/.analysis-driver/ab/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Dart process probe covers runtimes and snapshot launches without unrelated matches" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() {
    case "$1" in
        -x) printf '%s\n' "$process_name" | grep -Exq "$2" ;;
        -f) printf '%s\n' "$process_command" | grep -Eq "$2" ;;
        *) return 2 ;;
    esac
}
for process_name in dart dartvm dartaotruntime dart_aot_runtime analysis_server; do
    process_command="/sdk/bin/$process_name"
    dart_analysis_process_state || exit 1
done
process_name=custom-launcher
for snapshot in analysis_server.dart.snapshot analysis_server_aot.dart.snapshot; do
    process_command="/sdk/custom-launcher /sdk/bin/snapshots/$snapshot --lsp"
    dart_analysis_process_state || exit 1
done
process_name=dartboard
process_command='/usr/bin/editor /projects/dartboard.txt'
rc=0
dart_analysis_process_state || rc=$?
[[ "$rc" == 1 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Dart cleanup refuses symlinked state root cache root and cache children" {
    for component in container root child; do
        run env HOME="$DART_TEST_HOME/$component" PROJECT_ROOT="$PROJECT_ROOT" COMPONENT="$component" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
root="$HOME/.dartServer/.analysis-driver"
mkdir -p "$root" "$HOME/elsewhere"
case "$COMPONENT" in
    container) mv "$HOME/.dartServer" "$HOME/original"; ln -s "$HOME/original" "$HOME/.dartServer" ;;
    root) mv "$root" "$HOME/original"; ln -s "$HOME/original" "$root" ;;
    child) ln -s "$HOME/elsewhere" "$root/link" ;;
esac
printf cache > "$root/data"
printf user > "$HOME/elsewhere/user-file"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$HOME/elsewhere/user-file" ]] || exit 1
if [[ "$COMPONENT" == child ]]; then
    [[ -L "$root/link" && ! -e "$root/data" ]] || exit 1
else
    [[ -f "$root/data" && "$files_cleaned" == 0 ]] || exit 1
fi
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Dart cleanup rechecks activity after sizing in preview and real cleanup" {
    for dry_run in true false; do
        run env HOME="$DART_TEST_HOME/$dry_run" PROJECT_ROOT="$PROJECT_ROOT" TEST_DRY_RUN="$dry_run" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
root="$HOME/.dartServer/.analysis-driver"
mkdir -p "$root/ab"
printf cache > "$root/ab/data"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ -f "$HOME/owner-started" ]]; }
get_cleanup_path_size_kb() { touch "$HOME/owner-started"; echo 1; }
DRY_RUN="$TEST_DRY_RUN"
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$HOME/owner-started" && -f "$root/ab/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Dart cleanup rejects container and root replacement after sizing" {
    for component in container root; do
        run env HOME="$DART_TEST_HOME/$component" PROJECT_ROOT="$PROJECT_ROOT" COMPONENT="$component" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
root="$HOME/.dartServer/.analysis-driver"
mkdir -p "$root/ab"
printf cache > "$root/ab/data"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    if [[ ! -e "$HOME/swapped" ]]; then
        touch "$HOME/swapped"
        if [[ "$COMPONENT" == container ]]; then mv "$HOME/.dartServer" "$HOME/original"; else mv "$root" "$HOME/original"; fi
        mkdir -p "$root/ab"
        printf replacement > "$root/ab/data"
    fi
    echo 1
}
DRY_RUN=false
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$HOME/swapped" && "$(cat "$root/ab/data")" == replacement && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
}

@test "Dart cleanup rechecks processes at the final removal boundary" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ -f "$HOME/final-boundary" ]]; }
_MOLE_SAFE_REMOVE_FINAL_GUARD=dart_test_final_guard
dart_test_final_guard() { touch "$HOME/final-boundary"; return 0; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$HOME/final-boundary" && -f "$HOME/.dartServer/.analysis-driver/ab/data" && "$files_cleaned" == 0 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Dart cleanup does not count a failed removal as freed cache" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
eval "$(declare -f safe_remove | sed '1s/safe_remove/dart_test_safe_remove/')"
safe_remove() {
    [[ "$1" != "$HOME/.dartServer/.analysis-driver/.hidden" ]] || return 1
    dart_test_safe_remove "$@"
}
DRY_RUN=false
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$HOME/.dartServer/.analysis-driver/.hidden/data" && ! -e "$HOME/.dartServer/.analysis-driver/ab" ]] || exit 1
[[ "$files_cleaned" == 1 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Dart cleanup skips absent and empty caches without probing processes" {
    run env HOME="$DART_TEST_HOME/absent" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { echo UNEXPECTED_PROBE >> "$HOME/probes"; return 2; }
mkdir -p "$HOME"
clean_dart_analysis_cache
mkdir -p "$HOME/.dartServer/.analysis-driver"
clean_dart_analysis_cache
[[ ! -e "$HOME/probes" && -d "$HOME/.dartServer/.analysis-driver" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Dart cleanup does not traverse custom analyzer state locations" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" ANALYZER_STATE_LOCATION_OVERRIDE="$DART_TEST_HOME/custom-state" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_dart_analysis_cache
[[ -f "$ANALYZER_STATE_LOCATION_OVERRIDE/.analysis-driver/state" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Dart cleanup is dispatched by the language cleaner" {
    run env HOME="$DART_TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
safe_clean() { :; }
clean_clang_module_cache() { :; }
clean_dart_analysis_cache() { echo DART_DISPATCHED; }
clean_dev_other_langs
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *DART_DISPATCHED* ]] || return 1
}
