#!/bin/bash
# Roomy - JSON API surface for native UI clients.
# Keeps the CLI/TUI as the execution engine while exposing stable contracts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/common.sh
source "$PROJECT_ROOT/lib/core/common.sh"

trap cleanup_temp_files EXIT INT TERM

api_json_escape() {
    local s="${1:-}"
    if command -v perl > /dev/null 2>&1; then
        local clean_file
        clean_file=$(mktemp_file "roomy-api-json-escape")
        if printf '%s' "$s" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g; s/([\x00-\x08\x0B\x0C\x0E-\x1F])/sprintf("\\u%04x", ord($1))/ge' > "$clean_file" 2> /dev/null; then
            IFS= read -r -d '' s < <(cat "$clean_file"; printf '\0')
        fi
    else
        s="${s//$'\033'/}"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\t'/\\t}"
        s="${s//$'\r'/\\r}"
        s="${s//$'\n'/\\n}"
        printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
        return 0
    fi
    printf '%s' "$s"
}

api_json_field() {
    local key="$1"
    local value="${2:-}"
    printf '"%s":"%s"' "$(api_json_escape "$key")" "$(api_json_escape "$value")"
}

api_json_number_field() {
    local key="$1"
    local value="${2:-0}"
    [[ "$value" =~ ^-?[0-9]+$ ]] || value=0
    printf '"%s":%s' "$(api_json_escape "$key")" "$value"
}

api_json_bool_field() {
    local key="$1"
    local value="${2:-false}"
    [[ "$value" == "true" || "$value" == "false" ]] || value=false
    printf '"%s":%s' "$(api_json_escape "$key")" "$value"
}

api_json_extra() {
    local first=true
    local field
    for field in "$@"; do
        [[ -n "$field" ]] || continue
        if $first; then
            first=false
        else
            printf ','
        fi
        printf '%s' "$field"
    done
}

api_json_array_is_valid() {
    local json="${1:-}"
    printf '%s' "$json" | grep -Eq '^[[:space:]]*\[' || return 1

    local json_file
    json_file=$(mktemp_file "roomy-api-json-array")
    printf '%s' "$json" > "$json_file"
    plutil -p "$json_file" > /dev/null 2>&1
}

api_base64_encode() {
    printf '%s' "${1:-}" | base64 | tr -d '\n'
}

api_base64_decode_to_var() {
    local target_var="$1"
    local encoded="$2"
    [[ "$target_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

    local decoded_file decoded_value=""
    decoded_file=$(mktemp_file "roomy-api-base64")
    if ! printf '%s' "$encoded" | base64 -D > "$decoded_file" 2> /dev/null; then
        printf '%s' "$encoded" | base64 -d > "$decoded_file" 2> /dev/null || return 1
    fi
    IFS= read -r -d '' decoded_value < <(cat "$decoded_file"; printf '\0')
    printf -v "$target_var" '%s' "$decoded_value"
}

api_plist_string_to_var() {
    local target_var="$1"
    local plist="$2"
    local key="$3"
    local fallback="${4:-}"
    [[ "$target_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

    local value_file value="$fallback"
    value_file=$(mktemp_file "roomy-api-plist")
    if plutil -extract "$key" raw "$plist" > "$value_file" 2> /dev/null; then
        api_chomp_one_trailing_newline_file "$value_file"
        IFS= read -r -d '' value < <(cat "$value_file"; printf '\0')
    fi
    printf -v "$target_var" '%s' "$value"
}

api_error() {
    local code="$1"
    local message="$2"
    local status="${3:-1}"
    printf '{"error":{"code":"%s","message":"%s"}}\n' \
        "$(api_json_escape "$code")" "$(api_json_escape "$message")" >&2
    exit "$status"
}

api_event() {
    local event="$1"
    local domain="$2"
    local message="${3:-}"
    local extra="${4:-}"
    local payload

    payload=$(
        printf '{"event":"%s","domain":"%s"' \
            "$(api_json_escape "$event")" "$(api_json_escape "$domain")"
    )
    if [[ -n "$message" ]]; then
        payload+=$(printf ',"message":"%s"' "$(api_json_escape "$message")")
    fi
    if [[ -n "$extra" ]]; then
        payload+=",$extra"
    fi
    payload+="}"
    printf '%s\n' "$payload"

    case "$domain" in
        clean | storage | uninstall | purge | installer | optimize | update | remove | whitelist | purge_paths | completion | launchers | touchid)
            if declare -f log_operation_event_json > /dev/null 2>&1; then
                log_operation_event_json "api" "$payload"
            fi
            ;;
    esac
}

api_find_status_bin() {
    if [[ -x "${ROOMY_TEST_STATUS_BIN:-}" ]]; then
        printf '%s\n' "$ROOMY_TEST_STATUS_BIN"
    elif [[ -x "$SCRIPT_DIR/status-go" ]]; then
        printf '%s\n' "$SCRIPT_DIR/status-go"
    else
        return 1
    fi
}

api_find_analyze_bin() {
    if [[ -x "${ROOMY_TEST_ANALYZE_BIN:-}" ]]; then
        printf '%s\n' "$ROOMY_TEST_ANALYZE_BIN"
    elif [[ -x "$SCRIPT_DIR/analyze-go" ]]; then
        printf '%s\n' "$SCRIPT_DIR/analyze-go"
    else
        return 1
    fi
}

api_resolve_existing_path_to_var() {
    local target_var="$1"
    local raw="$2"
    local expanded="$raw"
    [[ "$target_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$expanded" == "~"* ]] && expanded="${expanded/#\~/$HOME}"

    if [[ ! -e "$expanded" && ! -L "$expanded" ]]; then
        return 1
    fi

    local dir base resolved_path
    if [[ "$expanded" == "/" ]]; then
        printf -v "$target_var" '%s' "/"
        return 0
    elif [[ "$expanded" == */* ]]; then
        dir="${expanded%/*}"
        base="${expanded##*/}"
        [[ -n "$dir" ]] || dir="/"
    else
        dir="."
        base="$expanded"
    fi

    if [[ -L "$expanded" && -d "$expanded" ]]; then
        local resolved_file
        resolved_file=$(mktemp_file "roomy-api-resolve")
        (cd "$expanded" 2> /dev/null && pwd -P) > "$resolved_file" || return 1
        api_chomp_one_trailing_newline_file "$resolved_file"
        IFS= read -r -d '' resolved_path < <(cat "$resolved_file"; printf '\0')
        printf -v "$target_var" '%s' "$resolved_path"
        return 0
    fi

    local parent parent_file
    parent_file=$(mktemp_file "roomy-api-resolve-parent")
    (cd "$dir" 2> /dev/null && pwd -P) > "$parent_file" || return 1
    api_chomp_one_trailing_newline_file "$parent_file"
    IFS= read -r -d '' parent < <(cat "$parent_file"; printf '\0')
    if [[ "$parent" == "/" ]]; then
        resolved_path="/$base"
    else
        resolved_path="$parent/$base"
    fi
    printf -v "$target_var" '%s' "$resolved_path"
}

api_resolve_existing_path() {
    local resolved
    api_resolve_existing_path_to_var resolved "$1" || return 1
    printf '%s\n' "$resolved"
}

api_status() {
    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api status"
    local bin
    bin=$(api_find_status_bin) || api_error "missing_status_binary" "Bundled status binary not found. Run make build or reinstall Roomy."
    exec "$bin" --json
}

api_storage() {
    local command="${1:-}"
    shift || true

    if [[ "$command" == "execute" ]]; then
        api_storage_execute "$@"
        return
    fi

    [[ "$command" == "scan" ]] || api_error "usage" "Usage: roomy api storage scan --path <path>"

    local path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --path"
                path="$1"
                ;;
            *)
                api_error "usage" "Unknown storage scan option: $1"
                ;;
        esac
        shift || true
    done
    [[ -n "$path" ]] || api_error "usage" "Usage: roomy api storage scan --path <path>"

    local target
    api_resolve_existing_path_to_var target "$path" || api_error "invalid_path" "Storage scan path does not exist: $path"

    local bin
    bin=$(api_find_analyze_bin) || api_error "missing_analyze_binary" "Bundled analyzer binary not found. Run make build or reinstall Roomy."
    exec "$bin" --json "$target"
}

api_path_within_root() {
    local target="$1"
    local root="$2"
    target="${target%/}"
    root="${root%/}"
    [[ "$target" == "$root" || "$target" == "$root/"* ]]
}

api_path_size_bytes() {
    local path="$1"
    local value=0

    if [[ -d "$path" && ! -L "$path" ]]; then
        value=$(get_path_size_kb "$path")
        [[ "$value" =~ ^[0-9]+$ ]] || value=0
        printf '%s\n' "$((value * 1024))"
        return
    fi

    value=$(get_file_size "$path")
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

api_storage_execute() {
    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown storage execute option: $1" ;;
        esac
        shift || true
    done

    [[ -n "$plan_file" && -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"
    api_validate_plan_or_emit "storage" "$plan_file" || return 1

    local operation
    api_plan_string_to_var operation "$plan_file" "operation"
    [[ -n "$operation" ]] || operation="trash"
    case "$operation" in
        reveal | open | trash) ;;
        *) api_error "usage" "Storage operation must be reveal, open, or trash" ;;
    esac

    local scan_path
    api_plan_string_to_var scan_path "$plan_file" "scan_path"
    [[ -n "$scan_path" ]] || scan_path="$HOME"

    local scan_root scan_root_input
    api_expand_home_path_to_var scan_root_input "$scan_path"
    [[ -d "$scan_root_input" ]] || api_error "invalid_path" "Storage scan root does not exist: $scan_path"
    api_resolve_existing_path_to_var scan_root "$scan_path" || api_error "invalid_path" "Storage scan root does not exist: $scan_path"

    local dry_run=false
    api_plan_bool "$plan_file" "dry_run" && dry_run=true

    local -a targets=()
    local target
    while IFS= read -r -d '' target; do
        [[ -n "$target" ]] && targets+=("$target")
    done < <(api_plan_extract_array "$plan_file" "targets")

    [[ ${#targets[@]} -gt 0 ]] || {
        api_event "started" "storage"
        api_event "failed" "storage" "Storage execute requires a targets array"
        return 1
    }

    api_event "started" "storage" "" "$(api_json_extra "$(api_json_field operation "$operation")")"

    local completed=0
    local failed=0
    local total_bytes=0
    for target in "${targets[@]}"; do
        local expanded resolved bytes=0
        api_expand_home_path_to_var expanded "$target"

        if [[ ! -e "$expanded" && ! -L "$expanded" ]]; then
            api_event "skipped" "storage" "Path does not exist" "$(api_json_extra "$(api_json_field path "$expanded")")"
            continue
        fi

        if ! api_resolve_existing_path_to_var resolved "$expanded"; then
            api_event "skipped" "storage" "Path could not be resolved" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
            continue
        fi

        if ! api_path_within_root "$resolved" "$scan_root"; then
            api_event "skipped" "storage" "Path is outside the scanned folder" "$(api_json_extra "$(api_json_field path "$resolved")" "$(api_json_field scan_path "$scan_root")")"
            failed=1
            continue
        fi

        bytes=$(api_path_size_bytes "$resolved")

        case "$operation" in
            reveal)
                if [[ "$dry_run" == "true" ]]; then
                    api_event "progress" "storage" "Would reveal in Finder" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    completed=$((completed + 1))
                elif open -R "$resolved" > /dev/null 2>&1; then
                    api_event "progress" "storage" "Revealed in Finder" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    completed=$((completed + 1))
                else
                    api_event "warning" "storage" "Failed to reveal in Finder" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    failed=1
                fi
                ;;
            open)
                if [[ "$dry_run" == "true" ]]; then
                    api_event "progress" "storage" "Would open item" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    completed=$((completed + 1))
                elif open "$resolved" > /dev/null 2>&1; then
                    api_event "progress" "storage" "Opened item" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    completed=$((completed + 1))
                else
                    api_event "warning" "storage" "Failed to open item" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    failed=1
                fi
                ;;
            trash)
                if ! validate_path_for_deletion "$resolved" > /dev/null 2>&1; then
                    api_event "skipped" "storage" "Path failed deletion validation" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    failed=1
                    continue
                fi
                if [[ "$dry_run" == "true" ]]; then
                    api_event "progress" "storage" "Would move item to Trash" "$(api_json_extra "$(api_json_field path "$resolved")" "$(api_json_number_field bytes "$bytes")")"
                    completed=$((completed + 1))
                    total_bytes=$((total_bytes + bytes))
                elif ROOMY_DELETE_MODE=trash roomy_delete "$resolved" false; then
                    api_event "progress" "storage" "Moved item to Trash" "$(api_json_extra "$(api_json_field path "$resolved")" "$(api_json_number_field bytes "$bytes")")"
                    completed=$((completed + 1))
                    total_bytes=$((total_bytes + bytes))
                else
                    api_event "warning" "storage" "Failed to move item to Trash" "$(api_json_extra "$(api_json_field path "$resolved")")"
                    failed=1
                fi
                ;;
        esac
    done

    if [[ $failed -eq 0 ]]; then
        api_event "completed" "storage" "" "$(api_json_extra "$(api_json_field operation "$operation")" "$(api_json_number_field item_count "$completed")" "$(api_json_number_field bytes "$total_bytes")")"
        return 0
    fi
    api_event "failed" "storage" "One or more storage targets failed" "$(api_json_extra "$(api_json_field operation "$operation")" "$(api_json_number_field item_count "$completed")" "$(api_json_number_field bytes "$total_bytes")")"
    return 1
}

api_apps() {
    local command="${1:-}"
    shift || true
    [[ "$command" == "list" ]] || api_error "usage" "Usage: roomy api apps list --json"

    local json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true ;;
            *) api_error "usage" "Unknown apps list option: $1" ;;
        esac
        shift || true
    done
    $json || api_error "usage" "Usage: roomy api apps list --json"

    if [[ "${ROOMY_API_FULL_APP_INVENTORY:-0}" != "1" ]]; then
        api_apps_list_fast
        return 0
    fi

    local apps_json="" app_status=0 stderr_file stderr_msg=""
    stderr_file=$(mktemp_file "roomy-api-apps-full-stderr")
    if [[ ("${ROOMY_TEST_MODE:-0}" == "1" || "${ROOMY_TEST_NO_AUTH:-0}" == "1") && -n "${ROOMY_TEST_API_FULL_APPS_JSON+x}" ]]; then
        apps_json="$ROOMY_TEST_API_FULL_APPS_JSON"
    else
        set +e
        apps_json=$("$SCRIPT_DIR/uninstall.sh" --list 2> "$stderr_file")
        app_status=$?
        set -e
    fi
    if [[ $app_status -ne 0 ]]; then
        if [[ -z "$apps_json" ]] && grep -Eiq "No applications found|No applications available" "$stderr_file" 2> /dev/null; then
            apps_json="[]"
        else
            if [[ -s "$stderr_file" ]]; then
                IFS= read -r -d '' stderr_msg < <(cat "$stderr_file"; printf '\0')
            fi
            [[ -n "$stderr_msg" ]] || stderr_msg="uninstall --list exited $app_status"
            api_error "apps_inventory_failed" "Application inventory failed: $stderr_msg"
        fi
    elif [[ -z "$apps_json" ]]; then
        apps_json="[]"
    fi
    api_json_array_is_valid "$apps_json" || api_error "invalid_apps_json" "Application inventory did not return a valid JSON array"

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "apps": %s\n' "$apps_json"
    printf '}\n'
}

api_apps_list_fast() {
    local records_file
    records_file=$(mktemp_file "roomy-api-apps")
    : > "$records_file"

    local -a app_dirs=(
        "/Applications"
        "$HOME/Applications"
        "/Library/Input Methods"
        "$HOME/Library/Input Methods"
    )

    local app_dir app_path
    for app_dir in "${app_dirs[@]}"; do
        [[ -d "$app_dir" && -r "$app_dir" ]] || continue
        while IFS= read -r -d '' app_path; do
            [[ -d "$app_path" ]] || continue

            local parent_dir
            parent_dir="${app_path%/*}"
            [[ "$parent_dir" != "$app_path" ]] || parent_dir="."
            case "$parent_dir" in
                *.app | *.app/*) continue ;;
            esac

            local plist="$app_path/Contents/Info.plist"
            local bundle_id="unknown"
            local display_name=""
            local bundle_name=""
            if [[ -f "$plist" ]]; then
                api_plist_string_to_var bundle_id "$plist" "CFBundleIdentifier" "unknown"
                api_plist_string_to_var display_name "$plist" "CFBundleDisplayName" ""
                api_plist_string_to_var bundle_name "$plist" "CFBundleName" ""
            fi

            local app_name
            app_name="${display_name:-$bundle_name}"
            if [[ -z "$app_name" || "$app_name" == "(null)" ]]; then
                app_name="${app_path##*/}"
                app_name="${app_name%.app}"
            fi
            [[ -n "$bundle_id" && "$bundle_id" != "(null)" ]] || bundle_id="unknown"

            local size_display="N/A"
            local size_kb=""
            size_kb=$(run_with_timeout "${ROOMY_API_APP_SIZE_TIMEOUT:-0.6}" du -sk "$app_path" 2> /dev/null | awk 'NR==1 {print $1}' || true)
            if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
                size_display=$(bytes_to_human "$((size_kb * 1024))")
            fi

            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$(api_base64_encode "$app_name")" \
                "$(api_base64_encode "$bundle_id")" \
                "$(api_base64_encode "$app_path")" \
                "$(api_base64_encode "$size_display")" \
                "$(api_base64_encode "$app_name")" >> "$records_file"
        done < <(command find "$app_dir" -maxdepth 2 -name "*.app" -type d -prune -print0 2> /dev/null)
    done

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "apps": [\n'

    local first=true
    local app_name bundle_id path size uninstall_name encoded_name encoded_bundle encoded_path encoded_size encoded_uninstall
    while IFS=$'\t' read -r encoded_name encoded_bundle encoded_path encoded_size encoded_uninstall; do
        api_base64_decode_to_var app_name "$encoded_name" || continue
        api_base64_decode_to_var bundle_id "$encoded_bundle" || continue
        api_base64_decode_to_var path "$encoded_path" || continue
        api_base64_decode_to_var size "$encoded_size" || continue
        api_base64_decode_to_var uninstall_name "$encoded_uninstall" || continue
        [[ -n "$path" ]] || continue
        local uninstall_supported=true
        local uninstall_reason=""
        if [[ "$path" =~ [[:cntrl:]] || "$uninstall_name" =~ [[:cntrl:]] ]]; then
            uninstall_supported=false
            uninstall_reason="Path or uninstall name contains control characters"
        fi
        if $first; then
            first=false
        else
            printf ',\n'
        fi
        printf '    {"name":"%s","bundle_id":"%s","source":"App","uninstall_name":"%s","path":"%s","size":"%s","uninstall_supported":%s,"uninstall_reason":"%s"}' \
            "$(api_json_escape "$app_name")" \
            "$(api_json_escape "$bundle_id")" \
            "$(api_json_escape "$uninstall_name")" \
            "$(api_json_escape "$path")" \
            "$(api_json_escape "$size")" \
            "$uninstall_supported" \
            "$(api_json_escape "$uninstall_reason")"
    done < <(LC_COLLATE=C sort -u "$records_file")

    printf '\n'
    printf '  ]\n'
    printf '}\n'
}

api_optimize() {
    local command="${1:-}"
    shift || true
    [[ "$command" == "preview" ]] || api_error "usage" "Usage: roomy api optimize preview"
    [[ $# -eq 0 ]] || api_error "usage" "Unknown optimize preview option: $1"

    # shellcheck source=lib/check/health_json.sh
    source "$PROJECT_ROOT/lib/check/health_json.sh"
    generate_health_json
}

api_clean_preview_emit_json() {
    local capture_file="$1"
    local command_status="$2"
    local details_path="$3"

    local total_size_kb=0
    local total_items=0
    local skipped_total=0
    local protected_total=0
    local whitelist_total=0
    local admin_required=false
    local category_count=0
    local -a categories=()

    if [[ -f "$capture_file" ]]; then
        while IFS=$'\t' read -r kind section description size_kb item_count skipped_count risk_level risk_reason item_admin skip_reason; do
            [[ -z "${kind:-}" ]] && continue
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            [[ "$item_count" =~ ^[0-9]+$ ]] || item_count=0
            [[ "$skipped_count" =~ ^[0-9]+$ ]] || skipped_count=0

            [[ "$item_admin" == "true" ]] && admin_required=true

            if [[ "$kind" == "skipped" ]]; then
                skipped_total=$((skipped_total + skipped_count))
                case "$skip_reason" in
                    protected) protected_total=$((protected_total + skipped_count)) ;;
                    whitelist) whitelist_total=$((whitelist_total + skipped_count)) ;;
                esac
            elif [[ "$kind" == "category" ]]; then
                total_size_kb=$((total_size_kb + size_kb))
                total_items=$((total_items + item_count))
                category_count=$((category_count + 1))
                categories+=("$section"$'\t'"$description"$'\t'"$size_kb"$'\t'"$item_count"$'\t'"$skipped_count"$'\t'"$risk_level"$'\t'"$risk_reason"$'\t'"$item_admin")
            fi
        done < "$capture_file"
    fi

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "command": "clean.preview",\n'
    printf '  "dry_run": true,\n'
    printf '  "status": "%s",\n' "$command_status"
    printf '  "estimated_bytes": %s,\n' "$((total_size_kb * 1024))"
    printf '  "item_count": %s,\n' "$total_items"
    printf '  "category_count": %s,\n' "$category_count"
    printf '  "skipped_count": %s,\n' "$skipped_total"
    printf '  "protected_count": %s,\n' "$protected_total"
    printf '  "whitelist_count": %s,\n' "$whitelist_total"
    printf '  "admin_required": %s,\n' "$admin_required"
    printf '  "delete_mode": "%s",\n' "$(api_json_escape "${ROOMY_DELETE_MODE:-trash}")"
    printf '  "details_path": "%s",\n' "$(api_json_escape "$details_path")"
    printf '  "categories": [\n'

    local first=true
    local line section description size_kb item_count skipped_count risk_level risk_reason item_admin
    for line in "${categories[@]+"${categories[@]}"}"; do
        IFS=$'\t' read -r section description size_kb item_count skipped_count risk_level risk_reason item_admin <<< "$line"
        if $first; then
            first=false
        else
            printf ',\n'
        fi
        printf '    {"section":"%s","name":"%s","estimated_bytes":%s,"item_count":%s,"skipped_count":%s,"risk":"%s","risk_reason":"%s","admin_required":%s}' \
            "$(api_json_escape "$section")" \
            "$(api_json_escape "$description")" \
            "$((size_kb * 1024))" \
            "$item_count" \
            "$skipped_count" \
            "$(api_json_escape "$risk_level")" \
            "$(api_json_escape "$risk_reason")" \
            "$item_admin"
    done
    printf '\n'
    printf '  ]\n'
    printf '}\n'
}

api_clean() {
    local command="${1:-}"
    shift || true
    [[ "$command" == "preview" ]] || api_error "usage" "Usage: roomy api clean preview --json"

    local json=false
    local external_path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true ;;
            --external)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --external"
                external_path="$1"
                ;;
            *) api_error "usage" "Unknown clean preview option: $1" ;;
        esac
        shift || true
    done
    $json || api_error "usage" "Usage: roomy api clean preview --json [--external <path>]"

    local capture_file output_file status_label="success"
    capture_file=$(mktemp_file "roomy-api-clean")
    output_file=$(mktemp_file "roomy-api-clean-output")

    if [[ -n "$external_path" ]]; then
        if ! ROOMY_API_CLEAN_CAPTURE_FILE="$capture_file" ROOMY_NO_OPLOG=1 ROOMY_SKIP_TRASH_CLEANUP=1 TERM=dumb "$SCRIPT_DIR/clean.sh" --dry-run --external "$external_path" > "$output_file" 2>&1; then
            status_label="failed"
        fi
    else
        if ! ROOMY_API_CLEAN_CAPTURE_FILE="$capture_file" ROOMY_NO_OPLOG=1 ROOMY_SKIP_TRASH_CLEANUP=1 TERM=dumb "$SCRIPT_DIR/clean.sh" --dry-run > "$output_file" 2>&1; then
            status_label="failed"
        fi
    fi

    api_clean_preview_emit_json "$capture_file" "$status_label" "${ROOMY_CONFIG_DIR:-$HOME/.config/roomy}/clean-list.txt"

    [[ "$status_label" == "success" ]] || return 1
}

api_installer_preview() {
    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api installer preview --json"

    local output_file
    output_file=$(mktemp_file "roomy-api-installer-output")

    # shellcheck disable=SC1090
    ROOMY_TEST_MODE=1 source "$SCRIPT_DIR/installer.sh"

    if ! collect_installers > "$output_file" 2>&1; then
        INSTALLER_PATHS=()
        INSTALLER_SIZES=()
        INSTALLER_SOURCES=()
    fi

    local total_bytes=0
    local -a preview_paths=()
    local -a preview_sizes=()
    local -a preview_sources=()
    local count=${#INSTALLER_PATHS[@]}
    local i
    for ((i = 0; i < count; i++)); do
        local path="${INSTALLER_PATHS[i]}"
        validate_path_for_deletion "$path" > /dev/null 2>&1 || continue
        local bytes="${INSTALLER_SIZES[i]:-0}"
        local source="${INSTALLER_SOURCES[i]:-}"
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        preview_paths+=("$path")
        preview_sizes+=("$bytes")
        preview_sources+=("$source")
        total_bytes=$((total_bytes + bytes))
    done
    count=${#preview_paths[@]}

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "command": "installer.preview",\n'
    printf '  "estimated_bytes": %s,\n' "$total_bytes"
    printf '  "item_count": %s,\n' "$count"
    printf '  "items": [\n'

    local first=true
    for ((i = 0; i < count; i++)); do
        local path="${preview_paths[i]}"
        local bytes="${preview_sizes[i]:-0}"
        local source="${preview_sources[i]:-}"
        local name="${path##*/}"
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        if $first; then
            first=false
        else
            printf ',\n'
        fi
        printf '    {"name":"%s","path":"%s","source":"%s","bytes":%s}' \
            "$(api_json_escape "$name")" \
            "$(api_json_escape "$path")" \
            "$(api_json_escape "$source")" \
            "$bytes"
    done
    printf '\n'
    printf '  ]\n'
    printf '}\n'
}

api_purge_preview() {
    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api purge preview --json"

    if [[ -n "${ROOMY_CACHE_DIR:-}" && -z "${XDG_CACHE_HOME:-}" ]]; then
        export XDG_CACHE_HOME="$ROOMY_CACHE_DIR"
    fi

    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/roomy"
    ensure_user_dir "$stats_dir"
    ensure_user_file "$stats_dir/purge_scanning"

    # shellcheck disable=SC1090
    ROOMY_SKIP_MAIN=1 _PURGE_DISCOVERY_SILENT=1 source "$SCRIPT_DIR/purge.sh"

    local scan_output
    scan_output=$(mktemp_file "roomy-api-purge-scan")
    : > "$scan_output"

    local search_path temp_output
    for search_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
        [[ -d "$search_path" ]] || continue
        temp_output=$(mktemp_file "roomy-api-purge-path")
        scan_purge_targets_nul "$search_path" "$temp_output"
        [[ -f "$temp_output" ]] && cat "$temp_output" >> "$scan_output"
    done
    rm -f "$stats_dir/purge_scanning" 2> /dev/null || true

    local -a deduped_paths=()
    local path existing already_seen
    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] || continue
        already_seen=false
        for existing in "${deduped_paths[@]+"${deduped_paths[@]}"}"; do
            if [[ "$existing" == "$path" ]]; then
                already_seen=true
                break
            fi
        done
        [[ "$already_seen" == "true" ]] && continue
        deduped_paths+=("$path")
    done < "$scan_output"

    local total_bytes=0
    local item_count=0
    local now_epoch
    now_epoch=$(get_epoch_seconds)
    local -a item_paths=()
    local -a item_names=()
    local -a item_bytes=()
    local -a item_recent_flags=()
    local -a item_age_days=()
    local -a item_project_roots=()

    for path in "${deduped_paths[@]+"${deduped_paths[@]}"}"; do
        [[ -n "$path" && -e "$path" ]] || continue
        validate_path_for_deletion "$path" > /dev/null 2>&1 || continue
        local size_kb=0
        local size_raw
        size_raw=$(get_dir_size_kb "$path")
        [[ "$size_raw" =~ ^[0-9]+$ ]] && size_kb="$size_raw"
        [[ "$size_kb" -gt 0 ]] || continue

        local recent=false
        if is_recently_modified "$path" "$now_epoch"; then
            recent=true
        fi

        local mod_time=0
        mod_time=$(get_file_mtime "$path" 2> /dev/null || echo "0")
        [[ "$mod_time" =~ ^[0-9]+$ ]] || mod_time=0
        local age_days=$(((now_epoch - mod_time) / 86400))
        [[ "$age_days" -lt 0 ]] && age_days=0

        local project_root=""
        for search_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
            search_path="${search_path%/}"
            if [[ "$path" == "$search_path/"* ]]; then
                local relative_path="${path#"$search_path"/}"
                local first_component="${relative_path%%/*}"
                if [[ -n "$first_component" && "$first_component" != "$relative_path" ]]; then
                    project_root="$search_path/$first_component"
                else
                    project_root="$search_path"
                fi
                break
            fi
        done
        if [[ -z "$project_root" ]]; then
            project_root="${path%/*}"
            [[ "$project_root" != "$path" ]] || project_root="."
            [[ -n "$project_root" ]] || project_root="/"
        fi

        local bytes=$((size_kb * 1024))
        total_bytes=$((total_bytes + bytes))
        item_count=$((item_count + 1))
        local name="${path##*/}"
        item_paths+=("$path")
        item_names+=("$name")
        item_bytes+=("$bytes")
        item_recent_flags+=("$recent")
        item_age_days+=("$age_days")
        item_project_roots+=("$project_root")
    done

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "command": "purge.preview",\n'
    printf '  "estimated_bytes": %s,\n' "$total_bytes"
    printf '  "item_count": %s,\n' "$item_count"
    printf '  "search_paths": ['
    local first_path=true
    for search_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
        if $first_path; then
            first_path=false
        else
            printf ','
        fi
        printf '"%s"' "$(api_json_escape "$search_path")"
    done
    printf '],\n'
    printf '  "items": [\n'

    local first=true i name bytes recent age_days project_root
    for i in "${!item_paths[@]}"; do
        path="${item_paths[i]}"
        name="${item_names[i]}"
        bytes="${item_bytes[i]}"
        recent="${item_recent_flags[i]}"
        age_days="${item_age_days[i]}"
        project_root="${item_project_roots[i]}"
        [[ -n "$path" ]] || continue
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        [[ "$recent" == "true" || "$recent" == "false" ]] || recent=false
        [[ "$age_days" =~ ^[0-9]+$ ]] || age_days=0
        if $first; then
            first=false
        else
            printf ',\n'
        fi
        printf '    {"name":"%s","path":"%s","project_root":"%s","bytes":%s,"recent":%s,"age_days":%s}' \
            "$(api_json_escape "$name")" \
            "$(api_json_escape "$path")" \
            "$(api_json_escape "$project_root")" \
            "$bytes" \
            "$recent" \
            "$age_days"
    done
    printf '\n'
    printf '  ]\n'
    printf '}\n'
}

api_whitelist_mode_from_args() {
    local mode="clean"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --mode"
                mode="$1"
                ;;
            *) api_error "usage" "Unknown whitelist option: $1" ;;
        esac
        shift || true
    done
    case "$mode" in
        clean | optimize) printf '%s\n' "$mode" ;;
        *) api_error "usage" "Whitelist mode must be clean or optimize" ;;
    esac
}

api_whitelist_list() {
    local mode
    mode=$(api_whitelist_mode_from_args "$@")

    # shellcheck source=lib/manage/whitelist.sh
    source "$PROJECT_ROOT/lib/manage/whitelist.sh"
    load_whitelist "$mode"

    local items_source
    if [[ "$mode" == "optimize" ]]; then
        items_source=$(get_optimize_whitelist_items)
    else
        items_source=$(get_all_cache_items)
    fi

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "mode": "%s",\n' "$mode"
    printf '  "items": [\n'

    local first=true display_name pattern category expanded selected
    while IFS='|' read -r display_name pattern category; do
        [[ -n "$display_name" && -n "$pattern" ]] || continue
        expanded="${pattern/\$HOME/$HOME}"
        selected=false
        if is_whitelisted "$expanded"; then
            selected=true
        fi
        if $first; then
            first=false
        else
            printf ',\n'
        fi
        printf '    {"name":"%s","pattern":"%s","category":"%s","selected":%s}' \
            "$(api_json_escape "$display_name")" \
            "$(api_json_escape "${expanded/#$HOME/~}")" \
            "$(api_json_escape "${category:-custom}")" \
            "$selected"
    done <<< "$items_source"

    local current_pattern is_known
    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        for current_pattern in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
            is_known=false
            while IFS='|' read -r _ pattern _; do
                expanded="${pattern/\$HOME/$HOME}"
                if patterns_equivalent "$current_pattern" "$expanded"; then
                    is_known=true
                    break
                fi
            done <<< "$items_source"
            $is_known && continue
            if $first; then
                first=false
            else
                printf ',\n'
            fi
            printf '    {"name":"%s","pattern":"%s","category":"custom","selected":true}' \
                "$(api_json_escape "${current_pattern/#$HOME/~}")" \
                "$(api_json_escape "${current_pattern/#$HOME/~}")"
        done
    fi

    printf '\n'
    printf '  ]\n'
    printf '}\n'
}

api_whitelist_update() {
    local mode="clean"
    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --mode"
                mode="$1"
                ;;
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown whitelist update option: $1" ;;
        esac
        shift || true
    done
    case "$mode" in
        clean | optimize) ;;
        *) api_error "usage" "Whitelist mode must be clean or optimize" ;;
    esac
    [[ -n "$plan_file" && -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"
    api_validate_plan_or_emit "whitelist" "$plan_file" || return 1

    local -a patterns=()
    local pattern
    while IFS= read -r -d '' pattern; do
        [[ -n "$pattern" ]] && patterns+=("$pattern")
    done < <(api_plan_extract_array "$plan_file" "patterns")

    # shellcheck source=lib/manage/whitelist.sh
    source "$PROJECT_ROOT/lib/manage/whitelist.sh"
    if ! save_whitelist_patterns "$mode" "${patterns[@]+"${patterns[@]}"}" 2> /dev/null; then
        api_event "started" "whitelist"
        api_event "failed" "whitelist" "Could not write whitelist configuration" "$(api_json_extra "$(api_json_field mode "$mode")")"
        return 1
    fi
    api_event "completed" "whitelist" "Whitelist updated" "$(api_json_extra "$(api_json_field mode "$mode")" "$(api_json_number_field pattern_count "${#patterns[@]}")")"
}

api_purge_paths_list() {
    # shellcheck source=lib/clean/project.sh
    source "$PROJECT_ROOT/lib/clean/project.sh"

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "config_path": "%s",\n' "$(api_json_escape "$PURGE_CONFIG_FILE")"
    printf '  "paths": ['
    local first=true path
    for path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
        if $first; then first=false; else printf ','; fi
        printf '"%s"' "$(api_json_escape "$path")"
    done
    printf '],\n'
    printf '  "default_paths": ['
    first=true
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]+"${DEFAULT_PURGE_SEARCH_PATHS[@]}"}"; do
        if $first; then first=false; else printf ','; fi
        printf '"%s"' "$(api_json_escape "$path")"
    done
    printf ']\n'
    printf '}\n'
}

api_purge_paths_update() {
    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown purge paths update option: $1" ;;
        esac
        shift || true
    done

    [[ -n "$plan_file" && -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"
    api_validate_plan_or_emit "purge_paths" "$plan_file" || return 1

    # shellcheck source=lib/clean/project.sh
    source "$PROJECT_ROOT/lib/clean/project.sh"

    local -a paths=()
    local path expanded
    while IFS= read -r -d '' path; do
        [[ -z "$path" ]] && continue
        api_expand_home_path_to_var expanded "$path"
        if ! roomy_purge_is_safe_search_path "$expanded"; then
            api_event "started" "purge_paths"
            api_event "failed" "purge_paths" "Unsafe project scan path" "$(api_json_extra "$(api_json_field path "$expanded")")"
            return 1
        fi
        paths+=("$expanded")
    done < <(api_plan_extract_array "$plan_file" "paths")

    if ! write_purge_config "# Roomy Purge Paths - Directories to scan for project artifacts
# Managed by RoomyUI. Add one path per line (supports ~ for home directory).
" "${paths[@]+"${paths[@]}"}" 2> /dev/null; then
        api_event "started" "purge_paths"
        api_event "failed" "purge_paths" "Could not write project scan paths" "$(api_json_extra "$(api_json_field config_path "$PURGE_CONFIG_FILE")")"
        return 1
    fi

    api_event "completed" "purge_paths" "Project scan paths updated" "$(api_json_extra "$(api_json_number_field path_count "${#paths[@]}")" "$(api_json_field config_path "$PURGE_CONFIG_FILE")")"
}

api_update_status() {
    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api update status"

    local version="unknown"
    version=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$PROJECT_ROOT/roomy" | head -1)
    [[ -n "$version" ]] || version="unknown"

    local channel_file="${ROOMY_CONFIG_DIR:-$HOME/.config/roomy}/install_channel"
    [[ -f "$channel_file" ]] || channel_file="$PROJECT_ROOT/install_channel"

    local channel="stable"
    local commit=""
    if [[ -f "$channel_file" ]]; then
        channel=$(sed -n 's/^CHANNEL=\(.*\)$/\1/p' "$channel_file" | head -1)
        commit=$(sed -n 's/^COMMIT_HASH=\(.*\)$/\1/p' "$channel_file" | head -1)
    fi
    case "$channel" in
        nightly | dev | stable) ;;
        *) channel="stable" ;;
    esac

    local install_method="local"
    if command -v brew > /dev/null 2>&1 && brew list roomy > /dev/null 2>&1; then
        install_method="homebrew"
    fi

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "version": "%s",\n' "$(api_json_escape "$version")"
    printf '  "channel": "%s",\n' "$(api_json_escape "$channel")"
    printf '  "commit": "%s",\n' "$(api_json_escape "$commit")"
    printf '  "install_method": "%s",\n' "$(api_json_escape "$install_method")"
    printf '  "cli_path": "%s",\n' "$(api_json_escape "$PROJECT_ROOT/roomy")"
    printf '  "config_path": "%s"\n' "$(api_json_escape "${ROOMY_CONFIG_DIR:-$HOME/.config/roomy}")"
    printf '}\n'
}

api_execute_update() {
    local plan_file="$1"
    local dry_run="$2"
    local force=false
    local nightly=false
    api_plan_bool "$plan_file" "force" && force=true
    api_plan_bool "$plan_file" "nightly" && nightly=true

    local -a args=("update")
    $force && args+=("--force")
    $nightly && args+=("--nightly")

    if [[ "$dry_run" == "true" ]]; then
        api_event "started" "update"
        api_event "progress" "update" "Would run Roomy update" "$(api_json_extra "$(api_json_field command "roomy ${args[*]}")" "$(api_json_bool_field force "$force")" "$(api_json_bool_field nightly "$nightly")")"
        api_event "completed" "update" "" "$(api_json_extra "$(api_json_number_field exit_code 0)")"
        return 0
    fi

    TERM=dumb api_run_command_stream "update" "$PROJECT_ROOT/roomy" "${args[@]}"
}

api_execute_remove() {
    local dry_run="$2"

    local -a args=("remove")
    [[ "$dry_run" == "true" ]] && args+=("--dry-run")

    if [[ "$dry_run" == "true" ]]; then
        TERM=dumb api_run_command_stream "remove" "$PROJECT_ROOT/roomy" "${args[@]}"
    else
        ROOMY_API_AUTO_CONFIRM=1 TERM=dumb api_run_command_stream "remove" "$PROJECT_ROOT/roomy" "${args[@]}"
    fi
}

api_touchid_status() {
    # shellcheck source=bin/touchid.sh
    ROOMY_SKIP_MAIN=1 source "$SCRIPT_DIR/touchid.sh"

    local configured=false
    local supported=false
    is_touchid_configured && configured=true
    supports_touchid && supported=true

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "configured": %s,\n' "$configured"
    printf '  "supported": %s,\n' "$supported"
    printf '  "sudo_file": "%s",\n' "$(api_json_escape "$PAM_SUDO_FILE")"
    printf '  "sudo_local_file": "%s"\n' "$(api_json_escape "$PAM_SUDO_LOCAL_FILE")"
    printf '}\n'
}

api_completion_status() {
    local current_shell="${SHELL##*/}"
    [[ -n "$current_shell" ]] || current_shell="unknown"

    local config_file=""
    local installed=false
    case "$current_shell" in
        bash)
            config_file="$HOME/.bashrc"
            [[ -f "$HOME/.bash_profile" ]] && config_file="$HOME/.bash_profile"
            ;;
        zsh)
            config_file="$HOME/.zshrc"
            ;;
        fish)
            config_file="$HOME/.config/fish/completions/roomy.fish"
            ;;
    esac

    if [[ -n "$config_file" && -f "$config_file" ]]; then
        if [[ "$current_shell" == "fish" ]]; then
            installed=true
        elif grep -Eq "(roomy|mo)[[:space:]]+completion" "$config_file" 2> /dev/null; then
            installed=true
        fi
    fi

    local command_name=""
    if command -v roomy > /dev/null 2>&1; then
        command_name="roomy"
    elif command -v mo > /dev/null 2>&1; then
        command_name="mo"
    elif [[ -x "$PROJECT_ROOT/roomy" ]]; then
        command_name="$PROJECT_ROOT/roomy"
    elif [[ -x "$PROJECT_ROOT/mo" ]]; then
        command_name="$PROJECT_ROOT/mo"
    fi

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "shell": "%s",\n' "$(api_json_escape "$current_shell")"
    printf '  "config_file": "%s",\n' "$(api_json_escape "$config_file")"
    printf '  "installed": %s,\n' "$installed"
    printf '  "command_name": "%s"\n' "$(api_json_escape "$command_name")"
    printf '}\n'
}

api_completion_execute() {
    local command="${1:-}"
    shift || true
    [[ "$command" == "execute" ]] || api_error "usage" "Usage: roomy api completion execute --plan <json-file>"

    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown completion execute option: $1" ;;
        esac
        shift || true
    done

    [[ -n "$plan_file" && -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"
    api_validate_plan_or_emit "completion" "$plan_file" || return 1

    local -a args=()
    if api_plan_bool "$plan_file" "dry_run"; then
        args+=("--dry-run")
    fi
    ROOMY_API_AUTO_CONFIRM=1 api_run_command_stream "completion" "$SCRIPT_DIR/completion.sh" "${args[@]+"${args[@]}"}"
}

api_launcher_specs() {
    cat << 'EOF'
clean|Roomy Clean
uninstall|Roomy Uninstall
optimize|Roomy Optimize
analyze|Roomy Analyze
status|Roomy Status
EOF
}

api_launchers_status() {
    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api launchers status"

    local raycast_dir="$HOME/Library/Application Support/Raycast/script-commands"
    local alfred_dir="${ALFRED_PREFS_DIR:-$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences}/workflows"
    local raycast_count=0
    local alfred_count=0
    local command_count=0
    local records_file
    records_file=$(mktemp_file "roomy-api-launchers")
    : > "$records_file"

    local subcommand title raycast_installed alfred_installed
    while IFS='|' read -r subcommand title; do
        [[ -n "$subcommand" ]] || continue
        command_count=$((command_count + 1))
        raycast_installed=false
        alfred_installed=false

        if [[ -x "$raycast_dir/roomy-${subcommand}.sh" ]]; then
            raycast_installed=true
            raycast_count=$((raycast_count + 1))
        fi

        if [[ -d "$alfred_dir" ]] && grep -Rsl "fun.tw93.roomy.${subcommand}" "$alfred_dir"/*/info.plist > /dev/null 2>&1; then
            alfred_installed=true
            alfred_count=$((alfred_count + 1))
        fi

        printf '%s\t%s\t%s\t%s\n' "$subcommand" "$title" "$raycast_installed" "$alfred_installed" >> "$records_file"
    done < <(api_launcher_specs)

    local raycast_installed=false
    local alfred_installed=false
    [[ $raycast_count -eq $command_count && $command_count -gt 0 ]] && raycast_installed=true
    [[ $alfred_count -eq $command_count && $command_count -gt 0 ]] && alfred_installed=true

    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "raycast_dir": "%s",\n' "$(api_json_escape "$raycast_dir")"
    printf '  "raycast_installed": %s,\n' "$raycast_installed"
    printf '  "raycast_count": %s,\n' "$raycast_count"
    printf '  "alfred_dir": "%s",\n' "$(api_json_escape "$alfred_dir")"
    printf '  "alfred_available": %s,\n' "$([[ -d "$alfred_dir" ]] && echo true || echo false)"
    printf '  "alfred_installed": %s,\n' "$alfred_installed"
    printf '  "alfred_count": %s,\n' "$alfred_count"
    printf '  "command_count": %s,\n' "$command_count"
    printf '  "commands": [\n'

    local first=true
    while IFS=$'\t' read -r subcommand title raycast_installed alfred_installed; do
        [[ -n "$subcommand" ]] || continue
        if $first; then
            first=false
        else
            printf ',\n'
        fi
        printf '    {"command":"%s","title":"%s","raycast_installed":%s,"alfred_installed":%s}' \
            "$(api_json_escape "$subcommand")" \
            "$(api_json_escape "$title")" \
            "$raycast_installed" \
            "$alfred_installed"
    done < "$records_file"
    printf '\n'
    printf '  ]\n'
    printf '}\n'
}

api_launchers_execute() {
    local command="${1:-}"
    shift || true
    [[ "$command" == "execute" ]] || api_error "usage" "Usage: roomy api launchers execute --plan <json-file>"

    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown launchers execute option: $1" ;;
        esac
        shift || true
    done

    [[ -n "$plan_file" && -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"
    api_validate_plan_or_emit "launchers" "$plan_file" || return 1

    if api_plan_bool "$plan_file" "dry_run"; then
        api_event "started" "launchers"
        api_event "progress" "launchers" "Would install Raycast script commands" "$(api_json_extra "$(api_json_field path "$HOME/Library/Application Support/Raycast/script-commands")" "$(api_json_number_field command_count 5)")"
        api_event "progress" "launchers" "Would install Alfred workflows when Alfred preferences exist" "$(api_json_extra "$(api_json_number_field command_count 5)")"
        api_event "completed" "launchers" "" "$(api_json_extra "$(api_json_number_field exit_code 0)" "$(api_json_number_field command_count 5)")"
        return 0
    fi

    PATH="$PROJECT_ROOT:$PATH" ROOMY_CLI_PATH="$PROJECT_ROOT/roomy" api_run_command_stream "launchers" "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
}

api_touchid_execute() {
    local command="${1:-}"
    shift || true
    [[ "$command" == "execute" ]] || api_error "usage" "Usage: roomy api touchid execute --action <enable|disable> --plan <json-file>"

    local action=""
    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --action"
                action="$1"
                ;;
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown touchid execute option: $1" ;;
        esac
        shift || true
    done
    case "$action" in
        enable | disable) ;;
        *) api_error "usage" "Touch ID action must be enable or disable" ;;
    esac
    [[ -n "$plan_file" && -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"
    api_validate_plan_or_emit "touchid" "$plan_file" || return 1

    local -a args=("$action")
    if api_plan_bool "$plan_file" "dry_run"; then
        args+=("--dry-run")
    fi
    api_run_command_stream "touchid" "$SCRIPT_DIR/touchid.sh" "${args[@]}"
}

api_plan_raw() {
    local file="$1"
    local key="$2"

    command -v plutil > /dev/null 2>&1 ||
        api_error "missing_json_parser" "plutil is required to parse API plan JSON"

    plutil -extract "$key" raw -o - "$file" 2> /dev/null
}

api_plan_bool() {
    local file="$1"
    local key="$2"
    local value=""

    value=$(api_plan_raw "$file" "$key" 2> /dev/null || true)
    [[ "$value" == "true" ]]
}

api_plan_extract_array() {
    local file="$1"
    local key="$2"
    local index=0
    local value_file
    value_file=$(mktemp_file "roomy-api-plan-value")

    while api_plan_raw "$file" "$key.$index" > "$value_file" 2> /dev/null; do
        api_chomp_one_trailing_newline_file "$value_file"
        cat "$value_file"
        printf '\0'
        : > "$value_file"
        index=$((index + 1))
    done
}

api_chomp_one_trailing_newline_file() {
    local file="$1"
    [[ -s "$file" ]] || return 0

    local last_hex
    last_hex=$(tail -c 1 "$file" 2> /dev/null | od -An -tx1 | tr -d '[:space:]' || true)
    [[ "$last_hex" == "0a" ]] || return 0

    local size
    size=$(wc -c < "$file" 2> /dev/null | tr -d '[:space:]' || echo 0)
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || return 0

    truncate -s "$((size - 1))" "$file" 2> /dev/null ||
        perl -0pi -e 's/\n\z//' "$file" 2> /dev/null ||
        true
}

api_plan_string() {
    local file="$1"
    local key="$2"
    local value
    api_plan_string_to_var value "$file" "$key" || true
    printf '%s\n' "$value"
}

api_plan_string_to_var() {
    local target_var="$1"
    local file="$2"
    local key="$3"
    [[ "$target_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

    local value_file plan_string_value=""
    value_file=$(mktemp_file "roomy-api-plan-string")
    if api_plan_raw "$file" "$key" > "$value_file" 2> /dev/null; then
        api_chomp_one_trailing_newline_file "$value_file"
        IFS= read -r -d '' plan_string_value < <(cat "$value_file"; printf '\0')
    fi
    printf -v "$target_var" '%s' "$plan_string_value"
}

api_plan_key_exists() {
    local file="$1"
    local key="$2"
    plutil -extract "$key" raw -o - "$file" > /dev/null 2>&1
}

api_plan_type() {
    local file="$1"
    local key="$2"
    plutil -type "$key" "$file" 2> /dev/null || true
}

api_plan_array_count() {
    local file="$1"
    local key="$2"
    plutil -extract "$key" raw -expect array -o - "$file" 2> /dev/null
}

api_plan_validation_error() {
    API_PLAN_VALIDATION_ERROR="$1"
    return 1
}

api_plan_expect_optional_type() {
    local file="$1"
    local key="$2"
    local expected="$3"

    api_plan_key_exists "$file" "$key" || return 0

    local actual
    actual=$(api_plan_type "$file" "$key")
    [[ "$actual" == "$expected" ]] ||
        api_plan_validation_error "Plan field \"$key\" must be a $expected"
}

api_plan_expect_string_array() {
    local file="$1"
    local key="$2"

    local count
    count=$(api_plan_array_count "$file" "$key" 2> /dev/null) ||
        api_plan_validation_error "Plan field \"$key\" must be an array" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] ||
        api_plan_validation_error "Plan field \"$key\" must be an array" || return 1

    local index actual
    for ((index = 0; index < count; index++)); do
        actual=$(api_plan_type "$file" "$key.$index")
        [[ "$actual" == "string" ]] ||
            api_plan_validation_error "Plan field \"$key\" must contain only strings" || return 1
    done
}

api_plan_require_string_array() {
    local file="$1"
    local key="$2"
    local count

    api_plan_expect_string_array "$file" "$key" || return 1
    count=$(api_plan_array_count "$file" "$key" 2> /dev/null) ||
        api_plan_validation_error "Plan field \"$key\" must be an array" || return 1
    [[ "$count" -gt 0 ]] ||
        api_plan_validation_error "Plan field \"$key\" must contain at least one item" || return 1
}

api_plan_require_no_control_strings() {
    local file="$1"
    local key="$2"
    local value

    while IFS= read -r -d '' value; do
        [[ ! "$value" =~ [[:cntrl:]] ]] ||
            api_plan_validation_error "Plan field \"$key\" cannot contain control characters" || return 1
    done < <(api_plan_extract_array "$file" "$key")
}

api_validate_common_plan_schema() {
    local file="$1"

    if ! plutil -p "$file" > /dev/null 2>&1; then
        api_plan_validation_error "Plan JSON is invalid"
        return 1
    fi

    local confirmed_type
    confirmed_type=$(api_plan_type "$file" "confirmed")
    [[ "$confirmed_type" == "bool" ]] ||
        api_plan_validation_error "Plan field \"confirmed\" must be true" || return 1
    api_plan_bool "$file" "confirmed" ||
        api_plan_validation_error "Plan must include confirmed: true" || return 1

    api_plan_expect_optional_type "$file" "dry_run" "bool" || return 1
}

api_validate_execute_plan_schema() {
    local domain="$1"
    local file="$2"
    API_PLAN_VALIDATION_ERROR=""

    api_validate_common_plan_schema "$file" || return 1

    case "$domain" in
        storage)
            api_plan_require_string_array "$file" "targets" || return 1
            api_plan_expect_optional_type "$file" "scan_path" "string" || return 1
            api_plan_expect_optional_type "$file" "operation" "string" || return 1
            local operation
            api_plan_string_to_var operation "$file" "operation"
            case "$operation" in
                "" | reveal | open | trash) ;;
                *)
                    api_plan_validation_error "Plan field \"operation\" must be reveal, open, or trash"
                    return 1
                    ;;
            esac
            if [[ -z "$operation" || "$operation" == "trash" ]]; then
                api_plan_require_no_control_strings "$file" "targets" || return 1
            fi
            ;;
        clean)
            api_plan_expect_optional_type "$file" "external_path" "string" || return 1
            ;;
        uninstall)
            local key count any_targets=false
            for key in targets apps uninstall_names; do
                if api_plan_key_exists "$file" "$key"; then
                    api_plan_require_string_array "$file" "$key" || return 1
                    api_plan_require_no_control_strings "$file" "$key" || return 1
                    count=$(api_plan_array_count "$file" "$key" 2> /dev/null || echo 0)
                    [[ "$count" -gt 0 ]] && any_targets=true
                fi
            done
            $any_targets || api_plan_validation_error "Uninstall execute requires targets, apps, or uninstall_names" || return 1
            api_plan_expect_optional_type "$file" "permanent" "bool" || return 1
            ;;
        purge | installer)
            api_plan_require_string_array "$file" "targets" || return 1
            api_plan_require_no_control_strings "$file" "targets" || return 1
            ;;
        update)
            api_plan_expect_optional_type "$file" "force" "bool" || return 1
            api_plan_expect_optional_type "$file" "nightly" "bool" || return 1
            ;;
        remove | optimize | completion | launchers | touchid)
            ;;
        whitelist)
            api_plan_expect_string_array "$file" "patterns" || return 1
            api_plan_require_no_control_strings "$file" "patterns" || return 1
            ;;
        purge_paths)
            api_plan_expect_string_array "$file" "paths" || return 1
            api_plan_require_no_control_strings "$file" "paths" || return 1
            ;;
        *)
            api_plan_validation_error "Unknown executable API domain: $domain"
            ;;
    esac
}

api_validate_plan_or_emit() {
    local domain="$1"
    local file="$2"

    if api_validate_execute_plan_schema "$domain" "$file"; then
        return 0
    fi

    api_event "started" "$domain"
    api_event "failed" "$domain" "${API_PLAN_VALIDATION_ERROR:-Plan validation failed}"
    return 1
}

api_run_command_stream() {
    local domain="$1"
    shift

    api_event "started" "$domain"

    local rc=0
    set +e
    "$@" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && api_event "progress" "$domain" "$line"
    done
    rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -eq 0 ]]; then
        local completion_extra=""
        if [[ -n "${ROOMY_API_COMPLETION_METRICS_FILE:-}" ]]; then
            completion_extra=$(api_completion_metrics_extra "$ROOMY_API_COMPLETION_METRICS_FILE")
        fi
        api_event "completed" "$domain" "" "$(api_json_extra "$(api_json_number_field exit_code 0)" "$completion_extra")"
    else
        api_event "failed" "$domain" "Command failed" "$(api_json_extra "$(api_json_number_field exit_code "$rc")")"
    fi
    return "$rc"
}

api_completion_metrics_extra() {
    local metrics_file="$1"
    [[ -f "$metrics_file" ]] || return 0

    local -a fields=()
    local key value
    while IFS=$'\t' read -r key value; do
        case "$key" in
            bytes | item_count | category_count)
                fields+=("$(api_json_number_field "$key" "${value:-0}")")
                ;;
            free_space | equivalent)
                [[ -n "${value:-}" ]] && fields+=("$(api_json_field "$key" "$value")")
                ;;
        esac
    done < "$metrics_file"

    [[ ${#fields[@]} -gt 0 ]] || return 0
    api_json_extra "${fields[@]}"
}

api_expand_home_path() {
    local expanded
    api_expand_home_path_to_var expanded "$1" || return 1
    printf '%s\n' "$expanded"
}

api_expand_home_path_to_var() {
    local target_var="$1"
    local path="$2"
    [[ "$target_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$path" == "~"* ]] && path="${path/#\~/$HOME}"
    printf -v "$target_var" '%s' "$path"
}

api_installer_target_is_supported() {
    local path="$1"
    local lower_path
    lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"

    case "$lower_path" in
        *.dmg | *.pkg | *.mpkg | *.iso | *.xip | *.zip)
            return 0
            ;;
    esac

    return 1
}

api_installer_zip_has_payload() {
    local zip="$1"
    local cap=50
    local -a zip_list_cmd=()

    if command -v zipinfo > /dev/null 2>&1; then
        zip_list_cmd=(zipinfo -1)
    elif command -v unzip > /dev/null 2>&1; then
        zip_list_cmd=(unzip -Z -1)
    else
        return 1
    fi

    "${zip_list_cmd[@]}" "$zip" 2> /dev/null |
        head -n "$cap" |
        awk '
            {
                entry=tolower($0)
                if (entry ~ /\.(app|pkg|dmg|xip)(\/|$)/) {
                    found=1
                    exit 0
                }
            }
            END { exit found ? 0 : 1 }
        '
}

api_installer_target_needs_zip_payload_check() {
    local path="$1"
    local lower_path
    lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    [[ "$lower_path" == *.zip && -f "$path" && ! -L "$path" ]]
}

api_execute_installer_targets() {
    local plan_file="$1"
    local dry_run="$2"
    local -a targets=()
    local target

    while IFS= read -r -d '' target; do
        [[ -n "$target" ]] && targets+=("$target")
    done < <(api_plan_extract_array "$plan_file" "targets")

    [[ ${#targets[@]} -gt 0 ]] || {
        api_event "failed" "installer" "Installer execute requires a targets array"
        return 1
    }

    api_event "started" "installer"
    local removed_count=0
    local total_bytes=0
    local failed=0

    for target in "${targets[@]}"; do
        local expanded
        api_expand_home_path_to_var expanded "$target"

        if ! api_installer_target_is_supported "$expanded"; then
            api_event "skipped" "installer" "Unsupported installer target" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
            continue
        fi

        if [[ ! -e "$expanded" && ! -L "$expanded" ]]; then
            api_event "skipped" "installer" "Path does not exist" "$(api_json_extra "$(api_json_field path "$expanded")")"
            continue
        fi

        if api_installer_target_needs_zip_payload_check "$expanded" && ! api_installer_zip_has_payload "$expanded"; then
            api_event "skipped" "installer" "ZIP does not contain installer payload" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
            continue
        fi

        if ! validate_path_for_deletion "$expanded" > /dev/null 2>&1; then
            api_event "skipped" "installer" "Path failed deletion validation" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
            continue
        fi

        local bytes=0
        bytes=$(get_file_size "$expanded")
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

        if [[ "$dry_run" == "true" ]]; then
            api_event "progress" "installer" "Would remove installer" "$(api_json_extra "$(api_json_field path "$expanded")" "$(api_json_number_field bytes "$bytes")")"
            total_bytes=$((total_bytes + bytes))
            removed_count=$((removed_count + 1))
        elif safe_remove "$expanded" true; then
            api_event "progress" "installer" "Removed installer" "$(api_json_extra "$(api_json_field path "$expanded")" "$(api_json_number_field bytes "$bytes")")"
            total_bytes=$((total_bytes + bytes))
            removed_count=$((removed_count + 1))
        else
            api_event "warning" "installer" "Failed to remove installer" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
        fi
    done

    if [[ $failed -eq 0 ]]; then
        api_event "completed" "installer" "" "$(api_json_extra "$(api_json_number_field removed_count "$removed_count")" "$(api_json_number_field bytes "$total_bytes")")"
        return 0
    fi
    api_event "failed" "installer" "One or more installer targets failed" "$(api_json_extra "$(api_json_number_field removed_count "$removed_count")" "$(api_json_number_field bytes "$total_bytes")")"
    return 1
}

api_execute_purge_targets() {
    local plan_file="$1"
    local dry_run="$2"
    local -a targets=()
    local target

    while IFS= read -r -d '' target; do
        [[ -n "$target" ]] && targets+=("$target")
    done < <(api_plan_extract_array "$plan_file" "targets")

    [[ ${#targets[@]} -gt 0 ]] || {
        api_event "failed" "purge" "Purge execute requires a targets array"
        return 1
    }

    # shellcheck source=lib/clean/project.sh
    source "$PROJECT_ROOT/lib/clean/project.sh"

    api_event "started" "purge"
    local removed_count=0
    local total_kb=0
    local failed=0

    for target in "${targets[@]}"; do
        local expanded safe_target=false search_path=""
        api_expand_home_path_to_var expanded "$target"

        for search_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
            if is_safe_project_artifact "$expanded" "$search_path"; then
                safe_target=true
                break
            fi
        done

        if ! $safe_target; then
            api_event "skipped" "purge" "Path is outside configured project artifact roots" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
            continue
        fi

        if [[ ! -e "$expanded" && ! -L "$expanded" ]]; then
            api_event "skipped" "purge" "Path does not exist" "$(api_json_extra "$(api_json_field path "$expanded")")"
            continue
        fi

        if ! validate_path_for_deletion "$expanded" > /dev/null 2>&1; then
            api_event "skipped" "purge" "Path failed deletion validation" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
            continue
        fi

        local size_kb=0
        size_kb=$(get_dir_size_kb "$expanded")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$dry_run" == "true" ]]; then
            api_event "progress" "purge" "Would remove project artifact" "$(api_json_extra "$(api_json_field path "$expanded")" "$(api_json_number_field bytes "$((size_kb * 1024))")")"
            total_kb=$((total_kb + size_kb))
            removed_count=$((removed_count + 1))
        elif safe_remove "$expanded" true; then
            api_event "progress" "purge" "Removed project artifact" "$(api_json_extra "$(api_json_field path "$expanded")" "$(api_json_number_field bytes "$((size_kb * 1024))")")"
            total_kb=$((total_kb + size_kb))
            removed_count=$((removed_count + 1))
        else
            api_event "warning" "purge" "Failed to remove project artifact" "$(api_json_extra "$(api_json_field path "$expanded")")"
            failed=1
        fi
    done

    if [[ $failed -eq 0 ]]; then
        api_event "completed" "purge" "" "$(api_json_extra "$(api_json_number_field removed_count "$removed_count")" "$(api_json_number_field bytes "$((total_kb * 1024))")")"
        return 0
    fi
    api_event "failed" "purge" "One or more purge targets failed" "$(api_json_extra "$(api_json_number_field removed_count "$removed_count")" "$(api_json_number_field bytes "$((total_kb * 1024))")")"
    return 1
}

api_execute_uninstall() {
    local plan_file="$1"
    local dry_run="$2"
    local -a targets=()
    local target key

    for key in targets apps uninstall_names; do
        while IFS= read -r -d '' target; do
            [[ -n "$target" ]] && targets+=("$target")
        done < <(api_plan_extract_array "$plan_file" "$key")
        [[ ${#targets[@]} -gt 0 ]] && break
    done

    [[ ${#targets[@]} -gt 0 ]] || {
        api_event "failed" "uninstall" "Uninstall execute requires targets, apps, or uninstall_names"
        return 1
    }

    local -a args=()
    [[ "$dry_run" == "true" ]] && args+=("--dry-run")
    if api_plan_bool "$plan_file" "permanent"; then
        args+=("--permanent")
    fi
    args+=("--")
    args+=("${targets[@]}")

    ROOMY_API_AUTO_CONFIRM=1 api_run_command_stream "uninstall" "$SCRIPT_DIR/uninstall.sh" "${args[@]}"
}

api_execute() {
    local domain="$1"
    shift
    local command="${1:-}"
    shift || true
    [[ "$command" == "execute" ]] || api_error "usage" "Usage: roomy api <domain> execute --plan <json-file>"

    local plan_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan)
                shift
                [[ $# -gt 0 ]] || api_error "usage" "Missing value for --plan"
                plan_file="$1"
                ;;
            *) api_error "usage" "Unknown execute option: $1" ;;
        esac
        shift || true
    done

    [[ -n "$plan_file" ]] || api_error "usage" "Usage: roomy api <domain> execute --plan <json-file>"
    [[ -f "$plan_file" ]] || api_error "invalid_plan" "Plan file does not exist: $plan_file"

    api_validate_plan_or_emit "$domain" "$plan_file" || return 1

    local dry_run=false
    if api_plan_bool "$plan_file" "dry_run"; then
        dry_run=true
    fi

    case "$domain" in
        clean)
            local -a args=()
            [[ "$dry_run" == "true" ]] && args+=("--dry-run")
            local external_path
            api_plan_string_to_var external_path "$plan_file" "external_path"
            if [[ -n "$external_path" ]]; then
                args+=("--external" "$external_path")
            fi
            local clean_metrics_file
            clean_metrics_file=$(mktemp_file "roomy-api-clean-metrics")
            ROOMY_API_COMPLETION_METRICS_FILE="$clean_metrics_file" \
                ROOMY_API_CLEAN_METRICS_FILE="$clean_metrics_file" \
                ROOMY_SKIP_TRASH_CLEANUP="${ROOMY_SKIP_TRASH_CLEANUP:-1}" \
                ROOMY_DELETE_MODE="${ROOMY_DELETE_MODE:-trash}" \
                ROOMY_TRASH_STRICT="${ROOMY_TRASH_STRICT:-1}" \
                ROOMY_TRASH_NO_APPLESCRIPT="${ROOMY_TRASH_NO_APPLESCRIPT:-1}" \
                api_run_command_stream "clean" "$SCRIPT_DIR/clean.sh" "${args[@]+"${args[@]}"}"
            ;;
        optimize)
            local -a args=()
            [[ "$dry_run" == "true" ]] && args+=("--dry-run")
            api_run_command_stream "optimize" "$SCRIPT_DIR/optimize.sh" "${args[@]+"${args[@]}"}"
            ;;
        uninstall)
            api_execute_uninstall "$plan_file" "$dry_run"
            ;;
        purge)
            api_execute_purge_targets "$plan_file" "$dry_run"
            ;;
        installer)
            api_execute_installer_targets "$plan_file" "$dry_run"
            ;;
        update)
            api_execute_update "$plan_file" "$dry_run"
            ;;
        remove)
            api_execute_remove "$plan_file" "$dry_run"
            ;;
        *)
            api_error "usage" "Unknown executable API domain: $domain"
            ;;
    esac
}

show_api_help() {
    cat << 'EOF'
Roomy JSON API

Usage:
  roomy api status
  roomy api storage scan --path <path>
  roomy api storage execute --plan <json-file>
  roomy api apps list --json
  roomy api optimize preview
  roomy api clean preview --json [--external <path>]
  roomy api purge preview --json
  roomy api installer preview --json
  roomy api whitelist list --mode <clean|optimize>
  roomy api whitelist update --mode <clean|optimize> --plan <json-file>
  roomy api purge paths --json
  roomy api purge paths update --plan <json-file>
  roomy api update status
  roomy api completion status
  roomy api completion execute --plan <json-file>
  roomy api launchers status
  roomy api launchers execute --plan <json-file>
  roomy api touchid status
  roomy api touchid execute --action <enable|disable> --plan <json-file>
  roomy api <clean|uninstall|purge|installer|optimize|update|remove> execute --plan <json-file>

Execute plan files must contain "confirmed": true. Destructive actions stream
newline-delimited JSON events.
EOF
}

main() {
    local domain="${1:-}"
    shift || true

    case "$domain" in
        "" | "--help" | "-h" | help)
            show_api_help
            ;;
        status)
            api_status "$@"
            ;;
        storage)
            api_storage "$@"
            ;;
        apps)
            api_apps "$@"
            ;;
        optimize)
            if [[ "${1:-}" == "execute" ]]; then
                api_execute "optimize" "$@"
            else
                api_optimize "$@"
            fi
            ;;
        clean)
            if [[ "${1:-}" == "execute" ]]; then
                api_execute "clean" "$@"
            else
                api_clean "$@"
            fi
            ;;
        purge)
            if [[ "${1:-}" == "preview" ]]; then
                shift || true
                [[ "${1:-}" == "--json" ]] || api_error "usage" "Usage: roomy api purge preview --json"
                shift || true
                api_purge_preview "$@"
            elif [[ "${1:-}" == "paths" ]]; then
                shift || true
                if [[ "${1:-}" == "--json" ]]; then
                    shift || true
                    api_purge_paths_list "$@"
                elif [[ "${1:-}" == "update" ]]; then
                    shift || true
                    api_purge_paths_update "$@"
                else
                    api_error "usage" "Usage: roomy api purge paths --json OR roomy api purge paths update --plan <json-file>"
                fi
            else
                api_execute "$domain" "$@"
            fi
            ;;
        installer)
            if [[ "${1:-}" == "preview" ]]; then
                shift || true
                [[ "${1:-}" == "--json" ]] || api_error "usage" "Usage: roomy api installer preview --json"
                shift || true
                api_installer_preview "$@"
            else
                api_execute "$domain" "$@"
            fi
            ;;
        uninstall)
            api_execute "$domain" "$@"
            ;;
        update)
            if [[ "${1:-}" == "status" ]]; then
                shift || true
                api_update_status "$@"
            else
                api_execute "$domain" "$@"
            fi
            ;;
        remove)
            api_execute "$domain" "$@"
            ;;
        whitelist)
            case "${1:-}" in
                list)
                    shift || true
                    api_whitelist_list "$@"
                    ;;
                update)
                    shift || true
                    api_whitelist_update "$@"
                    ;;
                *)
                    api_error "usage" "Usage: roomy api whitelist <list|update>"
                    ;;
            esac
            ;;
        completion)
            case "${1:-}" in
                status)
                    shift || true
                    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api completion status"
                    api_completion_status
                    ;;
                execute)
                    api_completion_execute "$@"
                    ;;
                *)
                    api_error "usage" "Usage: roomy api completion <status|execute>"
                    ;;
            esac
            ;;
        launchers)
            case "${1:-}" in
                status)
                    shift || true
                    api_launchers_status "$@"
                    ;;
                execute)
                    api_launchers_execute "$@"
                    ;;
                *)
                    api_error "usage" "Usage: roomy api launchers <status|execute>"
                    ;;
            esac
            ;;
        touchid)
            case "${1:-}" in
                status)
                    shift || true
                    [[ $# -eq 0 ]] || api_error "usage" "Usage: roomy api touchid status"
                    api_touchid_status
                    ;;
                execute)
                    api_touchid_execute "$@"
                    ;;
                *)
                    api_error "usage" "Usage: roomy api touchid <status|execute>"
                    ;;
            esac
            ;;
        *)
            api_error "usage" "Unknown API domain: $domain"
            ;;
    esac
}

main "$@"
