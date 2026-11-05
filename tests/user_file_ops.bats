#!/usr/bin/env bats

load helpers/common


setup_file() {
    mole_test_setup_home userfile
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
    rm -rf "$HOME/.config" "$HOME/.cache"
    mkdir -p "$HOME"
}

@test "is_root_user detects non-root correctly" {
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_root_user && echo 'root' || echo 'not-root'")
    [ "$result" = "not-root" ]
}

@test "get_invoking_uid returns numeric UID" {
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_uid")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_invoking_gid returns numeric GID" {
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_gid")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_invoking_home returns home directory" {
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_home")
    [ -n "$result" ]
    [ -d "$result" ]
}

@test "prepare_mole_tmpdir uses writable TMPDIR when available" {
    local writable_tmp="$HOME/custom-tmp"
    mkdir -p "$writable_tmp"

    result=$(env HOME="$HOME" TMPDIR="$writable_tmp" /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; prepare_mole_tmpdir")
    [ "$result" = "$writable_tmp" ]
}

@test "prepare_mole_tmpdir falls back to user cache when TMPDIR is not writable" {
    local blocked_tmp="$HOME/blocked-tmp"
    mkdir -p "$blocked_tmp"
    chmod 500 "$blocked_tmp"

    result=$(env HOME="$HOME" TMPDIR="$blocked_tmp" /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; prepare_mole_tmpdir")
    [ "$result" = "$HOME/.cache/mole/tmp" ]
    [ -d "$HOME/.cache/mole/tmp" ]
}

@test "ensure_mole_temp_root caches the first resolved directory" {
    local first_tmp="$HOME/first-tmp"
    local second_tmp="$HOME/second-tmp"
    mkdir -p "$first_tmp" "$second_tmp"

    result=$(env HOME="$HOME" TMPDIR="$first_tmp" /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_mole_temp_root
        first=\$MOLE_RESOLVED_TMPDIR
        export TMPDIR='$second_tmp'
        ensure_mole_temp_root
        second=\$MOLE_RESOLVED_TMPDIR
        printf '%s|%s\n' \"\$first\" \"\$second\"
    ")

    [ "$result" = "$first_tmp|$first_tmp" ]
}

@test "cleanup_temp_files removes command-substitution temp files (#1203)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

MOLE_RESOLVED_TMPDIR="$HOME/.cache/mole/tmp"
MOLE_TEMP_REGISTRY_FILE=""
export MOLE_RESOLVED_TMPDIR MOLE_TEMP_REGISTRY_FILE
mkdir -p "$MOLE_RESOLVED_TMPDIR"

temp_file=$(mktemp_file "subshell")
printf 'BEFORE:%s\n' "$([[ -f "$temp_file" ]] && echo exists || echo missing)"
cleanup_temp_files
printf 'AFTER:%s\n' "$([[ -f "$temp_file" ]] && echo leaked || echo cleaned)"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"BEFORE:exists"* ]] || return 1
    [[ "$output" == *"AFTER:cleaned"* ]]
}

@test "a forked child does not adopt the parent temp registry" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

MOLE_RESOLVED_TMPDIR="$HOME/.cache/mole/tmp"
MOLE_TEMP_REGISTRY_FILE=""
export MOLE_RESOLVED_TMPDIR MOLE_TEMP_REGISTRY_FILE
mkdir -p "$MOLE_RESOLVED_TMPDIR"

# `mole` resolves the temp root at startup, so the registry path is exported
# from the main shell rather than from a command-substitution subshell.
ensure_mole_temp_root
parent_file=$(mktemp_file "parent-installer")
[[ -f "$parent_file" ]] || exit 1

# install.sh runs the freshly installed `mole --version` while `mo update`
# still holds its downloaded installer. That child inherits the exported
# registry path; adopting it would delete the parent's live temp files.
/bin/bash --noprofile --norc -c '
    source "$PROJECT_ROOT/lib/core/base.sh"
    printf "CHILD_ADOPTED:%s\n" "$MOLE_TEMP_REGISTRY_FILE"
    ensure_mole_temp_registry_file || exit 1
    printf "CHILD_OWNS:%s\n" "$MOLE_TEMP_REGISTRY_FILE"
    cleanup_temp_files
' || exit 1

printf 'PARENT_FILE:%s\n' "$([[ -f "$parent_file" ]] && echo kept || echo deleted)"
cleanup_temp_files
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PARENT_FILE:kept"* ]] || return 1
    child_adopted=$(printf '%s\n' "$output" | sed -n 's/^CHILD_ADOPTED://p')
    child_owns=$(printf '%s\n' "$output" | sed -n 's/^CHILD_OWNS://p')
    [[ -n "$child_adopted" && -n "$child_owns" ]] || return 1
    [ "$child_adopted" != "$child_owns" ]
}

@test "cleanup_temp_files rejects registry paths outside the temp root (#1203)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

MOLE_RESOLVED_TMPDIR="$HOME/.cache/mole/tmp"
MOLE_TEMP_REGISTRY_FILE="$MOLE_RESOLVED_TMPDIR/mole.registry.$$"
export MOLE_RESOLVED_TMPDIR MOLE_TEMP_REGISTRY_FILE
mkdir -p "$MOLE_RESOLVED_TMPDIR"

persistent_file="$HOME/.cache/mole/installed_apps_cache"
touch "$persistent_file"
printf '%s\n' "$persistent_file" > "$MOLE_TEMP_REGISTRY_FILE"

cleanup_temp_files
[[ -e "$persistent_file" ]] || exit 1

invalid_registry="$HOME/.cache/mole/not-a-temp-registry"
printf '%s\n' "$persistent_file" > "$invalid_registry"
MOLE_TEMP_REGISTRY_FILE="$invalid_registry"
cleanup_temp_files
[[ -e "$invalid_registry" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "prune_stale_mole_temp_files leaves persistent cache and fresh temps alone (#1203)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEMP_STALE_MINUTES=60 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

temp_root="$HOME/.cache/mole/tmp"
old_temp="$temp_root/old-scan"
fresh_temp="$temp_root/current-scan"
old_spinner="$temp_root/.mole-spinner.old"
fresh_spinner="$temp_root/.mole-spinner.fresh"
persistent_cache="$HOME/.cache/mole/installed_apps_cache"
mkdir -p "$old_spinner" "$fresh_spinner"
touch "$old_temp" "$fresh_temp" "$persistent_cache"
touch "$old_spinner/message" "$fresh_spinner/message"
touch -t 202001010101 "$old_temp" "$old_spinner" "$persistent_cache"

prune_stale_mole_temp_files "$temp_root"

[[ ! -e "$old_temp" ]] || exit 1
[[ ! -e "$old_spinner" ]] || exit 1
[[ -e "$fresh_temp" ]] || exit 1
[[ -e "$fresh_spinner/message" ]] || exit 1
[[ -e "$persistent_cache" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "Darwin temp root prune takes only stale Mole registries and temp entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

darwin_root="$HOME/darwin-T"
other_root="$HOME/user-folder"
rm -rf "$darwin_root" "$other_root"
mkdir -p "$darwin_root" "$other_root"
_mole_darwin_user_temp_dir() { printf '%s/\n' "$darwin_root"; }

dead_pid=99990
while ps -p "$dead_pid" > /dev/null 2>&1; do dead_pid=$((dead_pid + 1)); done
fresh_dead_pid=$((dead_pid + 1))
while ps -p "$fresh_dead_pid" > /dev/null 2>&1; do fresh_dead_pid=$((fresh_dead_pid + 1)); done

old=()
for name in "mole.registry.$dead_pid" "mole.registry.$$" mole.AbC123 mole.hard01 \
    mole.probe.Ab12Cd mole.Ab12Cde mole-checksums.Ab12Cd notes.txt; do
    touch "$darwin_root/$name"
    old+=("$darwin_root/$name")
done
ln "$darwin_root/mole.hard01" "$darwin_root/hard-link"
mkdir -p "$darwin_root/mole.Empty1" "$darwin_root/mole.Full01" "$darwin_root/mole.OwnDir"
touch "$darwin_root/mole.Owned1"
old+=("$darwin_root/mole.Owned1" "$darwin_root/mole.OwnDir")
printf '%s\n' "$darwin_root/mole.Owned1" "$darwin_root/mole.OwnDir" > "$darwin_root/mole.registry.$$"
ln -s "$other_root/mole.Other1" "$darwin_root/mole.Link01"
touch -h -t 202001010101 "$darwin_root/mole.Link01"
touch "$darwin_root/mole.Full01/kept"
touch "$darwin_root/mole.Fresh1" "$darwin_root/mole.registry.$fresh_dead_pid" "$other_root/mole.Other1"
touch -t 202001010101 "${old[@]}" "$darwin_root/mole.Empty1" "$darwin_root/mole.Full01" "$other_root/mole.Other1"

prune_stale_mole_tmpdir_leftovers "$other_root"
[[ -e "$other_root/mole.Other1" ]] || exit 1

prune_stale_mole_tmpdir_leftovers "$darwin_root"
for gone in "mole.registry.$dead_pid" mole.AbC123 mole.Empty1; do
    [[ ! -e "$darwin_root/$gone" ]] || { echo "kept $gone"; exit 1; }
done
for kept in "mole.registry.$$" mole.hard01 mole.probe.Ab12Cd mole.Ab12Cde \
    mole-checksums.Ab12Cd notes.txt mole.Full01/kept mole.Fresh1 "mole.registry.$fresh_dead_pid" \
    mole.Owned1 mole.OwnDir mole.Link01; do
    [[ -e "$darwin_root/$kept" ]] || { echo "removed $kept"; exit 1; }
done
EOF

    [ "$status" -eq 0 ]
}

@test "Darwin temp root prune runs from temp root setup and keeps everything when ps fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

darwin_root="$HOME/darwin-T-setup"
rm -rf "$darwin_root"
mkdir -p "$darwin_root"
_mole_darwin_user_temp_dir() { printf '%s/\n' "$darwin_root"; }
touch "$darwin_root/mole.Stale1" "$darwin_root/mole.registry.99999999"
touch -t 202001010101 "$darwin_root/mole.Stale1" "$darwin_root/mole.registry.99999999"

ps() { return 1; }
prune_stale_mole_tmpdir_leftovers "$darwin_root"
echo "survived ps failure"
[[ -e "$darwin_root/mole.Stale1" && -e "$darwin_root/mole.registry.99999999" ]] || exit 1
unset -f ps

unset MOLE_RESOLVED_TMPDIR MOLE_TEMP_REGISTRY_FILE
TMPDIR="$darwin_root" ensure_mole_temp_root
[[ ! -e "$darwin_root/mole.Stale1" && ! -e "$darwin_root/mole.registry.99999999" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"survived ps failure"* ]]
}

@test "Darwin temp root prune lists the root once a day and only after a complete pass" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

darwin_root="$HOME/darwin-T-daily"
rm -rf "$darwin_root"
mkdir -p "$darwin_root"
_mole_darwin_user_temp_dir() { printf '%s/\n' "$darwin_root"; }

# A failed process listing proves nothing, so it must not stamp the day.
ps() { return 1; }
prune_stale_mole_tmpdir_leftovers "$darwin_root"
unset -f ps
[[ ! -e "$darwin_root/mole.prune-stamp" ]] || { echo "stamped after ps failure"; exit 1; }

touch "$darwin_root/mole.Stale1"
touch -t 202001010101 "$darwin_root/mole.Stale1"
prune_stale_mole_tmpdir_leftovers "$darwin_root"
[[ ! -e "$darwin_root/mole.Stale1" ]] || { echo "first pass kept a stale entry"; exit 1; }
[[ -f "$darwin_root/mole.prune-stamp" ]] || { echo "no stamp after a complete pass"; exit 1; }

# Within the day the root is not listed again.
touch "$darwin_root/mole.Stale2"
touch -t 202001010101 "$darwin_root/mole.Stale2"
prune_stale_mole_tmpdir_leftovers "$darwin_root"
[[ -e "$darwin_root/mole.Stale2" ]] || { echo "listed again within a day"; exit 1; }

# A day-old stamp lets the next run list it.
touch -t 202001010101 "$darwin_root/mole.prune-stamp"
prune_stale_mole_tmpdir_leftovers "$darwin_root"
[[ ! -e "$darwin_root/mole.Stale2" ]] || { echo "old stamp still skipped the pass"; exit 1; }
echo "daily ok"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"daily ok"* ]]
}

@test "Darwin temp root prune lists again when its stamp is from the future" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

darwin_root="$HOME/clock-darwin-temp"
mkdir -p "$darwin_root"
_mole_darwin_user_temp_dir() { printf '%s/\n' "$darwin_root"; }

touch "$darwin_root/mole.prune-stamp"
touch "$darwin_root/mole.Stale3"
touch -t 202001010101 "$darwin_root/mole.Stale3"
prune_stale_mole_tmpdir_leftovers "$darwin_root"
[[ -e "$darwin_root/mole.Stale3" ]] || { echo "recent stamp listed again"; exit 1; }

touch -t "$(date -v+2d +%Y%m%d%H%M)" "$darwin_root/mole.prune-stamp"
prune_stale_mole_tmpdir_leftovers "$darwin_root"
[[ ! -e "$darwin_root/mole.Stale3" ]] || { echo "future stamp skipped the pass"; exit 1; }
echo "prune-clock ok"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"prune-clock ok"* ]]
}

@test "Darwin temp root prune clears a backlog larger than one argument list" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

darwin_root="$HOME/darwin-T-backlog"
rm -rf "$darwin_root"
mkdir -p "$darwin_root"
_mole_darwin_user_temp_dir() { printf '%s/\n' "$darwin_root"; }

# 80,000 names exceed ARG_MAX when passed as operands (the limit falls
# between 50k and 70k on macOS), which once left the backlog untouched
# while the pass still stamped the day.
(cd "$darwin_root" && /usr/bin/seq -f 'mole.%06g' 100000 179999 |
    /usr/bin/xargs /usr/bin/touch -t 202001010101)
[[ "$(/bin/ls "$darwin_root" | /usr/bin/wc -l | tr -d ' ')" -eq 80000 ]] || { echo "fixture short"; exit 1; }
prune_stale_mole_tmpdir_leftovers "$darwin_root"
left=$(/usr/bin/find "$darwin_root" -mindepth 1 -maxdepth 1 -name 'mole.[0-9]*' | /usr/bin/wc -l | tr -d ' ')
[[ "$left" -eq 0 ]] || { echo "left=$left"; exit 1; }
[[ -f "$darwin_root/mole.prune-stamp" ]] || { echo "no stamp"; exit 1; }
echo "backlog ok"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"backlog ok"* ]]
}

@test "Darwin temp root prune removes nothing and leaves no stamp when the listing fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"

darwin_root="$HOME/darwin-T-listfail"
rm -rf "$darwin_root"
mkdir -p "$darwin_root"
_mole_darwin_user_temp_dir() { printf '%s/\n' "$darwin_root"; }
touch "$darwin_root/mole.Stale1"
touch -t 202001010101 "$darwin_root/mole.Stale1"

# The root listing fails partway: what it printed proves nothing.
failing_find() {
    printf 'O./mole.Stale1\n'
    return 1
}
FIND_BSD=failing_find
prune_stale_mole_tmpdir_leftovers "$darwin_root"
FIND_BSD=/usr/bin/find
[[ -e "$darwin_root/mole.Stale1" ]] || { echo "removed after a failed listing"; exit 1; }
[[ ! -e "$darwin_root/mole.prune-stamp" ]] || { echo "stamped after a failed listing"; exit 1; }
echo "listing ok"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"listing ok"* ]]
}

@test "prepare_mole_tmpdir falls back to /tmp when TMPDIR and invoking home are unavailable" {
    result=$(env HOME="$HOME" TMPDIR="/var/empty" /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        get_invoking_home() { echo '/var/empty'; }
        prepare_mole_tmpdir
    ")

    [ "$result" = "/tmp" ]
}

@test "common.sh exports resolved TMPDIR for runtime callers" {
    local blocked_tmp="$HOME/common-blocked-tmp"
    mkdir -p "$blocked_tmp"
    chmod 500 "$blocked_tmp"

    result=$(env HOME="$HOME" TMPDIR="$blocked_tmp" /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; printf '%s\n' \"\$TMPDIR\"")
    [ "$result" = "$HOME/.cache/mole/tmp" ]
}

@test "get_user_home returns home for valid user" {
    current_user="${USER:-$(whoami)}"
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_user_home '$current_user'")
    [ -n "$result" ]
    [ -d "$result" ]
}

@test "get_user_home returns empty for invalid user" {
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_user_home 'nonexistent_user_12345'")
    [ -z "$result" ] || [ "$result" = "~nonexistent_user_12345" ]
}

@test "ensure_user_dir creates simple directory" {
    test_dir="$HOME/.cache/test"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir creates nested directory" {
    test_dir="$HOME/.config/mole/deep/nested/path"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir handles tilde expansion" {
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '~/.cache/tilde-test'"
    [ -d "$HOME/.cache/tilde-test" ]
}

@test "ensure_user_dir is idempotent" {
    test_dir="$HOME/.cache/idempotent"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir handles empty path gracefully" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir ''"
    [ "$status" -eq 0 ]
}

@test "ensure_user_dir preserves ownership for non-root users" {
    test_dir="$HOME/.cache/ownership-test"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"

    current_uid=$(id -u)
    dir_uid=$(/usr/bin/stat -f%u "$test_dir")
    [ "$dir_uid" = "$current_uid" ]
}


@test "ensure_user_file creates file and parent directories" {
    test_file="$HOME/.config/mole/test.log"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
    [ -d "$(dirname "$test_file")" ]
}

@test "ensure_user_file handles tilde expansion" {
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '~/.cache/tilde-file.txt'"
    [ -f "$HOME/.cache/tilde-file.txt" ]
}

@test "ensure_user_file is idempotent" {
    test_file="$HOME/.cache/idempotent.txt"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    echo "content" > "$test_file"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
    [ "$(cat "$test_file")" = "content" ]
}

@test "ensure_user_file handles empty path gracefully" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file ''"
    [ "$status" -eq 0 ]
}

@test "ensure_user_file creates deeply nested files" {
    test_file="$HOME/.config/deep/very/nested/structure/file.log"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
}

@test "ensure_user_file preserves ownership for non-root users" {
    test_file="$HOME/.cache/file-ownership-test.txt"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"

    current_uid=$(id -u)
    file_uid=$(/usr/bin/stat -f%u "$test_file")
    [ "$file_uid" = "$current_uid" ]
}

@test "ensure_user_dir early stop optimization works" {
    test_dir="$HOME/.cache/perf/test/nested"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"

    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]

    current_uid=$(id -u)
    dir_uid=$(/usr/bin/stat -f%u "$test_dir")
    [ "$dir_uid" = "$current_uid" ]
}

@test "ensure_user_dir and ensure_user_file work together" {
    cache_dir="$HOME/.cache/mole"
    cache_file="$cache_dir/integration_test.log"

    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$cache_dir'"
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$cache_file'"

    [ -d "$cache_dir" ]
    [ -f "$cache_file" ]
}

@test "multiple ensure_user_file calls in same directory" {
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_user_file '$HOME/.config/mole/file1.txt'
        ensure_user_file '$HOME/.config/mole/file2.txt'
        ensure_user_file '$HOME/.config/mole/file3.txt'
    "

    [ -f "$HOME/.config/mole/file1.txt" ]
    [ -f "$HOME/.config/mole/file2.txt" ]
    [ -f "$HOME/.config/mole/file3.txt" ]
}

@test "ensure functions handle concurrent calls safely" {
    /bin/bash -c "source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_user_dir '$HOME/.cache/concurrent' &
        ensure_user_dir '$HOME/.cache/concurrent' &
        wait
    "

    [ -d "$HOME/.cache/concurrent" ]
}


@test "log append avoids repeat setup and recreates a removed log" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
fixture=$(mktemp -d "$HOME/log-append.XXXXXX")
touch "$fixture/events"
ensure_user_file() { echo setup >> "$fixture/setups"; mkdir -p "${1%/*}"; touch "$1"; }
id() { echo id >> "$fixture/id-calls"; command id "$@"; }
append_log_line "$fixture/events" first
[[ ! -e "$fixture/id-calls" ]] || exit 1
command rm -f "$fixture/events"
append_log_line "$fixture/events" second
[[ $(wc -l < "$fixture/setups") -eq 1 ]] || exit 1
[[ "$(cat "$fixture/events")" == second ]] || exit 1
printf 'recreated-without-repeat-setup\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"recreated-without-repeat-setup"* ]]
}

@test "Bats helper isolates inherited temp roots and registries" {
    run env PROJECT_ROOT="$PROJECT_ROOT" BATS_FILE_TMPDIR="$BATS_TEST_TMPDIR/isolated-file" \
        TMPDIR="$BATS_TEST_TMPDIR/ambient" MOLE_RESOLVED_TMPDIR="$BATS_TEST_TMPDIR/ambient" \
        MOLE_TEMP_REGISTRY_FILE="$BATS_TEST_TMPDIR/ambient/mole.registry.parent" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p "$TMPDIR" "$BATS_FILE_TMPDIR"
ambient="$TMPDIR"
printf sentinel > "$MOLE_TEMP_REGISTRY_FILE"
source "$PROJECT_ROOT/tests/helpers/common.bash"
source "$PROJECT_ROOT/lib/core/base.sh"
temp_file=$(create_temp_file)
[[ "$temp_file" == "$BATS_FILE_TMPDIR/"* ]] || exit 1
[[ "${MOLE_TEMP_REGISTRY_FILE:-}" != "$ambient/"* ]] || exit 1
[[ "$(cat "$ambient/mole.registry.parent")" == sentinel ]] || exit 1
[[ -f "$temp_file" ]] || exit 1
printf 'PASS\n'
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *PASS* ]]
}

@test "Darwin temp prune retains every candidate when a live registry cannot be read" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
darwin_root="$HOME/unreadable-registry"
mkdir -p "$darwin_root"
_mole_darwin_user_temp_dir() { printf '%s\n' "$darwin_root"; }
for mode in 000 600; do
    printf fixture > "$darwin_root/mole.Owned1"
    printf fixture > "$darwin_root/mole.Stale1"
    printf '%s\n' "$darwin_root/mole.Owned1" > "$darwin_root/mole.registry.$$"
    touch -t 202001010101 "$darwin_root/mole.Owned1" "$darwin_root/mole.Stale1"
    # A second live registry is readable, so the failed read can be partial.
    printf '%s\n' "$darwin_root/mole.Other1" > "$darwin_root/mole.registry.$PPID"
    chmod "$mode" "$darwin_root/mole.registry.$$"
    prune_stale_mole_tmpdir_leftovers "$darwin_root"
    chmod 600 "$darwin_root/mole.registry.$$"
    [[ -f "$darwin_root/mole.Owned1" ]] || { echo OWNED_REMOVED; exit 1; }
    if [[ "$mode" == 000 ]]; then
        [[ -f "$darwin_root/mole.Stale1" ]] || { echo INCOMPLETE_SCAN_REMOVED; exit 2; }
    else
        [[ ! -e "$darwin_root/mole.Stale1" ]] || { echo CONTROL_NOT_REMOVED; exit 3; }
    fi
done
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
