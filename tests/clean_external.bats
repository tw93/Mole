#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home clean-external
}

teardown_file() {
    mole_test_teardown_home
}

@test "external metadata scans preserve system roots in preview and cleanup" {
    for dry_run in true false; do
        for unreadable in true false; do
            local test_home="$HOME/roots-$dry_run-$unreadable"
            local volume="$test_home/External [disk]*"
            local system_root
            for system_root in .AppInstallationStaging .Spotlight-V100 .fseventsd .DocumentRevisions-V100; do
                mkdir -p "$volume/$system_root/private"
                touch "$volume/$system_root/private/.DS_Store" "$volume/$system_root/private/._keep"
                if [[ "$unreadable" == true ]]; then
                    chmod 000 "$volume/$system_root/private"
                fi
            done
            mkdir -p "$volume/Photos/.AppInstallationStaging" "$test_home/Outside"
            touch "$volume/Photos/.DS_Store" "$volume/Photos/._photo" \
                "$volume/Photos/.AppInstallationStaging/.DS_Store" \
                "$volume/Photos/.AppInstallationStaging/._nested" \
                "$test_home/Outside/.DS_Store" "$test_home/Outside/._outside"
            ln -s "$test_home/Outside" "$volume/linked"

            run env HOME="$test_home" VOLUME="$volume" TEST_DRY_RUN="$dry_run" \
                PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN="$TEST_DRY_RUN"
PROTECT_FINDER_METADATA=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { printf '%s\n' "$1" >> "$HOME/sinks"; }
record_dry_run_cleanup_target() { printf '%s\n' "$1" >> "$HOME/sinks"; }
clean_external_volume_target "$VOLUME"
[[ $(wc -l < "$HOME/sinks" | tr -d ' ') -eq 4 ]] || exit 1
for candidate in Photos/.DS_Store Photos/._photo \
    Photos/.AppInstallationStaging/.DS_Store Photos/.AppInstallationStaging/._nested; do
    grep -Fxq "$VOLUME/$candidate" "$HOME/sinks" || exit 1
done
EOF
            # Restore only fixture permissions so teardown can remove its HOME.
            for system_root in .AppInstallationStaging .Spotlight-V100 .fseventsd .DocumentRevisions-V100; do
                chmod 700 "$volume/$system_root/private"
            done
            [ "$status" -eq 0 ] || {
                echo "$output"
                return 1
            }
        done
    done
}

run_external_scan_error() {
    local test_home="$HOME/error-$1-$2-$3"
    mkdir -p "$test_home/External"
    touch "$test_home/External/.DS_Store" "$test_home/External/._partial"
    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" FAIL_SCAN="$1" \
        MO_DEBUG="$2" TEST_DRY_RUN="$3" NO_COLOR=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
EXTERNAL_VOLUME_TARGET="$HOME/External"
DRY_RUN="$TEST_DRY_RUN"
PROTECT_FINDER_METADATA=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
run_with_timeout() {
    local candidate=._partial scan=appledouble
    case "$*" in *-name\ .DS_Store*) candidate=.DS_Store; scan=finder ;; esac
    printf '%s\0' "$EXTERNAL_VOLUME_TARGET/$candidate"
    if [[ "$scan" == "$FAIL_SCAN" ]]; then
        printf 'find: %s/Denied\t\033[31m: Permission denied\n' "$EXTERNAL_VOLUME_TARGET" >&2
        printf 'find: %s/Second: Input/output error\n' "$EXTERNAL_VOLUME_TARGET" >&2
        return 1
    fi
}
safe_remove() { echo UNEXPECTED_REMOVE; }
record_dry_run_cleanup_target() { echo UNEXPECTED_PREVIEW; }
set +e
perform_cleanup
rc=$?
set -e
[[ $rc -eq 1 ]] || exit 1
grep -Fq 'Denied\t\x1b[31m: Permission denied' "$LOG_FILE" || exit 1
grep -Fq '/Second: Input/output error' "$LOG_FILE" || exit 1
echo DIAGNOSTICS_LOGGED
exit "$rc"
EOF
}

@test "external cleanup keeps unreadable trash and temporary roots and continues" {
    for dry_run in true false; do
        for readable in true false; do
            local test_home="$HOME/access-$dry_run-$readable"
            local volume="$test_home/External"
            mkdir -p "$volume/.TemporaryItems" "$volume/.Trashes"
            touch "$volume/.TemporaryItems/keep" "$volume/.Trashes/keep" "$volume/._later"
            if [[ "$readable" == false ]]; then
                chmod 311 "$volume/.TemporaryItems" "$volume/.Trashes"
            fi
            run env HOME="$test_home" VOLUME="$volume" TEST_DRY_RUN="$dry_run" \
                READABLE="$readable" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN="$TEST_DRY_RUN"
PROTECT_FINDER_METADATA=true
start_section_spinner() { :; }
stop_section_spinner() { :; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { printf '%s\n' "$1" >> "$HOME/sinks"; }
record_dry_run_cleanup_target() { printf '%s\n' "$1" >> "$HOME/sinks"; }
get_path_size_kb() { printf '%s\n' "$1" >> "$HOME/sizes"; printf '1\n'; }
clean_external_volume_target "$VOLUME"
grep -Fxq "$VOLUME/._later" "$HOME/sinks" || exit 1
expected_count=3
if [[ "$READABLE" == false ]]; then
    expected_count=1
    grep -Fq "kept unreadable directory: $VOLUME/.TemporaryItems" "$LOG_FILE" || exit 1
    grep -Fq "kept unreadable directory: $VOLUME/.Trashes" "$LOG_FILE" || exit 1
    [[ $(cat "$HOME/sizes") == "$VOLUME/._later" ]] || exit 1
fi
[[ $(wc -l < "$HOME/sinks" | tr -d ' ') -eq $expected_count ]] || exit 1
EOF
            chmod 700 "$volume/.TemporaryItems" "$volume/.Trashes"
            [ "$status" -eq 0 ] || {
                echo "$output"
                return 1
            }
            [[ "$output" != *'kept unreadable directory'* ]] || return 1
        done
    done
}

@test "external scan failures name the first cause and keep full diagnostics in logs" {
    for scan in appledouble finder; do
        for dry_run in true false; do
            run_external_scan_error "$scan" 0 "$dry_run"
            [ "$status" -eq 1 ] || {
                echo "$output"
                return 1
            }
            [[ "$output" == *'Denied\t\x1b[31m: Permission denied'* ]] || {
                echo "$output"
                return 1
            }
            [[ "$output" == *"permissions"* && "$output" == *"System Settings"* ]] || return 1
            [[ "$output" != *'/Second:'* && "$output" != *$'\033[31m'* ]] || return 1
            [[ "$output" != *UNEXPECTED_REMOVE* && "$output" != *UNEXPECTED_PREVIEW* ]] || return 1
            [[ "$output" == *incomplete* ]] || return 1
            [[ "$output" == *DIAGNOSTICS_LOGGED* ]] || return 1
        done
    done
}

@test "external scan debug output includes every escaped diagnostic" {
    for scan in appledouble finder; do
        run_external_scan_error "$scan" 1 false
        [ "$status" -eq 1 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *'Denied\t\x1b[31m: Permission denied'* ]] || return 1
        [[ "$output" == *'/Second: Input/output error'* ]] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *DIAGNOSTICS_LOGGED* ]] || return 1
    done
}

run_external_space_summary() {
    local test_home="$HOME/space-$1-$2"
    mkdir -p "$test_home/External" "$test_home/bin"
    cat > "$test_home/bin/df" << 'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/df.trace"
available=1000000
[[ "${!#}" == "$HOME/External" ]] && available=200000000
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/test 300000000 100000000 %s 33%% %s\n' "$available" "${!#}"
case "$SUMMARY_CASE" in
    df_failure) exit 1 ;;
    disconnected_during_df)
        mv "$HOME/External" "$HOME/Original"
        mkdir "$HOME/External" ;;
esac
MOCK
    chmod +x "$test_home/bin/df"
    run env HOME="$test_home" PATH="$test_home/bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" \
        SUMMARY_CASE="$1" TEST_DRY_RUN="$2" NO_COLOR=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
EXTERNAL_VOLUME_TARGET="$HOME/External"
DRY_RUN="$TEST_DRY_RUN"
clean_external_volume_target() {
    case "$SUMMARY_CASE" in
        failure) return 7 ;;
        removed) rmdir "$EXTERNAL_VOLUME_TARGET"; return 1 ;;
        replaced)
            mv "$EXTERNAL_VOLUME_TARGET" "$HOME/Original"
            mkdir "$EXTERNAL_VOLUME_TARGET"
            return 1 ;;
        cleaned)
            if [[ "$DRY_RUN" == true ]]; then
                record_dry_run_cleanup_target "$EXTERNAL_VOLUME_TARGET" 1024 1 true
            else
                mole_add_cleaned_row 1 1024
            fi ;;
    esac
}
start_cleanup
set +e
perform_cleanup
rc=$?
set -e
printf 'RC=%s\n' "$rc"
if [[ -f "$HOME/df.trace" ]]; then
    while IFS= read -r args; do
        [[ "$args" == "-Pk $HOME/External" ]] || exit 98
    done < "$HOME/df.trace"
fi
exit "$rc"
EOF
}

@test "external cleanup summaries measure the selected volume" {
    for dry_run in true false; do
        for summary_case in empty failure cleaned; do
            run_external_space_summary "$summary_case" "$dry_run"
            local expected_rc=0
            [[ "$summary_case" == failure ]] && expected_rc=7
            [ "$status" -eq "$expected_rc" ] || {
                echo "$output"
                return 1
            }
            # A populated preview shows potential space, not a free-space row.
            if [[ "$dry_run" == true && "$summary_case" == cleaned ]]; then
                [[ "$output" == *"Potential space:"* ]] || {
                    echo "$output"
                    return 1
                }
            else
                [[ "$output" == *"Free space: 204.80GB"* ]] || {
                    echo "$output"
                    return 1
                }
            fi
        done
    done
}

@test "external cleanup summaries refuse a missing or replaced volume" {
    for dry_run in true false; do
        for summary_case in removed replaced; do
            run_external_space_summary "$summary_case" "$dry_run"
            [ "$status" -eq 1 ] || {
                echo "$output"
                return 1
            }
            [[ "$output" == *"Free space: Unknown"* ]] || {
                echo "$output"
                return 1
            }
        done
    done
}

@test "external free space rejects failed df output and disconnection during measurement" {
    for dry_run in true false; do
        for summary_case in df_failure disconnected_during_df; do
            run_external_space_summary "$summary_case" "$dry_run"
            [ "$status" -eq 0 ] || {
                echo "$output"
                return 1
            }
            [[ "$output" == *"Free space: Unknown"* ]] || {
                echo "$output"
                return 1
            }
        done
    done
}
