#!/bin/bash
# Mole CLI (Linux) - the "new version available" line in the main menu.
#
# At most one lookup a day, in the background, with a short timeout, so the
# menu never waits on the network. The answer is cached as the latest version
# string; the line is rebuilt from it on every read, so it disappears as soon
# as the installed version catches up. MOLE_NO_UPDATE_CHECK=1 turns it off.

if [[ -n "${MOLE_UPDATE_NOTICE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UPDATE_NOTICE_LOADED=1

readonly MOLE_UPDATE_NOTICE_DAY=86400
readonly MOLE_UPDATE_NOTICE_RETRY=3600

mole_update_notice_dir() { printf '%s' "$MOLE_CACHE_HOME/mole"; }

# The lookup itself: the newest V*-linux release, through the installer's own
# --latest. Prints a version or nothing. Tests replace this function.
mole_update_fetch_latest() {
    local installer="$SCRIPT_DIR/install.sh"
    [[ -f "$installer" ]] || return 1
    if command -v timeout > /dev/null 2>&1; then
        timeout 8 bash "$installer" --latest 2> /dev/null
    else
        bash "$installer" --latest 2> /dev/null
    fi
}

mole_update_notice_write() {
    local path="$1" value="$2" scratch
    scratch=$(umask 077 && mktemp "$path.XXXXXX" 2> /dev/null) || return 1
    if printf '%s' "$value" > "$scratch" 2> /dev/null && mv -f "$scratch" "$path" 2> /dev/null; then
        return 0
    fi
    rm -f -- "$scratch" # SAFE: the mktemp scratch file made just above
    return 1
}

mole_update_notice_lookup() {
    local dir="$1" now="$2" latest
    latest="$(mole_update_fetch_latest)" || return 0
    latest="${latest//[$'\n\r ']/}"
    [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    mole_update_notice_write "$dir/update_latest" "$latest" || return 0
    mole_update_notice_write "$dir/update_check" "$now $MOLE_UPDATE_NOTICE_DAY"$'\n' || true
}

# Start a lookup when the last one is old enough. $1 = wait: run it in the
# foreground (tests); anything else detaches it. Returns quietly in every
# case that should not look.
mole_update_notice_check() {
    local mode="${1:-background}" dir now checked=0 interval=0
    [[ "${MOLE_NO_UPDATE_CHECK:-}" == "1" ]] && return 0
    # Only the installed tree can act on the line (mo update refuses others).
    mole_runs_installed_tree || return 0
    dir="$(mole_update_notice_dir)"
    mkdir -p "$dir" 2> /dev/null || return 0
    now=$(date +%s)
    if [[ -f "$dir/update_check" ]]; then
        { read -r checked interval < "$dir/update_check"; } 2> /dev/null || true
        # A clock set backwards reads as expired, never as fresh.
        if [[ "$checked" =~ ^[0-9]{1,12}$ && "$interval" =~ ^[0-9]{1,6}$ ]] &&
            ((now >= 10#$checked && now - 10#$checked < 10#$interval)); then
            return 0
        fi
    fi
    # Claim the slot first: a lookup that fails is retried in an hour, not on
    # every menu open.
    mole_update_notice_write "$dir/update_check" "$now $MOLE_UPDATE_NOTICE_RETRY"$'\n' || return 0
    if [[ "$mode" == wait ]]; then
        mole_update_notice_lookup "$dir" "$now"
    else
        (mole_update_notice_lookup "$dir" "$now" > /dev/null 2>&1 < /dev/null &)
    fi
    return 0
}

# Print the line to show, or nothing.
mole_update_notice_message() {
    [[ "${MOLE_NO_UPDATE_CHECK:-}" == "1" ]] && return 0
    mole_runs_installed_tree || return 0
    local latest=""
    # The cache file has no trailing newline, so read reports failure on a good value.
    { read -r latest < "$(mole_update_notice_dir)/update_latest"; } 2> /dev/null || [[ -n "$latest" ]] || return 0
    [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    [[ "$latest" != "$VERSION" ]] || return 0
    [[ "$(printf '%s\n%s\n' "$VERSION" "$latest" | sort -V | head -1)" == "$VERSION" ]] || return 0
    printf 'Update %s available, run mo update' "$latest"
}
