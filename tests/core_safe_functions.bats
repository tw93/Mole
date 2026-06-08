#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-safe-functions.XXXXXX")"
    export HOME

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

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    source "$PROJECT_ROOT/lib/core/common.sh"
    TEST_DIR="$HOME/test_safe_functions"
    mkdir -p "$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "validate_path_for_deletion rejects empty path" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion ''"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects relative path" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion 'relative/path'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects path traversal" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/tmp/../etc'"
    [ "$status" -eq 1 ]

    # Test other path traversal patterns
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/var/log/../../etc'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/..'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion accepts Firefox-style ..files directories" {
    # Firefox uses ..files suffix in IndexedDB directory names
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/2753419432nreetyfallipx..files'"
    [ "$status" -eq 0 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/storage/default/https+++www.netflix.com/idb/name..files/data'"
    [ "$status" -eq 0 ]

    # Directories with .. in the middle of names should be allowed
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/test..backup/file.txt'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion rejects system directories" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/System'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/usr/bin'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/etc'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Library/Apple'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Applications/Finder.app'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Users'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects aliased critical paths" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '//etc/passwd'"
    [ "$status" -eq 1 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '///System'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion accepts valid path" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/valid'"
    [ "$status" -eq 0 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$HOME/Library/Caches/com.example.app/cache.db'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion accepts CoreSimulator system cache children" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Library/Developer/CoreSimulator/Caches/dyld'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion allows Darwin C cache shards but rejects protected extension paths" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/folders/test/a/C/com.example.App/com.apple.metal'"
    [ "$status" -eq 0 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Library/Extensions/com.example.driver/com.apple.metal' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"critical system path"* ]]
}

@test "should_protect_path applies high-risk cleanup denylist" {
    run bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        should_protect_path '$HOME/Library/Caches/ms-playwright/chromium-123'
        should_protect_path '$HOME/Library/Caches/com.apple.homed/state'
        should_protect_path '$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite'
        should_protect_path '$HOME/Library/Preferences/com.paceap.eden.iLokLicenseManager.plist'
        should_protect_path '/private/var/folders/aa/bb/C/com.native-instruments.NativeAccess/license'
        should_protect_path '/Library/Audio/Plug-Ins/VST3/Example.vst3'
        should_protect_data 'com.native-instruments.NativeAccess'
        ! should_protect_path '$HOME/Library/Application Support/Example/Cache/item'
    "
    [ "$status" -eq 0 ]
}

@test "should_protect_path protects OrbStack live container data" {
    local orb_group_data="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw"
    local orb_state="$HOME/.orbstack/state.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ORB_GROUP_DATA="$orb_group_data" ORB_STATE="$orb_state" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
should_protect_data "dev.orbstack.OrbStack"
should_protect_data "dev.kdrag0n.MacVirt"
should_protect_path "$ORB_GROUP_DATA"
should_protect_path "$ORB_STATE"
EOF

    [ "$status" -eq 0 ]
}

@test "safe_remove validates path before deletion" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '/System/test' 2>&1"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects symlink to protected system path" {
    local link_path="$TEST_DIR/system-link"
    ln -s "/System" "$link_path"

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$link_path' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"protected system path"* ]]
}

@test "safe_remove silent mode hides protected symlink validation warning" {
    local link_path="$TEST_DIR/silent-system-link"
    ln -s "/System" "$link_path"

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$link_path' true 2>&1"
    [ "$status" -eq 1 ]
    [[ -L "$link_path" ]]
    [[ "$output" != *"Symlink points to protected system path"* ]]
}

@test "safe_remove successfully removes file" {
    local test_file="$TEST_DIR/test_file.txt"
    echo "test" > "$test_file"

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$test_file' true"
    [ "$status" -eq 0 ]
    [ ! -f "$test_file" ]
}

@test "safe_remove successfully removes directory" {
    local test_subdir="$TEST_DIR/test_subdir"
    mkdir -p "$test_subdir"
    touch "$test_subdir/file.txt"

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$test_subdir' true"
    [ "$status" -eq 0 ]
    [ ! -d "$test_subdir" ]
}

@test "safe_remove handles non-existent path gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$TEST_DIR/nonexistent' true"
    [ "$status" -eq 0 ]
}

@test "safe_remove preserves interrupt exit codes" {
    local test_file="$TEST_DIR/interrupt_file"
    echo "test" > "$test_file"

    run bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        rm() { return 130; }
        safe_remove '$test_file' true
    "
    [ "$status" -eq 130 ]
    [ -f "$test_file" ]
}

@test "safe_remove in silent mode suppresses error output" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '/System/test' true 2>&1"
    [ "$status" -eq 1 ]
}


@test "safe_find_delete validates base directory" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '/nonexistent' '*.tmp' 7 'f' 2>&1"
    [ "$status" -eq 1 ]
}

@test "safe_sudo_remove refuses symlink paths" {
    local target_dir="$TEST_DIR/real"
    local link_dir="$TEST_DIR/link"
    mkdir -p "$target_dir"
    ln -s "$target_dir" "$link_dir"

    run bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        sudo() { return 0; }
        export -f sudo
        safe_sudo_remove '$link_dir' 2>&1
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to sudo remove symlink"* ]]
}

@test "safe_sudo_remove never opens an interactive sudo prompt" {
    local target_dir="$TEST_DIR/sudo-target"
    mkdir -p "$target_dir"
    touch "$target_dir/file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

sudo() {
    if [[ "${1:-}" != "-n" ]]; then
        echo "INTERACTIVE_SUDO:$*" >&2
        return 99
    fi
    shift
    case "${1:-}" in
        test)
            shift
            command test "$@"
            ;;
        du)
            shift
            command du "$@"
            ;;
        rm)
            shift
            command rm "$@"
            ;;
        *)
            "$@"
            ;;
    esac
}
export -f sudo

safe_sudo_remove "$TARGET_DIR"
[[ ! -e "$TARGET_DIR" ]]
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" != *"INTERACTIVE_SUDO"* ]]
}

@test "safe_sudo_remove returns auth failure when noninteractive sudo expires" {
    local target_dir="$TEST_DIR/sudo-expired"
    mkdir -p "$target_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

sudo() {
    if [[ "${1:-}" != "-n" ]]; then
        echo "INTERACTIVE_SUDO:$*" >&2
        return 99
    fi
    echo "sudo: a password is required" >&2
    return 1
}
export -f sudo

safe_sudo_remove "$TARGET_DIR" && rc=0 || rc=$?
echo "RC=$rc"
[[ -e "$TARGET_DIR" ]]
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=11"* ]]
    [[ "$output" != *"INTERACTIVE_SUDO"* ]]
}

@test "safe_sudo_find_delete never opens an interactive sudo prompt" {
    local target_dir="$TEST_DIR/sudo-find-target"
    local script="$TEST_DIR/sudo-find-delete-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/old.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
TRACE="$TARGET_DIR/sudo.trace"
> "$TRACE"

sudo() {
    printf 'SUDO:%s\n' "$*" >> "$TRACE"
    if [[ "${1:-}" != "-n" ]]; then
        echo "INTERACTIVE_SUDO:$*" >&2
        return 99
    fi
    shift
    case "${1:-}" in
        test)
            shift
            command test "$@"
            ;;
        find)
            printf '%s\0' "$TARGET_DIR/old.log"
            ;;
        du)
            shift
            command du "$@"
            ;;
        rm)
            return 0
            ;;
        *)
            "$@"
            ;;
    esac
}
export -f sudo

set +e
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f"
rc=$?
set -e
printf 'RC=%s\n' "$rc"
cat "$TRACE" || true
exit 0
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 bash --noprofile --norc "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]]
    [[ "$output" == *"SUDO:-n test -d "* ]]
    [[ "$output" == *"SUDO:-n test -L "* ]]
    [[ "$output" == *"SUDO:-n find "* ]]
    [[ "$output" != *"INTERACTIVE_SUDO"* ]]
}

@test "safe_find_delete rejects symlinked directory" {
    local real_dir="$TEST_DIR/real"
    local link_dir="$TEST_DIR/link"
    mkdir -p "$real_dir"
    ln -s "$real_dir" "$link_dir"

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '$link_dir' '*.tmp' 7 'f' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]]

    rm -rf "$link_dir" "$real_dir"
}

@test "safe_find_delete validates type filter" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '$TEST_DIR' '*.tmp' 7 'x' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid type filter"* ]]
}

@test "safe_find_delete deletes old files" {
    local old_file="$TEST_DIR/old.tmp"
    local new_file="$TEST_DIR/new.tmp"

    touch "$old_file"
    touch "$new_file"

    touch -t "$(date -v-8d '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M.%S')" "$old_file" 2>/dev/null || true

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '$TEST_DIR' '*.tmp' 7 'f'"
    [ "$status" -eq 0 ]
}

@test "safe_find_delete works when app protection is not loaded" {
    local old_file="$TEST_DIR/file-ops-only.tmp"
    touch "$old_file"
    touch -t "$(date -v-8d '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M.%S')" "$old_file" 2>/dev/null || true

    run bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/file_ops.sh"
safe_find_delete "$TEST_DIR" "*.tmp" 7 "f"
EOF

    [ "$status" -eq 0 ]
    [ ! -e "$old_file" ]
}

@test "MOLE_* constants are defined" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_TEMP_FILE_AGE_DAYS"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_MAX_PARALLEL_JOBS"
    [ "$status" -eq 0 ]
    [ "$output" = "15" ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_TM_BACKUP_SAFE_HOURS"
    [ "$status" -eq 0 ]
    [ "$output" = "48" ]
}
