#!/bin/bash
# Mole - File Operations
# Safe file and directory manipulation with validation

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_FILE_OPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_FILE_OPS_LOADED=1

# Error codes for removal operations
readonly MOLE_ERR_SIP_PROTECTED=10
readonly MOLE_ERR_AUTH_FAILED=11
readonly MOLE_ERR_READONLY_FS=12
readonly MOLE_ERR_PROTECTED_PATH=13
readonly MOLE_ERR_PRIVACY_DENIED=14
readonly MOLE_ERR_MUTABLE_PARENT=15

# Ensure dependencies are loaded
_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi
if [[ -z "${MOLE_LOG_LOADED:-}" ]]; then
    # shellcheck source=lib/core/log.sh
    source "$_MOLE_CORE_DIR/log.sh"
fi
if [[ -z "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeout.sh
    source "$_MOLE_CORE_DIR/timeout.sh"
fi
if [[ -z "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeouts.sh
    source "$_MOLE_CORE_DIR/timeouts.sh"
fi

# Bound production sudo commands while keeping shell-function mocks observable
# in tests. Timeout behavior itself must use a PATH stub so it exercises the
# same external-command branch that users run.
_mole_bounded_sudo() {
    local duration="${1:-${MOLE_TIMEOUT_DISK_VERIFY_SEC:-30}}"
    shift || true
    [[ $# -gt 0 ]] || return 2
    if [[ ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ || "$duration" =~ ^0+(\.0+)?$ ]]; then
        duration=30
    fi

    if declare -F sudo > /dev/null 2>&1; then
        sudo "$@"
        return $?
    fi

    local sudo_bin=""
    sudo_bin=$(command -v sudo 2> /dev/null || true)
    [[ -n "$sudo_bin" ]] || return 127
    run_with_timeout "$duration" "$sudo_bin" "$@"
}

_mole_bounded_sudo_until() {
    local deadline="$1"
    local requested="$2"
    shift 2
    local duration=""
    duration=$(_mole_timeout_with_deadline "$requested" "$deadline") || return $?
    _mole_bounded_sudo "$duration" "$@"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Format duration in seconds to human readable string (e.g., "5 days", "2 months")
format_duration_human() {
    local seconds="${1:-0}"
    [[ ! "$seconds" =~ ^[0-9]+$ ]] && seconds=0

    local days=$((seconds / 86400))

    if [[ $days -eq 0 ]]; then
        echo "today"
    elif [[ $days -eq 1 ]]; then
        echo "1 day"
    elif [[ $days -lt 7 ]]; then
        echo "${days} days"
    elif [[ $days -lt 30 ]]; then
        local weeks=$((days / 7))
        [[ $weeks -eq 1 ]] && echo "1 week" || echo "${weeks} weeks"
    elif [[ $days -lt 365 ]]; then
        local months=$((days / 30))
        [[ $months -eq 1 ]] && echo "1 month" || echo "${months} months"
    else
        local years=$((days / 365))
        [[ $years -eq 1 ]] && echo "1 year" || echo "${years} years"
    fi
}

# ============================================================================
# Path Validation
# ============================================================================

_mole_normalize_deletion_policy_path() {
    local path="$1"
    local slash="/"
    local double_slash="//"

    while [[ "$path" == *"$double_slash"* ]]; do
        path="${path//$double_slash/$slash}"
    done

    while [[ "$path" == *"/./"* ]]; do
        path="${path//\/\.\//$slash}"
    done
    while [[ "$path" == */. ]]; do
        path="${path%/.}"
        [[ -n "$path" ]] || path="/"
    done

    local trimmed="${path%/}"
    [[ -n "$trimmed" ]] && printf '%s\n' "$trimmed" || printf '%s\n' "$path"
}

# This is a live Apple SQLite database. The main file and its WAL companions
# must stay together while PerfPowerServices is running; unlinking or truncating
# any member can split the active database state. Keep the exact path in one
# place so deletion policy and the read-only System Data hint cannot drift.
readonly MOLE_ACTIVE_POWERLOG_DB_PATH="/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"

_mole_is_active_powerlog_database_path() {
    local restore_nocasematch=false
    local result=1

    if ! shopt -q nocasematch; then
        shopt -s nocasematch
        restore_nocasematch=true
    fi

    case "$1" in
        "$MOLE_ACTIVE_POWERLOG_DB_PATH" | \
            "$MOLE_ACTIVE_POWERLOG_DB_PATH-wal" | \
            "$MOLE_ACTIVE_POWERLOG_DB_PATH-shm")
            result=0
            ;;
    esac

    [[ "$restore_nocasematch" == "true" ]] && shopt -u nocasematch
    return "$result"
}

# Live reverse-DNS user-cache guard (#1390).
# Unlinking an open Cache.db (or its -wal/-shm companions) while the owning
# helper still holds the database can send that process into an unbounded write
# loop on unlinked temp files and fill the volume (Autodesk Fusion's
# AcCoreConsole). Size and mtime are never authority for these trees: only a
# conclusive "no matching process" result, plus an open-file check for SQLite
# families, may authorize deletion.
#
# Process-state results are memoized for the current clean process so a batch
# under one cache directory does not fork pgrep once per leaf file. Bash 3.2
# has no associative arrays, so the cache is a pipe-delimited string.

_mole_user_library_caches_prefix() {
    printf '%s\n' "${HOME%/}/Library/Caches"
}

_mole_user_cache_owner_component() {
    local path="$1"
    local prefix
    prefix=$(_mole_user_library_caches_prefix)
    local normalized="${path%/}"
    case "$normalized" in
        "$prefix"/*) ;;
        *) return 1 ;;
    esac
    local remainder="${normalized#"$prefix"/}"
    local component="${remainder%%/*}"
    # Reverse-DNS style only (com.vendor.app). Named trees such as Homebrew
    # stay outside this gate; they have their own process probes.
    [[ "$component" == *.* && "$component" != .* ]] || return 1
    printf '%s\n' "$component"
    return 0
}

# SQLite main file or -wal / -shm / -journal companion. Case-insensitive so a
# cache sweep cannot delete a database through a case variant of its name
# (contributor PR #1391 + main reverse-DNS gate).
_mole_is_sqlite_database_path() {
    local restore_nocasematch=false
    local result=1
    local path="$1"
    local base="${path%-wal}"
    base="${base%-shm}"
    base="${base%-journal}"

    if ! shopt -q nocasematch; then
        shopt -s nocasematch
        restore_nocasematch=true
    fi

    case "$base" in
        *.db | *.sqlite | *.sqlite3)
            result=0
            ;;
    esac

    [[ "$restore_nocasematch" == "true" ]] && shopt -u nocasematch
    return "$result"
}

_mole_is_user_cache_sqlite_family_path() {
    _mole_is_sqlite_database_path "$1"
}

_mole_user_cache_sqlite_main_path() {
    local path="$1"
    case "$path" in
        *-wal) printf '%s\n' "${path%-wal}" ;;
        *-shm) printf '%s\n' "${path%-shm}" ;;
        *-journal) printf '%s\n' "${path%-journal}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

_mole_sqlite_family_base_path() {
    _mole_user_cache_sqlite_main_path "$1"
}

# One process-table snapshot per run, mirroring the Mac app's
# ProcessGuard.cachedProcessTable. The answer cannot change between candidates
# inside a single sweep, and the old code forked pgrep up to three times per
# cache directory.
#
# Lines that must not vote are dropped here: Mole's own process, and the
# measurement tools it forks over the very path being judged. `du -skPx
# ~/Library/Caches/<id>` puts <id> in the table purely because Mole is looking
# at it, which would make every slowly-measured cache report its owner as live.
_MOLE_PROCESS_TABLE=""
_MOLE_PROCESS_TABLE_STATE=""

_mole_process_table() {
    if [[ -n "${_MOLE_PROCESS_TABLE_STATE:-}" ]]; then
        [[ "$_MOLE_PROCESS_TABLE_STATE" == "ok" ]] || return 1
        printf '%s\n' "$_MOLE_PROCESS_TABLE"
        return 0
    fi

    local raw=""
    if ! raw=$(ps -axo pid,ppid,comm,args 2> /dev/null) || [[ -z "$raw" ]]; then
        _MOLE_PROCESS_TABLE_STATE="unavailable"
        return 1
    fi

    # Every text tool below runs under LC_ALL=C so it compares BYTES. A process
    # table is not guaranteed to be UTF-8: an app named 富途牛牛 makes awk and
    # grep abort with "illegal byte sequence" in a UTF-8 locale, and an aborted
    # filter would silently shorten the table into a false "owner is idle".
    local filtered=""

    # Mole must not vote on itself. `pgrep -f` skipped the caller for free;
    # a raw table does not, and every candidate id reaches this code as an
    # argument, so the shell running `mo clean` (and any wrapper above it)
    # carries that id in its own argv. Walking the ppid chain drops the whole
    # invoking tree, which is also what excludes the `du` and `find` children
    # forked to MEASURE the very directory being judged.
    if ! filtered=$(printf '%s\n' "$raw" | LC_ALL=C awk -v self="$$" '
        NR > 1 {
            pid = $1
            parent[pid] = $2
            order[++count] = pid
            # Drop the pid/ppid columns back off the line.
            sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "")
            text[pid] = $0
            comm[pid] = $1
        }
        END {
            for (p = self; p != "" && p != "0" && p != "1" && !(p in seen); p = parent[p]) {
                seen[p] = 1
                mine[p] = 1
            }
            # Descendants too: a command substitution forks a child that
            # inherits our argv verbatim, so the id would come back through
            # the copy even after the ancestor chain is gone.
            for (i = 1; i <= count; i++) {
                pid = order[i]
                depth = 0
                for (p = pid; p != "" && p != "0" && p != "1" && depth < 64; p = parent[p]) {
                    if (p == self) { mine[pid] = 1; break }
                    depth++
                }
            }
            for (i = 1; i <= count; i++) {
                pid = order[i]
                if (pid in mine) continue
                n = split(comm[pid], parts, "/")
                base = parts[n]
                if (base == "du" || base == "find" || base == "mdfind" ||
                    base == "ps" || base == "grep" || base == "stat" ||
                    base == "ls" || base == "rm") continue
                if (index(tolower(text[pid]), "com.tw93.mole") > 0) continue
                print text[pid]
            }
        }'); then
        # A filter that died mid-table would leave a SHORT table, which reads
        # as "nothing owns this cache". Refuse to answer instead.
        _MOLE_PROCESS_TABLE_STATE="unavailable"
        return 1
    fi

    _MOLE_PROCESS_TABLE="$filtered"
    _MOLE_PROCESS_TABLE_STATE="ok"
    printf '%s\n' "$_MOLE_PROCESS_TABLE"
    return 0
}

# Escape every non-alphanumeric byte so a cache-dir component is matched as a
# literal inside an ERE.
_mole_regex_escape() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_]/\\&/g'
}

# Tri-state process probe for a reverse-DNS cache owner:
# 0 = a matching process is running, 1 = none matched, 2 = could not tell.
#
# Two acceptance shapes, deliberately asymmetric (parity with the Mac app's
# ProcessGuard.processListMentionsCacheOwner):
#   1. The full reverse-DNS id appears in the line. Self-identifying, so a
#      plain substring is enough.
#   2. The last DNS label appears as a DELIMITED token AND the same line
#      independently names another component of the id. Corroboration is what
#      makes a shared binary name usable: Claude and VS Code both ship a
#      Squirrel binary called ShipIt, so `pgrep -x ShipIt` attributed VS Code's
#      cache to a running Claude. Measured on this machine before the change,
#      34 of 59 idle caches were called busy; the plain-substring shapes it
#      relied on also read "default" out of syncdefaultsd and "data" out of
#      dataaccessd.
_mole_user_cache_owner_process_state() {
    local owner="$1"
    [[ -n "$owner" ]] || return 2

    local cache_token="|${owner}:"
    case "${_MOLE_USER_CACHE_OWNER_STATE_CACHE:-}" in
        *"${cache_token}0|"*) return 0 ;;
        *"${cache_token}1|"*) return 1 ;;
        *"${cache_token}2|"*) return 2 ;;
    esac

    local table=""
    if ! table=$(_mole_process_table); then
        # An unreadable process table is not proof the owner is idle.
        return 2
    fi

    # Feed the table by here-string, never through a pipe. `grep -q` exits on
    # its first match, and the printf still writing into that closed pipe takes
    # SIGPIPE, which bash reports as "printf: write error: Broken pipe" on
    # stderr; during `mo clean` that lands in the middle of the user's output.
    local state=1
    if LC_ALL=C grep -qiF -- "$owner" <<< "$table"; then
        state=0
    fi

    local leaf="${owner##*.}"
    if [[ $state -eq 1 && -n "$leaf" && "$leaf" != "$owner" && ${#leaf} -ge 4 ]]; then
        # "com" is in every reverse-DNS id and corroborates nothing.
        local -a corroborators=()
        local old_ifs="$IFS"
        local -a components=()
        IFS='.' read -r -a components <<< "$owner"
        IFS="$old_ifs"
        local index=0
        local last_index=$((${#components[@]} - 1))
        local component
        for component in "${components[@]}"; do
            if [[ $index -lt $last_index && ${#component} -ge 4 ]]; then
                case "$component" in
                    [cC][oO][mM]) ;;
                    *) corroborators+=("$(_mole_regex_escape "$component")") ;;
                esac
            fi
            index=$((index + 1))
        done

        if [[ ${#corroborators[@]} -gt 0 ]]; then
            local escaped_leaf
            escaped_leaf=$(_mole_regex_escape "$leaf")
            local alternation=""
            for component in "${corroborators[@]}"; do
                alternation="${alternation:+$alternation|}$component"
            done
            local boundary_open='(^|[^A-Za-z0-9])'
            local boundary_close='([^A-Za-z0-9]|$)'
            # Two passes, so both tokens must land on the SAME line. Materialize
            # the first result instead of piping into a `grep -q`, for the same
            # broken-pipe reason as the substring check above.
            local leaf_lines=""
            leaf_lines=$(LC_ALL=C grep -iE -- \
                "${boundary_open}${escaped_leaf}${boundary_close}" <<< "$table") || leaf_lines=""
            if [[ -n "$leaf_lines" ]] && LC_ALL=C grep -qiE -- \
                "${boundary_open}(${alternation})${boundary_close}" <<< "$leaf_lines"; then
                state=0
            fi
        fi
    fi

    _MOLE_USER_CACHE_OWNER_STATE_CACHE="${_MOLE_USER_CACHE_OWNER_STATE_CACHE-}${cache_token}${state}|"
    return "$state"
}

# Is the database family live? 0 = in use, 1 = idle, 2 = could not tell.
# WAL-mode -shm only exists while at least one connection is open (PR #1391),
# but a stale -shm can remain after an unclean exit. When -shm exists we must
# still verify a process holds it open; otherwise the guard refuses forever on
# orphaned caches (#1439).
_mole_sqlite_database_in_use() {
    local path="$1"
    local base
    base=$(_mole_sqlite_family_base_path "$path")

    command -v lsof > /dev/null 2>&1 || return 2

    # Check every family member with lsof, including a stale -shm. If any
    # process has a handle open the database is live; if none do, the -shm is
    # orphaned and deletion is safe.
    local candidate
    for candidate in "$base" "${base}-wal" "${base}-shm"; do
        [[ -e "$candidate" ]] || continue
        local lsof_rc=0
        if declare -f run_with_timeout > /dev/null 2>&1; then
            run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" lsof -F n -- "$candidate" \
                > /dev/null 2>&1 || lsof_rc=$?
        else
            lsof -F n -- "$candidate" > /dev/null 2>&1 || lsof_rc=$?
        fi
        if [[ $lsof_rc -eq 0 ]]; then
            return 0
        fi
        if [[ $lsof_rc -ne 1 ]]; then
            return 2
        fi
    done
    return 1
}

_mole_user_cache_sqlite_has_open_handle() {
    local path="$1"
    local state=0
    _mole_sqlite_database_in_use "$path" || state=$?
    return "$state"
}

# Return 0 when deletion must be refused (live owner or open SQLite handle).
_mole_should_refuse_live_user_cache_path() {
    local path="$1"
    local owner=""
    owner=$(_mole_user_cache_owner_component "$path") || return 1

    local process_state=0
    _mole_user_cache_owner_process_state "$owner" || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        debug_log "Live user cache owner running, keep: $path ($owner)"
        return 0
    fi
    if [[ $process_state -eq 2 ]]; then
        debug_log "Live user cache owner state unknown, keep: $path ($owner)"
        return 0
    fi

    # Process is conclusively idle. Still refuse SQLite family members that
    # another process has open, or that still expose a WAL -shm (PR #1391).
    if _mole_is_user_cache_sqlite_family_path "$path"; then
        local open_state=0
        _mole_user_cache_sqlite_has_open_handle "$path" || open_state=$?
        if [[ $open_state -eq 0 ]]; then
            debug_log "Open SQLite user cache handle, keep: $path"
            return 0
        fi
        # open_state 2 (lsof missing) with no -shm: process probe already idle.
    elif [[ -d "$path" ]]; then
        local candidate open_state
        for candidate in "$path/Cache.db" "$path"/*.db; do
            [[ -f "$candidate" ]] || continue
            open_state=0
            _mole_user_cache_sqlite_has_open_handle "$candidate" || open_state=$?
            if [[ $open_state -eq 0 ]]; then
                debug_log "Open SQLite under user cache dir, keep: $path ($candidate)"
                return 0
            fi
        done
    fi

    return 1
}

_mole_path_is_same_existing_file() {
    local path="$1"
    local protected_path="$2"
    [[ -e "$path" && -e "$protected_path" && "$path" -ef "$protected_path" ]]
}

_mole_path_is_within_existing_root() {
    local path="$1"
    local protected_root="$2"
    [[ -e "$protected_root" ]] || return 1

    local probe="$path"
    while [[ "$probe" == /* ]]; do
        if _mole_path_is_same_existing_file "$probe" "$protected_root"; then
            return 0
        fi
        [[ "$probe" == "/" ]] && break
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe="/"
    done
    return 1
}

# Deletion policy only. App/data protection stays in app_protection.sh.
_mole_is_critical_deletion_path() {
    local path="$1"

    case "$path" in
        # Homebrew (Intel) and user-installed software live here; individual
        # entries stay deletable. The Homebrew roots themselves are still
        # critical roots and must fall through to the deny arms below.
        /usr/local/* | /opt/homebrew/*)
            return 1
            ;;
        / | \
            /bin | /bin/* | \
            /dev | /dev/* | \
            /sbin | /sbin/* | \
            /usr | /usr/* | \
            /System | /System/* | \
            /Library | /Library/Apple | /Library/Apple/* | \
            /Library/Application\ Support | \
            /Library/Extensions | /Library/Extensions/* | \
            /Library/Keychains | /Library/Keychains/* | \
            /Applications | \
            /Applications/Finder.app | /Applications/Finder.app/* | \
            /Applications/Safari.app | /Applications/Safari.app/* | \
            /Volumes | \
            /opt | /opt/homebrew | \
            /Users | /Users/Shared | /Users/Guest | /Users/Guest/*)
            return 0
            ;;
        /private | /private/tmp)
            return 0
            ;;
        /etc | /etc/* | /private/etc | /private/etc/*)
            return 0
            ;;
        /var | /var/db | /var/db/* | /var/audit | /var/audit/* | /var/root | \
            /private/var | /private/var/tmp | /private/var/folders | \
            /private/var/db | /private/var/db/* | /private/var/audit | /private/var/audit/* | /private/var/root)
            return 0
            ;;
    esac

    # Reject a user home root (/Users/<name>) while keeping its children
    # deletable. A single case glob cannot express "exactly one component
    # under /Users", so match one level here: this catches the empty-variable
    # collapse "/Users/$user/$leaf" -> "/Users/<name>" that would otherwise
    # hand rm -rf an entire home directory.
    if [[ "$path" == /Users/* && "$path" != /Users/*/* ]]; then
        return 0
    fi

    # APFS is normally case-insensitive but case-preserving. Uppercase aliases
    # such as /SYSTEM and /OPT/HOMEBREW are not symlinks, so string policy
    # checks alone can miss that they are the same inode as protected roots.
    local protected_root
    local -a exact_roots=(
        / /Applications /Library /Volumes /Network /cores /etc /home /net
        /tmp /var /private /private/tmp /private/var /private/var/tmp
        /private/var/folders /Users /opt /opt/homebrew
    )
    for protected_root in "${exact_roots[@]}"; do
        if _mole_path_is_same_existing_file "$path" "$protected_root"; then
            return 0
        fi
    done

    local -a protected_trees=(
        /bin /dev /sbin /usr /System /private/etc /private/var/audit
        /private/var/db /private/var/root /Library/Apple /Library/Extensions
        /Library/Keychains /Applications/Finder.app /Applications/Safari.app
    )
    for protected_root in "${protected_trees[@]}"; do
        if _mole_path_is_within_existing_root "$path" "$protected_root"; then
            return 0
        fi
    done

    # Protect every account root even when a caller changes only component
    # casing (for example /USERS/SHARED on a case-insensitive volume).
    local parent_path="${path%/*}"
    [[ -n "$parent_path" ]] || parent_path="/"
    if _mole_path_is_same_existing_file "$parent_path" "/Users"; then
        return 0
    fi

    return 1
}

# Validate path for deletion (absolute, no traversal, not system dir)
validate_path_for_deletion() {
    local path="$1"

    # Check path is not empty
    if [[ -z "$path" ]]; then
        log_error "Path validation failed: empty path"
        return 1
    fi

    # Check path is absolute
    if [[ "$path" != /* ]]; then
        log_error "Path validation failed: path must be absolute: $path"
        return 1
    fi

    # Check for path traversal attempts
    # Only reject .. when it appears as a complete path component (/../ or /.. or ../)
    # This allows legitimate directory names containing .. (e.g., Firefox's "name..files")
    if [[ "$path" =~ (^|/)\.\.(\/|$) ]]; then
        log_error "Path validation failed: path traversal not allowed: $path"
        return 1
    fi

    # Check path doesn't contain dangerous characters
    if [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" =~ $'\n' ]]; then
        log_error "Path validation failed: contains control characters: $path"
        return 1
    fi

    local policy_path
    policy_path=$(_mole_normalize_deletion_policy_path "$path")

    # Check symlink target if path is a symbolic link
    if [[ -L "$path" ]]; then
        local link_target
        link_target=$(readlink "$path" 2> /dev/null) || {
            log_error "Cannot read symlink: $path"
            return 1
        }

        # Resolve relative symlinks to absolute paths for validation
        local resolved_target="$link_target"
        if [[ "$link_target" != /* ]]; then
            local link_dir
            link_dir=$(dirname "$path")
            resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") || resolved_target=""
        fi

        # Validate resolved target against protected paths
        if [[ -n "$resolved_target" ]]; then
            resolved_target=$(_mole_normalize_deletion_policy_path "$resolved_target")
            if _mole_is_critical_deletion_path "$resolved_target"; then
                log_error "Symlink points to protected system path: $path -> $resolved_target"
                return 1
            fi
        fi
    fi

    # Ancestor-symlink guard. The checks above (deny list, protection policy)
    # match on the LITERAL path string, and the -L test above only inspects the
    # leaf. If any ANCESTOR component is a symlink, the string matches nothing
    # dangerous while the actual rm follows the link into the real target:
    # a redirected "~/Library/Caches" would let a cache sweep walk into
    # ~/Documents or a system tree. Canonicalize the parent (physical cd
    # resolves every ancestor link) and re-run the deny predicates on the
    # resolved leaf. Deny-only: a resolved path never grants permission the
    # literal path lacked, so legitimate targets keep their existing verdict.
    # Runs BEFORE the allowlists below, which would otherwise early-return past
    # this gate for /private/* paths.
    #
    # This sits on the hot path (every deletion candidate), so the common case
    # must stay fork-free: walk the ancestors with the [[ -L ]] builtin and only
    # pay for the canonicalizing subshell when one of them really is a symlink.
    # A dirname + `cd -P` on every call cost ~2ms, about +23% on validation.
    local parent_dir resolved_parent probe
    local ancestor_is_link=false
    parent_dir="${policy_path%/*}"
    [[ -z "$parent_dir" ]] && parent_dir="/"
    if [[ -d "$parent_dir" ]]; then
        probe="$parent_dir"
        while [[ "$probe" == /?* ]]; do
            if [[ -L "$probe" ]]; then
                ancestor_is_link=true
                break
            fi
            probe="${probe%/*}"
        done
    fi
    if [[ "$ancestor_is_link" == "true" ]]; then
        resolved_parent=$(cd -P "$parent_dir" 2> /dev/null && pwd -P) || resolved_parent=""
        if [[ -n "$resolved_parent" && "$resolved_parent" != "$parent_dir" ]]; then
            local resolved_path
            resolved_path=$(_mole_normalize_deletion_policy_path "${resolved_parent}/${policy_path##*/}")
            if _mole_is_critical_deletion_path "$resolved_path"; then
                log_error "Path validation failed: resolves into a critical system path: $path -> $resolved_path"
                return 1
            fi
            if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$resolved_path"; then
                if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                    log_warning "Path validation: resolves into a protected path: $path -> $resolved_path"
                fi
                return 1
            fi
        fi
    fi

    # Allow deletion of coresymbolicationd cache (safe system cache that can be rebuilt)
    case "$policy_path" in
        /System/Library/Caches/com.apple.coresymbolicationd/data | /System/Library/Caches/com.apple.coresymbolicationd/data/*)
            return 0
            ;;
    esac

    # Reject the active power telemetry database before the broad powerlog
    # allowlist below. Size and mtime are diagnostic signals, never deletion
    # authority for a database that a KeepAlive system service can reopen.
    if _mole_is_active_powerlog_database_path "$policy_path"; then
        debug_log "Path validation: active powerlog database kept: $policy_path"
        return 1
    fi

    # Live reverse-DNS user caches (process + SQLite handle). Covers Autodesk
    # helpers and every other com.vendor tree under ~/Library/Caches (#1390).
    if _mole_should_refuse_live_user_cache_path "$policy_path"; then
        debug_log "Path validation: live user cache kept: $policy_path"
        return 1
    fi

    # General SQLite family gate from PR #1391: refuse any in-use database even
    # outside reverse-DNS cache dirs (fail closed when lsof cannot answer).
    if _mole_is_sqlite_database_path "$policy_path"; then
        local sqlite_state=0
        _mole_sqlite_database_in_use "$policy_path" || sqlite_state=$?
        if [[ $sqlite_state -eq 0 || $sqlite_state -eq 2 ]]; then
            debug_log "Path validation: in-use SQLite database kept: $policy_path"
            return 1
        fi
    fi

    # Endpoint-security/EDR agent caches under var/folders look like ordinary
    # rebuildable caches, but deleting anything in a sensor's container trips
    # tamper detection (reported as malware). Reject here, before the
    # /private/var/folders allowlist below, so every deletion caller is covered,
    # not only the cleanup sweeps that pre-check the predicate.
    if declare -f is_endpoint_security_cache_path > /dev/null 2>&1 && is_endpoint_security_cache_path "$policy_path"; then
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            log_warning "Path validation: endpoint-security agent cache skipped: $policy_path"
        fi
        return 1
    fi

    # Allow known safe paths under /private
    case "$policy_path" in
        /private/tmp/* | \
            /private/var/tmp/* | \
            /private/var/log | /private/var/log/* | \
            /private/var/folders/* | \
            /private/var/db/diagnostics | /private/var/db/diagnostics/* | \
            /private/var/db/DiagnosticPipeline | /private/var/db/DiagnosticPipeline/* | \
            /private/var/db/powerlog | /private/var/db/powerlog/* | \
            /private/var/db/reportmemoryexception | /private/var/db/reportmemoryexception/* | \
            /private/var/db/receipts/*.bom | /private/var/db/receipts/*.plist)
            return 0
            ;;
    esac

    # Check path isn't critical system directory
    if _mole_is_critical_deletion_path "$policy_path"; then
        log_error "Path validation failed: critical system path: $path"
        return 1
    fi

    # Check if path is protected (keychains, system settings, etc)
    if declare -f should_protect_path > /dev/null 2>&1; then
        if should_protect_path "$policy_path"; then
            if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                log_warning "Path validation: protected path skipped: $policy_path"
            fi
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# Safe Removal Operations
# ============================================================================

_record_file_ops_dry_run_target() {
    local path="$1"
    local precomputed_size_kb="${2:-}"

    declare -f record_dry_run_cleanup_target > /dev/null 2>&1 || return 0

    local size_kb=0
    local size_known=true
    if [[ -n "$precomputed_size_kb" && "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
        size_kb="$precomputed_size_kb"
    else
        local measured_size=""
        local measure_rc=0
        measured_size=$(get_path_size_kb "$path" 2> /dev/null) || measure_rc=$?
        if [[ $measure_rc -ge 128 ]]; then
            return "$measure_rc"
        fi
        if [[ $measure_rc -eq 124 ]]; then
            # Sizing budget exhausted: preview the item as size-unknown rather
            # than cancelling the whole dry run.
            MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
        fi
        if [[ $measure_rc -eq 0 && "$measured_size" =~ ^[0-9]+$ ]]; then
            size_kb="$measured_size"
        else
            size_known=false
        fi
    fi

    local record_rc=0
    record_dry_run_cleanup_target \
        "$path" "$size_kb" 1 "$size_known" || record_rc=$?
    [[ $record_rc -eq 124 || $record_rc -ge 128 ]] && return "$record_rc"
    return 0
}

# Preserve the first timeout or signal observed by a clean deletion sink. Some
# older cleanup families intentionally treat ordinary item failures as
# best-effort; this sticky status prevents those `|| true` paths from turning a
# user interrupt into permission to continue deleting later targets.
_mole_record_clean_cancellation() {
    local status="$1"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" &&
        ("$status" -eq 124 || "$status" -ge 128) ]]; then
        local existing="${MOLE_CLEAN_CANCEL_STATUS:-0}"
        if [[ $existing -ne 124 && $existing -lt 128 ]]; then
            MOLE_CLEAN_CANCEL_STATUS=$status
            export MOLE_CLEAN_CANCEL_STATUS
        fi
    fi
}

# Safe wrapper around rm -rf with validation
safe_remove() {
    local path="$1"
    local silent="${2:-false}"
    local precomputed_size_kb="${3:-}"
    local deadline_seconds="${4:-}"
    local expected_parent="${5:-}"
    local expected_parent_id="${6:-}"
    local expected_target_id="${7:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" &&
        ("$pending_clean_cancel" -eq 124 || "$pending_clean_cancel" -ge 128) ]]; then
        return "$pending_clean_cancel"
    fi

    # Validate path. Silent cleanup callers still need the same policy result,
    # but should not print one validation warning per skipped cache item.
    if [[ "$silent" == "true" ]]; then
        validate_path_for_deletion "$path" 2> /dev/null || return 1
    elif ! validate_path_for_deletion "$path"; then
        return 1
    fi

    # Honor the user whitelist here, not just in safe_clean. safe_remove is
    # called directly by several clean/optimize flows (Xcode DerivedData,
    # mail downloads, deep-system caches, broken LaunchAgents) that would
    # otherwise ignore a user's whitelist selection. is_path_whitelisted is
    # a no-op when the whitelist is empty, and uninstall does not route
    # through safe_remove, so this stays scoped to clean/optimize. See #710.
    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path"; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "whitelist"
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Keep preview eligibility identical to real cleanup. This first check
    # rejects an already-present compiled model cache before the dry-run return;
    # the final-sink check below still catches one created during size probing.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped removal for compiled model cache: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return 1
    fi

    # Live reverse-DNS caches under ~/Library/Caches (#1390): refuse while the
    # owning process is running or an open SQLite handle is proven. Final sink
    # so both safe_clean and direct safe_remove callers are covered.
    if _mole_should_refuse_live_user_cache_path "$path"; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "live user cache"
        return 1
    fi

    # Dry-run mode: log but don't delete
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local dry_record_rc=0
        _record_file_ops_dry_run_target \
            "$path" "$precomputed_size_kb" || dry_record_rc=$?
        if [[ $dry_record_rc -eq 124 || $dry_record_rc -ge 128 ]]; then
            _mole_record_clean_cancellation "$dry_record_rc"
            return "$dry_record_rc"
        fi
        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            local file_type="file"
            [[ -d "$path" ]] && file_type="directory"
            [[ -L "$path" ]] && file_type="symlink"

            local file_size=""
            local file_age=""

            if [[ -e "$path" ]]; then
                local size_kb=0
                local size_rc=0
                size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
                if [[ $size_rc -eq 124 || $size_rc -ge 128 ]]; then
                    _mole_record_clean_cancellation "$size_rc"
                    return "$size_rc"
                fi
                [[ $size_rc -eq 0 ]] || size_kb=0
                if [[ "$size_kb" -gt 0 ]]; then
                    file_size=$(bytes_to_human "$((size_kb * 1024))")
                fi

                if [[ -f "$path" || -d "$path" ]] && ! [[ -L "$path" ]]; then
                    local mod_time=0
                    local stat_rc=0
                    mod_time=$(stat -f%m "$path" 2> /dev/null) || stat_rc=$?
                    if [[ $stat_rc -eq 124 || $stat_rc -ge 128 ]]; then
                        _mole_record_clean_cancellation "$stat_rc"
                        return "$stat_rc"
                    fi
                    [[ $stat_rc -eq 0 ]] || mod_time=0
                    local now
                    now=$(date +%s 2> /dev/null || echo "0")
                    if [[ "$mod_time" -gt 0 && "$now" -gt 0 ]]; then
                        file_age=$(((now - mod_time) / 86400))
                    fi
                fi
            fi

            debug_file_action "[DRY RUN] Would remove" "$path" "$file_size" "$file_age"
        else
            debug_log "[DRY RUN] Would remove: $path"
        fi
        return 0
    fi

    debug_log "Removing: $path"

    # Calculate size before deletion for logging.
    # Accept pre-computed size to skip redundant I/O when the caller already measured.
    local size_kb=0
    local size_human=""
    if oplog_enabled; then
        if [[ -n "$precomputed_size_kb" ]]; then
            if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                size_kb="$precomputed_size_kb"
            fi
        elif [[ -e "$path" ]]; then
            local size_probe_rc=0
            local size_probe_timeout=""
            size_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                "$deadline_seconds") || size_probe_rc=$?
            if [[ $size_probe_rc -eq 0 ]]; then
                size_kb=$(get_path_size_kb "$path" "$size_probe_timeout" 2> /dev/null) || size_probe_rc=$?
            fi
            if [[ $size_probe_rc -eq 124 ]]; then
                # Sizing budget exhausted: still remove the item, with the
                # freed total under-reported, matching the batch-sizing policy.
                MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
            fi
            if [[ $size_probe_rc -ge 128 ]]; then
                _mole_record_clean_cancellation "$size_probe_rc"
                return "$size_probe_rc"
            fi
            [[ $size_probe_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        fi
        if [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]; then
            size_human=$(bytes_to_human "$((size_kb * 1024))" 2> /dev/null || echo "${size_kb}KB")
        fi
    fi

    # Recheck at the final sink. A daemon can create this compiled-model cache
    # while the preceding size probe walks the target, and deleting its parent
    # then breaks recognition until the owning process restarts.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped removal after compiled model cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return 1
    fi

    # Recheck live-owner / open-SQLite state after size probing: a helper can
    # launch while du is walking the tree (same race class as the compiled
    # model cache check above).
    if _mole_should_refuse_live_user_cache_path "$path"; then
        debug_log "Skipped removal after live user cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "live user cache"
        return 1
    fi

    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing removal after final path identity changed: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi

    # Last hop before rm, for callers whose exclusion depends on state this
    # function cannot express as a parent/target inode pair. A candidate list
    # that skipped a live owner root only proves where that root pointed when
    # the list was built; re-asking here closes the rest of the window rather
    # than leaving it open from discovery all the way to the unlink. Set
    # _MOLE_SAFE_REMOVE_FINAL_GUARD to a function name that takes the path and
    # returns non-zero to refuse.
    local final_sink_guard="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    if [[ -n "$final_sink_guard" ]] && declare -f "$final_sink_guard" > /dev/null 2>&1; then
        if ! "$final_sink_guard" "$path"; then
            debug_log "Refusing removal after the final sink guard denied: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "sink guard denied"
            return 1
        fi
    fi

    # Perform the deletion
    # Use || to capture the exit code so set -e won't abort on rm failures
    local error_msg
    local rm_exit=0
    local section_deadline_spent=0
    if declare -F rm > /dev/null 2>&1; then
        error_msg=$(rm -rf "$path" 2>&1) || rm_exit=$? # safe_remove
    else
        local rm_timeout=""
        rm_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            "$deadline_seconds") || rm_exit=$?
        if [[ $rm_exit -eq 0 ]]; then
            error_msg=$(run_with_timeout "$rm_timeout" rm -rf "$path" < /dev/null 2>&1) || rm_exit=$? # safe_remove
        else
            # The section's own wall-clock budget ran out, so rm never started.
            section_deadline_spent=1
        fi
    fi

    if [[ $rm_exit -eq 124 ]]; then
        debug_log "Removal timed out: $path"
        if [[ $section_deadline_spent -eq 1 ]]; then
            # Not a slow removal: the caller's section deadline expired before
            # rm ran, and that section reports its own stop. Counting it here
            # would point the user at the per-item removal budget instead.
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "section time limit reached"
        else
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "removal timed out"
            # A slow disk can exceed the per-item removal budget. That is a
            # failed removal, not a user interrupt: count it and keep going so
            # one slow cache never cancels the remaining cleanup.
            MOLE_CLEAN_REMOVAL_TIMEOUTS=$((${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0} + 1))
        fi
        return 124
    fi

    # Preserve interrupt semantics so callers can abort long-running deletions.
    if [[ $rm_exit -ge 128 ]]; then
        _mole_record_clean_cancellation "$rm_exit"
        return "$rm_exit"
    fi

    if [[ $rm_exit -eq 0 ]]; then
        # Log successful removal
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "$size_human"
        return 0
    else
        # Check if it's a permission error
        if [[ "$error_msg" == *"Permission denied"* ]] || [[ "$error_msg" == *"Operation not permitted"* ]]; then
            MOLE_PERMISSION_DENIED_COUNT=${MOLE_PERMISSION_DENIED_COUNT:-0}
            MOLE_PERMISSION_DENIED_COUNT=$((MOLE_PERMISSION_DENIED_COUNT + 1))
            export MOLE_PERMISSION_DENIED_COUNT
            debug_log "Permission denied: $path, may need Full Disk Access"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "permission denied"
        else
            [[ "$silent" != "true" ]] && log_error "Failed to remove: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "error"
        fi
        return 1
    fi
}

# Safe symlink removal (for pre-validated symlinks only)
safe_remove_symlink() {
    local path="$1"
    local use_sudo="${2:-false}"
    local expected_parent="${3:-}"
    local expected_parent_id="${4:-}"
    local expected_target_id="${5:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" &&
        ("$pending_clean_cancel" -eq 124 || "$pending_clean_cancel" -ge 128) ]]; then
        return "$pending_clean_cancel"
    fi

    if [[ ! -L "$path" ]]; then
        return 1
    fi

    if ! validate_path_for_deletion "$path"; then
        return 1
    fi

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path"; then
        debug_log "Skipped symlink removal for whitelisted path: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "whitelist"
        return 1
    fi

    if [[ "$use_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        if [[ ${EUID:-0} -ne 0 ]]; then
            use_sudo=false
        else
            debug_log "Refusing privileged symlink removal below mutable parent: $path"
            return 1
        fi
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local dry_record_rc=0
        _record_file_ops_dry_run_target "$path" || dry_record_rc=$?
        if [[ $dry_record_rc -eq 124 || $dry_record_rc -ge 128 ]]; then
            _mole_record_clean_cancellation "$dry_record_rc"
            return "$dry_record_rc"
        fi
        debug_log "[DRY RUN] Would remove symlink: $path"
        return 0
    fi

    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing symlink removal after final path identity changed: $path"
        return 1
    fi

    local rm_exit=0
    if [[ "$use_sudo" == "true" ]]; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo blocked in test mode"
            return 1
        fi
        sudo -n rm "$path" 2> /dev/null || rm_exit=$?
    else
        rm "$path" 2> /dev/null || rm_exit=$?
    fi

    if [[ $rm_exit -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "symlink"
        return 0
    else
        if [[ $rm_exit -eq 124 || $rm_exit -ge 128 ]]; then
            _mole_record_clean_cancellation "$rm_exit"
            return "$rm_exit"
        fi
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "symlink removal failed"
        return 1
    fi
}

# A privileged path operation is only safe when every parent directory is
# immutable to unprivileged users. Checking `-w` alone is insufficient: a
# directory owner can chmod a 0555 parent after validation, replace a component,
# and redirect a later sudo rm/mv. Fail closed on non-root ownership, writable
# mode bits, symlinks, unreadable metadata, and effective ACL write access.
_mole_privileged_path_has_mutable_ancestor() {
    local path="$1"
    local probe="${path%/*}"
    local invoking_uid=""
    [[ -n "$probe" ]] || probe="/"
    invoking_uid=$(get_invoking_uid 2> /dev/null || true)
    [[ "$invoking_uid" =~ ^[0-9]+$ ]] || return 0

    while true; do
        if [[ -L "$probe" ]]; then
            return 0
        fi

        local owner_uid=""
        local mode=""
        owner_uid=$($STAT_BSD -f%u "$probe" 2> /dev/null || true)
        mode=$($STAT_BSD -f%Lp "$probe" 2> /dev/null || true)
        if [[ ! "$owner_uid" =~ ^[0-9]+$ || ! "$mode" =~ ^[0-7]+$ ]]; then
            return 0
        fi
        if [[ "$owner_uid" -ne 0 ]] || (((8#$mode & 0022) != 0)); then
            return 0
        fi
        if [[ "$invoking_uid" -ne 0 ]]; then
            if [[ ${EUID:-0} -eq "$invoking_uid" ]]; then
                [[ -w "$probe" ]] && return 0
            elif [[ ${EUID:-0} -eq 0 ]]; then
                # Under `sudo mo`, the shell's -w probe reflects root rather
                # than the invoking user. Drop authority for the ACL check so
                # immutable system parents do not become false positives.
                local acl_probe_rc=0
                _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                    -n -u "#$invoking_uid" /bin/test -w "$probe" < /dev/null 2> /dev/null || acl_probe_rc=$?
                if [[ $acl_probe_rc -eq 0 ]]; then
                    return 0
                fi
                # Only test's ordinary false status proves the invoking user
                # cannot write here. Timeout, auth, and execution failures are
                # unknown and must classify the ancestor as mutable.
                if [[ $acl_probe_rc -ne 1 ]]; then
                    return 0
                fi
            else
                return 0
            fi
        fi

        [[ "$probe" == "/" ]] && break
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe="/"
    done
    return 1
}

# Safe sudo removal with symlink and parent-component protection
safe_sudo_remove() {
    local path="$1"
    local precomputed_size_kb="${2:-}"
    local deadline_seconds="${3:-}"
    local expected_parent="${4:-}"
    local expected_parent_id="${5:-}"
    local expected_target_id="${6:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" &&
        ("$pending_clean_cancel" -eq 124 || "$pending_clean_cancel" -ge 128) ]]; then
        return "$pending_clean_cancel"
    fi

    if ! validate_path_for_deletion "$path"; then
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$path"; then
            debug_log "Skipped sudo remove for protected path: $path"
            return "$MOLE_ERR_PROTECTED_PATH"
        else
            log_error "Path validation failed for sudo remove: $path"
        fi
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    if [[ -L "$path" ]]; then
        log_error "Refusing to sudo remove symlink: $path"
        return 1
    fi

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path"; then
        debug_log "Skipped sudo remove for whitelisted path: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "whitelist"
        return 1
    fi

    # This policy must run before dry-run/test-mode returns so preview and real
    # privileged cleanup agree on the eligible target set.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped sudo removal for compiled model cache: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return "$MOLE_ERR_PROTECTED_PATH"
    fi

    if _mole_privileged_path_has_mutable_ancestor "$path"; then
        if [[ ${EUID:-0} -ne 0 ]]; then
            debug_log "Downgrading sudo remove below mutable parent: $path"
            safe_remove "$path" true "" "$deadline_seconds" \
                "$expected_parent" "$expected_parent_id" "$expected_target_id"
            return $?
        fi
        debug_log "Refusing sudo remove below mutable parent: $path"
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local dry_record_rc=0
        _record_file_ops_dry_run_target \
            "$path" "$precomputed_size_kb" || dry_record_rc=$?
        if [[ $dry_record_rc -eq 124 || $dry_record_rc -ge 128 ]]; then
            _mole_record_clean_cancellation "$dry_record_rc"
            return "$dry_record_rc"
        fi
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            log_info "[DRY-RUN] Would sudo remove: $path"
            return 0
        fi
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo blocked in test mode"
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            local file_type="file"
            [[ -d "$path" ]] && file_type="directory"

            local file_size=""
            local file_age=""

            local exists_rc=0
            _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                -n test -e "$path" < /dev/null 2> /dev/null || exists_rc=$?
            if [[ $exists_rc -eq 124 || $exists_rc -ge 128 ]]; then
                _mole_record_clean_cancellation "$exists_rc"
                return "$exists_rc"
            fi
            if [[ $exists_rc -eq 0 ]]; then
                local size_kb=0
                if [[ -n "$precomputed_size_kb" ]]; then
                    if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                        size_kb="$precomputed_size_kb"
                    fi
                else
                    local size_rc=0
                    size_kb=$(_mole_bounded_sudo "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                        -n du -skP "$path" < /dev/null 2> /dev/null | awk '{print $1}') || size_rc=$?
                    if [[ $size_rc -eq 124 || $size_rc -ge 128 ]]; then
                        _mole_record_clean_cancellation "$size_rc"
                        return "$size_rc"
                    fi
                    [[ $size_rc -eq 0 ]] || size_kb=0
                fi
                if [[ "$size_kb" -gt 0 ]]; then
                    file_size=$(bytes_to_human "$((size_kb * 1024))")
                fi

                local type_probe_rc=0
                _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                    -n test -f "$path" < /dev/null 2> /dev/null || type_probe_rc=$?
                if [[ $type_probe_rc -eq 124 || $type_probe_rc -ge 128 ]]; then
                    _mole_record_clean_cancellation "$type_probe_rc"
                    return "$type_probe_rc"
                fi
                if [[ $type_probe_rc -ne 0 ]]; then
                    type_probe_rc=0
                    _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                        -n test -d "$path" < /dev/null 2> /dev/null || type_probe_rc=$?
                    if [[ $type_probe_rc -eq 124 || $type_probe_rc -ge 128 ]]; then
                        _mole_record_clean_cancellation "$type_probe_rc"
                        return "$type_probe_rc"
                    fi
                fi
                if [[ $type_probe_rc -eq 0 ]]; then
                    local mod_time=0
                    local stat_rc=0
                    mod_time=$(_mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                        -n stat -f%m "$path" < /dev/null 2> /dev/null) || stat_rc=$?
                    if [[ $stat_rc -eq 124 || $stat_rc -ge 128 ]]; then
                        _mole_record_clean_cancellation "$stat_rc"
                        return "$stat_rc"
                    fi
                    [[ $stat_rc -eq 0 ]] || mod_time=0
                    local now
                    now=$(date +%s 2> /dev/null || echo "0")
                    if [[ "$mod_time" -gt 0 && "$now" -gt 0 ]]; then
                        local age_seconds=$((now - mod_time))
                        file_age=$(format_duration_human "$age_seconds")
                    fi
                fi
            fi

            log_info "[DRY-RUN] Would sudo remove: $file_type $path"
            [[ -n "$file_size" ]] && log_info "  Size: $file_size"
            [[ -n "$file_age" ]] && log_info "  Age: $file_age"
        else
            log_info "[DRY-RUN] Would sudo remove: $path"
        fi
        return 0
    fi

    local size_kb=0
    local size_human=""
    if oplog_enabled; then
        if [[ -n "$precomputed_size_kb" ]]; then
            if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                size_kb="$precomputed_size_kb"
            fi
        else
            local exists_probe_rc=0
            local exists_probe_timeout=""
            exists_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$deadline_seconds") || exists_probe_rc=$?
            if [[ $exists_probe_rc -eq 0 ]]; then
                _mole_bounded_sudo "$exists_probe_timeout" \
                    -n test -e "$path" < /dev/null 2> /dev/null || exists_probe_rc=$?
            fi
            if [[ $exists_probe_rc -eq 124 ]]; then
                _mole_record_clean_cancellation 124
                return 124
            fi
            if [[ $exists_probe_rc -ge 128 ]]; then
                _mole_record_clean_cancellation "$exists_probe_rc"
                return "$exists_probe_rc"
            fi
            if [[ $exists_probe_rc -eq 0 ]]; then
                local size_probe_rc=0
                local size_probe_timeout=""
                size_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    "$deadline_seconds") || size_probe_rc=$?
                if [[ $size_probe_rc -eq 0 ]]; then
                    size_kb=$(_mole_bounded_sudo "$size_probe_timeout" \
                        -n du -skP "$path" < /dev/null 2> /dev/null | awk '{print $1}') || size_probe_rc=$?
                fi
                if [[ $size_probe_rc -eq 124 ]]; then
                    MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
                fi
                if [[ $size_probe_rc -ge 128 ]]; then
                    _mole_record_clean_cancellation "$size_probe_rc"
                    return "$size_probe_rc"
                fi
                [[ $size_probe_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            fi
        fi
        if [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]; then
            size_human=$(bytes_to_human "$((size_kb * 1024))" 2> /dev/null || echo "${size_kb}KB")
        fi
    fi

    # Keep the same last-mile policy as safe_remove: privileged cleanup must
    # also fail closed if a compiled-model cache appears during size probing.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped sudo removal after compiled model cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return "$MOLE_ERR_PROTECTED_PATH"
    fi

    local output
    local ret=0
    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing privileged removal after final path identity changed: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi
    local remove_timeout=""
    local section_deadline_spent=0
    remove_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
        "$deadline_seconds") || ret=$?
    if [[ $ret -eq 0 ]]; then
        output=$(_mole_bounded_sudo "$remove_timeout" \
            -n rm -rf "$path" < /dev/null 2>&1) || ret=$? # safe_remove
    else
        # The section's own wall-clock budget ran out, so rm never started.
        section_deadline_spent=1
    fi

    if [[ $ret -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "$size_human"
        return 0
    fi

    if [[ $ret -eq 124 ]]; then
        if [[ $section_deadline_spent -eq 1 ]]; then
            # The section prints its own "time limit reached" line; counting it
            # here too would tell the user to raise the per-item removal budget,
            # which is not the budget that ran out.
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "section time limit reached"
        else
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "removal timed out"
            MOLE_CLEAN_REMOVAL_TIMEOUTS=$((${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0} + 1))
        fi
        return 124
    fi
    if [[ $ret -ge 128 ]]; then
        _mole_record_clean_cancellation "$ret"
        return "$ret"
    fi

    case "$output" in
        *"a password is required"* | *"a terminal is required"* | *"Password:"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "auth required"
            return "$MOLE_ERR_AUTH_FAILED"
            ;;
        *"Operation not permitted"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sip/mdm protected"
            return "$MOLE_ERR_SIP_PROTECTED"
            ;;
        *"Read-only file system"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "readonly filesystem"
            return "$MOLE_ERR_READONLY_FS"
            ;;
        *"Sorry, try again"* | *"incorrect passphrase"* | *"incorrect credentials"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "auth failed"
            return "$MOLE_ERR_AUTH_FAILED"
            ;;
        *)
            log_error "Failed to remove, sudo: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo error"
            return 1
            ;;
    esac
}

# ============================================================================
# Unified deletion helper (Trash + permanent routing with forensic log)
# ============================================================================

# Route a deletion through either macOS Trash or permanent rm, while logging
# every call for forensic review. Designed for destructive paths where undo
# matters (e.g. uninstall). Not used by cache-clean paths.
#
# Usage: mole_delete <path> [needs_sudo=false] [expected_dev_inode_mtime]
#
# Environment:
#   MOLE_DELETE_MODE      "permanent" (default) or "trash"; other values fail
#   MOLE_DRY_RUN=1        Log intent, do not delete
#   MOLE_TEST_TRASH_DIR   Test-only override; Trash moves go here via `mv`
#                         instead of Finder/trash CLI. Required for bats.
#   MOLE_DELETE_LOG       Override the log file path (default:
#                         ~/Library/Logs/mole/deletions.log)
#
# Returns 0 on success and a nonzero MOLE_ERR_* code on failure. Always appends a tab-separated line to
# the deletions log: <iso_ts>\t<mode>\t<size_kb>\t<status>\t<path>.
# size_kb is "unknown" when du could not measure the path (permission denied,
# disappeared mid-call); never silently coerced to 0KB so post-hoc forensics
# can tell measured-zero from measurement-failure.
mole_delete() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local expected_identity="${3:-}"
    local mode="${MOLE_DELETE_MODE:-permanent}"

    [[ -z "$path" ]] && return 1

    case "$mode" in
        permanent | trash) ;;
        *)
            _mole_delete_log "$mode" "unknown" "invalid-mode" "$path"
            if [[ -z "${_MOLE_INVALID_MODE_WARNED:-}" ]]; then
                _MOLE_INVALID_MODE_WARNED=1
                export _MOLE_INVALID_MODE_WARNED
                printf 'Error: invalid MOLE_DELETE_MODE: %s (expected "permanent" or "trash")\n' "$mode" >&2
            fi
            return 1
            ;;
    esac

    # Nothing to do if path does not exist (but a broken symlink still counts).
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    # Validation is delegated to the underlying safe_* helpers (which call
    # validate_path_for_deletion). Trash routing only applies to paths the
    # user could legitimately restore from, so we short-circuit invalid paths
    # up front to avoid a no-op Trash move followed by a validation failure.
    # The rejection itself is recorded in the forensic log so audit trails
    # can distinguish refused-by-policy from never-attempted.
    if ! validate_path_for_deletion "$path"; then
        _mole_delete_log "$mode" "0" "rejected" "$path"
        return 1
    fi

    if [[ "$needs_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        # Neither sudo rm/mv nor Finder authorization is safe here: both receive
        # a pathname that a non-root invoking user can replace after validation.
        # Finder also fails for some package-installed apps even after its native
        # authorization dialog (#1266). Keep both Trash and permanent modes
        # fail-closed and direct the user to perform the app move themselves.
        _mole_delete_log "$mode" "unknown" "mutable-parent" "$path"
        debug_log "Refusing privileged delete below mutable parent: $path"
        return "$MOLE_ERR_MUTABLE_PARENT"
    fi

    # Capture size before the delete so the log line is still useful when the
    # path is gone afterwards. Use "unknown" (not 0) on failure so the log
    # never lies about a multi-GB delete by recording it as 0KB.
    local size_kb="unknown"
    if [[ -e "$path" ]]; then
        local raw_size=""
        local du_rc=0
        if [[ "$needs_sudo" == "true" ]]; then
            if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
                du_rc=1
            else
                raw_size=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    sudo -n du -skP "$path" 2> /dev/null |
                    awk '{print $1; exit}') || du_rc=$?
            fi
        else
            raw_size=$(get_path_size_kb "$path" 2> /dev/null) || du_rc=$?
        fi
        if [[ "$du_rc" -eq 0 && "$raw_size" =~ ^[0-9]+$ ]]; then
            size_kb="$raw_size"
        fi
        # Ctrl-C and other signals are cancellation, not an unknown-size
        # measurement. Stop before any dry-run registration, Trash move, or
        # permanent removal so the user's interrupt cannot be ignored.
        if [[ $du_rc -eq 124 || $du_rc -ge 128 ]]; then
            local cancel_status="interrupted"
            [[ $du_rc -eq 124 ]] && cancel_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$cancel_status" "$path"
            return "$du_rc"
        fi
    fi

    local expected_parent=""
    local expected_parent_id=""
    local expected_target_id=""
    if [[ -n "$expected_identity" ]]; then
        if ! _mole_snapshot_path_identity "$path"; then
            _mole_delete_log "$mode" "$size_kb" "identity-changed" "$path"
            return 1
        fi
        expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        local current_identity=""
        local identity_rc=0
        current_identity=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$STAT_BSD" -f%d:%i:%m "$path" 2> /dev/null) || identity_rc=$?
        if [[ $identity_rc -eq 124 || $identity_rc -ge 128 ]]; then
            local identity_status="interrupted"
            [[ $identity_rc -eq 124 ]] && identity_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$identity_status" "$path"
            return "$identity_rc"
        fi
        if [[ $identity_rc -ne 0 || "$current_identity" != "$expected_identity" ||
            "$expected_target_id" != "${expected_identity%:*}" ||
            "$expected_target_id" != "${current_identity%:*}" ]]; then
            _mole_delete_log "$mode" "$size_kb" "identity-changed" "$path"
            debug_log "Refusing deletion after selected path identity changed: $path"
            return 1
        fi
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local preview_rc=0
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
            _record_file_ops_dry_run_target "$path" "$size_kb" || preview_rc=$?
        else
            _record_file_ops_dry_run_target "$path" || preview_rc=$?
        fi
        if [[ $preview_rc -eq 124 || $preview_rc -ge 128 ]]; then
            local preview_status="interrupted"
            [[ $preview_rc -eq 124 ]] && preview_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$preview_status" "$path"
            return "$preview_rc"
        fi
        debug_log "[DRY RUN] Would delete ($mode): $path"
        _mole_delete_log "$mode" "$size_kb" "dry-run" "$path"
        return 0
    fi

    if [[ "$needs_sudo" == "true" ]]; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            _mole_delete_log "$mode" "$size_kb" "sudo-blocked-test-mode" "$path"
            return 1
        fi
    fi

    # Trash mode is a recoverable-delete contract. If Trash is unavailable,
    # fail closed instead of silently switching to permanent removal.
    if [[ "$mode" == "trash" ]]; then
        local trash_rc=0
        _mole_move_to_trash "$path" "$needs_sudo" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" || trash_rc=$?
        if [[ $trash_rc -eq 0 ]]; then
            _mole_delete_log "trash" "$size_kb" "ok" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "TRASHED" "$path" "${size_kb}KB"
            return 0
        fi
        if [[ $trash_rc -eq $MOLE_ERR_PRIVACY_DENIED ]]; then
            _mole_delete_log "trash" "$size_kb" "privacy-denied" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "privacy permission denied"
            if [[ -z "${_MOLE_PRIVACY_DENIED_WARNED:-}" ]]; then
                _MOLE_PRIVACY_DENIED_WARNED=1
                export _MOLE_PRIVACY_DENIED_WARNED
                printf 'Error: macOS could not authorize Trash access. Review App Management, App Data, or Full Disk Access for your terminal in System Settings, then retry.\n' >&2
            fi
            debug_log "macOS privacy permission denied while moving to Trash: $path"
            return "$MOLE_ERR_PRIVACY_DENIED"
        fi
        if [[ $trash_rc -eq $MOLE_ERR_MUTABLE_PARENT ]]; then
            _mole_delete_log "trash" "$size_kb" "mutable-parent" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "mutable-parent"
            debug_log "Trash move stopped because a mutable parent was detected: $path"
            return "$MOLE_ERR_MUTABLE_PARENT"
        fi
        if [[ $trash_rc -eq 124 || $trash_rc -ge 128 ]]; then
            local trash_status="interrupted"
            [[ $trash_rc -eq 124 ]] && trash_status="timed-out"
            _mole_delete_log "trash" "$size_kb" "$trash_status" "$path"
            return "$trash_rc"
        fi
        _mole_delete_log "trash" "$size_kb" "trash-failed" "$path"
        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "trash-failed"
        if [[ -z "${_MOLE_TRASH_UNAVAILABLE_WARNED:-}" ]]; then
            _MOLE_TRASH_UNAVAILABLE_WARNED=1
            export _MOLE_TRASH_UNAVAILABLE_WARNED
            printf 'Error: Trash unavailable; refusing permanent delete. Use --permanent to delete immediately.\n' >&2
        fi
        debug_log "Trash move failed, refusing permanent delete: $path"
        return 1
    fi

    # Permanent path. Delegate to the existing safe_* helpers so path
    # validation, sudo handling, and existing log_operation calls remain
    # unchanged for callers that have always gone through rm -rf.
    local rc=0
    if [[ "$needs_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        # Recheck at the permanent-delete sink. The parent may have become
        # mutable while size accounting was running. This check covers both
        # regular paths and symlinks before either helper can downgrade.
        rc=$MOLE_ERR_MUTABLE_PARENT
    elif [[ -L "$path" ]]; then
        safe_remove_symlink "$path" "$needs_sudo" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" || rc=$?
    elif [[ "$needs_sudo" == "true" ]]; then
        safe_sudo_remove "$path" "$size_kb" "" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" || rc=$?
    else
        safe_remove "$path" "true" "$size_kb" "" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" || rc=$?
    fi

    local status_label="ok"
    if [[ $rc -eq $MOLE_ERR_MUTABLE_PARENT ]]; then
        status_label="mutable-parent"
    elif [[ $rc -eq 124 ]]; then
        status_label="timed-out"
    elif [[ $rc -ge 128 ]]; then
        status_label="interrupted"
    elif [[ $rc -ne 0 ]]; then
        status_label="error"
    fi
    _mole_delete_log "$mode" "$size_kb" "$status_label" "$path"
    return "$rc"
}

_mole_valid_invoking_home() {
    local user_home=""
    if declare -f get_invoking_home > /dev/null 2>&1; then
        user_home=$(get_invoking_home)
    else
        user_home="${MOLE_USER_HOME:-${HOME:-}}"
    fi

    if [[ -z "$user_home" || "$user_home" != /* || "$user_home" == "/" || "$user_home" == "/var/root" ]]; then
        debug_log "Refusing direct Trash move: invalid invoking user home: ${user_home:-<empty>}"
        return 1
    fi

    printf '%s\n' "${user_home%/}"
}

_mole_path_is_immediate_child_of() {
    local path="${1%/}"
    local parent="${2%/}"
    [[ "$path" == "$parent/"* ]] || return 1

    local child="${path#"$parent"/}"
    [[ -n "$child" && "$child" != */* ]]
}

_mole_path_is_application_bundle() {
    local path="${1%/}"
    _mole_path_is_immediate_child_of "$path" "/Applications" &&
        [[ "${path##*/}" == *.app ]]
}

# Finder and third-party Trash helpers can fail on app bundles and TCC-managed
# app data even after authentication. Route only these exact one-level targets
# through the direct, recoverable Trash mover.
_mole_path_requires_direct_trash() {
    local path="${1%/}"
    if _mole_path_is_application_bundle "$path"; then
        return 0
    fi

    local user_home
    user_home=$(_mole_valid_invoking_home) || return 1
    _mole_path_is_immediate_child_of "$path" "$user_home/Library/Containers" && return 0
    _mole_path_is_immediate_child_of "$path" "$user_home/Library/Group Containers" && return 0
    _mole_path_is_immediate_child_of "$path" "$user_home/Library/Application Scripts" && return 0
    return 1
}

# Finder's Trash API can move package-installed app bundles that macOS App
# Management blocks from a direct mv. Run it only as the invoking user and only
# for an exact one-level /Applications/*.app target selected above.
_mole_move_app_to_trash_via_finder() {
    local path="$1"
    local expected_parent="${2:-}"
    local expected_parent_id="${3:-}"
    local expected_target_id="${4:-}"
    local finder_rc=0

    _mole_path_is_application_bundle "$path" || return 1
    _mole_bound_path_matches "$path" "$expected_parent" \
        "$expected_parent_id" "$expected_target_id" || return 1

    run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" osascript - "$path" > /dev/null 2>&1 << 'APPLESCRIPT' || finder_rc=$?
on run argv
    set p to POSIX file (item 1 of argv)
    tell application "Finder"
        delete p
    end tell
end run
APPLESCRIPT

    if [[ $finder_rc -eq 124 || $finder_rc -ge 128 ]]; then
        return "$finder_rc"
    elif [[ $finder_rc -ne 0 ]] || [[ -e "$path" || -L "$path" ]]; then
        debug_log "Finder failed to move application to Trash: $path"
        return 1
    fi

    debug_log "Finder moved application to Trash: $path"
    return 0
}

# Move a path to the macOS Trash. Test harnesses set MOLE_TEST_TRASH_DIR to
# redirect the move to a tmpdir, avoiding any Finder/osascript interaction.
_mole_move_to_trash() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local expected_parent="${3:-}"
    local expected_parent_id="${4:-}"
    local expected_target_id="${5:-}"

    if [[ -n "${MOLE_TEST_TRASH_DIR:-}" ]]; then
        mkdir -p "$MOLE_TEST_TRASH_DIR" 2> /dev/null || return 1
        local dest="$MOLE_TEST_TRASH_DIR/$(basename "$path").$$.$(date +%s 2> /dev/null || echo 0)"
        _mole_bound_path_matches "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" || return 1
        mv "$path" "$dest" 2> /dev/null
        return $?
    fi

    # Blocked in test mode so uninstall tests never hit Finder/AppleScript.
    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    if [[ "$needs_sudo" == "true" ]]; then
        _mole_move_path_to_user_trash "$path" "$needs_sudo" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id"
        return $?
    fi

    if _mole_path_requires_direct_trash "$path"; then
        local direct_rc=0
        _mole_move_path_to_user_trash "$path" false \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" || direct_rc=$?
        if [[ $direct_rc -eq $MOLE_ERR_PRIVACY_DENIED ]] &&
            _mole_path_is_application_bundle "$path"; then
            debug_log "Direct Trash move was denied; retrying application through Finder: $path"
            local finder_rc=0
            _mole_move_app_to_trash_via_finder "$path" \
                "$expected_parent" "$expected_parent_id" \
                "$expected_target_id" || finder_rc=$?
            [[ $finder_rc -eq 0 ]] && return 0
            [[ $finder_rc -eq 124 || $finder_rc -ge 128 ]] && return "$finder_rc"
        fi
        return "$direct_rc"
    fi

    # Prefer the `trash` CLI (Homebrew formula) for normal user-owned paths.
    if command -v trash > /dev/null 2>&1; then
        local trash_rc=0
        _mole_bound_path_matches "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" || return 1
        run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            trash "$path" > /dev/null 2>&1 || trash_rc=$?
        [[ $trash_rc -eq 0 ]] && return 0
        [[ $trash_rc -eq 124 || $trash_rc -ge 128 ]] && return "$trash_rc"
    fi

    # AppleScript fallback. Pass the path via argv so special chars (quotes,
    # backslashes) cannot break out of the quoted string.
    _mole_bound_path_matches "$path" "$expected_parent" \
        "$expected_parent_id" "$expected_target_id" || return 1
    run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
        osascript - "$path" > /dev/null 2>&1 << 'APPLESCRIPT'
on run argv
    set p to POSIX file (item 1 of argv)
    tell application "Finder"
        delete p
    end tell
end run
APPLESCRIPT
}

# /Library/Caches is mode 0777 on supported macOS releases, so it cannot anchor a
# privileged path operation. This prepares an exact root-owned parent under
# immutable /Library; mode 0711 lets the invoking user traverse into only the
# randomized staging directory handed to them later.
#
# Takes the root as an argument so the concurrency behaviour is reachable from a
# test without a real /Library write.
_mole_prepare_privileged_trash_stage_root() {
    local stage_root="$1"

    # Refuse an existing symlink before any ownership or mode operation. Only
    # root can mutate /Library, but a stale privileged symlink must not make
    # chown/chmod follow into an unrelated tree. Then mkdir -p rather than
    # test-then-mkdir: two concurrent Mole processes can both see a missing root,
    # and the loser of a plain mkdir would abort a Trash move that was safe.
    # Tolerating EEXIST costs nothing, because the verification below is what
    # actually decides whether this root can anchor the operation.
    if [[ -L "$stage_root" ]]; then
        return 1
    fi
    sudo -n /bin/mkdir -p "$stage_root" 2> /dev/null || return 1
    sudo -n /usr/sbin/chown 0:0 "$stage_root" 2> /dev/null || return 1
    sudo -n /bin/chmod -N "$stage_root" 2> /dev/null || return 1
    sudo -n /bin/chmod 711 "$stage_root" 2> /dev/null || return 1

    local root_uid=""
    local root_mode=""
    root_uid=$($STAT_BSD -f%u "$stage_root" 2> /dev/null || true)
    root_mode=$($STAT_BSD -f%Lp "$stage_root" 2> /dev/null || true)
    if [[ -L "$stage_root" || "$root_uid" != "0" || "$root_mode" != "711" ]]; then
        return 1
    fi
}

_mole_create_privileged_trash_stage() {
    local stage_root="/Library/MoleTrashStaging"
    local stage_dir=""

    _mole_prepare_privileged_trash_stage_root "$stage_root" || return 1

    stage_dir=$(sudo -n /usr/bin/mktemp -d "$stage_root/item.XXXXXX" 2> /dev/null) || return 1
    if [[ "$stage_dir" != "$stage_root"/item.* || ! -d "$stage_dir" || -L "$stage_dir" ]]; then
        return 1
    fi
    if _mole_privileged_path_has_mutable_ancestor "$stage_dir/item"; then
        sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact empty staging directory created by mktemp above
        return 1
    fi
    printf '%s\n' "$stage_dir"
}

# The staging root is deliberately persistent. Removing it when it looked empty
# raced with a concurrent Mole process that had just validated it and was about
# to mktemp inside, turning a safe Trash move into a spurious failure.
#
# `mo remove` deliberately leaves it behind too. It is an empty root-owned
# directory, and removing it would add a privileged step to an uninstall that
# may need no privileges at all: a ~/.local-only install would meet a sudo
# prompt for nothing. Any non-empty state is a payload a failed Trash move
# preserved for the user, which uninstall must not touch either.

_mole_move_path_to_user_trash() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local expected_parent="${3:-}"
    local expected_parent_id="${4:-}"
    local expected_target_id="${5:-}"

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    local user_home
    user_home=$(_mole_valid_invoking_home) || return 1

    if [[ -z "$path" ]] || [[ ! -e "$path" && ! -L "$path" ]]; then
        debug_log "Refusing direct Trash move: path does not exist: ${path:-<empty>}"
        return 1
    fi

    if [[ "$needs_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        debug_log "Refusing direct privileged Trash move below mutable parent: $path"
        return "$MOLE_ERR_MUTABLE_PARENT"
    fi

    local trash_dir="${user_home%/}/.Trash"
    local owner_uid="" owner_gid=""
    if declare -f get_invoking_uid > /dev/null 2>&1; then
        owner_uid=$(get_invoking_uid)
    fi
    if declare -f get_invoking_gid > /dev/null 2>&1; then
        owner_gid=$(get_invoking_gid)
    fi
    if [[ ! "$owner_uid" =~ ^[0-9]+$ || ! "$owner_gid" =~ ^[0-9]+$ ]]; then
        debug_log "Failed to resolve invoking user ownership for Trash"
        return 1
    fi

    # The destination must be the invoking user's Trash, even though sudo is
    # needed to unlink the original protected path.
    if [[ -L "$trash_dir" ]]; then
        debug_log "Refusing direct Trash move: invoking user Trash is a symlink: $trash_dir"
        return 1
    fi
    if [[ ${EUID:-0} -eq 0 ]]; then
        sudo -n -u "#$owner_uid" mkdir -p "$trash_dir" 2> /dev/null || {
            debug_log "Failed to create invoking user Trash: $trash_dir"
            return 1
        }
    elif ! mkdir -p "$trash_dir" 2> /dev/null; then
        debug_log "Failed to create invoking user Trash: $trash_dir"
        return 1
    fi
    if [[ ! -d "$trash_dir" || -L "$trash_dir" ]]; then
        debug_log "Refusing direct Trash move: invoking user Trash is not a normal directory: $trash_dir"
        return 1
    fi

    local trash_owner_uid=""
    trash_owner_uid=$($STAT_BSD -f%u "$trash_dir" 2> /dev/null || true)
    if [[ "$trash_owner_uid" != "$owner_uid" ]]; then
        debug_log "Refusing direct Trash move: invoking user does not own Trash: $trash_dir"
        return 1
    fi
    if [[ ${EUID:-0} -eq 0 ]]; then
        if ! sudo -n -u "#$owner_uid" chmod 700 "$trash_dir" 2> /dev/null; then
            debug_log "Failed to set invoking user Trash permissions: $trash_dir"
            return 1
        fi
    elif ! chmod 700 "$trash_dir" 2> /dev/null; then
        debug_log "Failed to set invoking user Trash permissions: $trash_dir"
        return 1
    fi

    # Avoid Finder-style ':' path weirdness and keep generated names filesystem-safe.
    local base
    base=$(basename "$path")
    base="${base//:/__}"
    base="${base//\//__}"
    [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || base="mole-trash-item"

    local dest="$trash_dir/$base"
    local ts suffix
    ts=$(date +%s 2> /dev/null || echo 0)
    suffix=0

    while [[ -e "$dest" || -L "$dest" ]]; do
        suffix=$((suffix + 1))
        if [[ $suffix -gt 100 ]]; then
            debug_log "Failed to choose unique Trash destination for: $path"
            return 1
        fi
        dest="$trash_dir/$base.$ts.$$.$suffix"
    done

    if [[ -n "$expected_parent" ]]; then
        if ! _mole_path_matches_identity \
            "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
            debug_log "Refusing Trash move after selected path identity changed: $path"
            return 1
        fi
    elif [[ -n "${_MOLE_TRASH_MOVE_EXPECTED_PATH:-}" && "$_MOLE_TRASH_MOVE_EXPECTED_PATH" == "$path" ]]; then
        if ! _mole_path_matches_identity \
            "$path" \
            "$_MOLE_TRASH_MOVE_EXPECTED_PARENT" \
            "$_MOLE_TRASH_MOVE_EXPECTED_PARENT_ID" \
            "$_MOLE_TRASH_MOVE_EXPECTED_TARGET_ID"; then
            debug_log "Refusing Trash move after source path identity changed: $path"
            return 1
        fi
    fi

    local move_output=""
    local move_rc=0
    if [[ "$needs_sudo" == "true" ]]; then
        # Never point a root mv directly into ~/.Trash: that directory is
        # intentionally controlled by the invoking user and can be replaced
        # after validation. First cross the privileged boundary into a
        # root-owned staging directory, then perform the final Trash move with
        # only the invoking user's authority.
        local stage_dir=""
        local stage_path=""
        stage_dir=$(_mole_create_privileged_trash_stage) || {
            debug_log "Failed to create immutable Trash staging directory"
            return 1
        }
        stage_path="$stage_dir/item"

        # The first move must be a same-filesystem rename. A cross-volume mv
        # degrades into copy-then-delete and can leave the only payload split
        # between source and staging if it fails midway.
        local source_device=""
        local stage_device=""
        local device_rc=0
        source_device=$($STAT_BSD -f%d "$path" 2> /dev/null) || device_rc=$?
        [[ $device_rc -eq 124 || $device_rc -ge 128 ]] && return "$device_rc"
        if [[ $device_rc -eq 0 ]]; then
            stage_device=$($STAT_BSD -f%d "$stage_dir" 2> /dev/null) || device_rc=$?
        fi
        [[ $device_rc -eq 124 || $device_rc -ge 128 ]] && return "$device_rc"
        if [[ ! "$source_device" =~ ^[0-9]+$ || "$source_device" != "$stage_device" ]]; then
            sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact empty staging directory created by mktemp above
            debug_log "Refusing cross-volume privileged Trash staging: $path"
            return 1
        fi

        local stage_move_rc=0
        _mole_bound_path_matches "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" || return 1
        sudo -n /bin/mv "$path" "$stage_path" 2> /dev/null || stage_move_rc=$?
        if [[ $stage_move_rc -ne 0 ]]; then
            if [[ $stage_move_rc -eq 124 || $stage_move_rc -ge 128 ]]; then
                if [[ -e "$stage_path" || -L "$stage_path" ]]; then
                    log_error "Trash move interrupted; item preserved for recovery at: $stage_path"
                fi
                return "$stage_move_rc"
            fi
            sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact root-owned directory created by mktemp above
            debug_log "Failed to move path into immutable Trash staging: $path"
            return 1
        fi
        # Keep the stage root-owned while ownership is repaired. `-h` keeps chown
        # off symlink targets, and `-x` keeps it from descending into a nested
        # mount: the same-device gate above only compares the payload root with
        # the stage, so a disk image or FUSE volume mounted *inside* the payload
        # is still reachable, and chown -R would rewrite ownership on that
        # filesystem and can block on it. Once either payload ownership or stage
        # ownership changes, preserve on any later failure rather than
        # reintroducing user-owned content into the privileged source path.
        local handoff_rc=0
        sudo -n /bin/chmod 700 "$stage_dir" 2> /dev/null || handoff_rc=$?
        if [[ $handoff_rc -eq 0 ]]; then
            sudo -n /usr/sbin/chown -Rhx "$owner_uid:$owner_gid" \
                "$stage_path" 2> /dev/null || handoff_rc=$?
        fi
        if [[ $handoff_rc -eq 0 ]]; then
            sudo -n /usr/sbin/chown "$owner_uid:$owner_gid" \
                "$stage_dir" 2> /dev/null || handoff_rc=$?
        fi
        if [[ $handoff_rc -ne 0 ]]; then
            if [[ $handoff_rc -eq 124 || $handoff_rc -ge 128 ]]; then
                log_error "Trash move interrupted; item preserved for recovery at: $stage_path"
                return "$handoff_rc"
            fi
            log_error "Trash move failed; item preserved for recovery at: $stage_path"
            debug_log "Failed to hand Trash staging directory to invoking user"
            return 1
        fi

        if [[ ${EUID:-0} -eq 0 ]]; then
            move_output=$(sudo -n -u "#$owner_uid" /bin/mv -n "$stage_path" "$dest" 2>&1) || move_rc=$?
        else
            move_output=$(/bin/mv -n "$stage_path" "$dest" 2>&1) || move_rc=$?
        fi

        if [[ $move_rc -ne 0 || -e "$stage_path" || -L "$stage_path" ]]; then
            if [[ $move_rc -eq 124 || $move_rc -ge 128 ]]; then
                if [[ -e "$stage_path" || -L "$stage_path" ]]; then
                    log_error "Trash move interrupted; item preserved for recovery at: $stage_path"
                elif [[ -e "$dest" || -L "$dest" ]]; then
                    debug_log "Trash move completed before interruption was observed: $dest"
                fi
                return "$move_rc"
            fi
            move_rc=1
            # stage_dir is user-controlled after the ownership handoff above.
            # Never let root resolve stage_path again: it may have been replaced
            # between the failed user move and this branch. Preserve the item
            # in staging and report the exact recovery location instead.
            log_error "Trash move failed; item preserved for recovery at: $stage_path"
        else
            # The invoking user owns stage_dir but has no write bit on the
            # root-owned 0711 parent, so only a privileged rmdir can unlink it.
            sudo -n /bin/rmdir "$stage_dir" 2> /dev/null || true
        fi
    else
        _mole_bound_path_matches "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" || return 1
        move_output=$(mv -n "$path" "$dest" 2>&1) || move_rc=$?
    fi
    if [[ $move_rc -ne 0 ]]; then
        [[ $move_rc -eq 124 || $move_rc -ge 128 ]] && return "$move_rc"
        debug_log "Failed to move path directly to invoking user Trash: $path -> $dest: $move_output"
        case "$move_output" in
            *"Operation not permitted"* | *"operation not permitted"* | \
                *"Permission denied"* | *"permission denied"*)
                return "$MOLE_ERR_PRIVACY_DENIED"
                ;;
        esac
        return 1
    fi
    if [[ -e "$path" || -L "$path" ]] || [[ ! -e "$dest" && ! -L "$dest" ]]; then
        debug_log "Failed to move path directly without overwriting destination: $path -> $dest"
        return 1
    fi

    debug_log "Moved path directly to invoking user Trash: $path -> $dest"
    return 0
}

# Batched Trash move for non-sudo, non-symlink paths. Removes the per-file
# Finder/AppleScript fan-out that made uninstalls feel frozen. The caller binds
# each item to its original physical parent and inode through the snapshot
# arrays below; this helper rechecks that identity before every direct move.
_MOLE_TRASH_BATCH_SNAPSHOT_PATHS=()
_MOLE_TRASH_BATCH_SNAPSHOT_PARENTS=()
_MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS=()
_MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS=()
_MOLE_TRASH_BATCH_MOVED_PATHS=()
_MOLE_TRASH_MOVE_EXPECTED_PATH=""
_MOLE_TRASH_MOVE_EXPECTED_PARENT=""
_MOLE_TRASH_MOVE_EXPECTED_PARENT_ID=""
_MOLE_TRASH_MOVE_EXPECTED_TARGET_ID=""

_MOLE_PATH_SNAPSHOT_PARENT=""
_MOLE_PATH_SNAPSHOT_PARENT_ID=""
_MOLE_PATH_SNAPSHOT_TARGET_ID=""

_mole_snapshot_path_identity() {
    local path="$1"
    _MOLE_PATH_SNAPSHOT_PARENT=""
    _MOLE_PATH_SNAPSHOT_PARENT_ID=""
    _MOLE_PATH_SNAPSHOT_TARGET_ID=""

    [[ -e "$path" || -L "$path" ]] || return 1
    local lexical_parent="${path%/*}"
    [[ -n "$lexical_parent" && "$lexical_parent" != "$path" ]] || lexical_parent="/"

    local physical_parent=""
    physical_parent=$(cd -P "$lexical_parent" 2> /dev/null && pwd -P) || return 1
    local parent_id=""
    local target_id=""
    parent_id=$($STAT_BSD -f '%d:%i' "$physical_parent" 2> /dev/null || true)
    target_id=$($STAT_BSD -f '%d:%i' "$path" 2> /dev/null || true)
    [[ "$parent_id" =~ ^[0-9]+:[0-9]+$ && "$target_id" =~ ^[0-9]+:[0-9]+$ ]] || return 1

    _MOLE_PATH_SNAPSHOT_PARENT="$physical_parent"
    _MOLE_PATH_SNAPSHOT_PARENT_ID="$parent_id"
    _MOLE_PATH_SNAPSHOT_TARGET_ID="$target_id"
}

_mole_path_matches_identity() {
    local path="$1"
    local expected_parent="$2"
    local expected_parent_id="$3"
    local expected_target_id="$4"

    _mole_snapshot_path_identity "$path" || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$expected_parent" ]] || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT_ID" == "$expected_parent_id" ]] || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_TARGET_ID" == "$expected_target_id" ]]
}

_mole_bound_path_matches() {
    local path="$1"
    local expected_parent="${2:-}"
    local expected_parent_id="${3:-}"
    local expected_target_id="${4:-}"
    [[ -z "$expected_parent" ]] && return 0
    _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"
}

_mole_move_to_trash_batch() {
    local -a paths=("$@")
    [[ ${#paths[@]} -eq 0 ]] && return 0
    _MOLE_TRASH_BATCH_MOVED_PATHS=()

    local use_bound_snapshots=false
    if [[ ${#_MOLE_TRASH_BATCH_SNAPSHOT_PATHS[@]} -eq ${#paths[@]} &&
        ${#_MOLE_TRASH_BATCH_SNAPSHOT_PARENTS[@]} -eq ${#paths[@]} &&
        ${#_MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS[@]} -eq ${#paths[@]} &&
        ${#_MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS[@]} -eq ${#paths[@]} ]]; then
        use_bound_snapshots=true
    fi

    local -a expected_parents=()
    local -a expected_parent_ids=()
    local -a expected_target_ids=()
    local index p
    for ((index = 0; index < ${#paths[@]}; index++)); do
        p="${paths[$index]}"
        if [[ "$use_bound_snapshots" == "true" ]]; then
            [[ "${_MOLE_TRASH_BATCH_SNAPSHOT_PATHS[$index]}" == "$p" ]] || return 1
            expected_parents+=("${_MOLE_TRASH_BATCH_SNAPSHOT_PARENTS[$index]}")
            expected_parent_ids+=("${_MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS[$index]}")
            expected_target_ids+=("${_MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS[$index]}")
        else
            _mole_snapshot_path_identity "$p" || return 1
            expected_parents+=("$_MOLE_PATH_SNAPSHOT_PARENT")
            expected_parent_ids+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
            expected_target_ids+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
        fi
    done

    if [[ -n "${MOLE_TEST_TRASH_DIR:-}" ]]; then
        mkdir -p "$MOLE_TEST_TRASH_DIR" 2> /dev/null || return 1
        local ts
        ts=$(date +%s 2> /dev/null || echo 0)
        local dest
        for ((index = 0; index < ${#paths[@]}; index++)); do
            p="${paths[$index]}"
            _mole_path_matches_identity \
                "$p" \
                "${expected_parents[$index]}" \
                "${expected_parent_ids[$index]}" \
                "${expected_target_ids[$index]}" || return 1
            dest="$MOLE_TEST_TRASH_DIR/$(basename "$p").$$.${ts}.$RANDOM"
            /bin/mv "$p" "$dest" 2> /dev/null || return 1
            _MOLE_TRASH_BATCH_MOVED_PATHS+=("$p")
        done
        return 0
    fi

    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    # Avoid handing a stale lexical batch to a third-party Trash CLI or Finder.
    # Direct per-item renames keep the helper in one shell process and let us
    # recheck the bound parent/inode immediately before every move.
    local failed=0
    for ((index = 0; index < ${#paths[@]}; index++)); do
        p="${paths[$index]}"
        if ! _mole_path_matches_identity \
            "$p" \
            "${expected_parents[$index]}" \
            "${expected_parent_ids[$index]}" \
            "${expected_target_ids[$index]}"; then
            failed=1
            continue
        fi
        _MOLE_TRASH_MOVE_EXPECTED_PATH="$p"
        _MOLE_TRASH_MOVE_EXPECTED_PARENT="${expected_parents[$index]}"
        _MOLE_TRASH_MOVE_EXPECTED_PARENT_ID="${expected_parent_ids[$index]}"
        _MOLE_TRASH_MOVE_EXPECTED_TARGET_ID="${expected_target_ids[$index]}"
        if _mole_move_path_to_user_trash "$p" false; then
            _MOLE_TRASH_BATCH_MOVED_PATHS+=("$p")
        else
            failed=1
        fi
        _MOLE_TRASH_MOVE_EXPECTED_PATH=""
        _MOLE_TRASH_MOVE_EXPECTED_PARENT=""
        _MOLE_TRASH_MOVE_EXPECTED_PARENT_ID=""
        _MOLE_TRASH_MOVE_EXPECTED_TARGET_ID=""
    done
    [[ $failed -eq 0 ]]
}

_mole_delete_log() {
    local mode="$1"
    local size_kb="$2"
    local status="$3"
    local target="$4"

    local log_file="${MOLE_DELETE_LOG:-$HOME/Library/Logs/mole/deletions.log}"
    local log_dir
    log_dir=$(dirname "$log_file")

    # Surface log-write failures once per session. The deletions log is the
    # only audit trail for Trash-routed removals; silently no-oping when the
    # log dir is unwritable (root-owned from prior sudo, ENOSPC, read-only
    # volume) defeats the design.
    if ! mkdir -p "$log_dir" 2> /dev/null; then
        _mole_warn_log_broken "create directory: $log_dir"
        return 0
    fi

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2> /dev/null || echo "unknown")

    if ! printf '%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$mode" "$size_kb" "$status" "$target" \
        >> "$log_file" 2> /dev/null; then
        _mole_warn_log_broken "write to: $log_file"
    fi
}

_mole_warn_log_broken() {
    [[ -n "${_MOLE_DELETE_LOG_WARNED:-}" ]] && return 0
    _MOLE_DELETE_LOG_WARNED=1
    export _MOLE_DELETE_LOG_WARNED
    printf 'Warning: deletions audit log unavailable (%s). Forensic trail incomplete this session.\n' "$1" >&2
}

# ============================================================================
# Safe Find and Delete Operations
# ============================================================================

# Safe file discovery and deletion with depth and age limits
safe_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi

    debug_log "Finding in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "5" "-name" "$pattern" "-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    local scan_file=""
    if ! scan_file=$(create_temp_file 2> /dev/null); then
        return 1
    fi
    local scan_rc=0
    run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" find \
        "$base_dir" "${find_args[@]}" -print0 < /dev/null > "$scan_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        debug_log "Cleanup scan failed for $base_dir (status $scan_rc)"
        return "$scan_rc"
    fi

    # Iterate only a completed result set so a timeout cannot authorize
    # deletion of the partial prefix.
    # Per-caller whitelist gates were missed in past releases (see #710, #724,
    # #738, #744, #757); enforcing here makes the protection structural so
    # new clean_* functions get whitelist enforcement for free.
    local delete_rc=0
    while IFS= read -r -d '' match; do
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$match"; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$match"; then
            continue
        fi
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
            local match_size_kb=0
            local match_size_rc=0
            match_size_kb=$(get_path_size_kb "$match" 2> /dev/null) || match_size_rc=$?
            if [[ $match_size_rc -eq 124 || $match_size_rc -ge 128 ]]; then
                delete_rc=$match_size_rc
                break
            fi
            [[ $match_size_rc -eq 0 ]] || match_size_kb=0
            [[ "$match_size_kb" =~ ^[0-9]+$ ]] || match_size_kb=0
            record_dry_run_cleanup_target "$match" "$match_size_kb" 1 true || continue
        fi
        local remove_rc=0
        safe_remove "$match" true || remove_rc=$?
        if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
            delete_rc=$remove_rc
            break
        fi
        if [[ $remove_rc -ne 0 && $delete_rc -eq 0 ]]; then
            delete_rc=$remove_rc
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    return "$delete_rc"
}

# Run privileged find with a wall-clock budget and closed stdin.
_mole_bounded_sudo_find() {
    local duration="${1:-${MOLE_TIMEOUT_DISK_VERIFY_SEC:-30}}"
    shift || true
    [[ $# -gt 0 ]] || return 2
    _mole_bounded_sudo "$duration" -n find "$@" < /dev/null
}

# Store a privileged scan only after the producer completed successfully. A
# timeout or any other failure truncates the destination so callers cannot act
# on a partial prefix.
_mole_materialize_bounded_sudo_find() {
    local output_file="$1"
    local duration="$2"
    shift 2
    [[ $# -gt 0 ]] || return 2

    : > "$output_file" || return 1
    local scan_rc=0
    _mole_bounded_sudo_find "$duration" "$@" > "$output_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return 0
}

# Keep privileged batch state bounded in Bash. This is a function rather than a
# public setting so tests can exercise the limit without exposing another user
# knob or constructing thousands of command-substitution probes.
_mole_privileged_batch_max_items() {
    printf '4096\n'
}

# Safe sudo discovery and deletion
safe_sudo_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"
    local max_depth="${5:-5}"
    local deadline_seconds="${6:-}"
    local -a name_patterns=("$pattern")
    if [[ $# -gt 6 ]]; then
        name_patterns+=("${@:7}")
    fi

    # Callers use this count to distinguish a completed empty scan from actual
    # cleanup. It is reset for every invocation and updated only for confirmed
    # removals or accepted dry-run previews.
    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0

    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi
    if [[ ! "$age_days" =~ ^[0-9]+$ ]]; then
        log_error "Invalid age: $age_days, must be a non-negative integer"
        return 1
    fi
    if [[ ! "$max_depth" =~ ^[1-5]$ ]]; then
        log_error "Invalid max depth: $max_depth, must be between 1 and 5"
        return 1
    fi
    if [[ -n "$deadline_seconds" && ! "$deadline_seconds" =~ ^[0-9]+$ ]]; then
        log_error "Invalid cleanup deadline: $deadline_seconds"
        return 1
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        debug_log "Skipping sudo find/delete in test mode: $base_dir"
        return 0
    fi

    # An already-expired overall budget authorizes no privileged probe at all.
    # Re-clamp every later probe because any preceding command can consume the
    # final second of the caller's section budget.
    _mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$deadline_seconds" > /dev/null || return $?

    # Keep the entire sudo-probing body independent of the caller's errexit
    # state. macOS 14's /bin/bash build fires the caller's errexit when a
    # sudo shell-function mock returns nonzero inside an if condition (the
    # same bash 3.2.57 on macOS 15+ does not), so the guard must sit above
    # the first sudo probe, not just around the scan/batch loop. The
    # predicates below intentionally return 1 for ordinary "not protected /
    # not whitelisted / no oplog" cases; callers still get explicit nonzero
    # returns from the validation gates, restored to their errexit state.
    local restore_errexit=0
    case $- in
        *e*)
            restore_errexit=1
            set +e
            ;;
    esac

    # Confirm noninteractive authorization before interpreting a failed path
    # predicate as "not present". Otherwise an expired credential looks like an
    # empty successful scan and callers can print a false cleanup result.
    local sudo_rc=0
    _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n true < /dev/null > /dev/null 2>&1 || sudo_rc=$?
    if [[ $sudo_rc -ne 0 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        [[ $sudo_rc -ge 128 ]] && return "$sudo_rc"
        [[ $sudo_rc -eq 124 ]] && return 124
        return "$MOLE_ERR_AUTH_FAILED"
    fi

    # Validate base directory (use sudo for permission-restricted dirs).
    local base_rc=0
    _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n test -d "$base_dir" < /dev/null 2> /dev/null || base_rc=$?
    if [[ $base_rc -ne 0 ]]; then
        if [[ $base_rc -ge 128 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            return "$base_rc"
        fi
        if [[ $base_rc -eq 124 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            return 124
        fi
        # `sudo test` uses status 1 both for a false predicate and for some
        # authorization failures. Recheck credentials before calling this a
        # missing directory; a credential may expire after the initial probe.
        local base_auth_rc=0
        _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            -n true < /dev/null > /dev/null 2>&1 || base_auth_rc=$?
        if [[ $base_auth_rc -ne 0 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            [[ $base_auth_rc -ge 128 ]] && return "$base_auth_rc"
            [[ $base_auth_rc -eq 124 ]] && return 124
            return "$MOLE_ERR_AUTH_FAILED"
        fi
        debug_log "Directory does not exist, skipping: $base_dir"
        [[ $restore_errexit -eq 1 ]] && set -e
        return 0
    fi

    local link_rc=0
    _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n test -L "$base_dir" < /dev/null 2> /dev/null || link_rc=$?
    if [[ $link_rc -eq 0 ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        [[ $restore_errexit -eq 1 ]] && set -e
        return 1
    fi
    if [[ $link_rc -eq 124 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        return 124
    fi
    if [[ $link_rc -ge 128 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        return "$link_rc"
    fi
    if [[ $link_rc -eq 1 ]]; then
        local link_auth_rc=0
        _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            -n true < /dev/null > /dev/null 2>&1 || link_auth_rc=$?
        if [[ $link_auth_rc -ne 0 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            [[ $link_auth_rc -ge 128 ]] && return "$link_auth_rc"
            [[ $link_auth_rc -eq 124 ]] && return 124
            return "$MOLE_ERR_AUTH_FAILED"
        fi
    fi
    if [[ $link_rc -ne 1 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        return "$link_rc"
    fi

    debug_log "Finding, sudo, in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "$max_depth")
    local match_all_names=false
    local name_pattern=""
    for name_pattern in "${name_patterns[@]}"; do
        if [[ "$name_pattern" == "*" ]]; then
            match_all_names=true
            break
        fi
    done
    if [[ "$match_all_names" != "true" ]]; then
        if [[ ${#name_patterns[@]} -eq 1 ]]; then
            find_args+=("-name" "${name_patterns[0]}")
        else
            find_args+=("(")
            local pattern_index=0
            for ((pattern_index = 0; pattern_index < ${#name_patterns[@]}; pattern_index++)); do
                [[ $pattern_index -gt 0 ]] && find_args+=("-o")
                find_args+=("-name" "${name_patterns[$pattern_index]}")
            done
            find_args+=(")")
        fi
    fi
    find_args+=("-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Materialize the completed scan before deleting anything. Process
    # substitution cannot expose the producer's exit status, so it previously
    # turned timeout 124 into an empty/partial successful scan and could delete
    # the partial prefix. A failed scan now authorizes no deletion.
    local scan_file=""
    if ! scan_file=$(create_temp_file 2> /dev/null); then
        [[ $restore_errexit -eq 1 ]] && set -e
        return 1
    fi
    local scan_rc=0
    local scan_timeout=""
    scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
        "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        _mole_materialize_bounded_sudo_find "$scan_file" "$scan_timeout" \
            "$base_dir" "${find_args[@]}" -print0 || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        debug_log "Privileged cleanup scan failed for $base_dir (status $scan_rc)"
        [[ $restore_errexit -eq 1 ]] && set -e
        return "$scan_rc"
    fi

    # Iterate results to respect both system protection and user whitelist.
    # See safe_find_delete for rationale (#757).
    #
    # Regular files are removed in one privileged xargs batch instead of one
    # safe_sudo_remove per match: the single-file path costs three sudo forks
    # per file (test -e, du, rm), which turns a sweep over a stale .logarchive
    # bundle (1000+ tracev3 files) into minutes. Every path still passes the
    # same per-file gates before entering the batch; only the rm is batched.
    # Directories and dry-run keep the single-file path so rm -rf handling
    # and preview output stay unchanged.
    local -a batch_files=()
    local -a batch_identities=()
    local max_batch_items=""
    max_batch_items=$(_mole_privileged_batch_max_items)
    [[ "$max_batch_items" =~ ^[1-9][0-9]*$ ]] || max_batch_items=4096
    local removed_count=0
    local delete_rc=0
    local deadline_reached=false
    local batch_aborted=false
    while IFS= read -r -d '' match; do
        if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
            deadline_reached=true
            delete_rc=124
            break
        fi
        if should_protect_path "$match"; then
            continue
        fi
        # Fast-path the active family before the general validator below. The
        # validator remains authoritative and also normalizes dot aliases so
        # preview and real cleanup cannot diverge.
        if _mole_is_active_powerlog_database_path "$match"; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$match"; then
            continue
        fi
        # Run the same final path policy before preview accounting and real
        # removal. This keeps aliases such as /./ and case variants out of
        # both surfaces instead of relying on a raw-string precheck.
        if ! validate_path_for_deletion "$match"; then
            continue
        fi
        if _mole_privileged_path_has_mutable_ancestor "$match"; then
            # A privileged path-based delete cannot safely cross a directory
            # the invoking user can rename or replace. Delete only with the
            # caller's own permissions; root invocations skip the path because
            # they have no unprivileged identity to fall back to.
            if [[ ${EUID:-0} -ne 0 ]]; then
                local mutable_rc=0
                safe_remove "$match" true "" "$deadline_seconds" || mutable_rc=$?
                if [[ $mutable_rc -eq 0 ]]; then
                    removed_count=$((removed_count + 1))
                elif [[ $mutable_rc -eq 124 || $mutable_rc -ge 128 ]]; then
                    delete_rc=$mutable_rc
                    break
                elif [[ $delete_rc -eq 0 ]]; then
                    delete_rc=$mutable_rc
                fi
            else
                debug_log "Skipping sudo delete below mutable parent: $match"
                [[ $delete_rc -eq 0 ]] && delete_rc=1
            fi
            continue
        fi
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
            local match_size_kb=0
            local match_size_known=false
            local raw_match_size=""
            local size_timeout=""
            local dry_size_rc=0
            size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                "$deadline_seconds") || dry_size_rc=$?
            if [[ $dry_size_rc -eq 0 ]]; then
                raw_match_size=$(_mole_bounded_sudo "$size_timeout" \
                    -n du -skP "$match" < /dev/null 2> /dev/null | awk '{print $1; exit}') || dry_size_rc=$?
            fi
            if [[ $dry_size_rc -eq 124 || $dry_size_rc -ge 128 ]]; then
                delete_rc=$dry_size_rc
                break
            elif [[ $dry_size_rc -eq 0 ]]; then
                if [[ "$raw_match_size" =~ ^[0-9]+$ ]]; then
                    match_size_kb="$raw_match_size"
                    match_size_known=true
                fi
            fi
            record_dry_run_cleanup_target "$match" "$match_size_kb" 1 "$match_size_known" || continue
        fi
        # -type f never emits symlinks; a path that is one now was swapped
        # after find saw it, and the single-file path refuses those.
        if [[ "$type_filter" == "f" && "${MOLE_DRY_RUN:-0}" != "1" && ! -L "$match" ]]; then
            local identity_timeout=""
            local match_identity=""
            local identity_rc=0
            identity_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$deadline_seconds") || identity_rc=$?
            if [[ $identity_rc -eq 0 ]]; then
                match_identity=$(_mole_bounded_sudo "$identity_timeout" \
                    -n "$STAT_BSD" -f%d:%i:%m "$match" < /dev/null 2> /dev/null) || identity_rc=$?
            fi
            if [[ $identity_rc -eq 124 || $identity_rc -ge 128 ]]; then
                delete_rc=$identity_rc
                break
            fi
            if [[ $identity_rc -eq 0 && "$match_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
                if [[ ${#batch_files[@]} -ge $max_batch_items ]]; then
                    debug_log "Privileged cleanup candidate limit reached for $base_dir"
                    delete_rc=1
                    batch_aborted=true
                    break
                fi
                batch_files+=("$match")
                batch_identities+=("$match_identity")
            elif [[ $delete_rc -eq 0 ]]; then
                delete_rc=${identity_rc:-1}
                [[ $delete_rc -ne 0 ]] || delete_rc=1
            fi
            continue
        fi
        local single_rc=0
        safe_sudo_remove "$match" "" "$deadline_seconds" || single_rc=$?
        if [[ $single_rc -eq 0 ]]; then
            removed_count=$((removed_count + 1))
        elif [[ $single_rc -eq 124 || $single_rc -ge 128 ]]; then
            delete_rc=$single_rc
            break
        elif [[ $delete_rc -eq 0 ]]; then
            delete_rc=$single_rc
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
        deadline_reached=true
        if [[ $delete_rc -lt 128 ]]; then
            delete_rc=124
        fi
    fi

    if [[ ${#batch_files[@]} -gt 0 && "$deadline_reached" != "true" && "$batch_aborted" != "true" && $delete_rc -ne 124 && $delete_rc -lt 128 ]]; then
        local batch_rc=0
        local batch_result_file=""
        local batch_timeout=""
        if ! batch_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            "$deadline_seconds"); then
            batch_rc=124
        elif ! batch_result_file=$(create_temp_file 2> /dev/null); then
            batch_rc=1
        else
            # The privileged worker acknowledges each completed unlink with a
            # NUL-delimited path. A later failure or timeout therefore cannot
            # erase the forensic record for an already completed prefix.
            local -a batch_worker_records=()
            local batch_index=0
            for ((batch_index = 0; batch_index < ${#batch_files[@]}; batch_index++)); do
                batch_worker_records+=("${batch_identities[$batch_index]}:${batch_files[$batch_index]}")
            done
            # shellcheck disable=SC2016 # $path expands inside privileged /bin/sh.
            printf '%s\0' "${batch_worker_records[@]}" |
                _mole_bounded_sudo "$batch_timeout" \
                    -n xargs -0 /bin/sh -c '
                        stat_tool=$1
                        age_days=$2
                        shift 2
                        for record do
                            dev=${record%%:*}
                            rest=${record#*:}
                            ino=${rest%%:*}
                            rest=${rest#*:}
                            mtime=${rest%%:*}
                            path=${rest#*:}
                            expected=$dev:$ino:$mtime
                            if [ "$age_days" -gt 0 ]; then
                                actual=$(/usr/bin/find "$path" -maxdepth 0 -type f -mtime "+$age_days" \
                                    -exec "$stat_tool" -f%d:%i:%m {} \; 2>/dev/null) || continue
                            else
                                actual=$($stat_tool -f%d:%i:%m "$path" 2>/dev/null) || continue
                            fi
                            [ "$actual" = "$expected" ] || continue
                            /bin/rm -f -- "$path" || exit 1
                            printf "%s\0" "$path"
                        done
                    ' sh "$STAT_BSD" "$age_days" > "$batch_result_file" 2> /dev/null || batch_rc=$?

            local batch_ts=""
            if oplog_enabled; then
                batch_ts=$(get_timestamp)
            fi
            local batch_ack_count=0
            local -a removed_lines=()
            local batch_file=""
            while IFS= read -r -d '' batch_file; do
                batch_ack_count=$((batch_ack_count + 1))
                if [[ -n "$batch_ts" ]]; then
                    removed_lines+=("[$batch_ts] [${MOLE_CURRENT_COMMAND:-clean}] REMOVED $batch_file (batch)")
                fi
            done < "$batch_result_file"
            rm -f -- "$batch_result_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

            removed_count=$((removed_count + batch_ack_count))
            if [[ ${#removed_lines[@]} -gt 0 ]]; then
                append_log_lines "$OPERATIONS_LOG_FILE" "${removed_lines[@]}"
            fi
            if [[ $batch_rc -eq 0 && $batch_ack_count -ne ${#batch_files[@]} ]]; then
                batch_rc=1
            fi
        fi

        if [[ $batch_rc -ne 0 && $delete_rc -eq 0 ]]; then
            delete_rc=$batch_rc
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$base_dir" \
                "batch removal incomplete (status $batch_rc)"
        fi
    fi

    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=$removed_count

    if [[ $restore_errexit -eq 1 ]]; then
        set -e
    fi

    return "$delete_rc"
}

# ============================================================================
# Size Calculation
# ============================================================================

# Get path size in KB (returns 0 if not found)
#
# For regular files and symlinks, prefer allocated blocks from 'stat' over
# 'du': it avoids the fork+pipe cost of 'du | awk' on every call, which adds
# up in tight loops (e.g. external-volume ._* sweeps, Application Support log
# scans). macOS st_blocks and 'du -skP' use the same 512-byte allocation basis
# without following symlinks. Directories still go through 'du' because 'stat'
# only reports a single directory entry, not recursive content size. .app
# bundles use Spotlight's physical size when available so uninstall previews
# do not add logical bundle bytes to physical leftover sizes.
get_path_size_kb() {
    local path="$1"
    local size_timeout="${2:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}"
    [[ -z "$path" || ! -e "$path" ]] && {
        echo "0"
        return
    }

    if [[ ! "$size_timeout" =~ ^[0-9]+(\.[0-9]+)?$ || "$size_timeout" =~ ^0+(\.0+)?$ ]]; then
        size_timeout="$MOLE_TIMEOUT_DISK_VERIFY_SEC"
    fi
    local timeout_whole="${size_timeout%%.*}"
    local timeout_budget=$((10#$timeout_whole))
    if [[ "$size_timeout" == *.* && "${size_timeout#*.}" =~ [1-9] ]]; then
        timeout_budget=$((timeout_budget + 1))
    fi
    [[ $timeout_budget -gt 0 ]] || timeout_budget=1
    local size_deadline=$((SECONDS + timeout_budget))

    # Uninstall totals represent estimated disk occupancy. Keep .app bundles
    # on the same physical-size basis as the directory fallback; logical size
    # can be much larger for APFS-cloned bundles and must not be mixed into the
    # same total as `du` results (#1404).
    if [[ "$path" == *.app || "$path" == *.app/ ]]; then
        local mdls_size
        local mdls_timeout=""
        local mdls_deadline_rc=0
        mdls_timeout=$(_mole_timeout_with_deadline \
            "$size_timeout" "$size_deadline") || mdls_deadline_rc=$?
        [[ $mdls_deadline_rc -eq 0 ]] || return "$mdls_deadline_rc"
        local mdls_rc=0
        mdls_size=$(run_with_timeout "$mdls_timeout" mdls \
            -name kMDItemPhysicalSize -raw "$path" < /dev/null 2> /dev/null) || mdls_rc=$?
        [[ $mdls_rc -eq 124 || $mdls_rc -ge 128 ]] && return "$mdls_rc"
        if [[ "$mdls_size" =~ ^[0-9]+$ && "$mdls_size" -gt 0 ]]; then
            echo $(((mdls_size + 1023) / 1024))
            return
        fi
    fi

    # Fast path for regular files and symlinks: st_blocks is measured in
    # 512-byte units and matches the physical basis of `du -skP`.
    if [[ -f "$path" || -L "$path" ]]; then
        local blocks
        local stat_timeout=""
        local stat_deadline_rc=0
        stat_timeout=$(_mole_timeout_with_deadline \
            "$size_timeout" "$size_deadline") || stat_deadline_rc=$?
        [[ $stat_deadline_rc -eq 0 ]] || return "$stat_deadline_rc"
        local stat_rc=0
        blocks=$(run_with_timeout "$stat_timeout" stat \
            -f%b "$path" < /dev/null 2> /dev/null) || stat_rc=$?
        [[ $stat_rc -eq 124 || $stat_rc -ge 128 ]] && return "$stat_rc"
        if [[ "$blocks" =~ ^[0-9]+$ ]]; then
            echo $(((blocks + 1) / 2))
            return
        fi
    fi

    # Bounded like every other du call site (hints/project/caches): an
    # unbounded walk here wedges one parallel sizing worker forever on a
    # stalled SMB/FUSE mount. A timeout is cancellation, not a zero-byte
    # measurement, because callers may feed the result into a deletion plan.
    local size
    local du_timeout=""
    local du_deadline_rc=0
    du_timeout=$(_mole_timeout_with_deadline \
        "$size_timeout" "$size_deadline") || du_deadline_rc=$?
    [[ $du_deadline_rc -eq 0 ]] || return "$du_deadline_rc"
    local du_rc=0
    size=$(run_with_timeout "$du_timeout" du -skP "$path" 2> /dev/null |
        awk 'NR==1 {print $1; exit}') || du_rc=$?
    # `du` may print a partial aggregate before reporting an unreadable child.
    # Any nonzero status makes that number incomplete, so never return it as a
    # successful size estimate (#1404).
    [[ $du_rc -eq 0 ]] || return "$du_rc"

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        [[ "${MO_DEBUG:-}" == "1" ]] && debug_log "get_path_size_kb: Failed to get size for $path (returned: $size)"
        echo "0"
    fi
}

# Calculate total size for multiple paths
calculate_total_size() {
    local files="$1"
    local total_kb=0
    local -a unique_paths=()

    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            local normalized_file="${file%/}"
            [[ -n "$normalized_file" ]] || normalized_file="$file"

            local skip_file=false
            local -a filtered_paths=()
            local existing_file
            for existing_file in "${unique_paths[@]+"${unique_paths[@]}"}"; do
                if [[ "$normalized_file" == "$existing_file" || "$normalized_file" == "$existing_file"/* ]]; then
                    skip_file=true
                    break
                fi
                if [[ "$existing_file" == "$normalized_file"/* ]]; then
                    continue
                fi
                filtered_paths+=("$existing_file")
            done

            if [[ "$skip_file" == "false" ]]; then
                unique_paths=("${filtered_paths[@]+"${filtered_paths[@]}"}")
                unique_paths+=("$normalized_file")
            fi
        fi
    done <<< "$files"

    for file in "${unique_paths[@]+"${unique_paths[@]}"}"; do
        local size_kb=0
        local size_rc=0
        size_kb=$(get_path_size_kb "$file") || size_rc=$?
        [[ $size_rc -eq 124 || $size_rc -ge 128 ]] && return "$size_rc"
        [[ $size_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        total_kb=$((total_kb + size_kb))
    done

    echo "$total_kb"
}

diagnose_removal_failure() {
    local exit_code="$1"
    local app_name="${2:-application}"

    local reason=""
    local suggestion=""

    case "$exit_code" in
        "$MOLE_ERR_SIP_PROTECTED")
            reason="protected by macOS (SIP/MDM)"
            ;;
        "$MOLE_ERR_AUTH_FAILED")
            reason="authentication failed"
            if declare -F check_touchid_support > /dev/null 2>&1 && check_touchid_support > /dev/null 2>&1; then
                suggestion="Check your credentials or restart Terminal"
            else
                suggestion="Try 'mole touchid' to enable fingerprint auth"
            fi
            ;;
        "$MOLE_ERR_READONLY_FS")
            reason="filesystem is read-only"
            suggestion="Check if disk needs repair"
            ;;
        "$MOLE_ERR_PROTECTED_PATH")
            reason="protected by Mole safety rules"
            ;;
        "$MOLE_ERR_PRIVACY_DENIED")
            reason="macOS could not authorize Trash access"
            suggestion="Review App Management, App Data, or Full Disk Access for your terminal in System Settings"
            ;;
        "$MOLE_ERR_MUTABLE_PARENT")
            reason="Mole cannot safely use elevated deletion below a user-writable parent"
            suggestion="Move the app to Trash in Finder; Mole will leave protected containers and app data untouched"
            ;;
        *)
            reason="permission denied"
            if declare -F check_touchid_support > /dev/null 2>&1 && check_touchid_support > /dev/null 2>&1; then
                suggestion="Try running again or check file ownership"
            else
                suggestion="Try 'mole touchid' or check with 'ls -l'"
            fi
            ;;
    esac

    echo "$reason|$suggestion"
}
