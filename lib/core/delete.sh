#!/bin/bash
# Mole CLI (Linux) - the two ways a path leaves:
#   mole_trash         user files, uninstall leftovers: freedesktop Trash via
#                      bin/trash-go (internal/xdgtrash), restorable.
#   mole_remove_cache  regenerable caches from Clean's allowlist: removed
#                      directly, since moving a cache to Trash frees nothing.
# Both refuse anything outside the user's home or a protected location, and
# neither ever runs as root.

set -euo pipefail

if [[ -n "${MOLE_DELETE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_DELETE_LOADED=1

# Paths that must never be removed or trashed, whatever a rule says.
mole_is_protected_path() {
    local path="$1"
    case "$path" in
        "" | / | "$HOME" | "$HOME/") return 0 ;;
        /bin | /bin/* | /boot | /boot/* | /dev | /dev/* | /etc | /etc/* | /lib | /lib/* | /lib64 | /lib64/* | \
            /proc | /proc/* | /root | /root/* | /run | /run/* | /sbin | /sbin/* | /sys | /sys/* | /usr | /usr/* | \
            /var | /var/* | /nix/store | /nix/store/* | /snap | /snap/*) return 0 ;;
    esac
    case "$path" in
        "$MOLE_TRASH_DIR" | "$MOLE_DATA_HOME" | "$MOLE_CONFIG_HOME" | "$MOLE_CACHE_HOME" | "$MOLE_STATE_HOME" | \
            "$HOME/.local" | "$HOME/.ssh" | "$HOME/.ssh/"* | "$HOME/.gnupg" | "$HOME/.gnupg/"* | \
            "$MOLE_DATA_HOME/keyrings" | "$MOLE_DATA_HOME/keyrings/"* | \
            "$MOLE_CACHE_HOME/doc" | "$MOLE_CACHE_HOME/doc/"* | \
            "$MOLE_DATA_HOME/applications" | "$MOLE_CONFIG_HOME/systemd" | "$MOLE_CONFIG_HOME/systemd/user" | \
            "$MOLE_CONFIG_HOME/autostart" | "$HOME/.var" | "$HOME/.var/app") return 0 ;;
    esac
    return 1
}

# The path, its parents and the home must be plain: no symlinked component, so
# the rule's path is the path that gets removed. Must also be inside $HOME and
# owned by the user.
mole_path_is_plain_home_item() {
    local path="$1" resolved
    [[ "$path" == /* && "$path" != *"/../"* && "$path" != *"/./"* && "$path" != */.. && "$path" != */. ]] || return 1
    [[ "$path" == "$HOME/"* ]] || return 1
    [[ -e "$path" || -L "$path" ]] || return 1
    # $HOME itself may be a link (/home -> /var/home); below it nothing may be.
    local dir home_real
    dir=$(dirname -- "$path")
    resolved=$(readlink -f -- "$dir" 2> /dev/null) || return 1
    home_real=$(readlink -f -- "$HOME" 2> /dev/null) || return 1
    [[ "$resolved" == "$home_real${dir#"$HOME"}" ]] || return 1
    [[ -O "$path" ]] || return 1
    mole_is_protected_path "$path" && return 1
    return 0
}

# Move paths to Trash. Prints nothing; returns 1 when any path failed and
# leaves the failure reasons in MOLE_TRASH_ERRORS.
MOLE_TRASH_ERRORS=()
MOLE_TRASH_MOVED=0
mole_trash() {
    local command="$1"
    shift
    MOLE_TRASH_ERRORS=()
    MOLE_TRASH_MOVED=0
    local -a ok=()
    local path
    for path in "$@"; do
        if ! mole_path_is_plain_home_item "$path"; then
            MOLE_TRASH_ERRORS+=("$path: refused")
            log_operation "$command" SKIPPED "$path" "refused"
            continue
        fi
        ok+=("$path")
    done
    [[ ${#ok[@]} -gt 0 ]] || { [[ ${#MOLE_TRASH_ERRORS[@]} -eq 0 ]]; return; }
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    local helper="$SCRIPT_DIR/bin/trash-go" status src rest
    if [[ ! -x "$helper" ]]; then
        MOLE_TRASH_ERRORS+=("Trash helper missing: $helper")
        return 1
    fi
    # Only an explicit "ok" line per path counts. A helper that cannot run
    # (wrong architecture, missing loader) prints something else or nothing,
    # and that must read as failure, never as a completed move.
    local output helper_rc=0 moved=0
    output=$("$helper" -- "${ok[@]}" 2>&1) || helper_rc=$?
    while IFS=$'\t' read -r status src rest; do
        case "$status" in
            ok)
                moved=$((moved + 1))
                log_operation "$command" TRASHED "$src"
                ;;
            error)
                MOLE_TRASH_ERRORS+=("$src: $rest")
                log_operation "$command" FAILED "$src" "$rest"
                ;;
        esac
    done <<< "$output"
    if ((moved + ${#MOLE_TRASH_ERRORS[@]} < ${#ok[@]})) || { ((helper_rc != 0)) && ((${#MOLE_TRASH_ERRORS[@]} == 0)); }; then
        MOLE_TRASH_ERRORS+=("Trash helper failed (exit $helper_rc): ${output%%$'\n'*}")
    fi
    MOLE_TRASH_MOVED=$moved
    [[ ${#MOLE_TRASH_ERRORS[@]} -eq 0 ]]
}

# 0 when mole_remove_cache would remove this child of an allowlisted root.
# Dry runs size exactly these, so a preview never counts what a real run
# refuses (another device, not the user's, below a symlink).
mole_cache_child_ok() {
    local path="$1" root="$2"
    [[ "$path" == "$root/"* ]] || return 1
    mole_path_is_plain_home_item "$path" || return 1
    # rm --one-file-system stays on the device of the path it is given, so a
    # child that is itself a mount point (sshfs, a bind mount) would lose its
    # contents. Only children on the cache root's own device are removed.
    local path_dev root_dev
    path_dev=$(stat -c %d -- "$path" 2> /dev/null) || return 1
    root_dev=$(stat -c %d -- "$root" 2> /dev/null) || return 1
    [[ "$path_dev" == "$root_dev" ]]
}

# Remove one cache path directly. $2 is the allowlisted root it must sit under
# (the root itself is never removed). Stays on one filesystem.
mole_remove_cache() {
    local path="$1" root="$2" command="${3:-clean}" detail="${4:-}"
    mole_cache_child_ok "$path" "$root" || return 1
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    if rm -rf --one-file-system -- "$path" 2> /dev/null; then
        log_operation "$command" REMOVED "$path" "$detail"
        return 0
    fi
    # Partially removed (permission on a nested file): report what is left.
    log_operation "$command" FAILED "$path" "$detail"
    return 1
}
