#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home clean-caches
    mkdir -p "$HOME/.cache/mole"
    mkdir -p "$HOME/Library/Caches"
    mkdir -p "$HOME/Library/Logs"
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/caches.sh"

    # Mock run_with_timeout to skip timeout overhead in tests
    # shellcheck disable=SC2329
    run_with_timeout() {
        shift  # Remove timeout argument
        "$@"
    }
    export -f run_with_timeout

    rm -f "$HOME/.cache/mole/permissions_granted"
}

@test "check_tcc_permissions skips in non-interactive mode" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; check_tcc_permissions" < /dev/null
    [ "$status" -eq 0 ]
    [[ ! -f "$HOME/.cache/mole/permissions_granted" ]]
}

@test "check_tcc_permissions skips when permissions already granted" {
    mkdir -p "$HOME/.cache/mole"
    touch "$HOME/.cache/mole/permissions_granted"

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; [[ -t 1 ]] || true; check_tcc_permissions"
    [ "$status" -eq 0 ]
}

@test "check_tcc_permissions validates protected directories" {

    [[ -d "$HOME/Library/Caches" ]] || return 1
    [[ -d "$HOME/Library/Logs" ]] || return 1
    [[ -d "$HOME/.cache/mole" ]] || return 1

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; check_tcc_permissions < /dev/null"
    [ "$status" -eq 0 ]
}

@test "clean_service_worker_cache returns early when path doesn't exist" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/clean/caches.sh'; clean_service_worker_cache 'TestBrowser' '/nonexistent/path'"
    [ "$status" -eq 0 ]
}

@test "clean_service_worker_cache handles empty cache directory" {
    local test_cache="$HOME/test_sw_cache"
    mkdir -p "$test_cache"

    run /bin/bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        run_with_timeout() { shift; \"\$@\"; }
        export -f run_with_timeout
        clean_service_worker_cache 'TestBrowser' '$test_cache'
    "
    [ "$status" -eq 0 ]

    rm -rf "$test_cache"
}

@test "clean_service_worker_cache protects specified domains" {
    local test_cache="$HOME/test_sw_cache"
    mkdir -p "$test_cache/abc123_https_capcut.com_0"
    mkdir -p "$test_cache/def456_https_example.com_0"

    run /bin/bash -c "
        export DRY_RUN=true
        export PROTECTED_SW_DOMAINS=(capcut.com photopea.com)
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        run_with_timeout() {
            local timeout=\"\$1\"
            shift
            if [[ \"\$1\" == \"get_path_size_kb\" ]]; then
                echo 0
                return 0
            fi
            if [[ \"\$1\" == \"sh\" ]]; then
                printf '%s\n' \
                    '$test_cache/abc123_https_capcut.com_0' \
                    '$test_cache/def456_https_example.com_0'
                return 0
            fi
            \"\$@\"
        }
        export -f run_with_timeout
        clean_service_worker_cache 'TestBrowser' '$test_cache'
    "
    [ "$status" -eq 0 ]

    [[ -d "$test_cache/abc123_https_capcut.com_0" ]] || return 1

    rm -rf "$test_cache"
}

# Regression for #724: MV3 extension SW caches are keyed by origin hash,
# so the PROTECTED_SW_DOMAINS domain-match never fires for them. The
# whitelist is the only escape hatch users have, respect it here.
@test "clean_service_worker_cache honors is_path_whitelisted (#724)" {
    local test_cache="$HOME/test_sw_cache_wl"
    mkdir -p "$test_cache/abc123hash_extension"
    mkdir -p "$test_cache/def456hash_other"

    run /bin/bash -c "
        export DRY_RUN=false
        export PROTECTED_SW_DOMAINS=(nomatch.invalid)
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        WHITELIST_PATTERNS=('$test_cache/abc123hash_extension')
        safe_remove() { echo \"REMOVE:\$1\"; return 0; }
        export -f safe_remove
        note_activity() { :; }
        export -f note_activity
        run_with_timeout() {
            local timeout=\"\$1\"
            shift
            if [[ \"\$1\" == \"sh\" ]]; then
                printf '%s\n' '$test_cache/abc123hash_extension' '$test_cache/def456hash_other'
                return 0
            fi
            if [[ \"\$1\" == \"du\" ]]; then
                printf '2048\t%s\n' \"\$3\"
                return 0
            fi
            \"\$@\"
        }
        export -f run_with_timeout
        clean_service_worker_cache 'TestBrowser' '$test_cache'
    "

    [ "$status" -eq 0 ]
    # Whitelisted dir must never be passed to safe_remove
    [[ "$output" != *"REMOVE:$test_cache/abc123hash_extension"* ]] || return 1
    # Non-whitelisted dir must be removed
    [[ "$output" == *"REMOVE:$test_cache/def456hash_other"* ]] || return 1
    # UI reports the protection count
    [[ "$output" == *"1 protected"* ]] || return 1

    rm -rf "$test_cache"
}

@test "clean_service_worker_cache colors cleaned size by unit" {
    local test_cache="$HOME/test_sw_cache_colored"
    mkdir -p "$test_cache/abc123_https_example.com_0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=false
declare -a PROTECTED_SW_DOMAINS=("capcut.com")
safe_remove() { return 0; }
note_activity() { :; }
run_with_timeout() {
    local timeout="\$1"
    shift
    if [[ "\$1" == "sh" ]]; then
        printf '%s\n' "$test_cache/abc123_https_example.com_0"
        return 0
    fi
    if [[ "\$1" == "du" ]]; then
        printf '1024\t%s\n' "$test_cache/abc123_https_example.com_0"
        return 0
    fi
    "\$@"
}
clean_service_worker_cache 'TestBrowser' '$test_cache'
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"TestBrowser Service Worker"* ]] || return 1
    [[ "$output" == *$'\033[0;32m✓\033[0m'* ]] || return 1
    [[ "$output" == *$'\033[0;33m1.0MB\033[0m'* ]] || return 1

    rm -rf "$test_cache"
}

@test "clean_service_worker_cache reports sub-megabyte cleanups as KB, not 0MB" {
    local test_cache="$HOME/test_sw_cache_submb"
    mkdir -p "$test_cache/abc123_https_example.com_0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=false
declare -a PROTECTED_SW_DOMAINS=("capcut.com")
safe_remove() { return 0; }
note_activity() { :; }
run_with_timeout() {
    local timeout="\$1"
    shift
    if [[ "\$1" == "sh" ]]; then
        printf '%s\n' "$test_cache/abc123_https_example.com_0"
        return 0
    fi
    if [[ "\$1" == "du" ]]; then
        # 900 KB: under 1MB, so the old KB/1024 truncation printed "0MB".
        printf '900\t%s\n' "$test_cache/abc123_https_example.com_0"
        return 0
    fi
    "\$@"
}
clean_service_worker_cache 'TestBrowser' '$test_cache'
EOF

    # Every assertion ends with || return 1: bare [[ ]] failures mid-test can
    # be swallowed and let the trailing rm -rf pass the test vacuously (#886).
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"TestBrowser Service Worker"* ]] || return 1
    [[ "$output" == *"KB"* ]] || return 1
    [[ "$output" != *"0MB"* ]] || return 1

    rm -rf "$test_cache"
}

@test "clean_service_worker_cache reports only successful removals" {
    local test_cache="$HOME/test_sw_cache_failed_remove"
    mkdir -p "$test_cache/abc123_https_example.com_0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=false
declare -a PROTECTED_SW_DOMAINS=("never.invalid")
safe_remove() { return 1; }
note_activity() { :; }
run_with_timeout() {
    shift
    if [[ "\$1" == "sh" ]]; then
        printf '%s\n' "$test_cache/abc123_https_example.com_0"
    elif [[ "\$1" == "du" ]]; then
        printf '512\t%s\n' "$test_cache/abc123_https_example.com_0"
    else
        "\$@"
    fi
}
clean_service_worker_cache TestBrowser "$test_cache"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"TestBrowser Service Worker"* ]]
}

@test "clean_service_worker_cache checks its guard after sizing before dry-run registration" {
    local test_cache="$HOME/test_sw_cache_guard"
    mkdir -p "$test_cache/abc123_https_example.com_0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
declare -a PROTECTED_SW_DOMAINS=("never.invalid")
delete_guard() { [[ ! -e "$test_cache/process-started" ]]; }
record_dry_run_cleanup_target() { echo "UNEXPECTED_RECORD:\$1"; }
note_activity() { :; }
run_with_timeout() {
    shift
    if [[ "\$1" == "sh" ]]; then
        printf '%s\n' "$test_cache/abc123_https_example.com_0"
    elif [[ "\$1" == "du" ]]; then
        touch "$test_cache/process-started"
        printf '512\t%s\n' "$test_cache/abc123_https_example.com_0"
    else
        "\$@"
    fi
}
rc=0
clean_service_worker_cache TestBrowser "$test_cache" delete_guard || rc=\$?
printf 'RC:%s\n' "\$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC:75"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_RECORD"* ]] || return 1
    [[ "$output" != *"TestBrowser Service Worker"* ]]
}

@test "clean_service_worker_cache discards partial discovery after timeout" {
    local test_cache="$HOME/test_sw_cache_partial_timeout"
    mkdir -p "$test_cache/abc123_https_example.com_0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=false
declare -a PROTECTED_SW_DOMAINS=("never.invalid")
safe_remove() { echo "UNEXPECTED_REMOVE:\$1"; return 0; }
note_activity() { :; }
run_with_timeout() {
    shift
    if [[ "\$1" == "sh" ]]; then
        printf '%s\n' "$test_cache/abc123_https_example.com_0"
        return 124
    fi
    if [[ "\$1" == "du" ]]; then
        printf '512\t%s\n' "$test_cache/abc123_https_example.com_0"
        return 0
    fi
    "\$@"
}
rc=0
clean_service_worker_cache TestBrowser "$test_cache" || rc=\$?
printf 'RC:%s\n' "\$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC:124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"TestBrowser Service Worker"* ]]
}

@test "clean_service_worker_cache refuses a symlinked cache root" {
    local outside="$HOME/outside-sw-profile"
    local linked_profile="$HOME/linked-sw-profile"
    mkdir -p "$outside/Service Worker/CacheStorage/abc123_https_example.com_0"
    ln -s "$outside" "$linked_profile"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=false
declare -a PROTECTED_SW_DOMAINS=("never.invalid")
safe_remove() { echo "UNEXPECTED_REMOVE:\$1"; return 0; }
note_activity() { :; }
run_with_timeout() {
    shift
    if [[ "\$1" == "sh" ]]; then
        printf '%s\n' "$linked_profile/Service Worker/CacheStorage/abc123_https_example.com_0"
        return 0
    fi
    if [[ "\$1" == "du" ]]; then
        printf '512\t%s\n' "$linked_profile/Service Worker/CacheStorage/abc123_https_example.com_0"
        return 0
    fi
    "\$@"
}
rc=0
clean_service_worker_cache TestBrowser "$linked_profile/Service Worker/CacheStorage" || rc=\$?
printf 'RC:%s\n' "\$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" == *"RC:1"* ]]
}

@test "clean_project_caches completes without errors" {
    mkdir -p "$HOME/Projects/test-app/.next/cache"
    mkdir -p "$HOME/Projects/python-app/__pycache__"

    touch "$HOME/Projects/test-app/package.json"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/test-app/.next/cache/test.cache"
    touch "$HOME/Projects/python-app/__pycache__/module.pyc"

    run /bin/bash -c "
        export DRY_RUN=true
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        clean_project_caches
    "
    [ "$status" -eq 0 ]

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches groups pycache directories by project root" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    mkdir -p "$HOME/Projects/python-app/subpkg/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"
    touch "$HOME/Projects/python-app/subpkg/__pycache__/other.pyc"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python bytecode cache"* ]] || return 1
    [[ "$output" == *"Python bytecode cache · python-app"* ]] || return 1
    [[ "$output" == *"2 dirs"* ]] || return 1
    [[ "$output" != *"module.pyc"* ]] || return 1

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches skips empty pycache directories" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    mkdir -p "$HOME/Projects/python-app/empty/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"
    # empty/__pycache__ has no .pyc files

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python bytecode cache"* ]] || return 1
    [[ "$output" == *"1 dirs"* ]] || return 1

	rm -rf "$HOME/Projects"
}

@test "clean_python_bytecode_cache_group reuses its exact size at removal" {
	local cache_dir="$HOME/Projects/python-app/pkg/__pycache__"
	mkdir -p "$cache_dir"
	touch "$cache_dir/module.pyc"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CACHE_DIR="$cache_dir" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=false
get_path_size_kb() { printf '321\n'; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { printf 'REMOVE=%s SILENT=%s SIZE=%s\n' "$1" "$2" "$3"; }
clean_python_bytecode_cache_group "$HOME/Projects/python-app" "$CACHE_DIR"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REMOVE=$cache_dir SILENT=true SIZE=321"* ]] || return 1
	rm -rf "$HOME/Projects"
}

@test "pycache_has_bytecode checks direct bytecode files without spawning find" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"

    run /bin/bash -c "
source '$PROJECT_ROOT/lib/clean/caches.sh'
if pycache_has_bytecode '$HOME/Projects/python-app/pkg/__pycache__'; then
    echo has-bytecode
else
    echo empty
fi
touch '$HOME/Projects/python-app/pkg/__pycache__/module.pyc'
if pycache_has_bytecode '$HOME/Projects/python-app/pkg/__pycache__'; then
    echo has-bytecode
else
    echo empty
fi
"

    [ "$status" -eq 0 ]
    [[ "$output" == $'empty\nhas-bytecode' ]]
}

@test "pycache_has_bytecode tolerates empty matches when nullglob is enabled" {
    mkdir -p "$HOME/Projects/nullglob-app/pkg/__pycache__"

    run /bin/bash -c "
set -euo pipefail
source '$PROJECT_ROOT/lib/clean/caches.sh'
shopt -s nullglob
if pycache_has_bytecode '$HOME/Projects/nullglob-app/pkg/__pycache__'; then
    echo has-bytecode
else
    echo empty
fi
if shopt -q nullglob; then
    echo nullglob-restored
else
    echo nullglob-lost
fi
"

    [ "$status" -eq 0 ]
    [[ "$output" == $'empty\nnullglob-restored' ]]
}

@test "clean_project_caches pycache dry-run exports grouped targets and counts skips" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    mkdir -p "$HOME/Projects/python-app/protected/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"
    touch "$HOME/Projects/python-app/protected/__pycache__/blocked.pyc"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
EXPORT_LIST_FILE="$HOME/export.txt"
whitelist_skipped_count=0
should_protect_path() {
    [[ "$1" == *"/protected/__pycache__" ]]
}
clean_project_caches
printf '\nEXPORT\n'
cat "$EXPORT_LIST_FILE"
printf '\nSKIPPED=%s\n' "$whitelist_skipped_count"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 dirs"* ]] || return 1
    [[ "$output" == *"1 skipped"* ]] || return 1
    [[ "$output" == *"EXPORT"* ]] || return 1
    [[ "$output" == *"$HOME/Projects/python-app/pkg/__pycache__"* ]] || return 1
    [[ "$output" != *"$HOME/Projects/python-app/protected/__pycache__"* ]] || return 1
    [[ "$output" == *"SKIPPED=1"* ]] || return 1

    rm -rf "$HOME/Projects" "$HOME/export.txt"
}

@test "clean_project_caches keeps project caches that Git tracks" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/Projects/repo"
mkdir -p "$repo/py/pkg/__pycache__" "$repo/py/committed/__pycache__" \
    "$repo/app/.dart_tool" "$repo/app/build" "$repo/app/test/fixtures/.dart_tool"
touch "$repo/py/pyproject.toml" "$repo/app/pubspec.yaml"
touch "$repo/py/pkg/__pycache__/local.pyc" "$repo/py/committed/__pycache__/committed.pyc"
touch "$repo/app/.dart_tool/state" "$repo/app/build/output"
printf '{}' > "$repo/app/test/fixtures/.dart_tool/package_config.json"
git init -q "$repo"
git -C "$repo" add -f py/committed/__pycache__/committed.pyc app/test/fixtures/.dart_tool/package_config.json
DRY_RUN=false
clean_project_caches
[[ ! -e "$repo/py/pkg/__pycache__" ]] || exit 11
[[ -f "$repo/py/committed/__pycache__/committed.pyc" ]] || exit 12
[[ ! -e "$repo/app/.dart_tool" ]] || exit 13
[[ ! -e "$repo/app/build" ]] || exit 14
[[ -f "$repo/app/test/fixtures/.dart_tool/package_config.json" ]] || exit 15
EOF
    [ "$status" -eq 0 ]

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches keeps a project cache whose Git probe cannot finish" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
mkdir -p "$HOME/Projects/app/.dart_tool" "$HOME/Projects/py/pkg/__pycache__"
touch "$HOME/Projects/app/pubspec.yaml" "$HOME/Projects/py/pyproject.toml"
touch "$HOME/Projects/py/pkg/__pycache__/module.pyc"
mole_path_has_git_tracked_files() { return 2; }
DRY_RUN=false
clean_project_caches
[[ -d "$HOME/Projects/app/.dart_tool" ]] || exit 11
[[ -f "$HOME/Projects/py/pkg/__pycache__/module.pyc" ]] || exit 12
EOF
    [ "$status" -eq 0 ]

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches scans configured roots instead of HOME" {
    mkdir -p "$HOME/.config/mole"
    mkdir -p "$HOME/CustomProjects/app/.next/cache"
    touch "$HOME/CustomProjects/app/package.json"

    local fake_bin
    fake_bin="$(mktemp -d "$HOME/find-bin.XXXXXX")"
    local find_log="$HOME/find.log"

    cat > "$fake_bin/find" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$find_log"
root=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "-P" ]]; then
        root="\$arg"
        break
    fi
    prev="\$arg"
done
if [[ "\$root" == "$HOME/CustomProjects" ]]; then
    printf '%s\n' "$HOME/CustomProjects/app/.next"
fi
EOF
    chmod +x "$fake_bin/find"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$fake_bin:$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
printf '%s\n' "$HOME/CustomProjects" > "$HOME/.config/mole/purge_paths"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
run_with_timeout() { shift; "$@"; }
safe_clean() { echo "$2|$1"; }
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Next.js build cache"* ]] || return 1
    grep -q -- "-P $HOME/CustomProjects " "$find_log"
    run grep -q -- "-P $HOME " "$find_log"
    [ "$status" -eq 1 ]

    rm -rf "$HOME/CustomProjects" "$HOME/.config/mole" "$fake_bin" "$find_log"
}

@test "clean_project_caches auto-detects top-level project containers" {
    mkdir -p "$HOME/go/src/demo/.next/cache"
    touch "$HOME/go/src/demo/go.mod"
    touch "$HOME/go/src/demo/.next/cache/test.cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
safe_clean() { echo "$2|$1"; }
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Next.js build cache|$HOME/go/src/demo/.next/cache/test.cache"* ]] || return 1

    rm -rf "$HOME/go"
}

@test "clean_project_caches auto-detects nested GOPATH-style project containers" {
    mkdir -p "$HOME/go/src/github.com/example/demo/.next/cache"
    touch "$HOME/go/src/github.com/example/demo/go.mod"
    touch "$HOME/go/src/github.com/example/demo/.next/cache/test.cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
safe_clean() { echo "$2|$1"; }
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Next.js build cache|$HOME/go/src/github.com/example/demo/.next/cache/test.cache"* ]] || return 1

	rm -rf "$HOME/go"
}

@test "project cache scans refill slots and keep statuses bound to original roots" {
    run /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
for name in root-0 root-1 root-2; do mkdir -p "$HOME/$name"; done
discover_project_cache_roots() { printf '%s\n' "$HOME/root-0" "$HOME/root-1" "$HOME/root-2"; }
get_optimal_parallel_jobs() { printf '2\n'; }
scan_project_cache_root() {
    local name="${1##*/}"
    printf '%s\n' "$name" > "$2"
    case "$name" in
        root-0)
            for _ in {1..100}; do
                [[ ! -e "$HOME/root-2-started" ]] || return 0
                sleep 0.02
            done
            return 1
            ;;
        root-1) return 1 ;;
        root-2) touch "$HOME/root-2-started" ;;
    esac
}
process_project_cache_matches() { printf 'PROCESSED=%s\n' "$(cat "$1")"; }
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'PROCESSED=root-0'* && "$output" == *'PROCESSED=root-2'* ]] || return 1
    [[ "$output" != *'PROCESSED=root-1'* ]] || return 1
}

@test "clean_project_caches scans independent roots concurrently within its bound" {
	local scan_home="$HOME/concurrent-project-scans"
	mkdir -p "$scan_home/root-1" "$scan_home/root-2" "$scan_home/root-3" "$scan_home/root-4"

	run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() {
	printf '%s\n' "$HOME/root-1" "$HOME/root-2" "$HOME/root-3" "$HOME/root-4"
}
get_optimal_parallel_jobs() { printf '2\n'; }
scan_project_cache_root() {
	: > "$2"
	touch "$HOME/active-${1##*/}"
	while [[ ! -e "$HOME/release-scans" ]]; do
		sleep 0.02
	done
	rm -f "$HOME/active-${1##*/}"
}
process_project_cache_matches() { :; }

(
	trap 'touch "$HOME/release-scans"' EXIT
	for _ in {1..100}; do
		active_count=$(command find "$HOME" -maxdepth 1 -name 'active-*' | wc -l | tr -d ' ')
		if [[ "$active_count" -ge 2 ]]; then
			printf '%s\n' "$active_count" > "$HOME/observed-concurrency"
			touch "$HOME/release-scans"
			exit 0
		fi
		sleep 0.02
	done
	exit 1
) &
monitor_pid=$!

clean_project_caches
wait "$monitor_pid"
printf 'CONCURRENCY=%s\n' "$(cat "$HOME/observed-concurrency")"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "CONCURRENCY=2" ]] || return 1
}

@test "discover_project_cache_roots dedupes aliased roots by filesystem identity" {
    mkdir -p "$HOME/code/demo/.dart_tool"
    touch "$HOME/code/demo/pubspec.yaml"
    mkdir -p "$HOME/.config/mole"
    ln -s "$HOME/code" "$HOME/Code"
    printf '%s\n' "$HOME/Code" > "$HOME/.config/mole/purge_paths"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
roots=$(discover_project_cache_roots)
printf '%s\n' "$roots"
printf 'COUNT=%s\n' "$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=1"* ]]
}

@test "clean_project_caches skips stalled root scans" {
    mkdir -p "$HOME/.config/mole"
    mkdir -p "$HOME/SlowProjects/app"
    printf '%s\n' "$HOME/SlowProjects" > "$HOME/.config/mole/purge_paths"

    local fake_bin
    fake_bin="$(mktemp -d "$HOME/find-timeout.XXXXXX")"

    cat > "$fake_bin/find" <<EOF
#!/bin/bash
root=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "-P" ]]; then
        root="\$arg"
        break
    fi
    prev="\$arg"
done
if [[ "\$root" == "$HOME/SlowProjects" ]]; then
    trap "" TERM
    sleep 5
    exit 0
fi
exit 0
EOF
    chmod +x "$fake_bin/find"

    run /usr/bin/perl -e 'alarm 5; exec @ARGV' env -i HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$fake_bin:$PATH:/usr/bin:/bin:/usr/sbin:/sbin" TERM="${TERM:-xterm-256color}" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
MO_TIMEOUT_BIN=""
MO_TIMEOUT_PERL_BIN="${MO_TIMEOUT_PERL_BIN:-$(command -v perl)}"
export MOLE_PROJECT_CACHE_DISCOVERY_TIMEOUT=0.5
export MOLE_PROJECT_CACHE_SCAN_TIMEOUT=0.5
SECONDS=0
clean_project_caches
echo "ELAPSED=$SECONDS"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"ELAPSED="* ]] || return 1
    elapsed=$(printf '%s\n' "$output" | awk -F= '/ELAPSED=/{print $2}' | tail -1)
    [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
    (( elapsed < 5 ))
    [[ "$output" == *"Project caches · skipped 1 slow/incomplete root scan"* ]] || return 1

	rm -rf "$HOME/.config/mole" "$HOME/SlowProjects" "$fake_bin"
}

@test "clean_project_caches propagates an interrupted root scan" {
	local scan_home="$HOME/interrupted-project-scan"
	mkdir -p "$scan_home/root"

	run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME/root"; }
scan_project_cache_root() {
	: > "$2"
	return 130
}
process_project_cache_matches() { printf 'UNEXPECTED_PROCESS\n'; }
clean_rc=0
clean_project_caches || clean_rc=$?
printf 'RC=%s\n' "$clean_rc"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "RC=130" ]] || return 1
}

@test "clean_project_caches processes no roots when a later scan is interrupted" {
	local scan_home="$HOME/interrupted-project-scan-batch"
	mkdir -p "$scan_home/root-1" "$scan_home/root-2"

	run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME/root-1" "$HOME/root-2"; }
scan_project_cache_root() {
	: > "$2"
	[[ "$1" == "$HOME/root-1" ]] && return 0
	return 130
}
process_project_cache_matches() { touch "$HOME/processed"; }
clean_rc=0
clean_project_caches || clean_rc=$?
printf 'RC=%s PROCESSED=%s\n' "$clean_rc" "$([[ -e "$HOME/processed" ]] && printf yes || printf no)"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "RC=130 PROCESSED=no" ]] || return 1
}

@test "clean_project_caches stops launching roots after an interrupted batch" {
	local scan_home="$HOME/interrupted-project-scan-launch"
	mkdir -p "$scan_home/root-1" "$scan_home/root-2" "$scan_home/root-3"

	run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() {
	printf '%s\n' "$HOME/root-1" "$HOME/root-2" "$HOME/root-3"
}
get_optimal_parallel_jobs() { printf '1\n'; }
scan_project_cache_root() {
	: > "$2"
	printf '%s\n' "${1##*/}" >> "$HOME/scanned"
	[[ "${1##*/}" == "root-1" ]] && return 130
	return 0
}
process_project_cache_matches() { printf 'UNEXPECTED_PROCESS\n'; }
clean_rc=0
clean_project_caches || clean_rc=$?
printf 'RC=%s SCANNED=%s\n' "$clean_rc" "$(paste -sd, "$HOME/scanned")"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "RC=130 SCANNED=root-1" ]] || return 1
}

@test "clean_project_caches kills active root scans when its parent receives TERM" {
	local scan_home="$HOME/terminated-project-scans"
	mkdir -p "$scan_home/root"
	local driver="$scan_home/driver.sh"

	cat > "$driver" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME/root"; }
get_optimal_parallel_jobs() { printf '1\n'; }
scan_project_cache_root() {
	: > "$2"
	touch "$HOME/worker-started"
	trap 'exit 143' TERM
	sleep 1
	touch "$HOME/worker-survived"
}
process_project_cache_matches() { :; }
clean_project_caches
EOF
	chmod +x "$driver"

	run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" DRIVER="$driver" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
/bin/bash "$DRIVER" &
parent_pid=$!
for _ in {1..100}; do
	[[ -e "$HOME/worker-started" ]] && break
	sleep 0.02
done
[[ -e "$HOME/worker-started" ]] || exit 1
kill -TERM "$parent_pid"
parent_rc=0
wait "$parent_pid" || parent_rc=$?
sleep 0.1
printf 'PARENT_RC=%s WORKER_SURVIVED=%s\n' \
	"$parent_rc" "$([[ -e "$HOME/worker-survived" ]] && printf yes || printf no)"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "PARENT_RC=143 WORKER_SURVIVED=no" ]] || return 1
}

@test "scan_project_cache_root discards partial output when its producer times out" {
	mkdir -p "$HOME/Projects/app/.next/cache"
	touch "$HOME/Projects/app/package.json"
	local output_file
	output_file=$(mktemp)

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" OUTPUT_FILE="$output_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
run_with_timeout() {
	printf '%s\n' "$HOME/Projects/app/.next"
	return 124
}
scan_rc=0
scan_project_cache_root "$HOME/Projects" "$OUTPUT_FILE" || scan_rc=$?
printf 'STATUS=%s SIZE=%s\n' "$scan_rc" "$(wc -c < "$OUTPUT_FILE" | tr -d ' ')"
EOF

	rm -rf "$HOME/Projects" "$output_file"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "STATUS=124 SIZE=0" ]] || return 1
}

@test "scan_project_cache_root bounds grouping within the shared deadline" {
	mkdir -p "$HOME/Projects"
	local fake_bin
	fake_bin="$(mktemp -d "$HOME/project-cache-postprocess.XXXXXX")"
	cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
for i in $(seq 1 1000); do
	printf '%s\n' "$HOME/Projects/app-$i/.next"
done
EOF
	cat > "$fake_bin/dirname" <<'EOF'
#!/bin/bash
sleep 0.02
/usr/bin/dirname "$@"
EOF
	chmod +x "$fake_bin/find" "$fake_bin/dirname"
	local output_file
	output_file=$(mktemp)

	run env HOME="$HOME" PATH="$fake_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" OUTPUT_FILE="$output_file" \
		MOLE_PROJECT_CACHE_SCAN_TIMEOUT=2 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
SECONDS=0
scan_rc=0
scan_project_cache_root "$HOME/Projects" "$OUTPUT_FILE" || scan_rc=$?
printf 'STATUS=%s ELAPSED=%s BYTES=%s\n' \
	"$scan_rc" "$SECONDS" "$(wc -c < "$OUTPUT_FILE" | tr -d ' ')"
EOF

	[ "$status" -eq 0 ] || return 1
	local elapsed
	elapsed=$(printf '%s\n' "$output" | sed -n 's/.*ELAPSED=\([0-9][0-9]*\).*/\1/p')
	[[ "$output" == STATUS=124*" BYTES=0" ]] || return 1
	[[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
	((elapsed < 4))
}

@test "scan_project_cache_root prunes conda and site-packages" {
    mkdir -p "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg1/__pycache__"
    mkdir -p "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg2/__pycache__"
    mkdir -p "$HOME/Projects/app/__pycache__"
    touch "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg1/__pycache__/mod.pyc"
    touch "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg2/__pycache__/mod.pyc"
    touch "$HOME/Projects/app/pyproject.toml"
    touch "$HOME/Projects/app/__pycache__/mod.pyc"

    local output_file
    output_file=$(mktemp)

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/lib/clean/caches.sh"
run_with_timeout() { shift; "\$@"; }
scan_project_cache_root "$HOME/Projects" "$output_file"
cat "$output_file"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"app/__pycache__"* ]] || return 1
    [[ "$output" != *"miniconda3"* ]] || return 1
    [[ "$output" != *"site-packages"* ]] || return 1

    rm -rf "$HOME/Projects" "$output_file"
}

@test "clean_project_caches excludes Library and Trash directories" {
    mkdir -p "$HOME/Library/.next/cache"
    mkdir -p "$HOME/.Trash/.next/cache"
    mkdir -p "$HOME/Projects/app/.next/cache"
    touch "$HOME/Projects/app/package.json"

    run /bin/bash -c "
        export DRY_RUN=true
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/caches.sh'
        clean_project_caches
    "
    [ "$status" -eq 0 ]

    rm -rf "$HOME/Projects"
}
