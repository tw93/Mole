#!/bin/bash
# Roomy - portable config profiles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/common.sh
source "$PROJECT_ROOT/lib/core/common.sh"

ROOMY_CONFIG_DIR="${ROOMY_CONFIG_DIR:-$HOME/.config/roomy}"
ROOMY_PROFILE_DIR="${ROOMY_PROFILE_DIR:-$ROOMY_CONFIG_DIR/profiles}"
PROFILE_FILES=(whitelist whitelist_optimize purge_paths automation.conf)

show_profile_help() {
    cat << EOF
Usage: roomy profile <command> [NAME] [OPTIONS]

Manage portable Roomy configuration profiles.

Commands:
  list                  List profiles
  create NAME           Save current config as a profile
  apply NAME            Replace current config with a profile
  show NAME             Show files saved in a profile
  delete NAME           Delete a profile
  export NAME --to PATH  Export a profile archive
  import NAME --from PATH Import a profile archive
EOF
}

profile_validate_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "Invalid profile name: $name" >&2
        echo "Use letters, numbers, dots, underscores, or dashes." >&2
        return 1
    }
}

profile_path() {
    printf '%s/%s\n' "$ROOMY_PROFILE_DIR" "$1"
}

profile_list() {
    if [[ ! -d "$ROOMY_PROFILE_DIR" ]]; then
        echo "No profiles found"
        return 0
    fi
    local found=false
    local item
    for item in "$ROOMY_PROFILE_DIR"/*; do
        [[ -d "$item" ]] || continue
        found=true
        echo "$(basename "$item")"
    done
    $found || echo "No profiles found"
}

profile_create() {
    local name="$1"
    profile_validate_name "$name" || return 1
    local dir
    dir=$(profile_path "$name")
    ensure_user_dir "$dir"

    local copied=0
    local file
    for file in "${PROFILE_FILES[@]}"; do
        if [[ -f "$ROOMY_CONFIG_DIR/$file" ]]; then
            cp "$ROOMY_CONFIG_DIR/$file" "$dir/$file"
            copied=$((copied + 1))
        fi
    done
    {
        printf 'name=%s\n' "$name"
        printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'file_count=%s\n' "$copied"
    } > "$dir/manifest"

    echo "Profile saved: $name ($copied files)"
}

profile_apply() {
    local name="$1"
    profile_validate_name "$name" || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -d "$dir" ]] || { echo "Profile not found: $name" >&2; return 1; }

    ensure_user_dir "$ROOMY_CONFIG_DIR"
    local applied=0
    local file
    for file in "${PROFILE_FILES[@]}"; do
        if [[ -f "$dir/$file" ]]; then
            cp "$dir/$file" "$ROOMY_CONFIG_DIR/$file"
            applied=$((applied + 1))
        fi
    done
    echo "Profile applied: $name ($applied files)"
}

profile_show() {
    local name="$1"
    profile_validate_name "$name" || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -d "$dir" ]] || { echo "Profile not found: $name" >&2; return 1; }

    echo "Profile: $name"
    local file
    for file in "$dir"/*; do
        [[ -f "$file" ]] || continue
        echo "  $(basename "$file")"
    done
}

profile_delete() {
    local name="$1"
    profile_validate_name "$name" || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -d "$dir" ]] || { echo "Profile not found: $name" >&2; return 1; }
    rm -rf "$dir"
    echo "Profile deleted: $name"
}

profile_export() {
    local name="$1"
    shift
    local output=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --to" >&2; return 1; }
                output="$1"
                ;;
            *) echo "Unknown profile export option: $1" >&2; return 1 ;;
        esac
        shift
    done
    [[ -n "$output" ]] || output="$PWD/roomy-profile-$name.tar.gz"
    profile_validate_name "$name" || return 1
    [[ -d "$(profile_path "$name")" ]] || { echo "Profile not found: $name" >&2; return 1; }
    tar -C "$ROOMY_PROFILE_DIR" -czf "$output" "$name"
    echo "Profile exported: $output"
}

profile_import() {
    local name="$1"
    shift
    local input=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --from" >&2; return 1; }
                input="$1"
                ;;
            *) echo "Unknown profile import option: $1" >&2; return 1 ;;
        esac
        shift
    done
    [[ -n "$input" && -f "$input" ]] || { echo "Profile archive not found: $input" >&2; return 1; }
    profile_validate_name "$name" || return 1
    ensure_user_dir "$ROOMY_PROFILE_DIR"
    local temp_dir
    temp_dir=$(create_temp_dir)
    tar -C "$temp_dir" -xzf "$input"
    local extracted
    extracted=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [[ -n "$extracted" ]] || { echo "Profile archive is empty" >&2; return 1; }
    rm -rf "$(profile_path "$name")"
    mv "$extracted" "$(profile_path "$name")"
    echo "Profile imported: $name"
}

main() {
    case "${1:-}" in
        list)
            profile_list
            ;;
        create)
            [[ -n "${2:-}" ]] || { echo "Usage: roomy profile create NAME" >&2; exit 1; }
            profile_create "$2"
            ;;
        apply)
            [[ -n "${2:-}" ]] || { echo "Usage: roomy profile apply NAME" >&2; exit 1; }
            profile_apply "$2"
            ;;
        show)
            [[ -n "${2:-}" ]] || { echo "Usage: roomy profile show NAME" >&2; exit 1; }
            profile_show "$2"
            ;;
        delete)
            [[ -n "${2:-}" ]] || { echo "Usage: roomy profile delete NAME" >&2; exit 1; }
            profile_delete "$2"
            ;;
        export)
            [[ -n "${2:-}" ]] || { echo "Usage: roomy profile export NAME --to PATH" >&2; exit 1; }
            name="$2"
            shift 2
            profile_export "$name" "$@"
            ;;
        import)
            [[ -n "${2:-}" ]] || { echo "Usage: roomy profile import NAME --from PATH" >&2; exit 1; }
            name="$2"
            shift 2
            profile_import "$name" "$@"
            ;;
        -h | --help | help | "")
            show_profile_help
            ;;
        *)
            echo "Unknown profile command: $1" >&2
            show_profile_help >&2
            exit 1
            ;;
    esac
}

main "$@"
