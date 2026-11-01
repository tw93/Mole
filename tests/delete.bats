#!/usr/bin/env bats

load helpers

@test "a Trash move counts only when the helper says ok" {
    mkdir -p "$TEST_ROOT/fake/bin"
    printf '#!/bin/bash\necho garbage\n' > "$TEST_ROOT/fake/bin/trash-go"
    chmod +x "$TEST_ROOT/fake/bin/trash-go"
    echo x > "$HOME/file"
    mole_run core 'SCRIPT_DIR="'"$TEST_ROOT"'/fake"; rc=0; mole_trash test "$HOME/file" || rc=$?; echo "rc=$rc moved=$MOLE_TRASH_MOVED"'
    [[ "$output" == *"rc=1 moved=0"* ]]
}

@test "a helper that cannot run is a failure, not a move" {
    mkdir -p "$TEST_ROOT/fake/bin"
    printf 'not an executable format' > "$TEST_ROOT/fake/bin/trash-go"
    chmod +x "$TEST_ROOT/fake/bin/trash-go"
    echo x > "$HOME/file"
    mole_run core 'SCRIPT_DIR="'"$TEST_ROOT"'/fake"; rc=0; mole_trash test "$HOME/file" || rc=$?; echo "rc=$rc moved=$MOLE_TRASH_MOVED"'
    [[ "$output" == *"rc=1 moved=0"* ]]
    [ -f "$HOME/file" ]
}

@test "the real helper moves to the XDG Trash with a trashinfo" {
    [ -x "$REPO/bin/trash-go" ] || skip "bin/trash-go not built"
    echo x > "$HOME/file one"
    mole_run core 'mole_trash test "$HOME/file one"; echo "moved=$MOLE_TRASH_MOVED"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"moved=1"* ]]
    [ ! -e "$HOME/file one" ]
    [ -f "$HOME/.local/share/Trash/files/file one" ]
    grep -q '^Path=.*/file%20one$' "$HOME/.local/share/Trash/info/file one.trashinfo"
}

@test "a path below a symlinked folder is refused" {
    mkdir -p "$TEST_ROOT/elsewhere"
    echo x > "$TEST_ROOT/elsewhere/file"
    ln -s "$TEST_ROOT/elsewhere" "$HOME/link"
    mole_run core 'rc=0; mole_trash test "$HOME/link/file" || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=1"* ]]
    [ -f "$TEST_ROOT/elsewhere/file" ]
}

@test "protected homes and XDG roots are refused" {
    mkdir -p "$HOME/.ssh" "$HOME/.config" "$HOME/.var/app"
    mole_run core '
        for p in "$HOME" "$HOME/.ssh" "$HOME/.config" "$HOME/.var/app" "$HOME/.local/share/Trash"; do
            mole_is_protected_path "$p" || { echo "not protected: $p"; exit 1; }
        done; echo ok'
    [ "$output" = "ok" ]
}

@test "a cache child on another device (a mount point) is never removed" {
    mkdir -p "$HOME/.cache/tool/mnt/inside" "$HOME/.cache/tool/plain"
    real_stat="$(command -v stat)"
    fake_command stat 'if [[ "${!#}" == */mnt ]]; then echo 99; else exec '"$real_stat"' "$@"; fi'
    mole_run core '
        rc=0; mole_remove_cache "$HOME/.cache/tool/mnt" "$HOME/.cache/tool" || rc=$?; echo "mnt=$rc"
        rc=0; mole_remove_cache "$HOME/.cache/tool/plain" "$HOME/.cache/tool" || rc=$?; echo "plain=$rc"'
    [[ "$output" == *"mnt=1"* ]]
    [[ "$output" == *"plain=0"* ]]
    [ -d "$HOME/.cache/tool/mnt/inside" ]
    [ ! -e "$HOME/.cache/tool/plain" ]
}
