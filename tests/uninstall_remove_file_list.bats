#!/usr/bin/env bats

load helpers/common

# Tests for remove_file_list batching in lib/uninstall/batch.sh.
# Exercises the batched Trash path (single _mole_move_to_trash_batch call for
# eligible files) and the fallback when the batch helper fails.

setup_file() {
    mole_test_setup_project_root
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-batch.XXXXXX")"
    export SANDBOX
    export MOLE_DELETE_LOG="$SANDBOX/deletions.log"
    export MOLE_TEST_TRASH_DIR="$SANDBOX/Trash"
    export MOLE_TEST_NO_AUTH=1
    export MOLE_DELETE_MODE=trash
    unset MOLE_DRY_RUN
    HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    export HOME
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat <<EOF
set -euo pipefail
export MOLE_DELETE_LOG="$MOLE_DELETE_LOG"
export MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR"
export MOLE_TEST_NO_AUTH=1
export MOLE_DELETE_MODE=trash
export HOME="$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
EOF
}

@test "remove_file_list refuses shared XDG roots regardless of display-name casing (#1446)" {
    mkdir -p "$HOME/.Local/bin" "$HOME/.Config" "$HOME/.Cache"
    touch "$HOME/.Local/bin/unrelated-cli" "$HOME/.Config/unrelated-config" "$HOME/.Cache/unrelated-cache"
    local list
    printf -v list '%s\n%s\n%s' "$HOME/.Local" "$HOME/.Config" "$HOME/.Cache"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]] || return 1
    [[ -f "$HOME/.Local/bin/unrelated-cli" ]] || return 1
    [[ -f "$HOME/.Config/unrelated-config" ]] || return 1
    [[ -f "$HOME/.Cache/unrelated-cache" ]] || return 1
    [[ ! -d "$MOLE_TEST_TRASH_DIR" ]]
}

@test "remove_file_list refuses the Steam library root and its contents" {
    local steam="$HOME/Library/Application Support/Steam"
    mkdir -p "$steam/steamapps/common/Game" "$steam/userdata/42"
    touch "$steam/steamapps/common/Game/game.bin" "$steam/userdata/42/save.vdf"
    local list
    printf -v list '%s\n%s\n%s' "$steam" "$steam/steamapps/common/Game" "$steam/userdata/42"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_UNINSTALL_MODE=1
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ -f "$steam/steamapps/common/Game/game.bin" ]] || return 1
    [[ -f "$steam/userdata/42/save.vdf" ]] || return 1
    [[ ! -d "$MOLE_TEST_TRASH_DIR" ]]
}

@test "uninstall keeps a LaunchAgent whose program changed after preview" {
    local app="$HOME/Applications/Target.app"
    local agents="$HOME/Library/LaunchAgents"
    mkdir -p "$app/Contents/MacOS" "$agents"
    touch "$app/Contents/MacOS/Target"
    cat > "$agents/com.example.Target.helper.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST
    cat > "$agents/org.vendor.helper.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>ProgramArguments</key><array><string>$app/Contents/MacOS/Target</string></array></dict></plist>
PLIST
    : > "$agents/com.example.Target.plist"

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agents="$HOME/Library/LaunchAgents"
plan=$(find_app_files com.example.Target Target "$app")
[[ "$plan" == *"$agents/com.example.Target.helper.plist"* ]] || exit 1
[[ "$plan" == *"$agents/org.vendor.helper.plist"* ]] || exit 1

# The reviewed helper now launches an unrelated program. The selected app has
# already moved, as it has when batch removal reaches its leftover list.
cat > "$agents/com.example.Target.helper.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
mv "$app" "$HOME/moved-Target.app"
remove_file_list "$plan" false com.example.Target "$app" > /dev/null
[[ -f "$agents/com.example.Target.helper.plist" ]] || exit 1
[[ ! -e "$agents/org.vendor.helper.plist" ]] || exit 1
[[ ! -e "$agents/com.example.Target.plist" ]] || exit 1
[[ -d "$HOME/moved-Target.app" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "uninstall keeps a LaunchAgent replaced while deletion is being sized" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
get_path_size_kb() {
    cat > "$agent" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
    printf '1\n'
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$count" == 0 ]] || exit 1
[[ -f "$agent" ]] || exit 1
grep -Fq '<string>/bin/true</string>' "$agent"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "uninstall keeps LaunchAgents if another app takes the selected path" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
plan=$(find_app_files com.example.Target Target "$app")
[[ "$plan" == *"$agent"* ]] || exit 1
mv "$app" "$HOME/moved-Target.app"
mkdir -p "$app/Contents/MacOS"
touch "$app/Contents/MacOS/Target"
rc=0
count=$(remove_file_list "$plan" false com.example.Target "$app") || rc=$?
[[ $rc -eq 16 && "$count" == 0 ]] || exit 1
[[ -f "$agent" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"selected app path exists again"* ]] || return 1
}

@test "uninstall keeps an agent if the app path reappears during sizing" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
get_path_size_kb() {
    mkdir -p "$app/Contents/MacOS"
    touch "$app/Contents/MacOS/Target"
    printf '1\n'
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$count" == 0 ]] || exit 1
[[ -f "$agent" ]] || exit 1
[[ -f "$app/Contents/MacOS/Target" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "uninstall rechecks app absence at the Trash move" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
_mole_trash_target_still_safe() {
    mkdir -p "$app/Contents/MacOS"
    touch "$app/Contents/MacOS/Target"
    return 0
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$count" == 0 ]] || exit 1
[[ -f "$agent" ]] || exit 1
[[ -f "$app/Contents/MacOS/Target" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "uninstall rechecks agent content at the Trash move" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
_mole_trash_target_still_safe() {
    cat > "$agent" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
    return 0
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$count" == 0 ]] || exit 1
[[ -f "$agent" ]] || exit 1
grep -Fq '<string>/bin/true</string>' "$agent"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "uninstall keeps a replacement installed during the final content check" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
mole_file_sha256() {
    local digest calls=0
    digest=$(shasum -a 256 -- "$1") || return $?
    [[ -f "$HOME/hash-calls" ]] && read -r calls < "$HOME/hash-calls"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$HOME/hash-calls"
    if [[ $calls -eq 3 ]]; then
        mv "$1" "$HOME/old-agent.plist"
        cat > "$1" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
    fi
    printf '%s\n' "${digest:0:64}"
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$(cat "$HOME/hash-calls")" -eq 3 ]] || exit 1
[[ "$count" == 0 && -f "$agent" && -f "$HOME/old-agent.plist" ]] || exit 1
grep -Fq '<string>/bin/true</string>' "$agent" || exit 1
[[ ! -d "$MOLE_TEST_TRASH_DIR" || -z "$(ls -A "$MOLE_TEST_TRASH_DIR")" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "uninstall rechecks app absence at permanent removal" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
MOLE_DELETE_MODE=permanent
_MOLE_SAFE_REMOVE_FINAL_GUARD=create_replacement_app
create_replacement_app() {
    mkdir -p "$app/Contents/MacOS"
    touch "$app/Contents/MacOS/Target"
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$count" == 0 ]] || exit 1
[[ -f "$agent" ]] || exit 1
[[ -f "$app/Contents/MacOS/Target" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "permanent removal rebinds ownership after calculating its timeout" {
    local app="$HOME/Applications/Target.app"
    local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
    mkdir -p "$app/Contents/MacOS" "${agent%/*}"
    touch "$app/Contents/MacOS/Target"
    cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST

    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mv "$app" "$HOME/moved-Target.app"
MOLE_DELETE_MODE=permanent
_mole_timeout_with_deadline() {
    local calls=0
    if [[ "$1" == "$MOLE_TIMEOUT_DISK_VERIFY_SEC" ]]; then
        [[ -f "$HOME/timeout-calls" ]] && read -r calls < "$HOME/timeout-calls"
        calls=$((calls + 1))
        printf '%s\n' "$calls" > "$HOME/timeout-calls"
        if [[ $calls -eq 2 ]]; then
            mv "$agent" "$HOME/original-agent.plist"
            cat > "$agent" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
        fi
    fi
    printf '%s\n' "$1"
}
count=$(remove_file_list "$agent" false com.example.Target "$app")
[[ "$(cat "$HOME/timeout-calls")" -eq 2 ]] || { echo 'timeout boundary not reached twice'; exit 1; }
[[ "$count" == 0 && -f "$agent" && -f "$HOME/original-agent.plist" ]] || {
    printf 'count=%s agent=%s original=%s\n' "$count" "$(test -e "$agent" && echo yes || echo no)" "$(test -e "$HOME/original-agent.plist" && echo yes || echo no)"
    exit 1
}
grep -Fq '<string>/bin/true</string>' "$agent" || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "remove_file_list batches eligible Trash moves into a single helper call" {
    local f1="$SANDBOX/a.plist"
    local f2="$SANDBOX/b.plist"
    local f3="$SANDBOX/c.plist"
    local f4="$SANDBOX/d.plist"
    local f5="$SANDBOX/e.plist"
    : > "$f1"
    : > "$f2"
    : > "$f3"
    : > "$f4"
    : > "$f5"
    local list
    printf -v list '%s\n%s\n%s\n%s\n%s' "$f1" "$f2" "$f3" "$f4" "$f5"

    local count_file="$SANDBOX/batch_calls"
    : > "$count_file"

    # Stub the batch helper to (1) record how many times it was called and
    # how many paths each call covered, (2) emulate the real test-harness
    # behavior by mv'ing each path into MOLE_TEST_TRASH_DIR. This lets the
    # test assert both "called once" and "every file landed in trash".
    run /bin/bash --noprofile --norc <<EOF
$(prelude)
_mole_move_to_trash_batch() {
    mkdir -p "\$MOLE_TEST_TRASH_DIR"
    printf 'call %d\n' "\$#" >> "$count_file"
    local p dest
    for p in "\$@"; do
        dest="\$MOLE_TEST_TRASH_DIR/\$(basename "\$p").stub.\$RANDOM"
        mv "\$p" "\$dest" 2>/dev/null || return 1
    done
    return 0
}
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"5"* ]] # remove_file_list echoes count

    # All five files moved to the stub trash dir.
    local in_trash
    in_trash=$(find "$MOLE_TEST_TRASH_DIR" -type f | wc -l | tr -d ' ')
    [ "$in_trash" -eq 5 ]
    for f in "$f1" "$f2" "$f3" "$f4" "$f5"; do
        [[ ! -e "$f" ]] || return 1
    done

    # Single batch invocation, with all five paths.
    local call_count
    call_count=$(wc -l < "$count_file" | tr -d ' ')
    [ "$call_count" -eq 1 ]
    grep -q '^call 5$' "$count_file"

    # Audit log records one ok line per moved path.
    local ok_lines
    ok_lines=$(awk -F'\t' '$4 == "ok" && $2 == "trash"' "$MOLE_DELETE_LOG" | wc -l | tr -d ' ')
	[ "$ok_lines" -eq 5 ]
}

@test "Trash batches refresh live-owner evidence before each move" {
	local first_cache="$HOME/Library/Caches/com.example.One"
	local second_cache="$HOME/Library/Caches/com.example.Two"
	mkdir -p "$first_cache" "$second_cache" "$HOME/.cache/mole"
	printf 'one\n' > "$first_cache/data"
	printf 'two\n' > "$second_cache/data"
	local ps_count="$SANDBOX/ps-count"
	: > "$ps_count"

	run env PROJECT_ROOT="$PROJECT_ROOT" PS_COUNT="$ps_count" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
ps() {
	# One snapshot is a table read plus an executable-path read; count and
	# answer only the table read.
	[[ "$*" == *comm=* ]] && return 0
	printf 'x' >> "$PS_COUNT"
	local calls
	calls=$(wc -c < "$PS_COUNT" | tr -d ' ')
	printf '  PID  PPID COMM ARGS\n'
	if [[ $calls -ge 2 ]]; then
		printf '9000 1 /Applications/ExampleTwo /Applications/ExampleTwo --bundle com.example.Two\n'
	fi
}
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
remove_file_list "$(printf '%s\n%s\n' \
	"$HOME/Library/Caches/com.example.One" \
	"$HOME/Library/Caches/com.example.Two")" false
printf 'PS_CALLS=%s ONE=%s TWO=%s\n' \
	"$(wc -c < "$PS_COUNT" | tr -d ' ')" \
	"$([[ -e "$HOME/Library/Caches/com.example.One" ]] && printf yes || printf no)" \
	"$([[ -e "$HOME/Library/Caches/com.example.Two" ]] && printf yes || printf no)"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"PS_CALLS=3 ONE=no TWO=yes"* ]] || return 1
}

@test "remove_file_list preserves unmoved paths when the guarded batch helper fails" {
    local f1="$SANDBOX/x.plist"
    local f2="$SANDBOX/y.plist"
    : > "$f1"
    : > "$f2"
    local list
    printf -v list '%s\n%s' "$f1" "$f2"

    local trace="$SANDBOX/trace"
    : > "$trace"

    # A failed identity-bound batch must not hand the same stale lexical paths
    # to a second sink. The files stay in place for manual review.
    run /bin/bash --noprofile --norc <<EOF
$(prelude)
_mole_move_to_trash_batch() { return 1; }
mole_delete() {
    printf 'mole_delete %s\n' "\$1" >> "$trace"
    return 99
}
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]] || return 1
    [[ -e "$f1" && -e "$f2" ]] || return 1
    [[ ! -s "$trace" ]]
}

@test "guarded Trash batch rejects an ancestor swapped after collection" {
    local base="$SANDBOX/swap-parent"
    local original_parent="$SANDBOX/original-parent"
    local outside_parent="$HOME/Documents/OutsideParent"
    local target="$base/cache"
    mkdir -p "$target" "$outside_parent/cache"
    touch "$target/OWNED_SENTINEL" "$outside_parent/cache/OUTSIDE_SENTINEL"
    local list="$target"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
eval "\$(declare -f _mole_snapshot_path_identity | sed '1s/_mole_snapshot_path_identity/_real_mole_snapshot_path_identity/')"
snapshot_calls=0
_mole_snapshot_path_identity() {
    snapshot_calls=\$((snapshot_calls + 1))
    if [[ \$snapshot_calls -eq 2 ]]; then
        mv "$base" "$original_parent"
        ln -s "$outside_parent" "$base"
    fi
    _real_mole_snapshot_path_identity "\$1"
}
mole_delete() { echo "UNEXPECTED_FALLBACK:\$1"; return 99; }
remove_file_list "$list" "false"
[[ -f "$outside_parent/cache/OUTSIDE_SENTINEL" ]] || exit 1
[[ -f "$original_parent/cache/OWNED_SENTINEL" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"0"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_FALLBACK"* ]] || return 1
    [[ ! -e "$MOLE_TEST_TRASH_DIR/cache" ]]
}

@test "_mole_move_to_trash_batch returns 1 when trash CLI is missing under MOLE_TEST_NO_AUTH" {
    local f1="$SANDBOX/p.plist"
    : > "$f1"

    # Drop MOLE_TEST_TRASH_DIR so we exercise the real helper path; the
    # MOLE_TEST_NO_AUTH guard must fail closed before any AppleScript runs.
    run /bin/bash --noprofile --norc <<EOF
set -euo pipefail
export MOLE_TEST_NO_AUTH=1
unset MOLE_TEST_TRASH_DIR
source "$PROJECT_ROOT/lib/core/common.sh"
_mole_move_to_trash_batch "$f1"
EOF

    [ "$status" -ne 0 ]
    [[ -e "$f1" ]]
}

@test "remove_file_list with sudo paths bypasses batching and routes per-file" {
    local f1="$SANDBOX/sudo_a.plist"
    local f2="$SANDBOX/sudo_b.plist"
    : > "$f1"
    : > "$f2"
    local list
    printf -v list '%s\n%s' "$f1" "$f2"

    local batch_count="$SANDBOX/batch_count"
    local fallback_count="$SANDBOX/fallback_count"
    : > "$batch_count"
    : > "$fallback_count"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
_mole_move_to_trash_batch() {
    printf '1\n' >> "$batch_count"
    return 0
}
mole_delete() {
    printf '%s\n' "\$1" >> "$fallback_count"
    rm -f "\$1"
    return 0
}
remove_file_list "$list" "true"
EOF

    [ "$status" -eq 0 ]

    # Sudo path must avoid the batch helper entirely.
    [[ ! -s "$batch_count" ]] || return 1

    local n
    n=$(wc -l < "$fallback_count" | tr -d ' ')
    [ "$n" -eq 2 ]
}

@test "remove_file_list stops after an interrupted per-file delete" {
    local first="$SANDBOX/interrupt-first.plist"
    local second="$SANDBOX/interrupt-second.plist"
    : > "$first"
    : > "$second"
    local list
    printf -v list '%s\n%s' "$first" "$second"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
_mole_path_requires_direct_trash() { return 0; }
delete_calls=0
mole_delete() {
    delete_calls=\$((delete_calls + 1))
    printf 'DELETE_CALL:%s\n' "\$1"
    return 130
}
rc=0
remove_file_list "$list" "false" || rc=\$?
printf 'RC=%s CALLS=%s\n' "\$rc" "\$delete_calls"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130 CALLS=1"* ]] || return 1
    [[ "$output" == *"DELETE_CALL:$first"* ]] || return 1
    [[ "$output" != *"DELETE_CALL:$second"* ]] || return 1
    [[ -e "$first" ]] || return 1
    [[ -e "$second" ]]
}

@test "remove_file_list routes Microsoft Word app data per-file and batches ordinary leftovers" {
    local container="$HOME/Library/Containers/com.microsoft.Word"
    local group_container="$HOME/Library/Group Containers/UBF8T346G9.Office"
    local app_scripts="$HOME/Library/Application Scripts/com.microsoft.Word"
    local ordinary="$HOME/Library/Preferences/com.microsoft.Word.plist"
    mkdir -p "$container" "$group_container" "$app_scripts" "$(dirname "$ordinary")"
    : > "$ordinary"
    local list
    printf -v list '%s\n%s\n%s\n%s' "$container" "$group_container" "$app_scripts" "$ordinary"

    local direct_trace="$SANDBOX/direct.log"
    local batch_trace="$SANDBOX/batch.log"
    : > "$direct_trace"
    : > "$batch_trace"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_UNINSTALL_MODE=1
_mole_move_to_trash_batch() {
    printf '%s\n' "\$@" >> "$batch_trace"
    return 0
}
mole_delete() {
    printf '%s|%s\n' "\$1" "\${2:-false}" >> "$direct_trace"
    return 0
}
trash() {
    echo "trash CLI must not be called" >&2
    return 99
}
osascript() {
    echo "Finder must not be called" >&2
    return 98
}
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$direct_trace" | tr -d ' ')" -eq 3 ]
    grep -qF "$container|false" "$direct_trace"
    grep -qF "$group_container|false" "$direct_trace"
    grep -qF "$app_scripts|false" "$direct_trace"
    [ "$(wc -l < "$batch_trace" | tr -d ' ')" -eq 1 ]
    grep -qxF "$ordinary" "$batch_trace"
    [[ "$output" != *"trash CLI must not be called"* ]] || return 1
    [[ "$output" != *"Finder must not be called"* ]]
}

@test "uninstall refusal evidence survives protection and live-cache gates" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
export MOLE_UNINSTALL_MODE=1
protected="$HOME/Library/Logs/com.openai.codex"
active="$HOME/Library/Caches/com.example.Active"
ordinary="$HOME/ordinary"
mkdir -p "$protected" "$active" "$ordinary"
_mole_should_refuse_live_user_cache_path() { [[ "$1" == "$active" ]]; }
collect() {
    local _MOLE_UNINSTALL_REFUSALS_ACTIVE=1
    local -a _MOLE_UNINSTALL_REFUSAL_PATHS=() _MOLE_UNINSTALL_REFUSAL_REASONS=()
    remove_file_list "$(printf '%s\n' "$protected" "$active" "$ordinary")" false
    [[ ${#_MOLE_UNINSTALL_REFUSAL_PATHS[@]} -eq 2 ]] || exit 1
    [[ "${_MOLE_UNINSTALL_REFUSAL_PATHS[0]}" == "$protected" && "${_MOLE_UNINSTALL_REFUSAL_REASONS[0]}" == protected ]] || exit 1
    [[ "${_MOLE_UNINSTALL_REFUSAL_PATHS[1]}" == "$active" && "${_MOLE_UNINSTALL_REFUSAL_REASONS[1]}" == live-cache ]] || exit 1
}
collect
[[ -d "$protected" && -d "$active" && ! -e "$ordinary" ]] || exit 1
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "uninstall records a live cache appearing at the final Trash guard" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
export MOLE_UNINSTALL_MODE=1
active="$HOME/Library/Caches/com.example.Active"
mkdir -p "$active"
probes=0
_mole_should_refuse_live_user_cache_path() {
    probes=$((probes + 1))
    [[ $probes -gt 1 ]]
}
collect() {
    local _MOLE_UNINSTALL_REFUSALS_ACTIVE=1
    local -a _MOLE_UNINSTALL_REFUSAL_PATHS=() _MOLE_UNINSTALL_REFUSAL_REASONS=()
    remove_file_list "$active" false
    [[ $probes -eq 2 ]] || exit 1
    [[ ${#_MOLE_UNINSTALL_REFUSAL_PATHS[@]} -eq 1 ]] || exit 1
    [[ "${_MOLE_UNINSTALL_REFUSAL_PATHS[0]}" == "$active" && "${_MOLE_UNINSTALL_REFUSAL_REASONS[0]}" == live-cache ]] || exit 1
}
collect
[[ -d "$active" ]] || exit 1
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "uninstall records access denial from the actual direct Trash mover" {
    mole_test_fake_command mv 'printf "mv: Permission denied\n" >&2; exit 1'
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
unset MOLE_TEST_TRASH_DIR MOLE_TEST_NO_AUTH
export MOLE_UNINSTALL_MODE=1
victim="$HOME/Library/Group Containers/com.example.Privacy"
mkdir -p "$victim"
_mole_should_refuse_live_user_cache_path() { return 1; }
osascript() { echo unexpected-Finder >> "$HOME/unexpected"; return 99; }
safe_remove() { echo unexpected-delete >> "$HOME/unexpected"; return 99; }
collect() {
    local _MOLE_UNINSTALL_REFUSALS_ACTIVE=1
    local -a _MOLE_UNINSTALL_REFUSAL_PATHS=() _MOLE_UNINSTALL_REFUSAL_REASONS=()
    remove_file_list "$victim" false
    [[ ${#_MOLE_UNINSTALL_REFUSAL_PATHS[@]} -gt 0 ]] || exit 1
    local i
    for ((i = 0; i < ${#_MOLE_UNINSTALL_REFUSAL_PATHS[@]}; i++)); do
        [[ "${_MOLE_UNINSTALL_REFUSAL_PATHS[$i]}" == "$victim" && "${_MOLE_UNINSTALL_REFUSAL_REASONS[$i]}" == access-denied ]] || exit 1
    done
}
collect
[[ -d "$victim" && ! -e "$HOME/unexpected" ]] || exit 1
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}


@test "remove_file_list propagates validation cancellation before later candidates" {
    local probe_rc failures=0
    for probe_rc in 1 124 130; do
        run env PROJECT_ROOT="$PROJECT_ROOT" PROBE_RC="$probe_rc" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
export MOLE_CURRENT_COMMAND=uninstall
first="$HOME/first"
second="$HOME/second"
mkdir -p "$first" "$second"
validate_path_for_deletion() {
    printf '%s\n' "$1" >> "$HOME/probed-$PROBE_RC"
    [[ "$1" == "$first" ]] && return "$PROBE_RC"
    return 0
}
_mole_move_to_trash_batch() { printf '%s\n' "$@" > "$HOME/moved-$PROBE_RC"; }
rc=0
remove_file_list "$first"$'\n'"$second" false || rc=$?
grep -Fxq "$first" "$HOME/probed-$PROBE_RC" || exit 1
if [[ $PROBE_RC -eq 1 ]]; then
    [[ $rc -eq 0 ]] || exit 1
    grep -Fxq "$second" "$HOME/moved-$PROBE_RC" || exit 1
else
    [[ $rc -eq $PROBE_RC ]] || exit 1
    ! grep -Fxq "$second" "$HOME/probed-$PROBE_RC" || exit 1
    [[ ! -e "$HOME/moved-$PROBE_RC" ]] || exit 1
fi
EOF
        [ "$status" -eq 0 ] || { echo "probe=$probe_rc: $output"; failures=$((failures + 1)); }
    done
    [ "$failures" -eq 0 ]
}

@test "remove_file_list keeps leftovers when the app returns, whatever the plan's bundle id" {
    # The replacement test needs no inventory, so a plan narrowed to an
    # unknown id, or an id that is not reverse-DNS, must keep name-keyed data
    # exactly like an ordinary plan does.
    local id
    for id in unknown com.example.Target_Beta com.example.Target; do
        rm -rf "$HOME/Applications" "$HOME/Library" "$HOME/moved-Target.app"
        mkdir -p "$HOME/Applications/Target.app/Contents" "$HOME/Library/Application Support/Target"
        printf 'notes\n' > "$HOME/Library/Application Support/Target/notes"
        run env PROJECT_ROOT="$PROJECT_ROOT" BUNDLE_ID="$id" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Target.app"
data="$HOME/Library/Application Support/Target"
mv "$app" "$HOME/moved-Target.app"
mkdir -p "$app/Contents"
rc=0
count=$(remove_file_list "$data" false "$BUNDLE_ID" "$app") || rc=$?
[[ $rc -eq 16 && "$count" == 0 ]] || { echo "reappeared rc=$rc count=$count"; exit 1; }
[[ -f "$data/notes" ]] || { echo "data removed while the app path was occupied"; exit 1; }
# Positive control: with the path free, the same call reaches the sink.
rm -rf "$app"
rc=0
count=$(remove_file_list "$data" false "$BUNDLE_ID" "$app") || rc=$?
[[ $rc -eq 0 && "$count" == 1 && ! -e "$data" ]] || { echo "control rc=$rc count=$count"; exit 1; }
EOF
        [ "$status" -eq 0 ] || { echo "bundle id $id: $output"; return 1; }
    done
}

@test "UUID container owner is checked after sizing and at the final Trash sink" {
    run bash -c "$(prelude)"'
container="$HOME/Library/Containers/ABCDEFAB-1234-1234-1234-123456789ABC"
mkdir -p "$container"
printf "%s\n" '\''{"MCMMetadataIdentifier":"com.example.Gizmo"}'\'' > "$container/.com.apple.containermanagerd.metadata.plist"
get_path_size_kb() {
    printf "%s\n" '\''{"MCMMetadataIdentifier":"com.other.Gizmo"}'\'' > "$container/.com.apple.containermanagerd.metadata.plist"
    printf "1\n"
}
remove_file_list "$container" false com.example.Gizmo
[[ -d "$container" ]] || exit 1
grep -F ownership-unverified "$MOLE_DELETE_LOG"
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "native manifest replacement during sizing retains the new owner" {
    run bash -c "$(prelude)"'
hosts="$HOME/Library/Application Support/Browser/NativeMessagingHosts"
mkdir -p "$hosts"
manifest="$hosts/gizmo.json"
printf '\''{"path":"%s/Applications/Gizmo.app/Contents/MacOS/host"}\n'\'' "$HOME" > "$manifest"
get_path_size_kb() {
    printf "%s\n" '\''{"path":"/Applications/Other.app/host"}'\'' > "$manifest"
    printf "1\n"
}
remove_file_list "$manifest" false com.example.Gizmo "$HOME/Applications/Gizmo.app"
[[ -f "$manifest" ]] || exit 1
grep -F ownership-unverified "$MOLE_DELETE_LOG"
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "UUID container final guard retains changed metadata after the Trash identity check" {
    run bash -c "$(prelude)"'
container="$HOME/Library/Containers/ABCDEFAB-1234-1234-1234-123456789ABC"
mkdir -p "$container"
printf "%s\n" '\''{"MCMMetadataIdentifier":"com.example.Gizmo"}'\'' > "$container/.com.apple.containermanagerd.metadata.plist"
eval "$(declare -f _mole_trash_target_still_safe | sed '\''1s/_mole_trash_target_still_safe/_original_trash_safe/'\'')"
_mole_trash_target_still_safe() {
    _original_trash_safe "$@" || return $?
    printf "%s\n" '\''{"MCMMetadataIdentifier":"com.other.Gizmo"}'\'' > "$container/.com.apple.containermanagerd.metadata.plist"
}
remove_file_list "$container" false com.example.Gizmo
[[ -d "$container" ]] || exit 1
grep -F ownership-unverified "$MOLE_DELETE_LOG"
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "UUID exact owner uses normal Trash and permanent sinks" {
    run bash -c "$(prelude)"'
for mode in trash permanent; do
    export MOLE_DELETE_MODE="$mode"
    container="$HOME/Library/Containers/ABCDEFAB-1234-1234-1234-123456789ABC"
    mkdir -p "$container"
    printf "%s\n" '\''{"MCMMetadataIdentifier":"com.example.Gizmo"}'\'' > "$container/.com.apple.containermanagerd.metadata.plist"
    remove_file_list "$container" false com.example.Gizmo
    [[ ! -d "$container" ]] || exit 1
done
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the System Integrity Protection probe reads real protected trees and an ordinary one" {
    [[ -d /System/Library/Sandbox && -d /private/var/db/CVMS ]] || skip "needs macOS system folders"
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
_uninstall_tree_holds_system_protected_entry /System/Library/Sandbox || exit 1
_uninstall_tree_holds_system_protected_entry /private/var/db/CVMS || exit 2
mkdir -p "$HOME/ordinary/Data"
if _uninstall_tree_holds_system_protected_entry "$HOME/ordinary"; then exit 3; fi
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}

@test "the System Integrity Protection probe asks the system find for every mark, bounded" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; printf '%s\n' "$*"; }
line=$(_uninstall_find_system_protected "$HOME/x")
[[ "$line" == "/usr/bin/find $HOME/x -maxdepth 4 "* ]] || exit 1
[[ "$line" == *"-flags +restricted"* && "$line" == *"-flags +sunlnk"* ]] || exit 2
[[ "$line" == *"-xattrname com.apple.rootless"* && "$line" == *"-print -quit" ]] || exit 3
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}

@test "only a hit or a refused stat proves protection, and a signal cancels" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
answer() { _uninstall_tree_holds_system_protected_entry /x; echo "$?"; }
_uninstall_find_system_protected() { echo /x/Data/drkit; }
[[ $(answer) == 0 ]] || exit 1
_uninstall_find_system_protected() { echo "find: /x/Data/drkit: Operation not permitted" >&2; return 1; }
[[ $(answer) == 0 ]] || exit 2
_uninstall_find_system_protected() { echo "find: /x/gone: No such file or directory" >&2; return 1; }
[[ $(answer) == 1 ]] || exit 3
_uninstall_find_system_protected() { echo "/lib/timeout.sh: fork: retry: Resource temporarily unavailable" >&2; return 1; }
[[ $(answer) == 1 ]] || exit 4
_uninstall_find_system_protected() { return 124; }
[[ $(answer) == 1 ]] || exit 5
_uninstall_find_system_protected() { echo /x/Data/drkit; return 124; }
[[ $(answer) == 0 ]] || exit 6
_uninstall_find_system_protected() { return 143; }
[[ $(answer) == 143 ]] || exit 7
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}

@test "uninstall keeps a container macOS protects, counts only what it removed, and logs why" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
export MOLE_UNINSTALL_MODE=1 MOLE_HAS_FDA=1
flagged="$HOME/Library/Containers/developer.apple.wwdc-Release"
grouped="$HOME/Library/Group Containers/group.example.denied"
plain="$HOME/Library/Containers/com.example.plain"
outside="$HOME/Library/Application Support/com.example.outside"
mkdir -p "$flagged" "$grouped" "$plain" "$outside"
_uninstall_tree_holds_system_protected_entry() {
    printf '%s\n' "$1" >> "$HOME/asked"
    [[ "$1" == "$flagged" || "$1" == "$grouped" ]]
}
logged="$HOME/logged"
log_operation() { printf '%s|%s|%s\n' "$2" "$3" "$4" >> "$logged"; }
collect() {
    local _MOLE_UNINSTALL_REFUSALS_ACTIVE=1
    local -a _MOLE_UNINSTALL_REFUSAL_PATHS=() _MOLE_UNINSTALL_REFUSAL_REASONS=()
    local removed
    removed=$(remove_file_list "$(printf '%s\n' "$flagged" "$grouped" "$plain" "$outside")" false | tail -1)
    [[ "$removed" == 2 ]] || { echo "removed=$removed"; exit 1; }
    _MOLE_UNINSTALL_REFUSAL_PATHS=()
}
collect
[[ -d "$flagged" && -d "$grouped" ]] || exit 2
[[ ! -e "$plain" && ! -e "$outside" ]] || exit 3
if grep -qF "$outside" "$HOME/asked"; then exit 4; fi
grep -qF "SKIPPED|$flagged|system protected" "$logged" || exit 5
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}

@test "a protected container is recorded as denied access for the summary, and a signal stops the batch" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
export MOLE_UNINSTALL_MODE=1 MOLE_HAS_FDA=1
kept="$HOME/Library/Containers/com.example.kept"
later="$HOME/Library/Containers/com.example.later"
mkdir -p "$kept" "$later"
_MOLE_UNINSTALL_REFUSALS_ACTIVE=1
_MOLE_UNINSTALL_REFUSAL_PATHS=()
_MOLE_UNINSTALL_REFUSAL_REASONS=()
_uninstall_tree_holds_system_protected_entry() { return 0; }
remove_file_list "$kept" false > /dev/null || exit 1
[[ "${_MOLE_UNINSTALL_REFUSAL_PATHS[0]}" == "$kept" ]] || exit 2
[[ "${_MOLE_UNINSTALL_REFUSAL_REASONS[0]}" == access-denied ]] || exit 3
_uninstall_tree_holds_system_protected_entry() { return 143; }
rc=0
remove_file_list "$later" false > /dev/null || rc=$?
[[ $rc -eq 143 ]] || { echo "rc=$rc"; exit 4; }
[[ -d "$later" ]] || exit 5
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}

@test "a batch names a kept protected container as denied and leaves it out of the freed total" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
export MOLE_UNINSTALL_MODE=1 MOLE_HAS_FDA=1
app="$HOME/Applications/Kept.app"
kept="$HOME/Library/Containers/com.example.kept"
mkdir -p "$app" "$kept/Data"
dd if=/dev/zero of="$kept/Data/blob" bs=1024 count=100 2> /dev/null
kept_kb=$(du -skP "$kept" | awk '{print $1}')
stop_launch_services() { :; }
unregister_app_bundle() { :; }
_uninstall_tree_holds_system_protected_entry() { return 0; }
mole_delete() { rmdir "$1"; }
encoded=$(printf '%s\n' "$kept" | base64 | tr -d '\n')
app_details=("Kept|$app|com.example.kept|500|$encoded||false|false|false|||||guard_login|$(_batch_selected_app_identity "$app")|unknown||missing")
success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0
_batch_execute_removals > "$HOME/batch.out" 2>&1
[[ -d "$kept/Data" ]] || { echo "container moved"; exit 1; }
grep -Fq "macOS denied access" "$HOME/batch.out" || { cat "$HOME/batch.out"; exit 2; }
[[ $total_size_freed -eq $((500 - kept_kb)) ]] || { echo "freed=$total_size_freed kept=$kept_kb"; cat "$HOME/batch.out"; exit 3; }
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}

@test "the protection walk stays out of a dry run and needs a proven Full Disk Access grant" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
container="$HOME/Library/Containers/com.example.plain"
_uninstall_tree_holds_system_protected_entry() { printf 'walked\n' > "$HOME/walked"; return 0; }
is_uninstall_dry_run() { return 1; }
MOLE_HAS_FDA=0
if _uninstall_container_holds_system_protected_entry "$container"; then exit 1; fi
MOLE_HAS_FDA=unknown
if _uninstall_container_holds_system_protected_entry "$container"; then exit 2; fi
MOLE_HAS_FDA=1
is_uninstall_dry_run() { return 0; }
if _uninstall_container_holds_system_protected_entry "$container"; then exit 3; fi
is_uninstall_dry_run() { return 1; }
if _uninstall_container_holds_system_protected_entry "$HOME/Library/Application Support/x"; then exit 4; fi
[[ ! -e "$HOME/walked" ]] || exit 5
_uninstall_container_holds_system_protected_entry "$container" || exit 6
[[ -e "$HOME/walked" ]] || exit 7
SCRIPT
    [ "$status" -eq 0 ] || { echo "status=$status"; echo "$output"; return 1; }
}
