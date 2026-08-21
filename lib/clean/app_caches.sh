#!/bin/bash
# User GUI Applications Cleanup Module (desktop apps, media, utilities).
set -euo pipefail

_xcode_cleanup_process_state() {
    xcode_build_tooling_process_state
}

_simulator_cleanup_process_state() {
    if declare -f _coresimulator_activity_state > /dev/null 2>&1; then
        _coresimulator_activity_state
        return $?
    fi

    mole_pgrep_any \
        -x "Xcode" \
        -x "Simulator" \
        -x "xcodebuild" \
        -x "xctest" \
        -x "XCTRunner"
}

_xcode_cleanup_skip_reason() {
    if [[ "$1" -eq 0 ]]; then
        printf 'Xcode or build tooling running\n'
    else
        printf 'process state unknown\n'
    fi
}

_app_cache_cleanup_directories_exist() {
    local target
    for target in "$@"; do
        [[ -d "$target" ]] || continue
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

_xcode_app_cache_delete_guard_allows() {
    # Same mapping _xcode_cleanup_skip_reason applies (state 0 running, state 2
    # unknown; state 1 already returned), without its command substitution. The
    # scan-stage callers still use that helper, where one fork per section is
    # free; this one runs per delete candidate.
    mole_clean_process_guard _xcode_cleanup_process_state "Xcode or build tooling running"
}

_simulator_app_cache_delete_guard_allows() {
    mole_clean_process_guard _simulator_cleanup_process_state "Simulator or CoreSimulator running"
}

_final_cut_pro_delete_guard_allows() {
    mole_clean_process_guard final_cut_pro_is_running "Final Cut Pro started"
}

_defer_app_cache_guard_family() {
    case "$1" in
        _simulator_app_cache_delete_guard_allows) mole_defer_cleanup_family "Simulator" ;;
        _final_cut_pro_delete_guard_allows) mole_defer_cleanup_family "Final Cut Pro" ;;
        _autodesk_cache_delete_guard_allows) mole_defer_cleanup_family "Autodesk" ;;
        *) mole_defer_cleanup_family "Xcode" ;;
    esac
}

_app_cache_safe_clean_guarded() {
    local delete_guard="$1"
    local display_name="$2"
    shift 2
    local _MOLE_CLEAN_GUARD_REASON="process state changed"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! "$delete_guard"; then
            mole_report_guard_stop "$display_name" _defer_app_cache_guard_family "$delete_guard"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded "$delete_guard" "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        mole_report_guard_stop "$display_name" _defer_app_cache_guard_family "$delete_guard"
        return 1
    fi
    return "$guarded_rc"
}

# Xcode DerivedData cleanup with project count and size reporting.
# Fully regenerated on next build, safe to remove.
clean_xcode_derived_data() {
    local dd_dir="$HOME/Library/Developer/Xcode/DerivedData"

    [[ -d "$dd_dir" ]] || return 0

    # Count projects before recording an active-process skip, so an empty
    # DerivedData root stays silent.
    local -a projects=()
    local dir
    for dir in "$dd_dir"/*; do
        [[ -d "$dir" ]] || continue
        if should_protect_path "$dir" || is_path_whitelisted "$dir" || holds_compiled_model_cache "$dir"; then
            continue
        fi
        projects+=("$dir")
    done

    local project_count=${#projects[@]}
    [[ $project_count -eq 0 ]] && return 0

    # Only a conclusive "no matching process" result authorizes cleanup.
    local xcode_state=0
    _xcode_cleanup_process_state || xcode_state=$?
    if [[ $xcode_state -ne 1 ]]; then
        if [[ $xcode_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode DerivedData · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 0
    fi

    local project_label="projects"
    [[ $project_count -eq 1 ]] && project_label="project"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Measure and register only the filtered project set. Sizing the parent
        # would include protected or whitelisted siblings that real cleanup
        # intentionally leaves untouched.
        local size_kb=0
        local dir_size_kb=0
        local dry_run_count=0
        local dry_run_stopped_reason=""
        local dry_run_seen=0
        # Sizing every project means one du per entry plus a process probe on
        # each side of it. On a real DerivedData that is tens of seconds with
        # nothing on screen, which reads as a freeze.
        start_section_spinner "Measuring Xcode DerivedData, 0/${project_count}..."
        for dir in "${projects[@]}"; do
            dry_run_seen=$((dry_run_seen + 1))
            start_section_spinner "Measuring Xcode DerivedData, ${dry_run_seen}/${project_count}..."
            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                dry_run_stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
                break
            fi
            local size_rc=0
            dir_size_kb=$(get_path_size_kb "$dir" 2> /dev/null) || size_rc=$?
            if [[ $size_rc -ne 0 ]]; then
                stop_section_spinner
                _mole_record_clean_cancellation "$size_rc"
                return "$size_rc"
            fi
            [[ "$dir_size_kb" =~ ^[0-9]+$ ]] || dir_size_kb=0
            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                dry_run_stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
                break
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$dir_size_kb" 1 true || continue
            fi
            size_kb=$((size_kb + dir_size_kb))
            dry_run_count=$((dry_run_count + 1))
        done
        stop_section_spinner
        if [[ $dry_run_count -gt 0 ]]; then
            project_label="projects"
            [[ $dry_run_count -eq 1 ]] && project_label="project"
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode DerivedData · ${dry_run_count} ${project_label}, ${size_human}"
            note_activity
        fi
        if [[ -n "$dry_run_stopped_reason" ]]; then
            if [[ "$dry_run_stopped_reason" == "process state unknown" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode DerivedData · stopped (${dry_run_stopped_reason})"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
        fi
        return 0
    fi

    # Remove all project build dirs using safe_remove.
    local removed=0
    local removed_size_kb=0
    local stopped_reason=""
    local seen=0
    # Each project costs a du, two process probes, and the removal itself, so a
    # large DerivedData runs for tens of seconds. Without this the section
    # prints nothing until every project is gone.
    start_section_spinner "Removing Xcode DerivedData, 0/${project_count}..."
    for dir in "${projects[@]}"; do
        seen=$((seen + 1))
        start_section_spinner "Removing Xcode DerivedData, ${seen}/${project_count}..."
        xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -ne 1 ]]; then
            stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
            break
        fi

        local dir_size_kb=0
        local size_rc=0
        dir_size_kb=$(get_path_size_kb "$dir" 2> /dev/null) || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            stop_section_spinner
            _mole_record_clean_cancellation "$size_rc"
            return "$size_rc"
        fi
        [[ "$dir_size_kb" =~ ^[0-9]+$ ]] || dir_size_kb=0

        # Sizing is timeout-bounded but can still take long enough for a build
        # to start. Recheck at the deletion boundary, not only before du.
        xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -ne 1 ]]; then
            stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
            break
        fi
        if safe_remove "$dir" "true" "$dir_size_kb"; then
            removed=$((removed + 1))
            removed_size_kb=$((removed_size_kb + dir_size_kb))
        fi
    done
    stop_section_spinner

    if [[ $removed -gt 0 ]]; then
        project_label="projects"
        [[ $removed -eq 1 ]] && project_label="project"
        local size_human
        size_human=$(bytes_to_human "$((removed_size_kb * 1024))")
        local line_color
        line_color=$(cleanup_result_color_kb "$removed_size_kb" 2> /dev/null || echo "$GREEN")
        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode DerivedData · ${removed} ${project_label}, ${line_color}${size_human}${NC}"
        files_cleaned=$((${files_cleaned:-0} + removed))
        total_size_cleaned=$((${total_size_cleaned:-0} + removed_size_kb))
        total_items=$((${total_items:-0} + 1))
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        if [[ "$stopped_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode DerivedData · stopped (${stopped_reason})"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
    fi
}
# Xcode and iOS tooling.
clean_xcode_tools() {
    local simulator_has_targets=false
    if mole_cleanup_targets_exist \
        "$HOME/Library/Developer/CoreSimulator/Caches"/* \
        "$HOME/Library/Developer/CoreSimulator/Devices"/*/data/tmp/* \
        "$HOME/Library/Logs/CoreSimulator"/*; then
        simulator_has_targets=true
    fi

    if [[ "$simulator_has_targets" == "true" ]]; then
        # Probe errors are unknown, never permission to clean active tool state.
        local simulator_state=0
        _simulator_cleanup_process_state || simulator_state=$?
        if [[ $simulator_state -eq 1 ]]; then
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "Simulator caches" \
                ~/Library/Developer/CoreSimulator/Caches/* \
                "Simulator cache" || return 0
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "Simulator temp files" \
                ~/Library/Developer/CoreSimulator/Devices/*/data/tmp/* \
                "Simulator temp files" || return 0
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "CoreSimulator logs" \
                ~/Library/Logs/CoreSimulator/* \
                "CoreSimulator logs" || return 0
        else
            if [[ $simulator_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Simulator caches · skipped (process state unknown)"
                note_activity
            else
                mole_defer_cleanup_family "Simulator"
            fi
        fi
    fi

    local xcode_cache_has_targets=false
    local xcode_build_has_targets=false
    mole_cleanup_targets_exist \
        "$HOME/Library/Caches/com.apple.dt.Xcode"/* && xcode_cache_has_targets=true
    if mole_cleanup_targets_exist "$HOME/Library/Developer/Xcode/Products"/* ||
        _app_cache_cleanup_directories_exist "$HOME/Library/Developer/Xcode/DerivedData"/*; then
        xcode_build_has_targets=true
    fi

    if [[ "$xcode_cache_has_targets" == "true" || "$xcode_build_has_targets" == "true" ]]; then
        local xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -eq 1 ]]; then
            if [[ "$xcode_cache_has_targets" == "true" ]]; then
                _app_cache_safe_clean_guarded \
                    _xcode_app_cache_delete_guard_allows \
                    "Xcode cache" \
                    ~/Library/Caches/com.apple.dt.Xcode/* \
                    "Xcode cache" || return 0
            fi

            # The cache pass may take long enough for the separate build
            # candidates to disappear. Revalidate before another process gate
            # so a completed cache-only pass never reports a deferred build.
            xcode_build_has_targets=false
            if mole_cleanup_targets_exist "$HOME/Library/Developer/Xcode/Products"/* ||
                _app_cache_cleanup_directories_exist "$HOME/Library/Developer/Xcode/DerivedData"/*; then
                xcode_build_has_targets=true
            fi
            [[ "$xcode_build_has_targets" == "true" ]] || return 0

            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                if [[ $xcode_state -eq 2 ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode build products/DerivedData · stopped (process state unknown)"
                    note_activity
                else
                    mole_defer_cleanup_family "Xcode"
                fi
                return 0
            fi
            _app_cache_safe_clean_guarded \
                _xcode_app_cache_delete_guard_allows \
                "Xcode build products" \
                ~/Library/Developer/Xcode/Products/* \
                "Xcode build products" || return 0
            clean_xcode_derived_data || return $?
        else
            if [[ $xcode_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode cache/build products · skipped (process state unknown)"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
        fi
    fi
}
# Remove extension directories that VS Code / Cursor have marked obsolete.
# Each editor writes a .obsolete JSON file under its extensions root whose keys
# are stale extension directory names left behind after an extension update.
clean_editor_obsolete_extensions() {
    local -a editor_roots=(
        "$HOME/.vscode/extensions|VS Code"
        "$HOME/.vscode-insiders/extensions|VS Code Insiders"
        "$HOME/.cursor/extensions|Cursor"
    )
    local entry ext_root editor_label obsolete_file key target
    for entry in "${editor_roots[@]}"; do
        ext_root="${entry%%|*}"
        editor_label="${entry##*|}"
        obsolete_file="$ext_root/.obsolete"
        [[ -f "$obsolete_file" ]] || continue

        while IFS= read -r key; do
            # Each key must be a plain direct-child directory name; reject
            # anything that could escape the extensions root.
            case "$key" in
                "" | "." | ".." | */*) continue ;;
            esac
            target="$ext_root/$key"
            [[ -d "$target" ]] || continue
            safe_clean "$target" "Obsolete $editor_label extension"
        done < <(plutil -p "$obsolete_file" 2> /dev/null |
            sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*=>.*/\1/p')
    done
}
# Code editors.
clean_code_editors() {
    safe_clean ~/Library/Application\ Support/Code/logs/* "VS Code logs"
    safe_clean ~/Library/Application\ Support/Code/Cache/* "VS Code cache"
    safe_clean ~/Library/Application\ Support/Code/CachedExtensions/* "VS Code extension cache"
    safe_clean ~/Library/Application\ Support/Code/CachedData/* "VS Code data cache"
    safe_clean ~/Library/Application\ Support/Code/WebStorage/*/CacheStorage/* "VS Code webview cache"
    safe_clean ~/Library/Caches/com.sublimetext.*/* "Sublime Text cache"
    safe_clean ~/Library/Caches/Zed/* "Zed cache"
    # Zed npm caches: node/cache (system-node scratch) and node/node-v*/cache
    # (per-version managed runtime, see #88); keep editor state under db/ untouched.
    safe_clean ~/Library/Application\ Support/Zed/node/cache/* "Zed npm cache"
    safe_clean ~/Library/Application\ Support/Zed/node/node-v*/cache/* "Zed npm cache"
    safe_clean ~/Library/Logs/Zed/* "Zed logs"
    clean_editor_obsolete_extensions
    # CodeBuddy Extension (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddyExtension ]]; then
        safe_clean ~/Library/Application\ Support/CodeBuddyExtension/Cache/* "CodeBuddy Extension cache"
        safe_clean ~/Library/Application\ Support/CodeBuddyExtension/logs/* "CodeBuddy Extension logs"
    fi
    # CodeBuddy CN (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddy\ CN ]]; then
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/Cache/* "CodeBuddy CN cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/CachedData/* "CodeBuddy CN cached data"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/CachedExtensionVSIXs/* "CodeBuddy CN extension cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/Code\ Cache/* "CodeBuddy CN code cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/GPUCache/* "CodeBuddy CN GPU cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/DawnGraphiteCache/* "CodeBuddy CN Dawn cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/DawnWebGPUCache/* "CodeBuddy CN WebGPU cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/logs/* "CodeBuddy CN logs"
    fi
}
# Communication apps.
clean_communication_apps() {
    safe_clean ~/Library/Application\ Support/discord/Cache/* "Discord cache"
    safe_clean ~/Library/Application\ Support/legcord/Cache/* "Legcord cache"
    safe_clean ~/Library/Application\ Support/Slack/Cache/* "Slack cache"
    safe_clean ~/Library/Caches/us.zoom.xos/* "Zoom cache"
    safe_clean ~/Library/Caches/com.tencent.xinWeChat/* "WeChat cache"
    safe_clean ~/Library/Caches/ru.keepcoder.Telegram/* "Telegram cache"

    safe_clean ~/Library/Caches/com.microsoft.teams2/* "Microsoft Teams cache"
    safe_clean ~/Library/Caches/net.whatsapp.WhatsApp/* "WhatsApp cache"
    safe_clean ~/Library/Caches/com.skype.skype/* "Skype cache"
    safe_clean ~/Library/Caches/com.tencent.meeting/* "Tencent Meeting cache"
    safe_clean ~/Library/Caches/com.tencent.WeWorkMac/* "WeCom cache"
    safe_clean ~/Library/Caches/com.tencent.qq/* "QQ cache"
    safe_clean ~/Library/Caches/com.feishu.*/* "Feishu cache"
    if [[ -d ~/Library/Application\ Support/Microsoft/Teams ]]; then
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Cache/* "Microsoft Teams legacy cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Application\ Cache/* "Microsoft Teams legacy application cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Code\ Cache/* "Microsoft Teams legacy code cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/GPUCache/* "Microsoft Teams legacy GPU cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/logs/* "Microsoft Teams legacy logs"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/tmp/* "Microsoft Teams legacy temp files"
    fi
}
# DingTalk.
clean_dingtalk() {
    safe_clean ~/Library/Caches/dd.work.exclusive4aliding/* "DingTalk iDingTalk cache"
    safe_clean ~/Library/Caches/com.alibaba.AliLang.osx/* "AliLang security component"
    if [[ -d ~/Library/Application\ Support/iDingTalk ]]; then
        safe_clean ~/Library/Application\ Support/iDingTalk/log/* "DingTalk logs"
        safe_clean ~/Library/Application\ Support/iDingTalk/holmeslogs/* "DingTalk holmes logs"
    fi
}
# AI assistants.
clean_ai_apps() {
    safe_clean ~/Library/Caches/com.openai.chat/* "ChatGPT cache"
    safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Claude desktop cache"
    safe_clean ~/Library/Logs/Claude/* "Claude logs"
    safe_clean ~/Library/Caches/com.lmstudio.lmstudio/* "LM Studio cache"
    # LM Studio <=0.3.5 used ~/.cache/lm-studio as its complete home directory,
    # including models, presets, chats, and runtime state. LM Studio moved new
    # installs to ~/.lmstudio in 0.3.6, but existing data is not migrated, so
    # never recursively clean the legacy root. The Library/Caches target above
    # is the only path treated as an auto-rebuildable cache here.
    safe_clean ~/Library/Caches/CCTClearcutLogger "Google Clearcut logs"
    if [[ -d "$HOME/Library/Application Support/Codex" || -d "$HOME/Library/Logs/com.openai.codex" ]]; then
        debug_log "Codex Desktop state left intact by default"
    fi
}
# Design and creative tools.
clean_design_tools() {
    safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/* "Sketch cache"
    safe_clean ~/Library/Application\ Support/com.bohemiancoding.sketch3/cache/* "Sketch app cache"
    safe_clean ~/Library/Caches/Adobe/* "Adobe cache"
    safe_clean ~/Library/Caches/com.adobe.*/* "Adobe app caches"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Application\ Support/Adobe/Common/Media\ Cache\ Files/* "Adobe media cache files"
}
# Video editing tools.
final_cut_pro_is_running() {
    mole_pgrep_any \
        -x "Final Cut Pro" \
        -f "/Final Cut Pro.app/"
}

final_cut_pro_path_has_protected_component() {
    local path="$1"

    case "$path" in
        */Original\ Media | */Original\ Media/* | \
            */CurrentVersion.flexolibrary | */CurrentVersion.plist | */Settings.plist | \
            */Motion\ Templates | */Motion\ Templates/* | \
            */Final\ Cut\ Pro\ Backups | */Final\ Cut\ Pro\ Backups/*)
            return 0
            ;;
    esac

    return 1
}

is_final_cut_pro_generated_cache_target() {
    local library="$1"
    local target="$2"

    [[ -n "$library" && -n "$target" ]] || return 1
    [[ "$library" == /* && "$target" == /* ]] || return 1
    [[ "$library" == "$HOME"/Movies/*.fcpbundle ]] || return 1
    [[ "$target" == "$library"/* ]] || return 1
    [[ -d "$library" && ! -L "$library" ]] || return 1
    [[ -d "$target" && ! -L "$target" ]] || return 1

    final_cut_pro_path_has_protected_component "$target" && return 1

    if declare -f validate_path_for_deletion > /dev/null 2>&1; then
        validate_path_for_deletion "$target" > /dev/null 2>&1 || return 1
    fi

    local relative_target="${target#"$library"/}"
    case "$relative_target" in
        */Render\ Files/High\ Quality\ Media | */Transcoded\ Media/Proxy\ Media)
            return 0
            ;;
    esac

    return 1
}

find_final_cut_pro_generated_cache_targets() {
    local movies_dir="$HOME/Movies"
    [[ -d "$movies_dir" ]] || return 0

    local library target
    while IFS= read -r -d '' library; do
        [[ -d "$library" && ! -L "$library" ]] || continue

        while IFS= read -r -d '' target; do
            if is_final_cut_pro_generated_cache_target "$library" "$target"; then
                printf '%s\0' "$target"
            fi
        done < <(command find "$library" \
            \( -type d \( \
            -name "Original Media" -o \
            -name "Analysis Files" -o \
            -name "Motion Templates" -o \
            -name "Final Cut Pro Backups" \
            \) -prune \) -o \
            \( -type d \( \
            -path "*/Render Files/High Quality Media" -o \
            -path "*/Transcoded Media/Proxy Media" \
            \) -print0 \) 2> /dev/null || true)
    done < <(command find "$movies_dir" -maxdepth 4 -type d -name "*.fcpbundle" -prune -print0 2> /dev/null || true)
}

clean_final_cut_pro_generated_caches() {
    local -a fcp_cache_targets=()
    local target
    while IFS= read -r -d '' target; do
        if mole_cleanup_targets_exist "$target"; then
            fcp_cache_targets+=("$target")
        fi
    done < <(find_final_cut_pro_generated_cache_targets)

    [[ ${#fcp_cache_targets[@]} -gt 0 ]] || return 0

    local process_state=0
    final_cut_pro_is_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Final Cut Pro generated caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Final Cut Pro"
        fi
        return 0
    fi

    # Final Cut Pro generated cache cleanup (issue #843).
    # Safety scope for the first pass:
    # - only scan ~/Movies, the default Apple library location;
    # - only delete exact generated-media directories documented by Apple as
    #   regenerable: render media and proxy media;
    # - never touch Original Media, library databases, plist settings, backups,
    #   Motion templates, Analysis Files, optimized media, or external .fcpcache.
    # Future expansion can add explicit flags or configurable roots for
    # optimized media, Analysis Files, and external cache bundles after more
    # field feedback.
    _app_cache_safe_clean_guarded \
        _final_cut_pro_delete_guard_allows \
        "Final Cut Pro generated caches" \
        "${fcp_cache_targets[@]}" \
        "Final Cut Pro generated cache" || true
}

jianying_pro_is_running() {
    command -v pgrep > /dev/null 2>&1 || return 2

    # Match the main editor process only. Narrow the -f pattern to the primary
    # executable path so the always-resident menu-bar agent
    # (.../Frameworks/VideoFusion-macOSTrayHelper.app/.../VideoFusion-macOSTrayHelper)
    # does not read as "editor running" and permanently skip cleanup.
    local probe_rc=0
    if pgrep -x "VideoFusion-macOS" > /dev/null 2>&1; then
        return 0
    else
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 2
    fi
    if pgrep -f "/VideoFusion-macOS.app/Contents/MacOS/VideoFusion-macOS" > /dev/null 2>&1; then
        return 0
    else
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 2
    fi
    return 1
}

clean_jianying_pro_generated_caches() {
    local cache_root="$HOME/Movies/JianyingPro/User Data/Cache"
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 0

    local process_state=0
    jianying_pro_is_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        local skip_reason="JianyingPro running"
        [[ $process_state -eq 2 ]] && skip_reason="process state unknown"
        echo -e "  ${GRAY}${ICON_WARNING}${NC} JianyingPro generated caches · skipped ($skip_reason)"
        note_activity
        return 0
    fi

    # JianyingPro (剪映专业版 / CapCut CN, com.lemon.lvpro) generated cache
    # cleanup (issue #1277). Same shape as Final Cut Pro (#843): the editor
    # keeps heavy generated caches under ~/Movies/JianyingPro/User Data/Cache/
    # instead of ~/Library/Caches, so standard cleanup never reaches them.
    #
    # Safety scope for the first pass:
    # - only the default cache root under ~/Movies; never User Data/Projects
    #   (the user's editable drafts) or any sibling of Cache;
    # - only remove an explicit whitelist of regenerable subdirectories:
    #   subtitle-recognition PCM scratch, frame thumbnails, audio waveforms,
    #   algorithm scratch, and prerender/remux temp;
    # - never touch draft-referenced or downloaded assets (effect,
    #   onlineMaterial, artistEffect, music, AITextTemplate, template,
    #   local_models, AigcMaterailCache, agencycache); plaintext draft configs
    #   reference effect 8000+ times, so anything not on this list is preserved.
    #
    # image/ and importcache3/ are deliberately excluded: both hold copies of
    # material the user imported, draft_info.json is encrypted so no plaintext
    # reference check can prove they are unreferenced, and mo clean deletes
    # permanently. If the user has since moved or deleted the source file, the
    # cached copy is the only remaining one. Revisit only with evidence that
    # the editor re-imports from the original on demand.
    #
    # Verified on a real machine (macOS 15.7 Intel, JianyingPro 11.1.0):
    # removing this set reclaimed ~70GB, 2025-era projects reopened cleanly, and
    # the app recreated the scratch directories on next launch.
    local -a regenerable_subdirs=(
        recognize
        frameThumbnail
        audioWave
        AlgorithmCache
        ILASDKDB
        RemuxCache
        prerender
        segmentPrerenderCache
        MotionBlurCache
        ttsTemp
        tmp
    )

    local -a targets=()
    local subdir path
    for subdir in "${regenerable_subdirs[@]}"; do
        path="$cache_root/$subdir"
        if [[ -d "$path" && ! -L "$path" ]]; then
            targets+=("$path")
        fi
    done

    [[ ${#targets[@]} -gt 0 ]] || return 0

    safe_clean "${targets[@]}" "JianyingPro generated cache"
}

clean_video_tools() {
    safe_clean ~/Library/Caches/net.telestream.screenflow10/* "ScreenFlow cache"
    safe_clean ~/Library/Caches/com.apple.FinalCut/* "Final Cut Pro cache"
    clean_final_cut_pro_generated_caches
    safe_clean ~/Library/Caches/com.blackmagic-design.DaVinciResolve/* "DaVinci Resolve cache"
    safe_clean ~/Movies/CacheClip/* "DaVinci Resolve CacheClip"
    safe_clean ~/Library/Caches/com.adobe.PremierePro.*/* "Premiere Pro cache"
    clean_jianying_pro_generated_caches
}
# Autodesk Fusion helpers (AcCoreConsole, ADPClientService) outlive the main
# window and keep SQLite caches open under ~/Library/Caches/com.autodesk.*.
# Deleting those while the helper runs can fill the volume with unlinked temp
# writes (#1390). Probe is intentionally broad on the Autodesk family; the
# safe_remove live-cache gate is the per-path backstop for every reverse-DNS
# cache tree, including the generic ~/Library/Caches/* sweep.
autodesk_cache_process_state() {
    mole_pgrep_any \
        -f "com.autodesk." \
        -x "AcCoreConsole" \
        -f "/AcCoreConsole" \
        -x "ADPClientService" \
        -f "/ADPClientService" \
        -x "streamer" \
        -f "/streamer" \
        -x "Fusion Client Downloader" \
        -x "Fusion 360 Client Downloader" \
        -f "Autodesk Fusion" \
        -f "Fusion 360" \
        -f "Fusion360"
}

_autodesk_cache_delete_guard_allows() {
    mole_clean_process_guard autodesk_cache_process_state "Autodesk running"
}

# Autodesk Fusion's in-app updater can leave tens of gigabytes of old app
# bundles under webdeploy/production (#1438 measured 60GB). This is not a
# generic Autodesk tree cleanup: only direct 40-hex version directories that
# contain one exact com.autodesk.fusion360 app bundle are eligible. Keep the
# current, equal-version, newer staged, unrecognized, non-hash, and symlinked
# entries. Version evidence is stronger than directory mtime, which an updater
# can preserve or reorder.
_MOLE_AUTODESK_FUSION_VERSION=""
_MOLE_AUTODESK_FUSION_APP=""
_MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
_MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
_MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
_MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
_MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
_MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()
_MOLE_AUTODESK_FUSION_GUARD_REASON=""

_autodesk_fusion_trusted_production_root() {
    local production_dir="$1"
    _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    [[ -d "$production_dir" && ! -L "$production_dir" ]] || return 1

    local physical_root=""
    physical_root=$(cd -P "$production_dir" 2> /dev/null && pwd -P) || return 1
    # Refuse every symlinked ancestor. A lexical path below Application Support
    # is not containment when webdeploy or production redirects elsewhere.
    [[ "$physical_root" == "$production_dir" ]] || return 1
    _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT="$physical_root"
}

_autodesk_fusion_version_dir_version() {
    local version_dir="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_VERSION=""
    _MOLE_AUTODESK_FUSION_APP=""

    [[ -d "$version_dir" && ! -L "$version_dir" ]] || return 1
    local app_candidate=""
    local app_count=0
    local candidate
    for candidate in \
        "$version_dir/Autodesk Fusion.app" \
        "$version_dir/Autodesk Fusion 360.app"; do
        [[ -d "$candidate" && ! -L "$candidate" ]] || continue
        app_candidate="$candidate"
        app_count=$((app_count + 1))
    done
    [[ $app_count -eq 1 ]] || return 1

    local contents_dir="$app_candidate/Contents"
    local macos_dir="$contents_dir/MacOS"
    [[ -d "$contents_dir" && ! -L "$contents_dir" ]] || return 1
    [[ -d "$macos_dir" && ! -L "$macos_dir" ]] || return 1
    local info_plist="$contents_dir/Info.plist"
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1

    local probe_timeout=""
    local probe_rc=0
    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"

    local bundle_id=""
    bundle_id=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleIdentifier raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$bundle_id" == "com.autodesk.fusion360" ]] || return 1

    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"
    local version=""
    version=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleVersion raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"
    local executable=""
    executable=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleExecutable raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 &&
        ("$executable" == "Autodesk Fusion" || "$executable" == "Autodesk Fusion 360") ]] || return 1
    local executable_path="$macos_dir/$executable"
    [[ -f "$executable_path" && -x "$executable_path" && ! -L "$executable_path" ]] || return 1

    _MOLE_AUTODESK_FUSION_VERSION="$version"
    _MOLE_AUTODESK_FUSION_APP="$app_candidate"
}

_autodesk_fusion_version_is_older() {
    local candidate_version="$1"
    local current_version="$2"
    [[ "$candidate_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
    [[ "$current_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    local saved_ifs="$IFS"
    IFS='.'
    # shellcheck disable=SC2206 # intentional numeric version split
    local -a candidate_parts=($candidate_version)
    # shellcheck disable=SC2206 # intentional numeric version split
    local -a current_parts=($current_version)
    IFS="$saved_ifs"

    local count=${#candidate_parts[@]}
    [[ ${#current_parts[@]} -gt $count ]] && count=${#current_parts[@]}
    local index candidate_part current_part
    for ((index = 0; index < count; index++)); do
        candidate_part="${candidate_parts[$index]:-0}"
        current_part="${current_parts[$index]:-0}"
        # Avoid arithmetic overflow on corrupt metadata. Unknown is retained.
        [[ ${#candidate_part} -le 9 && ${#current_part} -le 9 ]] || return 1
        if ((10#$candidate_part < 10#$current_part)); then
            return 0
        elif ((10#$candidate_part > 10#$current_part)); then
            return 1
        fi
    done
    return 1
}

_autodesk_fusion_resolve_current_dir() {
    local production_root="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""

    local current_alias="$production_root/Autodesk Fusion.app"
    [[ -e "$current_alias" || -L "$current_alias" ]] || return 1

    local resolved_target=""
    local resolve_rc=0
    if [[ -L "$current_alias" ]]; then
        [[ -e "$current_alias" ]] || return 1
        resolved_target=$(cd -P "$current_alias" 2> /dev/null && pwd -P) || return 1
    else
        # Resolve a Finder alias through Foundation, not Finder automation. The
        # static JXA receives the path as argv, so quotes or AppleScript syntax
        # in a user path cannot become code. Test/no-auth runs never launch it.
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ||
            ! -x /usr/bin/osascript ]]; then
            return 1
        fi
        local resolve_timeout=""
        resolve_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || resolve_rc=$?
        [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
        # shellcheck disable=SC2016 # `$` belongs to the JXA bridge, not Bash
        local jxa_script='ObjC.import("Foundation"); function run(argv) { var url = $.NSURL.fileURLWithPath($(argv[0])); var resolved = $.NSURL.URLByResolvingAliasFileAtURLOptionsError(url, 0, null); if (!resolved) throw new Error("unresolved alias"); return ObjC.unwrap(resolved.path); }'
        resolved_target=$(run_with_timeout "$resolve_timeout" /usr/bin/osascript \
            -l JavaScript -e "$jxa_script" "$current_alias" < /dev/null 2> /dev/null) || resolve_rc=$?
        [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
        resolved_target="${resolved_target%/}"
        [[ -d "$resolved_target" ]] || return 1
        resolved_target=$(cd -P "$resolved_target" 2> /dev/null && pwd -P) || return 1
    fi

    local version_dir=""
    local target_name="${resolved_target##*/}"
    if [[ "${resolved_target%/*}" == "$production_root" &&
        "$target_name" =~ ^[0-9a-f]{40}$ ]]; then
        version_dir="$resolved_target"
    elif [[ "$target_name" == "Autodesk Fusion.app" ||
        "$target_name" == "Autodesk Fusion 360.app" ]]; then
        version_dir="${resolved_target%/*}"
        local version_name="${version_dir##*/}"
        [[ "${version_dir%/*}" == "$production_root" &&
            "$version_name" =~ ^[0-9a-f]{40}$ ]] || return 1
    else
        return 1
    fi
    [[ -d "$version_dir" && ! -L "$version_dir" ]] || return 1

    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$version_dir"
}

_autodesk_fusion_resolve_current_version() {
    local production_root="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""

    local resolve_rc=0
    _autodesk_fusion_resolve_current_dir \
        "$production_root" "$deadline_seconds" || resolve_rc=$?
    [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
    local version_dir="$_MOLE_AUTODESK_FUSION_RESOLVED_DIR"

    local version_rc=0
    _autodesk_fusion_version_dir_version \
        "$version_dir" "$deadline_seconds" || version_rc=$?
    [[ $version_rc -eq 0 ]] || return "$version_rc"
    local version="$_MOLE_AUTODESK_FUSION_VERSION"

    # The updater can switch the alias while plist metadata is being read and
    # exit before the caller's process recheck. End this resolver with an
    # alias-only rebind, so its returned directory/version are one stable
    # observation rather than metadata from an alias target that is no longer
    # current.
    resolve_rc=0
    _autodesk_fusion_resolve_current_dir \
        "$production_root" "$deadline_seconds" || resolve_rc=$?
    [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
    [[ "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" == "$version_dir" ]] || return 1

    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$version_dir"
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION="$version"
}

_autodesk_fusion_materialize_version_dirs() {
    local production_root="$1"
    local output_file="$2"
    local deadline_seconds="$3"
    : > "$output_file" || return 1

    local scan_timeout=""
    local scan_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        run_with_timeout "$scan_timeout" find "$production_root" \
            -mindepth 1 -maxdepth 1 -type d -print0 \
            < /dev/null > "$output_file" 2> /dev/null || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
}

_autodesk_fusion_plan_old_versions() {
    local production_root="$1"
    local current_dir="$2"
    local current_version="$3"
    local deadline_seconds="$4"
    _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()

    local inventory_file=""
    inventory_file=$(create_temp_file) || return 1
    local inventory_rc=0
    _autodesk_fusion_materialize_version_dirs \
        "$production_root" "$inventory_file" "$deadline_seconds" || inventory_rc=$?
    if [[ $inventory_rc -ne 0 ]]; then
        rm -f -- "$inventory_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$inventory_rc"
    fi

    local dir name candidate_version version_rc
    while IFS= read -r -d '' dir; do
        if [[ $SECONDS -ge $deadline_seconds ]]; then
            inventory_rc=124
            break
        fi
        name="${dir##*/}"
        [[ "$name" =~ ^[0-9a-f]{40}$ ]] || continue
        [[ "$dir" != "$current_dir" && "${dir%/*}" == "$production_root" ]] || continue
        [[ -d "$dir" && ! -L "$dir" ]] || continue

        version_rc=0
        _autodesk_fusion_version_dir_version \
            "$dir" "$deadline_seconds" || version_rc=$?
        if [[ $version_rc -eq 124 || $version_rc -ge 128 ]]; then
            inventory_rc=$version_rc
            break
        elif [[ $version_rc -ne 0 ]]; then
            debug_log "Autodesk Fusion old versions: keeping unverified directory $dir"
            continue
        fi
        candidate_version="$_MOLE_AUTODESK_FUSION_VERSION"
        _autodesk_fusion_version_is_older \
            "$candidate_version" "$current_version" || continue
        if should_protect_path "$dir" || is_path_whitelisted "$dir" ||
            (declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$dir"); then
            continue
        fi

        _mole_snapshot_path_identity "$dir" || continue
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$production_root" ]] || continue
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS+=("$dir")
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS+=("$_MOLE_PATH_SNAPSHOT_PARENT")
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
    done < "$inventory_file"
    rm -f -- "$inventory_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    if [[ $inventory_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()
        return "$inventory_rc"
    fi
}

_autodesk_fusion_guard_current_is_unchanged() {
    local _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    local _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
    local resolve_rc=0
    _autodesk_fusion_resolve_current_version \
        "$_MOLE_AUTODESK_FUSION_GUARD_ROOT" \
        "$_MOLE_AUTODESK_FUSION_GUARD_DEADLINE" || resolve_rc=$?
    if [[ $resolve_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="current version unknown"
        [[ $resolve_rc -eq 124 || $resolve_rc -ge 128 ]] && return "$resolve_rc"
        return 1
    fi
    if [[ "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" != "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR" ||
        "$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION" != "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION" ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="current version changed"
        return 1
    fi
}

_autodesk_fusion_delete_guard_allows() {
    local target="$1"
    _MOLE_AUTODESK_FUSION_GUARD_REASON=""

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard \
        autodesk_cache_process_state "Autodesk started"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi

    local _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    if ! _autodesk_fusion_trusted_production_root \
        "$_MOLE_AUTODESK_FUSION_GUARD_ROOT"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="production root changed"
        return 1
    fi

    local current_rc=0
    _autodesk_fusion_guard_current_is_unchanged || current_rc=$?
    [[ $current_rc -eq 0 ]] || return "$current_rc"

    local name="${target##*/}"
    if [[ ! "$name" =~ ^[0-9a-f]{40}$ || "${target%/*}" != "$_MOLE_AUTODESK_FUSION_GUARD_ROOT" ||
        "$target" == "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR" || ! -d "$target" || -L "$target" ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate changed"
        return 1
    fi

    local version_rc=0
    _autodesk_fusion_version_dir_version \
        "$target" "$_MOLE_AUTODESK_FUSION_GUARD_DEADLINE" || version_rc=$?
    if [[ $version_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate identity changed"
        [[ $version_rc -eq 124 || $version_rc -ge 128 ]] && return "$version_rc"
        return 1
    fi
    if ! _autodesk_fusion_version_is_older \
        "$_MOLE_AUTODESK_FUSION_VERSION" \
        "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="retention changed"
        return 1
    fi
    if should_protect_path "$target" || is_path_whitelisted "$target" ||
        (declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$target"); then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="policy changed"
        return 1
    fi

    # Metadata probes above are bounded, but the updater can start during any
    # one of them. Rebind its tri-state immediately before the final identity
    # check; that identity remains the last operation before safe_remove's rm.
    _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard \
        autodesk_cache_process_state "Autodesk started"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi

    # The updater may atomically switch the alias and exit during any earlier
    # metadata, policy, or process probe. Make current resolution the last
    # external-state check, immediately before the target identity binding.
    current_rc=0
    _autodesk_fusion_guard_current_is_unchanged || current_rc=$?
    [[ $current_rc -eq 0 ]] || return "$current_rc"

    # Make the object/parent identity check the last guard operation so a
    # replacement during the metadata probes is rejected at the sink.
    if ! _mole_path_matches_identity \
        "$target" \
        "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
        "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
        "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate replaced"
        return 1
    fi
}

clean_autodesk_fusion_old_bundles() {
    local production_dir="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    [[ -d "$production_dir" ]] || return 0
    local cleanup_deadline=$((SECONDS + 60))

    local _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    if ! _autodesk_fusion_trusted_production_root "$production_dir"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · skipped (production root not trusted)"
        note_activity
        return 0
    fi
    local production_root="$_MOLE_AUTODESK_FUSION_PRODUCTION_ROOT"

    local _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    local _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
    local current_rc=0
    _autodesk_fusion_resolve_current_version \
        "$production_root" "$cleanup_deadline" || current_rc=$?
    if [[ $current_rc -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · skipped (current version probe timed out)"
        note_activity
        return 0
    elif [[ $current_rc -ge 128 ]]; then
        return "$current_rc"
    elif [[ $current_rc -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · skipped (current version unknown)"
        note_activity
        return 0
    fi
    local current_dir="$_MOLE_AUTODESK_FUSION_RESOLVED_DIR"
    local current_version="$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION"

    local plan_rc=0
    _autodesk_fusion_plan_old_versions \
        "$production_root" "$current_dir" "$current_version" \
        "$cleanup_deadline" || plan_rc=$?
    if [[ $plan_rc -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · skipped (inventory timed out)"
        note_activity
        return 0
    elif [[ $plan_rc -ge 128 ]]; then
        return "$plan_rc"
    elif [[ $plan_rc -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · skipped (inventory incomplete)"
        note_activity
        return 0
    fi
    [[ ${#_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[@]} -gt 0 ]] || return 0

    local process_state=0
    autodesk_cache_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Autodesk Fusion"
        fi
        return 0
    fi

    local cleaned_count=0
    local failed_count=0
    local total_size=0
    local stopped_reason=""
    local index dir size_kb size_rc size_timeout guard_rc remove_rc
    for ((index = 0; index < ${#_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[@]}; index++)); do
        dir="${_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_ROOT="$production_root"
        local _MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current_dir"
        local _MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="$current_version"
        local _MOLE_AUTODESK_FUSION_GUARD_DEADLINE="$cleanup_deadline"
        local _MOLE_AUTODESK_FUSION_GUARD_PARENT="${_MOLE_AUTODESK_FUSION_CLEANUP_PARENTS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="${_MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="${_MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS[$index]}"

        guard_rc=0
        _autodesk_fusion_delete_guard_allows "$dir" || guard_rc=$?
        if [[ $guard_rc -eq 124 ]]; then
            stopped_reason="verification timed out"
            break
        elif [[ $guard_rc -ge 128 ]]; then
            return "$guard_rc"
        elif [[ $guard_rc -ne 0 ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        fi

        size_timeout=""
        size_rc=0
        size_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$cleanup_deadline") || size_rc=$?
        if [[ $size_rc -eq 0 ]]; then
            size_kb=$(get_path_size_kb "$dir" "$size_timeout") || size_rc=$?
        fi
        if [[ $size_rc -eq 124 ]]; then
            stopped_reason="size probe timed out"
            break
        elif [[ $size_rc -ge 128 ]]; then
            return "$size_rc"
        elif [[ $size_rc -ne 0 || ! "$size_kb" =~ ^[0-9]+$ ]]; then
            failed_count=$((failed_count + 1))
            continue
        fi

        guard_rc=0
        _autodesk_fusion_delete_guard_allows "$dir" || guard_rc=$?
        if [[ $guard_rc -eq 124 ]]; then
            stopped_reason="verification timed out"
            break
        elif [[ $guard_rc -ge 128 ]]; then
            return "$guard_rc"
        elif [[ $guard_rc -ne 0 ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        fi

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$size_kb" 1 true || continue
            fi
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
            continue
        fi

        remove_rc=0
        local _MOLE_SAFE_REMOVE_FINAL_GUARD="_autodesk_fusion_delete_guard_allows"
        safe_remove "$dir" true "$size_kb" "$cleanup_deadline" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
            "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID" \
            > /dev/null 2>&1 || remove_rc=$?
        if [[ $remove_rc -eq 0 ]]; then
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
        elif [[ $remove_rc -eq 124 ]]; then
            stopped_reason="removal timed out"
            break
        elif [[ $remove_rc -ge 128 ]]; then
            return "$remove_rc"
        elif [[ -n "$_MOLE_AUTODESK_FUSION_GUARD_REASON" ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        else
            failed_count=$((failed_count + 1))
            debug_log "Autodesk Fusion old version removal failed: $dir"
        fi
    done

    if [[ $cleaned_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Autodesk Fusion old versions${NC} · ${YELLOW}${cleaned_count} dirs, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Autodesk Fusion old versions${NC} · ${line_color}${cleaned_count} dirs, $size_human${NC}"
        fi
        files_cleaned=$((${files_cleaned:-0} + cleaned_count))
        total_size_cleaned=$((${total_size_cleaned:-0} + total_size))
        total_items=$((${total_items:-0} + 1))
        note_activity
    fi
    if [[ $failed_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · ${failed_count} failed"
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion old versions · stopped (${stopped_reason})"
        note_activity
    fi
}

# 3D and CAD tools.
clean_3d_tools() {
    safe_clean ~/Library/Caches/org.blenderfoundation.blender/* "Blender cache"
    safe_clean ~/Library/Caches/com.maxon.cinema4d/* "Cinema 4D cache"

    local -a autodesk_targets=()
    local autodesk_entry
    for autodesk_entry in "$HOME"/Library/Caches/com.autodesk.*; do
        [[ -e "$autodesk_entry" ]] || continue
        if mole_cleanup_targets_exist "$autodesk_entry"/*; then
            autodesk_targets+=("$autodesk_entry"/*)
        elif mole_cleanup_targets_exist "$autodesk_entry"; then
            autodesk_targets+=("$autodesk_entry")
        fi
    done
    if [[ ${#autodesk_targets[@]} -gt 0 ]]; then
        local process_state=0
        autodesk_cache_process_state || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            if [[ $process_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk cache · skipped (process state unknown)"
                note_activity
            else
                mole_defer_cleanup_family "Autodesk"
            fi
        else
            _app_cache_safe_clean_guarded \
                _autodesk_cache_delete_guard_allows \
                "Autodesk cache" \
                "${autodesk_targets[@]}" \
                "Autodesk cache" || true
        fi
    fi

    safe_clean ~/Library/Caches/com.sketchup.*/* "SketchUp cache"

    # Remove old Autodesk Fusion app bundles left by the in-app updater.
    # The updater keeps every version under webdeploy/production and leaves an
    # alias named "Autodesk Fusion.app" pointing at the current one. Delete
    # every older bundle, keep the current target and any newer staged update.
    clean_autodesk_fusion_old_bundles
}
# Productivity apps.
clean_productivity_apps() {
    safe_clean ~/Library/Caches/com.tw93.MiaoYan/* "MiaoYan cache"
    safe_clean ~/Library/Caches/com.klee.desktop/* "Klee cache"
    safe_clean ~/Library/Caches/klee_desktop/* "Klee desktop cache"
    safe_clean ~/Library/Caches/com.orabrowser.app/* "Ora browser cache"
    safe_clean ~/Library/Caches/com.filo.client/* "Filo cache"
    safe_clean ~/Library/Caches/com.flomoapp.mac/* "Flomo cache"
    safe_clean ~/Library/Application\ Support/Quark/Cache/videoCache/* "Quark video cache"
    safe_clean ~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches/* "NetNewsWire cache"
    safe_clean ~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches/* "MindNode cache"
    safe_clean ~/.cache/kaku/* "Kaku cache"
    safe_clean ~/Library/Application\ Support/spacedrive/thumbnails/* "Spacedrive thumbnail cache"
    safe_clean ~/Library/Containers/is.follow/Data/Library/Application\ Support/Folo/Cache/Cache_Data/* "Folo cache"
}
# Music/media players (protect Spotify offline music).
clean_media_players() {
    local spotify_cache="$HOME/Library/Caches/com.spotify.client"
    local spotify_data="$HOME/Library/Application Support/Spotify"
    local has_offline_music=false
    # offline.bnk exists even with no offline downloads; only treat it as evidence
    # when it has real content (>1 KB). Encrypted track blobs (*.file) are reliable.
    local bnk_file="$spotify_data/PersistentCache/Storage/offline.bnk"
    local bnk_size=0
    [[ -f "$bnk_file" ]] && bnk_size=$(stat -f%z "$bnk_file" 2> /dev/null || echo 0)
    if [[ $bnk_size -gt 1024 ]] ||
        [[ -d "$spotify_data/PersistentCache/Storage" && -n "$(find "$spotify_data/PersistentCache/Storage" -type f -name "*.file" 2> /dev/null | head -1)" ]]; then
        has_offline_music=true
    fi
    if [[ "$has_offline_music" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Spotify cache protected · offline music detected"
        note_activity
    else
        safe_clean ~/Library/Caches/com.spotify.client/* "Spotify cache"
    fi
    safe_clean ~/Library/Caches/com.apple.Music "Apple Music cache"
    safe_clean ~/Library/Caches/com.apple.podcasts "Apple Podcasts cache"
    # Apple Podcasts sandbox container: zombie sparse files and stale artwork cache (#387)
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia "Podcasts streamed media"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.heic "Podcasts artwork cache"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.img "Podcasts image cache"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp "Podcasts download temp"
    safe_clean ~/Library/Caches/com.apple.TV/* "Apple TV cache"
    safe_clean ~/Library/Caches/tv.plex.player.desktop "Plex cache"
    safe_clean ~/Library/Caches/com.netease.163music "NetEase Music cache"
    safe_clean ~/Library/Caches/com.tencent.QQMusic/* "QQ Music cache"
    safe_clean ~/Library/Caches/com.tencent.QQMusicMac/* "QQ Music Mac cache"
    # QQ Music Mac sandboxed container caches (protect offline downloads in iDownloadProxy).
    local _qqmusic_container="$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"
    if [[ -d "$_qqmusic_container" ]]; then
        safe_clean "$_qqmusic_container/iRRCache"/* "QQ Music streaming cache"
        safe_clean "$_qqmusic_container/iLog"/* "QQ Music logs"
        safe_clean "$_qqmusic_container/iCache"/* "QQ Music cache"
        safe_clean "$_qqmusic_container/iTemp"/* "QQ Music temp files"
    fi
    safe_clean ~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Caches/* "QQ Music container cache"
    safe_clean ~/Library/Caches/com.kugou.mac/* "Kugou Music cache"
    safe_clean ~/Library/Caches/com.kuwo.mac/* "Kuwo Music cache"
}
# Video players.
clean_video_players() {
    safe_clean ~/Library/Caches/com.colliderli.iina "IINA cache"
    safe_clean ~/Library/Caches/org.videolan.vlc "VLC cache"
    safe_clean ~/Library/Caches/io.mpv "MPV cache"
    safe_clean ~/Library/Caches/com.iqiyi.player "iQIYI cache"
    safe_clean ~/Library/Caches/com.tencent.tenvideo "Tencent Video cache"
    # Tencent Video sandboxed container caches.
    local _tenvideo_as="$HOME/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support"
    if [[ -d "$_tenvideo_as" ]]; then
        safe_clean "$_tenvideo_as/Upgrade"/* "Tencent Video old installer"
        safe_clean "$_tenvideo_as/VideoNative"/* "Tencent Video native cache"
        safe_clean "$_tenvideo_as/documentCache"/* "Tencent Video document cache"
    fi
    safe_clean ~/Library/Caches/tv.danmaku.bili/* "Bilibili cache"
    safe_clean ~/Library/Caches/com.douyu.*/* "Douyu cache"
    safe_clean ~/Library/Caches/com.huya.*/* "Huya cache"
    safe_clean ~/Library/Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache/* "SenPlayer video cache"
    safe_clean ~/Library/Caches/smart.stremio*/* "Stremio cache"
    if [[ -d ~/Library/Application\ Support/stremio ]]; then
        safe_clean ~/Library/Application\ Support/stremio/stremio-server/stremio-cache/* "Stremio server cache"
    fi
}
# Download managers.
clean_download_managers() {
    safe_clean ~/Library/Caches/net.xmac.aria2gui "Aria2 cache"
    safe_clean ~/Library/Caches/org.m0k.transmission "Transmission cache"
    safe_clean ~/Library/Caches/com.qbittorrent.qBittorrent "qBittorrent cache"
    safe_clean ~/Library/Caches/com.downie.Downie-* "Downie cache"
    safe_clean ~/Library/Caches/com.folx.*/* "Folx cache"
    safe_clean ~/Library/Caches/com.charlessoft.pacifist/* "Pacifist cache"
    clean_neatdm_stale_segments || return $?
}
# Neat Download Manager: clean stale incomplete download segments.
# History database (NeatDB.db) is never touched; only numbered segment
# directories whose seg.x0 file is older than MOLE_ORPHAN_AGE_DAYS are removed.
# Download URLs expire within hours/days so 30-day-old segments cannot be resumed.
clean_neatdm_stale_segments() {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    [[ -d "$neatdm_dir" ]] || return 0

    local stale_count=0
    local stale_kb=0
    local current_epoch
    current_epoch=$(get_epoch_seconds)

    local -a stale_dirs=()
    local seg_dir
    for seg_dir in "$neatdm_dir"/*/; do
        [[ -d "$seg_dir" ]] || continue
        local seg_name
        seg_name=$(basename "${seg_dir%/}")
        [[ "$seg_name" =~ ^[0-9]+$ ]] || continue
        [[ -f "$seg_dir/seg.x0" ]] || continue

        local seg_mtime
        seg_mtime=$(get_file_mtime "$seg_dir/seg.x0")
        local age_days=$(((current_epoch - seg_mtime) / 86400))

        if [[ $age_days -ge ${MOLE_ORPHAN_AGE_DAYS:-30} ]]; then
            stale_dirs+=("$seg_dir")
        fi
    done

    [[ ${#stale_dirs[@]} -eq 0 ]] && return 0

    for seg_dir in "${stale_dirs[@]}"; do
        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$seg_dir") || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" != "true" ]]; then
            if safe_remove "$seg_dir" true; then
                stale_count=$((stale_count + 1))
                stale_kb=$((stale_kb + size_kb))
            fi
        else
            stale_count=$((stale_count + 1))
            stale_kb=$((stale_kb + size_kb))
        fi
    done

    if [[ $stale_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((stale_kb * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} NeatDM stale downloads · ${stale_count} items, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$stale_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} NeatDM stale downloads · ${stale_count} items, ${line_color}${size_human}${NC}"
        fi
        files_cleaned=$((files_cleaned + stale_count))
        total_size_cleaned=$((total_size_cleaned + stale_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}
# Gaming platforms.
clean_gaming_platforms() {
    safe_clean ~/Library/Caches/com.valvesoftware.steam/* "Steam cache"
    if [[ -d ~/Library/Application\ Support/Steam ]]; then
        safe_clean ~/Library/Application\ Support/Steam/htmlcache/* "Steam web cache"
        safe_clean ~/Library/Application\ Support/Steam/appcache/* "Steam app cache"
        safe_clean ~/Library/Application\ Support/Steam/depotcache/* "Steam depot cache"
        safe_clean ~/Library/Application\ Support/Steam/steamapps/shadercache/* "Steam shader cache"
        safe_clean ~/Library/Application\ Support/Steam/logs/* "Steam logs"
    fi
    safe_clean ~/Library/Caches/com.epicgames.EpicGamesLauncher/* "Epic Games cache"
    safe_clean ~/Library/Caches/com.blizzard.Battle.net/* "Battle.net cache"
    if [[ -d ~/Library/Application\ Support/Battle.net ]]; then
        safe_clean ~/Library/Application\ Support/Battle.net/Cache/* "Battle.net app cache"
    fi
    safe_clean ~/Library/Caches/com.ea.*/* "EA Origin cache"
    safe_clean ~/Library/Caches/com.gog.galaxy/* "GOG Galaxy cache"
    safe_clean ~/Library/Caches/com.riotgames.*/* "Riot Games cache"
    if [[ -d ~/Library/Application\ Support/minecraft ]]; then
        safe_clean ~/Library/Application\ Support/minecraft/logs/* "Minecraft logs"
        safe_clean ~/Library/Application\ Support/minecraft/crash-reports/* "Minecraft crash reports"
        safe_clean ~/Library/Application\ Support/minecraft/webcache/* "Minecraft web cache"
        safe_clean ~/Library/Application\ Support/minecraft/webcache2/* "Minecraft web cache 2"
    fi
    if [[ -d ~/.lunarclient ]]; then
        safe_clean ~/.lunarclient/game-cache/* "Lunar Client game cache"
        safe_clean ~/.lunarclient/launcher-cache/* "Lunar Client launcher cache"
        safe_clean ~/.lunarclient/logs/* "Lunar Client logs"
        safe_clean ~/.lunarclient/offline/*/logs/* "Lunar Client offline logs"
        safe_clean ~/.lunarclient/offline/files/*/logs/* "Lunar Client offline file logs"
    fi
    safe_clean ~/Library/Caches/net.pcsx2.PCSX2/* "PCSX2 cache"
    if [[ -d ~/Library/Application\ Support/PCSX2 ]]; then
        safe_clean ~/Library/Application\ Support/PCSX2/cache/* "PCSX2 shader cache"
        safe_clean ~/Library/Logs/PCSX2/* "PCSX2 logs"
    fi
    if [[ -d ~/Library/Application\ Support/rpcs3 ]]; then
        safe_clean ~/Library/Caches/net.rpcs3.rpcs3/* "RPCS3 cache"
        safe_clean ~/Library/Application\ Support/rpcs3/logs/* "RPCS3 logs"
    fi
}
# Translation/dictionary apps.
clean_translation_apps() {
    safe_clean ~/Library/Caches/com.youdao.YoudaoDict "Youdao Dictionary cache"
    safe_clean ~/Library/Caches/com.eudic.* "Eudict cache"
    safe_clean ~/Library/Caches/com.bob-build.Bob "Bob Translation cache"
}
# Screenshot/recording tools.
clean_screenshot_tools() {
    safe_clean ~/Library/Caches/com.cleanshot.* "CleanShot cache"
    safe_clean ~/Library/Caches/com.reincubate.camo "Camo cache"
    safe_clean ~/Library/Caches/com.xnipapp.xnip "Xnip cache"
}
# Email clients.
clean_email_clients() {
    safe_clean ~/Library/Caches/com.readdle.smartemail-Mac "Spark cache"
    safe_clean ~/Library/Caches/com.airmail.* "Airmail cache"
}
# Task management apps.
clean_task_apps() {
    safe_clean ~/Library/Caches/com.todoist.mac.Todoist "Todoist cache"
    safe_clean ~/Library/Caches/com.any.do.* "Any.do cache"
}
# Shell/terminal utilities.
clean_shell_utils() {
    safe_clean ~/.zcompdump* "Zsh completion cache"
    safe_clean ~/.lesshst "less history"
    safe_clean ~/.viminfo.tmp "Vim temporary files"
    safe_clean ~/.wget-hsts "wget HSTS cache"
    safe_clean ~/.cacher/logs/* "Cacher logs"
    safe_clean ~/.kite/logs/* "Kite logs"
    safe_clean ~/Library/Caches/dev.warp.Warp-Stable/* "Warp cache"
    safe_clean ~/Library/Logs/warp.log "Warp log"
    safe_clean ~/Library/Caches/SentryCrash/Warp/* "Warp Sentry crash reports"
    safe_clean ~/Library/Caches/com.mitchellh.ghostty/* "Ghostty cache"
}
# Input methods and system utilities.
clean_system_utils() {
    safe_clean ~/Library/Caches/com.runjuu.Input-Source-Pro/* "Input Source Pro cache"
    safe_clean ~/Library/Caches/macos-wakatime.WakaTime/* "WakaTime cache"
    # WeType input method (image and dict update cache, not engine or user dict)
    safe_clean ~/Library/Application\ Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType/* "WeType image cache"
    safe_clean ~/Library/Application\ Support/WeType/DictUpdate/* "WeType dict update cache"
    # mihomo-party proxy tool (Electron)
    if [[ -d ~/Library/Application\ Support/mihomo-party ]]; then
        safe_clean ~/Library/Application\ Support/mihomo-party/Cache/* "mihomo-party cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/Code\ Cache/* "mihomo-party code cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/GPUCache/* "mihomo-party GPU cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/DawnGraphiteCache/* "mihomo-party Dawn cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/DawnWebGPUCache/* "mihomo-party WebGPU cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/logs/* "mihomo-party logs"
    fi
    # Stash proxy tool
    safe_clean ~/Library/Caches/ws.stash.app.mac/* "Stash cache"
}
# Note-taking apps.
clean_note_apps() {
    safe_clean ~/Library/Caches/notion.id/* "Notion cache"
    safe_clean ~/Library/Caches/md.obsidian/* "Obsidian cache"
    safe_clean ~/Library/Caches/com.logseq.*/* "Logseq cache"
    safe_clean ~/Library/Caches/com.bear-writer.*/* "Bear cache"
    safe_clean ~/Library/Caches/com.evernote.*/* "Evernote cache"
    safe_clean ~/Library/Caches/com.yinxiang.*/* "Yinxiang Note cache"
}
# Launchers and automation tools.
clean_launcher_apps() {
    safe_clean ~/Library/Caches/com.runningwithcrayons.Alfred/* "Alfred cache"
    safe_clean ~/Library/Caches/cx.c3.theunarchiver/* "The Unarchiver cache"
}
# Remote desktop tools.
clean_remote_desktop() {
    safe_clean ~/Library/Caches/com.teamviewer.*/* "TeamViewer cache"
    safe_clean ~/Library/Caches/com.anydesk.*/* "AnyDesk cache"
    safe_clean ~/Library/Caches/com.todesk.*/* "ToDesk cache"
    safe_clean ~/Library/Caches/com.sunlogin.*/* "Sunlogin cache"
}
# Main entry for GUI app cleanup.
clean_user_gui_applications() {
    stop_section_spinner
    clean_communication_apps
    clean_dingtalk
    clean_ai_apps
    clean_design_tools
    clean_video_tools
    clean_3d_tools
    clean_productivity_apps
    clean_media_players
    clean_video_players
    clean_download_managers || return $?
    clean_gaming_platforms
    clean_translation_apps
    clean_screenshot_tools
    clean_email_clients
    clean_task_apps
    clean_shell_utils
    clean_system_utils
    clean_note_apps
    clean_launcher_apps
    clean_remote_desktop
}
