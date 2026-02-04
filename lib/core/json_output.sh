#!/bin/bash
# Mole - JSON Output Module
# Provides machine-readable JSON output for UI integration
# Usage: source this module and use json_* functions

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_JSON_OUTPUT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_JSON_OUTPUT_LOADED=1

# JSON Output Configuration

# Global flag for JSON output mode
export MOLE_JSON_OUTPUT="${MOLE_JSON_OUTPUT:-false}"

# JSON output buffer (array of cleanup items)
declare -a MOLE_JSON_ITEMS=()

# JSON warnings buffer
declare -a MOLE_JSON_WARNINGS=()

# Current category being processed
MOLE_JSON_CURRENT_CATEGORY=""

# Total bytes tracked
MOLE_JSON_TOTAL_BYTES=0

# Whether sudo is required for any item
MOLE_JSON_REQUIRES_SUDO=false

# JSON Helper Functions

# Escape string for JSON output
# Args: $1 - string to escape
json_escape_string() {
    local str="$1"
    # Escape backslash first, then other special characters
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    printf '%s' "$str"
}

# Generate stable ID from path and description
# Args: $1 - description, $2 - path (optional)
json_generate_id() {
    local description="$1"
    local path="${2:-}"

    # Create a stable ID by normalizing the description
    local id
    id=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_-')

    # Add path hash suffix if path provided for uniqueness
    if [[ -n "$path" ]]; then
        # Use first path if multiple, create short hash
        local first_path="${path%%$'\n'*}"
        local path_hash
        path_hash=$(printf '%s' "$first_path" | cksum | cut -d' ' -f1)
        id="${id}_${path_hash}"
    fi

    printf '%s' "$id"
}

# Determine risk level from description and path
# Args: $1 - description, $2 - path (optional)
# Returns: low, medium, or high
json_classify_risk() {
    local description="$1"
    local path="${2:-}"

    # HIGH RISK: System files, preferences, requires sudo
    if [[ "$description" =~ [Ss]ystem || "$path" =~ ^/System || "$path" =~ ^/Library ]]; then
        echo "high"
        return
    fi

    if [[ "$description" =~ [Pp]reference || "$path" =~ /Preferences/ ]]; then
        echo "high"
        return
    fi

    # MEDIUM RISK: Installers, large files, orphaned data
    if [[ "$description" =~ [Ii]nstaller || "$description" =~ [Oo]rphan || "$description" =~ [Bb]ackup ]]; then
        echo "medium"
        return
    fi

    # LOW RISK: Caches, logs, temp files (automatically regenerated)
    if [[ "$description" =~ [Cc]ache || "$description" =~ [Ll]og || "$description" =~ [Tt]emp ]]; then
        echo "low"
        return
    fi

    # Default to medium
    echo "medium"
}

# Extract persona tags from description
# Args: $1 - description, $2 - category
json_extract_tags() {
    local description="$1"
    local category="${2:-}"
    local -a tags=()

    # Developer tools
    if [[ "$description" =~ [Xx]code || "$description" =~ iOS || "$description" =~ [Ss]imulator ]]; then
        tags+=("ios" "xcode")
    fi
    if [[ "$description" =~ [Nn]ode || "$description" =~ npm || "$description" =~ [Yy]arn || "$description" =~ pnpm ]]; then
        tags+=("nodejs" "frontend")
    fi
    if [[ "$description" =~ [Pp]ython || "$description" =~ pip || "$description" =~ [Cc]onda ]]; then
        tags+=("python")
    fi
    if [[ "$description" =~ [Rr]ust || "$description" =~ [Cc]argo ]]; then
        tags+=("rust")
    fi
    if [[ "$description" =~ [Gg]o && ! "$description" =~ [Gg]oogle ]]; then
        tags+=("golang")
    fi
    if [[ "$description" =~ [Dd]ocker || "$description" =~ [Cc]ontainer ]]; then
        tags+=("docker" "devops")
    fi

    # Browsers
    if [[ "$description" =~ [Ss]afari ]]; then
        tags+=("browser" "safari")
    fi
    if [[ "$description" =~ [Cc]hrome ]]; then
        tags+=("browser" "chrome")
    fi
    if [[ "$description" =~ [Ff]irefox ]]; then
        tags+=("browser" "firefox")
    fi

    # Cloud/DevOps
    if [[ "$description" =~ AWS || "$description" =~ [Aa]mazon ]]; then
        tags+=("aws" "cloud")
    fi
    if [[ "$description" =~ [Gg]oogle.*[Cc]loud || "$description" =~ gcloud ]]; then
        tags+=("gcp" "cloud")
    fi
    if [[ "$description" =~ [Aa]zure ]]; then
        tags+=("azure" "cloud")
    fi
    if [[ "$description" =~ [Kk]ubernetes || "$description" =~ kubectl ]]; then
        tags+=("kubernetes" "devops")
    fi

    # Category-based tags
    case "$category" in
        "Developer tools") tags+=("developer") ;;
        "Browsers") tags+=("browser") ;;
        "Cloud storage") tags+=("cloud") ;;
        "Office applications") tags+=("productivity") ;;
    esac

    # Output as JSON array elements
    if [[ ${#tags[@]} -gt 0 ]]; then
        local first=true
        for tag in "${tags[@]}"; do
            [[ "$first" == "true" ]] && first=false || printf ','
            printf '"%s"' "$tag"
        done
    fi
}

# Generate reason/explanation for cleanup item
# Args: $1 - description, $2 - risk level
json_generate_reason() {
    local description="$1"
    local risk="$2"

    case "$risk" in
        "low")
            if [[ "$description" =~ [Cc]ache ]]; then
                echo "Cache files are automatically regenerated when needed"
            elif [[ "$description" =~ [Ll]og ]]; then
                echo "Log files can be safely removed to free space"
            elif [[ "$description" =~ [Tt]emp ]]; then
                echo "Temporary files from previous sessions"
            else
                echo "Safe to remove, will be recreated as needed"
            fi
            ;;
        "medium")
            if [[ "$description" =~ [Oo]rphan ]]; then
                echo "Data from uninstalled applications"
            elif [[ "$description" =~ [Bb]ackup ]]; then
                echo "Old backup files that may no longer be needed"
            elif [[ "$description" =~ [Dd]ownload ]]; then
                echo "Downloaded files that can be re-downloaded if needed"
            else
                echo "Review recommended before removal"
            fi
            ;;
        "high")
            if [[ "$description" =~ [Pp]reference ]]; then
                echo "Preference files may affect app settings"
            elif [[ "$description" =~ [Ss]ystem ]]; then
                echo "System files, requires admin privileges"
            else
                echo "Careful review recommended"
            fi
            ;;
        *)
            echo "Cleanup item identified by Mole"
            ;;
    esac
}

# JSON Item Collection Functions

# Set current category for subsequent items
# Args: $1 - category name
json_set_category() {
    MOLE_JSON_CURRENT_CATEGORY="$1"
}

# Add a cleanup item to JSON buffer
# Args: $1 - description, $2 - size_kb, $3 - paths (newline-separated), $4 - requires_sudo (optional)
json_add_item() {
    local description="$1"
    local size_kb="${2:-0}"
    local paths="$3"
    local requires_sudo="${4:-false}"

    [[ "$MOLE_JSON_OUTPUT" != "true" ]] && return 0
    [[ -z "$description" ]] && return 0

    local size_bytes=$((size_kb * 1024))
    local id
    id=$(json_generate_id "$description" "$paths")

    local risk
    risk=$(json_classify_risk "$description" "$paths")

    local reason
    reason=$(json_generate_reason "$description" "$risk")

    # Build paths array
    local paths_json=""
    local first_path=true
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ "$first_path" == "true" ]] && first_path=false || paths_json+=","
        paths_json+="\"$(json_escape_string "$path")\""
    done <<< "$paths"

    # Build tags array
    local tags_json
    tags_json=$(json_extract_tags "$description" "$MOLE_JSON_CURRENT_CATEGORY")

    # Build the item JSON
    local item_json
    item_json=$(cat <<EOF
    {
      "id": "$(json_escape_string "$id")",
      "title": "$(json_escape_string "$description")",
      "category": "$(json_escape_string "${MOLE_JSON_CURRENT_CATEGORY:-Uncategorized}")",
      "paths": [$paths_json],
      "estimatedBytes": $size_bytes,
      "risk": "$risk",
      "requiresSudo": $requires_sudo,
      "reason": "$(json_escape_string "$reason")",
      "personaTags": [$tags_json]
    }
EOF
)

    MOLE_JSON_ITEMS+=("$item_json")
    MOLE_JSON_TOTAL_BYTES=$((MOLE_JSON_TOTAL_BYTES + size_bytes))

    if [[ "$requires_sudo" == "true" ]]; then
        MOLE_JSON_REQUIRES_SUDO=true
    fi
}

# Add a warning to JSON output
# Args: $1 - warning message
json_add_warning() {
    local warning="$1"
    [[ "$MOLE_JSON_OUTPUT" != "true" ]] && return 0
    MOLE_JSON_WARNINGS+=("\"$(json_escape_string "$warning")\"")
}

# ============================================================================
# JSON Output Generation
# ============================================================================

# Generate final JSON output for clean command
# Args: $1 - command name, $2 - dry_run (true/false)
json_output_clean() {
    local command="${1:-clean}"
    local dry_run="${2:-true}"

    # Build items array
    local items_json=""
    local first_item=true
    if [[ ${#MOLE_JSON_ITEMS[@]} -gt 0 ]]; then
        for item in "${MOLE_JSON_ITEMS[@]}"; do
            [[ "$first_item" == "true" ]] && first_item=false || items_json+=","
            items_json+="$item"
        done
    fi

    # Build warnings array
    local warnings_json=""
    local first_warning=true
    if [[ ${#MOLE_JSON_WARNINGS[@]} -gt 0 ]]; then
        for warning in "${MOLE_JSON_WARNINGS[@]}"; do
            [[ "$first_warning" == "true" ]] && first_warning=false || warnings_json+=","
            warnings_json+="$warning"
        done
    fi

    # Output complete JSON
    cat <<EOF
{
  "command": "$command",
  "dryRun": $dry_run,
  "items": [
$items_json
  ],
  "totalEstimatedBytes": $MOLE_JSON_TOTAL_BYTES,
  "requiresSudo": $MOLE_JSON_REQUIRES_SUDO,
  "warnings": [$warnings_json]
}
EOF
}

# Generate final JSON output for purge command
# Args: $1 - dry_run (true/false)
json_output_purge() {
    local dry_run="${1:-true}"
    json_output_clean "purge" "$dry_run"
}

# Reset JSON buffers for new scan
json_reset() {
    MOLE_JSON_ITEMS=()
    MOLE_JSON_WARNINGS=()
    MOLE_JSON_CURRENT_CATEGORY=""
    MOLE_JSON_TOTAL_BYTES=0
    MOLE_JSON_REQUIRES_SUDO=false
}

# Check if JSON output mode is enabled
is_json_output() {
    [[ "$MOLE_JSON_OUTPUT" == "true" ]]
}

# JSON-aware Output Helpers

# Suppress terminal output when in JSON mode
# Use this wrapper for echo statements that shouldn't appear in JSON mode
json_quiet_echo() {
    [[ "$MOLE_JSON_OUTPUT" == "true" ]] && return 0
    echo "$@"
}

# Printf that respects JSON mode
json_quiet_printf() {
    [[ "$MOLE_JSON_OUTPUT" == "true" ]] && return 0
    printf "$@"
}
