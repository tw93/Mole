#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-user-core.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_user_essentials respects Trash whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
note_activity() { :; }
is_path_whitelisted() { [[ "$1" == "$HOME/.Trash" ]]; }
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
EOF

    [ "$status" -eq 0 ]
    # Whitelist-protected items no longer show output (UX improvement in V1.22.0)
    [[ "$output" != *"Trash"* ]]
}

@test "incomplete downloads are kept when the open-file view is incomplete (#1471)" {
    local partial="$HOME/Downloads/pending.crdownload"
    mkdir -p "$(dirname "$partial")"
    printf 'partial\n' > "$partial"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
trace_file=$(mktemp)
lsof() {
    case " $* " in
        *" -p 1 "*) printf 'visibility\n' >> "$trace_file"; return 1 ;;
        *) printf 'target\n' >> "$trace_file"; return 1 ;;
    esac
}
run_with_timeout() { shift; "$@"; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$1"; }
note_activity() { :; }
_clean_incomplete_downloads
printf 'TRACE=%s\n' "$(tr '\n' ',' < "$trace_file")"
command rm -f "$trace_file"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"open-file check unavailable"* ]] || return 1
    [[ "$output" == *"TRACE=visibility,"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "incomplete download dry-run rechecks open handles after sizing (#1471)" {
    local partial="$HOME/Downloads/pending.part"
    mkdir -p "$(dirname "$partial")"
    printf 'partial\n' > "$partial"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" partial="$partial" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
trace_file=$(mktemp)
size_marker=$(mktemp)
command rm -f "$size_marker"
lsof() {
    printf 'LSOF:%s\n' "$(test -f "$size_marker" && echo live || echo idle)" >> "$trace_file"
    if [[ -f "$size_marker" ]]; then
        printf 'n%s\n' "$partial"
        return 0
    fi
    return 1
}
run_with_timeout() { shift; "$@"; }
get_cleanup_path_size_kb() {
    printf 'SIZE\n' >> "$trace_file"
    printf 'sized\n' > "$size_marker"
    printf '1\n'
}
record_dry_run_cleanup_target() { printf 'UNEXPECTED_REGISTER:%s\n' "$1"; }
note_activity() { :; }
DRY_RUN=true
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
_clean_incomplete_downloads
printf 'EXISTS=%s ORDER=%s\n' "$(test -f "$partial" && echo yes || echo no)" \
    "$(tr '\n' ',' < "$trace_file")"
command rm -f "$trace_file" "$size_marker"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"EXISTS=yes ORDER=LSOF:idle,SIZE,LSOF:live,"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REGISTER"* ]] || return 1
}

@test "clean_user_essentials avoids Darwin runtime probes and live-log truncation" {
    mkdir -p "$HOME/Library/Caches/ordinary-app"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { echo "SAFE:$2"; }
clean_trash() { echo "TRASH"; }
_clean_recent_items() { :; }
_clean_mail_downloads() { :; }
getconf() { echo "WRONG:getconf"; return 99; }
lsof() { echo "WRONG:lsof"; return 99; }
mole_truncate_log_file() { echo "WRONG:truncate"; return 99; }
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
EOF

    [ "$status" -eq 0 ] || return 1
    [ "$output" = $'SAFE:User app cache\nSAFE:User app logs\nTRASH' ]
    rm -rf "$HOME/Library/Caches/ordinary-app"
}

@test "clean_user_essentials preserves default Deno state from the generic cache sweep" {
    local test_home="$HOME/deno-default-home"
    mkdir -p \
        "$test_home/Library/Caches/deno/origin-data" \
        "$test_home/Library/Caches/ordinary-app/junk"

    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_trash() { :; }
_clean_recent_items() { :; }
_clean_mail_downloads() { :; }
safe_clean() {
    local description="${!#}"
    local path
    while [[ $# -gt 1 ]]; do
        path="$1"
        shift
        printf 'CLEAN=%s|%s\n' "$description" "$path"
        rm -rf "$path"
    done
}
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
[[ -d "$HOME/Library/Caches/deno/origin-data" ]] || exit 1
[[ ! -e "$HOME/Library/Caches/ordinary-app" ]]
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"User app cache|$test_home/Library/Caches/deno"* ]] || return 1
    [[ "$output" == *"User app cache|$test_home/Library/Caches/ordinary-app"* ]] || return 1
    rm -rf "$test_home"
}

@test "clean_user_essentials preserves nested and physical Deno roots" {
    local nested_home="$HOME/deno-nested-home"
    local linked_home="$HOME/deno-linked-home"
    mkdir -p \
        "$nested_home/Library/Caches/tool-root/deno/origin-data" \
        "$nested_home/Library/Caches/ordinary-app/junk" \
        "$linked_home/Library/Caches/physical-deno/origin-data" \
        "$linked_home/Library/Caches/ordinary-app/junk"
    ln -s "$linked_home/Library/Caches/physical-deno" \
        "$linked_home/Library/Caches/deno"

    run env HOME="$nested_home" PROJECT_ROOT="$PROJECT_ROOT" \
        DENO_DIR="$nested_home/Library/Caches/tool-root/deno" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_trash() { :; }
_clean_recent_items() { :; }
_clean_mail_downloads() { :; }
safe_clean() {
    while [[ $# -gt 1 ]]; do
        rm -rf "$1"
        shift
    done
}
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
[[ -d "$HOME/Library/Caches/tool-root/deno/origin-data" ]] || exit 1
[[ ! -e "$HOME/Library/Caches/ordinary-app" ]]
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    run env HOME="$linked_home" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_trash() { :; }
_clean_recent_items() { :; }
_clean_mail_downloads() { :; }
safe_clean() {
    while [[ $# -gt 1 ]]; do
        rm -rf "$1"
        shift
    done
}
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
[[ -L "$HOME/Library/Caches/deno" ]] || exit 1
[[ -d "$HOME/Library/Caches/physical-deno/origin-data" ]] || exit 1
[[ ! -e "$HOME/Library/Caches/ordinary-app" ]]
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    rm -rf "$nested_home" "$linked_home"
}

@test "clean_user_essentials fails closed on a broad DENO_DIR" {
    local test_home="$HOME/deno-broad-home"
    mkdir -p "$test_home/Library/Caches/ordinary-app/junk"

    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" \
        DENO_DIR="$test_home/Library/Caches" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_trash() { :; }
_clean_recent_items() { :; }
_clean_mail_downloads() { :; }
safe_clean() { printf 'CLEAN=%s\n' "${!#}"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"CLEAN=User app cache"* ]] || return 1
    [[ "$output" == *"CLEAN=User app logs"* ]] || return 1
    # Refusing silently would drop the whole category from the section with no
    # way for the user to tell cleanup from a stopped gate.
    [[ "$output" == *"User app cache · stopped (DENO_DIR unresolved)"* ]] || {
        echo "$output"
        return 1
    }
    rm -rf "$test_home"
}

@test "a Deno root retargeted inside safe_remove is refused before rm" {
    # Excluding the root while the candidate list is built only proves where
    # it pointed then, and the batch guard fires before safe_remove does its
    # own validation, sizing and identity work. The root is re-asked at the
    # last hop before rm so a swap anywhere in that span is refused.
    local test_home="$HOME/deno-race-home"
    mkdir -p "$test_home/Library/Caches/deno-old" \
        "$test_home/Library/Caches/aaa-first" \
        "$test_home/Library/Caches/ordinary-app"
    printf 'deno\n' > "$test_home/Library/Caches/deno-old/d.txt"
    printf 'first\n' > "$test_home/Library/Caches/aaa-first/f.txt"
    printf 'app\n' > "$test_home/Library/Caches/ordinary-app/a.txt"
    ln -s "$test_home/Library/Caches/deno-old" "$test_home/Library/Caches/deno"

    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_trash() { :; }
_clean_recent_items() { :; }
_clean_mail_downloads() { :; }

# Retarget the root for the candidate that is being removed right now,
# after the batch guard already cleared it. safe_remove still runs path
# validation, process and identity checks before rm, so the only honest
# test is one that moves the root inside that span.
eval "$(declare -f safe_remove | sed '1s/safe_remove/_real_safe_remove/')"
safe_remove() {
    if [[ "$1" == *"/ordinary-app" ]]; then
        rm -f "$HOME/Library/Caches/deno"
        ln -s "$HOME/Library/Caches/ordinary-app" "$HOME/Library/Caches/deno"
    fi
    _real_safe_remove "$@"
}
clean_user_essentials
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -d "$test_home/Library/Caches/ordinary-app" ]] || {
        echo "sink deleted the retargeted Deno root"
        return 1
    }
    [[ -e "$test_home/Library/Caches/deno" ]] || {
        echo "Deno root left dangling"
        return 1
    }
    [[ ! -d "$test_home/Library/Caches/aaa-first" ]] || {
        echo "the ordinary candidate before the retarget was not cleaned"
        return 1
    }
    rm -rf "$test_home"
}

@test "a custom whitelist still protects system caches and Poetry virtualenvs" {
    # clean_user_essentials sweeps every child of ~/Library/Caches, and
    # load_mole_whitelist replaces DEFAULT_WHITELIST_PATTERNS wholesale once a
    # user saves one entry of their own. Anything that breaks macOS search,
    # fonts or iCloud, or that holds live interpreters rather than downloads,
    # has to survive that replacement.
    local test_home="$HOME/custom-whitelist-home"
    mkdir -p "$test_home/.config/mole" \
        "$test_home/Library/Caches/com.apple.spotlight" \
        "$test_home/Library/Caches/com.apple.FontRegistry" \
        "$test_home/Library/Caches/CloudKit" \
        "$test_home/Library/Caches/pypoetry/virtualenvs/proj-abc123"
    printf '%s\n' "$test_home/.cache/keep-my-own-thing/*" > "$test_home/.config/mole/whitelist"

    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
load_mole_whitelist "$HOME"
for probe in \
    "$HOME/Library/Caches/com.apple.spotlight" \
    "$HOME/Library/Caches/com.apple.FontRegistry" \
    "$HOME/Library/Caches/CloudKit" \
    "$HOME/Library/Caches/pypoetry/virtualenvs/proj-abc123"; do
    if is_path_whitelisted "$probe"; then
        printf 'PROTECTED=%s\n' "${probe#"$HOME"/}"
    else
        printf 'EXPOSED=%s\n' "${probe#"$HOME"/}"
    fi
done
# The user's own entry must survive too.
is_path_whitelisted "$HOME/.cache/keep-my-own-thing/x" && printf 'CUSTOM_KEPT\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"EXPOSED="* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"PROTECTED=Library/Caches/com.apple.spotlight"* ]] || return 1
    [[ "$output" == *"PROTECTED=Library/Caches/pypoetry/virtualenvs/proj-abc123"* ]] || return 1
    [[ "$output" == *"CUSTOM_KEPT"* ]] || return 1
    rm -rf "$test_home"
}

@test "clean_trash dry run stays silent for compiled-model-only items" {
    mkdir -p "$HOME/.Trash/model/com.apple.e5rt.e5bundlecache"
    touch "$HOME/.Trash/model/com.apple.e5rt.e5bundlecache/weights.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
note_activity() { :; }
record_dry_run_cleanup_target() { echo "UNEXPECTED_RECORD:$1"; }
get_path_size_kb() { echo "UNEXPECTED_SIZE"; return 1; }
clean_trash
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == "" ]] || return 1
    rm -rf "$HOME/.Trash/model"
}

@test "clean_user_essentials empties trash directly without Finder prompt" {
    mkdir -p "$HOME/.Trash"
    touch "$HOME/.Trash/one.tmp" "$HOME/.Trash/two.tmp"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
safe_clean() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
debug_log() { :; }
osascript() {
    echo "FAIL: osascript called, should be direct delete" >&2
    return 1
}
export -f osascript
safe_remove() {
    local target="$1"
    /bin/rm -rf "$target"
    return 0
}

safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials
[[ ! -e "$HOME/.Trash/one.tmp" ]] || exit 1
[[ ! -e "$HOME/.Trash/two.tmp" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Trash · emptied, 2 items"* ]] || return 1
    [[ "$output" != *"osascript called"* ]]
}

@test "clean_trash reports skipped items instead of silent partial empty (#1517)" {
    mkdir -p "$HOME/.Trash"
    touch "$HOME/.Trash/one.tmp" "$HOME/.Trash/two.tmp"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
debug_log() { :; }
safe_remove() {
    local target="$1"
    [[ "$target" == *"/two.tmp" ]] && return 1
    rm -f "$target"
    return 0
}

clean_trash
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Trash · removed 1 items, 1 skipped"* ]] || return 1
    [[ -e "$HOME/.Trash/two.tmp" ]]
    [[ ! -e "$HOME/.Trash/one.tmp" ]]
}

@test "clean_trash removes input-method leftovers already in Trash (#1517)" {
    rm -rf "$HOME/.Trash" # SAFE: reset this test's temporary HOME fixture before populating it
    mkdir -p "$HOME/.Trash/Input Methods"
    touch "$HOME/.Trash/com.sogou.inputmethod.sogou.plist"
    touch "$HOME/.Trash/com.tencent.inputmethod.QQInput.plist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
debug_log() { :; }

clean_trash
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Trash · emptied, 3 items"* ]] || return 1
    [[ ! -e "$HOME/.Trash/com.sogou.inputmethod.sogou.plist" ]]
    [[ ! -e "$HOME/.Trash/com.tencent.inputmethod.QQInput.plist" ]]
    [[ ! -d "$HOME/.Trash/Input Methods" ]]
}

@test "clean_user_essentials keeps Mole runtime logs while cleaning other user logs" {
    mkdir -p "$HOME/Library/Logs/mole"
    mkdir -p "$HOME/Library/Logs/OtherApp"
    touch "$HOME/Library/Logs/mole/operations.log"
    touch "$HOME/Library/Logs/OtherApp/old.log"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
safe_clean() {
    local path=""
    for path in "${@:1:$#-1}"; do
        if should_protect_path "$path"; then
            continue
        fi
        /bin/rm -rf "$path"
    done
}

safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${!#}"
    local -a targets=("${@:1:$#-1}")
    local -a kept=()
    local target
    for target in "${targets[@]}"; do
        if "$guard" "$target"; then
            kept+=("$target")
        fi
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
        return 75
    fi
    safe_clean "${kept[@]}" "$label"
}
clean_user_essentials

[[ -d "$HOME/Library/Logs/mole" ]] || exit 1
[[ -f "$HOME/Library/Logs/mole/operations.log" ]] || exit 1
[[ ! -e "$HOME/Library/Logs/OtherApp/old.log" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "clean_app_caches includes macOS system caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
start_section_spinner() { :; }
safe_clean() { echo "$2"; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Saved application states"* ]] || [[ "$output" == *"App caches"* ]]
}

@test "clean_app_caches does not clean Autosave Information" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
start_section_spinner() { :; }
safe_clean() { echo "$2|$1"; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Autosave information"* ]] || return 1
    [[ "$output" != *"Library/Autosave Information"* ]]
}

@test "clean_app_caches does not clean Calendar cache (#1508)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
start_section_spinner() { :; }
safe_clean() { echo "$2|$1"; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Calendar cache"* ]] || return 1
    [[ "$output" != *"Library/Calendars/Calendar Cache"* ]]
}

@test "clean_app_caches includes additional Apple cache families" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
start_section_spinner() { :; }
safe_clean() { echo "$2"; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_app_caches
EOF

    [ "$status" -eq 0 ] || return 1
    # The E5RT bundle cache is deliberately no longer a cleanup target: see
    # holds_compiled_model_cache(). Assert it first so the check cannot pass
    # vacuously on empty output.
    [[ "$output" != *"Apple Intelligence runtime cache"* ]] || return 1
    [[ "$output" == *"Apple Media Services cache"* ]] || return 1
    [[ "$output" == *"Duet Expert cache"* ]] || return 1
    [[ "$output" == *"Parsecd cache"* ]] || return 1
    [[ "$output" == *"Apple Python cache"* ]] || return 1
}

@test "clean_app_caches shows spinner during initial app cache scan" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { echo "SPIN_START:$1"; }
stop_section_spinner() { echo "SPIN_STOP"; }
safe_clean() { :; }
clean_support_app_data() { :; }
clean_group_container_caches() { :; }

clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SPIN_START:Scanning app caches..."* ]]
}

@test "clean_support_app_data targets crash reports and messages preview caches only" {
    local support_home="$HOME/support-cache-home-1"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
safe_find_delete() { echo "FIND:$1:$3:$4"; }
pgrep() { return 1; }

mkdir -p "$HOME/Library/Application Support/CrashReporter"
mkdir -p "$HOME/Library/Application Support/com.apple.idleassetsd"

clean_support_app_data

rm -rf "$HOME/Library/Application Support/CrashReporter"
rm -rf "$HOME/Library/Application Support/com.apple.idleassetsd"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"FIND:$support_home/Library/Application Support/CrashReporter:30:f"* ]] || return 1
    [[ "$output" != *"com.apple.idleassetsd"* ]] || return 1
    [[ "$output" != *"Aerial wallpaper videos"* ]] || return 1
    [[ "$output" == *"Messages sticker cache"* ]] || return 1
    [[ "$output" == *"Messages preview attachment cache"* ]] || return 1
    [[ "$output" == *"Messages preview sticker cache"* ]] || return 1
    [[ "$output" != *"Messages attachments"* ]]
}

@test "clean_support_app_data always cleans messages preview caches" {
    local support_home="$HOME/support-cache-home-2"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
safe_find_delete() { :; }
pgrep() { return 0; }

clean_support_app_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Messages sticker cache"* ]] || return 1
    [[ "$output" == *"Messages preview attachment cache"* ]] || return 1
    [[ "$output" == *"Messages preview sticker cache"* ]]
}

@test "clean_app_caches never hands a third-party container to safe_clean" {
    # The previous version mocked safe_clean to a no-op and asserted only that
    # "App caches" was absent from empty output, so it could not fail. It also
    # could not test what its name claimed: clean_app_caches walks a fixed list of
    # Apple container paths and never enumerates arbitrary bundle ids, so the
    # com.example.app fixture was never in scope either way.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
safe_clean() { echo "CLEAN:$1"; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/Library/Containers/com.example.app/Data/Library/Caches"
touch "$HOME/Library/Containers/com.example.app/Data/Library/Caches/test.cache"
clean_app_caches
EOF

    [ "$status" -eq 0 ]
    # Positive control: without it every assertion below is true on empty output.
    [[ "$output" == *"CLEAN:"*"Containers/com.apple."* ]] || return 1
    [[ "$output" != *"com.example.app"* ]] || return 1
    [[ "$output" != *"Containers/com.example"* ]]
}

@test "clean_app_caches preserves nested E5RT caches in sandboxed apps" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() {
    /bin/rm -rf "$1"
}

container="$HOME/Library/Containers/com.example.ocr"
cache_dir="$container/Data/Library/Caches"
e5rt_parent="$cache_dir/com.example.ocr"
mkdir -p "$e5rt_parent/com.apple.e5rt.e5bundlecache" "$cache_dir/disposable"
touch "$e5rt_parent/com.apple.e5rt.e5bundlecache/model.e5" "$cache_dir/disposable/data.tmp"

total_size=0
total_size_partial=false
cleaned_count=0
found_any=false
precise_size_limit=64
precise_size_used=0
process_container_cache "$container"

# Report state instead of asserting here: this script is fed to bash on stdin,
# and a child that drains the heredoc truncates whatever follows, so trailing
# in-script assertions can silently never run. Assert on $output below.
printf 'E5RT_KEPT=%s\n' "$([[ -f "$e5rt_parent/com.apple.e5rt.e5bundlecache/model.e5" ]] && echo yes || echo no)"
printf 'SIBLING_REMOVED=%s\n' "$([[ -e "$cache_dir/disposable" ]] && echo no || echo yes)"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"E5RT_KEPT=yes"* ]] || return 1
    [[ "$output" == *"SIBLING_REMOVED=yes"* ]] || return 1
}

@test "clean_app_caches skips expensive size scans for large sandboxed caches" {
    local large_home
    large_home=$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-large-container.XXXXXX")
    run env HOME="$large_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
safe_clean() { :; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
get_path_size_kb() {
    printf 'SIZE:%s\n' "$1" >> "$size_trace"
    printf '7\n'
}
safe_remove() { return 0; }
files_cleaned=0
total_size_cleaned=0
total_items=0

size_trace="$HOME/size-trace"
mkdir -p "$HOME/Library/Containers/com.example.large/Data/Library/Caches"
for i in $(seq 1 101); do
    touch "$HOME/Library/Containers/com.example.large/Data/Library/Caches/file-$i.tmp"
done

clean_app_caches
printf 'SIZE_CALLS=%s\n' "$(wc -l < "$size_trace" 2> /dev/null || printf '0')"
EOF

    rm -rf "$large_home"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sandboxed app caches"* ]] || return 1
    [[ "$output" == *"SIZE_CALLS=0"* ]]
}

@test "clean_application_support_logs counts nested directory contents in dry-run size summary" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { :; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/TestApp/Code Cache/nested"
dd if=/dev/zero of="$HOME/Library/Application Support/TestApp/Code Cache/nested/data.bin" bs=1024 count=2 2> /dev/null

clean_application_support_logs
echo "TOTAL_KB=$total_size_cleaned"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Application Support logs/caches"* ]] || return 1
    local total_kb
    total_kb=$(printf '%s\n' "$output" | sed -n 's/.*TOTAL_KB=\([0-9][0-9]*\).*/\1/p' | tail -1)
    [[ -n "$total_kb" ]] || return 1
	[[ "$total_kb" -ge 2 ]]
}

@test "clean_application_support_logs reuses exact item sizes at removal" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
app_support_item_size_bytes() { printf '2048\n'; }
safe_remove() { printf 'REMOVE=%s SILENT=%s SIZE=%s\n' "$1" "$2" "${3:-missing}" >> "$HOME/remove-calls"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

app_item="$HOME/Library/Application Support/TestApp/Code Cache/nested"
group_item="$HOME/Library/Group Containers/group.com.apple.contentdelivery/Logs/event.log"
mkdir -p "$app_item" "${group_item%/*}"
printf 'log\n' > "$group_item"

clean_application_support_logs
grep -Fx "REMOVE=$app_item SILENT=true SIZE=2" "$HOME/remove-calls"
grep -Fx "REMOVE=$group_item SILENT=true SIZE=2" "$HOME/remove-calls"
command rm -rf "$HOME/Library/Application Support/TestApp" \
    "$HOME/Library/Group Containers/group.com.apple.contentdelivery" \
    "$HOME/remove-calls"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REMOVE=$HOME/Library/Application Support/TestApp/Code Cache/nested SILENT=true SIZE=2"* ]] || return 1
	[[ "$output" == *"REMOVE=$HOME/Library/Group Containers/group.com.apple.contentdelivery/Logs/event.log SILENT=true SIZE=2"* ]] || return 1
}

@test "clean_application_support_logs uses bulk clean for large Application Support directories" {
    local support_home="$HOME/support-appsupport-bulk"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { echo "SPIN:$1"; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { echo "REMOVE:$1"; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
bytes_to_human() { echo "0B"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/adspower_global/Crashpad/completed"
for i in $(seq 1 101); do
    touch "$HOME/Library/Application Support/adspower_global/Crashpad/completed/file-$i.dmp"
done

clean_application_support_logs
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SPIN:Scanning Application Support... 1/1 [adspower_global, bulk clean]"* ]] || return 1
    [[ "$output" == *"Application Support logs/caches"* ]] || return 1
    [[ "$output" != *"151250 items"* ]] || return 1
    [[ "$output" != *"REMOVE:"* ]]
}

@test "clean_application_support_logs does not clean generic Application Support logs" {
    local support_home="$HOME/support-appsupport-generic-logs"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { echo "REMOVE:$1"; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/TestApp/logs"
touch "$HOME/Library/Application Support/TestApp/logs/runtime.log"

clean_application_support_logs
test -f "$HOME/Library/Application Support/TestApp/logs/runtime.log"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"REMOVE:"* ]]
}

@test "clean_application_support_logs cleans Electron-style Cache only when cache markers exist" {
    local support_home="$HOME/support-appsupport-electron-cache"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
WHITELIST_PATTERNS=()
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/ElectronLike/Code Cache"
mkdir -p "$HOME/Library/Application Support/ElectronLike/Cache"
mkdir -p "$HOME/Library/Application Support/ElectronLike/CachedData"
touch "$HOME/Library/Application Support/ElectronLike/Code Cache/runtime.bin"
touch "$HOME/Library/Application Support/ElectronLike/Cache/http-cache"
touch "$HOME/Library/Application Support/ElectronLike/CachedData/v8-data"

mkdir -p "$HOME/Library/Application Support/PlainApp/Cache"
touch "$HOME/Library/Application Support/PlainApp/Cache/keep.db"

clean_application_support_logs

test ! -e "$HOME/Library/Application Support/ElectronLike/Code Cache/runtime.bin"
test ! -e "$HOME/Library/Application Support/ElectronLike/Cache/http-cache"
test ! -e "$HOME/Library/Application Support/ElectronLike/CachedData/v8-data"
test -e "$HOME/Library/Application Support/PlainApp/Cache/keep.db"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
}

@test "clean_application_support_logs skips whitelisted application support directories" {
    local support_home="$HOME/support-appsupport-whitelist"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { echo "REMOVE:$1"; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
WHITELIST_PATTERNS=("$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/Code Cache"
touch "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/Code Cache/runtime.bin"

clean_application_support_logs
test -f "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/Code Cache/runtime.bin"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"REMOVE:"* ]]
}

@test "app_support_entry_count_capped stops at cap without failing under pipefail" {
    local support_home="$HOME/support-appsupport-cap"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

mkdir -p "$HOME/Library/Application Support/adspower_global/logs"
for i in $(seq 1 150); do
    touch "$HOME/Library/Application Support/adspower_global/logs/file-$i.log"
done

count=$(app_support_entry_count_capped "$HOME/Library/Application Support/adspower_global/logs" 1 101)
echo "COUNT=$count"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=101"* ]]
}

@test "clean_group_container_caches keeps protected caches and cleans non-protected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
_mole_user_cache_owner_process_state() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Logs"
mkdir -p "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Caches"
mkdir -p "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches"
echo "log" > "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Logs/log.txt"
echo "cache" > "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Caches/cache.db"
echo "cache" > "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/cache.db"

clean_group_container_caches

if [[ ! -e "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Logs/log.txt" ]] \
    && [[ -e "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Caches/cache.db" ]] \
    && [[ ! -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/cache.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Group Containers logs/caches"* ]] || return 1
	[[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches reuses exact item sizes at removal" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_data() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { printf '77\n'; }
safe_remove() { printf 'REMOVE=%s SILENT=%s SIZE=%s\n' "$1" "$2" "$3"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

item="$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/cache.db"
mkdir -p "${item%/*}"
printf 'cache\n' > "$item"
clean_group_container_caches
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REMOVE=$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/cache.db SILENT=true SIZE=77"* ]] || return 1
}

@test "clean_group_container_caches dry run omits a live nested non-SQLite cache (#1471)" {
    local live_target="$HOME/Library/Group Containers/TEAM.com.example.shared/Library/Caches/ComputerUse"
    local idle_target="$HOME/Library/Group Containers/TEAM.com.example.shared/Library/Caches/IdleCache"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true \
        live_target="$live_target" idle_target="$idle_target" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_data() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
_mole_user_cache_owner_process_state() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
lsof() {
    printf '%s\n' "$*" >> "$lsof_trace"
    case "$*" in
        *"+D $live_target"*)
            printf 'p901\nf5\nn%s\n' "$live_file"
            return 0
            ;;
        *"+D $idle_target"*) return 1 ;;
        *) return 2 ;;
    esac
}
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { printf '77\n'; }
record_dry_run_cleanup_target() { printf 'PREVIEW=%s\n' "$1"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

live_file="$live_target/segments/current/events.jsonl"
lsof_trace="$HOME/container-lsof-trace"
mkdir -p "${live_file%/*}"
mkdir -p "$idle_target"
printf 'event\n' > "$live_file"
printf 'idle\n' > "$idle_target/state.json"
clean_group_container_caches
test -f "$live_file" || exit 1
grep -qF "+D $live_target" "$lsof_trace" || exit 1
grep -qF "+D $idle_target" "$lsof_trace" || exit 1
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"PREVIEW=$live_target"* ]] || return 1
    [[ "$output" == *"PREVIEW=$idle_target"* ]] || return 1
}

@test "clean_group_container_caches dry run omits compiled model cache parents (#1471)" {
    local model_home
    model_home=$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-model-group.XXXXXX")
    local model_parent="$model_home/Library/Group Containers/TEAM.com.example.shared/Library/Caches/Vision"
    local idle_target="$model_home/Library/Group Containers/TEAM.com.example.shared/Library/Caches/ZIdle"
    run env HOME="$model_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 \
        model_parent="$model_parent" idle_target="$idle_target" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_data() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
_mole_user_cache_owner_process_state() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
_mole_timeout_with_deadline() {
    [[ ! -f "$exhausted_marker" ]] || return 1
    printf '2\n'
}
lsof() {
    case "$*" in
        *"+D $model_parent"*)
            touch "$exhausted_marker"
            return 1
            ;;
        *"+D $idle_target"*) return 1 ;;
        *) return 2 ;;
    esac
}
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { printf '7\n'; }
register_dry_run_cleanup_target() { printf 'REGISTER=%s\n' "$1"; }
append_dry_run_cleanup_target() { printf 'APPEND=%s\n' "$1"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

exhausted_marker="$HOME/compiled-probe-spent-budget"
mkdir -p "$model_parent/com.apple.e5rt.e5bundlecache"
mkdir -p "$idle_target"
printf 'model\n' > "$model_parent/com.apple.e5rt.e5bundlecache/model.bin"
printf 'idle\n' > "$idle_target/state.json"
clean_group_container_caches
printf 'FILES=%s SIZE=%s ITEMS=%s EXISTS=%s\n' \
    "$files_cleaned" "$total_size_cleaned" "$total_items" \
    "$(test -d "$model_parent" && echo yes || echo no)"
EOF

    rm -rf "$model_home"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"FILES=1 SIZE=7 ITEMS=1 EXISTS=yes"* ]] || return 1
    [[ "$output" != *"REGISTER=$model_parent"* ]] || return 1
    [[ "$output" != *"APPEND=$model_parent"* ]] || return 1
    [[ "$output" == *"REGISTER=$idle_target"* ]] || return 1
    [[ "$output" == *"APPEND=$idle_target"* ]] || return 1
    [[ "$output" == *"Group Containers logs/caches"* ]] || return 1
}

@test "explicit App Container cleanup families expose one cumulative probe deadline (#1471)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
bytes_to_human() { printf '0B\n'; }
directory_has_entries() { return 1; }
clean_support_app_data() { :; }
safe_clean() {
    case "${*: -1}" in
        "Wallpaper agent cache" | "Microsoft Word container cache" | "UTM sandbox cache")
            [[ -n "${_MOLE_CONTAINER_CACHE_PROBE_DEADLINE+x}" ]] || {
                printf 'MISSING=%s\n' "${*: -1}"
                return 99
            }
            if [[ -z "$_MOLE_CONTAINER_CACHE_PROBE_DEADLINE" ]]; then
                _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=4242
            elif [[ "$_MOLE_CONTAINER_CACHE_PROBE_DEADLINE" != "4242" ]]; then
                printf 'RESET=%s:%s\n' "${*: -1}" "$_MOLE_CONTAINER_CACHE_PROBE_DEADLINE"
                return 99
            fi
            printf 'SCOPED=%s\n' "${*: -1}"
            ;;
    esac
}
files_cleaned=0
total_size_cleaned=0
total_items=0

clean_app_caches
clean_office_applications
clean_utm_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SCOPED=Wallpaper agent cache"* ]] || return 1
    [[ "$output" == *"SCOPED=Microsoft Word container cache"* ]] || return 1
    [[ "$output" == *"SCOPED=UTM sandbox cache"* ]] || return 1
    [[ "$output" != *"MISSING="* ]] || return 1
    [[ "$output" != *"RESET="* ]] || return 1
}

@test "process_container_cache counts only items safe_remove actually removed (#1471)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
should_protect_data() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
holds_compiled_model_cache() { return 1; }
get_path_size_kb() { printf '7\n'; }
safe_remove() { return 1; }

container="$HOME/Library/Containers/com.example.Failed"
target="$container/Data/Library/Caches/Live"
mkdir -p "$target"
printf 'live\n' > "$target/state.json"
total_size=0
total_size_partial=false
cleaned_count=0
found_any=false
precise_size_limit=64
precise_size_used=0
process_container_cache "$container"
printf 'FOUND=%s CLEANED=%s SIZE=%s EXISTS=%s\n' \
    "$found_any" "$cleaned_count" "$total_size" \
    "$(test -d "$target" && echo yes || echo no)"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"FOUND=false CLEANED=0 SIZE=0 EXISTS=yes"* ]] || return 1
}

@test "clean_group_container_caches does not report or count an all-refused large candidate (#1471)" {
    local refused_home
    refused_home=$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-refused-group.XXXXXX")
    run env HOME="$refused_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_data() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { return 1; }
get_path_size_kb() { printf 'UNEXPECTED_SIZE\n'; return 99; }
files_cleaned=0
total_size_cleaned=0
total_items=0

candidate="$HOME/Library/Group Containers/group.com.example.refused/Library/Caches"
mkdir -p "$candidate"
for i in $(seq 1 101); do
    printf 'live\n' > "$candidate/item-$i.jsonl"
done
clean_group_container_caches
remaining=$(find "$candidate" -type f | wc -l | tr -d ' ')
printf 'FILES=%s SIZE=%s ITEMS=%s REMAINING=%s\n' \
    "$files_cleaned" "$total_size_cleaned" "$total_items" "$remaining"
EOF

    rm -rf "$refused_home"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"FILES=0 SIZE=0 ITEMS=0 REMAINING=101"* ]] || return 1
    [[ "$output" != *"Group Containers logs/caches"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SIZE"* ]] || return 1
}

@test "clean_handoff_pasteboard_cache removes stale items and keeps fresh ones (#1178)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

pb="$HOME/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard"
mkdir -p "$pb/stale-item" "$pb/fresh-item"
echo "payload" > "$pb/stale-item/data"
echo "payload" > "$pb/fresh-item/data"
touch -t 202001010000 "$pb/stale-item"

clean_handoff_pasteboard_cache

# Stale item is removed, the in-flight (fresh) item and the container root
# survive. If path protection ever tightens over group.com.apple.* the stale
# item would survive too and this test must fail loudly.
if [[ ! -e "$pb/stale-item" ]] && [[ -e "$pb/fresh-item" ]] && [[ -d "$pb" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Handoff clipboard cache"* ]] || return 1
    [[ "$output" == *"PASS"* ]] || return 1
}

@test "clean_handoff_pasteboard_cache dry run reports without deleting" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

pb="$HOME/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard"
mkdir -p "$pb/stale-item"
echo "payload" > "$pb/stale-item/data"
touch -t 202001010000 "$pb/stale-item"

clean_handoff_pasteboard_cache

if [[ -e "$pb/stale-item/data" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Handoff clipboard cache"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"PASS"* ]] || return 1
}

@test "jetbrains_stale_version_dirs reports only superseded IDE version dirs (#1179)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

jb="$HOME/Library/Application Support/JetBrains"
mkdir -p "$jb/GoLand2024.3" "$jb/GoLand2025.1" "$jb/GoLand2025.2" \
    "$jb/PyCharm2025.1" "$jb/IntelliJIdea2024.2" "$jb/IntelliJIdea2024.10" \
    "$jb/Toolbox"

jetbrains_stale_version_dirs "$jb" | sort
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"GoLand2024.3"* ]] || return 1
    [[ "$output" == *"GoLand2025.1"* ]] || return 1
    # Minor version 10 outranks 2: 2024.2 is stale, 2024.10 is the newest.
    [[ "$output" == *"IntelliJIdea2024.2"* ]] || return 1
    [[ "$output" != *"GoLand2025.2"* ]] || return 1
    [[ "$output" != *"PyCharm"* ]] || return 1
    [[ "$output" != *"IntelliJIdea2024.10"* ]] || return 1
    [[ "$output" != *"Toolbox"* ]] || return 1
}

@test "clean_group_container_caches skips Apple Notes group container" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

notes_cache="$HOME/Library/Group Containers/group.com.apple.notes/Library/Caches"
mkdir -p "$notes_cache"
echo "notes" > "$notes_cache/NoteStore.sqlite"

clean_group_container_caches

if [[ -e "$notes_cache/NoteStore.sqlite" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches respects whitelist entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
_mole_user_cache_owner_process_state() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches"
echo "protected" > "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/keep.db"
echo "remove" > "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/drop.db"

is_path_whitelisted() {
    [[ "$1" == *"/group.com.example.tool/Library/Caches/keep.db" ]]
}

clean_group_container_caches

if [[ -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/keep.db" ]] \
    && [[ ! -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/drop.db" ]]; then
    echo "PASS"
else
    # A bare FAIL cannot be told apart from a size-probe timeout under a
    # loaded parallel run, which is how this case reports when the suite is
    # busy. Print what actually survived.
    echo "FAIL"
    echo "keep.db present: $([[ -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/keep.db" ]] && echo yes || echo no)"
    echo "drop.db present: $([[ -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/drop.db" ]] && echo yes || echo no)"
    ls -la "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches" 2> /dev/null || true
    exit 1
fi
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches skips systemgroup apple containers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/systemgroup.com.apple.example/Library/Caches"
echo "system-data" > "$HOME/Library/Group Containers/systemgroup.com.apple.example/Library/Caches/cache.db"

clean_group_container_caches

if [[ -e "$HOME/Library/Group Containers/systemgroup.com.apple.example/Library/Caches/cache.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches does not report when only whitelisted items exist" {
    local whitelist_home="$HOME/group-only-whitelisted"
    mkdir -p "$whitelist_home"

    run env HOME="$whitelist_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.example.onlywhite/Library/Caches"
echo "whitelisted" > "$HOME/Library/Group Containers/group.com.example.onlywhite/Library/Caches/keep.db"

is_path_whitelisted() {
    [[ "$1" == *"/group.com.example.onlywhite/Library/Caches/keep.db" ]]
}

clean_group_container_caches

if [[ -e "$HOME/Library/Group Containers/group.com.example.onlywhite/Library/Caches/keep.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]] || return 1
    [[ "$output" != *"Group Containers logs/caches"* ]]
}

@test "clean_group_container_caches skips per-item size scans for large candidates" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
_mole_user_cache_owner_process_state() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() {
    echo "SHOULD_NOT_SIZE_SCAN"
    return 0
}
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.example.large/Library/Caches"
for i in $(seq 1 101); do
    touch "$HOME/Library/Group Containers/group.com.example.large/Library/Caches/file-$i.tmp"
done

clean_group_container_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Group Containers logs/caches"* ]] || return 1
    [[ "$output" != *"SHOULD_NOT_SIZE_SCAN"* ]]
}

@test "clean_finder_metadata respects protection flag" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PROTECT_FINDER_METADATA=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
note_activity() { :; }
clean_finder_metadata
EOF

    [ "$status" -eq 0 ]
    # Whitelist-protected items no longer show output (UX improvement in V1.22.0)
    [[ "$output" == "" ]]
}

@test "clean_browsers calls expected cache paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { :; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Safari cache"* ]] || return 1
    [[ "$output" == *"Firefox cache"* ]] || return 1
    [[ "$output" == *"Puppeteer browser cache"* ]]
}

@test "clean_browsers never enters Firefox cleanup while Firefox is running" {
    mkdir -p "$HOME/Library/Caches/Firefox" \
        "$HOME/Library/Application Support/Firefox/Profiles/default/cache2"
    touch "$HOME/Library/Caches/Firefox/candidate" \
        "$HOME/Library/Application Support/Firefox/Profiles/default/cache2/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { [[ "$*" == "-x Firefox" ]]; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_service_worker_cache() { :; }
note_activity() { :; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"SAFE_CLEAN:Firefox cache"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Firefox profile cache"* ]]
}

@test "clean_browsers fails closed when the Chrome process probe errors" {
    local chrome_support="$HOME/Library/Application Support/Google/Chrome"
    rm -rf "$chrome_support"
    mkdir -p "$chrome_support/Default/Code Cache"
    touch "$chrome_support/Default/Code Cache/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 2; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_service_worker_cache() { :; }
note_activity() { :; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Chrome profile caches · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Chrome code cache"* ]]
}

@test "clean_browsers does not defer empty Chrome and Firefox roots" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
rm -rf "$HOME/Library/Application Support/Google/Chrome" \
    "$HOME/Library/Caches/Firefox" \
    "$HOME/Library/Application Support/Firefox/Profiles"
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache" \
    "$HOME/Library/Caches/Firefox" \
    "$HOME/Library/Application Support/Firefox/Profiles/default/cache2"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { :; }
clean_service_worker_cache() { :; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER:Chrome"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER:Firefox"* ]] || return 1
    [[ "$output" != *"process state unknown"* ]]
}

@test "clean_browsers does not defer broken-symlink-only Chrome and Firefox roots" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
rm -rf "$HOME/Library/Application Support/Google/Chrome" \
    "$HOME/Library/Caches/Firefox" \
    "$HOME/Library/Application Support/Firefox/Profiles"
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache" \
    "$HOME/Library/Caches/Firefox" \
    "$HOME/Library/Application Support/Firefox/Profiles/default/cache2"
ln -s "$HOME/missing-chrome-cache" \
    "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache/broken"
ln -s "$HOME/missing-firefox-cache" "$HOME/Library/Caches/Firefox/broken"
ln -s "$HOME/missing-firefox-profile-cache" \
    "$HOME/Library/Application Support/Firefox/Profiles/default/cache2/broken"
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache/compiled/com.apple.e5rt.e5bundlecache"
mkdir -p "$HOME/Library/Caches/Firefox/compiled/com.apple.e5rt.e5bundlecache"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_service_worker_cache() { :; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER:Chrome"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER:Firefox"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Chrome code cache"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Firefox cache"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Firefox profile cache"* ]]
}

@test "clean_browsers ignores active whitelist-only Chrome profile caches" {
    local chrome_support="$HOME/Library/Application Support/Google/Chrome"
    rm -rf "$chrome_support"
    mkdir -p "$chrome_support/Default/Code Cache"
    touch "$chrome_support/Default/Code Cache/whitelisted"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
target="$HOME/Library/Application Support/Google/Chrome/Default/Code Cache/whitelisted"
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { :; }
clean_service_worker_cache() { :; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER:Chrome"* ]]
}

@test "clean_cloud_storage never enters active provider cleanup when caches are absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() {
    case "$*" in
        "-x Dropbox" | "-x Google Drive" | "-x OneDrive") return 0 ;;
        *) return 1 ;;
    esac
}
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_cloud_storage
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"SAFE_CLEAN:Dropbox cache"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Google Drive cache"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:OneDrive cache"* ]]
}

@test "clean_cloud_storage fails closed when provider probes error" {
    local cache_root="$HOME/Library/Caches"
    mkdir -p "$cache_root/com.getdropbox.dropbox" \
        "$cache_root/com.google.GoogleDrive" \
        "$cache_root/com.microsoft.OneDrive"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 2; }
should_protect_path() { return 1; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_cloud_storage
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Dropbox cache · skipped (process state unknown)"* ]] || return 1
    [[ "$output" == *"Google Drive cache · skipped (process state unknown)"* ]] || return 1
    [[ "$output" == *"OneDrive cache · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Dropbox cache"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Google Drive cache"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:OneDrive cache"* ]]
}

@test "clean_browsers keeps all Chrome AI model stores when whitelisted" {
    local chrome_support="$HOME/Library/Application Support/Google/Chrome"
    mkdir -p "$chrome_support/OptGuideOnDeviceModel/2026"
    mkdir -p "$chrome_support/OptGuideOnDeviceClassifierModel/2026"
    mkdir -p "$chrome_support/optimization_guide_model_store/2026"
    mkdir -p "$chrome_support/Default/Code Cache/js"
    touch "$chrome_support/OptGuideOnDeviceModel/2026/model.bin"
    touch "$chrome_support/OptGuideOnDeviceClassifierModel/2026/classifier.bin"
    touch "$chrome_support/optimization_guide_model_store/2026/model.bin"
    touch "$chrome_support/Default/Code Cache/js/cache.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
WHITELIST_PATTERNS=(
    "$HOME/Library/Application Support/Google/Chrome/OptGuideOnDevice*/*"
    "$HOME/Library/Application Support/Google/Chrome/optimization_guide_model_store/*"
)
pgrep() { return 1; }
# The fixture HOME carries Library/Caches/com.apple.Safari from a sibling
# test, and validate_path_for_deletion refuses a cache whose owner is live.
# Pin an empty process table so this whitelist test does not depend on
# whether Safari happens to be running on the machine (#1390).
ps() { printf '  PID  PPID COMM ARGS\n'; }
clean_service_worker_cache() { :; }
note_activity() { :; }
safe_clean() {
    local count=$#
    local label="${!count}"
    local index item
    for ((index = 1; index < count; index++)); do
        item="${!index}"
        if is_path_whitelisted "$item"; then
            printf 'KEEP:%s:%s\n' "$label" "$item"
        else
            safe_remove "$item" true
        fi
    done
}
clean_browsers
EOF

    [ "$status" -eq 0 ] || return 1
    [[ -f "$chrome_support/OptGuideOnDeviceModel/2026/model.bin" ]] || return 1
    [[ -f "$chrome_support/OptGuideOnDeviceClassifierModel/2026/classifier.bin" ]] || return 1
    [[ -f "$chrome_support/optimization_guide_model_store/2026/model.bin" ]] || return 1
    [[ ! -e "$chrome_support/Default/Code Cache/js/cache.bin" ]] || return 1
    [[ "$output" == *"KEEP:Chrome on-device model cache"* ]] || return 1
    [[ "$output" == *"KEEP:Chrome on-device classifier cache"* ]] || return 1
    [[ "$output" == *"KEEP:Chrome optimization guide models"* ]] || return 1
}

@test "clean_browsers preserves Brave Service Worker ScriptCache" {
    mkdir -p "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker/ScriptCache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { echo "Brave SW $1"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Brave SW Brave"* ]] || return 1
    [[ "$output" != *"Brave Service Worker ScriptCache"* ]] || return 1

    rm -rf "$HOME/Library"
}

@test "clean_browsers covers Arc User Data layout" {
    mkdir -p "$HOME/Library/Application Support/Arc/User Data/Default/Service Worker/ScriptCache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2|$1"; }
clean_service_worker_cache() { echo "Arc SW $2"; }
note_activity() { :; }
pgrep() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Arc code cache|$HOME/Library/Application Support/Arc/User Data/"* ]] || return 1
    [[ "$output" == *"Arc component CRX cache|$HOME/Library/Application Support/Arc/User Data/component_crx_cache/"* ]] || return 1
    [[ "$output" == *"Arc extensions CRX cache|$HOME/Library/Application Support/Arc/User Data/extensions_crx_cache/"* ]] || return 1
    [[ "$output" == *"Arc SW $HOME/Library/Application Support/Arc/User Data/Default/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" != *"Arc Service Worker ScriptCache|$HOME/Library/Application Support/Arc/User Data/Default/Service Worker/ScriptCache/"* ]] || return 1

    rm -rf "$HOME/Library"
}

@test "clean_browsers always preserves Chromium Service Worker ScriptCache (#785 #964 #968)" {
    mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default/Service Worker/ScriptCache"
    mkdir -p "$HOME/Library/Application Support/Arc/User Data/Default/Service Worker/ScriptCache"
    mkdir -p "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker/ScriptCache"
    mkdir -p "$HOME/Library/Application Support/Vivaldi/Default/Service Worker/ScriptCache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { echo "SW-CALL $1"; }
note_activity() { :; }
pgrep() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    # CacheStorage cleanup still runs (it has its own protection logic).
    [[ "$output" == *"SW-CALL Chrome"* ]] || return 1
    # ScriptCache cleanup must NOT run at all: wiping V8 bytecode can break
    # Chromium MV3 extension service workers even after the browser exits.
    [[ "$output" != *"Chrome Service Worker ScriptCache"* ]] || return 1
    [[ "$output" != *"Arc Service Worker ScriptCache"* ]] || return 1
    [[ "$output" != *"Brave Service Worker ScriptCache"* ]] || return 1
    [[ "$output" != *"Vivaldi Service Worker ScriptCache"* ]] || return 1

    rm -rf "$HOME/Library"
}

@test "clean_browsers preserves Arc User Data ScriptCache regardless of running state" {
    mkdir -p "$HOME/Library/Application Support/Arc/User Data/Default/Service Worker/ScriptCache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2|$1"; }
clean_service_worker_cache() { echo "Arc SW $2"; }
note_activity() { :; }
pgrep() {
    [[ "${2:-}" == "Arc" ]]
}
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Arc SW $HOME/Library/Application Support/Arc/User Data/Default/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" != *"Arc Service Worker ScriptCache|$HOME/Library/Application Support/Arc/User Data/Default/Service Worker/ScriptCache/"* ]] || return 1

    rm -rf "$HOME/Library"
}

@test "clean_browsers covers QQ Browser 3 caches when not running" {
    mkdir -p "$HOME/Library/Application Support/QQBrowser3/Default/Code Cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2|$1"; }
clean_service_worker_cache() { :; }
note_activity() { :; }
pgrep() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QQ Browser cache|$HOME/Library/Caches/com.tencent.QQBrowser3/"* ]] || return 1
    [[ "$output" == *"QQ Browser code cache|$HOME/Library/Application Support/QQBrowser3/"* ]] || return 1
    [[ "$output" == *"QQ Browser component cache|$HOME/Library/Application Support/QQBrowser3/component_crx_cache/"* ]] || return 1

    rm -rf "$HOME/Library"
}

@test "clean_browsers skips QQ Browser 3 profile caches while running" {
    mkdir -p "$HOME/Library/Application Support/QQBrowser3/Default/Code Cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2|$1"; }
clean_service_worker_cache() { :; }
note_activity() { :; }
pgrep() {
    [[ "${2:-}" == "QQBrowser3" ]]
}
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QQ Browser cache|$HOME/Library/Caches/com.tencent.QQBrowser3/"* ]] || return 1
    [[ "$output" != *"QQ Browser code cache"* ]] || return 1
    [[ "$output" != *"QQ Browser GPU cache"* ]] || return 1

    rm -rf "$HOME/Library"
}

@test "clean_application_support_logs skips when no access" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
clean_application_support_logs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped: No permission"* ]]
}

@test "clean_apple_silicon_caches exits when not M-series" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" IS_M_SERIES=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_apple_silicon_caches
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "clean_user_essentials includes dotfiles in Trash cleanup" {
    mkdir -p "$HOME/.Trash"
    touch "$HOME/.Trash/.hidden_file"
    touch "$HOME/.Trash/.DS_Store"
    touch "$HOME/.Trash/regular_file.txt"
    mkdir -p "$HOME/.Trash/.hidden_dir"
    mkdir -p "$HOME/.Trash/regular_dir"

    run /bin/bash << 'EOF'
set -euo pipefail
count=0
while IFS= read -r -d '' item; do
    ((count++)) || true
    echo "FOUND: $(basename "$item")"
done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
echo "COUNT: $count"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT: 5"* ]] || return 1
    [[ "$output" == *"FOUND: .hidden_file"* ]] || return 1
    [[ "$output" == *"FOUND: .DS_Store"* ]] || return 1
    [[ "$output" == *"FOUND: .hidden_dir"* ]] || return 1
    [[ "$output" == *"FOUND: regular_file.txt"* ]]
}

@test "validate_external_volume_target canonicalizes root before comparing target" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

mock_bin="$HOME/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/diskutil" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$mock_bin/diskutil"
export PATH="$mock_bin:$PATH"

real_root="$(mktemp -d "$HOME/ext-real.XXXXXX")"
link_root="$HOME/ext-link"
ln -s "$real_root" "$link_root"
mkdir -p "$link_root/USB"
export MOLE_EXTERNAL_VOLUMES_ROOT="$link_root"

resolved=$(validate_external_volume_target "$link_root/USB")
echo "RESOLVED=$resolved"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"RESOLVED="*"/USB"* ]] || return 1
    [[ "$output" != *"must be under"* ]]
}

@test "clean_app_caches caps precise sandbox size scans when many containers exist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_CONTAINER_CACHE_PRECISE_SIZE_LIMIT=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { :; }
clean_support_app_data() { :; }
clean_group_container_caches() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
_mole_user_cache_owner_process_state() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

count_file="$HOME/size-count"
get_path_size_kb() {
    local count
    count=$(cat "$count_file" 2> /dev/null || echo "0")
    count=$((count + 1))
    echo "$count" > "$count_file"
    echo "1"
}

for i in $(seq 1 5); do
    mkdir -p "$HOME/Library/Containers/com.example.$i/Data/Library/Caches"
    touch "$HOME/Library/Containers/com.example.$i/Data/Library/Caches/file-$i.tmp"
done

clean_app_caches
echo "SIZE_CALLS=$(cat "$count_file")"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sandboxed app caches"* ]] || return 1
    [[ "$output" == *"SIZE_CALLS=2"* ]]
}

@test "clean_app_caches stops before deleting when a container size probe times out" {
    local container="$HOME/Library/Containers/com.example.timeout/Data/Library/Caches"
    mkdir -p "$container"
    touch "$container/payload"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { :; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }
clean_support_app_data() { :; }
clean_group_container_caches() { echo "UNEXPECTED_CONTINUATION"; }
clean_handoff_pasteboard_cache() { echo "UNEXPECTED_CONTINUATION"; }
note_activity() { :; }
get_path_size_kb() { return 124; }
files_cleaned=0
total_size_cleaned=0
total_items=0

set +e
clean_app_caches
rc=$?
set -e
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124 CANCEL=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CONTINUATION"* ]]
}

# Regression for discussion #583: the only Dia row used to be
# ~/Library/Caches/company.thebrowser.dia, which on a real install holds nothing
# but Sentry crash state. The actual Chromium caches live under
# ~/Library/Caches/Dia/User Data and ~/Library/Application Support/Dia/User Data,
# so `mo clean` reclaimed 0 bytes from Dia. Paths below were measured on Dia
# 1.41.1 (bundle company.thebrowser.dia), not inferred from Chromium convention.
@test "clean_browsers covers the real Dia cache locations" {
    mkdir -p "$HOME/Library/Caches/company.thebrowser.dia/io.sentry"
    mkdir -p "$HOME/Library/Caches/Dia/User Data/Default/Cache/Cache_Data"
    mkdir -p "$HOME/Library/Caches/Dia/User Data/Default/Code Cache/js"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/GraphiteDawnCache"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/GPUPersistentCache"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/component_crx_cache"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/extensions_crx_cache"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/Default/DawnGraphiteCache"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/Default/DawnWebGPUCache"
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/Default/GPUCache"
    touch "$HOME/Library/Caches/Dia/User Data/Default/Cache/Cache_Data/entry"
    touch "$HOME/Library/Application Support/Dia/User Data/component_crx_cache/blob"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
clean_service_worker_cache() { :; }
# Must be mocked: an unmocked pgrep sees the maintainer's real Dia process and
# silently flips this test to the skip branch.
pgrep() { return 1; }
safe_clean() { local n=$#; echo "CLEAN:${!n}"; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CLEAN:Dia HTTP cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia code cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia component CRX cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia extensions CRX cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia Graphite Dawn cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia GPU cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia Dawn Graphite cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Dia Dawn WebGPU cache"* ]] || return 1
}

@test "clean_browsers skips Dia Application Support caches while Dia runs" {
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/component_crx_cache"
    mkdir -p "$HOME/Library/Caches/Dia/User Data/Default/Cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
clean_service_worker_cache() { :; }
pgrep() { [[ "${2:-}" == "Dia" ]] && return 0; return 1; }
safe_clean() { local n=$#; echo "CLEAN:${!n}"; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Dia Application Support cache"* ]] || return 1
    [[ "$output" == *"skipped (Dia running)"* ]] || return 1
    [[ "$output" != *"CLEAN:Dia component CRX cache"* ]] || return 1
    [[ "$output" != *"CLEAN:Dia HTTP cache"* ]] || return 1
}

@test "clean_browsers fails closed when the Dia process probe errors" {
    mkdir -p "$HOME/Library/Application Support/Dia/User Data/component_crx_cache"
    mkdir -p "$HOME/Library/Caches/Dia/User Data/Default/Cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
clean_service_worker_cache() { :; }
pgrep() { return 2; }
safe_clean() { local n=$#; echo "CLEAN:${!n}"; }
clean_browsers
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"CLEAN:Dia component CRX cache"* ]] || return 1
    [[ "$output" != *"CLEAN:Dia HTTP cache"* ]] || return 1
}

@test "large files includes the unique System Data review targets" {
    local review_home="$HOME/large-review-targets"
    mkdir -p \
        "$review_home/Library/Developer/Xcode/DerivedData" \
        "$review_home/Library/Developer/CoreSimulator/Devices" \
        "$review_home/Library/Containers/com.docker.docker/Data" \
        "$review_home/Library/Caches/deno" \
        "$review_home/go/pkg/mod"

    run env HOME="$review_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
docker() { return 1; }
defaults() { return 1; }
du() { printf '2097152 %s\n' "${2:-/tmp}"; }
run_with_timeout() {
    shift
    "$@"
}
check_large_file_candidates
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"⊙"* ]] &&
        [[ "$output" == *"Xcode DerivedData"* ]] &&
        [[ "$output" == *"Simulator data"* ]] &&
        [[ "$output" == *"Docker Desktop data"* ]] &&
        [[ "$output" == *"Deno module cache"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Go module cache"* ]] || {
        echo "$output"
        return 1
    }
}

@test "large files dates the irreplaceable rows and leaves caches undated" {
    local review_home="$HOME/large-review-dates"
    mkdir -p \
        "$review_home/Library/Application Support/MobileSync/Backup/00008150-DEVICE" \
        "$review_home/Library/Developer/Xcode/Archives/2026-03-04" \
        "$review_home/Library/Developer/Xcode/DerivedData/Some-project"
    touch -t 202601021200 "$review_home/Library/Application Support/MobileSync/Backup/00008150-DEVICE"
    touch -t 202603041200 "$review_home/Library/Developer/Xcode/Archives/2026-03-04"

    run env HOME="$review_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
docker() { return 1; }
defaults() { return 1; }
du() { printf '2097152 %s\n' "${2:-/tmp}"; }
run_with_timeout() {
    shift
    "$@"
}
check_large_file_candidates
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    # Size alone cannot decide these two: the date separates a live phone
    # backup from a dead one, and a shipped archive from a stray export.
    [[ "$output" == *"iOS backups"*"2026-01-02"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode archives"*"2026-03-04"* ]] || {
        echo "$output"
        return 1
    }
    # Rebuildable caches stay undated on purpose; their age never changes the
    # answer, and a date on every row would bury the two that matter.
    local derived_row
    derived_row=$(printf '%s\n' "$output" | grep 'Xcode DerivedData' || true)
    [[ -n "$derived_row" ]] || {
        echo "$output"
        return 1
    }
    [[ "$derived_row" != *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]* ]] || {
        echo "$derived_row"
        return 1
    }
}
