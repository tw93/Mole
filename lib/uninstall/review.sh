#!/bin/bash
# Personal-data choices refine an already discovered and protected uninstall plan.

_uninstall_disposable_leftover() {
    case "$1" in
        # Data that only lives under Caches: Spotify offline music, Raycast
        # clipboard-history images, Mullvad Browser's profile root, Buzz's
        # Whisper models, installed plugins and user CSS.
        "$HOME/Library/Caches/com.spotify.client" | "$HOME/Library/Caches/com.spotify.client/"*) return 1 ;;
        "$HOME/Library/Caches/com.raycast.macos" | "$HOME/Library/Caches/com.raycast.macos/"*) return 1 ;;
        "$HOME/Library/Caches/MullvadBrowser" | "$HOME/Library/Caches/MullvadBrowser/"*) return 1 ;;
        "$HOME/Library/Caches/Buzz" | "$HOME/Library/Caches/Buzz/"*) return 1 ;;
        "$HOME/Library/Caches/"* | "$HOME/Library/Logs/"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Data that --with-data still leaves unselected; D lists it like any other
# personal path. Browser profiles hold passwords, history and extensions, and
# the CLI cannot prove that no other installed app claims an App Group
# container. Profile roots the uninstall scan can offer (the Chromium vendors'
# entries also cover their Beta, Dev and Canary channels) and everything below
# them, compared case-insensitively because APFS folds case. Game and ROM
# libraries that sit inside one app's data root stay unselected too: CrossOver
# and Whisky bottles hold installed Windows games, OpenEmu holds ROMs and saves.
# So do virtual machine libraries: the UTM container and VirtualBuddy's
# Application Support folder hold the VM disks.
_uninstall_data_preselect_holdback() {
    local path home
    mole_ascii_lowercase path "$1"
    mole_ascii_lowercase home "$HOME"
    case "$path" in
        "$home/library/group containers/"*) return 0 ;;
        "$home/library/containers/com.isaacmarovitz.whisky" | \
            "$home/library/containers/com.isaacmarovitz.whisky/"* | \
            "$home/library/containers/com.utmapp.utm" | \
            "$home/library/containers/com.utmapp.utm/"*)
            return 0
            ;;
    esac
    # Browser profile roots keyed by the browser's own bundle id (Mole Mac's
    # `BrowserDataPolicy`): passwords, history and extensions live there, and
    # the own-identifier default would otherwise start with them selected.
    local browser root
    for browser in net.imput.helium company.thebrowser.browser com.duckduckgo.macos.browser \
        com.ardia.browser com.sigmaos.sigmaos.macos com.apple.safaritechnologypreview; do
        for root in "$home/library/application support/$browser" "$home/library/containers/$browser"; do
            [[ "$path" == "$root" || "$path" == "$root/"* ]] && return 0
        done
    done
    local support="$home/library/application support"
    case "$path" in
        "$support/google/chrome"* | "$support/bravesoftware"* | \
            "$support/microsoft edge"* | "$support/com.operasoftware.opera"* | \
            "$support/chromium" | "$support/chromium/"* | \
            "$support/vivaldi" | "$support/vivaldi/"* | \
            "$support/arc" | "$support/arc/"* | \
            "$support/firefox" | "$support/firefox/"* | \
            "$support/zen" | "$support/zen/"* | \
            "$support/crossover" | "$support/crossover/"* | \
            "$support/virtualbuddy" | "$support/virtualbuddy/"* | \
            "$support/openemu" | "$support/openemu/"* | \
            "$support/dolphin" | "$support/dolphin/"* | \
            "$support/pcsx2" | "$support/pcsx2/"* | \
            "$support/retroarch" | "$support/retroarch/"* | \
            "$support/prismlauncher" | "$support/prismlauncher/"* | \
            "$support/minecraft" | "$support/minecraft/"* | \
            "$support/citra" | "$support/citra/"* | \
            "$support/cemu" | "$support/cemu/"* | \
            "$support/ryujinx" | "$support/ryujinx/"* | \
            "$support/ppsspp" | "$support/ppsspp/"* | \
            "$support/rpcs3" | "$support/rpcs3/"* | \
            "$support/multimc" | "$support/multimc/"* | \
            "$support/atlauncher" | "$support/atlauncher/"*)
            return 0
            ;;
    esac
    return 1
}

# Data keyed by the app's own identifier, which a default uninstall starts
# with selected: `<id>` exactly (or `<id>.plist`, `.binarycookies`,
# `.savedState`) directly under the per-app roots of ~/Library and the user's
# Darwin cache and temp folders, where <id> is the app's bundle id or the id of
# an extension or XPC service embedded in it that starts with `<bundle id>.`
# (Mole Mac's rule): a service several apps of a vendor embed, such as
# Office's shared ones, is not this app's alone. An uninstall that left these
# behind had every other cleaner report the app's leftovers (2026-11-27, a
# Gemini uninstall kept nine such paths). Name-matched folders
# (`Application Support/Code`, a dot folder in the home) stay unselected: the
# name can be shared, and they are where tools keep user-made content. A dot
# after the id is never taken as ownership, since it does not tell another
# product from a subordinate domain.
_uninstall_own_identifier_data() {
    local path="$1" id="$2" embedded="${3:-}" parent leaf key candidate lowered
    [[ "$id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+$ ]] || return 1
    parent="${path%/*}" leaf="${path##*/}" key="$leaf"
    case "$parent" in
        "$HOME/Library/Preferences")
            [[ "$leaf" == *.plist ]] || return 1
            key="${leaf%.plist}"
            ;;
        "$HOME/Library/Saved Application State")
            [[ "$leaf" == *.savedState ]] || return 1
            key="${leaf%.savedState}"
            ;;
        "$HOME/Library/HTTPStorages" | "$HOME/Library/Cookies") key="${leaf%.binarycookies}" ;;
        "$HOME/Library/Application Support" | "$HOME/Library/WebKit" | \
            "$HOME/Library/Containers" | "$HOME/Library/Application Scripts") ;;
        /var/folders/*/*/C | /var/folders/*/*/T | /private/var/folders/*/*/C | /private/var/folders/*/*/T)
            # `*` crosses `/` in a case pattern: hold the folder to its depth.
            [[ "$parent" =~ ^(/private)?/var/folders/[^/]+/[^/]+/[CT]$ ]] || return 1
            ;;
        *) return 1 ;;
    esac
    local own
    mole_ascii_lowercase key "$key"
    mole_ascii_lowercase own "$id"
    [[ "$key" == "$own" ]] && return 0
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        mole_ascii_lowercase lowered "$candidate"
        [[ "$lowered" == "$own."* && "$key" == "$lowered" ]] && return 0
    done <<< "$embedded"
    return 1
}

# shellcheck disable=SC2154  # Arrays belong to the calling batch preview scope.
_uninstall_prepare_data_review() {
    local detail name app id total encoded remainder files path automatic personal i=0 embedded preselect
    for detail in "${_review_original_details[@]}"; do
        IFS='|' read -r name app id total encoded remainder <<< "$detail"
        embedded=""
        if [[ "${MOLE_UNINSTALL_WITH_DATA:-0}" == "own" && -d "$app" ]]; then
            embedded=$(_mole_uninstall_embedded_bundle_ids "$app" "$id" 2> /dev/null) || embedded=""
        fi
        files=$(decode_file_list "$encoded" "$name")
        local -a paths=()
        while IFS= read -r path; do
            [[ -z "$path" ]] || paths+=("$path")
        done <<< "$files"
        files=$(mole_filter_nested_paths "${paths[@]+"${paths[@]}"}") || return $?
        automatic="" personal=""
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            if _uninstall_disposable_leftover "$path"; then
                automatic=$(append_line "$automatic" "$path")
            else
                personal=$(append_line "$personal" "$path")
                if ! mole_identity_in_list "$path" "${_review_personal_paths[@]+"${_review_personal_paths[@]}"}"; then
                    _review_personal_paths+=("$path")
                    # The starting selection: the app's own identifier data
                    # by default, every path with --with-data, none with
                    # --keep-data. D can still change any of them before Enter.
                    preselect=0
                    case "${MOLE_UNINSTALL_WITH_DATA:-0}" in
                        1) preselect=1 ;;
                        own) ! _uninstall_own_identifier_data "$path" "$id" "$embedded" || preselect=1 ;;
                    esac
                    if [[ "$preselect" == "1" ]] && ! _uninstall_data_preselect_holdback "$path"; then
                        _review_selected_paths+=("$path")
                    fi
                fi
            fi
        done <<< "$files"
        _review_auto_files[i]="$automatic"
        _review_personal_files[i]="$personal"
        # The scan already measured this bundle for the current review.
        # No persisted size or previous invocation is reused.
        _review_app_sizes[i]="$total"
        i=$((i + 1))
    done
    _uninstall_apply_data_selection
}

_uninstall_apply_data_selection() {
    local detail name app id old_total encoded remainder files path size rc i=0
    local -a next_details=()
    local next_total=0
    for detail in "${_review_original_details[@]}"; do
        IFS='|' read -r name app id old_total encoded remainder <<< "$detail"
        files="${_review_auto_files[i]}"
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            if mole_identity_in_list "$path" "${_review_selected_paths[@]+"${_review_selected_paths[@]}"}"; then
                files=$(append_line "$files" "$path")
            fi
        done <<< "${_review_personal_files[i]}"
        rc=0
        size=$(calculate_total_size "$files") || rc=$?
        mole_rc_signal "$rc" && return "$rc"
        [[ $rc -eq 0 && "$size" =~ ^[0-9]+$ ]] || size=0
        size=$((size + _review_app_sizes[i]))
        encoded=$(printf '%s' "$files" | base64 | tr -d '\n') || return 1
        next_details+=("$name|$app|$id|$size|$encoded|$remainder")
        next_total=$((next_total + size))
        i=$((i + 1))
    done
    app_details=("${next_details[@]}")
    total_estimated_size=$next_total
}

_uninstall_choose_personal_data() {
    local -a labels=() indices=() chosen=()
    local path display idx=0 selection rc=0
    for path in "${_review_personal_paths[@]}"; do
        display="$path"
        # shellcheck disable=SC2088  # Display HOME as a literal tilde, never expand it.
        [[ "$path" != "$HOME/"* ]] || display="~/${path#"$HOME/"}"
        labels+=("$(mole_terminal_safe_text "$display")")
        if mole_identity_in_list "$path" "${_review_selected_paths[@]+"${_review_selected_paths[@]}"}"; then
            indices+=("$idx")
        fi
        idx=$((idx + 1))
    done
    local MOLE_PRESELECTED_INDICES=""
    # The app selector's metadata does not describe these path rows.
    local MOLE_MENU_META_EPOCHS="" MOLE_MENU_META_SIZEKB="" MOLE_MENU_FILTER_NAMES=""
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    local MOLE_MENU_IGNORE_INITIAL_ENTER=false
    if [[ ${#indices[@]} -gt 0 ]]; then
        MOLE_PRESELECTED_INDICES=$(
            IFS=,
            printf '%s' "${indices[*]}"
        )
    fi
    # Unlike app selection, Enter on an empty data selection must keep everything.
    local _MOLE_MENU_KEEP_EMPTY=true
    local _MOLE_MENU_SELECT_ALL=true
    paginated_multi_select "Personal data to remove" "${labels[@]}" || rc=$?
    mole_rc_timeout_or_signal "$rc" && return "$rc"
    if [[ $rc -ne 0 ]]; then
        [[ "${_MOLE_MENU_USER_QUIT:-0}" == 1 ]] && return 0
        return "$rc"
    fi
    selection="${MOLE_SELECTION_RESULT:-}"
    indices=()
    IFS=, read -ra indices <<< "$selection"
    for idx in "${indices[@]+"${indices[@]}"}"; do
        [[ "$idx" =~ ^[0-9]+$ && ${#idx} -lt 9 ]] || return 1
        idx=$((10#$idx))
        [[ $idx -lt ${#_review_personal_paths[@]} ]] || return 1
        chosen+=("${_review_personal_paths[idx]}")
    done
    _review_selected_paths=("${chosen[@]+"${chosen[@]}"}")
    _uninstall_apply_data_selection
}
