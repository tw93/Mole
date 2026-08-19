#!/bin/bash
# Mole self-update: version discovery (GitHub + Homebrew), install-channel
# detection, the update-available banner cache, and the update flow itself.
# Extracted from the `mole` dispatcher, which now only routes.
#
# VERSION lives in `mole` (install.sh reads it from there); these functions
# read it at call time, so this file must be sourced after it is set.

set -euo pipefail

# The `mole` dispatcher assigns VERSION before sourcing this file, so the
# linter cannot see the assignment from here; declare it as an inherited value.
: "${VERSION:=}"

if [[ -n "${MOLE_MANAGE_UPDATE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_MANAGE_UPDATE_LOADED=1

curl_download_with_retry() {
    local url="$1"
    local output_file="$2"
    local attempt=1
    local max_attempts=3
    local curl_exit=0

    while true; do
        if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output_file"; then
            return 0
        else
            curl_exit=$?
        fi

        rm -f "$output_file" 2> /dev/null || true
        case "$curl_exit" in
            6 | 7 | 18 | 28 | 35 | 52 | 55 | 56) ;;
            *) return "$curl_exit" ;;
        esac

        if [[ "$attempt" -ge "$max_attempts" ]]; then
            return "$curl_exit"
        fi
        sleep 1 || return "$curl_exit"
        attempt=$((attempt + 1))
    done
}

_update_lock_path() {
    local install_dir="$1"
    printf '%s/.mole-update.lock/kernel.lock\n' "$install_dir"
}

_update_lock_process_start() {
    local pid="$1"
    LC_ALL=C /bin/ps -p "$pid" -o lstart= 2> /dev/null |
        /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | /usr/bin/head -1
}

_update_lock_current_shell_pid() {
    local variable_name="$1"
    local pid_file current_pid=""
    pid_file=$(/usr/bin/mktemp /tmp/mole-update-pid.XXXXXX) || return 1
    if ! /bin/sh -c 'printf "%s\n" "$PPID" > "$1"' sh "$pid_file"; then
        /bin/rm -f "$pid_file" 2> /dev/null || true # SAFE: exact mktemp-created PID probe file.
        return 1
    fi
    IFS= read -r current_pid < "$pid_file" || true
    /bin/rm -f "$pid_file" 2> /dev/null || true # SAFE: exact mktemp-created PID probe file.
    [[ "$current_pid" =~ ^[0-9]+$ ]] || return 1
    printf -v "$variable_name" '%s' "$current_pid"
}

_update_lock_mode_for_install_dir() {
    local install_dir="$1"
    local use_sudo=false
    [[ -d "$install_dir" && ! -L "$install_dir" ]] || return 1

    if [[ ${EUID:-0} -eq 0 ]]; then
        use_sudo=false
    elif [[ -w "$install_dir" ]]; then
        use_sudo=false
    else
        use_sudo=true
    fi
    _update_lock_path_has_unsafe_ancestor "$install_dir" "$use_sudo" && return 1
    printf '%s\n' "$use_sudo"
}

_update_lock_path_has_unsafe_ancestor() {
    local probe="$1"
    local use_sudo="$2"
    local current_uid owner_uid mode acl_listing
    current_uid=$(id -u 2> /dev/null || true)
    [[ "$current_uid" =~ ^[0-9]+$ ]] || return 0

    while true; do
        [[ ! -L "$probe" ]] || return 0
        owner_uid=$(/usr/bin/stat -f%u "$probe" 2> /dev/null || true)
        mode=$(/usr/bin/stat -f%Lp "$probe" 2> /dev/null || true)
        [[ "$owner_uid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || return 0
        if [[ "$use_sudo" == "true" || ${EUID:-0} -eq 0 ]]; then
            [[ "$owner_uid" -eq 0 ]] || return 0
            (((8#$mode & 0022) == 0)) || return 0
        elif [[ "$owner_uid" -ne 0 && "$owner_uid" -ne "$current_uid" ]]; then
            return 0
        else
            # A regular updater already writes through this tree. Accept
            # group-writable prefixes, but keep world-writable paths closed.
            (((8#$mode & 0002) == 0)) || return 0
        fi
        acl_listing=$(/bin/ls -lde "$probe" 2> /dev/null) || return 0
        if printf '%s\n' "$acl_listing" |
            /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:.*[[:space:]]allow[[:space:]]'; then
            return 0
        fi
        [[ "$probe" == "/" ]] && break
        local parent_probe="${probe%/*}"
        [[ "$parent_probe" != "$probe" ]] || return 0
        probe="$parent_probe"
        [[ -n "$probe" ]] || probe="/"
    done
    return 1
}

_update_lock_prepare_dir() {
    local lock_path="$1"
    local use_sudo="$2"
    local lock_dir expected_uid owner_uid mode acl_listing
    lock_dir=$(dirname "$lock_path")
    expected_uid=$(id -u 2> /dev/null || true)
    [[ "$expected_uid" =~ ^[0-9]+$ ]] || return 1

    if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
        if [[ "$use_sudo" == "true" ]]; then
            _update_lock_sudo mkdir -m 0700 "$lock_dir" 2> /dev/null || return 1
        else
            mkdir -m 0700 "$lock_dir" 2> /dev/null || return 1
        fi
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
    # macOS preserves inherited ACLs across mkdir -m 0700. Clear them before
    # opening the kernel lock and verify that no non-mode ACL entry remains.
    if [[ "$use_sudo" == "true" ]]; then
        _update_lock_sudo /bin/chmod -N "$lock_dir" 2> /dev/null || return 1
        acl_listing=$(_update_lock_sudo /bin/ls -lde "$lock_dir" 2> /dev/null) || return 1
    else
        /bin/chmod -N "$lock_dir" 2> /dev/null || return 1
        acl_listing=$(/bin/ls -lde "$lock_dir" 2> /dev/null) || return 1
    fi
    if printf '%s\n' "$acl_listing" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:'; then
        return 1
    fi
    if [[ "$use_sudo" == "true" ]]; then
        expected_uid=0
    fi
    if [[ "$use_sudo" == "true" ]]; then
        owner_uid=$(_update_lock_sudo /usr/bin/stat -f%u "$lock_dir" 2> /dev/null || true)
        mode=$(_update_lock_sudo /usr/bin/stat -f%Lp "$lock_dir" 2> /dev/null || true)
    else
        owner_uid=$(/usr/bin/stat -f%u "$lock_dir" 2> /dev/null || true)
        mode=$(/usr/bin/stat -f%Lp "$lock_dir" 2> /dev/null || true)
    fi
    [[ "$owner_uid" == "$expected_uid" && "$mode" =~ ^[0-7]+$ ]] || return 1
    (((8#$mode & 0077) == 0)) || return 1
}

_update_lock_sudo() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi
    sudo -n "$@"
}

# Whether the installer child will need sudo for this install dir. This MUST
# be at least as broad as install.sh's needs_sudo(), which checks the PARENT
# directory: on a machine where /usr/local/bin is user-writable but /usr/local
# is root's, the old narrower check here said "no sudo", so no pre-auth and no
# keepalive ran, MOLE_ASSUME_SUDO_AUTH stayed 0, and the installer then asked
# interactively at each privileged stretch: two password prompts per slow
# update, with the keepalive never in play. One predicate, one answer.
update_install_requires_sudo() {
    local install_dir="$1"
    # Mirror install.sh needs_sudo VERBATIM: when the install dir exists,
    # its own writability alone decides, and the parent matters only when
    # the dir is missing and must be created. The entry script's own file
    # permission is deliberately not consulted: the installer replaces it
    # through a same-directory temp file and an atomic mv, and a rename
    # needs directory write, never target-file write, so a read-only mole
    # in a writable dir updates fine without sudo.
    if [[ -e "$install_dir" ]]; then
        [[ ! -w "$install_dir" ]]
        return
    fi
    local parent_dir
    parent_dir="$(dirname "$install_dir")"
    [[ ! -w "$parent_dir" ]]
}

# The installer, and the lock helpers above, reuse this shell's sudo session
# through `sudo -n`. Ask a real child process whether that session reaches it
# rather than inferring it from a TTY check: the timestamp scope is sudo's
# decision, not ours, and the answer is the only thing that matters here.
_update_sudo_reaches_subprocess() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi
    /bin/sh -c 'sudo -n true' 2> /dev/null
}

_update_lock_read_owner() {
    local lock_path="$1"
    local use_sudo="$2"
    if [[ "$use_sudo" == "true" ]]; then
        _update_lock_sudo /bin/test -f "$lock_path" 2> /dev/null || return 1
        ! _update_lock_sudo /bin/test -L "$lock_path" 2> /dev/null || return 1
        _update_lock_sudo cat "$lock_path" 2> /dev/null
    else
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || return 1
        cat "$lock_path" 2> /dev/null
    fi
}

_update_lock_remove_control() {
    local control_path="$1"
    local use_sudo="$2"
    local lock_path="$3"
    local control_prefix control_suffix
    [[ -n "$control_path" ]] || return 0
    control_prefix="$(dirname "$lock_path")/control."
    [[ "$control_path" == "$control_prefix"* ]] || return 1
    control_suffix="${control_path#"$control_prefix"}"
    [[ -n "$control_suffix" && "$control_suffix" != */* ]] || return 1
    if [[ "$use_sudo" == "true" ]]; then
        _update_lock_sudo /bin/test -f "$control_path" 2> /dev/null || return 1
        ! _update_lock_sudo /bin/test -L "$control_path" 2> /dev/null || return 1
        _update_lock_sudo /bin/rm -f "$control_path" 2> /dev/null # SAFE: exact mktemp-created update lock control file.
    else
        [[ -f "$control_path" && ! -L "$control_path" ]] || return 1
        command rm -f "$control_path" 2> /dev/null # SAFE: exact mktemp-created update lock control file.
    fi
}

_update_acquire_lock() {
    local lock_path="$1"
    local use_sudo="${2:-false}"
    local control_path holder_pid owner_pid owner_start token owner_value="" attempt=0
    _update_lock_prepare_dir "$lock_path" "$use_sudo" || return 1
    if [[ "$use_sudo" == "true" ]]; then
        if _update_lock_sudo /bin/test -e "$lock_path" 2> /dev/null ||
            _update_lock_sudo /bin/test -L "$lock_path" 2> /dev/null; then
            _update_lock_sudo /bin/test -f "$lock_path" 2> /dev/null || return 1
            ! _update_lock_sudo /bin/test -L "$lock_path" 2> /dev/null || return 1
        fi
    elif [[ -e "$lock_path" || -L "$lock_path" ]]; then
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || return 1
    fi
    # Same mutex choice as install.sh: prefer the kernel lock, fall back to an
    # atomic mkdir where /usr/bin/lockf was never shipped (#1348). Requiring it
    # made `mo update` unusable on every macOS before it existed.
    local mutex_dir=""
    if [[ ! -x /usr/bin/lockf ]]; then
        [[ -x /bin/mkdir ]] || return 1
        mutex_dir="$(dirname "$lock_path")/holder"
    fi
    _update_lock_current_shell_pid owner_pid || return 1
    owner_start=$(_update_lock_process_start "$owner_pid")
    [[ -n "$owner_start" ]] || return 1
    if [[ "$use_sudo" == "true" ]]; then
        control_path=$(_update_lock_sudo /usr/bin/mktemp "$(dirname "$lock_path")/control.XXXXXX") || return 1
    else
        control_path=$(/usr/bin/mktemp "$(dirname "$lock_path")/control.XXXXXX") || return 1
    fi
    token="$owner_pid|$owner_start|${control_path##*.}"

    # shellcheck disable=SC2016 # The lock-holder shell expands these values.
    local holder_script='
        token="$1"; owner_pid="$2"; owner_start="$3"; lock_path="$4"; control_path="$5"; mutex_dir="$6"
        [ -f "$control_path" ] || exit 1
        if [ -n "$mutex_dir" ] && ! /bin/mkdir "$mutex_dir" 2>/dev/null; then
            previous=$(/bin/cat "$lock_path" 2>/dev/null || true)
            previous_pid=${previous%%|*}
            previous_rest=${previous#*|}
            previous_start=${previous_rest%%|*}
            owner_gone=1
            if [ -n "$previous_pid" ] && kill -0 "$previous_pid" 2>/dev/null; then
                current_start=$(LC_ALL=C /bin/ps -p "$previous_pid" -o lstart= 2>/dev/null |
                    /usr/bin/sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | /usr/bin/head -1)
                if [ "$current_start" = "$previous_start" ]; then
                    owner_gone=0
                fi
            fi
            [ "$owner_gone" = 1 ] || exit 1
            /bin/rmdir "$mutex_dir" 2>/dev/null || exit 1
            /bin/mkdir "$mutex_dir" 2>/dev/null || exit 1
        fi
        if ! printf "%s\n" "$token" > "$lock_path"; then
            [ -n "$mutex_dir" ] && /bin/rmdir "$mutex_dir" 2>/dev/null
            exit 1
        fi
        while [ -f "$control_path" ]; do
            kill -0 "$owner_pid" 2>/dev/null || break
            current_start=$(LC_ALL=C /bin/ps -p "$owner_pid" -o lstart= 2>/dev/null |
                /usr/bin/sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | /usr/bin/head -1)
            [ "$current_start" = "$owner_start" ] || break
            /bin/sleep 0.1
        done
        /bin/rm -f "$control_path" # SAFE: exact mktemp-created update lock control file.
        [ -n "$mutex_dir" ] && /bin/rmdir "$mutex_dir" 2>/dev/null
        exit 0
    '
    # Spelled out rather than built as a command array: an empty array expanded
    # under `set -u` is an unbound-variable error on the bash 3.2 macOS ships,
    # and the empty one would have been the mkdir path this exists to enable.
    if [[ -n "$mutex_dir" ]]; then
        if [[ "$use_sudo" == "true" ]]; then
            _update_lock_sudo /bin/sh -c "$holder_script" \
                sh "$token" "$owner_pid" "$owner_start" "$lock_path" "$control_path" "$mutex_dir" &
        else
            /bin/sh -c "$holder_script" \
                sh "$token" "$owner_pid" "$owner_start" "$lock_path" "$control_path" "$mutex_dir" &
        fi
    elif [[ "$use_sudo" == "true" ]]; then
        _update_lock_sudo /usr/bin/lockf -k -s -t 0 -w "$lock_path" /bin/sh -c "$holder_script" \
            sh "$token" "$owner_pid" "$owner_start" "$lock_path" "$control_path" "" &
    else
        /usr/bin/lockf -k -s -t 0 -w "$lock_path" /bin/sh -c "$holder_script" \
            sh "$token" "$owner_pid" "$owner_start" "$lock_path" "$control_path" "" &
    fi
    holder_pid=$!

    while [[ "$attempt" -lt 100 ]]; do
        if ! kill -0 "$holder_pid" 2> /dev/null; then
            wait "$holder_pid" 2> /dev/null || true
            _update_lock_remove_control "$control_path" "$use_sudo" "$lock_path" || true
            return 1
        fi
        owner_value=$(_update_lock_read_owner "$lock_path" "$use_sudo" || true)
        if [[ "$owner_value" == "$token" ]]; then
            UPDATE_LOCK_CONTROL="$control_path"
            UPDATE_LOCK_HOLDER_PID="$holder_pid"
            UPDATE_LOCK_ACQUIRED=true
            return 0
        fi
        /bin/sleep 0.05
        attempt=$((attempt + 1))
    done

    _update_lock_remove_control "$control_path" "$use_sudo" "$lock_path" || true
    wait "$holder_pid" 2> /dev/null || true
    return 1
}

_update_release_lock() {
    local lock_path="${1:-}"
    local use_sudo="${2:-false}"
    local control_path="${3:-}"
    local holder_pid="${4:-}"
    local acquired="${5:-false}"
    [[ "$acquired" == "true" ]] || return 0
    _update_lock_remove_control "$control_path" "$use_sudo" "$lock_path" || true
    [[ "$holder_pid" =~ ^[0-9]+$ ]] && wait "$holder_pid" 2> /dev/null || true
    UPDATE_LOCK_CONTROL=""
    UPDATE_LOCK_HOLDER_PID=""
    UPDATE_LOCK_ACQUIRED=false
}

_update_new_install_receipt() {
    local prefix="${1:-update}"
    printf '%s-%s-%s-%s\n' "$prefix" "$(date +%s)" "$$" "${RANDOM:-0}"
}

_MOLE_UPDATE_VERIFIED_VERSION=""
_MOLE_UPDATE_VERIFIED_COMMIT=""

# An installer exit status is not release proof. Re-open the installed
# generation under the same target-adjacent lock and bind its metadata to this
# exact attempt before any success message is shown.
_update_verify_installed_generation() {
    local update_ref="$1"
    local install_dir="$2"
    local config_dir="$3"
    local mole_path="$4"
    local expected_commit="${5:-}"
    local expected_receipt="$6"

    _MOLE_UPDATE_VERIFIED_VERSION=""
    _MOLE_UPDATE_VERIFIED_COMMIT=""

    local verification_lock=""
    local lock_uses_sudo="false"
    lock_uses_sudo=$(_update_lock_mode_for_install_dir "$install_dir") || return 1
    verification_lock=$(_update_lock_path "$install_dir")
    _update_acquire_lock "$verification_lock" "$lock_uses_sudo" || return 1

    local lock_control="$UPDATE_LOCK_CONTROL"
    local lock_holder_pid="$UPDATE_LOCK_HOLDER_PID"
    local lock_acquired="$UPDATE_LOCK_ACQUIRED"
    local verification_status=0
    local installed_channel=""
    local installed_receipt=""
    local repair_reason=""
    installed_channel=$(MOLE_CONFIG_DIR="$config_dir" get_install_channel 2> /dev/null || true)
    installed_receipt=$(MOLE_CONFIG_DIR="$config_dir" get_install_receipt 2> /dev/null || true)
    repair_reason=$(MOLE_CONFIG_DIR="$config_dir" manual_install_repair_reason 2> /dev/null || true)

    if [[ "$installed_receipt" != "$expected_receipt" || -n "$repair_reason" ]]; then
        verification_status=1
    elif [[ "$update_ref" == "main" ]]; then
        local installed_commit=""
        local version_output=""
        local probe_rc=0
        installed_commit=$(MOLE_CONFIG_DIR="$config_dir" get_install_commit 2> /dev/null || true)
        version_output=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$mole_path" --version 2> /dev/null) || probe_rc=$?
        if [[ "$installed_channel" != "nightly" || $probe_rc -ne 0 || -z "$version_output" ]]; then
            verification_status=1
        fi
        if [[ $verification_status -eq 0 && "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
            if [[ ! "$installed_commit" =~ ^[0-9a-f]{7,40}$ ||
                "${installed_commit:0:7}" != "${expected_commit:0:7}" ]]; then
                verification_status=1
            fi
        fi
        if [[ $verification_status -eq 0 && "$installed_commit" =~ ^[0-9a-f]{7,40}$ ]]; then
            _MOLE_UPDATE_VERIFIED_COMMIT="${installed_commit:0:7}"
        fi
    else
        local installed_version=""
        local version_output=""
        local probe_rc=0
        version_output=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$mole_path" --version 2> /dev/null) || probe_rc=$?
        if [[ $probe_rc -eq 0 ]]; then
            installed_version=$(printf '%s\n' "$version_output" | awk 'NF {print $NF; exit}')
        fi
        if [[ "$installed_channel" != "stable" || "$installed_version" != "${update_ref#V}" ]]; then
            verification_status=1
        else
            _MOLE_UPDATE_VERIFIED_VERSION="$installed_version"
        fi
    fi

    _update_release_lock "$verification_lock" "$lock_uses_sudo" \
        "$lock_control" "$lock_holder_pid" "$lock_acquired"
    return "$verification_status"
}

_update_print_verified_success() {
    local update_ref="$1"
    local success_label="$2"
    if [[ "$update_ref" == "main" && -n "$_MOLE_UPDATE_VERIFIED_COMMIT" ]]; then
        printf '\n%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} Updated to ${success_label}, ${_MOLE_UPDATE_VERIFIED_COMMIT}"
    elif [[ "$update_ref" == "main" ]]; then
        printf '\n%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} Updated to ${success_label}"
    else
        printf '\n%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} Updated to ${success_label}, ${_MOLE_UPDATE_VERIFIED_VERSION}"
    fi
}

# Last-resort self-heal for a failed staged install. The staged path runs
# through local bootstrap code (temp file, registry, exec) that is frozen on
# the user's machine, which is exactly what a broken installed version cannot
# fix by itself (#1297). Streaming install.sh from main straight into bash
# skips all of it, so a server-side install.sh fix reaches every stuck install
# on its next `mo update`. install.sh only dispatches on its final line, and
# pipefail surfaces a truncated download, so a partial script runs nothing.
_update_self_heal_reinstall() {
    local assume_sudo="$1"
    local update_ref="$2"
    local install_dir="$3"
    local config_dir="$4"
    local mole_path="$5"
    local success_label="$6"
    local expected_commit="${7:-}"
    local install_commit=""
    local install_receipt=""
    install_receipt=$(_update_new_install_receipt heal)

    if [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
        install_commit="$expected_commit"
    fi

    echo "Retrying with a direct reinstall from GitHub..."

    local heal_output=""
    if command -v curl > /dev/null 2>&1; then
        heal_output=$(
            set -o pipefail
            curl -fsSL --connect-timeout 10 --max-time 60 \
                "https://raw.githubusercontent.com/tw93/mole/main/install.sh" |
                MOLE_ASSUME_SUDO_AUTH="$assume_sudo" MOLE_VERSION="$update_ref" \
                    MOLE_INSTALL_COMMIT="$install_commit" MOLE_INSTALL_RECEIPT="$install_receipt" \
                    bash -s -- --prefix "$install_dir" --config "$config_dir" 2>&1
        ) || {
            [[ -n "$heal_output" ]] && printf '%s\n' "$heal_output" | tail -5 >&2
            return 1
        }
    elif command -v wget > /dev/null 2>&1; then
        heal_output=$(
            set -o pipefail
            wget --timeout=10 --tries=3 -qO- \
                "https://raw.githubusercontent.com/tw93/mole/main/install.sh" |
                MOLE_ASSUME_SUDO_AUTH="$assume_sudo" MOLE_VERSION="$update_ref" \
                    MOLE_INSTALL_COMMIT="$install_commit" MOLE_INSTALL_RECEIPT="$install_receipt" \
                    bash -s -- --prefix "$install_dir" --config "$config_dir" 2>&1
        ) || {
            [[ -n "$heal_output" ]] && printf '%s\n' "$heal_output" | tail -5 >&2
            return 1
        }
    else
        return 1
    fi

    _update_verify_installed_generation \
        "$update_ref" "$install_dir" "$config_dir" "$mole_path" \
        "$install_commit" "$install_receipt" || return 1
    _update_print_verified_success "$update_ref" "$success_label"
}

_update_print_manual_reinstall() {
    local update_ref="$1"
    local install_dir="$2"
    local config_dir="$3"
    local quoted_ref quoted_install_dir quoted_config_dir
    printf -v quoted_ref '%q' "$update_ref"
    printf -v quoted_install_dir '%q' "$install_dir"
    printf -v quoted_config_dir '%q' "$config_dir"
    printf '%s Reinstall manually: curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | MOLE_VERSION=%s bash -s -- --prefix %s --config %s\n' \
        "${ICON_REVIEW}" "$quoted_ref" "$quoted_install_dir" "$quoted_config_dir"
}

# Version discovery must report "unknown" by returning empty, never by failing.
# These run inside `latest=$(...)` command substitutions in a shell with
# `set -euo pipefail`, so a nonzero pipeline (curl refused by a flaky proxy, or
# grep finding no match) would kill the whole command before the caller's own
# fallback and error message could run. `mo update` exited 1 with no output at
# all that way. The trailing `|| true` is what keeps the failure recoverable.
get_latest_version() {
    curl -fsSL --connect-timeout 2 --max-time 3 -H "Cache-Control: no-cache" \
        "https://raw.githubusercontent.com/tw93/mole/main/mole" 2> /dev/null |
        grep '^VERSION=' | head -1 | sed 's/VERSION="\(.*\)"/\1/' || true
}

get_latest_version_from_github() {
    local version
    version=$(curl -fsSL --connect-timeout 2 --max-time 3 \
        "https://api.github.com/repos/tw93/mole/releases/latest" 2> /dev/null |
        grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    version="${version#v}"
    version="${version#V}"
    echo "$version"
}

# Foreground `mo update` version discovery. The single-shot helpers above stay
# fast because the update-available banner calls them on every command; an
# explicit update is worth a bounded retry instead, since the same proxy reset
# that breaks the installer download also breaks this request.
resolve_latest_stable_version() {
    local attempt=1
    local max_attempts=3
    local candidate=""

    while true; do
        candidate=$(get_latest_version_from_github)
        [[ -z "$candidate" ]] && candidate=$(get_latest_version)
        if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        [[ "$attempt" -ge "$max_attempts" ]] && return 0
        sleep 1 || return 0
        attempt=$((attempt + 1))
    done
}

run_brew_command() {
    local timeout_seconds="$1"
    shift

    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        run_with_timeout "$timeout_seconds" "$@"
}

run_brew_detect() {
    run_brew_command "${MOLE_HOMEBREW_DETECT_TIMEOUT:-2}" "$@"
}

run_brew_query() {
    run_brew_command "${MOLE_HOMEBREW_QUERY_TIMEOUT:-5}" "$@"
}

brew_mole_formula_installed() {
    local brew_cmd="${1:-brew}"
    run_brew_detect "$brew_cmd" list mole > /dev/null 2>&1
}

get_homebrew_latest_version() {
    command -v brew > /dev/null 2>&1 || return 1

    local line candidate=""

    # Prefer local tap outdated info to avoid notifying before formula is available.
    line=$(run_brew_query brew outdated --formula --verbose mole 2> /dev/null | head -1 || true)
    if [[ "$line" == *"< "* ]]; then
        candidate="${line##*< }"
        candidate="${candidate%% *}"
    fi

    # Fallback for environments where outdated output is unavailable.
    if [[ -z "$candidate" ]]; then
        line=$(run_brew_query brew info mole 2> /dev/null | awk 'NR==1 { print; exit }' || true)
        line="${line#==> }"
        line="${line#*: }"
        if [[ "$line" == stable* ]]; then
            candidate=$(printf '%s\n' "$line" | awk '{print $2}')
        fi
    fi

    [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}
resolve_mole_source_path() {
    # MOLE_ENTRY_SCRIPT is set by the `mole` entrypoint before this file is
    # sourced. Do NOT fall back to BASH_SOURCE[0] first: in here it names this
    # lib file, so the update would target lib/manage/update.sh instead of the
    # mole binary the user invoked.
    local mole_path="${MOLE_ENTRY_SCRIPT:-${BASH_SOURCE[0]:-$0}}"
    if [[ "$mole_path" != /* ]]; then
        if [[ "$mole_path" == */* ]]; then
            mole_path="$(cd "$(dirname "$mole_path")" 2> /dev/null && pwd)/${mole_path##*/}"
        else
            mole_path=$(command -v "$mole_path" 2> /dev/null || true)
        fi
    fi
    [[ -n "$mole_path" ]] && printf '%s\n' "$mole_path"
}

manual_install_repair_reason() {
    local config_root="${MOLE_CONFIG_DIR:-$SCRIPT_DIR}"
    local reason=""
    local helper

    if [[ -f "$config_root/.helper_install_incomplete" ]]; then
        reason="incomplete helper install"
    fi

    for helper in analyze status; do
        if [[ ! -x "$config_root/bin/${helper}-go" ]]; then
            [[ -n "$reason" ]] && reason+=", "
            reason+="missing ${helper}-go"
        fi
    done

    [[ -n "$reason" ]] && printf '%s\n' "$reason"
}

is_homebrew_mole_path() {
    local mole_path="$1"
    local has_brew="$2"
    local link_target=""
    [[ -n "$mole_path" ]] || return 1

    if [[ -L "$mole_path" ]]; then
        link_target=$(readlink "$mole_path" 2> /dev/null) || true
        if [[ "$link_target" == *"Cellar/mole"* ]]; then
            if $has_brew; then
                brew_mole_formula_installed brew && return 0
            fi
            return 1
        fi
        return 1
    fi

    if [[ -f "$mole_path" ]]; then
        # Paths are quoted so Homebrew bottle relocation cannot break parsing
        # when the prefix contains spaces (e.g. Applite under "Application Support").
        case "$mole_path" in
            "/opt/homebrew/bin/mole" | "/usr/local/bin/mole")
                if [[ -d "/opt/homebrew/Cellar/mole" ]] || [[ -d "/usr/local/Cellar/mole" ]]; then
                    if $has_brew; then
                        brew_mole_formula_installed brew && return 0
                    else
                        return 0 # Cellar exists, probably Homebrew install
                    fi
                fi
                ;;
        esac
    fi

    return 1
}

# Install detection (Homebrew vs manual).
# Always follows the invoked Mole script, never PATH, so update and remove act
# on the Mole the user actually ran instead of another copy earlier in PATH.
is_homebrew_install() {
    local has_brew=false
    if command -v brew > /dev/null 2>&1; then
        has_brew=true
    fi

    local mole_path
    mole_path=$(resolve_mole_source_path || true)
    is_homebrew_mole_path "$mole_path" "$has_brew"
}

get_install_channel() {
    # Try user config dir first (matches install.sh behavior), fallback to SCRIPT_DIR
    local channel_file="${MOLE_CONFIG_DIR:-$HOME/.config/mole}/install_channel"
    if [[ ! -f "$channel_file" ]]; then
        channel_file="$SCRIPT_DIR/install_channel"
    fi
    local channel="stable"
    if [[ -f "$channel_file" ]]; then
        channel=$(sed -n 's/^CHANNEL=\(.*\)$/\1/p' "$channel_file" | head -1)
    fi
    case "$channel" in
        nightly | dev | stable) printf '%s\n' "$channel" ;;
        *) printf 'stable\n' ;;
    esac
}

# Read one field out of the install channel receipt, empty when absent.
# User config dir first (matches install.sh), then the install directory.
_read_install_channel_field() {
    local key="$1"
    local channel_file="${MOLE_CONFIG_DIR:-$HOME/.config/mole}/install_channel"
    if [[ ! -f "$channel_file" ]]; then
        channel_file="$SCRIPT_DIR/install_channel"
    fi
    if [[ -f "$channel_file" ]]; then
        sed -n "s/^${key}=\(.*\)$/\1/p" "$channel_file" | head -1
    fi
}

get_install_commit() {
    _read_install_channel_field COMMIT_HASH
}

get_install_receipt() {
    _read_install_channel_field INSTALL_RECEIPT
}

get_latest_commit_from_github() {
    local lookup_scope="${1:-allow-git-fallback}"
    local response=""
    local sha=""
    if command -v curl > /dev/null 2>&1; then
        response=$(curl -fsSL --connect-timeout 2 --max-time 3 \
            "https://api.github.com/repos/tw93/mole/commits/main" 2> /dev/null || true)
    elif command -v wget > /dev/null 2>&1; then
        response=$(wget --timeout=3 --tries=1 -qO- \
            "https://api.github.com/repos/tw93/mole/commits/main" 2> /dev/null || true)
    fi
    sha=$(printf '%s\n' "$response" |
        grep '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]\{40\}"' | head -1 | sed -E 's/.*"sha"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || sha=""
    if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s\n' "$sha"
        return 0
    fi

    # Background notices are best-effort and should not spawn a Git process.
    # Explicit update paths retain the bounded fallback below.
    if [[ "$lookup_scope" == "api-only" ]]; then
        printf '\n'
        return 0
    fi

    # The unauthenticated API can be rate-limited even while ordinary GitHub
    # access works. Keep the fallback bounded and accept only main's exact SHA.
    if command -v git > /dev/null 2>&1; then
        # Ignore ambient credential helpers and URL rewrites: this public,
        # read-only probe must resolve the literal GitHub remote or fail.
        if response=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            /usr/bin/env \
            -u GIT_CONFIG_PARAMETERS \
            -u GIT_EXEC_PATH \
            -u GIT_DIR \
            -u GIT_WORK_TREE \
            -u GIT_COMMON_DIR \
            -u GIT_CONFIG \
            -u GIT_PROXY_COMMAND \
            -u GIT_SSH \
            -u GIT_SSH_COMMAND \
            -u GIT_SSL_NO_VERIFY \
            GIT_TERMINAL_PROMPT=0 \
            GIT_ASKPASS=/usr/bin/false \
            SSH_ASKPASS=/usr/bin/false \
            GIT_CONFIG_NOSYSTEM=1 \
            GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_COUNT=0 \
            LC_ALL=C \
            git -c credential.helper= -c core.askPass=/usr/bin/false \
            -c protocol.allow=never -c protocol.https.allow=always \
            -c http.sslVerify=true -C / \
            ls-remote https://github.com/tw93/mole.git refs/heads/main \
            2> /dev/null); then
            sha=$(printf '%s\n' "$response" |
                awk '$2 == "refs/heads/main" { print $1; exit }')
        else
            sha=""
        fi
    fi
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || sha=""
    printf '%s\n' "$sha"
}

mole_update_message_cache_is_current() {
    local msg_cache="$1"
    [[ -f "$msg_cache" && -s "$msg_cache" ]] || return 1

    local mole_path
    mole_path=$(resolve_mole_source_path || true)
    [[ -n "$mole_path" && -e "$mole_path" ]] || return 0

    local cache_mtime mole_mtime
    cache_mtime=$(get_file_mtime "$msg_cache")
    mole_mtime=$(get_file_mtime "$mole_path")

    if [[ "$cache_mtime" =~ ^[0-9]+$ && "$mole_mtime" =~ ^[0-9]+$ &&
        "$cache_mtime" -gt 0 && "$mole_mtime" -gt 0 &&
        "$cache_mtime" -lt "$mole_mtime" ]]; then
        return 1
    fi

    return 0
}

read_update_message_cache() {
    local msg_cache="$1"
    if mole_update_message_cache_is_current "$msg_cache"; then
        cat "$msg_cache" 2> /dev/null || echo ""
    else
        : > "$msg_cache" 2> /dev/null || true
        echo ""
    fi
}

# Background update notice
check_for_updates() {
    local msg_cache="$HOME/.cache/mole/update_message"
    ensure_user_dir "$(dirname "$msg_cache")"
    ensure_user_file "$msg_cache"

    (
        (
            local channel
            channel=$(get_install_channel)

            if [[ "$channel" == "nightly" ]]; then
                # Nightly: compare commit hashes instead of version numbers
                local installed_commit latest_commit
                installed_commit=$(get_install_commit)
                latest_commit=$(get_latest_commit_from_github api-only)

                if [[ -n "$installed_commit" && -n "$latest_commit" && "${installed_commit:0:7}" != "${latest_commit:0:7}" ]]; then
                    printf "\nNew nightly commit %s available, run %smo update --nightly%s\n\n" "${latest_commit:0:7}" "$GREEN" "$NC" > "$msg_cache"
                else
                    echo -n > "$msg_cache"
                fi
            else
                local latest

                latest=$(get_latest_version_from_github)
                if [[ -z "$latest" ]]; then
                    latest=$(get_latest_version)
                fi

                if [[ -n "$latest" && "$VERSION" != "$latest" && "$(printf '%s\n' "$VERSION" "$latest" | sort -V | head -1)" == "$VERSION" ]]; then
                    if is_homebrew_install; then
                        # For Homebrew, only notify if the brew tap has the new version available locally
                        local brew_latest
                        brew_latest=$(get_homebrew_latest_version || true)
                        if [[ -n "$brew_latest" && "$brew_latest" != "$VERSION" && "$(printf '%s\n' "$VERSION" "$brew_latest" | sort -V | head -1)" == "$VERSION" ]]; then
                            printf "\nUpdate %s available, run %smo update%s\n\n" "$brew_latest" "$GREEN" "$NC" > "$msg_cache"
                        else
                            echo -n > "$msg_cache"
                        fi
                    else
                        printf "\nUpdate %s available, run %smo update%s\n\n" "$latest" "$GREEN" "$NC" > "$msg_cache"
                    fi
                else
                    echo -n > "$msg_cache"
                fi
            fi
        ) > /dev/null 2>&1 < /dev/null &
    )
}

# UI helpers
show_brand_banner() {
    cat << EOF
${GREEN} __  __       _      ${NC}
${GREEN}|  \/  | ___ | | ___ ${NC}
${GREEN}| |\/| |/ _ \| |/ _ \\${NC}
${GREEN}| |  | | (_) | |  __/${NC}  ${BLUE}https://mole.fit${NC}
${GREEN}|_|  |_|\___/|_|\___|${NC}  ${GREEN}${MOLE_TAGLINE}${NC}

EOF
}

show_version() {
    local os_ver
    if command -v sw_vers > /dev/null; then
        os_ver=$(sw_vers -productVersion)
    else
        os_ver="Unknown"
    fi

    local arch
    arch=$(uname -m)

    local kernel
    kernel=$(uname -r)

    local sip_status
    if command -v csrutil > /dev/null; then
        sip_status=$(csrutil status 2> /dev/null | grep -o "enabled\|disabled" || echo "Unknown")
        sip_status="$(LC_ALL=C tr '[:lower:]' '[:upper:]' <<< "${sip_status:0:1}")${sip_status:1}"
    else
        sip_status="Unknown"
    fi

    local disk_free
    disk_free=$(get_free_space)

    local install_method="Manual"
    if is_homebrew_install; then
        install_method="Homebrew"
    fi

    local channel
    channel=$(get_install_channel)

    # A reader like `mo --version | head -1` closes the pipe after the first
    # line; the remaining writes then fail with SIGPIPE and bash prints a
    # "write error: Broken pipe" the user never asked for. A closed reader
    # means "stop", so stop quietly.
    printf '\nMole version %s\n' "$VERSION" 2> /dev/null || return 0
    if [[ "$channel" == "nightly" ]]; then
        local commit
        commit=$(get_install_commit)
        if [[ -n "$commit" ]]; then
            printf 'Channel: Nightly (%s)\n' "$commit" 2> /dev/null || return 0
        else
            printf 'Channel: Nightly\n' 2> /dev/null || return 0
        fi
    fi
    printf 'macOS: %s\n' "$os_ver" 2> /dev/null || return 0
    printf 'Architecture: %s\n' "$arch" 2> /dev/null || return 0
    printf 'Kernel: %s\n' "$kernel" 2> /dev/null || return 0
    printf 'SIP: %s\n' "$sip_status" 2> /dev/null || return 0
    printf 'Disk Free: %s\n' "$disk_free" 2> /dev/null || return 0
    printf 'Install: %s\n' "$install_method" 2> /dev/null || return 0
    printf 'Shell: %s\n\n' "${SHELL:-Unknown}" 2> /dev/null || return 0
}

show_help() {
    show_brand_banner
    echo
    printf "%s%s%s\n" "$BLUE" "COMMANDS" "$NC"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo" "$NC" "Main menu"
    for entry in "${MOLE_COMMANDS[@]}"; do
        local name="${entry%%:*}"
        local desc="${entry#*:}"
        local display="mo $name"
        [[ "$name" == "help" ]] && display="mo --help"
        [[ "$name" == "version" ]] && display="mo --version"
        printf "  %s%-28s%s %s\n" "$GREEN" "$display" "$NC" "$desc"
    done
    echo
    printf "  %s%-28s%s %s\n" "$GREEN" "mo clean --dry-run" "$NC" "Preview cleanup"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo clean --whitelist" "$NC" "Manage protected caches"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo clean --trash" "$NC" "Clean into the Trash, restorable"

    printf "  %s%-28s%s %s\n" "$GREEN" "mo optimize --dry-run" "$NC" "Preview optimization"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo optimize --whitelist" "$NC" "Manage protected items"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo uninstall --dry-run" "$NC" "Preview app uninstall"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo history --json" "$NC" "Export cleanup history"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo purge --dry-run" "$NC" "Preview project purge"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo installer --dry-run" "$NC" "Preview installer cleanup"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo touchid enable --dry-run" "$NC" "Preview Touch ID setup"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo completion --dry-run" "$NC" "Preview shell completion edits"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo purge --paths" "$NC" "Configure scan directories"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo analyze /Volumes" "$NC" "Analyze external drives only"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo update --force" "$NC" "Force reinstall latest stable version"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo update --nightly" "$NC" "Install latest unreleased main branch build"
    printf "  %s%-28s%s %s\n" "$GREEN" "mo remove --dry-run" "$NC" "Preview Mole removal"
    echo
    printf "%s%s%s\n" "$BLUE" "OPTIONS" "$NC"
    printf "  %s%-28s%s %s\n" "$GREEN" "--debug" "$NC" "Show detailed operation logs"
    echo
}

# Update flow (Homebrew or installer).
update_mole() (
    local force_update="${1:-false}"
    local nightly_update="${2:-false}"
    local update_interrupted=false
    local sudo_keepalive_pid=""
    local UPDATE_LOCK_CONTROL=""
    local UPDATE_LOCK_HOLDER_PID=""
    local UPDATE_LOCK_ACQUIRED=false

    # Cleanup function for sudo keepalive
    _update_cleanup() {
        [[ -n "$sudo_keepalive_pid" ]] && _stop_sudo_keepalive "$sudo_keepalive_pid" || true
        if [[ -n "${verification_lock:-}" && "$UPDATE_LOCK_ACQUIRED" == "true" ]]; then
            _update_release_lock "$verification_lock" "${lock_uses_sudo:-false}" \
                "$UPDATE_LOCK_CONTROL" "$UPDATE_LOCK_HOLDER_PID" "$UPDATE_LOCK_ACQUIRED"
        fi
    }
    trap '_update_cleanup; update_interrupted=true; echo ""; exit 130' INT TERM
    trap '_update_cleanup' EXIT

    if is_homebrew_install; then
        if [[ "$nightly_update" == "true" ]]; then
            local review_icon="${ICON_REVIEW:-⊙}"
            log_error "Nightly update is only available for script installations. Homebrew installs follow stable releases."
            printf '%s Reinstall via script to use: mo update --nightly\n' "$review_icon"
            exit 1
        fi
        update_via_homebrew "$VERSION"
        exit 0
    fi

    # Resolve the invoked Mole up front so the installer targets this manual
    # install, not another mole earlier in PATH. Fail before any download.
    local mole_path
    if ! mole_path=$(resolve_mole_source_path); then
        log_error "Unable to resolve current Mole path"
        exit 1
    fi
    local install_dir
    if ! install_dir="$(cd "$(dirname "$mole_path")" && pwd)"; then
        log_error "Unable to resolve current Mole install directory"
        exit 1
    fi
    local latest=""
    local latest_commit=""
    local download_label="Downloading latest version..."
    local install_label="Installing update..."
    local final_success_label="latest version"
    local switch_to_stable_channel=false
    local repair_install=false
    local repair_reason=""

    if [[ "$nightly_update" == "true" ]]; then
        latest="main"
        download_label="Downloading nightly installer..."
        install_label="Installing nightly update..."
        final_success_label="nightly build"

        latest_commit=$(get_latest_commit_from_github)
        if [[ "$force_update" != "true" ]]; then
            if [[ ! "$latest_commit" =~ ^[0-9a-f]{40}$ ]]; then
                log_error "Unable to resolve latest nightly commit. No update was installed."
                echo -e "${ICON_REVIEW} Check GitHub access and try again."
                echo -e "${ICON_REVIEW} To explicitly reinstall anyway: ${GRAY}mo update --nightly --force${NC}"
                exit 1
            fi

            local installed_commit
            installed_commit=$(get_install_commit)

            if [[ "$installed_commit" =~ ^[0-9a-f]{7,40}$ && "$latest_commit" =~ ^[0-9a-f]{40}$ &&
                "${installed_commit:0:7}" == "${latest_commit:0:7}" ]]; then
                repair_reason=$(manual_install_repair_reason || true)
                if [[ -n "$repair_reason" ]]; then
                    repair_install=true
                else
                    echo ""
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest nightly, ${latest_commit:0:7}"
                    echo ""
                    exit 0
                fi
            fi
        fi
    else
        # Announce before resolving, never after. The bounded retry can spend
        # ~20s across three rounds on a flaky proxy, and an unannounced wait that
        # long reads as a hang, which is the report this retry was added for.
        local check_label="Checking for updates..."
        if [[ -t 1 ]]; then
            start_inline_spinner "$check_label"
        else
            echo "${check_label%...}"
        fi
        latest=$(resolve_latest_stable_version)
        if [[ -t 1 ]]; then stop_inline_spinner; fi

        if [[ -z "$latest" ]]; then
            log_error "Unable to check for updates. Check network connection."
            echo -e "${ICON_REVIEW} Check if you can access GitHub, https://github.com"
            echo -e "${ICON_REVIEW} Try again with: ${GRAY}mo update${NC}"
            exit 1
        fi
        if [[ ! "$latest" =~ ^[Vv]?[0-9]+(\.[0-9]+)*$ ]]; then
            log_error "Invalid version response: $latest"
            echo -e "${ICON_REVIEW} Try again later or use: ${GRAY}mo update --nightly${NC}"
            exit 1
        fi

        local install_channel
        install_channel=$(get_install_channel)
        if [[ "$install_channel" == "nightly" || "$install_channel" == "dev" ]]; then
            switch_to_stable_channel=true
        fi

        if [[ "$switch_to_stable_channel" == "true" ]]; then
            install_label="Switching to stable channel..."
        elif [[ "$VERSION" == "$latest" && "$force_update" != "true" ]]; then
            repair_reason=$(manual_install_repair_reason || true)
            if [[ -n "$repair_reason" ]]; then
                repair_install=true
            else
                echo ""
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version, ${VERSION}"
                echo ""
                exit 0
            fi
        fi
    fi

    if [[ "$repair_install" == "true" ]]; then
        download_label="Downloading repair installer..."
        install_label="Repairing Mole installation..."
        log_warning "Mole installation needs repair: $repair_reason"
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "$download_label"
    else
        echo "${download_label%...}"
    fi

    local installer_ref="main"
    if [[ "$nightly_update" != "true" ]]; then
        installer_ref="V${latest#V}"
    fi
    local installer_url="https://raw.githubusercontent.com/tw93/mole/${installer_ref}/install.sh"
    local tmp_installer
    tmp_installer="$(mktemp_file)" || {
        log_error "Update failed"
        exit 1
    }

    local download_error=""
    if command -v curl > /dev/null 2>&1; then
        download_error=$(curl_download_with_retry "$installer_url" "$tmp_installer" 2>&1) || {
            local curl_exit=$?
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            rm -f "$tmp_installer"
            log_error "Update failed, curl error: $curl_exit"

            case $curl_exit in
                6) echo -e "${ICON_REVIEW} Could not resolve host. Check DNS or network connection." ;;
                7) echo -e "${ICON_REVIEW} Failed to connect. Check network or proxy settings." ;;
                22) echo -e "${ICON_REVIEW} HTTP 404 Not Found. The installer may have moved." ;;
                28) echo -e "${ICON_REVIEW} Connection timed out. Try again or check firewall." ;;
                35 | 56) echo -e "${ICON_REVIEW} TLS connection reset. A local proxy or VPN is likely blocking GitHub." ;;
                *) echo -e "${ICON_REVIEW} Check network connection and try again." ;;
            esac
            echo -e "${ICON_REVIEW} URL: $installer_url"
            exit 1
        }
    elif command -v wget > /dev/null 2>&1; then
        download_error=$(wget --timeout=10 --tries=3 -qO "$tmp_installer" "$installer_url" 2>&1) || {
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            rm -f "$tmp_installer"
            log_error "Update failed, wget error"
            echo -e "${ICON_REVIEW} Check network connection and try again."
            echo -e "${ICON_REVIEW} URL: $installer_url"
            exit 1
        }
    else
        if [[ -t 1 ]]; then stop_inline_spinner; fi
        rm -f "$tmp_installer"
        log_error "curl or wget required"
        echo -e "${ICON_REVIEW} Install curl with: ${GRAY}brew install curl${NC}"
        exit 1
    fi

    if [[ -t 1 ]]; then stop_inline_spinner; fi
    chmod +x "$tmp_installer"

    local requires_sudo="false"
    if update_install_requires_sudo "$install_dir"; then
        requires_sudo="true"
    fi

    if [[ "$requires_sudo" == "true" ]]; then
        if ! request_sudo_access "Mole update requires admin access"; then
            log_error "Update aborted, admin access denied"
            rm -f "$tmp_installer"
            exit 1
        fi
        # Start sudo keepalive to prevent cache expiration during install
        sudo_keepalive_pid=$(_start_sudo_keepalive)

        # The installer runs as a child process and reuses this session through
        # `sudo -n`. macOS scopes the sudo timestamp to the controlling
        # terminal, and falls back to the parent PID when there is none, so in a
        # terminal-less run (CI, cron, `ssh` without -t, an editor's shell pane)
        # the credential this shell just obtained does not reach any child.
        # Probe that handoff instead of guessing from `-t 0`; failing here beats
        # failing halfway through a privileged install.
        if ! _update_sudo_reaches_subprocess; then
            _update_cleanup
            rm -f "$tmp_installer"
            log_error "Admin access cannot be handed to the installer in this environment"
            echo -e "${ICON_REVIEW} Run ${GRAY}mo update${NC} from a terminal, or cache credentials first: ${GRAY}sudo -v && mo update${NC}"
            exit 1
        fi
    fi

    local installer_assume_sudo_auth="0"
    if [[ "$requires_sudo" == "true" ]]; then
        installer_assume_sudo_auth="1"
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "$install_label"
    else
        echo "${install_label%...}"
    fi

    process_install_output() {
        local output="$1"
        local fallback_version="$2"
        local success_label="$3"
        if [[ -t 1 ]]; then stop_inline_spinner; fi

        # One blank line opens the block and nothing adds another inside it.
        # The installer lines and the result below are one list; a gap between
        # them read as if the update had finished twice.
        local filtered_output
        filtered_output=$(printf '%s\n' "$output" | sed '/^$/d')
        printf '\n'
        if [[ -n "$filtered_output" ]]; then
            printf '%s\n' "$filtered_output"
        fi

        if ! printf '%s\n' "$output" | grep -Eq "Updated to latest version|Already on latest version"; then
            local new_version
            new_version=$(printf '%s\n' "$output" | sed -n 's/.*-> \([^[:space:]]\{1,\}\).*/\1/p' | head -1)
            if [[ -z "$new_version" ]]; then
                new_version=$(printf '%s\n' "$output" | sed -n 's/.*version[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' | head -1)
            fi
            if [[ -z "$new_version" ]]; then
                new_version=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                    "$mole_path" --version 2> /dev/null | awk 'NF {print $NF; exit}' || true)
            fi
            if [[ -z "$new_version" ]]; then
                new_version="$fallback_version"
            fi
            printf '%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} Updated to ${success_label}, ${new_version:-unknown}"
        else
            printf '\n'
        fi
    }

    local install_output
    local update_tag="V${latest#V}"
    local config_dir="${MOLE_CONFIG_DIR:-$SCRIPT_DIR}"
    if [[ ! -f "$config_dir/lib/core/common.sh" ]]; then
        config_dir="$HOME/.config/mole"
    fi

    _run_staged_installer() {
        local update_ref="$1"
        local expected_commit="${2:-}"
        shift 2
        local install_receipt=""
        install_receipt=$(_update_new_install_receipt update)

        local installer_rc=0
        install_output=$(MOLE_ASSUME_SUDO_AUTH="$installer_assume_sudo_auth" \
            MOLE_VERSION="$update_ref" MOLE_INSTALL_COMMIT="$expected_commit" \
            MOLE_INSTALL_RECEIPT="$install_receipt" \
            "$tmp_installer" --prefix "$install_dir" --config "$config_dir" "$@" 2>&1) || installer_rc=$?
        [[ $installer_rc -eq 0 ]] || return "$installer_rc"

        _update_verify_installed_generation \
            "$update_ref" "$install_dir" "$config_dir" "$mole_path" \
            "$expected_commit" "$install_receipt"
    }

    _print_failed_installer_output() {
        printf '%s\n' "$install_output" |
            sed '/Updated to latest version/d; /Already on latest version/d' |
            tail -10 >&2
    }

    if [[ "$nightly_update" == "true" ]]; then
        if _run_staged_installer "main" "$latest_commit"; then
            process_install_output "$install_output" "$latest" "$final_success_label"
        else
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            if ! _update_self_heal_reinstall "$installer_assume_sudo_auth" "main" "$install_dir" "$config_dir" "$mole_path" "$final_success_label" "$latest_commit"; then
                rm -f "$tmp_installer"
                _update_cleanup
                log_error "Nightly update failed"
                _print_failed_installer_output
                _update_print_manual_reinstall "main" "$install_dir" "$config_dir"
                exit 1
            fi
        fi
    elif [[ "$force_update" == "true" || "$switch_to_stable_channel" == "true" || "$repair_install" == "true" ]]; then
        if _run_staged_installer "$update_tag" ""; then
            process_install_output "$install_output" "$latest" "$final_success_label"
        else
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            if ! _update_self_heal_reinstall "$installer_assume_sudo_auth" "$update_tag" "$install_dir" "$config_dir" "$mole_path" "$final_success_label"; then
                rm -f "$tmp_installer"
                _update_cleanup
                log_error "Update failed"
                _print_failed_installer_output
                _update_print_manual_reinstall "$update_tag" "$install_dir" "$config_dir"
                exit 1
            fi
        fi
    else
        if _run_staged_installer "$update_tag" "" --update; then
            process_install_output "$install_output" "$latest" "$final_success_label"
        else
            if _run_staged_installer "$update_tag" ""; then
                process_install_output "$install_output" "$latest" "$final_success_label"
            else
                if [[ -t 1 ]]; then stop_inline_spinner; fi
                if ! _update_self_heal_reinstall "$installer_assume_sudo_auth" "$update_tag" "$install_dir" "$config_dir" "$mole_path" "$final_success_label"; then
                    rm -f "$tmp_installer"
                    _update_cleanup
                    log_error "Update failed"
                    _print_failed_installer_output
                    _update_print_manual_reinstall "$update_tag" "$install_dir" "$config_dir"
                    exit 1
                fi
            fi
        fi
    fi

    rm -f "$tmp_installer"
    rm -f "$HOME/.cache/mole/update_message"

    # Cleanup and reset trap
    _update_cleanup
    trap - INT TERM EXIT
)
