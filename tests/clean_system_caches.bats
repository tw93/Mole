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

@test "clean_service_worker_cache finds depth-two entries with GNU find first in PATH" {
    local test_cache="$HOME/sw_gnu_find"
    local stub_bin="$HOME/sw-gnu-bin"
    mkdir -p "$test_cache/origin_a/cache_one/deeper" "$stub_bin"
    # GNU find takes -depth as an option with no argument, so the BSD-only
    # `-depth 2` made it read "2" as a path and fail the whole discovery.
    cat > "$stub_bin/find" << 'STUB'
#!/bin/bash
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-depth" && "$arg" =~ ^[0-9]+$ ]]; then
        echo "find: paths must precede expression: '$arg'" >&2
        exit 1
    fi
    prev="$arg"
done
exec /usr/bin/find "$@"
STUB
    chmod +x "$stub_bin/find"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stub_bin:$PATH" CACHE="$test_cache" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
PROTECTED_SW_DOMAINS=(capcut.com)
record_dry_run_cleanup_target() { echo "RECORD:$1"; }
clean_service_worker_cache "TestBrowser" "$CACHE"
EOF

    rm -rf "$test_cache" "$stub_bin"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RECORD:$test_cache/origin_a/cache_one"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"RECORD:$test_cache/origin_a/cache_one/deeper"* ]] || { echo "$output"; return 1; }
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

@test "clean_project_caches skips an unwalkable CloudStorage root before scanning it" {
    mkdir -p "$HOME/Library/CloudStorage/Drive/project/.next/cache"
    mkdir -p "$HOME/Projects/app/.next/cache"
    touch "$HOME/Library/CloudStorage/Drive/project/package.json" \
        "$HOME/Library/CloudStorage/Drive/project/.next/cache/cloud.cache" \
        "$HOME/Projects/app/package.json" "$HOME/Projects/app/.next/cache/local.cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
real_find="$FIND_BSD"
find_stub="$HOME/find-stub.sh"
{
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >> "$HOME/find-calls"\n'
    printf 'for arg in "$@"; do\n'
    printf '    if [[ "$arg" == *"/Library/CloudStorage"* ]]; then\n'
    printf '        printf "find: %%s: Operation not permitted\\n" "$arg" >&2\n'
    printf '        exit 1\n'
    printf '    fi\n'
    printf 'done\n'
    printf 'exec %q "$@"\n' "$real_find"
} > "$find_stub"
chmod +x "$find_stub"
FIND_BSD="$find_stub"
clean_project_caches
EOF
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ -f "$HOME/find-calls" ] || { printf '%s\n' "$output"; return 1; }
    # The CloudStorage root is decided by the depth-two precheck and never
    # handed to the depth-nine scan.
    [ "$(grep -c -- '/Library/CloudStorage' "$HOME/find-calls")" -eq 1 ] || { cat "$HOME/find-calls"; return 1; }
    grep -q -- '-maxdepth 2' "$HOME/find-calls" || { cat "$HOME/find-calls"; return 1; }
    # The readable projects root keeps its normal depth-nine scan.
    grep -q -- "$HOME/Projects.*-maxdepth 9" "$HOME/find-calls" || { cat "$HOME/find-calls"; return 1; }
    # Coverage loss is still reported once as a skipped root.
    [[ "$output" == *"skipped 1 slow/incomplete root scan"* ]] || { printf '%s\n' "$output"; return 1; }

    rm -rf "$HOME/Library/CloudStorage" "$HOME/Projects" "$HOME/find-calls" "$HOME/find-stub.sh"
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

@test "clean_project_caches keeps loading up while it checks matches and stops it before a row" {
    if ! /usr/bin/script -q /dev/null /usr/bin/true < /dev/null > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"
    local raw="$HOME/project-cache-loading.raw"

    # shellcheck disable=SC2016  # inner bash expands these from its environment
    PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" TERM=xterm-256color \
        /usr/bin/script -q -F "$raw" /bin/bash --noprofile --norc -c '
            set -euo pipefail
            source "$PROJECT_ROOT/lib/core/common.sh"
            source "$PROJECT_ROOT/lib/clean/caches.sh"
            DRY_RUN=true
            spinning=""
            start_inline_spinner() { spinning="$1"; }
            start_section_spinner() { spinning="$1"; }
            stop_inline_spinner() { [[ -z "$spinning" ]] || echo "STOP"; spinning=""; }
            stop_section_spinner() { stop_inline_spinner; }
            get_path_size_kb() { echo "SIZE_WHILE:${spinning:-none}" >&2; echo 4; }
            clean_project_caches
            echo "AFTER:${spinning:-none}"
        ' < /dev/null > /dev/null 2>&1

    local content
    content=$(tr -d '\r' < "$raw")
    rm -rf "$HOME/Projects" "$raw"
    [[ "$content" == *"SIZE_WHILE:Checking project caches..."* ]] || { echo "$content"; return 1; }
    [[ "$content" == *"SIZE_WHILE:Checking project caches..."*"STOP"*"Python bytecode cache · python-app"* ]] || { echo "$content"; return 1; }
    [[ "$content" == *"AFTER:none"* ]] || { echo "$content"; return 1; }
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
    [[ "$output" == *"1 dir,"* ]] || return 1

	rm -rf "$HOME/Projects"
}

@test "clean_project_caches collects a scan started ahead of Developer tools" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
discover_project_cache_roots() {
    echo DISCOVER >> "$HOME/discover.trace"
    printf '%s\n' "$HOME/Projects"
}
: > "$HOME/discover.trace"
start_project_cache_prefetch
prefetch_pid="$_MOLE_PROJECT_CACHE_PREFETCH_PID"
[[ -n "$prefetch_pid" ]] || exit 1
while kill -0 "$prefetch_pid" 2> /dev/null; do sleep 0.05; done
clean_project_caches
discoveries=$(grep -c DISCOVER "$HOME/discover.trace")
[[ "$discoveries" == 1 ]] || { echo "DISCOVERIES:$discoveries"; exit 1; }
[[ -z "$_MOLE_PROJECT_CACHE_PREFETCH_PID" ]] || exit 1
echo COLLECTED
EOF
    rm -rf "$HOME/Projects" "$HOME/discover.trace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *COLLECTED* ]] || return 1
    [[ "$output" == *"Python bytecode cache · python-app"* ]] || return 1
}

@test "stop_project_cache_prefetch stops an uncollected scan and its workers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME"; }
project_cache_root_is_walkable() { return 0; }
scan_project_cache_root() {
    sh -c 'echo $PPID' > "$HOME/worker.pid"
    while :; do sleep 0.1; done
}
rm -f "$HOME/worker.pid"
start_project_cache_prefetch
prefetch_pid="$_MOLE_PROJECT_CACHE_PREFETCH_PID"
scan_manifest="$_MOLE_PROJECT_CACHE_PREFETCH_MANIFEST"
for _ in $(seq 100); do
    [[ -s "$HOME/worker.pid" ]] && break
    sleep 0.05
done
worker_pid=$(cat "$HOME/worker.pid")
[[ -n "$worker_pid" ]] || exit 1
stop_project_cache_prefetch
sleep 0.3
if kill -0 "$prefetch_pid" 2> /dev/null; then echo "PREFETCH_ALIVE"; exit 1; fi
if kill -0 "$worker_pid" 2> /dev/null; then echo "WORKER_ALIVE"; kill "$worker_pid"; exit 1; fi
[[ ! -e "$scan_manifest" ]] || { echo "MANIFEST_LEFT"; exit 1; }
[[ -z "$_MOLE_PROJECT_CACHE_PREFETCH_PID" ]] || exit 1
echo STOPPED
EOF
    rm -f "$HOME/worker.pid"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *STOPPED* ]] || return 1
}

@test "clean_project_caches returns a signal that arrives while it waits for the prefetch" {
    local scan_home="$HOME/prefetch-collect-term"
    mkdir -p "$scan_home/root"
    local driver="$scan_home/driver.sh"

    cat > "$driver" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME/root"; }
project_cache_root_is_walkable() { return 0; }
get_optimal_parallel_jobs() { printf '1\n'; }
scan_project_cache_root() {
    sh -c 'echo $PPID' > "$HOME/worker.pid"
    while :; do sleep 0.1; done
}
process_project_cache_matches() { touch "$HOME/sink-called"; }
start_project_cache_prefetch
touch "$HOME/collecting"
rc=0
clean_project_caches || rc=$?
printf 'RC=%s\n' "$rc" > "$HOME/driver.rc"
EOF
    chmod +x "$driver"

    run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" DRIVER="$driver" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
/bin/bash "$DRIVER" &
driver_pid=$!
for _ in $(seq 100); do
    [[ -s "$HOME/worker.pid" && -e "$HOME/collecting" ]] && break
    sleep 0.05
done
[[ -s "$HOME/worker.pid" && -e "$HOME/collecting" ]] || exit 1
worker_pid=$(cat "$HOME/worker.pid")
sleep 0.3
kill -TERM "$driver_pid"
wait "$driver_pid" || true
sleep 0.3
if kill -0 "$worker_pid" 2> /dev/null; then echo "WORKER_ALIVE"; kill "$worker_pid"; exit 1; fi
[[ ! -e "$HOME/sink-called" ]] || { echo "SINK_CALLED"; exit 1; }
cat "$HOME/driver.rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "RC=143" ]] || { echo "$output"; return 1; }
}

@test "a prefetch that ended on a signal feeds nothing to the project cache sink" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME"; }
project_cache_root_is_walkable() { return 0; }
scan_project_cache_root() {
    printf '%s\n' "$HOME/found-cache" > "$2"
    sh -c 'echo $PPID' > "$HOME/worker.pid"
    while :; do sleep 0.1; done
}
process_project_cache_matches() { touch "$HOME/sink-called"; }
rm -f "$HOME/worker.pid" "$HOME/sink-called"
start_project_cache_prefetch
for _ in $(seq 100); do
    [[ -s "$HOME/worker.pid" ]] && break
    sleep 0.05
done
[[ -s "$HOME/worker.pid" ]] || exit 1
kill -TERM "$_MOLE_PROJECT_CACHE_PREFETCH_PID"
rc=0
clean_project_caches || rc=$?
[[ "$rc" == 143 ]] || { echo "RC:$rc"; exit 1; }
[[ ! -e "$HOME/sink-called" ]] || { echo "SINK_CALLED"; exit 1; }
echo NO_SINK
EOF
    rm -f "$HOME/worker.pid" "$HOME/sink-called"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *NO_SINK* ]] || return 1
}

@test "stop_project_cache_prefetch never signals a scan that already finished" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { :; }
start_project_cache_prefetch
prefetch_pid="$_MOLE_PROJECT_CACHE_PREFETCH_PID"
[[ -n "$prefetch_pid" ]] || exit 1
for _ in $(seq 100); do
    kill -0 "$prefetch_pid" 2> /dev/null || break
    sleep 0.05
done
if kill -0 "$prefetch_pid" 2> /dev/null; then echo "STILL_RUNNING"; exit 1; fi
kill() { printf '%s\n' "$*" >> "$HOME/kill.calls"; builtin kill "$@"; }
: > "$HOME/kill.calls"
stop_project_cache_prefetch
if grep -q -- "$prefetch_pid" "$HOME/kill.calls"; then echo "SIGNALLED"; exit 1; fi
echo NOT_SIGNALLED
EOF
    rm -f "$HOME/kill.calls"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *NOT_SIGNALLED* ]] || return 1
}

@test "stop_project_cache_prefetch never signals a scan terminated before its own traps" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() {
    touch "$HOME/discovering"
    sleep 1
}
rm -f "$HOME/discovering"
start_project_cache_prefetch
prefetch_pid="$_MOLE_PROJECT_CACHE_PREFETCH_PID"
for _ in $(seq 100); do
    [[ -e "$HOME/discovering" ]] && break
    sleep 0.05
done
[[ -e "$HOME/discovering" ]] || exit 1
builtin kill -TERM "$prefetch_pid"
for _ in $(seq 100); do
    kill -0 "$prefetch_pid" 2> /dev/null || break
    sleep 0.05
done
if kill -0 "$prefetch_pid" 2> /dev/null; then echo "STILL_RUNNING"; exit 1; fi
kill() { printf '%s\n' "$*" >> "$HOME/kill.calls"; builtin kill "$@"; }
: > "$HOME/kill.calls"
stop_project_cache_prefetch
if grep -q -- "$prefetch_pid" "$HOME/kill.calls"; then echo "SIGNALLED"; exit 1; fi
echo NOT_SIGNALLED
EOF
    rm -f "$HOME/kill.calls" "$HOME/discovering"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *NOT_SIGNALLED* ]] || return 1
}

@test "scan_project_cache_roots returns an interrupt that arrives before any root is queued" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
discover_project_cache_roots() { printf '%s\n' "$HOME"; }
project_cache_root_is_walkable() { return 130; }
manifest="$HOME/interrupted.manifest"
: > "$manifest"
rc=0
scan_project_cache_roots "$manifest" || rc=$?
[[ "$rc" == 130 ]] || { echo "RC:$rc"; exit 1; }
[[ ! -s "$manifest" ]] || { echo "MANIFEST_WRITTEN"; exit 1; }
echo INTERRUPTED
EOF
    rm -f "$HOME/interrupted.manifest"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *INTERRUPTED* ]] || return 1
}

@test "mo clean starts the project cache scan before its first section and stops it on exit" {
    local clean_source="$PROJECT_ROOT/bin/clean.sh"
    local code
    code=$(grep -vE '^[[:space:]]*#' "$clean_source")
    local start_line first_section_line
    start_line=$(grep -n 'start_project_cache_prefetch$' <<< "$code" | head -1 | cut -d: -f1)
    first_section_line=$(grep -n 'start_section "System"' <<< "$code" | head -1 | cut -d: -f1)
    [[ -n "$start_line" && -n "$first_section_line" ]] || return 1
    [ "$start_line" -lt "$first_section_line" ] || return 1
    [ "$(grep -c 'stop_project_cache_prefetch' <<< "$code")" -ge 2 ] || return 1
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
    [[ "$output" == *"1 dir,"* ]] || return 1
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

@test "clean_project_caches keeps a project cache whose Git listing cannot finish" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
mkdir -p "$HOME/Projects/app/.dart_tool" "$HOME/Projects/py/pkg/__pycache__"
touch "$HOME/Projects/app/pubspec.yaml" "$HOME/Projects/py/pyproject.toml"
touch "$HOME/Projects/py/pkg/__pycache__/module.pyc"
git init -q "$HOME/Projects"
mole_git_ls_files() { return 124; }
log_operation() { printf 'LOG:%s|%s\n' "$3" "$4" >> "$HOME/oplog"; }
DRY_RUN=false
clean_project_caches
[[ -d "$HOME/Projects/app/.dart_tool" ]] || exit 11
[[ -f "$HOME/Projects/py/pkg/__pycache__/module.pyc" ]] || exit 12
grep -q 'git status unknown' "$HOME/oplog" || exit 13
! grep -q 'tracked by git' "$HOME/oplog" || exit 14
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "project cache final guard rejects changed Git evidence after sizing" {
    local failures=0
    for route in main fallback python preview; do
        for change in tracked nested unknown signal normal; do
            run env HOME="$BATS_TEST_TMPDIR/$route-$change" PROJECT_ROOT="$PROJECT_ROOT" ROUTE="$route" CHANGE="$change" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME/repo/cache"
printf 'authored fixture\n' > "$HOME/repo/cache/payload"
git init -q "$HOME/repo"
if [[ "$ROUTE" == main ]]; then
    source "$PROJECT_ROOT/bin/clean.sh"
else
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/caches.sh"
fi
DRY_RUN=false
[[ "$ROUTE" != preview ]] || DRY_RUN=true
_project_cache_git_index=$'\nC'"$HOME/repo/cache"$'\n'
eval "original_$(declare -f mole_git_ls_files)"
mole_git_ls_files() {
    if [[ -f "$HOME/sized" ]]; then
        [[ "$CHANGE" != unknown ]] || return 124
        [[ "$CHANGE" != signal ]] || return 130
    fi
    original_mole_git_ls_files "$@"
}
get_path_size_kb() {
    touch "$HOME/sized"
    case "$CHANGE" in
        tracked) git -C "$HOME/repo" add -f cache/payload ;;
        nested) git init -q "$HOME/repo/cache/nested" ;;
    esac
    echo 1
}
# The clean command uses reclaim sizing; standalone callers use occupancy.
# Mutate evidence at the actual size boundary for either route.
get_cleanup_path_size_kb() { get_path_size_kb "$@"; }
record_dry_run_cleanup_target() { printf '%s\n' "$1" >> "$HOME/preview"; }
rc=0
case "$ROUTE" in
    python|preview) clean_python_bytecode_cache_group "$HOME/repo" "$HOME/repo/cache" || rc=$? ;;
    *) clean_project_cache_target "$HOME/repo/cache" "fixture cache" || rc=$? ;;
esac
[[ -f "$HOME/sized" ]] || exit 10
if [[ "$CHANGE" == normal ]]; then
    if [[ "$ROUTE" == preview ]]; then
        [[ -s "$HOME/preview" ]] || exit 11
    else
        [[ ! -e "$HOME/repo/cache" ]] || exit 12
    fi
else
    [[ -f "$HOME/repo/cache/payload" ]] || exit 13
    [[ ! -e "$HOME/preview" ]] || exit 14
fi
if [[ "$CHANGE" == signal ]]; then
    [[ "$rc" -eq 130 ]] || exit 15
else
    [[ "$rc" -eq 0 ]] || exit 16
fi
EOF
            [ "$status" -eq 0 ] || { echo "$route/$change: $output (status $status)"; failures=$((failures + 1)); }
        done
    done
    [ "$failures" -eq 0 ]
}

@test "project cache final sink rechecks files directories and later cancellation" {
    for route in main fallback python; do
        run env HOME="$BATS_TEST_TMPDIR/$route" PROJECT_ROOT="$PROJECT_ROOT" ROUTE="$route" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME/repo/cache" "$HOME/repo/later"
printf 'fixture' > "$HOME/repo/cache/payload"
printf 'next cache' > "$HOME/repo/later/payload"
printf 'standalone' > "$HOME/repo/file"
git init -q "$HOME/repo"
if [[ "$ROUTE" == main ]]; then
    source "$PROJECT_ROOT/bin/clean.sh"
else
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/caches.sh"
fi
DRY_RUN=false
_project_cache_git_index=$'\nC'"$HOME/repo/cache"$'\nC'"$HOME/repo/later"$'\nC'"$HOME/repo/file"$'\n'
eval "original_$(declare -f safe_remove)"
safe_remove() {
    printf '%s\n' "$1" >> "$HOME/sinks"
    git -C "$HOME/repo" add -f cache/payload file
    original_safe_remove "$@"
}
if [[ "$ROUTE" == python ]]; then
    clean_python_bytecode_cache_group "$HOME/repo" "$HOME/repo/cache"
else
    clean_project_cache_target "$HOME/repo/cache" "$HOME/repo/file" fixture
fi
[[ -s "$HOME/sinks" && -f "$HOME/repo/cache/payload" && -f "$HOME/repo/file" ]] || exit 11
# The first sink is cancelled; the otherwise disposable later cache must stay.
safe_remove() {
    printf '%s\n' "$1" >> "$HOME/cancel-sinks"
    return 130
}
git -C "$HOME/repo" rm --cached -q cache/payload file
rc=0
if [[ "$ROUTE" == python ]]; then
    clean_python_bytecode_cache_group "$HOME/repo" "$HOME/repo/cache" "$HOME/repo/later" || rc=$?
else
    clean_project_cache_target "$HOME/repo/cache" "$HOME/repo/later" fixture || rc=$?
fi
[[ "$rc" -eq 130 ]] || exit 12
[[ "$(cat "$HOME/cancel-sinks")" == "$HOME/repo/cache" ]] || exit 13
[[ -f "$HOME/repo/later/payload" ]] || exit 14
EOF
        [ "$status" -eq 0 ] || { echo "$route: $output (status $status)"; return 1; }
    done
}

@test "clean_project_caches batches Git discovery and rechecks each deletion" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/Projects/mono"
for pkg in a b c d e f; do
    mkdir -p "$repo/svc/$pkg/__pycache__"
    touch "$repo/svc/$pkg/__pycache__/m.pyc"
done
touch "$repo/svc/pyproject.toml"
git init -q "$repo"
git -C "$repo" add -f svc/c/__pycache__/m.pyc
eval "real_$(declare -f mole_git_ls_files)"
mole_git_ls_files() { printf '%s\n' "$3|${*: -1}" >> "$HOME/ls-files.calls"; real_mole_git_ls_files "$@"; }
DRY_RUN=false
clean_project_caches
[[ "$(grep -Fxc "$repo|." "$HOME/ls-files.calls")" == 1 ]] || { cat "$HOME/ls-files.calls"; exit 11; }
[[ -f "$repo/svc/c/__pycache__/m.pyc" ]] || exit 12
for pkg in a b d e f; do
    [[ ! -e "$repo/svc/$pkg/__pycache__" ]] || exit 13
    grep -Fxq "$repo|:(top,literal,icase)svc/$pkg/__pycache__" "$HOME/ls-files.calls" || exit 14
done
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches keeps tracked Next.js cache files and Flutter build beside a kept .dart_tool" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/Projects/site"
mkdir -p "$repo/web/.next/cache/images" "$repo/flutter/.dart_tool" "$repo/flutter/build"
touch "$repo/web/package.json" "$repo/flutter/pubspec.yaml"
printf 'pinned' > "$repo/web/.next/cache/fixture.json"
touch "$repo/web/.next/cache/images/a.webp" "$repo/flutter/build/out.bin"
printf '{}' > "$repo/flutter/.dart_tool/package_config.json"
git init -q "$repo"
git -C "$repo" add -f web/.next/cache/fixture.json flutter/.dart_tool/package_config.json
DRY_RUN=false
clean_project_caches
# A tracked file directly under .next/cache stays; its untracked sibling goes.
[[ -f "$repo/web/.next/cache/fixture.json" ]] || exit 11
[[ ! -e "$repo/web/.next/cache/images" ]] || exit 12
# build/ is Flutter output only beside a disposable .dart_tool.
[[ -f "$repo/flutter/.dart_tool/package_config.json" ]] || exit 13
[[ -f "$repo/flutter/build/out.bin" ]] || exit 14
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches stops on a signal during the Git listing" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
mkdir -p "$HOME/Projects/py/pkg/__pycache__"
touch "$HOME/Projects/py/pyproject.toml" "$HOME/Projects/py/pkg/__pycache__/m.pyc"
git init -q "$HOME/Projects/py"
mole_git_ls_files() { return 130; }
DRY_RUN=false
rc=0
clean_project_caches || rc=$?
printf 'RC=%s\n' "$rc"
[[ -f "$HOME/Projects/py/pkg/__pycache__/m.pyc" ]] || exit 11
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=130"* ]] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches treats a Git fatal error as unknown, not as a cancellation" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
# A linked worktree whose main repository is gone: git exits 128 here.
mkdir -p "$HOME/Projects/stale/pkg/__pycache__" "$HOME/Projects/good/pkg/__pycache__"
printf 'gitdir: /nonexistent/repo/.git/worktrees/stale\n' > "$HOME/Projects/stale/.git"
touch "$HOME/Projects/stale/pyproject.toml" "$HOME/Projects/stale/pkg/__pycache__/a.pyc"
touch "$HOME/Projects/good/pyproject.toml" "$HOME/Projects/good/pkg/__pycache__/b.pyc"
git init -q "$HOME/Projects/good"
DRY_RUN=false
rc=0
clean_project_caches || rc=$?
printf 'RC=%s\n' "$rc"
[[ -f "$HOME/Projects/stale/pkg/__pycache__/a.pyc" ]] || exit 11
[[ ! -e "$HOME/Projects/good/pkg/__pycache__" ]] || exit 12
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=0"* ]] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches keeps a tracked cache under a decomposed folder name" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/Projects/repo"
# "Cafe" plus U+0301: the decomposed spelling a disk can keep while Git lists
# the precomposed one.
dir="$repo/Cafe"$'\xcc\x81'
mkdir -p "$dir/__pycache__"
touch "$repo/pyproject.toml" "$dir/__pycache__/committed.pyc"
git init -q "$repo"
git -C "$repo" config core.precomposeunicode true
git -C "$repo" add -f .
DRY_RUN=false
clean_project_caches
[[ -f "$dir/__pycache__/committed.pyc" ]] || exit 11
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches keeps the target of a linked .next/cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
other="$HOME/Other/data"
mkdir -p "$other" "$HOME/Projects/web/.next"
printf 'tracked elsewhere' > "$other/fixture.json"
git init -q "$HOME/Other"
git -C "$HOME/Other" add -f data/fixture.json
touch "$HOME/Projects/web/package.json"
ln -s "$other" "$HOME/Projects/web/.next/cache"
git init -q "$HOME/Projects/web"
DRY_RUN=false
clean_project_caches
[[ -f "$other/fixture.json" ]] || exit 11
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects" "$HOME/Other"
}

@test "clean_project_caches keeps a Flutter build/ that holds a nested repository" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
app="$HOME/Projects/app"
mkdir -p "$app/.dart_tool" "$app/build/plugins/local_plugin/lib"
touch "$app/pubspec.yaml" "$app/.dart_tool/state" "$app/build/plugins/local_plugin/lib/main.dart"
git init -q "$app"
git init -q "$app/build/plugins/local_plugin"
DRY_RUN=false
clean_project_caches
[[ ! -e "$app/.dart_tool" ]] || exit 11
[[ -d "$app/build/plugins/local_plugin/.git" ]] || exit 12
[[ -f "$app/build/plugins/local_plugin/lib/main.dart" ]] || exit 13
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "clean_project_caches keeps a Flutter build/ whose nested repository check cannot finish" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
app="$HOME/Projects/app"
mkdir -p "$app/.dart_tool" "$app/build"
touch "$app/pubspec.yaml" "$app/.dart_tool/state" "$app/build/out.bin"
git init -q "$app"
eval "real_$(declare -f run_with_timeout)"
run_with_timeout() {
    # Only the nested-repository probe times out; discovery still runs.
    if [[ "$2" == find && "$*" == *"/build -mindepth 1 -name .git -print -quit"* ]]; then
        return 124
    fi
    real_run_with_timeout "$@"
}
DRY_RUN=false
clean_project_caches
[[ ! -e "$app/.dart_tool" ]] || exit 11
[[ -f "$app/build/out.bin" ]] || exit 12
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    rm -rf "$HOME/Projects"
}

@test "project cache index gives no free pass to a path it never saw" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
index="$HOME/index"
printf 'C/p/clear\nT/p/tracked\nU/p/unknown\n' > "$index"
_project_cache_git_index=$'\n'"$(cat "$index")"$'\n'
rc=0; project_cache_git_status /p/clear || rc=$?; [[ $rc -eq 1 ]] || exit 11
rc=0; project_cache_git_status /p/tracked || rc=$?; [[ $rc -eq 0 ]] || exit 12
rc=0; project_cache_git_status /p/unknown || rc=$?; [[ $rc -eq 2 ]] || exit 13
rc=0; project_cache_git_status /p/new || rc=$?; [[ $rc -eq 2 ]] || exit 14
# A prefix of an indexed path is not that path.
rc=0; project_cache_git_status /p/clea || rc=$?; [[ $rc -eq 2 ]] || exit 15
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "clean_project_caches gives every recheck its own bound, so real cleaning matches the preview" {
    local mode cost
    for cost in walk git; do
        for mode in real dry; do
            run env HOME="$BATS_TEST_TMPDIR/bound-$cost-$mode" PROJECT_ROOT="$PROJECT_ROOT" MODE="$mode" COST="$cost" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/Projects/mono"
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    mkdir -p "$repo/svc/p$n/__pycache__"
    touch "$repo/svc/p$n/__pycache__/m.pyc"
done
mkdir -p "$repo/svc/keep/__pycache__"
touch "$repo/svc/keep/__pycache__/m.pyc" "$repo/svc/pyproject.toml"
git init -q "$repo"
git -C "$repo" add -f svc/keep/__pycache__/m.pyc
DRY_RUN=false
[[ "$MODE" != dry ]] || DRY_RUN=true
record_dry_run_cleanup_target() { printf '%s\n' "$1" >> "$HOME/preview"; }
# Every recheck costs simulated seconds, in its Git half or in its nested
# repository walk. One 15 s budget for the whole step is spent after a few
# deletions, and every later candidate was then kept.
if [[ "$COST" == git ]]; then
    eval "real_$(declare -f _mole_snapshot_path_identity)"
    _mole_snapshot_path_identity() { SECONDS=$((SECONDS + 1)); real__mole_snapshot_path_identity "$@"; }
else
    eval "real_$(declare -f _project_cache_holds_nested_repo)"
    _project_cache_holds_nested_repo() { SECONDS=$((SECONDS + 2)); real__project_cache_holds_nested_repo "$@"; }
fi
clean_project_caches
[[ -f "$repo/svc/keep/__pycache__/m.pyc" ]] || exit 11
handled=0
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    dir="$repo/svc/p$n/__pycache__"
    if [[ "$MODE" == dry ]]; then
        ! grep -Fxq "$dir" "$HOME/preview" || handled=$((handled + 1))
    else
        [[ -e "$dir" ]] || handled=$((handled + 1))
    fi
done
[[ "$handled" -eq 12 ]] || { echo "$COST/$MODE handled $handled of 12"; exit 12; }
EOF
            [ "$status" -eq 0 ] || { echo "$cost/$mode: status $status: $output"; return 1; }
        done
    done
}

@test "clean_project_caches builds each root's Git index on a fresh budget" {
    run env HOME="$BATS_TEST_TMPDIR/index-bound" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
for root in Projects Code; do
    repo="$HOME/$root/app"
    mkdir -p "$repo/pkg/__pycache__"
    touch "$repo/pyproject.toml" "$repo/pkg/__pycache__/m.pyc"
    git init -q "$repo"
done
DRY_RUN=false
# Time spent on the first root must not leave the second one's listing with an
# expired budget, which kept every one of its caches.
eval "real_$(declare -f process_project_cache_matches)"
passes=0
process_project_cache_matches() {
    passes=$((passes + 1))
    [[ $passes -ne 2 ]] || SECONDS=$((SECONDS + 20))
    real_process_project_cache_matches "$@"
}
clean_project_caches
[[ "$passes" -eq 2 ]] || exit 11
[[ ! -e "$HOME/Projects/app/pkg/__pycache__" ]] || exit 12
[[ ! -e "$HOME/Code/app/pkg/__pycache__" ]] || exit 13
EOF
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
}

@test "clean_project_caches skips a refused .next/cache child and still cleans its siblings" {
    local mode
    for mode in real dry; do
        run env HOME="$BATS_TEST_TMPDIR/next-$mode" PROJECT_ROOT="$PROJECT_ROOT" MODE="$mode" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
repo="$HOME/Projects/web"
cache="$repo/.next/cache"
mkdir -p "$cache/a" "$cache/c" "$cache/d/inner" "$cache/e" "$cache/f" "$HOME/Other"
touch "$cache/a/x" "$cache/c/x" "$cache/e/x" "$cache/f/x" "$HOME/Other/data"
# b is a link out of the project and d holds an authored repository: the guard
# refuses each of them by name, and the children after them are still caches.
ln -s "$HOME/Other" "$cache/b"
git init -q "$repo"
git init -q "$cache/d/inner"
DRY_RUN=false
[[ "$MODE" != dry ]] || DRY_RUN=true
files_cleaned=0
total_size_cleaned=0
total_items=0
record_dry_run_cleanup_target() { printf '%s\n' "$1" >> "$HOME/preview"; }
rc=0
clean_project_cache_target "$cache"/* "Next.js build cache" || rc=$?
[[ "$rc" -eq 0 ]] || exit 11
[[ -L "$cache/b" && -f "$HOME/Other/data" && -d "$cache/d/inner/.git" ]] || exit 12
for child in a c e f; do
    if [[ "$MODE" == dry ]]; then
        [[ -d "$cache/$child" ]] || exit 13
        grep -Fxq "$cache/$child" "$HOME/preview" || exit 14
    else
        [[ ! -e "$cache/$child" ]] || exit 15
    fi
done
if [[ "$MODE" == dry ]]; then
    [[ "$(grep -c . "$HOME/preview")" -eq 4 ]] || exit 16
fi
EOF
        [ "$status" -eq 0 ] || { echo "$mode: status $status: $output"; return 1; }
    done
}

@test "project cache removal timeouts count one failed removal while a signal still stops the run" {
    local route rm_rc
    for route in python fallback; do
        for rm_rc in 124 130; do
            run env HOME="$BATS_TEST_TMPDIR/rm-$route-$rm_rc" PROJECT_ROOT="$PROJECT_ROOT" ROUTE="$route" RM_RC="$rm_rc" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/repo"
mkdir -p "$repo/a/__pycache__" "$repo/b/__pycache__"
touch "$repo/a/__pycache__/m.pyc" "$repo/b/__pycache__/m.pyc"
DRY_RUN=false
# The first removal fails with the given status; later ones succeed.
safe_remove() {
    printf '%s\n' "$1" >> "$HOME/sinks"
    if [[ "$(wc -l < "$HOME/sinks")" -eq 1 ]]; then
        return "$RM_RC"
    fi
    /bin/rm -rf "$1"
}
rc=0
if [[ "$ROUTE" == python ]]; then
    clean_python_bytecode_cache_group "$repo" "$repo/a/__pycache__" "$repo/b/__pycache__" || rc=$?
else
    clean_project_cache_target "$repo/a/__pycache__" "$repo/b/__pycache__" fixture || rc=$?
fi
if [[ "$RM_RC" == 124 ]]; then
    [[ "$rc" -eq 0 ]] || exit 11
    [[ "$(wc -l < "$HOME/sinks")" -eq 2 ]] || exit 12
    [[ -d "$repo/a/__pycache__" && ! -e "$repo/b/__pycache__" ]] || exit 13
else
    [[ "$rc" -eq 130 ]] || exit 14
    [[ "$(wc -l < "$HOME/sinks")" -eq 1 ]] || exit 15
    [[ -d "$repo/b/__pycache__" ]] || exit 16
fi
EOF
            [ "$status" -eq 0 ] || { echo "$route/$rm_rc: status $status: $output"; return 1; }
        done
    done
}

@test "project cache Git evidence survives a case-only folder rename" {
    run env HOME="$BATS_TEST_TMPDIR/case" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
repo="$HOME/Projects/repo"
mkdir -p "$repo/Svc/p/__pycache__" "$repo/Svc/q/__pycache__"
touch "$repo/pyproject.toml" "$repo/Svc/p/__pycache__/m.pyc" "$repo/Svc/q/__pycache__/n.pyc"
git init -q "$repo"
git -C "$repo" add -f Svc/p/__pycache__/m.pyc
# A plain mv leaves the index with the old spelling and git status clean.
/bin/mv "$repo/Svc" "$repo/svc"
cache="$repo/svc/p/__pycache__"

# Discovery: the listing prefix and the spelling on disk differ only in case.
printf '%s\t%s\n' "$HOME/Projects" "$cache" > "$HOME/matches"
project_cache_build_git_index "$HOME/matches" "$HOME/index" "$((SECONDS + 15))"
grep -Fxq "T$cache" "$HOME/index" || { cat "$HOME/index"; exit 11; }

# The recheck must not trust a stale clear verdict either.
_project_cache_git_index=$'\nC'"$cache"$'\n'
rc=0
_project_cache_final_guard "$cache" || rc=$?
[[ "$rc" -ne 0 ]] || exit 12
rc=0
mole_path_has_git_tracked_files "$cache" || rc=$?
[[ "$rc" -eq 0 ]] || exit 13
# An inherited literal-pathspec switch would turn the case-blind spec into plain
# text that matches nothing, so the query must not honor it.
rc=0
GIT_LITERAL_PATHSPECS=1 mole_path_has_git_tracked_files "$cache" || rc=$?
[[ "$rc" -eq 0 ]] || exit 16
rc=0
GIT_LITERAL_PATHSPECS=1 _project_cache_final_guard "$cache" || rc=$?
[[ "$rc" -ne 0 ]] || exit 17
_project_cache_git_index=""

# Positive control: the untracked sibling under the same renamed folder is
# still a cache, so the keep above is evidence and not a blanket refusal.
DRY_RUN=false
clean_project_caches
[[ -f "$cache/m.pyc" ]] || exit 14
[[ ! -e "$repo/svc/q/__pycache__" ]] || exit 15
EOF
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
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
FIND_BSD=find  # route the scan through the stub
run_with_timeout() { shift; "$@"; }
safe_clean() { echo "$2|$1"; }
safe_clean_guarded() { shift; safe_clean "$@"; }
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
safe_clean_guarded() { shift; safe_clean "$@"; }
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
safe_clean_guarded() { shift; safe_clean "$@"; }
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
FIND_BSD=find  # route the scan through the stub
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
FIND_BSD=find  # route the scan through the stub
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
    (( elapsed < 5 )) || return 1
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

@test "clean_project_caches reaps a worker interrupted before PID registration" {
	local scan_home="$HOME/interrupted-scan-registration"
	mkdir -p "$scan_home/root"
	mkfifo "$scan_home/worker-gate" "$scan_home/worker-ready"

	run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
exec 3<> "$HOME/worker-gate"
exec 4<> "$HOME/worker-ready"
discover_project_cache_roots() { printf '%s\n' "$HOME/root"; }
get_optimal_parallel_jobs() { printf '1\n'; }
armed=false
previous_pid=""
project_cache_root_is_walkable() {
	previous_pid="${!:-}"
	armed=true
	return 0
}
scan_project_cache_root() {
	: > "$2"
	trap 'exit 143' TERM
	printf 'ready\n' >&4
	# A watchdog bounds the broken path; cancellation should interrupt this read immediately.
	IFS= read -r -t 10 -u 3 release || true
	touch "$HOME/worker-survived"
}
process_project_cache_matches() { :; }
interrupt_new_worker() {
	# DEBUG observes the new $! before the parent's next command can register it.
	# Subshells inherit the trap but must not signal the owning shell themselves.
	if [[ $BASH_SUBSHELL -eq 0 && $armed == true && -n "${!:-}" && "${!:-}" != "$previous_pid" ]]; then
		armed=false
		IFS= read -r -t 10 -u 4 ready || exit 1
		touch "$HOME/window-hit"
		kill -TERM "$$"
	fi
	return 0
}
set -T
trap interrupt_new_worker DEBUG
clean_rc=0
clean_project_caches || clean_rc=$?
trap - DEBUG
printf 'RC=%s WINDOW=%s SURVIVED=%s\n' "$clean_rc" \
	"$([[ -e "$HOME/window-hit" ]] && printf yes || printf no)" \
	"$([[ -e "$HOME/worker-survived" ]] && printf yes || printf no)"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "RC=143 WINDOW=yes SURVIVED=no" ]] || return 1
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
FIND_BSD=find  # route the scan through the stub
SECONDS=0
scan_rc=0
scan_project_cache_root "$HOME/Projects" "$OUTPUT_FILE" || scan_rc=$?
printf 'STATUS=%s ELAPSED=%s BYTES=%s\n' \
	"$scan_rc" "$SECONDS" "$(wc -c < "$OUTPUT_FILE" | tr -d ' ')"
EOF

	printf '%s\n' "$output" # shown only when this case fails, and it failed once on CI without it
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

@test "scan_project_cache_root prunes build outputs and package stores" {
    local name
    for name in target .build .gradle Index.noindex _cacache; do
        mkdir -p "$HOME/Projects/app/$name/sub/__pycache__"
        touch "$HOME/Projects/app/$name/sub/__pycache__/mod.pyc"
    done
    mkdir -p "$HOME/Projects/app/__pycache__"
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
    for name in target .build .gradle Index.noindex _cacache; do
        [[ "$output" != *"/$name/"* ]] || return 1
    done

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

@test "project cache and hint scans ignore a failing find earlier in PATH" {
    local stub_bin="$HOME/gnu-find-scan-bin"
    local root="$HOME/gnu-scan-root"
    mkdir -p "$stub_bin" "$root/app/.next" "$root/other"
    # GNU find failed on a File Provider mount BSD find walks past, and the
    # whole root was then counted as a failed scan.
    printf '#!/bin/bash\necho "find: Operation timed out" >&2\nexit 1\n' > "$stub_bin/find"
    chmod +x "$stub_bin/find"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stub_bin:$PATH" ROOT="$root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
rc=0
scan_project_cache_root "$ROOT" "$HOME/gnu-scan.out" || rc=$?
echo "SCAN_RC=$rc"
cat "$HOME/gnu-scan.out"
rc=0
hint_collect_child_dirs_with_timeout "$ROOT" "$HOME/gnu-children.out" 5 || rc=$?
echo "HINT_RC=$rc"
tr '\0' '\n' < "$HOME/gnu-children.out"
EOF
    rm -rf "$stub_bin" "$root"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SCAN_RC=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"$root/app/.next"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"HINT_RC=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"$root/other"* ]] || { echo "$output"; return 1; }
}
