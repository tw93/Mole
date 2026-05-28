#!/bin/bash
# Helpers for validating imported Roomy profile archives.

set -euo pipefail

if [[ -n "${ROOMY_PROFILE_ARCHIVE_LOADED:-}" ]]; then
    return 0
fi
readonly ROOMY_PROFILE_ARCHIVE_LOADED=1

profile_validate_archive_member() {
    local member="$1"

    [[ -n "$member" ]] || {
        echo "Profile archive contains an empty path" >&2
        return 1
    }
    [[ "$member" != /* ]] || {
        echo "Profile archive contains an absolute path: $member" >&2
        return 1
    }
    if [[ "$member" =~ (^|/)\.\.(\/|$) ]]; then
        echo "Profile archive contains path traversal: $member" >&2
        return 1
    fi
    if [[ "$member" =~ [[:cntrl:]] ]] || [[ "$member" =~ $'\n' ]]; then
        echo "Profile archive contains control characters in path: $member" >&2
        return 1
    fi
}

profile_validate_archive() {
    local input="$1"
    local listing
    if ! listing=$(tar -tzf "$input" 2> /dev/null); then
        echo "Profile archive is not a readable gzip tar archive: $input" >&2
        return 1
    fi
    [[ -n "$listing" ]] || {
        echo "Profile archive is empty" >&2
        return 1
    }

    local archive_root=""
    local member
    while IFS= read -r member; do
        [[ -n "$member" ]] || continue
        member="${member#./}"
        member="${member%/}"
        profile_validate_archive_member "$member" || return 1

        local root="${member%%/*}"
        if [[ -z "$archive_root" ]]; then
            archive_root="$root"
        elif [[ "$archive_root" != "$root" ]]; then
            echo "Profile archive must contain exactly one top-level directory" >&2
            return 1
        fi
    done <<< "$listing"

    local verbose
    if ! verbose=$(tar -tvzf "$input" 2> /dev/null); then
        echo "Profile archive cannot be inspected: $input" >&2
        return 1
    fi
    local entry
    while IFS= read -r entry; do
        case "${entry:0:1}" in
            l | h | b | c | p | s)
                echo "Profile archive contains an unsafe link or special file" >&2
                return 1
                ;;
        esac
    done <<< "$verbose"

    printf '%s\n' "$archive_root"
}

profile_cleanup_import_temp() {
    local path
    for path in "$@"; do
        [[ -n "$path" && -e "$path" ]] || continue
        ROOMY_NO_OPLOG=1 safe_remove "$path" true || true
    done
}
