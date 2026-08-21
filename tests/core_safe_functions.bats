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
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion ''"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects relative path" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion 'relative/path'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects path traversal" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/tmp/../etc'"
    [ "$status" -eq 1 ]

    # Test other path traversal patterns
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/var/log/../../etc'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/..'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion accepts Firefox-style ..files directories" {
    # Firefox uses ..files suffix in IndexedDB directory names
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/2753419432nreetyfallipx..files'"
    [ "$status" -eq 0 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/storage/default/https+++www.netflix.com/idb/name..files/data'"
    [ "$status" -eq 0 ]

    # Directories with .. in the middle of names should be allowed
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/test..backup/file.txt'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion rejects system directories" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/System'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/usr/bin'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/etc'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Library/Apple'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Applications/Finder.app'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Users'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects aliased critical paths" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '//etc/passwd'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '///System'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects a target whose ancestor symlink redirects into a critical path" {
    # The deny list and the -L check both look at the literal string / leaf, so
    # a symlinked ANCESTOR used to slip through: the policy path looked like an
    # ordinary cache dir while rm followed the link into the real tree.
    local fake_caches="$TEST_DIR/redirected-Caches"
    ln -s /System "$fake_caches"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$fake_caches/Library/Caches/victim'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"resolves into a critical system path"* ]] || return 1
}

@test "validate_path_for_deletion rejects a target whose ancestor symlink redirects into protected user data" {
    local protected_home="$TEST_DIR/home"
    mkdir -p "$protected_home/Library/Keychains"
    local fake_cache_root="$TEST_DIR/cache-root"
    ln -s "$protected_home/Library" "$fake_cache_root"

    # should_protect_path is home-relative, so drive it against a fake HOME.
    run /bin/bash -c "export HOME='$protected_home'; source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$fake_cache_root/Keychains/login.keychain-db'"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion still accepts an ordinary path under a real directory" {
    # The ancestor guard is deny-only: it must not reject legitimate targets
    # whose ancestors merely resolve (e.g. /tmp -> /private/tmp on macOS).
    mkdir -p "$TEST_DIR/real/Caches"
    : > "$TEST_DIR/real/Caches/cache.db"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/real/Caches/cache.db'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion accepts valid path" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$TEST_DIR/valid'"
    [ "$status" -eq 0 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$HOME/Library/Caches/com.example.app/cache.db'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion rejects temp roots while allowing their children" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/tmp'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/tmp'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/folders'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/dev'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/tmp/mole-old-artifact'"
    [ "$status" -eq 0 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/tmp/mole-old-artifact'"
    [ "$status" -eq 0 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/folders/test/a/C/com.example.App/cache'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion rejects case aliases of critical roots" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        checked=0
        for pair in \
            '/SYSTEM|/System' \
            '/DEV|/dev' \
            '/PRIVATE/TMP|/private/tmp' \
            '/PRIVATE/VAR/FOLDERS|/private/var/folders' \
            '/USERS|/Users'; do
            alias_path=\${pair%%|*}
            canonical_path=\${pair#*|}
            if [[ -e \"\$alias_path\" && \"\$alias_path\" -ef \"\$canonical_path\" ]]; then
                checked=\$((checked + 1))
                validate_path_for_deletion \"\$alias_path\" && exit 90
            fi
        done
        [[ \$checked -gt 0 ]] || return 1
    "
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion accepts CoreSimulator system cache children" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Library/Developer/CoreSimulator/Caches/dyld'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion allows Darwin C cache shards but rejects protected extension paths" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/folders/test/a/C/com.example.App/com.apple.metal'"
    [ "$status" -eq 0 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/Library/Extensions/com.example.driver/com.apple.metal' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"critical system path"* ]]
}

@test "validate_path_for_deletion rejects endpoint-security agent var/folders caches" {
    # Central chokepoint: every safe_remove / safe_sudo_remove caller is covered,
    # not only the cleanup sweeps that pre-check the predicate.
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/folders/9d/abc/C/com.crowdstrike.falcon.App/com.apple.metalfe'"
    [ "$status" -eq 1 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/PRIVATE/VAR/FOLDERS/9D/ABC/C/COM.CROWDSTRIKE.FALCON.APP/com.apple.metalfe'"
    [ "$status" -eq 1 ]

    # A normal app's Darwin cache shard stays deletable.
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/folders/9d/abc/C/com.example.App/com.apple.metalfe'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion rejects the active powerlog database family" {
    local db="/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"
    local path=""

    for path in "$db" "$db-wal" "$db-shm" "${db%/*}/./${db##*/}" "${db%/*}/currentbackgroundprocessingdb.bgsql"; do
        run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$path'"
        [ "$status" -eq 1 ] || return 1
    done

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/ArchivedBackgroundProcessingDB.BGSQL'"
    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion refuses a live SQLite database family (#1390)" {
    local db="$TEST_DIR/live-sqlite/Cache.db"
    mkdir -p "$(dirname "$db")"
    printf 'db' > "$db"
    printf 'wal' > "$db-wal"
    printf 'shm' > "$db-shm"

    for path in "$db" "$db-wal" "$db-shm"; do
        run env PROJECT_ROOT="$PROJECT_ROOT" path="$path" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
lsof() { return 0; }
run_with_timeout() { shift; "$@"; }
validate_path_for_deletion "$path"
EOF
        [ "$status" -eq 1 ] || return 1
    done
}

@test "validate_path_for_deletion refuses an SQLite database held open by a process (#1390)" {
    local db="$TEST_DIR/open-sqlite/Cache.db"
    mkdir -p "$(dirname "$db")"
    printf 'db' > "$db"

    run env PROJECT_ROOT="$PROJECT_ROOT" db="$db" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
lsof() { return 0; }
run_with_timeout() { shift; "$@"; }
validate_path_for_deletion "$db"
EOF

    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion allows an idle SQLite cache database (#1390)" {
    local db="$TEST_DIR/idle-sqlite/Cache.db"
    mkdir -p "$(dirname "$db")"
    printf 'db' > "$db"

    run env PROJECT_ROOT="$PROJECT_ROOT" db="$db" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
validate_path_for_deletion "$db"
EOF

    [ "$status" -eq 0 ]
}

@test "validate_path_for_deletion allows stale SQLite -shm files (#1439)" {
    local db="$TEST_DIR/stale-sqlite/Cache.db"
    mkdir -p "$(dirname "$db")"
    printf 'db' > "$db"
    printf 'shm' > "$db-shm"

    for path in "$db" "$db-shm"; do
        run env PROJECT_ROOT="$PROJECT_ROOT" path="$path" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
validate_path_for_deletion "$path"
EOF
        [ "$status" -eq 0 ] || return 1
    done
}

@test "validate_path_for_deletion refuses a SQLite cache directory when lsof is inconclusive (#1439)" {
    local cache_dir="$HOME/Library/Caches/com.example.UnknownSQLite"
    local db="$cache_dir/Cache.db"
    mkdir -p "$cache_dir"
    printf 'db' > "$db"
    printf 'shm' > "$db-shm"

    run env PROJECT_ROOT="$PROJECT_ROOT" cache_dir="$cache_dir" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_user_cache_owner_process_state() { return 1; }
lsof() { return 1; }
run_with_timeout() { return 124; }
validate_path_for_deletion "$cache_dir"
EOF

    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion checks every supported SQLite name inside a cache directory (#1439)" {
    local filename=""
    for filename in state.sqlite state.sqlite3 STATE.SQLITE .hidden.sqlite; do
        local cache_dir="$HOME/Library/Caches/com.example.${filename//[^A-Za-z0-9]/_}"
        mkdir -p "$cache_dir"
        printf 'db' > "$cache_dir/$filename"

        run env PROJECT_ROOT="$PROJECT_ROOT" cache_dir="$cache_dir" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_user_cache_owner_process_state() { return 1; }
lsof() { return 0; }
run_with_timeout() { shift; "$@"; }
validate_path_for_deletion "$cache_dir"
EOF

        [ "$status" -eq 1 ] || return 1
    done
}

@test "SQLite cache directory guard isolates caller nullglob and failglob on Bash 3.2 (#1439)" {
    local cache_dir="$HOME/Library/Caches/com.example.EmptySQLite"
    mkdir -p "$cache_dir"

    run env PROJECT_ROOT="$PROJECT_ROOT" cache_dir="$cache_dir" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_user_cache_owner_process_state() { return 1; }
shopt -s nullglob failglob
validate_path_for_deletion "$cache_dir"
shopt -q nullglob
shopt -q failglob
EOF

    [ "$status" -eq 0 ]
}

@test "SQLite cache directory guard ignores and restores caller GLOBIGNORE (#1439)" {
    local cache_dir="$HOME/Library/Caches/com.example.GlobIgnoreSQLite"
    mkdir -p "$cache_dir"
    printf 'db' > "$cache_dir/state.db"

    run env PROJECT_ROOT="$PROJECT_ROOT" cache_dir="$cache_dir" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_user_cache_owner_process_state() { return 1; }
lsof() { return 0; }
run_with_timeout() { shift; "$@"; }
export GLOBIGNORE='*.db'
validation_state=0
validate_path_for_deletion "$cache_dir" || validation_state=$?
[[ $validation_state -eq 1 ]]
[[ "$GLOBIGNORE" == '*.db' ]]
[[ "$(declare -p GLOBIGNORE)" == 'declare -x GLOBIGNORE='* ]]
shopt -q dotglob
EOF

    [ "$status" -eq 0 ]
}

@test "SQLite cache directory guard probes each database family once (#1439)" {
    local cache_dir="$HOME/Library/Caches/com.example.OneSQLiteFamily"
    local db="$cache_dir/Cache.db"
    mkdir -p "$cache_dir"
    printf 'db' > "$db"
    printf 'wal' > "$db-wal"
    printf 'shm' > "$db-shm"

    run env PROJECT_ROOT="$PROJECT_ROOT" cache_dir="$cache_dir" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_user_cache_owner_process_state() { return 1; }
lsof_calls=0
lsof() { lsof_calls=$((lsof_calls + 1)); return 1; }
run_with_timeout() { shift; "$@"; }
guard_state=0
_mole_should_refuse_live_user_cache_path "$cache_dir" || guard_state=$?
[[ $guard_state -eq 1 ]]
[[ $lsof_calls -eq 3 ]]
EOF

    [ "$status" -eq 0 ]
}

@test "should_protect_path applies high-risk cleanup denylist" {
    run /bin/bash -c "
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

@test "is_endpoint_security_cache_path matches only EDR agent var/folders caches" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# Deleting anything an EDR agent owns under the per-user Darwin folder trips
# sensor tamper detection (CrowdStrike MacFalconSensorTamper, MITRE T1562.001).
# The matcher covers the vendor bundle id anywhere under var/folders: the C/
# shader cache that triggered the real corporate alert, the X/ code-signature
# clone, and T/ temp. Protection-only, so a wide match within var/folders is
# intentional.
is_endpoint_security_cache_path "/private/var/folders/9d/abc123/C/com.crowdstrike.falcon.App/com.apple.metalfe"
is_endpoint_security_cache_path "/private/var/folders/9d/abc123/X/com.crowdstrike.falcon.App.code_sign_clone"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/T/com.crowdstrike.falcon.App/scratch"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.sentinelone.agent/com.apple.metal"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.jamf.management/com.apple.gpuarchiver"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.paloaltonetworks.GlobalProtect/com.apple.metalfe"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.eset.endpoint/com.apple.metal"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.sentinel-labs.agent/com.apple.metalfe"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.jamfsoftware.selfservice/com.apple.gpuarchiver"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/X/com.cisco.anyconnect.gui.code_sign_clone"
is_endpoint_security_cache_path "/private/var/folders/aa/bb/X/com.cisco.secureclient.gui.code_sign_clone"
# A normal third-party app's cache is not an EDR cache.
! is_endpoint_security_cache_path "/private/var/folders/aa/bb/C/com.example.App/com.apple.metalfe"
# Non-security Cisco products (e.g. Webex) are not matched; only the secure-access clients are.
! is_endpoint_security_cache_path "/private/var/folders/aa/bb/X/com.cisco.webex.code_sign_clone"
# Paths outside var/folders are out of scope for this predicate.
! is_endpoint_security_cache_path "/Applications/Falcon.app"
# A non-Darwin path that merely contains "var/folders" must NOT match (anchored).
! is_endpoint_security_cache_path "/Users/me/project/var/folders/com.crowdstrike.fixture/cache"
EOF

    [ "$status" -eq 0 ]
}

@test "should_protect_path protects endpoint-security / EDR agent caches (CrowdStrike Falcon tamper)" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# Matched by the dedicated EDR predicate before any bundle/filename fallback,
# so the result is deterministic regardless of nounset/source order.
should_protect_path "/private/var/folders/9d/abc123/C/com.crowdstrike.falcon.App/com.apple.metalfe"
should_protect_path "/private/var/folders/aa/bb/C/com.sentinelone.agent/com.apple.metal"
EOF

    [ "$status" -eq 0 ]
}

@test "should_protect_path protects OrbStack live container data" {
    local orb_group_data="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw"
    local orb_state="$HOME/.orbstack/state.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ORB_GROUP_DATA="$orb_group_data" ORB_STATE="$orb_state" /bin/bash --noprofile --norc <<'EOF'
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
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '/System/test' 2>&1"
    [ "$status" -eq 1 ]
}

@test "validate_path_for_deletion rejects symlink to protected system path" {
    local link_path="$TEST_DIR/system-link"
    ln -s "/System" "$link_path"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; validate_path_for_deletion '$link_path' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"protected system path"* ]]
}

@test "safe_remove silent mode hides protected symlink validation warning" {
    local link_path="$TEST_DIR/silent-system-link"
    ln -s "/System" "$link_path"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$link_path' true 2>&1"
    [ "$status" -eq 1 ]
    [[ -L "$link_path" ]] || return 1
    [[ "$output" != *"Symlink points to protected system path"* ]]
}

@test "safe_remove successfully removes file" {
    local test_file="$TEST_DIR/test_file.txt"
    echo "test" > "$test_file"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$test_file' true"
    [ "$status" -eq 0 ]
    [ ! -f "$test_file" ]
}

@test "safe_remove successfully removes directory" {
    local test_subdir="$TEST_DIR/test_subdir"
    mkdir -p "$test_subdir"
    touch "$test_subdir/file.txt"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$test_subdir' true"
    [ "$status" -eq 0 ]
    [ ! -d "$test_subdir" ]
}

@test "safe_remove handles non-existent path gracefully" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '$TEST_DIR/nonexistent' true"
    [ "$status" -eq 0 ]
}

@test "safe_remove preserves interrupt exit codes" {
    local test_file="$TEST_DIR/interrupt_file"
    echo "test" > "$test_file"

    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        rm() { return 130; }
        safe_remove '$test_file' true
    "
    [ "$status" -eq 130 ]
    [ -f "$test_file" ]
}

@test "safe_remove bounds a stalled external rm" {
    local target_file="$TEST_DIR/stalled-rm-file"
    local mock_bin="$TEST_DIR/stalled-rm-bin"
    local trace="$TEST_DIR/stalled-rm.trace"
    mkdir -p "$mock_bin"
    touch "$target_file"

    cat > "$mock_bin/rm" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"$TARGET_FILE"* ]]; then
    printf 'rm %s\n' "$*" >> "$MOLE_RM_TRACE"
    exec sleep 4
fi
exec /bin/rm "$@"
MOCK
    chmod +x "$mock_bin/rm"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_FILE="$target_file" \
        PATH="$mock_bin:$PATH" MOLE_RM_TRACE="$trace" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
get_path_size_kb() { echo 1; }
started=$(date +%s)
rc=0
safe_remove "$TARGET_FILE" true || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'RC=%s\nELAPSED=%s\n' "$rc" "$elapsed"
SCRIPT

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$(< "$trace")" == *"$target_file"* ]] || return 1
    local elapsed="${output##*ELAPSED=}"
    [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
    [ "$elapsed" -lt 3 ]
    [ -e "$target_file" ]
}

@test "safe_remove refuses a compiled model cache created during size probing" {
    local target_dir="$TEST_DIR/compiled-model-race"
    mkdir -p "$target_dir"
    touch "$target_dir/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
oplog_enabled() { return 0; }
get_path_size_kb() {
    mkdir -p "$1/com.apple.e5rt.e5bundlecache"
    echo 1
}
rm() { echo "UNEXPECTED_REMOVE:$*"; return 99; }
safe_remove "$TARGET_DIR" true && rc=0 || rc=$?
printf 'RC=%s\n' "$rc"
[[ -d "$TARGET_DIR/com.apple.e5rt.e5bundlecache" ]]
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "safe_remove dry-run refuses an existing compiled model cache" {
    local target_dir="$TEST_DIR/compiled-model-dry-run"
    mkdir -p "$target_dir/com.apple.e5rt.e5bundlecache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
MOLE_DRY_RUN=1
record_dry_run_cleanup_target() { echo "UNEXPECTED_REGISTER:$1"; }
safe_remove "$TARGET_DIR" true && rc=0 || rc=$?
printf 'RC=%s\n' "$rc"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REGISTER"* ]]
}

@test "safe_remove in silent mode suppresses error output" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_remove '/System/test' true 2>&1"
    [ "$status" -eq 1 ]
}


@test "safe_find_delete validates base directory" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '/nonexistent' '*.tmp' 7 'f' 2>&1"
    [ "$status" -eq 1 ]
}

@test "safe_sudo_remove refuses symlink paths" {
    local target_dir="$TEST_DIR/real"
    local link_dir="$TEST_DIR/link"
    mkdir -p "$target_dir"
    ln -s "$target_dir" "$link_dir"

    run /bin/bash -c "
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# This test models a root-owned, immutable system path so it reaches the
# noninteractive sudo authentication branch.
_mole_privileged_path_has_mutable_ancestor() { return 1; }

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
[[ ! -e "$TARGET_DIR" ]] || exit 1
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" != *"INTERACTIVE_SUDO"* ]]
}

@test "safe_sudo_remove bounds a stalled external sudo rm" {
    local target_dir="$TEST_DIR/stalled-sudo-rm-target"
    local mock_bin="$TEST_DIR/stalled-sudo-rm-bin"
    local trace="$TEST_DIR/stalled-sudo-rm.trace"
    mkdir -p "$target_dir" "$mock_bin"
    touch "$target_dir/data"

    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
set -u
[[ "${1:-}" == "-n" ]] && shift
case "${1:-}" in
    rm)
        printf 'sudo-rm %s\n' "$*" >> "$MOLE_SUDO_RM_TRACE"
        exec sleep 4
        ;;
    *)
        exit 99
        ;;
esac
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        PATH="$mock_bin:$PATH" MOLE_SUDO_RM_TRACE="$trace" \
        MOLE_TIMEOUT_DISK_VERIFY_SEC=1 MO_NO_OPLOG=1 \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
started=$(date +%s)
rc=0
safe_sudo_remove "$TARGET_DIR" || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'RC=%s\nELAPSED=%s\n' "$rc" "$elapsed"
SCRIPT

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$(< "$trace")" == *"sudo-rm rm -rf $target_dir"* ]] || return 1
    local elapsed="${output##*ELAPSED=}"
    [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
    [ "$elapsed" -lt 3 ]
    [ -e "$target_dir/data" ]
}

@test "safe_sudo_remove refuses a compiled model cache created during size probing" {
    local target_dir="$TEST_DIR/compiled-model-sudo-race"
    mkdir -p "$target_dir"
    touch "$target_dir/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
oplog_enabled() { return 0; }
sudo() {
    if [[ "${1:-}" == "-n" && "${2:-}" == "test" ]]; then
        shift 2
        command test "$@"
        return $?
    fi
    if [[ "${1:-}" == "-n" && "${2:-}" == "du" ]]; then
        mkdir -p "$TARGET_DIR/com.apple.e5rt.e5bundlecache"
        printf '1 %s\n' "$TARGET_DIR"
        return 0
    fi
    echo "UNEXPECTED_SUDO:$*"
    return 99
}
safe_sudo_remove "$TARGET_DIR" && rc=0 || rc=$?
printf 'RC=%s\n' "$rc"
[[ -d "$TARGET_DIR/com.apple.e5rt.e5bundlecache" ]]
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=13"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SUDO"* ]]
}

@test "safe_sudo_remove dry-run refuses an existing compiled model cache" {
    local target_dir="$TEST_DIR/compiled-model-sudo-dry-run"
    mkdir -p "$target_dir/com.apple.e5rt.e5bundlecache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
MOLE_DRY_RUN=1
_mole_privileged_path_has_mutable_ancestor() { return 1; }
record_dry_run_cleanup_target() { echo "UNEXPECTED_REGISTER:$1"; }
safe_sudo_remove "$TARGET_DIR" && rc=0 || rc=$?
printf 'RC=%s\n' "$rc"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=13"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REGISTER"* ]]
}

@test "safe_sudo_remove returns auth failure when noninteractive sudo expires" {
    local target_dir="$TEST_DIR/sudo-expired"
    mkdir -p "$target_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# This test models a root-owned, immutable system path so it reaches the
# noninteractive sudo authentication branch.
_mole_privileged_path_has_mutable_ancestor() { return 1; }

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
[[ -e "$TARGET_DIR" ]] || exit 1
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=11"* ]] || return 1
    [[ "$output" != *"INTERACTIVE_SUDO"* ]]
}

@test "safe_sudo_remove returns protected-path code for safety skips" {
    local target_dir="/private/var/folders/9d/abc/C/com.crowdstrike.falcon.App/com.apple.metalfe"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

safe_sudo_remove "$TARGET_DIR" && rc=0 || rc=$?
echo "RC=$rc"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=13"* ]]
}

@test "safe_sudo_find_delete never opens an interactive sudo prompt" {
    local target_dir="$TEST_DIR/sudo-find-target"
    local script="$TEST_DIR/sudo-find-delete-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/old.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
TRACE="${TARGET_DIR}.sudo.trace"
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]] || return 1
    [[ "$output" == *"SUDO:-n test -d "* ]] || return 1
    [[ "$output" == *"SUDO:-n test -L "* ]] || return 1
    [[ "$output" == *"SUDO:-n find "* ]] || return 1
    [[ "$output" != *"INTERACTIVE_SUDO"* ]]
}

@test "safe_sudo_find_delete bounds a stalled sudo find" {
    local target_dir="$TEST_DIR/sudo-find-timeout-target"
    local mock_bin="$TEST_DIR/sudo-find-timeout-bin"
    local trace="$TEST_DIR/sudo-find-timeout.trace"
    mkdir -p "$target_dir" "$mock_bin"

    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
set -u
[[ "${1:-}" == "-n" ]] && shift
case "${1:-}" in
    true)
        exit 0
        ;;
    test)
        shift
        /bin/test "$@"
        ;;
    find)
        shift
        printf 'find %s\n' "$*" >> "$MOLE_SUDO_FIND_TRACE"
        exec sleep 4
        ;;
    *)
        exit 99
        ;;
esac
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        PATH="$mock_bin:$PATH" MOLE_SUDO_FIND_TRACE="$trace" \
        MOLE_TIMEOUT_DISK_VERIFY_SEC=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
started=$(date +%s)
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'RC=%s\n' "$rc"
printf 'ELAPSED=%s\n' "$elapsed"
SCRIPT

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [ -f "$trace" ] || return 1
    local trace_content
    trace_content=$(< "$trace")
    [[ "$trace_content" == "find $target_dir -maxdepth 1 -name *.log -type f -print0" ]] || {
        echo "TRACE=$trace_content"
        return 1
    }
    [[ "$output" == *"ELAPSED="* ]] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    local elapsed="${output##*ELAPSED=}"
    [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
    [ "$elapsed" -lt 3 ]
}

@test "safe_sudo_find_delete discards partial output when sudo find times out" {
    local target_dir="$TEST_DIR/sudo-find-partial-timeout-target"
    local mock_bin="$TEST_DIR/sudo-find-partial-timeout-bin"
    local trace="$TEST_DIR/sudo-find-partial-timeout.trace"
    mkdir -p "$target_dir" "$mock_bin"
    touch "$target_dir/old.log"

    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$MOLE_SUDO_FIND_TRACE"
[[ "${1:-}" == "-n" ]] && shift
case "${1:-}" in
    test)
        shift
        /bin/test "$@"
        ;;
    true)
        exit 0
        ;;
    find)
        printf '%s\0' "$TARGET_DIR/old.log"
        exec sleep 4
        ;;
    xargs | rm)
        printf 'UNEXPECTED_DELETE:%s\n' "$*" >> "$MOLE_SUDO_FIND_TRACE"
        exit 99
        ;;
    *)
        exit 99
        ;;
esac
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        PATH="$mock_bin:$PATH" MOLE_SUDO_FIND_TRACE="$trace" \
        MOLE_TIMEOUT_DISK_VERIFY_SEC=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
printf 'RC=%s\n' "$rc"
SCRIPT

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]] || return 1
    local trace_content
    trace_content=$(< "$trace")
    [[ "$trace_content" == *"-n find $target_dir -maxdepth 1 -name *.log -type f -print0"* ]] || return 1
    [[ "$trace_content" != *"UNEXPECTED_DELETE"* ]] || return 1
    [[ -e "$target_dir/old.log" ]]
}

@test "safe_sudo_find_delete bounds a stalled sudo batch removal" {
    local target_dir="$TEST_DIR/sudo-batch-timeout-target"
    local mock_bin="$TEST_DIR/sudo-batch-timeout-bin"
    local trace="$TEST_DIR/sudo-batch-timeout.trace"
    mkdir -p "$target_dir" "$mock_bin"
    touch "$target_dir/old.log"

    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
set -u
[[ "${1:-}" == "-n" ]] && shift
case "${1:-}" in
    test)
        shift
        /bin/test "$@"
        ;;
    true)
        exit 0
        ;;
    find)
        printf '%s\0' "$TARGET_DIR/old.log"
        ;;
    */stat)
        exec "$@"
        ;;
    xargs)
        printf 'xargs %s\n' "$*" >> "$MOLE_SUDO_BATCH_TRACE"
        exec sleep 30
        ;;
    *)
        exit 99
        ;;
esac
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        PATH="$mock_bin:$PATH" MOLE_SUDO_BATCH_TRACE="$trace" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
started=$(date +%s)
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'RC=%s\nELAPSED=%s\n' "$rc" "$elapsed"
SCRIPT

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$(< "$trace")" == *"xargs xargs -0 /bin/sh -c"* ]] || return 1
    local elapsed="${output##*ELAPSED=}"
    [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
    [ "$elapsed" -lt 10 ]
}

@test "safe_sudo_find_delete stops before scanning when its deadline is exhausted" {
    local target_dir="$TEST_DIR/sudo-deadline-target"
    mkdir -p "$target_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
sudo() {
    printf 'SUDO:%s\n' "$*"
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test)
            shift
            command test "$@"
            ;;
        find | xargs)
            printf 'UNEXPECTED_WORK:%s\n' "$*"
            return 99
            ;;
        *) "$@" ;;
    esac
}
deadline=$SECONDS
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" "$deadline" || rc=$?
printf 'RC=%s\nCOUNT=%s\n' "$rc" "${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-unset}"
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$output" == *"COUNT=0"* ]] || return 1
    [[ "$output" != *"SUDO:"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_WORK"* ]]
}

@test "_mole_timeout_with_deadline clamps fractional timeouts to remaining whole seconds" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
# `remaining` is `deadline - SECONDS`, and SECONDS keeps ticking in real
# time, so one shared `SECONDS=100` before four forks means the last call
# sees a smaller window than the first. On a slow runner the window reached
# zero, the helper returned 124 with no output, and the case failed for
# reasons that had nothing to do with clamping. Re-pin the clock per call.
SECONDS=100
printf 'CLAMPED=%s\n' "$(_mole_timeout_with_deadline 30.5 101)"
SECONDS=100
printf 'SHORT=%s\n' "$(_mole_timeout_with_deadline 0.5 101)"
SECONDS=100
printf 'ZERO=%s\n' "$(_mole_timeout_with_deadline 0 101)"
SECONDS=100
printf 'LEADING=%s\n' "$(_mole_timeout_with_deadline 08.5 101)"
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CLAMPED=1"* ]] || return 1
    [[ "$output" == *"SHORT=0.5"* ]] || return 1
    [[ "$output" == *"ZERO=1"* ]] || return 1
    [[ "$output" == *"LEADING=1"* ]]
}

@test "get_path_size_kb bounds the app metadata fast path" {
    local app_dir="$TEST_DIR/Stalled.app"
    local mock_bin="$TEST_DIR/stalled-mdls-bin"
    local trace="$TEST_DIR/stalled-mdls.trace"
    mkdir -p "$app_dir" "$mock_bin"

    cat > "$mock_bin/mdls" <<'MOCK'
#!/bin/bash
printf 'mdls %s\n' "$*" >> "$MOLE_MDLS_TRACE"
exec sleep 4
MOCK
    chmod +x "$mock_bin/mdls"
    cat > "$mock_bin/du" <<'MOCK'
#!/bin/bash
printf 'UNEXPECTED_DU %s\n' "$*" >> "$MOLE_MDLS_TRACE"
exec sleep 4
MOCK
    chmod +x "$mock_bin/du"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_DIR="$app_dir" \
        PATH="$mock_bin:$PATH" MOLE_MDLS_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
started=$(date +%s)
set +e
# Budget must be >= 2s. SECONDS has whole-second granularity, so a 1s budget
# is really "until the next second boundary" and can collapse to nearly zero,
# returning 124 before mdls is ever spawned. Two seconds always leaves at
# least a full second for the probe, which is what this case asserts on.
size=$(get_path_size_kb "$APP_DIR" 2)
size_rc=$?
set -e
elapsed=$(( $(date +%s) - started ))
printf 'SIZE=%s\nRC=%s\nELAPSED=%s\n' "$size" "$size_rc" "$elapsed"
[[ $size_rc -eq 124 ]]
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SIZE="* ]] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$(< "$trace")" == *"$app_dir"* ]] || return 1
    [[ "$(< "$trace")" != *"UNEXPECTED_DU"* ]] || return 1
    local elapsed="${output##*ELAPSED=}"
    [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
    [ "$elapsed" -lt 4 ]
}

@test "safe_remove stops when a size probe is interrupted" {
    local app_dir="$TEST_DIR/Interrupted.app"
    mkdir -p "$app_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_DIR="$app_dir" \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "${1:-}" == "mdls" ]]; then
        return 130
    fi
    "$@"
}
rm() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$*"
    return 99
}
rc=0
safe_remove "$APP_DIR" true || rc=$?
printf 'RC=%s\n' "$rc"
[[ -d "$APP_DIR" ]]
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "safe_sudo_find_delete propagates interrupts from every sudo preflight" {
    local target_dir="$TEST_DIR/sudo-preflight-interrupt-target"
    mkdir -p "$target_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

for fail_stage in initial_auth base base_auth link link_auth; do
    true_calls=0
    sudo() {
        [[ "${1:-}" == "-n" ]] && shift
        case "${1:-}" in
            true)
                true_calls=$((true_calls + 1))
                if [[ "$fail_stage" == "initial_auth" && $true_calls -eq 1 ]] || \
                    [[ "$fail_stage" == "base_auth" && $true_calls -eq 2 ]] || \
                    [[ "$fail_stage" == "link_auth" && $true_calls -eq 2 ]]; then
                    return 130
                fi
                return 0
                ;;
            test)
                shift
                if [[ "${1:-}" == "-d" ]]; then
                    [[ "$fail_stage" == "base" ]] && return 130
                    [[ "$fail_stage" == "base_auth" ]] && return 1
                elif [[ "${1:-}" == "-L" ]]; then
                    [[ "$fail_stage" == "link" ]] && return 130
                    [[ "$fail_stage" == "link_auth" ]] && return 1
                fi
                command test "$@"
                ;;
            find | xargs | rm)
                printf 'UNEXPECTED_PRIVILEGED_ACTION:%s\n' "$*"
                return 99
                ;;
            *) return 0 ;;
        esac
    }

    rc=0
    safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" || rc=$?
    printf '%s:%s\n' "$fail_stage" "$rc"
done
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"initial_auth:130"* ]] || return 1
    [[ "$output" == *"base:130"* ]] || return 1
    [[ "$output" == *"base_auth:130"* ]] || return 1
    [[ "$output" == *"link:130"* ]] || return 1
    [[ "$output" == *"link_auth:130"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_PRIVILEGED_ACTION"* ]]
}

@test "safe_sudo_find_delete keeps a file refreshed after the initial age scan" {
    local target_dir="$TEST_DIR/sudo-age-refresh-target"
    local target_file="$target_dir/old.log"
    mkdir -p "$target_dir"
    touch "$target_file"
    touch -t "$(date -v-8d '+%Y%m%d%H%M.%S')" "$target_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" TARGET_FILE="$target_file" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test)
            shift
            command test "$@"
            ;;
        find)
            printf '%s\0' "$TARGET_FILE"
            touch "$TARGET_FILE"
            ;;
        */stat) "$@" ;;
        xargs)
            shift
            command xargs "$@"
            ;;
        *) "$@" ;;
    esac
}
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "1" "f" "1" || rc=$?
printf 'RC=%s\nCOUNT=%s\n' "$rc" "${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-unset}"
[[ -e "$TARGET_FILE" ]] && printf 'SURVIVED\n'
cat "$HOME/Library/Logs/mole/operations.log" 2> /dev/null || true
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"COUNT=0"* ]] || return 1
    [[ "$output" == *"SURVIVED"* ]] || return 1
    [[ "$output" != *"REMOVED $target_file"* ]]
}

@test "safe_sudo_find_delete keeps a path replaced after identity capture" {
    local target_dir="$TEST_DIR/sudo-identity-replace-target"
    local target_file="$target_dir/old.log"
    mkdir -p "$target_dir"
    printf 'original\n' > "$target_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" TARGET_FILE="$target_file" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test)
            shift
            command test "$@"
            ;;
        find) printf '%s\0' "$TARGET_FILE" ;;
        */stat)
            identity=$("$@")
            if [[ ! -e "$TARGET_DIR/replaced.marker" ]]; then
                : > "$TARGET_DIR/replaced.marker"
                /bin/rm -f "$TARGET_FILE"
                printf 'replacement\n' > "$TARGET_FILE"
            fi
            printf '%s\n' "$identity"
            ;;
        xargs)
            shift
            command xargs "$@"
            ;;
        *) "$@" ;;
    esac
}
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
printf 'RC=%s\nCOUNT=%s\nCONTENT=%s\n' "$rc" \
    "${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-unset}" "$(< "$TARGET_FILE")"
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"COUNT=0"* ]] || return 1
    [[ "$output" == *"CONTENT=replacement"* ]]
}

@test "safe_sudo_find_delete does not run an accumulated batch after a probe timeout" {
    local target_dir="$TEST_DIR/sudo-probe-timeout-target"
    local first_file="$target_dir/first.log"
    local second_file="$target_dir/second.log"
    local marker="$target_dir/first-stat-complete"
    mkdir -p "$target_dir"
    touch "$first_file" "$second_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        FIRST_FILE="$first_file" SECOND_FILE="$second_file" MARKER="$marker" \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
MOLE_TEST_MODE=0
MOLE_TEST_NO_AUTH=0
_mole_privileged_path_has_mutable_ancestor() { return 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test) command "$@" ;;
        find) printf '%s\0%s\0' "$FIRST_FILE" "$SECOND_FILE" ;;
        /usr/bin/stat)
            if [[ ! -e "$MARKER" ]]; then
                touch "$MARKER"
                command "$@"
            else
                printf 'STAT_TIMEOUT\n'
                return 124
            fi
            ;;
        xargs)
            printf 'UNEXPECTED_BATCH\n'
            return 99
            ;;
        *) command "$@" ;;
    esac
}

rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
printf 'RC=%s\n' "$rc"
[[ -e "$FIRST_FILE" && -e "$SECOND_FILE" ]]
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [ -e "$marker" ] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_BATCH"* ]]
}

@test "safe_sudo_find_delete logs only acknowledged removals from a timed-out batch" {
    local target_dir="$TEST_DIR/sudo-partial-ack-target"
    local mock_bin="$TEST_DIR/sudo-partial-ack-bin"
    local trace="$TEST_DIR/sudo-partial-ack.trace"
    mkdir -p "$target_dir" "$mock_bin"
    touch "$target_dir/a.log" "$target_dir/b.log"

    cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
set -u
[[ "${1:-}" == "-n" ]] && shift
case "${1:-}" in
    true) exit 0 ;;
    test)
        shift
        /bin/test "$@"
        ;;
    find)
        printf '%s\0' "$TARGET_DIR/a.log" "$TARGET_DIR/b.log"
        ;;
    */stat) exec "$@" ;;
    xargs)
        printf 'xargs-started\n' >> "$MOLE_PARTIAL_ACK_TRACE"
        IFS= read -r -d '' record || exit 1
        rest=${record#*:}
        rest=${rest#*:}
        path=${rest#*:}
        /bin/rm -f -- "$path" || exit 1
        printf '%s\0' "$path"
        exec sleep 4
        ;;
    *) exit 99 ;;
esac
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        PATH="$mock_bin:$PATH" MOLE_PARTIAL_ACK_TRACE="$trace" \
        MOLE_TIMEOUT_DISK_VERIFY_SEC=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
printf 'RC=%s\nCOUNT=%s\n' "$rc" "${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-unset}"
cat "$HOME/Library/Logs/mole/operations.log" 2> /dev/null || true
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$(< "$trace")" == "xargs-started" ]] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$output" == *"COUNT=1"* ]] || return 1
    [ ! -e "$target_dir/a.log" ] || return 1
    [ -e "$target_dir/b.log" ] || return 1
    [[ "$output" == *"REMOVED $target_dir/a.log (batch)"* ]] || return 1
    [[ "$output" != *"REMOVED $target_dir/b.log (batch)"* ]]
}

@test "safe_sudo_find_delete rejects an oversized privileged batch before deletion" {
    local target_dir="$TEST_DIR/sudo-batch-limit-target"
    mkdir -p "$target_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MO_NO_OPLOG=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
_mole_privileged_batch_max_items() { printf '4\n'; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test)
            shift
            command test "$@"
            ;;
        find)
            i=0
            while [[ $i -lt 5 ]]; do
                printf '%s\0' "$TARGET_DIR/item-$i.log"
                i=$((i + 1))
            done
            ;;
        */stat) printf '1:2:3\n' ;;
        xargs)
            printf 'UNEXPECTED_BATCH:%s\n' "$*"
            return 99
            ;;
        *) "$@" ;;
    esac
}
rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" "1" || rc=$?
printf 'RC=%s\nCOUNT=%s\n' "$rc" "${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-unset}"
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"COUNT=0"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_BATCH"* ]]
}

@test "safe_sudo_find_delete never previews or removes active powerlog database aliases" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

active_db="/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"
active_dot_alias="${active_db%/*}/./${active_db##*/}"
active_case_alias="${active_db%/*}/currentbackgroundprocessingdb.bgsql"
archived_db="/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/ArchivedBackgroundProcessingDB.BGSQL"

should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
_mole_privileged_path_has_mutable_ancestor() { return 1; }
record_dry_run_cleanup_target() { printf 'PREVIEW:%s\n' "$1"; }
safe_sudo_remove() { printf 'REMOVE:%s\n' "$1"; }
append_log_lines() {
    shift
    printf '%s\n' "$@"
}

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        test)
            [[ "${2:-}" == "-d" ]]
            ;;
        find)
            printf '%s\0' "$active_db" "$active_db-wal" "$active_db-shm" "$active_dot_alias" "$active_case_alias" "$archived_db"
            ;;
        */stat)
            printf '1:2:3\n'
            ;;
        xargs)
            while IFS= read -r -d '' record; do
                rest=${record#*:}
                rest=${rest#*:}
                rest=${rest#*:}
                printf '%s\0' "$rest"
            done
            ;;
        *)
            return 0
            ;;
    esac
}

MOLE_DRY_RUN=1
safe_sudo_find_delete "/private/var/db/powerlog" "*" "7" "f"
MOLE_DRY_RUN=0
safe_sudo_find_delete "/private/var/db/powerlog/." "*" "7" "f"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"PREVIEW:/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/ArchivedBackgroundProcessingDB.BGSQL"* ]] || return 1
    [[ "$output" == *"REMOVED /private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/ArchivedBackgroundProcessingDB.BGSQL (batch)"* ]] || return 1
    [[ "$output" != *"CurrentBackgroundProcessingDB.BGSQL"* ]] || return 1
    [[ "$output" != *"currentbackgroundprocessingdb.bgsql"* ]] || return 1
    [[ "$output" != *"/./CurrentBackgroundProcessingDB.BGSQL"* ]]
}

@test "safe_sudo_find_delete batches file removals into one xargs rm" {
    local target_dir="$TEST_DIR/sudo-batch-target"
    local script="$TEST_DIR/sudo-batch-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/a.log" "$target_dir/b.log" "$target_dir/keep.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
TRACE="$TARGET_DIR/sudo.trace"
> "$TRACE"

# This test models a root-owned, non-user-writable log tree.
_mole_privileged_path_has_mutable_ancestor() { return 1; }

WHITELIST_PATTERNS=("$TARGET_DIR/keep.log")

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
            printf '%s\0' "$TARGET_DIR/a.log" "$TARGET_DIR/b.log" "$TARGET_DIR/keep.log"
            ;;
        xargs)
            shift
            command xargs "$@"
            ;;
        rm)
            echo "SINGLE_FILE_RM:$*"
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
[[ -e "$TARGET_DIR/a.log" ]] && echo "A_SURVIVED" || echo "A_REMOVED"
[[ -e "$TARGET_DIR/b.log" ]] && echo "B_SURVIVED" || echo "B_REMOVED"
[[ -e "$TARGET_DIR/keep.log" ]] && echo "KEEP_SURVIVED" || echo "KEEP_REMOVED"
printf 'XARGS_CALLS=%s\n' "$(grep -c 'SUDO:-n xargs' "$TRACE" || true)"
cat "$TRACE"
echo "--OPLOG--"
cat "$HOME/Library/Logs/mole/operations.log" 2> /dev/null || true
exit 0
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]] || return 1
    [[ "$output" == *"A_REMOVED"* ]] || return 1
    [[ "$output" == *"B_REMOVED"* ]] || return 1
    [[ "$output" == *"KEEP_SURVIVED"* ]] || return 1
    [[ "$output" == *"XARGS_CALLS=1"* ]] || return 1
    [[ "$output" != *"SINGLE_FILE_RM"* ]] || return 1
    [[ "$output" == *"REMOVED $target_dir/a.log (batch)"* ]] || return 1
    [[ "$output" == *"REMOVED $target_dir/b.log (batch)"* ]] || return 1
    [[ "$output" != *"INTERACTIVE_SUDO"* ]] || return 1
}

@test "safe_sudo_find_delete reports a failed batch without logging REMOVED" {
    local target_dir="$TEST_DIR/sudo-batch-lapsed"
    local script="$TEST_DIR/sudo-batch-lapsed-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/a.log" "$target_dir/b.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# This test models a root-owned, non-user-writable log tree.
_mole_privileged_path_has_mutable_ancestor() { return 1; }

# Simulate a credential that dies at the batch xargs rm. Nothing was deleted,
# so the helper must return the failure and no REMOVED lines may be logged.
sudo() {
    if [[ "${1:-}" != "-n" ]]; then
        echo "INTERACTIVE_SUDO:$*" >&2
        return 99
    fi
    shift
    case "${1:-}" in
        true)
            return 0
            ;;
        test)
            shift
            command test "$@"
            ;;
        find)
            printf '%s\0' "$TARGET_DIR/a.log" "$TARGET_DIR/b.log"
            ;;
        xargs)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}
export -f sudo

set +e
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f"
rc=$?
set -e
printf 'RC=%s\n' "$rc"
[[ -e "$TARGET_DIR/a.log" ]] && echo "A_SURVIVED" || echo "A_REMOVED"
echo "--OPLOG--"
cat "$HOME/Library/Logs/mole/operations.log" 2> /dev/null || true
exit 0
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"A_SURVIVED"* ]] || return 1
    # Scope to this test's paths: the oplog HOME is shared across tests and
    # earlier batch tests legitimately log their own "(batch)" lines.
    [[ "$output" != *"REMOVED $target_dir/a.log (batch)"* ]] || return 1
    [[ "$output" != *"REMOVED $target_dir/b.log (batch)"* ]] || return 1
    [[ "$output" != *"INTERACTIVE_SUDO"* ]] || return 1
}

@test "safe_sudo_find_delete batch path survives set -e with oplog disabled" {
    local target_dir="$TEST_DIR/sudo-batch-nooplog"
    local script="$TEST_DIR/sudo-batch-nooplog-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/a.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
# Diagnostic breadcrumbs: this test fails only on some CI images, so record
# which bash runs the script and every mock invocation on a side channel.
printf 'DIAG_BASH:%s (%s)\n' "$BASH_VERSION" "$(command -v bash || true)"
source "$PROJECT_ROOT/lib/core/common.sh"
echo "DIAG_SOURCED"

# This test models a root-owned, non-user-writable log tree.
_mole_privileged_path_has_mutable_ancestor() { return 1; }

sudo() {
    printf 'MOCK_CALL:%s\n' "$*" >> "$TARGET_DIR/mock.trace" || true
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
            printf '%s\0' "$TARGET_DIR/a.log"
            ;;
        xargs)
            shift
            command xargs "$@"
            ;;
        *)
            "$@"
            ;;
    esac
}
export -f sudo

echo "DIAG_MOCK_READY"
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f"
# Reaching this line proves the disabled-oplog branch did not trip set -e.
echo "SURVIVED_SET_E"
[[ -e "$TARGET_DIR/a.log" ]] && echo "A_SURVIVED" || echo "A_REMOVED"
exit 0
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MO_NO_OPLOG=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"

    # This test is environment-sensitive (errexit active during the call); on
    # failure surface the exit status, captured output, and an xtrace replay
    # so CI logs show where the inner script died instead of a bare rc check.
    if [ "$status" -ne 0 ]; then
        echo "inner script exit status: $status"
        echo "--- captured output ---"
        echo "$output"
        echo "--- mock call trace ---"
        cat "$target_dir/mock.trace" 2> /dev/null || echo "(no mock trace)"
        echo "--- xtrace replay (tail) ---"
        env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
            MO_NO_OPLOG=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
            /bin/bash --noprofile --norc -x "$script" 2>&1 | tail -60 || true
        return 1
    fi
    [[ "$output" == *"SURVIVED_SET_E"* ]] || return 1
    [[ "$output" == *"A_REMOVED"* ]] || return 1
}

@test "safe_sudo_find_delete reports batch failure without a second removal pass" {
    local target_dir="$TEST_DIR/sudo-batch-fallback"
    local script="$TEST_DIR/sudo-batch-fallback-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/stuck.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
TRACE="$TARGET_DIR/sudo.trace"
> "$TRACE"

# This test models a root-owned, non-user-writable log tree.
_mole_privileged_path_has_mutable_ancestor() { return 1; }

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
            printf '%s\0' "$TARGET_DIR/stuck.log"
            ;;
        xargs)
            # Simulate a batch failure without deleting anything.
            return 1
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
cat "$TRACE"
exit 0
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"SUDO:-n xargs -0 /bin/sh -c"* ]] || return 1
    [[ "$output" != *"SUDO:-n rm -rf $target_dir/stuck.log"* ]] || return 1
    [[ "$output" != *"INTERACTIVE_SUDO"* ]] || return 1
}

@test "safe_sudo_find_delete never elevates deletion below a user-writable parent" {
    local target_dir="$TEST_DIR/sudo-mutable-parent"
    local script="$TEST_DIR/sudo-mutable-parent-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/old.log"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
TRACE="$TARGET_DIR/sudo.trace"
> "$TRACE"

sudo() {
    printf 'SUDO:%s\n' "$*" >> "$TRACE"
    [[ "${1:-}" == "-n" ]] || return 99
    shift
    case "${1:-}" in
        test)
            shift
            command test "$@"
            ;;
        find)
            printf '%s\0' "$TARGET_DIR/old.log"
            ;;
        xargs | rm)
            echo "PRIVILEGED_DELETE:$*"
            return 0
            ;;
        *)
            "$@"
            ;;
    esac
}
export -f sudo

rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" || rc=$?
printf 'RC=%s\n' "$rc"
[[ -e "$TARGET_DIR/old.log" ]] && echo "TARGET_SURVIVED" || echo "TARGET_REMOVED"
cat "$TRACE"
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]] || return 1
    [[ "$output" == *"TARGET_REMOVED"* ]] || return 1
    [[ "$output" != *"PRIVILEGED_DELETE"* ]] || return 1
    [[ "$output" != *"SUDO:-n xargs"* ]] || return 1
    [[ "$output" != *"SUDO:-n rm"* ]] || return 1
}

@test "safe_sudo_find_delete treats a user-owned 0555 parent as mutable" {
    local target_dir="$TEST_DIR/sudo-owner-mutable-parent"
    local script="$TEST_DIR/sudo-owner-mutable-parent-test.sh"
    mkdir -p "$target_dir"
    touch "$target_dir/old.log"
    chmod 0555 "$target_dir"

    cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
TRACE="${TARGET_DIR}.sudo.trace"
> "$TRACE"

sudo() {
    printf 'SUDO:%s\n' "$*" >> "$TRACE"
    [[ "${1:-}" == "-n" ]] || return 99
    shift
    case "${1:-}" in
        test)
            shift
            command test "$@"
            ;;
        find)
            printf '%s\0' "$TARGET_DIR/old.log"
            ;;
        xargs | rm)
            echo "PRIVILEGED_DELETE:$*"
            return 0
            ;;
        *)
            "$@"
            ;;
    esac
}
export -f sudo

rc=0
safe_sudo_find_delete "$TARGET_DIR" "*.log" "0" "f" || rc=$?
printf 'RC=%s\n' "$rc"
[[ -e "$TARGET_DIR/old.log" ]] && echo "TARGET_SURVIVED" || echo "TARGET_REMOVED"
cat "$TRACE"
SCRIPT
    chmod +x "$script"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc "$script"
    chmod 0755 "$target_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"TARGET_SURVIVED"* ]] || return 1
    [[ "$output" != *"PRIVILEGED_DELETE"* ]] || return 1
    [[ "$output" != *"SUDO:-n xargs"* ]] || return 1
    [[ "$output" != *"SUDO:-n rm"* ]] || return 1
}

@test "safe_sudo_remove honours the cleanup whitelist before sudo" {
    local target="$TEST_DIR/whitelisted-sudo-target"
    mkdir -p "$target"
    touch "$target/data"

    # shellcheck disable=SC2016  # The inner bash expands TARGET and PROJECT_ROOT.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET="$target" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc -c '
            set -euo pipefail
            source "$PROJECT_ROOT/lib/core/common.sh"
            is_path_whitelisted() { [[ "$1" == "$TARGET" ]]; }
            sudo() {
                echo "UNEXPECTED_SUDO:$*"
                return 99
            }
            set +e
            safe_sudo_remove "$TARGET"
            rc=$?
            set -e
            printf "RC=%s\n" "$rc"
            [[ -e "$TARGET/data" ]] && echo "TARGET_SURVIVED"
        '

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"TARGET_SURVIVED"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SUDO"* ]]
}

@test "safe_find_delete rejects symlinked directory" {
    local real_dir="$TEST_DIR/real"
    local link_dir="$TEST_DIR/link"
    mkdir -p "$real_dir"
    ln -s "$real_dir" "$link_dir"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '$link_dir' '*.tmp' 7 'f' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]] || return 1

    rm -rf "$link_dir" "$real_dir"
}

@test "safe_find_delete validates type filter" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '$TEST_DIR' '*.tmp' 7 'x' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid type filter"* ]]
}

@test "safe_find_delete deletes old files" {
    local old_file="$TEST_DIR/old.tmp"
    local new_file="$TEST_DIR/new.tmp"

    touch "$old_file"
    touch "$new_file"

    touch -t "$(date -v-8d '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M.%S')" "$old_file" 2>/dev/null || true

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; safe_find_delete '$TEST_DIR' '*.tmp' 7 'f'"
    [ "$status" -eq 0 ]
    [ ! -e "$old_file" ] || return 1
    [ -e "$new_file" ]
}

@test "safe_find_delete discards a timed-out partial scan" {
    local target_dir="$TEST_DIR/find-partial-target"
    local target_file="$target_dir/old.tmp"
    local mock_bin="$TEST_DIR/find-partial-bin"
    local trace="$TEST_DIR/find-partial.trace"
    mkdir -p "$target_dir" "$mock_bin"
    touch "$target_file"

    cat > "$mock_bin/find" <<'MOCK'
#!/bin/bash
printf 'find %s\n' "$*" >> "$MOLE_FIND_TRACE"
printf '%s\0' "$TARGET_FILE"
exec sleep 4
MOCK
    chmod +x "$mock_bin/find"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TARGET_DIR="$target_dir" \
        TARGET_FILE="$target_file" MOLE_FIND_TRACE="$trace" PATH="$mock_bin:$PATH" \
        MOLE_TIMEOUT_DISK_VERIFY_SEC=1 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
safe_remove() {
    printf 'UNEXPECTED_DELETE:%s\n' "$1"
    return 99
}
rc=0
safe_find_delete "$TARGET_DIR" "*.tmp" "0" "f" || rc=$?
printf 'RC=%s\n' "$rc"
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$(< "$trace")" == *"$target_dir -maxdepth 5 -name *.tmp -type f -print0"* ]] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || return 1
    [ -e "$target_file" ]
}

@test "safe_find_delete works when app protection is not loaded" {
    local old_file="$TEST_DIR/file-ops-only.tmp"
    touch "$old_file"
    touch -t "$(date -v-8d '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M.%S')" "$old_file" 2>/dev/null || true

    run /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/file_ops.sh"
safe_find_delete "$TEST_DIR" "*.tmp" 7 "f"
EOF

    [ "$status" -eq 0 ]
    [ ! -e "$old_file" ]
}

@test "MOLE_* constants are defined" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_TEMP_FILE_AGE_DAYS"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_MAX_PARALLEL_JOBS"
    [ "$status" -eq 0 ]
    [ "$output" = "15" ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_TM_BACKUP_SAFE_HOURS"
    [ "$status" -eq 0 ]
    [ "$output" = "48" ]
}

# One vendor's Squirrel `ShipIt` used to claim another vendor's cache: the old
# probe accepted the bare last DNS label (`pgrep -x ShipIt`), and Claude's
# running ShipIt made Mole treat VS Code's idle cache as live. Measured on a
# real process table, leaf-only matching called 34 of 59 idle caches busy.
# Parity with the Mac app's ProcessGuard.processListMentionsCacheOwner.
@test "cache owner probe requires corroboration for a shared leaf name (#1390)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/file_ops.sh"
# Squirrel passes the owning bundle id as argv[1], which is the real reason
# the running copy is identifiable at all. Copied from an actual `ps` line.
ps() {
    cat <<'TABLE'
  PID  PPID COMM             ARGS
  501     1 /Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt /Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt
  502     1 /System/Library/PrivateFrameworks/DataAccess.framework/Support/dataaccessd /System/Library/PrivateFrameworks/DataAccess.framework/Support/dataaccessd
  503     1 /usr/libexec/syncdefaultsd /usr/libexec/syncdefaultsd
TABLE
}
state=0
_mole_user_cache_owner_process_state "com.microsoft.VSCode.ShipIt" || state=$?
printf 'SHIPIT=%s\n' "$state"
state=0
_mole_user_cache_owner_process_state "com.plausiblelabs.crashreporter.data" || state=$?
printf 'DATA=%s\n' "$state"
state=0
_mole_user_cache_owner_process_state "com.anthropic.claudefordesktop.ShipIt" || state=$?
printf 'CLAUDE=%s\n' "$state"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SHIPIT=1"* ]] || return 1
    [[ "$output" == *"DATA=1"* ]] || return 1
    # The same line names both `ShipIt` and `Claude`, so this one is real.
    [[ "$output" == *"CLAUDE=0"* ]]
}

# The reason the probe exists: AcCoreConsole registers no NSRunningApplication
# and its cache dir is com.autodesk.AcCoreConsole, so the leaf plus the vendor
# on the same argv line is the only available evidence.
@test "cache owner probe still catches a corroborated helper (#1390)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/file_ops.sh"
ps() {
    cat <<'TABLE'
  PID  PPID COMM             ARGS
  601     1 /Applications/Autodesk Fusion.app/Contents/MacOS/AcCoreConsole /Applications/Autodesk Fusion.app/Contents/MacOS/AcCoreConsole
TABLE
}
state=0
_mole_user_cache_owner_process_state "com.autodesk.AcCoreConsole" || state=$?
printf 'HELPER=%s\n' "$state"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"HELPER=0"* ]]
}

# Mole's own size probe runs `du` over the very directory it is judging, so the
# cache id appears in the table because Mole is looking at it. Counting that as
# ownership would hide every cache that takes long enough to measure.
@test "cache owner probe ignores Mole's own measurement processes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/file_ops.sh"
ps() {
    cat <<TABLE
  PID  PPID COMM             ARGS
  701     1 /usr/bin/du du -skPx $HOME/Library/Caches/com.example.SampleApp
  702     1 /bin/sh sh -c mole clean
TABLE
}
state=0
_mole_user_cache_owner_process_state "com.example.SampleApp" || state=$?
printf 'SELF=%s\n' "$state"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SELF=1"* ]]
}

# An unreadable process table is not proof the owner is idle.
@test "cache owner probe fails closed when the process table is unreadable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/file_ops.sh"
ps() { return 1; }
state=0
_mole_user_cache_owner_process_state "com.example.SampleApp" || state=$?
printf 'UNREADABLE=%s\n' "$state"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"UNREADABLE=2"* ]]
}
