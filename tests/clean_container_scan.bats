#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home container-scan
}

teardown_file() {
    mole_test_teardown_home
}

run_container_scan_fixture() {
    local scope="$1" scan_status="$2" dry_run="$3"
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/$scope-$scan_status-$dry_run.XXXXXX")
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" \
        SCAN_SCOPE="$scope" SCAN_STATUS="$scan_status" DRY_RUN="$dry_run" \
        LC_ALL=en_US.UTF-8 \
        MOLE_TEST_NO_AUTH=1 MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        MOLE_TIMEOUT_MEDIUM_PROBE_SEC=2 MOLE_TIMEOUT_HINT_SCAN_SEC=0 \
        MOLE_CONTAINER_CACHE_SECTION_BUDGET_SEC=15 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
eval "$(declare -f create_temp_file | sed '1s/^create_temp_file/_scan_create_temp_file/')"
create_temp_file() {
    local file
    file=$(_scan_create_temp_file) || return $?
    printf '%s\0' "$file" >> "$HOME/temp-trace"
    printf '%s\n' "$file"
}
start_section_spinner() { spinner=on; }
stop_section_spinner() { spinner=off; }
safe_clean() { :; }
clean_support_app_data() { :; }
_clean_wallpaper_renders() { :; }
clean_handoff_pasteboard_cache() { echo LATER_SECTION; }
note_activity() { :; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
holds_compiled_model_cache() { return 1; }
get_path_size_kb() { echo 7; }
validate_path_for_deletion() { return 0; }
register_dry_run_cleanup_target() { return 0; }
record_scan_action() {
    printf '%s\0' "$1" >> "$HOME/actions"
    if [[ "$SCAN_SCOPE" == budget && "$1" == "$app_a/payload" ]]; then
        SECONDS="${_MOLE_CLEAN_SECTION_DEADLINE:-$SECONDS}"
    fi
    if [[ "$SCAN_SCOPE" == group-budget && "$1" == "$group_a/payload" ]]; then
        SECONDS="${_MOLE_CLEAN_SECTION_DEADLINE:-$SECONDS}"
    fi
}
safe_remove() { record_scan_action "$1"; }
append_dry_run_cleanup_target() { record_scan_action "$1"; }
record_dry_run_cleanup_target() { record_scan_action "$1"; }
files_cleaned=0
total_size_cleaned=0
total_items=0
spinner=off

app_root="$HOME/Library/Containers"
group_root="$HOME/Library/Group Containers"
app_a="$app_root/com.example.a/Data/Library/Caches"
app_z="$app_root/com.example.z/Data/Library/Caches"
group_a="$group_root/group.com.example.a/Library/Caches"
group_z="$group_root/group.com.example.z/Library/Caches"
mkdir -p "$app_a" "$app_z" "$group_a" "$group_z"
touch "$app_a/payload" "$app_a/zlater" "$app_z/.hidden" "$app_z/line
break" "$group_a/payload" "$group_z/.hidden"
ln -s "$app_a/payload" "$app_z/link"
# Root globs used to exclude hidden containers; keep that boundary.
mkdir -p "$app_root/.hidden-container/Data/Library/Caches"
touch "$app_root/.hidden-container/Data/Library/Caches/keep"
touch "$HOME/actions" "$HOME/find-trace" "$HOME/temp-trace"
if [[ "$SCAN_SCOPE" == safari* ]]; then
    mkdir -p "$app_root/group.com.example.a"
    if [[ "$SCAN_SCOPE" == safari-present ]]; then
        touch "$app_root/group.com.example.a/SafariExtension"
    fi
fi

export REAL_FIND="$FIND_BSD" app_root group_root app_a group_a
cat > "$HOME/find-stub" <<'FIND'
#!/bin/bash
printf '%s\0' "$1" >> "$HOME/find-trace"
blocked=false
case "$SCAN_SCOPE:$1" in
    "app-root:$app_root" | "cache:$app_a" | stall*:"$app_a" | \
        "group-root:$group_root" | "group-cache:$group_a" | \
        "safari:$app_root/group.com.example.a") blocked=true ;;
esac
if [[ "$blocked" == true ]]; then
    printf 'ENUMERATION_REACHED\n' >> "$HOME/producer-trace"
    case "$SCAN_SCOPE" in
        app-root) printf '%s\0' "$app_root/com.example.a" ;;
        group-root) printf '%s\0' "$group_root/group.com.example.a" ;;
        *) printf '%s\0' "$1/payload" ;;
    esac
    if [[ "$SCAN_SCOPE" == stall* ]]; then
        echo "$$" > "$HOME/stalled-pid"
        exec /bin/sleep 20
    fi
    exit "$SCAN_STATUS"
fi
exec "$REAL_FIND" "$@"
FIND
chmod +x "$HOME/find-stub"
FIND_BSD="$HOME/find-stub"
case "$SCAN_SCOPE" in
    stall-perl) MO_TIMEOUT_BIN="" ;;
    stall-shell) MO_TIMEOUT_BIN=""; MO_TIMEOUT_PERL_BIN="" ;;
esac
if [[ "$SCAN_SCOPE" == glob-on ]]; then
    shopt -s nullglob dotglob
else
    shopt -u nullglob dotglob
fi

rc=0
clean_app_caches || rc=$?
printf 'RC=%s CANCEL=%s SPINNER=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS" "$spinner"
printf 'ITEMS=%s SIZE=%s\n' "$files_cleaned" "$total_size_cleaned"
printf 'GLOBS=%s%s\n' "$(shopt -q nullglob && echo N || echo n)" "$(shopt -q dotglob && echo D || echo d)"
printf 'FINDS=%s\n' "$(tr -dc '\0' < "$HOME/find-trace" | wc -c | tr -d ' ')"
printf 'TEMP_FILES=%s\n' "$(tr -dc '\0' < "$HOME/temp-trace" | wc -c | tr -d ' ')"
while IFS= read -r -d '' file; do
    [[ ! -e "$file" ]] || { echo LISTING_NOT_REMOVED; exit 1; }
done < "$HOME/temp-trace"
while IFS= read -r -d '' item; do
    printf 'ACTION=%s\n' "${item#"$HOME/"}"
    [[ -f "$item" && ! -L "$item" ]] || exit 1
done < "$HOME/actions"
if [[ -f "$HOME/producer-trace" ]]; then cat "$HOME/producer-trace"; fi
if [[ -f "$HOME/stalled-pid" ]]; then
    if kill -0 "$(cat "$HOME/stalled-pid")" 2>/dev/null; then
        echo PRODUCER_STILL_RUNNING
        exit 1
    fi
    echo PRODUCER_STOPPED
fi
EOF
}

@test "container scans reuse complete NUL listings and preserve hidden cache entries (#1973)" {
    local mode
    for mode in true false; do
        run_container_scan_fixture none 0 "$mode"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"FINDS=6"* ]] || return 1
        [[ "$output" == *"TEMP_FILES=2"* ]] || return 1
        [[ "$output" == *"ITEMS=6 SIZE=42"* ]] || return 1
        [[ "$output" == *"ACTION=Library/Containers/com.example.z/Data/Library/Caches/.hidden"* ]] || return 1
        [[ "$output" == *$'Caches/line\nbreak'* ]] || return 1
        [[ "$output" != *"ACTION=Library/Containers/.hidden-container"* ]] || return 1
        [[ "$output" != *"ACTION="*"Caches/link"* ]] || return 1
        [[ "$output" == *"RC=0 CANCEL=0 SPINNER=off"* ]] || return 1
        [[ "$output" != *"time limit reached"* ]] || return 1
    done
}

@test "failed container enumerations discard partial candidates and continue (#1973)" {
    local scope code mode expected
    for mode in true false; do
        for scope in app-root cache group-root group-cache safari; do
            case "$scope" in
                app-root) expected='ITEMS=2 SIZE=14' ;;
                cache) expected='ITEMS=4 SIZE=28' ;;
                group-root) expected='ITEMS=4 SIZE=28' ;;
                group-cache | safari) expected='ITEMS=5 SIZE=35' ;;
            esac
            for code in 1 124; do
                run_container_scan_fixture "$scope" "$code" "$mode"
                [ "$status" -eq 0 ] || { echo "$output"; return 1; }
                [[ "$output" == *ENUMERATION_REACHED* ]] || {
                    printf 'scope=%s status=%s dry=%s\n%s\n' "$scope" "$code" "$mode" "$output"
                    return 1
                }
                [[ "$output" == *"RC=0 CANCEL=0 SPINNER=off"* ]] || return 1
                [[ "$output" == *"$expected"* ]] || return 1
                [[ "$output" == *LATER_SECTION* ]] || return 1
                case "$scope" in
                    app-root | cache) [[ "$output" != *"ACTION=Library/Containers/com.example.a/"* ]] || return 1 ;;
                    group-root | group-cache | safari) [[ "$output" != *"ACTION=Library/Group Containers/group.com.example.a/"* ]] || return 1 ;;
                esac
            done
        done
    done
}

@test "container enumeration signals stop later eligible candidates and restore the spinner (#1973)" {
    local scope mode
    for mode in true false; do
        for scope in app-root cache group-root group-cache safari; do
            run_container_scan_fixture "$scope" 143 "$mode"
            [ "$status" -eq 0 ] || { echo "$output"; return 1; }
            [[ "$output" == *ENUMERATION_REACHED* ]] || return 1
            [[ "$output" == *"RC=143 CANCEL=143 SPINNER=off"* ]] || return 1
            [[ "$output" != *LATER_SECTION* ]] || return 1
            [[ "$output" != *"ACTION=Library/Group Containers/group.com.example.z/"* ]] || return 1
            case "$scope" in
                app-root | cache) [[ "$output" != *"ACTION="* ]] || return 1 ;;
                *) [[ "$output" == *"ACTION=Library/Containers/com.example.z/"* ]] || return 1 ;;
            esac
        done
    done
}

@test "sandbox enumeration shares a deadline across containers and inner items (#1973)" {
    local mode budget_note
    for mode in true false; do
        run_container_scan_fixture budget 0 "$mode"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"FINDS=5"* ]] || return 1
        [[ "$output" == *"ITEMS=3 SIZE=21"* ]] || return 1
        [[ "$output" == *"ACTION=Library/Containers/com.example.a/Data/Library/Caches/payload"* ]] || return 1
        [[ "$output" != *"ACTION="*"Caches/zlater"* ]] || return 1
        [[ "$output" != *"ACTION=Library/Containers/com.example.z/"* ]] || return 1
        budget_note=$(printf '%s\n' "$output" | grep -F "time limit reached, skipped remaining items") || { echo "$output"; return 1; }
        [[ "$budget_note" == *"Sandboxed app caches · "* && "$budget_note" != *$'\n'* ]] || { echo "$output"; return 1; }
        [[ "$output" == *LATER_SECTION* ]] || return 1
    done
}

@test "Group Container scans retain Safari extensions and stop at their own deadline (#1973)" {
    local mode budget_note
    for mode in true false; do
        run_container_scan_fixture safari-present 0 "$mode"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"ITEMS=5 SIZE=35"* ]] || return 1
        [[ "$output" != *"ACTION=Library/Group Containers/group.com.example.a/"* ]] || return 1
        [[ "$output" == *"ACTION=Library/Group Containers/group.com.example.z/"* ]] || return 1

        run_container_scan_fixture group-budget 0 "$mode"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"FINDS=5"* ]] || return 1
        [[ "$output" == *"ITEMS=5 SIZE=35"* ]] || return 1
        [[ "$output" == *"ACTION=Library/Group Containers/group.com.example.a/Library/Caches/payload"* ]] || return 1
        [[ "$output" != *"ACTION=Library/Group Containers/group.com.example.z/"* ]] || return 1
        budget_note=$(printf '%s\n' "$output" | grep -F "time limit reached, skipped remaining items") || { echo "$output"; return 1; }
        [[ "$budget_note" == *"Group Containers logs/caches · "* && "$budget_note" != *$'\n'* ]] || { echo "$output"; return 1; }
        [[ "$output" == *LATER_SECTION* ]] || return 1
    done
}

@test "container directory snapshots leave caller glob options unchanged" {
    run_container_scan_fixture none 0 true
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GLOBS=nd"* ]] || return 1
    run_container_scan_fixture glob-on 0 true
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GLOBS=ND"* ]]
}

@test "a blocked container listing is stopped by the real timeout wrapper (#1973)" {
    local backend
    for backend in stall stall-perl stall-shell; do
        run_container_scan_fixture "$backend" 0 true
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *ENUMERATION_REACHED* ]] || return 1
        [[ "$output" == *PRODUCER_STOPPED* ]] || return 1
        [[ "$output" == *"RC=0 CANCEL=0 SPINNER=off"* ]] || return 1
        [[ "$output" == *"ITEMS=4 SIZE=28"* ]] || return 1
        [[ "$output" != *"ACTION=Library/Containers/com.example.a/"* ]] || return 1
        [[ "$output" == *LATER_SECTION* ]] || return 1
    done
}

@test "container listing sort preserves byte records under a UTF-8 locale (#1973)" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/sort-bytes.XXXXXX")
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" LC_ALL=en_US.UTF-8 \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
mkdir -p "$HOME/entries"
touch "$HOME/entries/payload"
printf 'a\0b\0invalid-\377\0line\nbreak\0' > "$HOME/expected"
# The filesystem refuses a real 0xff filename. Exercise the production sort
# call with synthetic records, then restore its ordinary completed listing.
# The separate blocked-producer case covers the real timeout backends.
run_with_timeout() {
    shift
    if [[ "$1" == /usr/bin/sort ]]; then
        local list="${!#}"
        printf 'b\0invalid-\377\0line\nbreak\0a\0' > "$list"
        "$@" || return $?
        if ! cmp -s "$list" "$HOME/expected"; then
            echo BYTE_SORT_MISMATCH > "$HOME/result"
            return 1
        fi
        echo BYTE_SORT_PRESERVED > "$HOME/result"
        printf '%s\0' "$HOME/entries/payload" > "$list"
    else
        "$@"
    fi
}
_MOLE_CONTAINER_CACHE_ENTRIES=()
rc=0
_container_cache_list_entries "$HOME/entries" || rc=$?
cat "$HOME/result"
printf 'RC=%s COUNT=%s\n' "$rc" "${#_MOLE_CONTAINER_CACHE_ENTRIES[@]}"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *BYTE_SORT_PRESERVED* ]] || return 1
    [[ "$output" == *"RC=0 COUNT=1"* ]]
}
