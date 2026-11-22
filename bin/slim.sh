#!/bin/bash
# Mole - Slim command
# Remove the Intel code from universal apps on Apple Silicon. Every app is
# slimmed on a clone, verified, and only then swapped in; the original goes
# to the Trash.

set -euo pipefail

# User state and installed tools must never run with inherited root privileges.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run Mole without sudo; mo slim only changes apps you own.' >&2
    exit 1
fi

# shellcheck disable=SC2154
# External variables set by menu_paginated.sh
declare MOLE_SELECTION_RESULT

export LC_ALL=C
export LANG=C
export MOLE_CURRENT_COMMAND="${MOLE_CURRENT_COMMAND:-slim}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"

# The selection menu manages its own alternate screen.
cleanup() {
    show_cursor
    cleanup_temp_files
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

readonly SLIM_EXIT_UNSUPPORTED=4
# Signature and Gatekeeper checks read every file of a large app.
readonly SLIM_VERIFY_TIMEOUT_SEC=180
# Assessing an original during the scan; a slower answer counts as unknown.
readonly SLIM_SCAN_GATEKEEPER_TIMEOUT_SEC=20
SLIM_WORK_DIR=""

# Scan results, one index per app.
SLIM_APP_PATHS=()
SLIM_APP_NAMES=()
SLIM_APP_BYTES=()
SLIM_APP_IDENTITIES=()
SLIM_APP_TEAMS=()
SLIM_APP_PLANS=()

total_slimmed=0
total_freed_bytes=0
total_failed=0
SLIM_DONE_NAMES=()
SLIM_FAILED_NAMES=()
SLIM_FAILED_REASONS=()

show_slim_help() {
    echo "Usage: mo slim [OPTIONS]"
    echo ""
    echo "Remove the Intel code from universal apps on Apple Silicon."
    echo "Each app is slimmed on a copy that must pass code signing and Gatekeeper"
    echo "checks before it replaces the original, which moves to the Trash."
    echo "App updates bring the Intel code back."
    echo "Apps protected by ~/.config/mole/whitelist are skipped."
    echo ""
    echo "Options:"
    echo "  --dry-run, -n     List apps and reclaimable space without changes"
    echo "  --debug           Show why apps were skipped"
    echo "  -h, --help        Show this help message"
}

slim_app_roots() {
    if [[ -n "${MOLE_SLIM_TEST_APP_ROOTS:-}" ]] &&
        [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        local IFS=':'
        local root
        for root in $MOLE_SLIM_TEST_APP_ROOTS; do
            printf '%s\n' "$root"
        done
        return 0
    fi
    printf '%s\n' "/Applications" "$HOME/Applications"
}

slim_host_is_apple_silicon() {
    if [[ -n "${MOLE_SLIM_TEST_HOST_ARM64:-}" && "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        [[ "$MOLE_SLIM_TEST_HOST_ARM64" == "1" ]]
        return
    fi
    # uname -m reports x86_64 inside a Rosetta shell; the sysctl does not.
    # Absolute path: a PATH without /usr/sbin made every Mac read as Intel (#1804).
    [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2> /dev/null || echo 0)" == "1" ]]
}

slim_plist_value() {
    local plist="$1" key="$2"
    [[ -f "$plist" ]] || return 1
    plutil -extract "$key" raw -o - "$plist" 2> /dev/null
}

# Print the Team ID when the bundle is signed with a Developer ID certificate.
# App Store, Apple, ad-hoc and unsigned bundles fail.
slim_signing_team() {
    local app="$1" info
    info=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" codesign -dv --verbose=2 "$app" 2>&1 < /dev/null) || return 1
    printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application: ' || return 1
    local team
    team=$(printf '%s\n' "$info" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || return 1
    printf '%s\n' "$team"
}

slim_app_is_running() {
    local app="${1%/}" comm
    while IFS= read -r comm; do
        [[ "$comm" == "$app/"* ]] && return 0
    done < <(ps -axww -o comm= 2> /dev/null || true)
    return 1
}

# "Open using Rosetta" in Finder's Get Info is stored per bundle id.
slim_app_prefers_rosetta() {
    local bundle_id="$1"
    local plist="$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist"
    [[ -f "$plist" ]] || return 1
    local xml
    xml=$(plutil -extract LSArchitecturesForX86_64 xml1 -o - "$plist" 2> /dev/null) || return 1
    printf '%s\n' "$xml" | awk -v want="<key>$bundle_id</key>" '
        { gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == want { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

# Print the reason an app is out of scope, or nothing when it may be slimmed.
# Running apps are listed and refused only when slimming starts.
slim_skip_reason() {
    local app="$1" check_running="${2:-true}"
    if is_path_whitelisted "$app"; then
        echo "whitelisted"
        return
    fi
    [[ -L "$app" ]] && {
        echo "symlink"
        return
    }
    [[ -d "$app/Contents" ]] || {
        echo "not an app bundle"
        return
    }
    [[ -d "$app/Contents/_MASReceipt" ]] && {
        echo "App Store app"
        return
    }
    local owner
    owner=$("$STAT_BSD" -f %u "$app" 2> /dev/null || echo "")
    [[ "$owner" == "$(id -u)" ]] || {
        echo "not owned by you"
        return
    }
    [[ -w "$(dirname "$app")" ]] || {
        echo "folder not writable"
        return
    }
    if [[ -n "$(find "$app" ! -user "$(id -un)" -print -quit 2> /dev/null)" ]]; then
        echo "contains files owned by another user"
        return
    fi
    local bundle_id
    bundle_id=$(slim_plist_value "$app/Contents/Info.plist" CFBundleIdentifier || echo "")
    [[ -n "$bundle_id" ]] || {
        echo "no bundle identifier"
        return
    }
    [[ "$bundle_id" == com.apple.* ]] && {
        echo "Apple app"
        return
    }
    if should_protect_from_uninstall "$bundle_id" ||
        official_uninstaller_vendor "$bundle_id" "" "$app" > /dev/null; then
        echo "protected app"
        return
    fi
    slim_app_prefers_rosetta "$bundle_id" && {
        echo "set to open using Rosetta"
        return
    }
    if [[ "$check_running" == true ]] && slim_app_is_running "$app"; then
        echo "still running"
        return
    fi
    return 0
}

# Print "<c|h>\t<key>" for every files2 key in CodeResources: c when it is
# sealed by cdhash (nested code with its own signature), h otherwise. A key
# sealed by hash2 is a plain file: thinning one breaks the bundle seal.
# Parses the XML form; plutil -p is not parseable.
slim_sealed_keys() {
    local code_resources="$1"
    plutil -convert xml1 -o - "$code_resources" 2> /dev/null | awk '
        function decode(s) {
            gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s)
            gsub(/&quot;/, "\"", s); gsub(/&apos;/, "\047", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }
        { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
        !in_files2 && line == "<key>files2</key>" { want_dict = 1; next }
        want_dict {
            want_dict = 0
            if (line == "<dict>") { in_files2 = 1; depth = 1 }
            next
        }
        !in_files2 { next }
        line == "<dict/>" { if (depth == 1) print "h\t" decode(key); next }
        line == "<dict>" { depth++; if (depth == 2) { sealed = 0 }; next }
        line == "</dict>" {
            if (depth == 2) print (sealed ? "c" : "h") "\t" decode(key)
            depth--
            if (depth == 0) exit
            next
        }
        depth == 1 && line ~ /^<key>.*<\/key>$/ {
            key = substr(line, 6, length(line) - 11)
            next
        }
        depth == 2 && line == "<key>cdhash</key>" { sealed = 1 }
    '
}

# Directory holding the _CodeSignature that seals this file: Contents/ for
# app-like bundles, Versions/<v>/ for frameworks.
slim_sealing_root() {
    local file="$1" app="${2%/}" dir
    dir=$(dirname "$file")
    while [[ "$dir" == "$app"/* || "$dir" == "$app" ]]; do
        if [[ -f "$dir/_CodeSignature/CodeResources" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
        [[ "$dir" == "$app" ]] && break
        dir=$(dirname "$dir")
    done
    return 1
}

# A bundle's main executable carries the bundle signature itself, so the
# seal never lists it.
slim_is_main_executable() {
    local file="$1" root="$2" exe=""
    if [[ "$(dirname "$file")" == "$root/MacOS" ]]; then
        exe=$(slim_plist_value "$root/Info.plist" CFBundleExecutable || echo "")
    elif [[ "$(dirname "$file")" == "$root" && "$root" == *.framework/Versions/* ]]; then
        exe=$(slim_plist_value "$root/Resources/Info.plist" CFBundleExecutable || echo "")
    fi
    [[ -n "$exe" && "$(basename "$file")" == "$exe" ]]
}

# Fat headers are read with od, so slimming needs no developer tools: lipo
# comes with the Command Line Tools, a larger install than most apps free.
# Print "<arch> <offset> <size>" per slice; a non-fat file fails.
slim_fat_slices() {
    local file="$1" entry n i p cpu sub arch off size file_size
    local -a b=()
    read -r -a b <<< "$(od -An -v -tu1 -N 8 "$file" 2> /dev/null | tr '\n' ' ')"
    [[ ${#b[@]} -eq 8 ]] || return 1
    case "${b[0]} ${b[1]} ${b[2]} ${b[3]}" in
        "202 254 186 190") entry=20 ;; # FAT_MAGIC
        "202 254 186 191") entry=32 ;; # FAT_MAGIC_64
        *) return 1 ;;
    esac
    n=$(((b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7]))
    ((n >= 1 && n <= 16)) || return 1
    read -r -a b <<< "$(od -An -v -tu1 -N $((8 + n * entry)) "$file" 2> /dev/null | tr '\n' ' ')"
    [[ ${#b[@]} -eq $((8 + n * entry)) ]] || return 1
    file_size=$("$STAT_BSD" -f %z "$file" 2> /dev/null) || return 1

    for ((i = 0; i < n; i++)); do
        p=$((8 + i * entry))
        cpu=$(((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]))
        sub=$(((b[p + 5] << 16) | (b[p + 6] << 8) | b[p + 7]))
        if [[ $entry -eq 20 ]]; then
            off=$(((b[p + 8] << 24) | (b[p + 9] << 16) | (b[p + 10] << 8) | b[p + 11]))
            size=$(((b[p + 12] << 24) | (b[p + 13] << 16) | (b[p + 14] << 8) | b[p + 15]))
        else
            off=$(((b[p + 8] << 56) | (b[p + 9] << 48) | (b[p + 10] << 40) | (b[p + 11] << 32) | (\
                b[p + 12] << 24) | (b[p + 13] << 16) | (b[p + 14] << 8) | b[p + 15]))
            size=$(((b[p + 16] << 56) | (b[p + 17] << 48) | (b[p + 18] << 40) | (b[p + 19] << 32) | (\
                b[p + 20] << 24) | (b[p + 21] << 16) | (b[p + 22] << 8) | b[p + 23]))
        fi
        ((off > 0 && size > 0 && off + size <= file_size)) || return 1
        case "$cpu:$sub" in
            16777228:2) arch=arm64e ;; # CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E
            16777228:*) arch=arm64 ;;
            16777223:8) arch=x86_64h ;; # CPU_TYPE_X86_64, CPU_SUBTYPE_X86_64_H
            16777223:*) arch=x86_64 ;;
            7:*) arch=i386 ;;
            *) arch=other ;;
        esac
        printf '%s %s %s\n' "$arch" "$off" "$size"
    done
}

# Print "<offset> <size> <intel bytes>" when the file holds exactly one arm64
# slice plus Intel slices and nothing else; that slice is the whole slimmed
# file. Any arm64e slice leaves the file alone: macOS refuses third-party
# arm64e code unless the arm64e ABI is enabled, so such an app may be running
# its Intel slice today and would have nothing left that runs.
slim_arm_slice() {
    local file="$1" slices arch off size
    local arm_count=0 arm_off=0 arm_size=0 intel=0
    slices=$(slim_fat_slices "$file") || return 1
    while read -r arch off size; do
        case "$arch" in
            arm64)
                arm_count=$((arm_count + 1))
                arm_off=$off
                arm_size=$size
                ;;
            x86_64 | x86_64h | i386) intel=$((intel + size)) ;;
            *) return 1 ;;
        esac
    done <<< "$slices"
    [[ $arm_count -eq 1 && $intel -gt 0 ]] || return 1
    printf '%s %s %s\n' "$arm_off" "$arm_size" "$intel"
}

# Bytes of Intel slices in a universal file that also runs natively.
slim_intel_bytes() {
    local info
    info=$(slim_arm_slice "$1") || return 1
    printf '%s\n' "${info##* }"
}

# A thin 64-bit Mach-O for Apple Silicon: MH_MAGIC_64 then CPU_TYPE_ARM64,
# both little-endian.
slim_is_thin_arm() {
    [[ "$(od -An -v -tu1 -N 8 "$1" 2> /dev/null | tr -s ' \n' ' ')" == " 207 250 237 254 12 0 0 1 " ]]
}

# Set keys_file to the cached slim_sealed_keys output for a sealing root;
# roots and root_keys belong to the calling slim_plan_app.
slim_seal_keys_file() {
    local root="$1" i
    for ((i = 0; i < ${#roots[@]}; i++)); do
        if [[ "${roots[i]}" == "$root" ]]; then
            keys_file="${root_keys[i]}"
            return 0
        fi
    done
    keys_file=$(create_temp_file) || return 1
    slim_sealed_keys "$root/_CodeSignature/CodeResources" > "$keys_file" || true
    roots+=("$root")
    root_keys+=("$keys_file")
}

# Write "<path relative to the app>\t<intel bytes>" for every file that can
# be thinned without breaking a seal; print the total.
slim_plan_app() {
    local app="${1%/}" plan_file="$2"
    local -a roots=() root_keys=()
    local total=0 file
    : > "$plan_file"

    while IFS= read -r file; do
        local root
        root=$(slim_sealing_root "$file" "$app") || continue
        local allowed=false keys_file
        if slim_is_main_executable "$file" "$root"; then
            allowed=true
        else
            slim_seal_keys_file "$root" || return 1
            grep -Fxq -- "c"$'\t'"${file#"$root"/}" "$keys_file" && allowed=true
        fi
        # An enclosing bundle may seal the same file by plain hash: ScreenFlow
        # signs its QuickLook plugin but its own seal lists the plugin's
        # executable as a file, so thinning that executable broke the app.
        local outer="$root"
        while [[ "$allowed" == true ]] && outer=$(slim_sealing_root "$outer" "$app"); do
            slim_seal_keys_file "$outer" || return 1
            grep -Fxq -- "h"$'\t'"${file#"$outer"/}" "$keys_file" && allowed=false
        done
        [[ "$allowed" == true ]] || {
            debug_log "slim: keeping $file (sealed as a plain file)"
            continue
        }
        local bytes
        bytes=$(slim_intel_bytes "$file") || continue
        printf '%s\t%s\n' "${file#"$app"/}" "$bytes" >> "$plan_file"
        total=$((total + bytes))
    done < <(find "$app/Contents" -type f \
        -not -path '*/Resources/*' -not -path '*/_CodeSignature/*' \
        -print0 2> /dev/null | xargs -0 file -N -F $'\t' 2> /dev/null |
        awk -F'\t' '$2 ~ /Mach-O universal/ { print $1 }')

    printf '%s\n' "$total"
}

collect_slim_candidates() {
    SLIM_APP_PATHS=()
    SLIM_APP_NAMES=()
    SLIM_APP_BYTES=()
    SLIM_APP_IDENTITIES=()
    SLIM_APP_TEAMS=()
    SLIM_APP_PLANS=()

    local -a apps=()
    local root dir app
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        # One level of plain folders such as Utilities (#1811); never a bundle
        # or a symlinked folder, and every app still passes the same checks.
        for dir in "$root" "$root"/*; do
            if [[ "$dir" != "$root" ]]; then
                [[ "$dir" != *.app && -d "$dir" && ! -L "$dir" ]] || continue
            fi
            for app in "$dir"/*.app; do
                [[ -e "$app" || -L "$app" ]] || continue
                apps+=("$app")
            done
        done
    done < <(slim_app_roots)

    local -a unsorted=() pids=()
    for app in "${apps[@]+"${apps[@]}"}"; do
        local reason
        reason=$(slim_skip_reason "$app" false)
        if [[ -n "$reason" ]]; then
            debug_log "slim: skipping $app ($reason)"
            continue
        fi
        local team
        if ! team=$(slim_signing_team "$app"); then
            debug_log "slim: skipping $app (not signed with a Developer ID)"
            continue
        fi
        local plan_file bytes
        plan_file=$(create_temp_file) || return 1
        bytes=$(slim_plan_app "$app" "$plan_file") || bytes=0
        if [[ ! "$bytes" =~ ^[0-9]+$ || "$bytes" -eq 0 ]]; then
            debug_log "slim: skipping $app (no Intel code)"
            continue
        fi
        local identity
        identity=$(mole_deletion_identity "$app") || continue
        unsorted+=("$bytes"$'\t'"$app"$'\t'"$identity"$'\t'"$team"$'\t'"$plan_file")
        run_with_timeout "$SLIM_SCAN_GATEKEEPER_TIMEOUT_SEC" spctl --assess --type execute "$app" > /dev/null 2>&1 < /dev/null &
        pids+=("$!")
    done

    [[ ${#unsorted[@]} -gt 0 ]] || return 1

    # An original Gatekeeper already rejects (an unnotarized build) can never
    # yield a copy that passes, so it is left out rather than offered and
    # failed after a full copy. Each candidate is assessed in the background
    # as soon as its plan is ready, so the checks overlap the rest of the
    # scan; only an explicit rejection (3) removes one.
    local -a accepted=()
    local i gk
    for ((i = 0; i < ${#unsorted[@]}; i++)); do
        gk=0
        wait "${pids[i]}" || gk=$?
        if [[ $gk -eq 3 ]]; then
            app="${unsorted[i]#*$'\t'}"
            debug_log "slim: skipping ${app%%$'\t'*} (Gatekeeper rejects the original)"
            continue
        fi
        accepted+=("${unsorted[i]}")
    done
    [[ ${#accepted[@]} -gt 0 ]] || return 1

    while IFS=$'\t' read -r bytes app identity team plan_file; do
        SLIM_APP_BYTES+=("$bytes")
        SLIM_APP_PATHS+=("$app")
        SLIM_APP_IDENTITIES+=("$identity")
        SLIM_APP_TEAMS+=("$team")
        SLIM_APP_PLANS+=("$plan_file")
        local name="${app##*/}"
        SLIM_APP_NAMES+=("${name%.app}")
    done < <(printf '%s\n' "${accepted[@]}" | sort -t$'\t' -k1,1nr)
    return 0
}

slim_name_column_width() {
    local columns="${COLUMNS:-$(tput cols 2> /dev/null || echo 80)}"
    [[ "$columns" =~ ^[0-9]+$ && "$columns" -gt 0 ]] || columns=80
    local name width max_width=18 available=$((columns - 14))
    for name in "${SLIM_APP_NAMES[@]}"; do
        width=$(get_display_width "$(mole_terminal_safe_text "$name")")
        [[ $width -le $max_width ]] || max_width=$width
    done
    # Match the app selector's bounded name column, with no date column.
    # Reserve four cells for the menu prefix, one gap and nine for size.
    [[ $max_width -le 60 ]] || max_width=60
    [[ $max_width -le $available ]] || max_width=$available
    [[ $max_width -ge 1 ]] || max_width=1
    printf '%s\n' "$max_width"
}

slim_display_row() {
    local name width
    local name_width="$3"
    name=$(truncate_by_display_width "$(mole_terminal_safe_text "$1")" "$name_width")
    width=$(get_display_width "$name")
    printf '%s%*s %9s' "$name" "$((name_width - width))" "" "$(bytes_to_human "$2")"
}

print_slim_list() {
    local i total=0 name_width
    name_width=$(slim_name_column_width)
    for ((i = 0; i < ${#SLIM_APP_PATHS[@]}; i++)); do
        printf '  %s\n' "$(slim_display_row "${SLIM_APP_NAMES[i]}" "${SLIM_APP_BYTES[i]}" "$name_width")"
        total=$((total + SLIM_APP_BYTES[i]))
    done
    printf '\n%s apps, %s of Intel code\n' "${#SLIM_APP_PATHS[@]}" "$(bytes_to_human "$total")"
}

record_slim_failure() {
    local app="$1" reason="$2"
    local name="${app##*/}"
    SLIM_FAILED_NAMES+=("${name%.app}")
    SLIM_FAILED_REASONS+=("$reason")
    total_failed=$((total_failed + 1))
    log_operation "$MOLE_CURRENT_COMMAND" "SKIPPED" "$app" "$reason"
}

slim_thin_file() {
    local file="$1" info off size _intel
    info=$(slim_arm_slice "$file") || return 1
    read -r off size _intel <<< "$info"

    local out mode
    mode=$("$STAT_BSD" -f %Lp "$file") || return 1
    # Bundle contents can already include any fixed suffix, including a link.
    # Create the output exclusively rather than opening a bundle-owned path.
    out=$(mktemp "$file.mole-slim.XXXXXX") || return 1
    # head stops reading once it has the slice, so when the slice is not the
    # last one tail dies of SIGPIPE; the size and Mach-O checks below are what
    # decide whether the copy is whole.
    if ! { tail -c +"$((off + 1))" "$file" 2> /dev/null || true; } | head -c "$size" > "$out" 2> /dev/null; then
        rm -f "$out" # SAFE: exclusively created slice output inside the staging copy
        return 1
    fi
    if [[ "$("$STAT_BSD" -f %z "$out" 2> /dev/null)" != "$size" ]] || ! slim_is_thin_arm "$out"; then
        rm -f "$out" # SAFE: partial slice written by this function inside the staging copy
        return 1
    fi
    if ! chmod "$mode" "$out" || ! mv -f "$out" "$file"; then
        rm -f "$out" # SAFE: exclusively created slice output that was not installed
        return 1
    fi
}

# Every check runs on the slimmed copy; any failure keeps the original.
slim_verify_copy() {
    local copy="$1" team="$2" plan_file="$3"
    local rel _bytes

    while IFS=$'\t' read -r rel _bytes; do
        slim_is_thin_arm "$copy/$rel" || {
            echo "Apple Silicon code missing"
            return 1
        }
    done < "$plan_file"

    run_with_timeout "$SLIM_VERIFY_TIMEOUT_SEC" codesign --verify --deep --strict "$copy" > /dev/null 2>&1 < /dev/null || {
        echo "code signature check failed"
        return 1
    }
    local copy_team
    copy_team=$(slim_signing_team "$copy") || copy_team=""
    [[ "$copy_team" == "$team" ]] || {
        echo "signing team changed"
        return 1
    }
    run_with_timeout "$SLIM_VERIFY_TIMEOUT_SEC" spctl --assess --type execute "$copy" > /dev/null 2>&1 < /dev/null || {
        echo "Gatekeeper check failed"
        return 1
    }
    return 0
}

slim_discard_stage() {
    local stage="$1"
    [[ -n "$stage" && "$stage" == "$SLIM_WORK_DIR"/app.* ]] || return 0
    rm -rf "$stage" # SAFE: mktemp staging folder under this run's work dir, holding only the slimmed copy
}

slim_one_app() {
    local index="$1"
    local app="${SLIM_APP_PATHS[index]}"
    local planned_identity="${SLIM_APP_IDENTITIES[index]}"
    local team="${SLIM_APP_TEAMS[index]}"
    local plan_file="${SLIM_APP_PLANS[index]}"
    local bytes="${SLIM_APP_BYTES[index]}"

    local reason identity
    if ! load_mole_whitelist "$HOME"; then
        record_slim_failure "$app" "whitelist unavailable"
        return 0
    fi
    reason=$(slim_skip_reason "$app")
    if [[ -n "$reason" ]]; then
        record_slim_failure "$app" "$reason"
        return 0
    fi
    identity=$(mole_deletion_identity "$app") || identity=""
    if [[ "$identity" != "$planned_identity" ]]; then
        record_slim_failure "$app" "changed since scan"
        return 0
    fi
    # A signature that is already broken cannot prove the copy is intact.
    local verify_out has_detritus=false
    if ! verify_out=$(run_with_timeout "$SLIM_VERIFY_TIMEOUT_SEC" codesign --verify --deep --strict "$app" 2>&1 < /dev/null); then
        if [[ "$verify_out" != *"detritus not allowed"* ]]; then
            record_slim_failure "$app" "code signature already invalid"
            return 0
        fi
        has_detritus=true
    fi

    local stage
    stage=$(mktemp -d "$SLIM_WORK_DIR/app.XXXXXX") || {
        record_slim_failure "$app" "no staging folder"
        return 0
    }
    local copy="$stage/${app##*/}"
    if ! ditto --clone "$app" "$copy" 2> /dev/null; then
        slim_discard_stage "$stage"
        record_slim_failure "$app" "copy failed"
        return 0
    fi

    # finder xattrs fail --strict but sit outside the seal: strip them on the
    # copy only, then the untouched copy has to pass in place of the original.
    # -s keeps xattr on a symlink itself, never on a target outside the copy.
    if [[ "$has_detritus" == "true" ]]; then
        /usr/bin/xattr -rsd com.apple.FinderInfo "$copy" 2> /dev/null || true
        /usr/bin/xattr -rsd com.apple.ResourceFork "$copy" 2> /dev/null || true
        if ! run_with_timeout "$SLIM_VERIFY_TIMEOUT_SEC" codesign --verify --deep --strict "$copy" > /dev/null 2>&1 < /dev/null; then
            slim_discard_stage "$stage"
            record_slim_failure "$app" "code signature already invalid"
            return 0
        fi
    fi

    local rel _bytes
    while IFS=$'\t' read -r rel _bytes; do
        if ! slim_thin_file "$copy/$rel"; then
            slim_discard_stage "$stage"
            record_slim_failure "$app" "could not remove Intel code from ${rel##*/}"
            return 0
        fi
    done < "$plan_file"

    if ! reason=$(slim_verify_copy "$copy" "$team" "$plan_file"); then
        slim_discard_stage "$stage"
        record_slim_failure "$app" "$reason"
        return 0
    fi

    # Protection may change during the copy or signature checks. A failed
    # reload is unknown, never permission to replace the original.
    if ! load_mole_whitelist "$HOME"; then
        slim_discard_stage "$stage"
        record_slim_failure "$app" "whitelist unavailable"
        return 0
    fi
    if is_path_whitelisted "$app"; then
        slim_discard_stage "$stage"
        record_slim_failure "$app" "whitelisted"
        return 0
    fi

    # The app may have started while the copy was checked.
    if slim_app_is_running "$app"; then
        slim_discard_stage "$stage"
        record_slim_failure "$app" "still running"
        return 0
    fi

    # From here until the copy is in place an interrupt would leave neither
    # app in /Applications: the cleanup trap deletes the work folder, copy
    # included. Hold INT and TERM over the swap and act on them after it.
    local swap_signal=""
    trap 'swap_signal=INT' INT
    trap 'swap_signal=TERM' TERM
    local delete_rc=0
    MOLE_DELETE_MODE=trash mole_delete "$app" false "$planned_identity" || delete_rc=$?
    local swap_failed=""
    if [[ $delete_rc -ne 0 || -e "$app" ]]; then
        swap_failed="could not move the original to Trash"
    elif ! mv "$copy" "$app" 2> /dev/null; then
        swap_failed="original is in the Trash, drag it back to ${app%/*}"
    fi
    trap 'trap - EXIT; cleanup; exit 130' INT TERM
    if [[ -n "$swap_failed" ]]; then
        [[ "$swap_failed" == "could not move"* ]] && slim_discard_stage "$stage"
        record_slim_failure "$app" "$swap_failed"
        [[ -z "$swap_signal" ]] || kill -s "$swap_signal" $$
        [[ "$swap_failed" == "could not move"* ]] && mole_rc_timeout_or_signal "$delete_rc" && return "$delete_rc"
        return 0
    fi
    [[ -z "$swap_signal" ]] || kill -s "$swap_signal" $$

    slim_discard_stage "$stage"
    total_slimmed=$((total_slimmed + 1))
    SLIM_DONE_NAMES+=("${SLIM_APP_NAMES[index]}")
    total_freed_bytes=$((total_freed_bytes + bytes))
    log_operation "$MOLE_CURRENT_COMMAND" "REBUILT" "$app" "removed Intel code, $(bytes_to_human "$bytes")"
    return 0
}

select_slim_apps() {
    local -a rows=() sizes_kb=() names=()
    local i name_width
    name_width=$(slim_name_column_width)
    for ((i = 0; i < ${#SLIM_APP_PATHS[@]}; i++)); do
        rows+=("$(slim_display_row "${SLIM_APP_NAMES[i]}" "${SLIM_APP_BYTES[i]}" "$name_width")")
        sizes_kb+=("$((SLIM_APP_BYTES[i] / 1024))")
        names+=("$(mole_terminal_safe_text "${SLIM_APP_NAMES[i]}")")
    done
    MOLE_MENU_META_SIZEKB=$(
        IFS=','
        printf '%s' "${sizes_kb[*]}"
    )
    export MOLE_MENU_META_SIZEKB
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
    export MOLE_MENU_FILTER_NAMES
    export MOLE_MENU_SORT_MODE=size
    export MOLE_MENU_SORT_REVERSE=false

    MOLE_SELECTION_RESULT=""
    local rc=0
    paginated_multi_select "Select apps to slim" "${rows[@]}" || rc=$?
    unset MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES
    [[ $rc -eq 0 && -n "$MOLE_SELECTION_RESULT" ]]
}

confirm_slim_selection() {
    local -a indices=("$@")
    local idx total=0 running=false tag
    echo -e "\n${PURPLE_BOLD}Apps to slim:${NC}"
    for idx in "${indices[@]}"; do
        tag=""
        if slim_app_is_running "${SLIM_APP_PATHS[idx]}"; then
            tag=" ${YELLOW}[Running]${NC}"
            running=true
        fi
        printf '%b%s%b\n' "${BLUE}${ICON_CONFIRM}${NC} " "$(mole_terminal_safe_text "${SLIM_APP_NAMES[idx]}")" \
            " ${GRAY}· $(bytes_to_human "${SLIM_APP_BYTES[idx]}")${NC}${tag}"
        total=$((total + SLIM_APP_BYTES[idx]))
    done
    echo ""
    echo -e "${GRAY}Originals move to the Trash. App updates bring the Intel code back.${NC}"
    [[ "$running" == false ]] || echo -e "${GRAY}Running apps are skipped, quit them before you confirm.${NC}"
    local app_text="apps"
    [[ ${#indices[@]} -gt 1 ]] || app_text="app"
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Slim ${#indices[@]} ${app_text}, $(bytes_to_human "$total")  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    local confirm
    if ! IFS= read -r -s -n1 confirm; then
        printf '\n'
        return 1
    fi
    printf '\n'
    case "$confirm" in
        "" | $'\n' | $'\r') return 0 ;;
    esac
    printf '\n'
    return 1
}

# Mirrors the uninstall summary: slimmed apps three per line, then the apps
# left unchanged grouped by reason so six running apps read as one line.
show_slim_summary() {
    local -a details=()
    local i name

    if [[ $total_slimmed -gt 0 ]]; then
        local app_text="apps"
        [[ $total_slimmed -gt 1 ]] || app_text="app"
        local line="Slimmed ${total_slimmed} ${app_text}, freed ${GREEN}$(bytes_to_human "$total_freed_bytes")${NC}: "
        for ((i = 0; i < ${#SLIM_DONE_NAMES[@]}; i++)); do
            if ((i > 0 && i % 3 == 0)); then
                details+=("$line")
                line=""
            elif ((i > 0)); then
                line+=", "
            fi
            name=$(mole_terminal_safe_text "${SLIM_DONE_NAMES[i]}")
            line+="${GREEN}${name//\\/\\\\}${NC}"
        done
        details+=("$line")
    fi

    local -a reasons=()
    local reason seen names label
    for reason in "${SLIM_FAILED_REASONS[@]+"${SLIM_FAILED_REASONS[@]}"}"; do
        for seen in "${reasons[@]+"${reasons[@]}"}"; do
            [[ "$seen" != "$reason" ]] || continue 2
        done
        reasons+=("$reason")
    done
    for reason in "${reasons[@]+"${reasons[@]}"}"; do
        names=""
        for ((i = 0; i < ${#SLIM_FAILED_NAMES[@]}; i++)); do
            [[ "${SLIM_FAILED_REASONS[i]}" == "$reason" ]] || continue
            [[ -z "$names" ]] || names+=", "
            names+="${SLIM_FAILED_NAMES[i]}"
        done
        names=$(mole_terminal_safe_text "$names")
        label=$(mole_terminal_safe_text "$reason")
        label="$(printf '%s' "${label:0:1}" | /usr/bin/tr '[:lower:]' '[:upper:]')${label:1}"
        details+=("${ICON_LIST} ${label//\\/\\\\}: ${YELLOW}${names//\\/\\\\}${NC}")
        if [[ "$reason" == "still running" ]]; then
            local them="them"
            [[ "$names" == *", "* ]] || them="it"
            details+=("${GRAY}${ICON_REVIEW} Quit ${them}, then run mo slim again${NC}")
        fi
    done

    [[ ${#details[@]} -gt 0 ]] || details+=("No apps were slimmed")

    local title="Slim complete"
    [[ $total_failed -eq 0 ]] || title="Slim incomplete"
    print_summary_block "$title" "${details[@]}"
    printf '\n'
}

slim_preflight() {
    if ! slim_host_is_apple_silicon; then
        printf 'mo slim needs an Apple Silicon Mac; on an Intel Mac the Intel code is the code that runs.\n' >&2
        return "$SLIM_EXIT_UNSUPPORTED"
    fi
    load_mole_whitelist "$HOME" || return 1
    SLIM_WORK_DIR=$(create_temp_dir) || return 1
    return 0
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_slim_help
                exit 0
                ;;
            "--debug") export MO_DEBUG=1 ;;
            "--dry-run" | "-n") export MOLE_DRY_RUN=1 ;;
            *)
                echo "Unknown option: $arg" >&2
                echo "Use 'mo slim --help' for supported options." >&2
                exit 1
                ;;
        esac
    done

    local rc=0
    slim_preflight || rc=$?
    [[ $rc -eq 0 ]] || return 1

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No apps will be changed"
        printf '\n'
    fi

    [[ -t 1 ]] && start_inline_spinner "Scanning apps..."
    local collect_rc=0
    collect_slim_candidates || collect_rc=$?
    [[ -t 1 ]] && stop_inline_spinner

    if [[ $collect_rc -ne 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No apps with Intel code to remove"
        return 0
    fi

    # Without a terminal there is nobody to choose: list and stop.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then
        print_slim_list
        if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
            printf 'Run mo slim in a terminal to choose apps.\n'
        fi
        return 0
    fi

    hide_cursor
    if ! select_slim_apps; then
        show_cursor
        printf '\n'
        return 0
    fi
    show_cursor

    local -a indices=()
    IFS=',' read -ra indices <<< "$MOLE_SELECTION_RESULT"
    confirm_slim_selection "${indices[@]}" || return 0

    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    local idx slim_rc=0 current=0 before failed_before name prefix=""
    for idx in "${indices[@]}"; do
        [[ "$idx" =~ ^[0-9]+$ && $idx -lt ${#SLIM_APP_PATHS[@]} ]] || continue
        current=$((current + 1))
        name=$(mole_terminal_safe_text "${SLIM_APP_NAMES[idx]}")
        # Like uninstall, number each app only when several are selected.
        [[ ${#indices[@]} -le 1 ]] || prefix="[$current/${#indices[@]}] "
        before=$total_slimmed
        failed_before=${#SLIM_FAILED_REASONS[@]}
        [[ -t 1 ]] && start_inline_spinner "${prefix}Slimming ${name}..."
        slim_one_app "$idx" || slim_rc=$?
        [[ -t 1 ]] && stop_inline_spinner
        if [[ -t 1 && -n "$prefix" ]]; then
            if [[ $total_slimmed -gt $before ]]; then
                printf '%b%s%b\n' "${GREEN}${ICON_SUCCESS}${NC} ${prefix}" "$name" " ${GRAY}· $(bytes_to_human "${SLIM_APP_BYTES[idx]}")${NC}"
            elif [[ ${#SLIM_FAILED_REASONS[@]} -gt $failed_before ]]; then
                printf '%b%s%b%s%b\n' "${YELLOW}${ICON_WARNING}${NC} ${prefix}" "$name" "${GRAY}, " \
                    "$(mole_terminal_safe_text "${SLIM_FAILED_REASONS[failed_before]}")" "$NC"
            fi
        fi
        [[ $slim_rc -eq 0 ]] || break
    done
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_slimmed" "$((total_freed_bytes / 1024))"

    show_slim_summary
    [[ $slim_rc -eq 0 ]] || return "$slim_rc"
    [[ $total_failed -eq 0 ]] || return 1
    return 0
}

if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
