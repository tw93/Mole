#!/bin/bash
# Hint notices used by `mo clean` (non-destructive guidance only).

set -euo pipefail

mole_hints_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$mole_hints_dir/purge_shared.sh"

# Quick reminder probe for project build artifacts handled by `mo purge`.
# Designed to be very fast: shallow directory checks only, no deep find scans.
# shellcheck disable=SC2329
load_quick_purge_hint_paths() {
    local config_file="$HOME/.config/mole/purge_paths"
    local -a paths=()

    while IFS= read -r line; do
        [[ -n "$line" ]] && paths+=("$line")
    done < <(mole_purge_read_paths_config "$config_file" 2> /dev/null)

    if [[ ${#paths[@]} -eq 0 ]]; then
        paths=("${MOLE_PURGE_DEFAULT_SEARCH_PATHS[@]}")
    fi

    if [[ ${#paths[@]} -gt 0 ]]; then
        printf '%s\n' "${paths[@]}"
    fi
}

# shellcheck disable=SC2329
hint_get_path_size_kb_with_timeout() {
    local path="$1"
    local timeout_seconds="${2:-0.8}"
    local du_tmp
    du_tmp=$(mktemp)

    local du_status=0
    if run_with_timeout "$timeout_seconds" du -skP "$path" > "$du_tmp" 2> /dev/null; then
        du_status=0
    else
        du_status=$?
    fi

    if [[ $du_status -ne 0 ]]; then
        rm -f "$du_tmp"
        return 1
    fi

    local size_kb
    size_kb=$(awk 'NR==1 {print $1; exit}' "$du_tmp")
    rm -f "$du_tmp"

    [[ "$size_kb" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$size_kb"
}

# shellcheck disable=SC2329
hint_collect_child_dirs_with_timeout() {
    local parent="$1"
    local output_file="$2"
    local timeout_seconds="${3:-1}"

    [[ -d "$parent" ]] || return 1
    : > "$output_file" || return 1

    # 1s: shallow directory listing should be near-instant on healthy local
    # paths. Slow/cloud-backed roots are skipped so `mo clean` never appears
    # stuck while rendering this non-destructive hint.
    run_with_timeout "$timeout_seconds" "$FIND_BSD" "$parent" -mindepth 1 -maxdepth 1 -type d -print0 > "$output_file" 2> /dev/null
}

# shellcheck disable=SC2329
hint_extract_launch_agent_program_path() {
    local plist="$1"
    local program=""

    if ! program=$(plutil -extract Program raw "$plist" 2> /dev/null); then
        program=""
    fi
    if [[ -z "$program" ]]; then
        if ! program=$(plutil -extract ProgramArguments.0 raw "$plist" 2> /dev/null); then
            program=""
        fi
    fi

    printf '%s\n' "$program"
}

# shellcheck disable=SC2329
hint_launch_agent_has_mach_services() {
    local plist="$1"
    plutil -extract MachServices raw "$plist" > /dev/null 2>&1
}

# shellcheck disable=SC2329
hint_extract_launch_agent_associated_bundle() {
    local plist="$1"
    local associated=""

    if ! associated=$(plutil -extract AssociatedBundleIdentifiers.0 raw "$plist" 2> /dev/null); then
        associated=""
    fi
    if [[ -z "$associated" ]] || [[ "$associated" == "1" ]]; then
        if ! associated=$(plutil -extract AssociatedBundleIdentifiers raw "$plist" 2> /dev/null); then
            associated=""
        fi
        if [[ "$associated" == "{"* ]] || [[ "$associated" == "["* ]]; then
            associated=""
        fi
    fi

    printf '%s\n' "$associated"
}

# shellcheck disable=SC2329
hint_is_app_scoped_launch_target() {
    local program="$1"

    case "$program" in
        /Applications/Setapp/*.app/* | \
            /Applications/*.app/* | \
            "$HOME"/Applications/*.app/* | \
            "$HOME"/Library/Application\ Support/*.app/* | \
            /Library/Input\ Methods/*.app/* | \
            /Library/PrivilegedHelperTools/*)
            return 0
            ;;
    esac

    return 1
}

# shellcheck disable=SC2329
hint_is_system_binary() {
    local program="$1"

    case "$program" in
        /bin/* | /sbin/* | /usr/bin/* | /usr/sbin/* | /usr/libexec/*)
            return 0
            ;;
    esac

    return 1
}

# shellcheck disable=SC2329
hint_launch_agent_bundle_exists() {
    local bundle_id="$1"

    [[ -z "$bundle_id" ]] && return 1

    # Delegate to the shared resolver so Spotlight misses (e.g. KeePassXC
    # installed via Homebrew) fall back to a direct /Applications scan. See #732.
    bundle_has_installed_app "$bundle_id"
}

# shellcheck disable=SC2329
record_project_artifact_hint() {
    local path="$1"

    PROJECT_ARTIFACT_HINT_COUNT=$((PROJECT_ARTIFACT_HINT_COUNT + 1))

    if [[ ${#PROJECT_ARTIFACT_HINT_EXAMPLES[@]} -lt 2 ]]; then
        PROJECT_ARTIFACT_HINT_EXAMPLES+=("${path/#$HOME/~}")
    fi

    local sample_max=3
    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -ge $sample_max ]]; then
        PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=true
        return 0
    fi

    local timeout_seconds="0.8"
    local size_kb=""
    if size_kb=$(hint_get_path_size_kb_with_timeout "$path" "$timeout_seconds"); then
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
            PROJECT_ARTIFACT_HINT_ESTIMATED_KB=$((PROJECT_ARTIFACT_HINT_ESTIMATED_KB + size_kb))
            PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=$((PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES + 1))
        else
            PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=true
        fi
    else
        PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=true
    fi

    return 0
}

# shellcheck disable=SC2329
is_quick_purge_project_root() {
    mole_purge_is_project_root "$1"
}

# shellcheck disable=SC2329
probe_project_artifact_hints() {
    PROJECT_ARTIFACT_HINT_DETECTED=false
    PROJECT_ARTIFACT_HINT_COUNT=0
    PROJECT_ARTIFACT_HINT_TRUNCATED=false
    PROJECT_ARTIFACT_HINT_EXAMPLES=()
    PROJECT_ARTIFACT_HINT_ESTIMATED_KB=0
    PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=0
    PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false
    PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=false

    local max_projects=200
    local max_projects_per_root=0
    local max_nested_per_project=120
    local max_matches=12
    local list_timeout_seconds=1

    # Wall-clock ceiling for the whole walk. Per-listing finds are already
    # capped at 1s, but with up to max_projects roots the cumulative scan can
    # stretch into minutes on busy machines and look hung (#1053). Checked
    # between iterations so the section degrades gracefully instead of stalling.
    local hint_budget_seconds="${MOLE_TIMEOUT_HINT_SCAN_SEC:-15}"
    [[ "$hint_budget_seconds" =~ ^[0-9]+$ ]] || hint_budget_seconds=15
    local scan_deadline=$((SECONDS + hint_budget_seconds))

    local -a target_names=()
    while IFS= read -r target_name; do
        [[ -n "$target_name" ]] && target_names+=("$target_name")
    done < <(mole_purge_quick_hint_target_names)

    local -a scan_roots=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && scan_roots+=("$path")
    done < <(load_quick_purge_hint_paths)

    [[ ${#scan_roots[@]} -eq 0 ]] && return 0

    # Fairness: avoid one very large root exhausting the entire scan budget.
    if [[ $max_projects_per_root -le 0 ]]; then
        max_projects_per_root=$(((max_projects + ${#scan_roots[@]} - 1) / ${#scan_roots[@]}))
        [[ $max_projects_per_root -lt 25 ]] && max_projects_per_root=25
    fi
    [[ $max_projects_per_root -gt $max_projects ]] && max_projects_per_root=$max_projects

    local scanned_projects=0
    local stop_scan=false
    local root project_dir nested_dir target_name candidate
    local project_dirs_file nested_dirs_file

    for root in "${scan_roots[@]}"; do
        if [[ $SECONDS -ge $scan_deadline ]]; then
            PROJECT_ARTIFACT_HINT_TRUNCATED=true
            PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
            break
        fi
        [[ -d "$root" ]] || continue
        # In-place spinner text swap per root: a multi-second walk with a
        # static label reads as a hang, a moving path reads as progress.
        start_section_spinner "Scanning projects · ${root/#$HOME/~}"
        local root_projects_scanned=0

        if is_quick_purge_project_root "$root"; then
            scanned_projects=$((scanned_projects + 1))
            root_projects_scanned=$((root_projects_scanned + 1))
            if [[ $scanned_projects -gt $max_projects ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                stop_scan=true
                break
            fi

            for target_name in "${target_names[@]}"; do
                candidate="$root/$target_name"
                if [[ -d "$candidate" ]]; then
                    record_project_artifact_hint "$candidate"
                fi
            done
        fi
        [[ "$stop_scan" == "true" ]] && break

        if [[ $root_projects_scanned -ge $max_projects_per_root ]]; then
            PROJECT_ARTIFACT_HINT_TRUNCATED=true
            continue
        fi

        project_dirs_file=$(mktemp_file "project_artifact_dirs") || {
            PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
            PROJECT_ARTIFACT_HINT_TRUNCATED=true
            continue
        }
        if ! hint_collect_child_dirs_with_timeout "$root" "$project_dirs_file" "$list_timeout_seconds"; then
            PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
            PROJECT_ARTIFACT_HINT_TRUNCATED=true
            rm -f "$project_dirs_file"
            continue
        fi

        while IFS= read -r -d '' project_dir; do
            if [[ $SECONDS -ge $scan_deadline ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
                stop_scan=true
                break
            fi
            [[ -d "$project_dir" ]] || continue

            local project_name="${project_dir%/}"
            project_name="${project_name##*/}"
            [[ "$project_name" == .* ]] && continue

            if [[ $root_projects_scanned -ge $max_projects_per_root ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                break
            fi

            scanned_projects=$((scanned_projects + 1))
            root_projects_scanned=$((root_projects_scanned + 1))
            if [[ $scanned_projects -gt $max_projects ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                stop_scan=true
                break
            fi

            for target_name in "${target_names[@]}"; do
                candidate="$project_dir/$target_name"
                if [[ -d "$candidate" ]]; then
                    record_project_artifact_hint "$candidate"
                fi
            done
            [[ "$stop_scan" == "true" ]] && break

            if [[ $SECONDS -ge $scan_deadline ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
                stop_scan=true
                break
            fi

            local nested_count=0
            nested_dirs_file=$(mktemp_file "project_artifact_nested") || {
                PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                continue
            }
            if ! hint_collect_child_dirs_with_timeout "$project_dir" "$nested_dirs_file" "$list_timeout_seconds"; then
                PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                rm -f "$nested_dirs_file"
                continue
            fi

            while IFS= read -r -d '' nested_dir; do
                if [[ $SECONDS -ge $scan_deadline ]]; then
                    PROJECT_ARTIFACT_HINT_TRUNCATED=true
                    PROJECT_ARTIFACT_HINT_SCAN_SKIPPED=true
                    stop_scan=true
                    break
                fi
                [[ -d "$nested_dir" ]] || continue

                local nested_name="${nested_dir%/}"
                nested_name="${nested_name##*/}"
                [[ "$nested_name" == .* ]] && continue

                case "$nested_name" in
                    node_modules | target | build | dist | DerivedData | Pods)
                        continue
                        ;;
                esac

                nested_count=$((nested_count + 1))
                if [[ $nested_count -gt $max_nested_per_project ]]; then
                    break
                fi

                for target_name in "${target_names[@]}"; do
                    candidate="$nested_dir/$target_name"
                    if [[ -d "$candidate" ]]; then
                        record_project_artifact_hint "$candidate"
                    fi
                done
            done < "$nested_dirs_file"
            rm -f "$nested_dirs_file"

            [[ "$stop_scan" == "true" ]] && break
        done < "$project_dirs_file"
        rm -f "$project_dirs_file"

        [[ "$stop_scan" == "true" ]] && break
    done

    if [[ $PROJECT_ARTIFACT_HINT_COUNT -gt 0 ]]; then
        PROJECT_ARTIFACT_HINT_DETECTED=true
    fi

    # Preserve a compact display hint if candidate count is large, but do not
    # stop scanning early solely because we exceeded this threshold.
    if [[ $PROJECT_ARTIFACT_HINT_COUNT -gt $max_matches ]]; then
        PROJECT_ARTIFACT_HINT_TRUNCATED=true
    fi

    return 0
}

# shellcheck disable=SC2329
show_project_artifact_hint_notice() {
    # The probe walks up to 200 project roots and du-samples candidates under
    # a 15s budget; without a loading state the section title just sits there
    # and the result row pops out of nowhere.
    start_section_spinner "Scanning project artifacts..."
    probe_project_artifact_hints
    stop_section_spinner

    if [[ "$PROJECT_ARTIFACT_HINT_DETECTED" != "true" ]]; then
        if [[ "${PROJECT_ARTIFACT_HINT_SCAN_SKIPPED:-false}" == "true" ]]; then
            note_activity
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Build artifacts · scan skipped · ${GRAY}mo purge${NC}"
        fi
        return 0
    fi

    local hint_count_label="$PROJECT_ARTIFACT_HINT_COUNT"
    [[ "$PROJECT_ARTIFACT_HINT_TRUNCATED" == "true" ]] && hint_count_label="${hint_count_label}+"

    local review_command="mo purge"
    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -gt 0 && $PROJECT_ARTIFACT_HINT_ESTIMATED_KB -eq 0 ]]; then
        review_command="mo purge --include-empty"
    fi

    # A fully measured estimate below the floor is not worth a row: four
    # directories holding 20KB read as "you have something to clean" and cost a
    # `mo purge` round trip to find out they do not. 200MB is where reclaiming
    # build output moves the number the user came for. A constant, not a knob,
    # because this repo counts a new env var as a new setting. A truncated,
    # partial or UNKNOWN measurement still prints: a sizing timeout has to stay
    # visible rather than be rounded down into silence. A measured ZERO is
    # exempt too, because that row is not about size at all: it points at empty
    # candidate directories and the `--include-empty` command that lists them
    # (#869).
    local min_kb=204800
    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATED_KB -gt 0 ]] &&
        [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -gt 0 ]] &&
        [[ $PROJECT_ARTIFACT_HINT_ESTIMATED_KB -lt $min_kb ]] &&
        [[ "$PROJECT_ARTIFACT_HINT_TRUNCATED" != "true" ]] &&
        [[ "$PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL" != "true" ]] &&
        [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -ge $PROJECT_ARTIFACT_HINT_COUNT ]]; then
        return 0
    fi

    # One compact row: "Build artifacts · 15+ dirs, 985.6MB+ · mo purge".
    local detail="${hint_count_label} dirs"
    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -gt 0 ]]; then
        local estimate_human
        estimate_human=$(bytes_to_human "$((PROJECT_ARTIFACT_HINT_ESTIMATED_KB * 1024))")

        local estimate_is_partial="$PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL"
        if [[ "$PROJECT_ARTIFACT_HINT_TRUNCATED" == "true" ]] || [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -lt $PROJECT_ARTIFACT_HINT_COUNT ]]; then
            estimate_is_partial=true
        fi

        if [[ "$estimate_is_partial" == "true" ]]; then
            detail+=", ${estimate_human}+"
        else
            detail+=", ${estimate_human}"
        fi
    fi

    local partial_note=""
    if [[ "${PROJECT_ARTIFACT_HINT_SCAN_SKIPPED:-false}" == "true" ]]; then
        partial_note=" ${GRAY}(partial scan)${NC}"
    fi

    note_activity
    echo -e "  ${YELLOW}${ICON_REVIEW}${NC} Build artifacts · ${GREEN}${detail}${NC} · ${GRAY}${review_command}${NC}${partial_note}"
}

# shellcheck disable=SC2329
show_user_launch_agent_hint_notice() {
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    [[ -d "$launch_agents_dir" ]] || return 0

    local max_hits=3
    local -a sources=()
    local -a reasons=()
    local -a targets=()
    local plist

    # Per-plist target probes add up; keep loading feedback on screen.
    start_section_spinner "Checking login items..."

    while IFS= read -r -d '' plist; do
        local filename
        filename=$(basename "$plist")
        [[ "$filename" == com.apple.* ]] && continue

        local reason=""
        local target=""
        local program=""
        local associated=""

        program=$(hint_extract_launch_agent_program_path "$plist")
        if [[ -z "$program" ]] && hint_launch_agent_has_mach_services "$plist"; then
            continue
        fi
        if [[ -n "$program" ]] && hint_is_system_binary "$program"; then
            continue
        fi
        if [[ "$program" == /* && -f "$program" && -x "$program" ]]; then
            continue
        elif [[ -n "$program" ]] && hint_is_app_scoped_launch_target "$program"; then
            if [[ ! -e "$program" ]]; then
                reason="Missing app/helper target"
                target="${program/#$HOME/~}"
            elif [[ ! -f "$program" || ! -x "$program" ]]; then
                reason="Program target is not executable"
                target="${program/#$HOME/~}"
            fi
        else
            associated=$(hint_extract_launch_agent_associated_bundle "$plist")
            if [[ -n "$associated" ]] && ! hint_launch_agent_bundle_exists "$associated"; then
                reason="Associated app not found"
                target="$associated"
            fi
        fi

        if [[ -n "$reason" ]]; then
            sources+=("${plist/#$HOME/~}")
            reasons+=("$reason")
            targets+=("$target")
            if [[ ${#sources[@]} -ge $max_hits ]]; then
                break
            fi
        fi
    done < <(find "$launch_agents_dir" -maxdepth 1 -name "*.plist" -print0 2> /dev/null)

    stop_section_spinner
    [[ ${#sources[@]} -eq 0 ]] && return 0

    note_activity

    local i
    for i in "${!sources[@]}"; do
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Stale login item · ${sources[$i]} · ${GRAY}${reasons[$i]}: ${targets[$i]} · review before removing${NC}"
    done
}
