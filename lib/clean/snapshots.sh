#!/bin/bash
# Local APFS snapshot review rows shared by the user and system clean paths
# (read-only: count and name, never size or delete).

set -euo pipefail

if [[ -n "${MOLE_CLEAN_SNAPSHOTS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_CLEAN_SNAPSHOTS_LOADED=1

# Reads `tmutil listlocalsnapshots /` on stdin and prints review rows.
# $1=true also prints the Time Machine row; the caller decides that from the
# Time Machine configuration. Snapshots from other apps (Synology Active
# Backup, Carbon Copy Cloner) pin deleted data the same way and exist on Macs
# with no Time Machine at all (#1916), so they are reported regardless.
# The heading is localized and holds spaces or a colon, so only bare
# reverse-DNS names count. Other com.apple.* names (software update prep) are
# Apple's own transient snapshots and stay out.
mole_local_snapshot_rows() {
    local include_tm="${1:-false}"
    local name_re='^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$'
    local tm_re='^com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}'
    local line owner known tm_count=0 app_count=0
    local -a owners=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ "$line" =~ $name_re ]] || continue
        if [[ "$line" =~ $tm_re ]]; then
            tm_count=$((tm_count + 1))
            continue
        fi
        [[ "$line" == com.apple.* ]] && continue
        app_count=$((app_count + 1))
        # Owner is the vendor.product prefix: drop the per-snapshot last
        # component, then keep at most three, so an id plus a date suffix
        # (com.vendor.app.<uuid>.<date>) still reads as one owner.
        owner="${line%.*}"
        if [[ "$owner" =~ ^([^.]+\.[^.]+\.[^.]+)\. ]]; then
            owner="${BASH_REMATCH[1]}"
        fi
        if [[ ${#owners[@]} -gt 0 ]]; then
            for known in "${owners[@]}"; do
                [[ "$known" == "$owner" ]] && continue 2
            done
        fi
        owners+=("$owner")
    done

    if [[ "$include_tm" == "true" && $tm_count -gt 0 ]]; then
        mole_review_row "Time Machine local snapshots" "" "$tm_count" "macOS removes them when space runs low"
    fi
    if [[ $app_count -gt 0 ]]; then
        mole_review_row "APFS snapshots" "" "$app_count" \
            "from $(mole_join_names "${owners[@]}"), deleted files keep using space until removed"
    fi
}
