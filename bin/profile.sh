#!/bin/bash
# Roomy - portable config profiles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/common.sh
source "$PROJECT_ROOT/lib/core/common.sh"
# shellcheck source=lib/manage/profile_archive.sh
source "$PROJECT_ROOT/lib/manage/profile_archive.sh"

trap cleanup_temp_files EXIT INT TERM

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

profile_require_regular_dir() {
    local dir="$1"
    local label="$2"

    if [[ ! -d "$dir" || -L "$dir" ]]; then
        echo "$label is not a regular profile directory" >&2
        return 1
    fi
}

profile_require_regular_file() {
    local file="$1"
    local label="$2"

    if [[ ! -f "$file" || -L "$file" ]]; then
        echo "$label is not a regular file" >&2
        return 1
    fi
}

profile_require_storage_dir() {
    local dir="$1"
    local label="$2"

    if [[ -L "$dir" ]]; then
        echo "$label must not be a symlink: $dir" >&2
        return 1
    fi
    if [[ -e "$dir" && ! -d "$dir" ]]; then
        echo "$label must be a directory: $dir" >&2
        return 1
    fi
}

profile_require_storage_roots() {
    profile_require_storage_dir "$ROOMY_CONFIG_DIR" "Profile config directory" || return 1
    profile_require_storage_dir "$ROOMY_PROFILE_DIR" "Profile directory" || return 1
}

profile_replace_file() {
    local src="$1"
    local dest="$2"
    local label="$3"

    profile_require_regular_file "$src" "$label" || return 1
    if [[ -e "$dest" || -L "$dest" ]]; then
        safe_remove "$dest" true || {
            echo "Failed to replace existing config file: $(basename "$dest")" >&2
            return 1
        }
    fi
    cp "$src" "$dest"
}

profile_list() {
    if [[ ! -d "$ROOMY_PROFILE_DIR" ]]; then
        echo "No profiles found"
        return 0
    fi
    profile_require_storage_dir "$ROOMY_PROFILE_DIR" "Profile directory" || return 1
    local found=false
    local item
    for item in "$ROOMY_PROFILE_DIR"/*; do
        [[ -d "$item" && ! -L "$item" ]] || continue
        found=true
        basename "$item"
    done
    $found || echo "No profiles found"
}

profile_create() {
    local name="$1"
    profile_validate_name "$name" || return 1
    profile_require_storage_roots || return 1
    local dir
    dir=$(profile_path "$name")
    if [[ -e "$dir" || -L "$dir" ]]; then
        safe_remove "$dir" true || {
            echo "Failed to replace existing profile: $name" >&2
            return 1
        }
    fi
    ensure_user_dir "$dir"

    local copied=0
    local file
    for file in "${PROFILE_FILES[@]}"; do
        local src="$ROOMY_CONFIG_DIR/$file"
        if [[ -e "$src" || -L "$src" ]]; then
            profile_require_regular_file "$src" "Config file $file" || {
                safe_remove "$dir" true || true
                return 1
            }
            if ! cp "$src" "$dir/$file"; then
                safe_remove "$dir" true || true
                echo "Failed to save config file: $file" >&2
                return 1
            fi
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
    profile_require_storage_roots || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -e "$dir" || -L "$dir" ]] || {
        echo "Profile not found: $name" >&2
        return 1
    }
    profile_require_regular_dir "$dir" "Profile $name" || return 1

    ensure_user_dir "$ROOMY_CONFIG_DIR"
    local applied=0
    local file
    for file in "${PROFILE_FILES[@]}"; do
        local src="$dir/$file"
        local dest="$ROOMY_CONFIG_DIR/$file"
        if [[ -e "$src" || -L "$src" ]]; then
            profile_replace_file "$src" "$dest" "Profile file $file" || return 1
            applied=$((applied + 1))
        elif [[ -e "$dest" || -L "$dest" ]]; then
            safe_remove "$dest" true || {
                echo "Failed to remove config file absent from profile: $file" >&2
                return 1
            }
        fi
    done
    echo "Profile applied: $name ($applied files)"
}

profile_show() {
    local name="$1"
    profile_validate_name "$name" || return 1
    profile_require_storage_dir "$ROOMY_PROFILE_DIR" "Profile directory" || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -e "$dir" || -L "$dir" ]] || {
        echo "Profile not found: $name" >&2
        return 1
    }
    profile_require_regular_dir "$dir" "Profile $name" || return 1

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
    profile_require_storage_dir "$ROOMY_PROFILE_DIR" "Profile directory" || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -e "$dir" || -L "$dir" ]] || {
        echo "Profile not found: $name" >&2
        return 1
    }
    safe_remove "$dir" true || {
        echo "Failed to delete profile: $name" >&2
        return 1
    }
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
                [[ $# -gt 0 ]] || {
                    echo "Missing value for --to" >&2
                    return 1
                }
                output="$1"
                ;;
            *)
                echo "Unknown profile export option: $1" >&2
                return 1
                ;;
        esac
        shift
    done
    [[ -n "$output" ]] || output="$PWD/roomy-profile-$name.tar.gz"
    profile_validate_name "$name" || return 1
    profile_require_storage_dir "$ROOMY_PROFILE_DIR" "Profile directory" || return 1
    local dir
    dir=$(profile_path "$name")
    [[ -e "$dir" || -L "$dir" ]] || {
        echo "Profile not found: $name" >&2
        return 1
    }
    profile_require_regular_dir "$dir" "Profile $name" || return 1
    if find "$dir" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
        echo "Profile contains an unsafe link or special file" >&2
        return 1
    fi
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
                [[ $# -gt 0 ]] || {
                    echo "Missing value for --from" >&2
                    return 1
                }
                input="$1"
                ;;
            *)
                echo "Unknown profile import option: $1" >&2
                return 1
                ;;
        esac
        shift
    done
    [[ -n "$input" && -f "$input" ]] || {
        echo "Profile archive not found: $input" >&2
        return 1
    }
    profile_validate_name "$name" || return 1
    profile_require_storage_roots || return 1
    ensure_user_dir "$ROOMY_PROFILE_DIR"

    local archive_root
    archive_root=$(profile_validate_archive "$input") || return 1

    local temp_dir
    temp_dir=$(create_temp_dir)
    if ! tar -C "$temp_dir" -xzf "$input"; then
        profile_cleanup_import_temp "$temp_dir"
        echo "Failed to extract profile archive: $input" >&2
        return 1
    fi

    local extracted="$temp_dir/$archive_root"
    if [[ ! -d "$extracted" || -L "$extracted" ]]; then
        profile_cleanup_import_temp "$temp_dir"
        echo "Profile archive must contain exactly one top-level directory" >&2
        return 1
    fi

    if find "$extracted" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
        profile_cleanup_import_temp "$temp_dir"
        echo "Profile archive contains an unsafe link or special file" >&2
        return 1
    fi

    local staging
    staging=$(create_temp_dir)
    local copied=0
    local file
    for file in "${PROFILE_FILES[@]}"; do
        if [[ -f "$extracted/$file" ]]; then
            if ! cp "$extracted/$file" "$staging/$file"; then
                profile_cleanup_import_temp "$temp_dir" "$staging"
                echo "Failed to import profile file: $file" >&2
                return 1
            fi
            copied=$((copied + 1))
        fi
    done
    {
        printf 'name=%s\n' "$name"
        printf 'imported_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'file_count=%s\n' "$copied"
    } > "$staging/manifest"

    local target
    target=$(profile_path "$name")
    if [[ -e "$target" || -L "$target" ]] && ! safe_remove "$target" true; then
        profile_cleanup_import_temp "$temp_dir" "$staging"
        echo "Failed to replace profile: $name" >&2
        return 1
    fi
    if ! mv "$staging" "$target"; then
        profile_cleanup_import_temp "$temp_dir" "$staging"
        echo "Failed to install imported profile: $name" >&2
        return 1
    fi
    profile_cleanup_import_temp "$temp_dir"
    echo "Profile imported: $name"
}

main() {
    case "${1:-}" in
        list)
            profile_list
            ;;
        create)
            [[ -n "${2:-}" ]] || {
                echo "Usage: roomy profile create NAME" >&2
                exit 1
            }
            profile_create "$2"
            ;;
        apply)
            [[ -n "${2:-}" ]] || {
                echo "Usage: roomy profile apply NAME" >&2
                exit 1
            }
            profile_apply "$2"
            ;;
        show)
            [[ -n "${2:-}" ]] || {
                echo "Usage: roomy profile show NAME" >&2
                exit 1
            }
            profile_show "$2"
            ;;
        delete)
            [[ -n "${2:-}" ]] || {
                echo "Usage: roomy profile delete NAME" >&2
                exit 1
            }
            profile_delete "$2"
            ;;
        export)
            [[ -n "${2:-}" ]] || {
                echo "Usage: roomy profile export NAME --to PATH" >&2
                exit 1
            }
            name="$2"
            shift 2
            profile_export "$name" "$@"
            ;;
        import)
            [[ -n "${2:-}" ]] || {
                echo "Usage: roomy profile import NAME --from PATH" >&2
                exit 1
            }
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
