#!/bin/bash
# Roomy - Clean command.
# Runs cleanup modules with optional sudo.
# Supports dry-run and whitelist.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

source "$SCRIPT_DIR/../lib/core/sudo.sh"
source "$SCRIPT_DIR/../lib/clean/brew.sh"
source "$SCRIPT_DIR/../lib/clean/caches.sh"
source "$SCRIPT_DIR/../lib/clean/apps.sh"
source "$SCRIPT_DIR/../lib/clean/dev.sh"
source "$SCRIPT_DIR/../lib/clean/app_caches.sh"
source "$SCRIPT_DIR/../lib/clean/hints.sh"
source "$SCRIPT_DIR/../lib/clean/system.sh"
source "$SCRIPT_DIR/../lib/clean/user.sh"

SYSTEM_CLEAN=false
DRY_RUN=false
PROTECT_FINDER_METADATA=false
EXTERNAL_VOLUME_TARGET=""
IS_M_SERIES=$([[ "$(uname -m)" == "arm64" ]] && echo "true" || echo "false")

ROOMY_CONFIG_DIR="${ROOMY_CONFIG_DIR:-$HOME/.config/roomy}"
EXPORT_LIST_FILE="$ROOMY_CONFIG_DIR/clean-list.txt"
export ROOMY_DELETE_MODE="${ROOMY_DELETE_MODE:-trash}"
export ROOMY_TRASH_STRICT="${ROOMY_TRASH_STRICT:-1}"
export ROOMY_TRASH_NO_APPLESCRIPT="${ROOMY_TRASH_NO_APPLESCRIPT:-1}"
CURRENT_SECTION=""
readonly PROTECTED_SW_DOMAINS=(
    # Web editors
    "capcut.com"
    "photopea.com"
    "pixlr.com"
    # Google Workspace (offline mode)
    "docs.google.com"
    "sheets.google.com"
    "slides.google.com"
    "drive.google.com"
    "mail.google.com"
    # Code platforms (offline/PWA)
    "github.com"
    "gitlab.com"
    "codepen.io"
    "codesandbox.io"
    "replit.com"
    "stackblitz.com"
    # Collaboration tools (offline/PWA)
    "notion.so"
    "figma.com"
    "linear.app"
    "excalidraw.com"
)

declare -a WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
CLEAN_INCLUDE_CATEGORIES=()
CLEAN_EXCLUDE_CATEGORIES=()
AUTO_YES=false
MAX_DELETE_BYTES=0
MAX_RISK_LEVEL=""
REQUIRE_DRY_RUN_HOURS=""

readonly CLEAN_CATEGORY_SPECS=(
    "system|System caches and rebuildable system data"
    "user-essentials|User logs, temp files, Trash, recent items"
    "app-caches|Application caches and sandbox caches"
    "browsers|Browser caches and old browser versions"
    "cloud-office|Cloud storage and Office caches"
    "developer|Developer tool caches"
    "applications|Known GUI application caches"
    "virtualization|Virtualization tool caches"
    "app-support|Application Support logs and temporary data"
    "leftovers|Already-uninstalled app leftovers"
    "apple-silicon|Apple Silicon and Rosetta caches"
    "device-backups|Cached device firmware and backup hints"
    "time-machine|Failed Time Machine backup cleanup"
    "large-files|Review-only large file hints"
    "system-data|Review-only System Data clues"
    "project-artifacts|Review-only project artifact hints"
    "external|External volume metadata cleanup"
)

clean_export_write_lines() {
    local parent tmp_file

    parent=$(dirname "$EXPORT_LIST_FILE")
    ensure_user_dir "$parent"

    tmp_file=$(mktemp "$parent/.clean-list.XXXXXX") || return 1
    if ! printf '%s\n' "$@" > "$tmp_file"; then
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    fi
    commit_staged_user_file "$tmp_file" "$EXPORT_LIST_FILE"
}

# shellcheck disable=SC2329  # Called by sourced cleanup modules and dry-run grouping loops.
clean_export_append_line() {
    local line="${1:-}"
    append_log_line "$EXPORT_LIST_FILE" "$line"
}

clean_export_append_lines() {
    append_log_lines "$EXPORT_LIST_FILE" "$@"
}

if [[ -f "$ROOMY_CONFIG_DIR/whitelist" ]]; then
    while IFS= read -r line; do
        # shellcheck disable=SC2295
        line="${line#"${line%%[![:space:]]*}"}"
        # shellcheck disable=SC2295
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        [[ "$line" == ~* ]] && line="${line/#~/$HOME}"
        line="${line//\$HOME/$HOME}"
        line="${line//\$\{HOME\}/$HOME}"
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
    done < "$ROOMY_CONFIG_DIR/whitelist"
else
    WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
fi

# Expand whitelist patterns once to avoid repeated tilde expansion in hot loops.
expand_whitelist_patterns() {
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local -a EXPANDED_PATTERNS
        EXPANDED_PATTERNS=()
        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local expanded="${pattern/#\~/$HOME}"
            EXPANDED_PATTERNS+=("$expanded")
        done
        WHITELIST_PATTERNS=("${EXPANDED_PATTERNS[@]}")
    fi
}
expand_whitelist_patterns

if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            PROTECT_FINDER_METADATA=true
            break
        fi
    done
fi

clean_category_key() {
    local raw="$1"
    raw=$(printf '%s' "$raw" | tr '[:upper:] _' '[:lower:]--')
    raw="${raw//--/-}"
    case "$raw" in
        user | essentials) raw="user-essentials" ;;
        apps | application | app) raw="applications" ;;
        browser) raw="browsers" ;;
        cloud | office | cloud-and-office | cloud-office) raw="cloud-office" ;;
        dev | developer-tools) raw="developer" ;;
        support | application-support) raw="app-support" ;;
        leftovers | app-leftovers) raw="leftovers" ;;
        apple | silicon | rosetta | apple-silicon-updates) raw="apple-silicon" ;;
        devices | firmware | backups | device-backups-and-firmware) raw="device-backups" ;;
        timemachine | time-machine-failed-backups) raw="time-machine" ;;
        large | large-file) raw="large-files" ;;
        systemdata | system-data-clues) raw="system-data" ;;
        projects | project | artifacts | project-artifact) raw="project-artifacts" ;;
    esac
    printf '%s\n' "$raw"
}

clean_category_exists() {
    local key="$1"
    local spec
    for spec in "${CLEAN_CATEGORY_SPECS[@]}"; do
        [[ "${spec%%|*}" == "$key" ]] && return 0
    done
    return 1
}

clean_parse_category_list() {
    local target="$1"
    local list="$2"
    local item key
    list="${list//,/ }"
    for item in $list; do
        key=$(clean_category_key "$item")
        if ! clean_category_exists "$key"; then
            echo "Unknown cleanup category: $item" >&2
            echo "Run 'roomy clean --list-categories' for valid category keys." >&2
            return 1
        fi
        if [[ "$target" == "include" ]]; then
            CLEAN_INCLUDE_CATEGORIES+=("$key")
        else
            CLEAN_EXCLUDE_CATEGORIES+=("$key")
        fi
    done
}

clean_array_contains() {
    local needle="$1"
    shift || true
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

should_run_clean_category() {
    local key="$1"
    if [[ ${#CLEAN_INCLUDE_CATEGORIES[@]} -gt 0 ]] && ! clean_array_contains "$key" "${CLEAN_INCLUDE_CATEGORIES[@]}"; then
        return 1
    fi
    if [[ ${#CLEAN_EXCLUDE_CATEGORIES[@]} -gt 0 ]] && clean_array_contains "$key" "${CLEAN_EXCLUDE_CATEGORIES[@]}"; then
        return 1
    fi
    return 0
}

show_clean_categories() {
    local spec
    for spec in "${CLEAN_CATEGORY_SPECS[@]}"; do
        printf '%-18s %s\n' "${spec%%|*}" "${spec#*|}"
    done
}

clean_join_csv() {
    local first=true
    local item
    for item in "$@"; do
        if $first; then
            first=false
        else
            printf ','
        fi
        printf '%s' "$item"
    done
}

parse_clean_size_gb() {
    local value="$1"
    awk -v n="$value" 'BEGIN {
        if (n !~ /^[0-9]+([.][0-9]+)?$/) exit 1
        printf "%.0f\n", n * 1073741824
    }'
}

clean_risk_rank() {
    case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
        LOW) printf '1\n' ;;
        MEDIUM) printf '2\n' ;;
        HIGH) printf '3\n' ;;
        *) printf '2\n' ;;
    esac
}

validate_clean_risk_level() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        low | medium | high) return 0 ;;
        *) return 1 ;;
    esac
}

check_required_dry_run_age() {
    [[ -n "$REQUIRE_DRY_RUN_HOURS" ]] || return 0
    [[ "$REQUIRE_DRY_RUN_HOURS" =~ ^[0-9]+$ ]] || {
        echo "Invalid --require-dry-run-age value: $REQUIRE_DRY_RUN_HOURS" >&2
        return 1
    }
    [[ -f "$EXPORT_LIST_FILE" && ! -L "$EXPORT_LIST_FILE" ]] || {
        echo "No cleanup dry-run preview found at ${EXPORT_LIST_FILE/#$HOME/~}" >&2
        return 1
    }

    local modified now age_seconds max_seconds
    modified=$(stat -f %m "$EXPORT_LIST_FILE" 2> /dev/null || echo 0)
    now=$(date +%s)
    [[ "$modified" =~ ^[0-9]+$ && "$modified" -gt 0 ]] || return 1
    age_seconds=$((now - modified))
    max_seconds=$((REQUIRE_DRY_RUN_HOURS * 3600))
    if ((age_seconds > max_seconds)); then
        echo "Cleanup dry-run preview is older than ${REQUIRE_DRY_RUN_HOURS}h: ${EXPORT_LIST_FILE/#$HOME/~}" >&2
        return 1
    fi
}

clean_automation_preflight() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ "${ROOMY_AUTOMATION_PREFLIGHT:-0}" == "1" ]] && return 0

    check_required_dry_run_age || return 1

    if [[ "$MAX_DELETE_BYTES" -le 0 && -z "$MAX_RISK_LEVEL" ]]; then
        return 0
    fi

    local capture_file metrics_file output_file
    capture_file=$(create_temp_file)
    metrics_file=$(create_temp_file)
    output_file=$(create_temp_file)

    local -a preflight_args=(--dry-run)
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        preflight_args+=(--external "$EXTERNAL_VOLUME_TARGET")
    fi
    if [[ ${#CLEAN_INCLUDE_CATEGORIES[@]} -gt 0 ]]; then
        preflight_args+=(--categories "$(clean_join_csv "${CLEAN_INCLUDE_CATEGORIES[@]}")")
    fi
    if [[ ${#CLEAN_EXCLUDE_CATEGORIES[@]} -gt 0 ]]; then
        preflight_args+=(--exclude "$(clean_join_csv "${CLEAN_EXCLUDE_CATEGORIES[@]}")")
    fi

    if ! ROOMY_AUTOMATION_PREFLIGHT=1 ROOMY_API_CLEAN_CAPTURE_FILE="$capture_file" ROOMY_API_CLEAN_METRICS_FILE="$metrics_file" "$0" "${preflight_args[@]}" > "$output_file" 2>&1; then
        echo "Automation preflight dry-run failed. Re-run with --dry-run --debug for details." >&2
        return 1
    fi

    local estimated_bytes=0
    if [[ -f "$metrics_file" ]]; then
        estimated_bytes=$(awk -F'\t' '$1 == "bytes" { print $2; found=1 } END { if (!found) print 0 }' "$metrics_file")
    fi
    [[ "$estimated_bytes" =~ ^[0-9]+$ ]] || estimated_bytes=0

    if [[ "$MAX_DELETE_BYTES" -gt 0 && "$estimated_bytes" -gt "$MAX_DELETE_BYTES" ]]; then
        echo "Cleanup estimate $(bytes_to_human "$estimated_bytes") exceeds --max-delete-gb limit $(bytes_to_human "$MAX_DELETE_BYTES")." >&2
        return 1
    fi

    if [[ -n "$MAX_RISK_LEVEL" && -f "$capture_file" ]]; then
        local allowed_rank found_risk found_rank
        allowed_rank=$(clean_risk_rank "$MAX_RISK_LEVEL")
        while IFS=$'\t' read -r _kind _section _description _size _count _skipped found_risk _reason _admin _skip; do
            [[ -n "$found_risk" ]] || continue
            found_rank=$(clean_risk_rank "$found_risk")
            if [[ "$found_rank" -gt "$allowed_rank" ]]; then
                echo "Cleanup preflight found $found_risk risk item above --max-risk $MAX_RISK_LEVEL: $_description" >&2
                return 1
            fi
        done < "$capture_file"
    fi

    echo "Automation preflight passed: estimated $(bytes_to_human "$estimated_bytes")"
}

# Section tracking and summary counters.
total_items=0
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0
PROJECT_ARTIFACT_HINT_DETECTED=false
PROJECT_ARTIFACT_HINT_COUNT=0
PROJECT_ARTIFACT_HINT_TRUNCATED=false
PROJECT_ARTIFACT_HINT_EXAMPLES=()
PROJECT_ARTIFACT_HINT_ESTIMATED_KB=0
PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=0
PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false
declare -a DRY_RUN_SEEN_IDENTITIES=()

# shellcheck disable=SC2329
note_activity() {
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

# shellcheck disable=SC2329
register_dry_run_cleanup_target() {
    local path="$1"
    local identity
    identity=$(roomy_path_identity "$path")

    if [[ ${#DRY_RUN_SEEN_IDENTITIES[@]} -gt 0 ]] && roomy_identity_in_list "$identity" "${DRY_RUN_SEEN_IDENTITIES[@]}"; then
        return 1
    fi

    DRY_RUN_SEEN_IDENTITIES+=("$identity")
    return 0
}

# shellcheck disable=SC2329
api_capture_clean_field() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

# shellcheck disable=SC2329
api_capture_clean_record() {
    [[ -n "${ROOMY_API_CLEAN_CAPTURE_FILE:-}" ]] || return 0

    local kind="$1"
    local section="${2:-}"
    local description="${3:-}"
    local sample_path="${4:-}"
    local size_kb="${5:-0}"
    local item_count="${6:-0}"
    local skipped_count="${7:-0}"
    local skip_reason="${8:-}"

    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    [[ "$item_count" =~ ^[0-9]+$ ]] || item_count=0
    [[ "$skipped_count" =~ ^[0-9]+$ ]] || skipped_count=0

    local risk_info risk_level risk_reason admin_required="false"
    risk_info=$(classify_cleanup_risk "$description" "$sample_path")
    risk_level="${risk_info%%|*}"
    risk_reason="${risk_info#*|}"

    case "$sample_path" in
        /System | /System/* | /Library | /Library/* | /private/var/db/* | /var/db/*)
            admin_required="true"
            ;;
    esac

    if [[ "$risk_level" == "HIGH" ]]; then
        admin_required="true"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(api_capture_clean_field "$kind")" \
        "$(api_capture_clean_field "$section")" \
        "$(api_capture_clean_field "$description")" \
        "$size_kb" "$item_count" \
        "$skipped_count" \
        "$(api_capture_clean_field "$risk_level")" \
        "$(api_capture_clean_field "$risk_reason")" \
        "$(api_capture_clean_field "$admin_required")" \
        "$(api_capture_clean_field "$skip_reason")" \
        >> "$ROOMY_API_CLEAN_CAPTURE_FILE" 2> /dev/null || true
}

CLEANUP_DONE=false
# shellcheck disable=SC2329
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    stop_inline_spinner 2> /dev/null || true

    cleanup_temp_files

    stop_sudo_session

    show_cursor
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

# IMPORTANT: This file overrides start_section / end_section from
# lib/core/base.sh by virtue of being sourced after it. The clean variant adds
# CURRENT_SECTION tracking, dry-run EXPORT_LIST_FILE writes and a section
# spinner stop. See the cross-reference block in lib/core/base.sh and the
# differing purge variant in bin/purge.sh before changing any of these three.
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"

    if [[ "$DRY_RUN" == "true" ]]; then
        clean_export_append_lines "" "=== $1 ==="
    fi
}

end_section() {
    stop_section_spinner

    if [[ "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to clean"
    fi
    TRACK_SECTION=0
}

# shellcheck disable=SC2329
normalize_paths_for_cleanup() {
    local -a input_paths=("$@")

    # Fast path for large batches: O(n log n) via sort|awk instead of O(n²) bash loops.
    # Lex sort guarantees every parent path precedes its children, so a single-pass
    # awk can filter child paths by tracking only the last kept path.
    # Paths with embedded newlines cannot go through the newline-delimited pipeline;
    # they are output directly with null-byte delimiters and skipped by the sort pass.
    if [[ ${#input_paths[@]} -gt 50 ]]; then
        local -a _fast_pipeline=()
        local _fast_path
        for _fast_path in "${input_paths[@]}"; do
            if [[ "$_fast_path" == *$'\n'* ]]; then
                printf '%s\0' "$_fast_path"
            else
                _fast_pipeline+=("$_fast_path")
            fi
        done
        if [[ ${#_fast_pipeline[@]} -gt 0 ]]; then
            printf '%s\n' "${_fast_pipeline[@]}" |
                awk '{sub(/\/$/, ""); if ($0 != "") print}' |
                LC_ALL=C sort -u |
                awk 'BEGIN { last = "" } {
                    if (last != "" && substr($0, 1, length(last) + 1) == last "/") next
                    last = $0; print
                }' |
                while IFS= read -r _fast_path; do printf '%s\0' "$_fast_path"; done
        fi
        return
    fi

    local -a unique_paths=()

    for path in "${input_paths[@]}"; do
        local normalized="${path%/}"
        [[ -z "$normalized" ]] && normalized="$path"
        local found=false
        if [[ ${#unique_paths[@]} -gt 0 ]]; then
            for existing in "${unique_paths[@]}"; do
                if [[ "$existing" == "$normalized" ]]; then
                    found=true
                    break
                fi
            done
        fi
        [[ "$found" == "true" ]] || unique_paths+=("$normalized")
    done

    # Paths with embedded newlines cannot safely go through the newline-delimited
    # sort pipeline. Collect them separately and append to result as-is.
    local -a pipeline_paths=()
    local -a passthrough_paths=()
    for path in "${unique_paths[@]}"; do
        if [[ "$path" == *$'\n'* ]]; then
            passthrough_paths+=("$path")
        else
            pipeline_paths+=("$path")
        fi
    done

    local sorted_paths
    if [[ ${#pipeline_paths[@]} -gt 0 ]]; then
        sorted_paths=$(printf '%s\n' "${pipeline_paths[@]}" | awk '{print length "|" $0}' | LC_ALL=C sort -n | cut -d'|' -f2-)
    else
        sorted_paths=""
    fi

    local -a result_paths=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local is_child=false
        if [[ ${#result_paths[@]} -gt 0 ]]; then
            for kept in "${result_paths[@]}"; do
                if [[ "$path" == "$kept" || "$path" == "$kept"/* ]]; then
                    is_child=true
                    break
                fi
            done
        fi
        [[ "$is_child" == "true" ]] || result_paths+=("$path")
    done <<< "$sorted_paths"

    # Append passthrough paths (newline-containing; not deduplicated against others).
    if [[ ${#passthrough_paths[@]} -gt 0 ]]; then
        result_paths+=("${passthrough_paths[@]}")
    fi

    if [[ ${#result_paths[@]} -gt 0 ]]; then
        printf '%s\0' "${result_paths[@]}"
    fi
}

# shellcheck disable=SC2329
get_cleanup_path_size_kb() {
    local path="$1"

    if [[ -f "$path" && ! -L "$path" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local bytes
            bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
            if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
                echo $(((bytes + 1023) / 1024))
                return 0
            fi
        fi
    fi

    if [[ -L "$path" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local bytes
            bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
            if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
                echo $(((bytes + 1023) / 1024))
            else
                echo 0
            fi
            return 0
        fi
    fi

    get_path_size_kb "$path"
}

# Classification helper for cleanup risk levels
# shellcheck disable=SC2329
classify_cleanup_risk() {
    local description="$1"
    local path="${2:-}"

    # HIGH RISK: System files, preference files, require sudo
    if [[ "$description" =~ [Ss]ystem || "$description" =~ [Ss]udo || "$path" =~ ^/System || "$path" =~ ^/Library ]]; then
        echo "HIGH|System files or requires admin access"
        return
    fi

    # HIGH RISK: Preference files that might affect app functionality
    if [[ "$description" =~ [Pp]reference || "$path" =~ /Preferences/ ]]; then
        echo "HIGH|Preference files may affect app settings"
        return
    fi

    # MEDIUM RISK: Installers, large files, app bundles
    if [[ "$description" =~ [Ii]nstaller || "$description" =~ [Aa]pp.*[Bb]undle || "$description" =~ [Ll]arge ]]; then
        echo "MEDIUM|Installer packages or app data"
        return
    fi

    # MEDIUM RISK: Old backups, downloads
    if [[ "$description" =~ [Bb]ackup || "$description" =~ [Dd]ownload || "$description" =~ [Oo]rphan ]]; then
        echo "MEDIUM|Backup or downloaded files"
        return
    fi

    # LOW RISK: Caches, logs, temporary files (automatically regenerated)
    if [[ "$description" =~ [Cc]ache || "$description" =~ [Ll]og || "$description" =~ [Tt]emp || "$description" =~ [Tt]humbnail ]]; then
        echo "LOW|Cache/log files, automatically regenerated"
        return
    fi

    # DEFAULT: MEDIUM
    echo "MEDIUM|User data files"
}

# shellcheck disable=SC2329
safe_clean() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        description="${*: -1}"
        targets=("${@:1:$#-1}")
    fi

    local -a valid_targets=()
    for target in "${targets[@]}"; do
        # Optimization: If target is a glob literal and parent dir missing, skip it.
        if [[ "$target" == *"*"* && ! -e "$target" ]]; then
            local base_path="${target%%\**}"
            local parent_dir
            if [[ "$base_path" == */ ]]; then
                parent_dir="${base_path%/}"
            else
                parent_dir="${base_path%/*}"
            fi

            if [[ ! -d "$parent_dir" ]]; then
                # debug_log "Skipping nonexistent parent: $parent_dir for $target"
                continue
            fi
        fi
        valid_targets+=("$target")
    done

    if [[ ${#valid_targets[@]} -gt 0 ]]; then
        targets=("${valid_targets[@]}")
    else
        targets=()
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        return 0
    fi

    local removed_any=0
    local total_size_kb=0
    local total_count=0
    local skipped_count=0
    local removal_failed_count=0
    local permission_start=${ROOMY_PERMISSION_DENIED_COUNT:-0}

    local show_scan_feedback=false
    if [[ ${#targets[@]} -gt 20 && -t 1 ]]; then
        show_scan_feedback=true
        stop_section_spinner
        ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Scanning ${#targets[@]} items..."
    fi

    local _perf_scan_start
    debug_timer_start _perf_scan_start

    local -a existing_paths=()
    for path in "${targets[@]}"; do
        local skip=false

        if should_protect_path "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "protected"
            api_capture_clean_record "skipped" "$CURRENT_SECTION" "$description" "$path" 0 0 1 "protected"
        fi

        [[ "$skip" == "true" ]] && continue

        if is_path_whitelisted "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "whitelist"
            api_capture_clean_record "skipped" "$CURRENT_SECTION" "$description" "$path" 0 0 1 "whitelist"
        fi
        [[ "$skip" == "true" ]] && continue
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                register_dry_run_cleanup_target "$path" || continue
            fi
            existing_paths+=("$path")
        fi
    done

    debug_timer_end "$description: path scan" _perf_scan_start

    if [[ "$show_scan_feedback" == "true" ]]; then
        stop_section_spinner
    fi

    debug_log "Cleaning: $description, ${#existing_paths[@]} items"

    # Enhanced debug output with risk level and details
    if [[ "${ROOMY_DEBUG:-}" == "1" && ${#existing_paths[@]} -gt 0 ]]; then
        # Determine risk level for this cleanup operation
        local risk_info
        risk_info=$(classify_cleanup_risk "$description" "${existing_paths[0]}")
        local risk_level="${risk_info%%|*}"
        local risk_reason="${risk_info#*|}"

        debug_operation_start "$description"
        debug_risk_level "$risk_level" "$risk_reason"
        debug_operation_detail "Item count" "${#existing_paths[@]}"

        # Log sample of files (first 10) with details
        if [[ ${#existing_paths[@]} -le 10 ]]; then
            debug_operation_detail "Files to be removed" "All files listed below"
        else
            debug_operation_detail "Files to be removed" "Showing first 10 of ${#existing_paths[@]} files"
        fi
    fi

    if [[ $skipped_count -gt 0 ]]; then
        whitelist_skipped_count=$((whitelist_skipped_count + skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ ${#existing_paths[@]} -gt 1 ]]; then
        local -a normalized_paths=()
        while IFS= read -r -d '' path; do
            [[ -n "$path" ]] && normalized_paths+=("$path")
        done < <(normalize_paths_for_cleanup "${existing_paths[@]}")

        if [[ ${#normalized_paths[@]} -gt 0 ]]; then
            existing_paths=("${normalized_paths[@]}")
        else
            existing_paths=()
        fi
    fi

    local show_spinner=false
    if [[ ${#existing_paths[@]} -gt 10 ]]; then
        show_spinner=true
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Scanning items..."; fi
    fi

    local cleaning_spinner_started=false

    local _perf_size_start
    debug_timer_start _perf_size_start

    # For larger batches, precompute sizes in parallel for better UX/stat accuracy.
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local temp_dir
        temp_dir=$(create_temp_dir)

        local dir_count=0
        local sample_size=$((${#existing_paths[@]} > 20 ? 20 : ${#existing_paths[@]}))
        local max_sample=$((${#existing_paths[@]} * 20 / 100))
        [[ $max_sample -gt $sample_size ]] && sample_size=$max_sample

        for ((i = 0; i < sample_size && i < ${#existing_paths[@]}; i++)); do
            [[ -d "${existing_paths[i]}" ]] && ((dir_count++))
        done

        # Heuristic: mostly files -> bulk stat is faster than per-file subshells.
        if [[ $dir_count -lt 5 && ${#existing_paths[@]} -gt 20 ]]; then
            if [[ -t 1 && "$show_spinner" == "false" ]]; then
                ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Scanning items..."
                show_spinner=true
            fi

            local idx=0
            local _bytes
            while IFS= read -r _bytes; do
                [[ "$_bytes" =~ ^[0-9]+$ ]] || _bytes=0
                local _kb=$(((_bytes + 1023) / 1024))
                if [[ "$_kb" -gt 0 ]]; then
                    echo "$_kb 1" > "$temp_dir/result_${idx}"
                else
                    echo "0 0" > "$temp_dir/result_${idx}"
                fi
                idx=$((idx + 1))
            done < <(stat -f%z "${existing_paths[@]}" 2> /dev/null)
            while [[ $idx -lt ${#existing_paths[@]} ]]; do
                echo "0 0" > "$temp_dir/result_${idx}"
                idx=$((idx + 1))
            done
            for ((idx = 0; idx < ${#existing_paths[@]}; idx++)); do
                if [[ -d "${existing_paths[$idx]}" && ! -L "${existing_paths[$idx]}" ]]; then
                    local _dsize
                    _dsize=$(get_cleanup_path_size_kb "${existing_paths[$idx]}")
                    [[ "$_dsize" =~ ^[0-9]+$ ]] || _dsize=0
                    if [[ "$_dsize" -gt 0 ]]; then
                        echo "$_dsize 1" > "$temp_dir/result_${idx}"
                    else
                        echo "0 0" > "$temp_dir/result_${idx}"
                    fi
                fi
            done
        else
            local -a pids=()
            local idx=0
            local completed=0
            local last_progress_update
            last_progress_update=$(get_epoch_seconds)
            local total_paths=${#existing_paths[@]}

            if [[ ${#existing_paths[@]} -gt 0 ]]; then
                for path in "${existing_paths[@]}"; do
                    (
                        local size
                        size=$(get_cleanup_path_size_kb "$path")
                        [[ ! "$size" =~ ^[0-9]+$ ]] && size=0
                        local tmp_file="$temp_dir/result_${idx}.$$"
                        if [[ "$size" -gt 0 ]]; then
                            echo "$size 1" > "$tmp_file"
                        else
                            echo "0 0" > "$tmp_file"
                        fi
                        mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
                    ) &
                    pids+=($!)
                    idx=$((idx + 1))

                    if ((${#pids[@]} >= ROOMY_MAX_PARALLEL_JOBS)); then
                        wait "${pids[0]}" 2> /dev/null || true
                        pids=("${pids[@]:1}")
                        completed=$((completed + 1))

                        if [[ "$show_spinner" == "true" && -t 1 ]]; then
                            update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                        fi
                    fi
                done
            fi

            if [[ ${#pids[@]} -gt 0 ]]; then
                for pid in "${pids[@]}"; do
                    wait "$pid" 2> /dev/null || true
                    completed=$((completed + 1))

                    if [[ "$show_spinner" == "true" && -t 1 ]]; then
                        update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                    fi
                done
            fi
        fi

        debug_timer_end "$description: size calc" _perf_size_start

        local _perf_del_start
        debug_timer_start _perf_del_start

        # Read results back in original order.
        # Start spinner for cleaning phase
        if [[ "$DRY_RUN" != "true" && ${#existing_paths[@]} -gt 0 && -t 1 ]]; then
            ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Cleaning..."
            cleaning_spinner_started=true
        fi
        idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local result_file="$temp_dir/result_${idx}"
                if [[ -f "$result_file" ]]; then
                    read -r size count < "$result_file" 2> /dev/null || true
                    local removed=0
                    if [[ "$DRY_RUN" != "true" ]]; then
                        if safe_remove "$path" true "$size"; then
                            removed=1
                        fi
                    else
                        removed=1
                    fi

                    if [[ $removed -eq 1 ]]; then
                        if [[ "$size" -gt 0 ]]; then
                            total_size_kb=$((total_size_kb + size))
                        fi
                        total_count=$((total_count + 1))
                        removed_any=1
                    else
                        if [[ ( -e "$path" || -L "$path" ) && "$DRY_RUN" != "true" ]]; then
                            removal_failed_count=$((removal_failed_count + 1))
                        fi
                    fi
                fi
                idx=$((idx + 1))
            done
        fi

        debug_timer_end "$description: deletion" _perf_del_start

    else
        debug_timer_end "$description: size calc" _perf_size_start

        local _perf_del_start
        debug_timer_start _perf_del_start

        # Start spinner for cleaning phase (small batch)
        if [[ "$DRY_RUN" != "true" && ${#existing_paths[@]} -gt 0 && -t 1 ]]; then
            ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Cleaning..."
            cleaning_spinner_started=true
        fi
        local idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local size_kb
                size_kb=$(get_cleanup_path_size_kb "$path")
                [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0

                local removed=0
                if [[ "$DRY_RUN" != "true" ]]; then
                    if safe_remove "$path" true "$size_kb"; then
                        removed=1
                    fi
                else
                    removed=1
                fi

                if [[ $removed -eq 1 ]]; then
                    if [[ "$size_kb" -gt 0 ]]; then
                        total_size_kb=$((total_size_kb + size_kb))
                    fi
                    total_count=$((total_count + 1))
                    removed_any=1
                else
                    if [[ ( -e "$path" || -L "$path" ) && "$DRY_RUN" != "true" ]]; then
                        removal_failed_count=$((removal_failed_count + 1))
                    fi
                fi
                idx=$((idx + 1))
            done
        fi

        debug_timer_end "$description: deletion" _perf_del_start
    fi

    if [[ "$show_spinner" == "true" || "$cleaning_spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    local permission_end=${ROOMY_PERMISSION_DENIED_COUNT:-0}
    # Track permission failures in debug output (avoid noisy user warnings).
    if [[ $permission_end -gt $permission_start && $removed_any -eq 0 ]]; then
        debug_log "Permission denied while cleaning: $description"
    fi
    if [[ $removal_failed_count -gt 0 && "$DRY_RUN" != "true" ]]; then
        debug_log "Skipped $removal_failed_count items, permission denied or in use, for: $description"
    fi

    if [[ $removed_any -eq 1 ]]; then
        api_capture_clean_record "category" "$CURRENT_SECTION" "$description" "${existing_paths[0]:-}" "$total_size_kb" "$total_count" "$skipped_count" ""

        # Stop spinner before output
        stop_section_spinner

        local size_human
        size_human=$(bytes_to_human "$((total_size_kb * 1024))")

        local label="$description"
        if [[ ${#targets[@]} -gt 1 ]]; then
            label+=" ${#targets[@]} items"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label${NC}, ${YELLOW}$size_human dry${NC}"

            local paths_temp
            paths_temp=$(create_temp_file)

            idx=0
            if [[ ${#existing_paths[@]} -gt 0 ]]; then
                for path in "${existing_paths[@]}"; do
                    local size=0

                    if [[ -n "${temp_dir:-}" && -f "$temp_dir/result_${idx}" ]]; then
                        read -r size count < "$temp_dir/result_${idx}" 2> /dev/null || true
                    else
                        size=$(get_cleanup_path_size_kb "$path" 2> /dev/null || echo "0")
                    fi

                    [[ "$size" == "0" || -z "$size" ]] && {
                        idx=$((idx + 1))
                        continue
                    }

                    echo "$(dirname "$path")|$size|$path" >> "$paths_temp"
                    idx=$((idx + 1))
                done
            fi

            # Group dry-run paths by parent for a compact export list.
            if [[ -f "$paths_temp" && -s "$paths_temp" ]]; then
                sort -t'|' -k1,1 "$paths_temp" | awk -F'|' '
                {
                    parent = $1
                    size = $2
                    path = $3

                    parent_size[parent] += size
                    if (parent_count[parent] == 0) {
                        parent_first[parent] = path
                    }
                    parent_count[parent]++
                }
                END {
                    for (parent in parent_size) {
                        if (parent_count[parent] > 1) {
                            printf "%s|%d|%d\n", parent, parent_size[parent], parent_count[parent]
                        } else {
                            printf "%s|%d|1\n", parent_first[parent], parent_size[parent]
                        }
                    }
                }
                ' | while IFS='|' read -r display_path total_size child_count; do
                    local size_human
                    size_human=$(bytes_to_human "$((total_size * 1024))")
                    if [[ $child_count -gt 1 ]]; then
                        clean_export_append_line "$display_path  # $size_human, $child_count items"
                    else
                        clean_export_append_line "$display_path  # $size_human"
                    fi
                done
            fi
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} $label${NC}, ${line_color}$size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + total_count))
        total_size_cleaned=$((total_size_cleaned + total_size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi

    return 0
}

start_cleanup() {
    # Set current command for operation logging
    export ROOMY_CURRENT_COMMAND="clean"
    log_operation_session_start "clean"
    DRY_RUN_SEEN_IDENTITIES=()

    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        echo -e "${PURPLE_BOLD}Clean External Volume${NC}"
        echo -e "${GRAY}${EXTERNAL_VOLUME_TARGET}${NC}"
        echo ""

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
            echo ""
        fi
        SYSTEM_CLEAN=false
        return 0
    fi

    echo -e "${PURPLE_BOLD}Clean Your Mac${NC}"
    echo ""

    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo -e "${GRAY}${ICON_WARNING} Use --dry-run to preview, --whitelist to manage protected paths${NC}"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
        echo ""

        clean_export_write_lines \
            "# Roomy Cleanup Preview - $(date '+%Y-%m-%d %H:%M:%S')" \
            "#" \
            "# How to protect files:" \
            "# 1. Copy any path below to ${ROOMY_CONFIG_DIR/#$HOME/~}/whitelist" \
            "# 2. Run: roomy clean --whitelist" \
            "#" \
            "# Example:" \
            "#   /Users/*/Library/Caches/com.example.app" \
            "#" \
            ""

        # Preview system section when sudo is already cached (no password prompt).
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access available, system preview included"
            echo ""
        else
            SYSTEM_CLEAN=false
            echo -e "${GRAY}${ICON_WARNING} System caches need sudo, run ${NC}sudo -v && roomy clean --dry-run${GRAY} for full preview${NC}"
            echo ""
        fi
        return
    fi

    if ! should_run_clean_category "system"; then
        SYSTEM_CLEAN=false
        if [[ -t 1 ]]; then
            echo -e "${GRAY}${ICON_LIST} System cleanup skipped by category filter${NC}"
            echo ""
        fi
    elif [[ "$AUTO_YES" == "true" ]]; then
        echo "Running with --yes"
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo "  ${ICON_LIST} System-level cleanup enabled, sudo session active"
        else
            SYSTEM_CLEAN=false
            echo "  ${ICON_LIST} System-level cleanup skipped, requires sudo"
        fi
        echo "  ${ICON_LIST} User-level cleanup will proceed automatically"
        echo ""
    elif [[ -t 0 ]]; then
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access already available"
            echo ""
        else
            echo -ne "${PURPLE}${ICON_ARROW}${NC} System caches need sudo. ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "

            local choice
            choice=$(read_key)

            # ESC/Q aborts, Space skips, Enter enables system cleanup.
            if [[ "$choice" == "QUIT" ]]; then
                echo -e " ${GRAY}Canceled${NC}"
                exit 0
            fi

            if [[ "$choice" == "SPACE" ]]; then
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
                SYSTEM_CLEAN=false
            elif [[ "$choice" == "ENTER" ]]; then
                printf "\r\033[K" # Clear the prompt line
                if ensure_sudo_session "System cleanup requires admin access"; then
                    SYSTEM_CLEAN=true
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                    echo ""
                else
                    SYSTEM_CLEAN=false
                    echo ""
                    echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
                fi
            else
                SYSTEM_CLEAN=false
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
            fi
        fi
    else
        echo ""
        echo "Running in non-interactive mode"
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo "  ${ICON_LIST} System-level cleanup enabled, sudo session active"
        else
            SYSTEM_CLEAN=false
            echo "  ${ICON_LIST} System-level cleanup skipped, requires sudo"
        fi
        echo "  ${ICON_LIST} User-level cleanup will proceed automatically"
        echo ""
    fi
}

perform_cleanup() {
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        total_items=0
        files_cleaned=0
        total_size_cleaned=0
    fi

    # Test mode skips expensive scans and returns minimal output.
    local test_mode_enabled=false
    if [[ -z "$EXTERNAL_VOLUME_TARGET" && "${ROOMY_TEST_MODE:-0}" == "1" ]]; then
        test_mode_enabled=true
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
            echo ""
        fi
        echo -e "${GREEN}${ICON_LIST}${NC} User app cache"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            local -a expanded_defaults
            expanded_defaults=()
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                expanded_defaults+=("${default/#\~/$HOME}")
            done
            local has_custom=false
            for pattern in "${WHITELIST_PATTERNS[@]}"; do
                local is_default=false
                local normalized_pattern="${pattern%/}"
                for default in "${expanded_defaults[@]}"; do
                    local normalized_default="${default%/}"
                    [[ "$normalized_pattern" == "$normalized_default" ]] && is_default=true && break
                done
                [[ "$is_default" == "false" ]] && has_custom=true && break
            done
            [[ "$has_custom" == "true" ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} Protected items found"
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            echo ""
            echo "Potential space: 0.00GB"
        fi
        total_items=1
        files_cleaned=0
        total_size_cleaned=0
    fi

    if [[ "$test_mode_enabled" == "false" && -z "$EXTERNAL_VOLUME_TARGET" ]]; then
        echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $(get_free_space)"
    fi

    if [[ "$test_mode_enabled" == "true" ]]; then
        local summary_heading="Test mode complete"
        local -a summary_details
        summary_details=()
        summary_details+=("Test mode - no actual cleanup performed")
        print_summary_block "$summary_heading" "${summary_details[@]}"
        printf '\n'
        return 0
    fi

    # Pre-check TCC permissions to avoid mid-run prompts.
    if [[ -z "$EXTERNAL_VOLUME_TARGET" ]]; then
        check_tcc_permissions
    fi

    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local predefined_count=0
        local custom_count=0

        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                local expanded_default="${default/#\~/$HOME}"
                if [[ "$pattern" == "$expanded_default" ]]; then
                    is_predefined=true
                    break
                fi
            done

            if [[ "$is_predefined" == "true" ]]; then
                predefined_count=$((predefined_count + 1))
            else
                custom_count=$((custom_count + 1))
            fi
        done

        if [[ $custom_count -gt 0 || $predefined_count -gt 0 ]]; then
            local summary=""
            [[ $predefined_count -gt 0 ]] && summary+="$predefined_count core"
            [[ $custom_count -gt 0 && $predefined_count -gt 0 ]] && summary+=" + "
            [[ $custom_count -gt 0 ]] && summary+="$custom_count custom"
            summary+=" patterns active"

            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $summary"

            if [[ "$DRY_RUN" == "true" ]]; then
                for pattern in "${WHITELIST_PATTERNS[@]}"; do
                    [[ "$pattern" == "$FINDER_METADATA_SENTINEL" ]] && continue
                    echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ${GRAY}${pattern}${NC}"
                done
            fi
        fi
    fi

    if [[ -t 1 && "$DRY_RUN" != "true" ]]; then
        local fda_status=0
        has_full_disk_access
        fda_status=$?
        if [[ $fda_status -eq 1 ]]; then
            echo ""
            echo -e "${GRAY}${ICON_REVIEW}${NC} ${GRAY}Grant Full Disk Access to your terminal in System Settings for best results${NC}"
        fi
    fi

    total_items=0
    files_cleaned=0
    total_size_cleaned=0

    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1

    # Allow per-section failures without aborting the full run.
    set +e

    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        if should_run_clean_category "external"; then
            start_section "External volume"
            clean_external_volume_target "$EXTERNAL_VOLUME_TARGET"
            end_section
        fi
    else
        # ===== 1. System =====
        if [[ "$SYSTEM_CLEAN" == "true" ]] && should_run_clean_category "system"; then
            start_section "System"
            clean_deep_system
            clean_local_snapshots
            end_section
        fi

        if [[ ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
            echo ""
            for warning in "${WHITELIST_WARNINGS[@]}"; do
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Whitelist: $warning"
            done
        fi

        # ===== 2. User essentials =====
        if should_run_clean_category "user-essentials"; then
            start_section "User essentials"
            clean_user_essentials
            clean_finder_metadata
            end_section
        fi

        # ===== 3. App caches (merged sandboxed and standard app caches) =====
        if should_run_clean_category "app-caches"; then
            start_section "App caches"
            clean_app_caches
            end_section
        fi

        # ===== 4. Browsers =====
        if should_run_clean_category "browsers"; then
            start_section "Browsers"
            clean_browsers
            end_section
        fi

        # ===== 5. Cloud & Office =====
        if should_run_clean_category "cloud-office"; then
            start_section "Cloud & Office"
            # Force shell fallback so timeout runs in this shell context.
            # The Cloud/Office cleaners rely on helpers (safe_clean, whitelist checks)
            # defined in this script and sourced modules.
            if run_with_shell_timeout 300 run_cloud_and_office_cleanup; then
                : # completed successfully
            else
                local ret=$?
                if [[ $ret -eq 124 ]]; then
                    log_warning "Cloud & Office cleanup timed out after 5 minutes, skipping remaining items"
                elif [[ $ret -eq 130 ]]; then
                    return 130
                else
                    log_warning "Cloud & Office cleanup failed with exit code $ret"
                fi
            fi
            end_section
        fi

        # ===== 6. Developer tools (merged CLI and GUI tooling) =====
        if should_run_clean_category "developer"; then
            start_section "Developer tools"
            clean_developer_tools
            end_section
        fi

        # ===== 7. Applications =====
        if should_run_clean_category "applications"; then
            start_section "Applications"
            clean_user_gui_applications
            end_section
        fi

        # ===== 8. Virtualization =====
        if should_run_clean_category "virtualization"; then
            start_section "Virtualization"
            clean_virtualization_tools
            end_section
        fi

        # ===== 9. Application Support =====
        if should_run_clean_category "app-support"; then
            start_section "Application Support"
            clean_application_support_logs
            end_section
        fi

        # ===== 10. App leftovers =====
        if should_run_clean_category "leftovers"; then
            start_section "App leftovers"
            clean_orphaned_app_data
            clean_orphaned_system_services
            clean_orphaned_container_stubs
            show_user_launch_agent_hint_notice
            show_orphan_dotdir_hint_notice
            end_section
        fi

        # ===== 11. Apple Silicon =====
        if should_run_clean_category "apple-silicon"; then
            clean_apple_silicon_caches
        fi

        # ===== 12. Device backups & firmware =====
        if should_run_clean_category "device-backups"; then
            start_section "Device backups & firmware"
            clean_cached_device_firmware
            check_ios_device_backups
            end_section
        fi

        # ===== 13. Time Machine =====
        if should_run_clean_category "time-machine"; then
            start_section "Time Machine"
            clean_time_machine_failed_backups
            end_section
        fi

        # ===== 14. Large files =====
        if should_run_clean_category "large-files"; then
            start_section "Large files"
            check_large_file_candidates
            end_section
        fi

        # ===== 15. System Data clues =====
        if should_run_clean_category "system-data"; then
            start_section "System Data clues"
            show_system_data_hint_notice
            end_section
        fi

        # ===== 16. Project artifacts =====
        if should_run_clean_category "project-artifacts"; then
            start_section "Project artifacts"
            show_project_artifact_hint_notice
            end_section
        fi
    fi

    # ===== Final summary =====
    echo ""

    local summary_heading=""
    local summary_status="success"
    if [[ "$DRY_RUN" == "true" ]]; then
        summary_heading="Dry run complete - no changes made"
    else
        summary_heading="Cleanup complete"
    fi

    local -a summary_details=()

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_size_human
        freed_size_human=$(bytes_to_human_kb "$total_size_cleaned")

        if [[ "$DRY_RUN" == "true" ]]; then
            local stats="Potential space: ${GREEN}${freed_size_human}${NC}"
            [[ $files_cleaned -gt 0 ]] && stats+=" | Items: $files_cleaned"
            [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
            summary_details+=("$stats")

            clean_export_append_lines \
                "" \
                "# ============================================" \
                "# Summary" \
                "# ============================================" \
                "# Potential cleanup: ${freed_size_human}" \
                "# Items: $files_cleaned" \
                "# Categories: $total_items"

            summary_details+=("Detailed file list: ${GRAY}$EXPORT_LIST_FILE${NC}")
            summary_details+=("Use ${GRAY}roomy clean --whitelist${NC} to add protection rules")
        else
            local summary_line="Space freed: ${GREEN}${freed_size_human}${NC}"

            if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                summary_line+=" | Items cleaned: $files_cleaned | Categories: $total_items"
            elif [[ $files_cleaned -gt 0 ]]; then
                summary_line+=" | Items cleaned: $files_cleaned"
            elif [[ $total_items -gt 0 ]]; then
                summary_line+=" | Categories: $total_items"
            fi

            summary_details+=("$summary_line")

            # Movie comparison only if >= 1GB
            if ((total_size_cleaned >= ROOMY_ONE_GIB_KB)); then
                local freed_gb=$((total_size_cleaned / ROOMY_ONE_GIB_KB))
                local movies=$((freed_gb * 10 / 45))

                if [[ $movies -gt 0 ]]; then
                    if [[ $movies -eq 1 ]]; then
                        summary_details+=("Equivalent to ~$movies 4K movie of storage.")
                    else
                        summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                    fi
                fi
            fi

            local final_free_space
            final_free_space=$(get_free_space)
            summary_details+=("Free space now: $final_free_space")
        fi
    else
        summary_status="info"
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_details+=("No significant reclaimable space detected, system already clean.")
        else
            summary_details+=("System was already clean; no additional space freed.")
        fi
        summary_details+=("Free space now: $(get_free_space)")
    fi

    if [[ $had_errexit -eq 1 ]]; then
        set -e
    fi

    # Log session end with summary
    log_operation_session_end "clean" "$files_cleaned" "$total_size_cleaned"

    if [[ -n "${ROOMY_API_CLEAN_METRICS_FILE:-}" ]]; then
        local metrics_free_space metrics_movies=0 metrics_equivalent=""
        metrics_free_space=$(get_free_space)
        if ((total_size_cleaned >= ROOMY_ONE_GIB_KB)); then
            local metrics_freed_gb=$((total_size_cleaned / ROOMY_ONE_GIB_KB))
            metrics_movies=$((metrics_freed_gb * 10 / 45))
            if [[ $metrics_movies -eq 1 ]]; then
                metrics_equivalent="Equivalent to ~1 4K movie of storage."
            elif [[ $metrics_movies -gt 1 ]]; then
                metrics_equivalent="Equivalent to ~$metrics_movies 4K movies of storage."
            fi
        fi

        {
            printf 'bytes\t%s\n' "$((total_size_cleaned * 1024))"
            printf 'item_count\t%s\n' "$files_cleaned"
            printf 'category_count\t%s\n' "$total_items"
            printf 'free_space\t%s\n' "$metrics_free_space"
            printf 'equivalent\t%s\n' "$metrics_equivalent"
        } > "$ROOMY_API_CLEAN_METRICS_FILE" 2> /dev/null || true
    fi

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

run_with_shell_timeout() {
    local duration="$1"
    shift || true
    # Functions (for example safe_clean) are available only in the current shell.
    # Force the shell fallback path so timeout can execute shell functions directly.
    ROOMY_TIMEOUT_BIN="" ROOMY_TIMEOUT_PERL_BIN="" run_with_timeout "$duration" "$@"
}

# shellcheck disable=SC2329  # Invoked indirectly via run_with_timeout fallback.
run_cloud_and_office_cleanup() {
    clean_cloud_storage
    clean_office_applications
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--help" | "-h")
                show_clean_help
                exit 0
                ;;
            "--debug")
                export ROOMY_DEBUG=1
                ;;
            "--dry-run" | "-n")
                DRY_RUN=true
                export ROOMY_DRY_RUN=1
                ;;
            "--yes" | "-y")
                AUTO_YES=true
                ;;
            "--external")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing path for --external" >&2
                    exit 1
                fi
                validate_external_volume_target_to_var EXTERNAL_VOLUME_TARGET "$1" || exit 1
                ;;
            "--categories" | "--select")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing value for --categories" >&2
                    exit 1
                fi
                clean_parse_category_list "include" "$1" || exit 1
                ;;
            "--exclude")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing value for --exclude" >&2
                    exit 1
                fi
                clean_parse_category_list "exclude" "$1" || exit 1
                ;;
            "--list-categories")
                show_clean_categories
                exit 0
                ;;
            "--max-delete-gb")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing value for --max-delete-gb" >&2
                    exit 1
                fi
                MAX_DELETE_BYTES=$(parse_clean_size_gb "$1") || {
                    echo "Invalid --max-delete-gb value: $1" >&2
                    exit 1
                }
                ;;
            "--max-risk")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing value for --max-risk" >&2
                    exit 1
                fi
                validate_clean_risk_level "$1" || {
                    echo "Invalid --max-risk value: $1 (use low, medium, or high)" >&2
                    exit 1
                }
                MAX_RISK_LEVEL="$1"
                ;;
            "--require-dry-run-age")
                shift
                if [[ $# -eq 0 || ! "$1" =~ ^[0-9]+$ ]]; then
                    echo "Invalid --require-dry-run-age value" >&2
                    exit 1
                fi
                REQUIRE_DRY_RUN_HOURS="$1"
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/manage/whitelist.sh"
                manage_whitelist "clean"
                exit 0
                ;;
            -*)
                echo "Unknown option for roomy clean: $1" >&2
                echo "Run 'roomy clean --help' for usage." >&2
                exit 1
                ;;
            *)
                echo "Unexpected argument for roomy clean: $1" >&2
                echo "Run 'roomy clean --help' for usage." >&2
                exit 1
                ;;
        esac
        shift
    done

    clean_automation_preflight || exit 1
    start_cleanup
    hide_cursor
    perform_cleanup
    show_cursor
    exit 0
}

main "$@"
