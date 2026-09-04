#!/bin/bash
# Mole - Base Definitions and Utilities
# Core definitions, constants, and basic utility functions used by all modules

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_BASE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_BASE_LOADED=1

# Cleanup libraries read "$DRY_RUN" in 70+ places without a default, and only the
# command entry points (bin/clean.sh and friends) assign it. Anything that sources
# a lib directly then calls into it therefore aborts on "unbound variable" under
# set -u, in branches that are only reached with specific fixtures. Default it
# once here rather than at each read site; entry points still assign over it.
: "${DRY_RUN:=false}"

# ============================================================================
# Color Definitions
# ANSI escapes are emitted only when nothing rules them out, in this order:
#   1. NO_COLOR non-empty disables them (https://no-color.org). It is checked
#      before the test-mode force below because several tests set both.
#   2. Test mode forces them on: the suite runs without a terminal and asserts
#      deterministic escape output (scripts/test.sh).
#   3. TERM=dumb cannot render them.
#   4. stdout that is not a terminal would carry them into a pipe or a file,
#      where they break grep and diff and stay in a log read back later.
# The decision is made once here, not per write: the variables are readonly,
# and re-probing would flip inside every command substitution.
# ============================================================================
mole_color=0
if [[ -n "${NO_COLOR:-}" ]]; then
    mole_color=0
elif [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
    mole_color=1
elif [[ "${TERM:-}" != "dumb" ]] && [[ -t 1 ]]; then
    mole_color=1
fi

if [[ "$mole_color" == "0" ]]; then
    readonly ESC=""
    readonly GREEN=""
    readonly BLUE=""
    readonly CYAN=""
    readonly YELLOW=""
    readonly PURPLE=""
    readonly PURPLE_BOLD=""
    readonly RED=""
    readonly GRAY=""
    readonly NC=""
else
    readonly ESC=$'\033'
    readonly GREEN="${ESC}[0;32m"
    readonly BLUE="${ESC}[1;34m"
    readonly CYAN="${ESC}[0;36m"
    readonly YELLOW="${ESC}[0;33m"
    readonly PURPLE="${ESC}[0;35m"
    readonly PURPLE_BOLD="${ESC}[1;35m"
    readonly RED="${ESC}[0;31m"
    readonly GRAY="${ESC}[0;38;5;244m"
    readonly NC="${ESC}[0m"
fi
unset mole_color

# Probe several process patterns without collapsing pgrep errors into "not
# running". Arguments are selector/pattern pairs, for example:
#   mole_pgrep_any -x Xcode -f com.apple.dt.XCTest
# Returns 0 when any pattern matches, 1 only when every probe reports no match,
# and 2 when no pattern matches but at least one probe could not be completed.
mole_pgrep_any() {
    if [[ $# -eq 0 || $(($# % 2)) -ne 0 ]] || ! command -v pgrep > /dev/null 2>&1; then
        return 2
    fi

    local aggregate_rc=1
    local selector pattern probe_rc
    while [[ $# -gt 0 ]]; do
        selector="$1"
        pattern="$2"
        shift 2

        probe_rc=0
        if pgrep "$selector" "$pattern" > /dev/null 2>&1; then
            return 0
        else
            probe_rc=$?
        fi
        [[ $probe_rc -eq 1 ]] || aggregate_rc=2
    done

    return "$aggregate_rc"
}

# ============================================================================
# Icon Definitions
# ============================================================================
readonly ICON_CONFIRM="◎"
readonly ICON_ADMIN="⚙"
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="◎"
readonly ICON_EMPTY="○"
readonly ICON_SOLID="●"
readonly ICON_LIST="•"
readonly ICON_SUBLIST="↳"
readonly ICON_ARROW="➤"
readonly ICON_DRY_RUN="→"
readonly ICON_REVIEW="⊙"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"
readonly ICON_INFO="ℹ"

# ============================================================================
# LaunchServices Utility
# ============================================================================

# Locate the lsregister binary (path varies across macOS versions).
# MOLE_LSREGISTER_PATH overrides the lookup when it is set, including when it
# is set empty, which disables every lsregister-backed scan. Tests use the
# empty form to keep a multi-second LaunchServices dump out of assertions that
# have nothing to do with launch services.
get_lsregister_path() {
    if [[ -n "${MOLE_LSREGISTER_PATH+x}" ]]; then
        echo "$MOLE_LSREGISTER_PATH"
        return 0
    fi

    local -a candidates=(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        "/System/Library/CoreServices/Frameworks/LaunchServices.framework/Support/lsregister"
    )
    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
    return 0
}

# ============================================================================
# Global Configuration Constants
# ============================================================================
readonly MOLE_TEMP_FILE_AGE_DAYS=7       # Temp file retention (days)
readonly MOLE_ORPHAN_AGE_DAYS=30         # Orphaned data retention (days)
readonly MOLE_DOTDIR_ORPHAN_AGE_DAYS=60  # Orphan dotfile hint threshold (days)
readonly MOLE_MAX_PARALLEL_JOBS=15       # Parallel job limit
readonly MOLE_MAIL_DOWNLOADS_MIN_KB=5120 # Mail attachment size threshold
readonly MOLE_MAIL_AGE_DAYS=30           # Mail attachment retention (days)
readonly MOLE_LOG_AGE_DAYS=7             # Log retention (days)
readonly MOLE_CRASH_REPORT_AGE_DAYS=7    # Crash report retention (days)
readonly MOLE_SAVED_STATE_AGE_DAYS=30    # Saved state retention (days) - increased for safety
readonly MOLE_GPU_CACHE_AGE_DAYS=1       # Rebuildable GPU cache retention (days)
readonly MOLE_TM_BACKUP_SAFE_HOURS=48    # TM backup safety window (hours)
readonly MOLE_MAX_DS_STORE_FILES=500     # Max .DS_Store files to clean per scan
readonly MOLE_MAX_ORPHAN_ITERATIONS=100  # Max iterations for orphaned app data scan
readonly MOLE_ONE_GIB_KB=$((1024 * 1024))
readonly MOLE_ONE_GB_BYTES=1000000000

# ============================================================================
# Whitelist Configuration
# ============================================================================
readonly FINDER_METADATA_SENTINEL="FINDER_METADATA"
declare -a DEFAULT_WHITELIST_PATTERNS=(
    "$HOME/Library/Caches/ms-playwright*"
    "$HOME/.gradle/caches/*"
    "$HOME/.gradle/daemon/*"
    "$HOME/.ollama/models/*"
    "$HOME/Library/Caches/com.nssurge.surge-mac/*"
    "$HOME/Library/Application Support/com.nssurge.surge-mac/*"
    "$HOME/Library/Caches/org.R-project.R/R/renv/*"
    "$HOME/Library/Caches/JetBrains*"
    "$HOME/Library/Caches/com.jetbrains.toolbox*"
    "$HOME/Library/Caches/tealdeer/tldr-pages"
    "$HOME/Library/Application Support/JetBrains*"
    "$HOME/Library/Caches/com.apple.finder"
    "$HOME/Library/Mobile Documents*"
    "$FINDER_METADATA_SENTINEL"
)

declare -a DEFAULT_OPTIMIZE_WHITELIST_PATTERNS=(
)

# Safety patterns always merge into an existing user whitelist file.
# Replacement semantics (V1.7.5+) treat the file as the complete set, so
# protections added later (FINDER_METADATA in V1.9.9) never reached users who
# already had a whitelist. Only hard safety belongs here; optional convenience
# defaults stay in DEFAULT_WHITELIST_PATTERNS and remain fully replaceable.
declare -a SAFETY_WHITELIST_PATTERNS=(
    "$FINDER_METADATA_SENTINEL"
    # `clean_user_essentials` sweeps every child of ~/Library/Caches, so a row
    # that only lives in DEFAULT_WHITELIST_PATTERNS stops protecting these the
    # moment a user saves one custom entry. Removing them breaks macOS search,
    # font rendering and iCloud sync rather than costing a rebuild, and
    # pypoetry/virtualenvs holds live interpreters every Poetry project points
    # at, not cached downloads. Hard safety, so they merge unconditionally.
    "$HOME/Library/Caches/com.apple.FontRegistry*"
    "$HOME/Library/Caches/com.apple.spotlight*"
    "$HOME/Library/Caches/com.apple.Spotlight*"
    "$HOME/Library/Caches/CloudKit*"
    "$HOME/Library/Caches/pypoetry/virtualenvs*"
)

# Resolve the cache root used by GitHub CLI without following filesystem
# links. Both cleanup and whitelist inventory consume this value so a custom
# XDG_CACHE_HOME cannot make the saved protection point at a different path.
mole_github_cli_cache_root() {
    local cache_root
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        cache_root="$XDG_CACHE_HOME"
    else
        [[ "${HOME:-}" == /* ]] || return 1
        cache_root="$HOME/.cache"
    fi

    [[ "$cache_root" == /* && ! "$cache_root" =~ [[:cntrl:]] ]] || return 1
    case "$cache_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac

    cache_root="${cache_root%/}"
    local home_root="${HOME:-}"
    home_root="${home_root%/}"
    case "$cache_root" in
        "" | / | "$home_root") return 1 ;;
    esac

    printf '%s\n' "$cache_root"
}

# Resolve the per-user cache root reported by macOS. Keep the resolver shared
# so cleanup and whitelist inventory always describe the same path.
mole_darwin_user_cache_root() {
    declare -f run_with_timeout > /dev/null 2>&1 || return 1

    local cache_root=""
    local resolver_rc=0
    cache_root=$(run_with_timeout "${MOLE_TIMEOUT_QUICK_DETECT_SEC:-3}" \
        /usr/bin/getconf DARWIN_USER_CACHE_DIR 2> /dev/null) || resolver_rc=$?
    [[ $resolver_rc -eq 0 ]] || return "$resolver_rc"

    [[ "$cache_root" == /* && ! "$cache_root" =~ [[:cntrl:]] ]] || return 1
    case "$cache_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac

    cache_root="${cache_root%/}"
    local home_root="${HOME:-}"
    home_root="${home_root%/}"
    case "$cache_root" in
        "" | / | "$home_root") return 1 ;;
    esac

    printf '%s\n' "$cache_root"
}

# Resolve the effective Go cache roots through the Go tool itself. Cleanup and
# whitelist inventory share this resolver so a relocated GOCACHE or
# GOMODCACHE never falls back to a different hardcoded path.
mole_go_cache_root() {
    local cache_kind="$1"
    case "$cache_kind" in
        GOCACHE | GOMODCACHE) ;;
        *) return 1 ;;
    esac
    declare -f run_with_timeout > /dev/null 2>&1 || return 1
    command -v go > /dev/null 2>&1 || return 1

    local cache_root=""
    local resolver_rc=0
    cache_root=$(run_with_timeout "${MOLE_TIMEOUT_QUICK_DETECT_SEC:-3}" \
        go env "$cache_kind" 2> /dev/null) || resolver_rc=$?
    [[ $resolver_rc -eq 0 ]] || return "$resolver_rc"

    [[ "$cache_root" == /* && ! "$cache_root" =~ [[:cntrl:]] ]] || return 1
    case "$cache_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac

    cache_root="${cache_root%/}"
    local home_root="${HOME:-}"
    home_root="${home_root%/}"
    case "$cache_root" in
        "" | / | "$home_root" | "$home_root/Library" | \
            "$home_root/Library/Caches" | "$home_root/.cache" | "$home_root/go")
            return 1
            ;;
    esac

    printf '%s\n' "$cache_root"
}

# Deno's root is intentionally review-only, but the generic user-cache sweep
# and the large-file hint still need to agree on which path must be preserved.
mole_deno_cache_root() {
    local cache_root="${DENO_DIR:-$HOME/Library/Caches/deno}"
    [[ "$cache_root" == /* && ! "$cache_root" =~ [[:cntrl:]] ]] || return 1
    case "$cache_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac

    cache_root="${cache_root%/}"
    local home_root="${HOME:-}"
    home_root="${home_root%/}"
    case "$cache_root" in
        "" | / | "$home_root" | "$home_root/Library" | \
            "$home_root/Library/Caches" | "$home_root/.cache")
            return 1
            ;;
    esac

    printf '%s\n' "$cache_root"
}

# Append any missing SAFETY_WHITELIST_PATTERNS to WHITELIST_PATTERNS.
# When CURRENT_WHITELIST_PATTERNS is declared (manage UI), keep it in sync.
ensure_safety_whitelist_patterns() {
    local safety existing found
    [[ ${#SAFETY_WHITELIST_PATTERNS[@]} -eq 0 ]] && return 0

    for safety in "${SAFETY_WHITELIST_PATTERNS[@]}"; do
        found=false
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$existing" == "$safety" ]]; then
                    found=true
                    break
                fi
            done
        fi
        if [[ "$found" == "false" ]]; then
            WHITELIST_PATTERNS+=("$safety")
        fi

        if declare -p CURRENT_WHITELIST_PATTERNS &> /dev/null 2>&1; then
            found=false
            if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
                for existing in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
                    if [[ "$existing" == "$safety" ]]; then
                        found=true
                        break
                    fi
                done
            fi
            if [[ "$found" == "false" ]]; then
                CURRENT_WHITELIST_PATTERNS+=("$safety")
            fi
        fi
    done
}

# Load and validate the invoking user's clean whitelist. Both `clean` and
# `purge` use safe_remove as their final deletion sink, so they must share the
# same source of WHITELIST_PATTERNS before either command starts scanning.
# Keeping this here also makes the validation rules independent of a command
# entrypoint, which prevents a new cleanup command from silently skipping the
# whitelist initialization (see #1427).
load_mole_whitelist() {
    local whitelist_home="${1:-}"
    if [[ -z "$whitelist_home" ]]; then
        whitelist_home=$(get_invoking_home)
    fi
    [[ -n "$whitelist_home" ]] || whitelist_home="${HOME:-}"
    MOLE_USER_HOME="$whitelist_home"

    WHITELIST_PATTERNS=()
    WHITELIST_WARNINGS=()

    local whitelist_file="$MOLE_USER_HOME/.config/mole/whitelist"
    if [[ -f "$whitelist_file" ]]; then
        local line duplicate existing
        while IFS= read -r line; do
            # shellcheck disable=SC2295
            line="${line#"${line%%[![:space:]]*}"}"
            # shellcheck disable=SC2295
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue

            [[ "$line" == ~* ]] && line="${line/#~/$MOLE_USER_HOME}"
            line="${line//\$HOME/$MOLE_USER_HOME}"
            line="${line//\$\{HOME\}/$MOLE_USER_HOME}"
            if [[ "$line" =~ \.\. ]]; then
                WHITELIST_WARNINGS+=("Path traversal not allowed: $line")
                continue
            fi

            if [[ "$line" != "$FINDER_METADATA_SENTINEL" ]]; then
                if [[ "$line" =~ [[:cntrl:]] ]]; then
                    WHITELIST_WARNINGS+=("Invalid path format: $line")
                    continue
                fi

                if [[ "$line" != /* ]]; then
                    WHITELIST_WARNINGS+=("Must be absolute path: $line")
                    continue
                fi
            fi

            if [[ "$line" =~ // ]]; then
                WHITELIST_WARNINGS+=("Consecutive slashes: $line")
                continue
            fi

            case "$line" in
                / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /etc | /etc/* | /var/db | /var/db/*)
                    WHITELIST_WARNINGS+=("Protected system path: $line")
                    continue
                    ;;
            esac

            duplicate="false"
            if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
                for existing in "${WHITELIST_PATTERNS[@]}"; do
                    if [[ "$line" == "$existing" ]]; then
                        duplicate="true"
                        break
                    fi
                done
            fi
            [[ "$duplicate" == "true" ]] && continue
            WHITELIST_PATTERNS+=("$line")
        done < "$whitelist_file"
    elif [[ ${#DEFAULT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
    fi

    # Expand patterns once, before hot cleanup loops call is_path_whitelisted.
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local -a expanded_patterns=()
        local pattern expanded
        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            expanded="${pattern/#\~/$MOLE_USER_HOME}"
            expanded_patterns+=("$expanded")
        done
        WHITELIST_PATTERNS=("${expanded_patterns[@]}")
    fi

    # Existing user files replace convenience defaults; hard safety entries
    # remain enforced for every command that loads this shared policy.
    ensure_safety_whitelist_patterns
}

# ============================================================================
# BSD Stat Compatibility
# ============================================================================
readonly STAT_BSD="/usr/bin/stat"

# Get file size in bytes
get_file_size() {
    local file="$1"
    local result
    result=$($STAT_BSD -f%z "$file" 2> /dev/null)
    echo "${result:-0}"
}

# Get file modification time in epoch seconds
get_file_mtime() {
    local file="$1"
    [[ -z "$file" ]] && {
        echo "0"
        return
    }
    local result
    result=$($STAT_BSD -f%m "$file" 2> /dev/null || echo "")
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Determine date command once
if [[ -x /bin/date ]]; then
    _DATE_CMD="/bin/date"
else
    _DATE_CMD="date"
fi

# Get current time in epoch seconds (defensive against locale/aliases)
get_epoch_seconds() {
    local result
    result=$($_DATE_CMD +%s 2> /dev/null || echo "")
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Get file owner username
get_file_owner() {
    local file="$1"
    $STAT_BSD -f%Su "$file" 2> /dev/null || echo ""
}

# ============================================================================
# System Utilities
# ============================================================================

# Detect CPU architecture
# Returns: "Apple Silicon" or "Intel"
detect_architecture() {
    if [[ -n "${MOLE_ARCH_CACHE:-}" ]]; then
        echo "$MOLE_ARCH_CACHE"
        return 0
    fi

    if [[ "$(uname -m)" == "arm64" ]]; then
        export MOLE_ARCH_CACHE="Apple Silicon"
    else
        export MOLE_ARCH_CACHE="Intel"
    fi
    echo "$MOLE_ARCH_CACHE"
}

get_free_space_target() {
    local target="/"
    if [[ -d "/System/Volumes/Data" ]]; then
        target="/System/Volumes/Data"
    fi

    printf '%s\n' "$target"
}

# Get free disk space on root volume in 1K blocks.
get_free_space_kb() {
    local target
    target=$(get_free_space_target)

    local available_kb
    available_kb=$(command df -Pk "$target" 2> /dev/null | awk 'NR==2 {print $4}' || true)
    if [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$available_kb"
        return 0
    fi

    return 1
}

format_free_space_kb() {
    local free_kb="${1:-}"
    if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
        bytes_to_human_kb "$free_kb"
        return 0
    fi

    echo "Unknown"
}

# Get free disk space on root volume.
# Returns: human-readable decimal string (e.g., "100.00GB")
get_free_space() {
    local free_kb
    if free_kb=$(get_free_space_kb) && [[ "$free_kb" =~ ^[0-9]+$ ]]; then
        format_free_space_kb "$free_kb"
        return $?
    fi

    echo "Unknown"
}

# Get optimal parallel jobs for operation type (scan|io|compute|default)
get_optimal_parallel_jobs() {
    local operation_type="${1:-default}"
    if [[ -z "${MOLE_CPU_CORES_CACHE:-}" ]]; then
        export MOLE_CPU_CORES_CACHE=$(sysctl -n hw.ncpu 2> /dev/null || echo 4)
    fi
    local cpu_cores="$MOLE_CPU_CORES_CACHE"
    case "$operation_type" in
        scan | io)
            echo $((cpu_cores * 2))
            ;;
        compute)
            echo "$cpu_cores"
            ;;
        *)
            echo $((cpu_cores + 2))
            ;;
    esac
}

# ============================================================================
# User Context Utilities
# ============================================================================

is_root_user() {
    [[ "$(id -u)" == "0" ]]
}

get_invoking_uid() {
    if [[ -n "${SUDO_UID:-}" ]]; then
        echo "$SUDO_UID"
        return 0
    fi

    local uid
    uid=$(id -u 2> /dev/null || true)
    echo "$uid"
}

get_invoking_gid() {
    if [[ -n "${SUDO_GID:-}" ]]; then
        echo "$SUDO_GID"
        return 0
    fi

    local gid
    gid=$(id -g 2> /dev/null || true)
    echo "$gid"
}

get_invoking_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        get_user_home "$SUDO_USER"
        return 0
    fi

    echo "${HOME:-}"
}

get_user_home() {
    local user="$1"
    local home=""

    if [[ -z "$user" ]]; then
        echo ""
        return 0
    fi

    if command -v dscl > /dev/null 2>&1; then
        home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2> /dev/null | awk '{print $2}' | head -1 || true)
    fi

    if [[ -z "$home" ]]; then
        home=$(id -P "$user" 2> /dev/null | cut -d: -f9 || true)
    fi

    if [[ "$home" == "~"* ]]; then
        home=""
    fi

    echo "$home"
}

ensure_user_dir() {
    local raw_path="$1"
    if [[ -z "$raw_path" ]]; then
        return 0
    fi

    local target_path="$raw_path"
    if [[ "$target_path" == "~"* ]]; then
        target_path="${target_path/#\~/$HOME}"
    fi

    mkdir -p "$target_path" 2> /dev/null || true

    if ! is_root_user; then
        return 0
    fi

    local sudo_user="${SUDO_USER:-}"
    if [[ -z "$sudo_user" || "$sudo_user" == "root" ]]; then
        return 0
    fi

    local user_home
    user_home=$(get_user_home "$sudo_user")
    if [[ -z "$user_home" ]]; then
        return 0
    fi
    user_home="${user_home%/}"

    if [[ "$target_path" != "$user_home" && "$target_path" != "$user_home/"* ]]; then
        return 0
    fi

    local owner_uid="${SUDO_UID:-}"
    local owner_gid="${SUDO_GID:-}"
    if [[ -z "$owner_uid" || -z "$owner_gid" ]]; then
        owner_uid=$(id -u "$sudo_user" 2> /dev/null || true)
        owner_gid=$(id -g "$sudo_user" 2> /dev/null || true)
    fi

    if [[ -z "$owner_uid" || -z "$owner_gid" ]]; then
        return 0
    fi

    local dir="$target_path"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        # Early stop: if ownership is already correct, no need to continue up the tree
        if [[ -d "$dir" ]]; then
            local current_uid
            current_uid=$("$STAT_BSD" -f%u "$dir" 2> /dev/null || echo "")
            if [[ "$current_uid" == "$owner_uid" ]]; then
                break
            fi
        fi

        chown "$owner_uid:$owner_gid" "$dir" 2> /dev/null || true

        if [[ "$dir" == "$user_home" ]]; then
            break
        fi
        dir=$(dirname "$dir")
        if [[ "$dir" == "." ]]; then
            break
        fi
    done
}

ensure_user_file() {
    local raw_path="$1"
    if [[ -z "$raw_path" ]]; then
        return 0
    fi

    local target_path="$raw_path"
    if [[ "$target_path" == "~"* ]]; then
        target_path="${target_path/#\~/$HOME}"
    fi

    ensure_user_dir "$(dirname "$target_path")"
    touch "$target_path" 2> /dev/null || true

    if ! is_root_user; then
        return 0
    fi

    local sudo_user="${SUDO_USER:-}"
    if [[ -z "$sudo_user" || "$sudo_user" == "root" ]]; then
        return 0
    fi

    local user_home
    user_home=$(get_user_home "$sudo_user")
    if [[ -z "$user_home" ]]; then
        return 0
    fi
    user_home="${user_home%/}"

    if [[ "$target_path" != "$user_home" && "$target_path" != "$user_home/"* ]]; then
        return 0
    fi

    local owner_uid="${SUDO_UID:-}"
    local owner_gid="${SUDO_GID:-}"
    if [[ -z "$owner_uid" || -z "$owner_gid" ]]; then
        owner_uid=$(id -u "$sudo_user" 2> /dev/null || true)
        owner_gid=$(id -g "$sudo_user" 2> /dev/null || true)
    fi

    if [[ -n "$owner_uid" && -n "$owner_gid" ]]; then
        chown "$owner_uid:$owner_gid" "$target_path" 2> /dev/null || true
    fi
}

# ============================================================================
# Formatting Utilities
# ============================================================================

# Convert bytes to human-readable format (e.g., 1.5GB)
# macOS (since Snow Leopard) uses Base-10 calculation (1 KB = 1000 bytes)
bytes_to_human() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || {
        echo "0B"
        return 1
    }

    # GB: >= 1,000,000,000 bytes
    if ((bytes >= 1000000000)); then
        local scaled=$(((bytes * 100 + 500000000) / 1000000000))
        printf "%d.%02dGB\n" $((scaled / 100)) $((scaled % 100))
    # MB: >= 1,000,000 bytes
    elif ((bytes >= 1000000)); then
        local scaled=$(((bytes * 10 + 500000) / 1000000))
        printf "%d.%01dMB\n" $((scaled / 10)) $((scaled % 10))
    # KB: >= 1,000 bytes (round up to nearest KB instead of decimal)
    elif ((bytes >= 1000)); then
        printf "%dKB\n" $(((bytes + 500) / 1000))
    else
        printf "%dB\n" "$bytes"
    fi
}

# Convert kilobytes to human-readable format
# Args: $1 - size in KB
# Returns: formatted string
bytes_to_human_kb() {
    bytes_to_human "$((${1:-0} * 1024))"
}

format_free_space_delta_kb() {
    local delta_kb="${1:-0}"
    [[ "$delta_kb" =~ ^-?[0-9]+$ ]] || delta_kb=0

    local sign=""
    local abs_kb="$delta_kb"
    if ((delta_kb > 0)); then
        sign="+"
    elif ((delta_kb < 0)); then
        sign="-"
        abs_kb=$((-delta_kb))
    fi

    printf '%s%s\n' "$sign" "$(bytes_to_human_kb "$abs_kb")"
}

mole_is_reverse_dns_bundle_id() {
    local bundle_id="${1:-}"

    [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]] || return 1
    [[ "$bundle_id" =~ ^[A-Za-z0-9][-A-Za-z0-9]*(\.[A-Za-z0-9][-A-Za-z0-9]*)+$ ]]
}

mole_name_starts_with_bundle_id_boundary() {
    local name="${1##*/}"
    local bundle_id="${2:-}"

    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1
    [[ "$name" == "$bundle_id" ||
        "$name" == "$bundle_id".* ]]
}

mole_name_has_bundle_id_boundary() {
    local name="${1##*/}"
    local bundle_id="${2:-}"

    mole_name_starts_with_bundle_id_boundary "$name" "$bundle_id" && return 0
    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1
    [[ "$name" == *."$bundle_id" ||
        "$name" == *."$bundle_id".* ]]
}

# Colorize an already-formatted human size string by unit.
colorize_human_size() {
    local size_human="$1"

    local size_color=""
    case "$size_human" in
        *GB) size_color="$RED" ;;
        *MB) size_color="$YELLOW" ;;
        *KB) size_color="$GREEN" ;;
        *B) size_color="$GRAY" ;;
        *)
            printf '%s' "$size_human"
            return 0
            ;;
    esac

    printf '%s%s%s' "$size_color" "$size_human" "$NC"
}

# Cleanup result lines are always shown in green. Kept as a function (callers
# still pass a size in KB) so per-size coloring can be reintroduced in one place
# if ever wanted.
cleanup_result_color_kb() {
    printf '%s' "$GREEN"
}

# Percent-encode a filesystem path for use in a file:// URL. Byte-wise loop
# under LC_ALL=C so multibyte characters are encoded per byte (bash 3.2 has
# no built-in encoder).
percent_encode_path() {
    local LC_ALL=C
    local input="$1"
    local out="" ch i val
    for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            [a-zA-Z0-9/._~-]) out+="$ch" ;;
            *)
                # bash 3.2 returns negative values for bytes >= 128; mask to a byte.
                val=$(printf '%d' "'$ch")
                out+=$(printf '%%%02X' $((val & 255)))
                ;;
        esac
    done
    printf '%s' "$out"
}

# Print a path as an OSC 8 file:// hyperlink so terminals keep it clickable
# even when it contains spaces (auto-detection breaks on whitespace). Shows
# the ~-abbreviated path; piped output and non-ANSI terminals get plain text.
format_path_link() {
    local path="$1"
    local display="${path/#$HOME/~}"
    if ! is_ansi_supported 2> /dev/null; then
        printf '%s' "$display"
        return 0
    fi
    # ESC-backslash is the OSC 8 string terminator; kept in a variable since
    # a single-quoted printf format ending in \\ trips ShellCheck SC1003.
    local st=$'\033\\'
    printf '\033]8;;file://%s%s%s\033]8;;%s' "$(percent_encode_path "$path")" "$st" "$display" "$st"
}

# ============================================================================
# Temporary File Management
# ============================================================================

# Tracked temporary files and directories
declare -a MOLE_TEMP_FILES=()
declare -a MOLE_TEMP_DIRS=()

normalize_temp_root() {
    local path="${1:-}"
    [[ -z "$path" ]] && return 1

    if [[ "$path" == "~"* ]]; then
        path="${path/#\~/$HOME}"
    fi

    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done

    [[ -n "$path" ]] || return 1
    printf '%s\n' "$path"
}

probe_temp_root() {
    local raw_path="$1"
    local allow_create="${2:-false}"
    local path
    local probe=""

    path=$(normalize_temp_root "$raw_path") || return 1

    if [[ "$allow_create" == "true" ]]; then
        ensure_user_dir "$path"
    fi

    [[ -d "$path" ]] || return 1

    probe=$(mktemp "$path/mole.probe.XXXXXX" 2> /dev/null) || return 1
    rm -f "$probe" 2> /dev/null || true

    printf '%s\n' "$path"
}

# Remove abandoned files only from Mole's dedicated fallback temp directory.
# Persistent cache files live one level above this directory and are never
# included. A one-day grace period avoids racing with concurrent long-running
# Mole processes while bounding leftovers from interrupted runs.
prune_stale_mole_temp_files() {
    local root="${1:-}"
    local invoking_home=""
    local max_age_minutes="${MOLE_TEMP_STALE_MINUTES:-1440}"

    [[ "$max_age_minutes" =~ ^[0-9]+$ ]] || max_age_minutes=1440
    [[ -n "$root" && -d "$root" && ! -L "$root" ]] || return 0

    if is_root_user; then
        [[ "$root" == "/private/var/root/.cache/mole/tmp" ]] || return 0
    else
        invoking_home=$(get_invoking_home)
        [[ -n "$invoking_home" ]] || return 0
        [[ "$root" == "${invoking_home%/}/.cache/mole/tmp" ]] || return 0
    fi

    find "$root" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) \
        -mmin "+$max_age_minutes" -exec rm -f -- {} + 2> /dev/null || true # SAFE: dedicated Mole temp root only

    # Spinner control directories contain only flat control files. Remove
    # their contents without recursive deletion, then rmdir the now-empty
    # directory. Unexpected nested content makes rmdir fail closed.
    local stale_dir
    while IFS= read -r -d '' stale_dir; do
        case "$stale_dir" in
            "$root"/.mole-spinner.*) ;;
            *) continue ;;
        esac
        [[ -d "$stale_dir" && ! -L "$stale_dir" && -O "$stale_dir" ]] || continue
        find "$stale_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) \
            -exec rm -f -- {} + 2> /dev/null || true # SAFE: validated spinner control dir only
        rmdir "$stale_dir" 2> /dev/null || true
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name '.mole-spinner.*' \
        -mmin "+$max_age_minutes" -print0 2> /dev/null)
}

initialize_mole_temp_registry_path() {
    [[ -n "${MOLE_RESOLVED_TMPDIR:-}" ]] || return 1

    # Bash keeps $$ stable inside command substitutions and across exec, so the
    # parent, its subshells, and an exec'd bin/*.sh all derive the same registry
    # path. A forked child gets a different $$: the registry is exported, so an
    # inherited value that no longer matches belongs to the parent process, and
    # adopting it would make the child's exit cleanup delete the parent's live
    # temp files. `mo update` lost its downloaded installer exactly this way,
    # because install.sh runs the freshly installed `mole --version`.
    local owned="${MOLE_RESOLVED_TMPDIR%/}/mole.registry.$$"
    [[ "${MOLE_TEMP_REGISTRY_FILE:-}" == "$owned" ]] && return 0

    MOLE_TEMP_REGISTRY_FILE="$owned"
    export MOLE_TEMP_REGISTRY_FILE
}

ensure_mole_temp_registry_file() {
    initialize_mole_temp_registry_path || return 1

    case "$MOLE_TEMP_REGISTRY_FILE" in
        "${MOLE_RESOLVED_TMPDIR%/}"/mole.registry.*) ;;
        *) return 1 ;;
    esac

    if [[ ! -e "$MOLE_TEMP_REGISTRY_FILE" ]]; then
        (umask 077 && set -C && : > "$MOLE_TEMP_REGISTRY_FILE") 2> /dev/null || true
    fi

    [[ -f "$MOLE_TEMP_REGISTRY_FILE" && ! -L "$MOLE_TEMP_REGISTRY_FILE" && -O "$MOLE_TEMP_REGISTRY_FILE" ]]
}

ensure_mole_temp_root() {
    if is_root_user; then
        # Whole-command sudo must not reuse TMPDIR or the invoking user's cache
        # for root-written registries and command output. Keep all root temp
        # state below root's private home so a lower-trust user cannot rename a
        # checked file between validation and append/read operations.
        local root_home="/private/var/root"
        [[ -d "$root_home" && ! -L "$root_home" && -O "$root_home" ]] || root_home="/var/root"
        [[ -d "$root_home" && ! -L "$root_home" && -O "$root_home" ]] || return 1

        local root_temp="$root_home/.cache/mole/tmp"
        mkdir -p "$root_temp" 2> /dev/null || return 1
        chmod 700 "$root_home/.cache" "$root_home/.cache/mole" "$root_temp" 2> /dev/null || true
        root_temp=$(cd -P "$root_temp" 2> /dev/null && pwd) || return 1
        [[ "$root_temp" == "$root_home/.cache/mole/tmp" && -d "$root_temp" && ! -L "$root_temp" && -O "$root_temp" ]] || return 1

        MOLE_RESOLVED_TMPDIR="$root_temp"
        export MOLE_RESOLVED_TMPDIR
        prune_stale_mole_temp_files "$MOLE_RESOLVED_TMPDIR"
        case "${MOLE_TEMP_REGISTRY_FILE:-}" in
            "$root_temp"/mole.registry.*) ;;
            *) unset MOLE_TEMP_REGISTRY_FILE ;;
        esac
        initialize_mole_temp_registry_path || true
        return 0
    fi

    if [[ -n "${MOLE_RESOLVED_TMPDIR:-}" ]]; then
        initialize_mole_temp_registry_path || true
        return 0
    fi

    local resolved=""
    local candidate="${TMPDIR:-}"
    local invoking_home=""

    if [[ -n "$candidate" ]]; then
        resolved=$(probe_temp_root "$candidate" false || true)
    fi

    if [[ -z "$resolved" ]]; then
        invoking_home=$(get_invoking_home)
        if [[ -n "$invoking_home" ]]; then
            resolved=$(probe_temp_root "$invoking_home/.cache/mole/tmp" true || true)
        fi
    fi

    if [[ -z "$resolved" ]]; then
        resolved=$(probe_temp_root "/tmp" false || true)
    fi

    [[ -n "$resolved" ]] || resolved="/tmp"
    MOLE_RESOLVED_TMPDIR="$resolved"
    export MOLE_RESOLVED_TMPDIR
    initialize_mole_temp_registry_path || true
    prune_stale_mole_temp_files "$MOLE_RESOLVED_TMPDIR"
}

prepare_mole_tmpdir() {
    ensure_mole_temp_root
    export TMPDIR="$MOLE_RESOLVED_TMPDIR"
    printf '%s\n' "$MOLE_RESOLVED_TMPDIR"
}

mole_temp_path_template() {
    local prefix="${1:-mole}"
    ensure_mole_temp_root
    printf '%s/%s.XXXXXX\n' "$MOLE_RESOLVED_TMPDIR" "$prefix"
}

# Create tracked temporary file
create_temp_file() {
    local temp
    ensure_mole_temp_root
    temp=$(mktemp "$MOLE_RESOLVED_TMPDIR/mole.XXXXXX") || return 1
    register_temp_file "$temp"
    echo "$temp"
}

# Create tracked temporary directory
create_temp_dir() {
    local temp
    ensure_mole_temp_root
    temp=$(mktemp -d "$MOLE_RESOLVED_TMPDIR/mole.XXXXXX") || return 1
    register_temp_dir "$temp"
    echo "$temp"
}

# Register existing file for cleanup
register_temp_file() {
    MOLE_TEMP_FILES+=("$1")
    if ensure_mole_temp_registry_file; then
        printf '%s\n' "$1" >> "$MOLE_TEMP_REGISTRY_FILE" 2> /dev/null || true
    fi
}

# Register existing directory for cleanup
register_temp_dir() {
    MOLE_TEMP_DIRS+=("$1")
    if ensure_mole_temp_registry_file; then
        printf '%s\n' "$1" >> "$MOLE_TEMP_REGISTRY_FILE" 2> /dev/null || true
    fi
}

# Create temp file with prefix (for analyze.sh compatibility)
# Compatible with both BSD mktemp (macOS default) and GNU mktemp (coreutils)
mktemp_file() {
    local prefix="${1:-mole}"
    local temp
    local error_msg
    # Add .XXXXXX suffix to work with both BSD and GNU mktemp
    if ! error_msg=$(mktemp "$(mole_temp_path_template "$prefix")" 2>&1); then
        echo "Error: Failed to create temporary file: $error_msg" >&2
        return 1
    fi
    temp="$error_msg"
    register_temp_file "$temp"
    echo "$temp"
}

# Cleanup all tracked temp files and directories
cleanup_temp_files() {
    if declare -F stop_inline_spinner > /dev/null 2>&1; then
        stop_inline_spinner || true
    fi
    local file
    if [[ ${#MOLE_TEMP_FILES[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_FILES[@]}"; do
            [[ -f "$file" ]] && rm -f "$file" 2> /dev/null || true
        done
    fi

    if [[ ${#MOLE_TEMP_DIRS[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_DIRS[@]}"; do
            [[ -d "$file" ]] && rm -rf "$file" 2> /dev/null || true # SAFE: cleanup_temp_files
        done
    fi

    # Command substitutions run mktemp_file/create_temp_* in a child shell, so
    # their in-memory array updates cannot reach this parent. The registry is
    # shared across those shells and closes that cleanup gap. See #1203.
    if ensure_mole_temp_registry_file; then
        local registered_path
        while IFS= read -r registered_path; do
            [[ -n "$registered_path" ]] || continue
            [[ "$registered_path" == "${MOLE_RESOLVED_TMPDIR%/}/"* ]] || continue
            [[ ! "$registered_path" =~ (^|/)\.\.(\/|$) ]] || continue

            if [[ -d "$registered_path" && ! -L "$registered_path" ]]; then
                rm -rf "$registered_path" 2> /dev/null || true # SAFE: mktemp dir registered under resolved Mole temp root
            else
                rm -f "$registered_path" 2> /dev/null || true
            fi
        done < "$MOLE_TEMP_REGISTRY_FILE"
        rm -f "$MOLE_TEMP_REGISTRY_FILE" 2> /dev/null || true
    fi

    MOLE_TEMP_FILES=()
    MOLE_TEMP_DIRS=()
}

# ============================================================================
# Section Tracking (for progress indication)
# ============================================================================

# Global section tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0

# IMPORTANT: There are intentionally three start_section / end_section /
# note_activity implementations across the codebase. The one that wins is the
# one loaded last, and each variant has product-level differences (color,
# fallback wording, dry-run export behavior). Before changing any of them,
# read the cross references first:
#
#   - lib/core/base.sh   (this file): purple arrow header, "Nothing to tidy"
#                                     fallback, no dry-run export.
#   - bin/clean.sh:      purple arrow header, erases the header of idle
#                        sections on ANSI TTYs ("Nothing to clean" fallback
#                        when piped or under MO_DEBUG), appends '=== title ==='
#                        to EXPORT_LIST_FILE under DRY_RUN, stops the section
#                        spinner on close.
#   - bin/purge.sh:      blue ━━━ box header, no fallback message, writes
#                        each note_activity line directly to EXPORT_LIST_FILE.
#
# Treat this file's version as the default for everything outside the clean
# and purge entry points. Do not unify the three blindly; the wording and
# export semantics are user-visible.

# Start a new section
# Args: $1 - section title
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
}

# End a section
# Shows "Nothing to tidy" if no activity was recorded
end_section() {
    if [[ "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

# Mark activity in current section
note_activity() {
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Start a section spinner with optional message. When a spinner is already
# running, swap its text in place instead of restarting the subprocess: the
# stop/start cycle blanks the line for a frame and reads as flicker.
# Usage: start_section_spinner "message"
start_section_spinner() {
    local message="${1:-Scanning...}"
    if [[ -t 1 ]]; then
        if declare -F update_inline_spinner_message > /dev/null 2>&1 &&
            update_inline_spinner_message "$message"; then
            return 0
        fi
        stop_inline_spinner || true
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "$message"
    else
        stop_inline_spinner || true
    fi
}

# Stop spinner and clear the line
# Usage: stop_section_spinner
stop_section_spinner() {
    # stop_inline_spinner clears the line itself when a spinner was running;
    # a second unconditional clear here only blanked the row an extra frame
    # right before result rows printed.
    stop_inline_spinner || true
}

# Safe terminal line clearing with terminal type detection
# Usage: safe_clear_lines <num_lines> [tty_device]
# Returns: 0 on success, 1 if terminal doesn't support ANSI
safe_clear_lines() {
    local lines="${1:-1}"
    local tty_device="${2:-/dev/tty}"

    # Use centralized ANSI support check (defined below)
    # Note: This forward reference works because functions are parsed before execution
    is_ansi_supported 2> /dev/null || return 1

    [[ "$lines" =~ ^[0-9]+$ && "$lines" -gt 0 ]] || return 0

    # Emit the whole erase as one write so the terminal renders it in a
    # single frame; per-line writes flash intermediate states.
    local sequence=""
    local i
    for ((i = 0; i < lines; i++)); do
        sequence+="\033[1A\r\033[2K"
    done
    # shellcheck disable=SC2059
    printf "$sequence" > "$tty_device" 2> /dev/null || return 1

    return 0
}

# Safe single line clear with fallback
# Usage: safe_clear_line [tty_device]
safe_clear_line() {
    local tty_device="${1:-/dev/tty}"

    # Use centralized ANSI support check
    is_ansi_supported 2> /dev/null || return 1

    printf "\r\033[2K" > "$tty_device" 2> /dev/null || return 1
    return 0
}

# Update progress spinner if enough time has elapsed
# Usage: update_progress_if_needed <completed> <total> <last_update_time_var> [interval]
# Example: update_progress_if_needed "$completed" "$total" last_progress_update 2
# Returns: 0 if updated, 1 if skipped
update_progress_if_needed() {
    local completed="$1"
    local total="$2"
    local last_update_var="$3" # Name of variable holding last update time
    local interval="${4:-2}"   # Default: update every 2 seconds

    # Get current time
    local current_time
    current_time=$(get_epoch_seconds)

    # Get last update time from variable
    local last_time
    # eval: indirect read by name; bash 3.2 has no nameref (declare -n)
    eval "last_time=\${$last_update_var:-0}"
    [[ "$last_time" =~ ^[0-9]+$ ]] || last_time=0

    # Check if enough time has elapsed
    if [[ $((current_time - last_time)) -ge $interval ]]; then
        # Update the spinner text in place; restarting it here blinked the
        # line on every progress tick.
        start_section_spinner "Scanning items... $completed/$total"

        # Update the last_update_time variable
        # eval: indirect write by name; bash 3.2 has no nameref
        eval "$last_update_var=$current_time"
        return 0
    fi

    return 1
}

# ============================================================================
# Terminal Compatibility Checks
# ============================================================================

# Check if terminal supports ANSI escape codes
# Usage: is_ansi_supported
# Returns: 0 if supported, 1 if not
is_ansi_supported() {
    if [[ -n "${MOLE_ANSI_SUPPORTED_CACHE:-}" ]]; then
        return "$MOLE_ANSI_SUPPORTED_CACHE"
    fi

    # Check if running in interactive terminal
    if ! [[ -t 1 ]]; then
        export MOLE_ANSI_SUPPORTED_CACHE=1
        return 1
    fi

    # Check TERM variable
    if [[ -z "${TERM:-}" ]]; then
        export MOLE_ANSI_SUPPORTED_CACHE=1
        return 1
    fi

    # Check for known ANSI-compatible terminals
    case "$TERM" in
        xterm* | vt100 | vt220 | screen* | tmux* | ansi | linux | rxvt* | konsole*)
            export MOLE_ANSI_SUPPORTED_CACHE=0
            return 0
            ;;
        dumb | unknown)
            export MOLE_ANSI_SUPPORTED_CACHE=1
            return 1
            ;;
        *)
            # Check terminfo database if available
            if command -v tput > /dev/null 2>&1; then
                # Test if terminal supports colors (good proxy for ANSI support)
                local colors=$(tput colors 2> /dev/null || echo "0")
                if [[ "$colors" -ge 8 ]]; then
                    export MOLE_ANSI_SUPPORTED_CACHE=0
                    return 0
                fi
            fi
            export MOLE_ANSI_SUPPORTED_CACHE=1
            return 1
            ;;
    esac
}

# Record that a cleanup family was skipped because the app was running, so the
# clean summary can tell the user which apps to quit and re-run.
#
# `defer_cleanup_family` is the real ledger and lives in bin/clean.sh, which is
# the only production entry point that sources lib/clean/*. A cleanup lib
# sourced on its own (every standalone Bats case) has no ledger, so this drops
# the family into the debug log instead of failing.
#
# This is NOT one of the three-way-forked helpers documented above start_section:
# there is exactly one implementation and callers must not fork their own. Three
# byte-identical copies of it grew in lib/clean/{dev,user,app_caches}.sh before
# it landed here, which is the reason it is a shared function rather than a
# convention. `tests/clean_core.bats` pins that they do not come back.
mole_defer_cleanup_family() {
    if declare -f defer_cleanup_family > /dev/null 2>&1; then
        defer_cleanup_family "$1"
    else
        debug_log "Deferred cleanup while active: $1"
    fi
}

# Why a cleanup delete guard refused, read by the caller right after a denial.
# Dynamically scoped rather than returned on stdout on purpose: guards run at
# the delete boundary, where a command substitution would fork per candidate.
# Callers that need it isolated declare `local _MOLE_CLEAN_GUARD_REASON` in the
# wrapper that owns the cleanup.
_MOLE_CLEAN_GUARD_REASON=""

# Turn a tri-state process probe into an allow/deny plus that reason.
#
# Probe contract: 0 = the app is running, 1 = it is not, 2 = could not tell.
# State 2 must deny. An unreadable process table is not evidence the app is
# closed, and a copy of this block that folds 2 into "not running" silently
# turns "unknown" into "safe to delete" on a path that then removes the files.
# Nine guards across dev.sh, user.sh, and app_caches.sh open-coded these six
# lines before they landed here; one transcription slip in any of them was a
# deletion while the owning app was live.
#
# Compound guards (Codex runtime/staging, Claude Desktop, versioned agents) call
# this for the process question and then add their own evidence.
# The optional third argument overrides the unknown-state wording. Only the
# default "process state unknown" is echoed against the item by
# mole_report_guard_stop; a guard that supplies its own wording (the Codex
# Sparkle updater probe) is deliberately routed to the deferred-family list
# instead, so keep the two in step when changing either.
mole_clean_process_guard() {
    local probe="$1"
    local busy_reason="$2"
    local unknown_reason="${3:-process state unknown}"
    local process_state=0
    "$probe" || process_state=$?
    if [[ $process_state -eq 1 ]]; then
        return 0
    fi

    _MOLE_CLEAN_GUARD_REASON="$busy_reason"
    [[ $process_state -eq 2 ]] && _MOLE_CLEAN_GUARD_REASON="$unknown_reason"
    return 1
}

# Report a guard refusal. An unknown process state is the user's problem to see
# now (it means Mole could not tell, not that it found something running), so it
# prints against the item. A known-running app is ordinary and goes to the
# end-of-run "Skipped while active" list instead of a line per cache.
# Usage: mole_report_guard_stop "Xcode cache" mole_defer_cleanup_family "Xcode"
mole_report_guard_stop() {
    local display_name="$1"
    shift
    if [[ "$_MOLE_CLEAN_GUARD_REASON" == "process state unknown" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
        note_activity
    else
        "$@"
    fi
}

# Does any of these targets survive the eligibility filter, i.e. would a real
# cleanup have anything to do?
#
# Callers use it to decide whether an active app is worth reporting as skipped:
# deferring "Xcode" when every candidate was already whitelisted tells the user
# to quit an app for no reason. The predicate list mirrors the one
# `_safe_clean_impl` applies before it consults the delete guard, so the two
# agree on what "eligible" means; broken symlinks are excluded there too.
mole_cleanup_targets_exist() {
    local target
    for target in "$@"; do
        [[ -e "$target" ]] || continue
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$target" 2> /dev/null; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$target" 2> /dev/null; then
            continue
        fi
        if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$target" 2> /dev/null; then
            continue
        fi
        return 0
    done
    return 1
}
