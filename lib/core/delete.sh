#!/bin/bash
# Mole CLI (Linux) - the two ways a path leaves:
#   mole_trash         user files, uninstall leftovers: freedesktop Trash via
#                      bin/trash-go (internal/xdgtrash), restorable.
#   mole_remove_cache  regenerable caches from Clean's allowlist: removed
#                      directly, since moving a cache to Trash frees nothing.
#   mole_remove_artifact  project build output purge picked: removed
#                      directly after its identity and scan root are checked
#                      again, since build output in the Trash frees nothing.
# All refuse protected locations, and none ever runs as root.

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
    # The parent is cut off without a fork where that equals dirname (no
    # trailing or doubled slash), and one readlink resolves both folders
    # unless a newline in either would split its output wrongly.
    local dir home_real both
    if [[ "$path" == */ || "$path" == *//* ]]; then
        dir=$(dirname -- "$path")
    else
        dir="${path%/*}"
        [[ -n "$dir" ]] || dir=/
    fi
    if [[ "$dir$HOME" == *$'\n'* ]]; then
        resolved=$(readlink -f -- "$dir" 2> /dev/null) || return 1
        home_real=$(readlink -f -- "$HOME" 2> /dev/null) || return 1
    else
        both=$(readlink -f -- "$dir" "$HOME" 2> /dev/null) || return 1
        [[ "$both" == *$'\n'* ]] || return 1
        resolved="${both%%$'\n'*}"
        home_real="${both#*$'\n'}"
    fi
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

# 0 when root is a Flatpak or Snap app's whole cache folder, the app's own
# XDG cache home, which is one rule root.
mole_app_cache_root() {
    case "$1" in
        "$HOME/.var/app/"*/cache | "$HOME/snap/"*/.cache) return 0 ;;
    esac
    return 1
}

# How a name directly inside an app's cache folder is treated, the same way
# the native rules in lib/clean/rules.sh treat that name in ~/.cache:
#   keep    never a rule natively: Spotify's offline music, the model stores,
#           the browsers Playwright, Cypress and Puppeteer install, uv (only
#           uv cache prune may touch it), Wine (only its .msi downloads go)
#           and, without --gpu-shaders, the Mesa and NVIDIA shader caches
#   narrow  natively only some folders inside it are rule roots; the same
#           leaves (mole_app_cache_leaves) are the only ones that go
#   whole   reviewed: the native rule root is nested only because the tool
#           keeps its cache there (mozilla/firefox)
# Prints nothing and fails for a name no native rule narrows: the whole child
# goes. tests/clean.bats fails when a narrowed native rule has no entry here.
mole_app_cache_name_kind() {
    case "$1" in
        spotify | huggingface | lm-studio | ms-playwright | Cypress | puppeteer | uv | wine) echo keep ;;
        # Rejected as native rules: downloads no longer online, the search
        # index database, the learned input dictionary.
        winetricks | tracker3 | ibus) echo keep ;;
        # GPU shader caches go only with mo clean --gpu-shaders, as in ~/.cache.
        mesa_shader_cache | mesa_shader_cache_db | nvidia)
            [[ "${GPU_SHADERS:-false}" == true ]] && return 1
            echo keep
            ;;
        JetBrains | Google | lutris | deno | bazel | webkitgtk | thunderbird | pypoetry | node) echo narrow ;;
        mozilla) echo whole ;;
        *) return 1 ;;
    esac
}

# The rule roots inside a narrowed name, as globs relative to the app's cache
# folder, matching the native rules: JetBrains and Android Studio IDE logs only
# (LocalHistory lives beside them and is not recoverable), Lutris's installer
# downloads only (its shaders are opt-in GPU caches, its other folders hold
# sign-in tokens), Deno's import caches, Bazel's repository cache, WebKitGTK's
# HTTP and media caches, Thunderbird's cache2, Poetry's cache and artifacts
# (virtualenvs stay), Corepack. One glob per line.
mole_app_cache_leaves() {
    case "$1" in
        JetBrains) echo 'JetBrains/*/log' ;;
        Google) echo 'Google/AndroidStudio*/log' ;;
        lutris) echo 'lutris/installer' ;;
        deno) printf '%s\n' deno/deps deno/remote deno/gen deno/npm deno/registries ;;
        bazel) echo 'bazel/_bazel_*/cache/repos' ;;
        webkitgtk) printf '%s\n' webkitgtk/WebKitCache webkitgtk/MediaCache ;;
        thunderbird) echo 'thunderbird/*/cache2' ;;
        pypoetry) printf '%s\n' pypoetry/cache pypoetry/artifacts ;;
        node) echo 'node/corepack' ;;
    esac
}

# 0 when rel (a path relative to an app's cache folder) is something that
# folder's rule removes: a direct child whose name is not kept or narrowed, a
# direct child of a narrowed name's leaf, or (Google only) a folder under
# Google that is not Android Studio's.
mole_app_cache_path_ok() {
    local rel="$1" top kind leaf parent slashes want
    # "Google/" would read as a Google folder that is not Android Studio's.
    [[ -z "$rel" || "$rel" == /* || "$rel" == */ || "$rel" == *//* ]] && return 1
    top="${rel%%/*}"
    kind=$(mole_app_cache_name_kind "$top") || kind=""
    case "$kind" in
        keep) return 1 ;;
        "" | whole)
            [[ "$rel" != */* ]]
            return
            ;;
    esac
    [[ "$rel" == */* ]] || return 1
    if [[ "$top" == Google && "$rel" == Google/* && "${rel#Google/}" != */* ]]; then
        [[ "${rel#Google/}" != AndroidStudio* ]]
        return
    fi
    parent="${rel%/*}"
    slashes="${parent//[!\/]/}"
    while IFS= read -r leaf; do
        want="${leaf//[!\/]/}"
        # shellcheck disable=SC2053  # The leaf is a glob on purpose.
        [[ ${#want} -eq ${#slashes} && "$parent" == $leaf ]] && return 0
    done < <(mole_app_cache_leaves "$top")
    return 1
}

# 0 when mole_remove_cache would remove this child of an allowlisted root.
# Dry runs size exactly these, so a preview never counts what a real run
# refuses (another device, not the user's, below a symlink).
mole_cache_child_ok() {
    local path="$1" root="$2"
    [[ "$path" == "$root/"* ]] || return 1
    mole_path_is_plain_home_item "$path" || return 1
    # A Flatpak or Snap app's whole cache folder is a rule root, and inside it
    # the names native rules narrow or never clean keep that treatment.
    if mole_app_cache_root "$root"; then
        mole_app_cache_path_ok "${path#"$root/"}" || return 1
    fi
    # rm --one-file-system stays on the device of the path it is given, so a
    # child that is itself a mount point (sshfs, a bind mount) would lose its
    # contents. Only children on the cache root's own device are removed.
    local devs
    devs=$(stat -c %d -- "$root" "$path" 2> /dev/null) || return 1
    [[ "$devs" == *$'\n'* && "${devs%%$'\n'*}" == "${devs#*$'\n'}" ]]
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

# Remove one purge candidate. $2 is the physical scan root it was found under,
# $3 the device:inode it had when it was reviewed. The folder must still be
# that folder, below the root through real folders only, the user's, on its
# parent's filesystem (never a mount point), and not protected. The caller has
# already rechecked activity and authored content.
mole_artifact_path_ok() {
    local path="$1" root="$2" identity="$3" parent real_parent now dev parent_dev
    [[ "$path" == /* && "$root" == /* && "$root" != / ]] || return 1
    [[ "$path" != *"/../"* && "$path" != *"/./"* && "$path" != */.. && "$path" != */. ]] || return 1
    [[ "$path" == "$root/"* ]] || return 1
    [[ -d "$path" && ! -L "$path" && -O "$path" ]] || return 1
    parent="${path%/*}"
    real_parent=$(readlink -e -- "$parent" 2> /dev/null) || return 1
    [[ "$real_parent" == "$parent" ]] || return 1
    [[ "$(readlink -e -- "$root" 2> /dev/null)" == "$root" ]] || return 1
    now=$(stat -c '%d:%i' -- "$path" 2> /dev/null) || return 1
    [[ -n "$identity" && "$now" == "$identity" ]] || return 1
    dev="${now%%:*}"
    parent_dev=$(stat -c %d -- "$parent" 2> /dev/null) || return 1
    [[ "$dev" == "$parent_dev" ]] || return 1
    # Below a home under /var (Fedora Atomic's /var/home) the protected list
    # is read on the home's logical spelling, as the scan did.
    local home_real check="$path"
    home_real=$(readlink -e -- "$HOME" 2> /dev/null) || home_real="$HOME"
    [[ "$path" == "$home_real/"* ]] && check="$HOME/${path#"$home_real"/}"
    mole_is_protected_path "$check" && return 1
    mole_is_protected_path "${check%/*}" && return 1
    return 0
}

# Returns 0 when removed, 1 when refused (nothing touched), 2 when rm ran but
# left something behind. MOLE_REMOVING names the folder while rm runs, so an
# interrupt handler can log it.
MOLE_REMOVING=""
mole_remove_artifact() {
    local path="$1" root="$2" identity="$3" detail="${4:-}"
    mole_artifact_path_ok "$path" "$root" "$identity" || {
        log_operation purge SKIPPED "$path" "refused"
        return 1
    }
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    MOLE_REMOVING="$path"
    if rm -rf --one-file-system -- "$path" 2> /dev/null; then
        MOLE_REMOVING=""
        log_operation purge REMOVED "$path" "$detail"
        return 0
    fi
    MOLE_REMOVING=""
    log_operation purge FAILED "$path" "partly removed"
    return 2
}
