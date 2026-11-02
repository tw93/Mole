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
# pgrep reads each pattern as an extended regex, so the patterns of one
# selector join with | into a single probe; -x still anchors the whole name.
# A pgrep per pattern cost about 16ms each in per-item delete guards.
mole_pgrep_any() {
    if [[ $# -eq 0 || $(($# % 2)) -ne 0 ]] || ! command -v pgrep > /dev/null 2>&1; then
        return 2
    fi

    local exact="" full="" selector pattern probe_rc aggregate_rc=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -x) exact="${exact:+$exact|}$2" ;;
            -f) full="${full:+$full|}$2" ;;
            *) return 2 ;;
        esac
        shift 2
    done

    for selector in -x -f; do
        pattern="$exact"
        [[ "$selector" == "-x" ]] || pattern="$full"
        [[ -n "$pattern" ]] || continue
        probe_rc=0
        pgrep "$selector" "$pattern" > /dev/null 2>&1 || probe_rc=$?
        [[ $probe_rc -ne 0 ]] || return 0
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
readonly ICON_DRY_RUN="○"
readonly ICON_REVIEW="⊙"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"

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
    # at, not cached downloads. The renv cache is the same shape: renv
    # installs packages there and, by default, symlinks them into project
    # libraries, so removing it leaves those libraries dangling. Its entry is
    # spelled exactly like the old default row so saved files that still
    # carry that line read it as this mandatory rule. pnpm installs every
    # `pnpm dlx` package under its cache dir, so a running command loses its
    # modules when the sweep takes it, the shape of the npx loss in #1870.
    # Hard safety, so they merge unconditionally.
    "$HOME/Library/Caches/com.apple.FontRegistry*"
    "$HOME/Library/Caches/com.apple.spotlight*"
    "$HOME/Library/Caches/com.apple.Spotlight*"
    "$HOME/Library/Caches/CloudKit*"
    # Kitty keeps a live graphics-protocol cache here; removing it from a
    # running session makes subsequent image transfers fail until the
    # directory is recreated.
    "$HOME/Library/Caches/kitty"
    "$HOME/Library/Caches/pypoetry/virtualenvs*"
    "$HOME/Library/Caches/org.R-project.R/R/renv/*"
    "$HOME/Library/Caches/pnpm/dlx*"
    # llama.cpp downloads `-hf` model weights (multi-GB GGUF files) into its
    # default LLAMA_CACHE here; they are user-chosen models, not a cache that
    # rebuilds on its own. Mole Mac blocks the same folder (2026-10-29).
    "$HOME/Library/Caches/llama.cpp"
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

# 0 when the file can be opened for reading. Existing is not enough: a list the
# user wrote but this process cannot open (mode 000, a privacy denial) is
# unknown protection, and reading it as empty would clean what it protects.
mole_file_openable() {
    { : < "$1"; } 2> /dev/null
}

# One factual cause and one next action for an exclusion list that cannot be read.
mole_report_unreadable_whitelist() {
    local file="$1" label="${2:-whitelist}" reason="${3:-file}"
    case "$reason" in
        directory)
            printf 'Cannot access your %s directory: %s\n' "$label" "${file//[[:cntrl:]]/?}" >&2
            printf '  Mole stops so nothing you protected is cleaned by mistake. Run: chmod u+rx %q\n' "$file" >&2
            ;;
        invalid)
            printf 'Cannot read your %s: invalid path or broken link: %s\n' "$label" "${file//[[:cntrl:]]/?}" >&2
            printf '  Mole stops so nothing you protected is cleaned by mistake. Restore this path or its link target before retrying.\n' >&2
            ;;
        unknown)
            printf 'Cannot inspect your %s path: %s\n' "$label" "${file//[[:cntrl:]]/?}" >&2
            printf '  Mole stops because absence could not be verified. Check access to this path before retrying.\n' >&2
            ;;
        *)
            printf 'Cannot read your %s: %s\n' "$label" "${file//[[:cntrl:]]/?}" >&2
            printf '  Mole stops so nothing you protected is cleaned by mistake. Run: chmod u+r %q\n' "$file" >&2
            ;;
    esac
}

# 0 = readable file, 1 = confirmed ENOENT, 2 = unknown/invalid. Shell test -f
# cannot distinguish absence from EACCES or I/O failure. System Perl exposes
# errno without adding a dependency beyond the existing macOS runtime probes.
# Inspect parents first so an inaccessible directory names the right repair,
# and a broken symlink never authorizes defaults or a legacy-list fallback.
mole_whitelist_file_state() {
    local file="$1" label="${2:-whitelist}" problem="" probe_rc=0
    if [[ ! -x /usr/bin/perl ]]; then
        printf 'Cannot inspect your %s: the system Perl runtime is unavailable.\n' "$label" >&2
        printf '  Mole stops so nothing you protected is cleaned by mistake. Restore /usr/bin/perl before retrying.\n' >&2
        return 2
    fi
    problem=$(/usr/bin/perl -e '
        use strict;
        use warnings;
        use Errno qw(ENOENT);
        use Fcntl qw(S_ISDIR S_ISREG S_ISLNK);
        my $file = shift;
        sub stop { my ($status, $path) = @_; print $path, "."; exit $status; }
        $file =~ m{^/} or stop(5, $file);
        my @parts = grep { length } split m{/}, $file;
        my $path = "";
        for my $i (0 .. $#parts) {
            $path .= "/" . $parts[$i];
            my @meta = lstat($path);
            if (!@meta) { stop($! == ENOENT ? 1 : 5, $path); }
            if (S_ISLNK($meta[2])) {
                @meta = stat($path);
                if (!@meta) { stop($! == ENOENT ? 3 : 5, $path); }
            }
            if ($i < $#parts) {
                S_ISDIR($meta[2]) or stop(3, $path);
                -x $path or stop(2, $path);
            } else {
                S_ISREG($meta[2]) or stop(3, $path);
            }
        }
        exit 0;
    ' -- "$file" 2> /dev/null) || probe_rc=$?
    # Preserve trailing newlines in a path across command substitution.
    problem="${problem%.}"
    case "$probe_rc" in
        0)
            mole_file_openable "$file" && return 0
            mole_report_unreadable_whitelist "$file" "$label"
            ;;
        1) return 1 ;;
        2) mole_report_unreadable_whitelist "$problem" "$label" directory ;;
        3) mole_report_unreadable_whitelist "$problem" "$label" invalid ;;
        *) mole_report_unreadable_whitelist "${problem:-$file}" "$label" unknown ;;
    esac
    return 2
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
    local whitelist_state=0
    mole_whitelist_file_state "$whitelist_file" || whitelist_state=$?
    [[ $whitelist_state -ne 2 ]] || return 1
    if [[ $whitelist_state -eq 0 ]]; then
        local line duplicate existing
        while IFS= read -r line || [[ -n "$line" ]]; do
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
# Every stat call names this path: a PATH stat can be GNU coreutils, whose
# `-f` prints file-system text that reads as a value (#1196, #1752). Assigned
# unconditionally on load, so the environment cannot redirect it; not readonly
# so a test can rebind it to a fixture stub after sourcing.
STAT_BSD="/usr/bin/stat"
# Scans whose result depends on BSD find's error format or its handling of
# File Provider mounts use this path too; GNU findutils earlier in PATH quotes
# paths in its errors and fails on mounts BSD find walks past.
FIND_BSD="/usr/bin/find"
# sysctl lives in /usr/sbin, which a shell PATH may leave out; the PATH lookup
# then fails and callers silently use their fallback values (#1804).
SYSCTL_CMD="/usr/sbin/sysctl"
# diskutil, lsof, pkgutil, ioreg and the other system tools Mole runs by name
# live there too. Without them a probe reads as "nothing found": diskutil's
# empty answer skipped the internal-volume refusal of --external. Appending
# keeps the user's own order ahead of them.
case ":${PATH:-}:" in *:/usr/sbin:*) ;; *) PATH="${PATH:+$PATH:}/usr/sbin" ;; esac
case ":$PATH:" in *:/sbin:*) ;; *) PATH="$PATH:/sbin" ;; esac
export PATH

# Only complete generated completion lines are owned by Mole. A quoted mention
# or a mixed command may carry unrelated user settings and must remain intact.
# Include the previous eval/source forms when normalizing or removing them.
# shellcheck disable=SC2016 # Match literal shell substitutions in rc files.
MOLE_COMPLETION_LINE_PATTERN='^[[:space:]]*(# Mole shell completion|if output="\$\((mole|mo) completion (bash|zsh) 2>/dev/null\)"; then eval "\$output"; fi|eval "\$\((mole|mo) completion (bash|zsh)\)"|source <\((mole|mo) completion (bash|zsh)\)|set -l output \((mole|mo) completion fish 2>/dev/null\); and echo "\$output" \| source|(mole|mo) completion fish \| source)[[:space:]]*$'

# Print the final file a symlink chain points at. Renaming a rewritten rc file
# over this target keeps every link in a dotfile chain; renaming over the first
# link replaced it with a plain file. Fails on an unreadable link or a cycle.
mole_resolve_link_chain() {
    local target="$1"
    local link hops=0
    while [[ -L "$target" ]]; do
        link=$(readlink "$target") || return 1
        [[ "$link" == /* ]] || link="$(dirname "$target")/$link"
        target="$link"
        hops=$((hops + 1))
        [[ $hops -le 40 ]] || return 1
    done
    printf '%s\n' "$target"
}

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

# Get free disk space in 1K blocks. An omitted path selects the system volume.
get_free_space_kb() {
    local target="${1:-}"
    [[ -n "$target" ]] || target=$(get_free_space_target)

    local available_kb
    if ! available_kb=$(command df -Pk "$target" 2> /dev/null | awk 'NR==2 {print $4}'); then
        return 1
    fi
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

# Keep literal parent paths once without interpreting glob metacharacters.
# Callers with newline-bearing paths handle those outside this line format.
mole_filter_nested_paths() {
    [[ $# -gt 0 ]] || return 0
    local -a paths=("${@}")
    local path normalized existing skip
    local -a kept=()
    if [[ ${#paths[@]} -le 50 ]]; then
        for path in "${paths[@]}"; do
            normalized="${path%/}"
            [[ -n "$normalized" ]] || normalized="$path"
            skip=false
            local -a remaining=()
            for existing in "${kept[@]+"${kept[@]}"}"; do
                if [[ "$normalized" == "$existing" || "$normalized" == "$existing"/* || "$existing" == / ]]; then
                    skip=true
                    break
                fi
                [[ "$existing" == "$normalized"/* || "$normalized" == / ]] || remaining+=("$existing")
            done
            if [[ "$skip" == false ]]; then
                kept=("${remaining[@]+"${remaining[@]}"}" "$normalized")
            fi
        done
        printf '%s\n' "${kept[@]}"
        return
    fi
    # A prefix sibling can sort between a parent and its child. Remember all
    # kept ancestors, rather than only the last row, and publish a complete pass.
    local filtered=""
    filtered=$(printf '%s\n' "${paths[@]}" | LC_ALL=C awk '{if ($0 != "/") sub(/\/$/, ""); print}' |
        LC_ALL=C sort -u | LC_ALL=C awk '
        {
            if (seen["/"]) next
            parent=$0; skip=0
            while (parent != "") {
                if (seen[parent]) {skip=1; break}
                if (!sub(/\/[^\/]*$/, "", parent)) break
            }
            if (!skip) {seen[$0]=1; print}
        }') || return $?
    [[ -z "$filtered" ]] || printf '%s\n' "$filtered"
    return 0
}

# Lowercase ASCII letters into the variable named by $1, the same bytes
# `LC_ALL=C tr '[:upper:]' '[:lower:]'` produces in the C and UTF-8 locales,
# without a subprocess: hot loops call this once per candidate, and each tr
# cost a fork. Bash 3.2 expansion skips some letters after high bytes in
# legacy multibyte locales (GBK, SJIS, Big5), so keep callers under the
# LC_ALL=C that bin/clean.sh exports.
mole_ascii_lowercase() {
    local _lowercase_value="${2:-}"
    _lowercase_value=${_lowercase_value//A/a}
    _lowercase_value=${_lowercase_value//B/b}
    _lowercase_value=${_lowercase_value//C/c}
    _lowercase_value=${_lowercase_value//D/d}
    _lowercase_value=${_lowercase_value//E/e}
    _lowercase_value=${_lowercase_value//F/f}
    _lowercase_value=${_lowercase_value//G/g}
    _lowercase_value=${_lowercase_value//H/h}
    _lowercase_value=${_lowercase_value//I/i}
    _lowercase_value=${_lowercase_value//J/j}
    _lowercase_value=${_lowercase_value//K/k}
    _lowercase_value=${_lowercase_value//L/l}
    _lowercase_value=${_lowercase_value//M/m}
    _lowercase_value=${_lowercase_value//N/n}
    _lowercase_value=${_lowercase_value//O/o}
    _lowercase_value=${_lowercase_value//P/p}
    _lowercase_value=${_lowercase_value//Q/q}
    _lowercase_value=${_lowercase_value//R/r}
    _lowercase_value=${_lowercase_value//S/s}
    _lowercase_value=${_lowercase_value//T/t}
    _lowercase_value=${_lowercase_value//U/u}
    _lowercase_value=${_lowercase_value//V/v}
    _lowercase_value=${_lowercase_value//W/w}
    _lowercase_value=${_lowercase_value//X/x}
    _lowercase_value=${_lowercase_value//Y/y}
    _lowercase_value=${_lowercase_value//Z/z}
    printf -v "$1" '%s' "$_lowercase_value"
}

# Escape operation records and deletion-log fields at their write boundaries.
# Control bytes must never create audit records or terminal controls, so each
# one is written as \n, \r, \t or \xHH. Backslashes stay literal: a name with
# one reads back exactly as it is on disk, as it did before this escaping.
# Only the logged copy changes, never the action path. mo history applies it
# again when printing text, which leaves V1.59.0 rows untouched and escapes
# the raw control bytes older logs may still hold.
_mole_escape_log_value() {
    local _output="$1" _value="$2" _escaped="" _char _code _index
    local LC_ALL=C
    if [[ "$_value" =~ [[:cntrl:]] ]]; then
        for ((_index = 0; _index < ${#_value}; _index++)); do
            _char="${_value:_index:1}"
            case "$_char" in
                $'\n') _escaped+='\n' ;;
                $'\r') _escaped+='\r' ;;
                $'\t') _escaped+='\t' ;;
                *)
                    if [[ "$_char" =~ [[:cntrl:]] ]]; then
                        printf -v _code '\\x%02x' "'$_char"
                        _escaped+="$_code"
                    else
                        _escaped+="$_char"
                    fi
                    ;;
            esac
        done
        _value="$_escaped"
    fi
    printf -v "$_output" '%s' "$_value"
}

# Wait in the owning shell so Bash 3.2 can reap any completed scan worker.
# The first argument names a caller variable receiving the completed PID;
# the return status belongs to that worker, or to an interrupted polling sleep.
mole_wait_for_any_worker() {
    local _wait_output_name="$1"
    shift
    local _wait_pid _wait_status
    while [[ $# -gt 0 ]]; do
        for _wait_pid in "$@"; do
            if kill -0 "$_wait_pid" 2> /dev/null; then
                continue
            fi
            printf -v "$_wait_output_name" '%s' "$_wait_pid"
            _wait_status=0
            wait "$_wait_pid" 2> /dev/null || _wait_status=$?
            return "$_wait_status"
        done
        sleep 0.02 || return $?
    done
    return 1
}

# Get optimal parallel jobs for operation type (scan|io|compute|default)
get_optimal_parallel_jobs() {
    local operation_type="${1:-default}"
    if [[ -z "${MOLE_CPU_CORES_CACHE:-}" ]]; then
        export MOLE_CPU_CORES_CACHE=$("$SYSCTL_CMD" -n hw.ncpu 2> /dev/null || echo 4)
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

# EUID answers the same question as id -u without a subprocess; clean asks
# it for many targets.
is_root_user() {
    [[ "${EUID:-$(id -u)}" == "0" ]]
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
# "1 item", "3 items": a count with its noun, singular for exactly one.
mole_count_label() {
    local count="${1:-0}" noun="$2"
    if [[ "$count" == "1" ]]; then
        printf '%s %s' "$count" "$noun"
    else
        printf '%s %ss' "$count" "$noun"
    fi
}

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

# Escape a value for embedding inside a double-quoted AppleScript string
# literal: `\` first, then `"`.
mole_applescript_escape() {
    local _as_value="${2:-}"
    _as_value="${_as_value//\\/\\\\}"
    _as_value="${_as_value//\"/\\\"}"
    printf -v "$1" '%s' "$_as_value"
}

mole_is_reverse_dns_bundle_id() {
    local bundle_id="${1:-}"

    [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]] || return 1
    [[ "$bundle_id" =~ ^[A-Za-z0-9][-A-Za-z0-9]*(\.[A-Za-z0-9][-A-Za-z0-9]*)+$ ]]
}

# An executable name a runtime gives every app that does not rename it, so it
# names no single app: an unrenamed Electron binary is `Electron` everywhere.
mole_is_shared_runtime_executable() {
    local lowered=""
    mole_ascii_lowercase lowered "${1:-}"
    [[ "$lowered" == "electron" ]]
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
    # A lower-bound total ("3.27GB+") takes its unit's color.
    local size_unit="${size_human%+}"

    local size_color=""
    case "$size_unit" in
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
# An optional $2 replaces the visible text inside the link only: without a
# link to carry the full path, plain text always shows the whole path.
format_path_link() {
    local path="$1"
    local display="${path/#$HOME/~}"
    if ! is_ansi_supported 2> /dev/null; then
        printf '%s' "$display"
        return 0
    fi
    if [[ -n "${2:-}" ]]; then
        display="$2"
    fi
    # ESC-backslash is the OSC 8 string terminator; kept in a variable since
    # a single-quoted printf format ending in \\ trips ShellCheck SC1003.
    local st=$'\033\\'
    printf '\033]8;;file://%s%s%s\033]8;;%s' "$(percent_encode_path "$path")" "$st" "$display" "$st"
}

# One review row: "⊙ label · value · fact". On a terminal the label itself
# links to the path, so the row needs no command or path field; plain output
# has no links and keeps the path as the last field. path, value and fact
# may each be empty.
mole_review_row() {
    local label="$1" path="${2:-}" value="${3:-}" fact="${4:-}"
    local shown="$label" tail=""
    if [[ -n "$path" ]]; then
        # Settle the check here: inside $(...) stdout is a pipe.
        if is_ansi_supported 2> /dev/null; then
            shown=$(format_path_link "$path" "$label")
        else
            tail=" · $(format_path_link "$path")"
        fi
    fi
    local line="  ${YELLOW}${ICON_REVIEW}${NC} ${shown}"
    [[ -n "$value" ]] && line+=" · ${GREEN}${value}${NC}"
    [[ -n "$fact" ]] && line+=" · ${GRAY}${fact}${NC}"
    echo -e "${line}${tail}"
}

# "a", "a and b", "a, b and c", then "a, b, c and 2 more".
mole_join_names() {
    local count=$#
    [[ $count -gt 0 ]] || return 0
    if [[ $count -gt 4 ]]; then
        printf '%s, %s, %s and %s more' "$1" "$2" "$3" "$((count - 3))"
        return 0
    fi
    local out="$1"
    shift
    while [[ $# -gt 1 ]]; do
        out+=", $1"
        shift
    done
    [[ $# -eq 1 ]] && out+=" and $1"
    printf '%s' "$out"
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

_mole_darwin_user_temp_dir() {
    /usr/bin/getconf DARWIN_USER_TEMP_DIR 2> /dev/null
}

# A run killed before its exit trap leaves its registry and tracked temp
# entries in TMPDIR, and macOS does not expire the per-user Darwin temp root
# (2026-10-27: 25,412 Mole entries there, the oldest from July). Take only the
# two names Mole creates, after the same one-day grace: `mole.registry.<pid>`
# whose pid is gone, and `mole.` plus six letters or digits that is a regular
# file with one link or an empty folder. Only the Darwin temp root qualifies,
# never /tmp or a TMPDIR pointed at a user folder. Mole Mac's
# TemporaryRootLeftoverPolicy applies the same contract.
prune_stale_mole_tmpdir_leftovers() {
    local root="${1:-}"
    local max_age_minutes="${MOLE_TEMP_STALE_MINUTES:-1440}"
    local darwin_temp="" resolved_root=""

    [[ "$max_age_minutes" =~ ^[0-9]+$ ]] || max_age_minutes=1440
    is_root_user && return 0
    [[ -n "$root" && -d "$root" && ! -L "$root" && -O "$root" ]] || return 0

    darwin_temp=$(_mole_darwin_user_temp_dir) || return 0
    [[ -n "$darwin_temp" ]] || return 0
    darwin_temp=$(cd -P "$darwin_temp" 2> /dev/null && pwd) || return 0
    resolved_root=$(cd -P "$root" 2> /dev/null && pwd) || return 0
    [[ "$resolved_root" == "$darwin_temp" ]] || return 0

    # One process listing and set differences instead of a probe per entry:
    # the first run on a long-lived temp root can meet tens of thousands of
    # entries. No listing means every owner is unknown, so nothing goes.
    local live_pids uid
    live_pids=$(ps -axo pid= 2> /dev/null | tr -d ' ') || return 0
    [[ "$live_pids" =~ [0-9] ]] || return 0
    uid=$(id -u 2> /dev/null) || return 0
    [[ "$uid" =~ ^[0-9]+$ ]] || return 0

    # Names stay relative to the root so no path is rebuilt from text. Each
    # list holds one name per line: the token and digit-only patterns leave no
    # room for a crafted name to add a line. "/" is a pattern no name can
    # equal, so an empty keep list still filters correctly. Every pipeline ends
    # in `|| true` because callers run under errexit and pipefail, where a
    # grep that matches nothing would otherwise end the pass early.
    (
        cd "$resolved_root" 2> /dev/null || exit 0

        # What it takes is a day old, so one complete pass a day finds all of
        # it. Listing this root is the cost: about half a second per listing
        # on a long-lived Mac (126,196 entries on 2026-10-31), paid by every
        # mo command before its first line, four listings per run before this.
        local stamp="mole.prune-stamp"
        if [[ -f "$stamp" && ! -L "$stamp" ]] &&
            [[ -n "$(find "$stamp" -maxdepth 0 -mmin "-$max_age_minutes" -print 2> /dev/null)" ]]; then
            exit 0
        fi

        # One listing of the root that also answers every attribute question,
        # tagged per line: O an old one-link file, D an old empty folder, A any
        # other regular file. Names never go back onto a command line, where
        # tens of thousands of them exceed the argument limit. Any failure,
        # including one exec batch, ends the pass with nothing removed and no
        # stamp. The tag and "./" anchor every match, so a name holding a
        # newline cannot turn its tail into an untagged candidate.
        local listing
        listing=$("$FIND_BSD" . -mindepth 1 -maxdepth 1 -name 'mole.*' -user "$uid" \( \
            \( -type f -links 1 -mmin "+$max_age_minutes" -exec printf 'O%s\n' {} + \) -o \
            \( -type f -exec printf 'A%s\n' {} + \) -o \
            \( -type d -empty -mmin "+$max_age_minutes" -exec printf 'D%s\n' {} + \) \
            \) 2> /dev/null) || exit 0

        local old_files old_dirs registries old_registries
        old_files=$(printf '%s\n' "$listing" |
            sed -n -E 's#^O\./(mole\.[A-Za-z0-9]{6})$#\1#p') || exit 0
        old_dirs=$(printf '%s\n' "$listing" |
            sed -n -E 's#^D\./(mole\.[A-Za-z0-9]{6})$#\1#p') || exit 0
        registries=$(printf '%s\n' "$listing" |
            sed -n -E 's#^[OA]\./mole\.registry\.([1-9][0-9]*)$#\1#p') || exit 0
        old_registries=$(printf '%s\n' "$listing" |
            sed -n -E 's#^O\./mole\.registry\.([1-9][0-9]*)$#\1#p') || exit 0

        local live_registries="" keep="/" registry_contents
        if [[ -n "$registries" ]]; then
            live_registries=$(printf '%s\n' "$registries" |
                grep -xF -f <(printf '%s\n' "$live_pids") 2> /dev/null) || live_registries=""
        fi

        # A Mole run that has been open for more than a day still owns the
        # entries its registry lists, however old they are.
        if [[ -n "$live_registries" ]]; then
            # A partial read cannot prove any old entry is unowned. Separate
            # read success from the valid case where filtering finds no names.
            registry_contents=$(printf '%s\n' "$live_registries" | sed 's#^#mole.registry.#' |
                tr '\n' '\0' | xargs -0 cat -- 2> /dev/null) || exit 0
            keep+=$'\n'$(printf '%s\n' "$registry_contents" | sed 's#^.*/##' |
                grep -xE 'mole\.[A-Za-z0-9]{6}' 2> /dev/null) || true
        fi

        if [[ -n "$old_files" ]]; then
            printf '%s\n' "$old_files" | grep -vxF -f <(printf '%s\n' "$keep") 2> /dev/null |
                tr '\n' '\0' | xargs -0 rm -f -- 2> /dev/null || true # SAFE: unowned Mole temp names in the Darwin temp root only
        fi
        if [[ -n "$old_dirs" ]]; then
            # rmdir refuses a folder that gained content since the scan.
            printf '%s\n' "$old_dirs" | grep -vxF -f <(printf '%s\n' "$keep") 2> /dev/null |
                tr '\n' '\0' | xargs -0 rmdir -- 2> /dev/null || true
        fi
        if [[ -n "$old_registries" ]]; then
            printf '%s\n' "$old_registries" |
                grep -vxF -f <(printf '%s\n' "$live_pids") 2> /dev/null |
                sed 's#^#mole.registry.#' | tr '\n' '\0' |
                xargs -0 rm -f -- 2> /dev/null || true # SAFE: dead-owner Mole registries in the Darwin temp root only
        fi

        [[ -L "$stamp" ]] || touch "$stamp" 2> /dev/null || true
        exit 0
    ) || true
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
    prune_stale_mole_tmpdir_leftovers "$MOLE_RESOLVED_TMPDIR"
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
# Usage: update_progress_if_needed <completed> <total> <last_update_time_var> [interval] [label]
# Example: update_progress_if_needed "$completed" "$total" last_progress_update 2
# Returns: 0 if updated, 1 if skipped
update_progress_if_needed() {
    local completed="$1"
    local total="$2"
    local last_update_var="$3" # Name of variable holding last update time
    local interval="${4:-2}"   # Default: update every 2 seconds
    local label="${5:-}"       # What is being scanned, named in the spinner

    # Get current time. Callers tick once per item, so anchor $SECONDS to the
    # epoch once per shell instead of forking date on every call; the sum is
    # the same epoch that callers seed the last update time with.
    if [[ ! "${_MOLE_PROGRESS_EPOCH_BASE:-}" =~ ^[0-9]+$ ]]; then
        _MOLE_PROGRESS_EPOCH_BASE=$(($(get_epoch_seconds) - SECONDS))
    fi
    local current_time=$((_MOLE_PROGRESS_EPOCH_BASE + SECONDS))

    # Get last update time from variable
    local last_time
    # eval: indirect read by name; bash 3.2 has no nameref (declare -n)
    eval "last_time=\${$last_update_var:-0}"
    [[ "$last_time" =~ ^[0-9]+$ ]] || last_time=0

    # Check if enough time has elapsed
    if [[ $((current_time - last_time)) -ge $interval ]]; then
        # Update the spinner text in place; restarting it here blinked the
        # line on every progress tick.
        if [[ -n "$label" ]]; then
            start_section_spinner "Scanning ${label}, $completed/$total..."
        else
            start_section_spinner "Scanning items... $completed/$total"
        fi

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

# Named Electron caches do not carry a reverse-DNS owner in their path.
# Callers supply the exact app name, not an executable such as Electron that
# unrelated apps share. Escape it before both process-name and bundle probes.
_mole_named_app_cache_running() {
    mole_pgrep_any -x "$_MOLE_NAMED_APP_CACHE_PATTERN" \
        -f "/${_MOLE_NAMED_APP_CACHE_PATTERN}[.]app/"
}

_dev_process_delete_guard_allows() {
    # Bind ordinary leaves before probing. Compound probes can supply their
    # own narrower binding; the final callback never refreshes this evidence.
    local _MOLE_DEV_GUARDED_PATH="${1:-}"
    local leaf_parent="" leaf_parent_id="" leaf_target_id=""
    if [[ -n "$_MOLE_DEV_GUARDED_PATH" &&
        "${_MOLE_SAFE_CLEAN_BOUND_PATH:-}" != "$_MOLE_DEV_GUARDED_PATH" ]]; then
        if ! _mole_snapshot_path_identity "$_MOLE_DEV_GUARDED_PATH"; then
            _MOLE_CLEAN_GUARD_REASON="${_MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON:-process state unknown}"
            return 1
        fi
        leaf_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        leaf_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        leaf_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    fi
    mole_clean_process_guard \
        "$_MOLE_DEV_PROCESS_GUARD_PROBE" \
        "$_MOLE_DEV_PROCESS_GUARD_FAMILY started" \
        "${_MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON:-process state unknown}" || return $?

    if [[ -n "$leaf_parent" &&
        "${_MOLE_SAFE_CLEAN_BOUND_PATH:-}" != "$_MOLE_DEV_GUARDED_PATH" ]]; then
        _MOLE_SAFE_CLEAN_BOUND_PATH="$_MOLE_DEV_GUARDED_PATH"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$leaf_parent"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$leaf_parent_id"
        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$leaf_target_id"
    fi
    return 0
}

_dev_report_process_guard_stop() {
    local display_name="$1"
    local family="$2"
    local reason="$3"

    if [[ "$reason" == "process state unknown" || "$reason" == "process or cache path state unknown" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${reason})"
        note_activity
    else
        mole_defer_cleanup_family "$family"
    fi
}

# Preserve a caller's final exclusion before repeating the owner probe. The
# outer callback may itself do slow work, so owner evidence must come last.
_dev_final_process_delete_guard_allows() {
    if [[ -n "$_MOLE_DEV_OUTER_FINAL_GUARD" ]]; then
        "$_MOLE_DEV_OUTER_FINAL_GUARD" "$@" || return $?
    fi
    _dev_process_delete_guard_allows "$@"
}

# Bind a tri-state process probe after sizing and at safe_remove's final sink.
# Guard state is intentionally dynamic so Bash 3.2 callbacks can read it.
_dev_safe_clean_process_guarded() {
    local probe="$1"
    local family="$2"
    local display_name="$3"
    shift 3
    local _MOLE_DEV_PROCESS_GUARD_PROBE="$probe"
    local _MOLE_DEV_PROCESS_GUARD_FAMILY="$family"
    local _MOLE_CLEAN_GUARD_REASON="${family} started"
    local _MOLE_DEV_OUTER_FINAL_GUARD="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    local _MOLE_SAFE_REMOVE_FINAL_GUARD=_dev_final_process_delete_guard_allows

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _dev_process_delete_guard_allows; then
            _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded _dev_process_delete_guard_allows "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi
    return "$guarded_rc"
}

mole_safe_clean_app_cache() {
    local owner="$1"
    shift
    local _MOLE_NAMED_APP_CACHE_PATTERN
    _MOLE_NAMED_APP_CACHE_PATTERN=$(_mole_regex_escape "$owner")
    local rc=0
    _dev_safe_clean_process_guarded _mole_named_app_cache_running "$owner" "${*: -1}" "$@" || rc=$?
    [[ $rc -gt 1 ]] || return 0
    return "$rc"
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
