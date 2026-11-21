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

# One mountinfo row with $1 as its mount point, escaped as the kernel writes it.
mount_row() {
    local mp="$1"
    mp=${mp//\\/\\134}
    mp=${mp// /\\040}
    printf '41 1 259:2 /victim %s rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw\n' "$mp"
}

@test "a cache child holding a bind mount from the same filesystem is never removed or counted" {
    local tool="$HOME/.cache/tool" phys
    mkdir -p "$tool/deep/a/sub" "$tool/at" "$tool/sub" "$tool/deep2" "$tool/my cache/x" "$tool/plain"
    phys="$(readlink -f -- "$tool")"
    {
        mount_row /
        mount_row "$phys/deep/a/sub"
        mount_row "$phys/at"
        mount_row "$phys/my cache/x"
        mount_row "/elsewhere/sub"
    } > "$TEST_ROOT/mountinfo"
    mole_run core '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/mountinfo"
        for c in deep at sub deep2 "my cache" plain; do
            mole_cache_child_ok "'"$tool"'/$c" "'"$tool"'" && ok=yes || ok=no
            rc=0; mole_remove_cache "'"$tool"'/$c" "'"$tool"'" || rc=$?
            echo "$c ok=$ok rc=$rc"
        done'
    [ "$status" -eq 0 ]
    # A mount deep inside, at the child itself, or in a name with a space.
    [[ "$output" == *"deep ok=no rc=1"* ]]
    [[ "$output" == *"at ok=no rc=1"* ]]
    [[ "$output" == *"my cache ok=no rc=1"* ]]
    [ -d "$tool/deep/a/sub" ] && [ -d "$tool/at" ] && [ -d "$tool/my cache/x" ]
    # Same last name as a mount elsewhere, or a name that only starts the same.
    [[ "$output" == *"sub ok=yes rc=0"* ]]
    [[ "$output" == *"deep2 ok=yes rc=0"* ]]
    [[ "$output" == *"plain ok=yes rc=0"* ]]
    [ ! -e "$tool/sub" ] && [ ! -e "$tool/deep2" ] && [ ! -e "$tool/plain" ]
}

@test "an unreadable mount table refuses every cache child" {
    mkdir -p "$HOME/.cache/tool/plain"
    mole_run core '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/no-such-mountinfo"
        rc=0; mole_remove_cache "$HOME/.cache/tool/plain" "$HOME/.cache/tool" || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]
    [ -d "$HOME/.cache/tool/plain" ]
}

@test "mount paths escape a backslash byte by byte, even in a multibyte locale" {
    # In GBK, 0x5C can be the second byte of a character; the kernel still
    # writes it as \134, so a locale-aware replace would miss the mount.
    mkdir -p "$TEST_ROOT/loc"
    localedef -i zh_CN -f GBK "$TEST_ROOT/loc/zh_CN.GBK" > /dev/null 2>&1 || skip "cannot build a GBK locale here"
    export LOCPATH="$TEST_ROOT/loc"
    mole_run core 'LC_ALL=zh_CN.GBK; s=$'"'"'\xb5\x5c'"'"'; echo "chars=${#s}"
        v=""; _mole_escape_mount v $'"'"'/x/\xb5\x5cy'"'"'; printf "%s\n" "$v"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "chars=1" ] || skip "GBK locale did not load"
    [ "${lines[1]}" = $'/x/\xb5\\134y' ]
}

@test "removal reads the mount table again, whatever snapshot the sizing pass held" {
    local tool="$HOME/.cache/tool" phys
    mkdir -p "$tool/bound/sub" "$tool/plain"
    phys="$(readlink -f -- "$tool")"
    { mount_row /; mount_row "$phys/bound/sub"; } > "$TEST_ROOT/mountinfo"
    mount_row / > "$TEST_ROOT/stale"
    mole_run core '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/stale"
        mole_mount_snapshot "'"$tool"'" || echo snapshot-failed
        _MOLE_MOUNTINFO="'"$TEST_ROOT"'/mountinfo"
        mole_cache_child_ok "'"$tool"'/bound" "'"$tool"'" && echo sized=yes || echo sized=no
        rc=0; mole_remove_cache "'"$tool"'/bound" "'"$tool"'" || rc=$?; echo "removed-rc=$rc"'
    [[ "$output" == *"sized=yes"* ]]
    [[ "$output" == *"removed-rc=1"* ]]
    [ -d "$tool/bound/sub" ]
}

@test "a clean rule's dry run leaves a child holding a bind mount out of its count" {
    local tool="$HOME/.cache/tool" phys
    mkdir -p "$tool/bound/sub" "$tool/plain"
    head -c 65536 /dev/zero > "$tool/bound/sub/blob"
    head -c 65536 /dev/zero > "$tool/plain/blob"
    phys="$(readlink -f -- "$tool")"
    { mount_row /; mount_row "$phys/bound/sub"; } > "$TEST_ROOT/mountinfo"
    mole_run clean '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/mountinfo"; DRY_RUN=true
        group_begin Tool; clean_rule_collect "Tool cache" "'"$tool"'" ""; echo "count=$G_COUNT"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]]
}

@test "a real same-filesystem bind mount inside a cache child keeps the bound folder's files" {
    command -v unshare > /dev/null 2>&1 || skip "unshare not installed"
    unshare -rm true 2> /dev/null || skip "unprivileged user and mount namespaces are not available"
    mkdir -p "$HOME/victim" "$HOME/.cache/tool/child/sub" "$TEST_ROOT/state"
    echo keep > "$HOME/victim/precious"
    echo junk > "$HOME/.cache/tool/child/junk"
    cat > "$TEST_ROOT/inside.sh" << 'EOF'
SCRIPT_DIR="$MOLE_TEST_REPO"
source "$MOLE_TEST_REPO/lib/core/common.sh"
rc=0; mole_remove_cache "$HOME/.cache/tool/child" "$HOME/.cache/tool" || rc=$?; echo "rc=$rc"
EOF
    # Mounting needs the namespace's root; Mole refuses root, so the removal
    # runs in a nested namespace mapped back to the test user's own uid.
    run env XDG_STATE_HOME="$TEST_ROOT/state" unshare -rm bash -c '
        mount --bind "$HOME/victim" "$HOME/.cache/tool/child/sub" || exit 90
        exec unshare -U --map-user='"$(id -u)"' --map-group='"$(id -g)"' bash "'"$TEST_ROOT"'/inside.sh"'
    [ "$status" -ne 90 ] || skip "bind mount not permitted here"
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]
    [ -f "$HOME/victim/precious" ]
    [ -f "$HOME/.cache/tool/child/junk" ]
}

@test "mole_ascii_lowercase lowers ASCII only, under any locale, and runs no program" {
    mole_run core 'PATH=/nonexistent; LC_ALL=C.UTF-8; v=""; mole_ascii_lowercase v "ÄbC Org.Gnome-X"; printf "[%s]\n" "$v"
        mole_ascii_lowercase v "$(printf "ABC\n\n")"; printf "[%s]\n" "$v"
        mole_ascii_lowercase v ""; printf "[%s]\n" "$v"
        s="Ä"; echo "chars=${#s}"'
    [ "$status" -eq 0 ]
    # The caller's locale is back once the function returns.
    [ "${lines[3]}" = "chars=1" ]
    [ "${lines[0]}" = "[Äbc org.gnome-x]" ]
    [ "${lines[1]}" = "[abc]" ]
    [ "${lines[2]}" = "[]" ]
}
