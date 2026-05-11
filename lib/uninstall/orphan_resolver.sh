#!/bin/bash
# Mole - Orphan App Bundle ID Resolution.
# Resolves bundle IDs for apps whose .app bundle has already been deleted.
# Used by `mo uninstall <name>` as a fallback when the normal .app scan
# finds no matches.

set -euo pipefail

if [[ -n "${_MOLE_ORPHAN_RESOLVER_LOADED:-}" ]]; then
    return 0
fi
readonly _MOLE_ORPHAN_RESOLVER_LOADED=1

# Build a newline-separated list of bundle IDs for all .app bundles currently
# installed in standard locations. Used as a fast lookup set.
_build_installed_bundle_ids() {
    local -a app_roots=(
        "/Applications"
        "/Applications/Utilities"
        "/Applications/Setapp"
        "/System/Applications"
        "/System/Applications/Utilities"
        "$HOME/Applications"
    )

    local app_root app_path info bid
    for app_root in "${app_roots[@]}"; do
        [[ -d "$app_root" ]] || continue
        for app_path in "$app_root"/*.app; do
            [[ -d "$app_path" ]] || continue
            info="$app_path/Contents/Info.plist"
            [[ -f "$info" ]] || continue
            bid=$(plutil -extract CFBundleIdentifier raw "$info" 2> /dev/null || echo "")
            if [[ -n "$bid" && "$bid" != "(null)" ]]; then
                printf '%s\n' "$bid"
            fi
        done
    done
}

# Scans a directory for items whose basename matches reverse-DNS bundle ID
# format and the search term. Appends qualifying bundle IDs to $results_file.
_scan_dir_for_orphan_bundle() {
    local scan_dir="$1"
    local search_lower="$2"
    local installed_ids_file="$3"
    local results_file="$4"

    [[ -d "$scan_dir" ]] || return 0

    local item base base_lower
    while IFS= read -r -d '' item; do
        base=$(basename "$item")
        base="${base%.savedState}"
        base="${base%.binarycookies}"
        base="${base%.plist}"
        base="${base%.sfl4}"

        [[ "$base" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]] || continue

        base_lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
        [[ "$base_lower" == *"$search_lower"* ]] || continue

        [[ "$base" == com.apple.* ]] && continue

        if grep -Fxq "$base" "$installed_ids_file" 2> /dev/null; then
            continue
        fi

        if ! should_protect_from_uninstall "$base" 2> /dev/null; then
            printf '%s\n' "$base" >> "$results_file"
        fi
    done < <(find "$scan_dir" -maxdepth 1 \( -type d -o -type f \) -print0 2> /dev/null)

    return 0
}

# Pick the best candidate from a results file. Prefers the shortest name,
# which is usually the main app (e.g. "com.tencent.qq" vs "com.tencent.qqexdoc").
_pick_best_bundle_id() {
    local results_file="$1"
    [[ -f "$results_file" && -s "$results_file" ]] || return 1

    sort -u "$results_file" | awk '{ print length($0), $0 }' | sort -n | head -1 | awk '{ print $2 }'
}

# Resolve a bundle ID for an app that was already manually deleted.
resolve_bundle_id_for_deleted_app() {
    local search_term="$1"
    [[ -z "$search_term" ]] && return 1

    local search_lower
    search_lower=$(echo "$search_term" | tr '[:upper:]' '[:lower:]')

    # Build installed bundle ID set once for fast lookup.
    local installed_ids_file results_file best
    installed_ids_file=$(create_temp_file)
    results_file=$(create_temp_file)
    _build_installed_bundle_ids > "$installed_ids_file"

    # Pre-declare locals for Bash 3.2 subshell compatibility.
    local app_path app_name app_name_lower bundle_id hit_path
    local mdfind_results mdfind_hit plist base base_lower
    local cask cask_lower cask_list cask_app_path found_app
    local receipts_dir receipt

    # ---- Method 1: mdfind Spotlight metadata ----
    if command -v mdfind > /dev/null 2>&1; then
        mdfind_results=$(mdfind "kMDItemKind == 'Application'" 2> /dev/null | head -20) || true
        while IFS= read -r app_path; do
            [[ -n "$app_path" ]] || continue
            [[ "$app_path" == *.app ]] || continue
            app_name=$(basename "$app_path" .app)
            app_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$app_name_lower" == *"$search_lower"* ]]; then
                bundle_id=$(mdls -name kMDItemCFBundleIdentifier -raw "$app_path" 2> /dev/null || echo "")
                if [[ -n "$bundle_id" && "$bundle_id" != "(null)" ]]; then
                    bundle_id="${bundle_id//|/-}"
                    if [[ "$bundle_id" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
                        if ! should_protect_from_uninstall "$bundle_id" 2> /dev/null; then
                            rm -f "$installed_ids_file" "$results_file"
                            printf '%s\n' "$bundle_id"
                            return 0
                        fi
                    fi
                fi
            fi
        done <<< "$mdfind_results"

        mdfind_hit=$(mdfind "kMDItemDisplayName == '*${search_term}*'c" 2> /dev/null | head -5) || true
        while IFS= read -r hit_path; do
            [[ -n "$hit_path" ]] || continue
            bundle_id=$(mdls -name kMDItemCFBundleIdentifier -raw "$hit_path" 2> /dev/null || echo "")
            if [[ -n "$bundle_id" && "$bundle_id" != "(null)" ]]; then
                bundle_id="${bundle_id//|/-}"
                if [[ "$bundle_id" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
                    if ! should_protect_from_uninstall "$bundle_id" 2> /dev/null; then
                        rm -f "$installed_ids_file" "$results_file"
                        printf '%s\n' "$bundle_id"
                        return 0
                    fi
                fi
            fi
        done <<< "$mdfind_hit"
    fi

    # ---- Method 2: Preferences plist filenames (collect all, pick best) ----
    local prefs_dir="$HOME/Library/Preferences"
    if [[ -d "$prefs_dir" ]]; then
        while IFS= read -r -d '' plist; do
            base=$(basename "$plist" .plist)
            [[ "$base" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]] || continue
            base_lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
            [[ "$base_lower" == *"$search_lower"* ]] || continue
            [[ "$base" == com.apple.* ]] && continue
            if grep -Fxq "$base" "$installed_ids_file" 2> /dev/null; then continue; fi
            if ! should_protect_from_uninstall "$base" 2> /dev/null; then
                printf '%s\n' "$base" >> "$results_file"
            fi
        done < <(find "$prefs_dir" -maxdepth 1 -name "*.plist" -print0 2> /dev/null)

        best=$(_pick_best_bundle_id "$results_file") || true
        if [[ -n "$best" ]]; then
            rm -f "$installed_ids_file" "$results_file"
            printf '%s\n' "$best"
            return 0
        fi
    fi

    # ---- Method 3: Containers directory ----
    _scan_dir_for_orphan_bundle "$HOME/Library/Containers" "$search_lower" "$installed_ids_file" "$results_file"
    best=$(_pick_best_bundle_id "$results_file") || true
    if [[ -n "$best" ]]; then
        rm -f "$installed_ids_file" "$results_file"
        printf '%s\n' "$best"
        return 0
    fi

    # ---- Method 4: Caches directory ----
    _scan_dir_for_orphan_bundle "$HOME/Library/Caches" "$search_lower" "$installed_ids_file" "$results_file"
    best=$(_pick_best_bundle_id "$results_file") || true
    if [[ -n "$best" ]]; then
        rm -f "$installed_ids_file" "$results_file"
        printf '%s\n' "$best"
        return 0
    fi

    # ---- Method 5: Homebrew cask list ----
    if command -v brew > /dev/null 2>&1; then
        cask_list=$(brew list --cask -1 2> /dev/null) || true
        while IFS= read -r cask; do
            [[ -n "$cask" ]] || continue
            cask_lower=$(echo "$cask" | tr '[:upper:]' '[:lower:]')
            if [[ "$cask_lower" == *"$search_lower"* ]]; then
                cask_app_path="/opt/homebrew/Caskroom/${cask}"
                [[ ! -d "$cask_app_path" ]] && cask_app_path="/usr/local/Caskroom/${cask}"
                if [[ -d "$cask_app_path" ]]; then
                    found_app=$(find "$cask_app_path" -maxdepth 3 -name "*.app" -print0 2> /dev/null | tr '\0' '\n' | head -1) || true
                    if [[ -n "$found_app" && -d "$found_app" ]]; then
                        bundle_id=$(plutil -extract CFBundleIdentifier raw "$found_app/Contents/Info.plist" 2> /dev/null || echo "")
                        if [[ -n "$bundle_id" && "$bundle_id" != "(null)" ]]; then
                            bundle_id="${bundle_id//|/-}"
                            if [[ "$bundle_id" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
                                if ! should_protect_from_uninstall "$bundle_id" 2> /dev/null; then
                                    rm -f "$installed_ids_file" "$results_file"
                                    printf '%s\n' "$bundle_id"
                                    return 0
                                fi
                            fi
                        fi
                    fi
                fi
            fi
        done <<< "$cask_list"
    fi

    # ---- Method 6: pkg receipts ----
    receipts_dir="/private/var/db/receipts"
    if [[ -d "$receipts_dir" ]]; then
        while IFS= read -r -d '' receipt; do
            base=$(basename "$receipt" .plist)
            base="${base%.bom}"
            base_lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
            [[ "$base_lower" == *"$search_lower"* ]] || continue
            [[ "$base" == com.apple.* ]] && continue
            [[ "$base" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]] || continue
            if ! should_protect_from_uninstall "$base" 2> /dev/null; then
                rm -f "$installed_ids_file" "$results_file"
                printf '%s\n' "$base"
                return 0
            fi
        done < <(find "$receipts_dir" -maxdepth 1 \( -name "*${search_term}*.plist" -o -name "*${search_term}*.bom" \) -print0 2> /dev/null)
    fi

    rm -f "$installed_ids_file" "$results_file"
    return 1
}

# Given a bundle ID, try to produce a human-readable display name.
resolve_app_name_for_bundle_id() {
    local bundle_id="$1"
    [[ -z "$bundle_id" ]] && return 1

    local hit display_name app_name

    if command -v mdfind > /dev/null 2>&1; then
        hit=$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1) || true
        if [[ -n "$hit" ]]; then
            display_name=$(mdls -name kMDItemDisplayName -raw "$hit" 2> /dev/null || echo "")
            if [[ -n "$display_name" && "$display_name" != "(null)" ]]; then
                display_name="${display_name%.app}"
                printf '%s\n' "$display_name"
                return 0
            fi
            app_name=$(basename "$hit" .app 2> /dev/null || echo "")
            if [[ -n "$app_name" && "$app_name" != "(null)" ]]; then
                printf '%s\n' "$app_name"
                return 0
            fi
        fi
    fi

    local last_component="${bundle_id##*.}"
    if [[ -n "$last_component" && ${#last_component} -ge 2 ]]; then
        local first_char="${last_component:0:1}"
        local rest="${last_component:1}"
        first_char=$(echo "$first_char" | tr '[:lower:]' '[:upper:]')
        printf '%s%s\n' "$first_char" "$rest"
        return 0
    fi

    printf '%s\n' "$bundle_id"
    return 0
}
