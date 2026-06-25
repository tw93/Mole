#!/bin/bash
# Roomy - Installer for manual installs.
# Fetches source/binaries and installs to prefix.
# Supports update and edge installs.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

_SPINNER_PID=""
start_line_spinner() {
    local msg="$1"
    [[ ! -t 1 ]] && {
        echo -e "${BLUE}|${NC} $msg"
        return
    }
    local chars="|/-\\"
    # shellcheck disable=SC1003
    [[ -z "$chars" ]] && chars='|/-\\'
    local i=0
    (while true; do
        c="${chars:$((i % ${#chars})):1}"
        printf "\r${BLUE}%s${NC} %s" "$c" "$msg"
        ((i++))
        sleep 0.12
    done) &
    _SPINNER_PID=$!
}
stop_line_spinner() { if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2> /dev/null || true
    wait "$_SPINNER_PID" 2> /dev/null || true
    _SPINNER_PID=""
    printf "\r\033[K"
fi; }

VERBOSE=1

# Icons duplicated from lib/core/common.sh (install.sh runs standalone).
# Avoid readonly to prevent conflicts when sourcing common.sh later.
ICON_SUCCESS="✓"
ICON_ADMIN="●"
ICON_CONFIRM="◎"
ICON_ERROR="☻"

log_info() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}$1${NC}"; }
log_success() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} $1"; }
log_warning() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${YELLOW}${ICON_ERROR}${NC} $1"; }
log_admin() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}${ICON_ADMIN}${NC} $1"; }
log_confirm() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}${ICON_CONFIRM}${NC} $1"; }

safe_rm() {
    local target="${1:-}"
    local tmp_root

    if [[ -z "$target" ]]; then
        log_error "safe_rm: empty path"
        return 1
    fi
    if [[ ! -e "$target" ]]; then
        return 0
    fi

    tmp_root="${TMPDIR:-/tmp}"
    case "$target" in
        "$tmp_root" | /tmp)
            log_error "safe_rm: refusing to remove temp root: $target"
            return 1
            ;;
        "$tmp_root"/* | /tmp/*) ;;
        *)
            log_error "safe_rm: refusing to remove non-temp path: $target"
            return 1
            ;;
    esac

    if [[ -d "$target" ]]; then
        find "$target" -depth \( -type f -o -type l \) -exec rm -f {} + 2> /dev/null || true # SAFE: safe_rm only accepts temporary install workspaces
        find "$target" -depth -type d -exec rmdir {} + 2> /dev/null || true
    else
        rm -f "$target" 2> /dev/null || true
    fi
}

archive_entries_are_safe() {
    local archive="${1:-}"
    local listing verbose entry
    local saw_entry=false

    [[ -n "$archive" ]] || return 1
    if ! listing=$(tar -tzf "$archive" 2> /dev/null); then
        return 1
    fi

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        saw_entry=true
        if [[ "$entry" =~ [[:cntrl:]] ]]; then
            return 1
        fi
        case "$entry" in
            /* | .. | ../* | */.. | */../*)
                return 1
                ;;
        esac
    done <<< "$listing"

    [[ "$saw_entry" == "true" ]] || return 1

    if ! verbose=$(tar -tvzf "$archive" 2> /dev/null); then
        return 1
    fi
    while IFS= read -r entry; do
        case "${entry:0:1}" in
            l | h | b | c | p | s)
                return 1
                ;;
        esac
    done <<< "$verbose"
}

# Install defaults
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/roomy"
SOURCE_DIR=""

ACTION="install"

# Resolve source dir (local checkout, env override, or download).
needs_sudo() {
    if [[ -e "$INSTALL_DIR" ]]; then
        [[ ! -w "$INSTALL_DIR" ]]
        return
    fi

    local parent_dir
    parent_dir="$(dirname "$INSTALL_DIR")"
    [[ ! -w "$parent_dir" ]]
}

maybe_sudo() {
    if needs_sudo; then
        if [[ "${ROOMY_TEST_MODE:-0}" == "1" || "${ROOMY_TEST_NO_AUTH:-0}" == "1" ]]; then
            log_error "Admin access required, blocked in test mode"
            return 1
        fi
        sudo "$@"
    else
        "$@"
    fi
}

resolve_source_dir() {
    if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" && -f "$SOURCE_DIR/roomy" ]]; then
        return 0
    fi

    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$script_dir/roomy" ]]; then
            SOURCE_DIR="$script_dir"
            return 0
        fi
    fi

    if [[ -n "${CLEAN_SOURCE_DIR:-}" && -d "$CLEAN_SOURCE_DIR" && -f "$CLEAN_SOURCE_DIR/roomy" ]]; then
        SOURCE_DIR="$CLEAN_SOURCE_DIR"
        return 0
    fi

    local tmp
    tmp="$(mktemp -d)"

    # Safe cleanup function for temporary directory
    cleanup_tmp() {
        stop_line_spinner 2> /dev/null || true
        if [[ -z "${tmp:-}" ]]; then
            return 0
        fi
        safe_rm "$tmp"
    }
    trap cleanup_tmp EXIT

    local branch="${ROOMY_VERSION:-}"
    if [[ -z "$branch" ]]; then
        branch="$(get_latest_release_tag || true)"
    fi
    if [[ -z "$branch" ]]; then
        branch="$(get_latest_release_tag_from_git || true)"
    fi
    if [[ -z "$branch" ]]; then
        branch="main"
    fi
    if [[ "$branch" != "main" && "$branch" != "dev" ]]; then
        local normalized_branch
        if ! normalized_branch="$(normalize_release_tag "$branch")"; then
            log_error "Invalid Roomy release version: $branch"
            exit 1
        fi
        branch="$normalized_branch"
    fi
    local url="https://github.com/jake-seo-cl/roomy/archive/refs/heads/main.tar.gz"

    if [[ "$branch" == "dev" ]]; then
        url="https://github.com/jake-seo-cl/roomy/archive/refs/heads/dev.tar.gz"
    elif [[ "$branch" != "main" ]]; then
        url="https://github.com/jake-seo-cl/roomy/archive/refs/tags/${branch}.tar.gz"
    fi

    start_line_spinner "Fetching Roomy source, ${branch}..."
    if command -v curl > /dev/null 2>&1; then
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp/roomy.tar.gz" "$url" 2> /dev/null; then
            if ! archive_entries_are_safe "$tmp/roomy.tar.gz"; then
                stop_line_spinner
                log_error "Downloaded source archive contains unsafe paths."
                exit 1
            fi
            if tar -xzf "$tmp/roomy.tar.gz" -C "$tmp" 2> /dev/null; then
                stop_line_spinner

                local extracted_dir
                extracted_dir=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)

                if [[ -n "$extracted_dir" && -f "$extracted_dir/roomy" ]]; then
                    SOURCE_DIR="$extracted_dir"
                    return 0
                fi
            fi
        else
            stop_line_spinner
            # Only exit early for version tags (not for main/dev branches)
            if [[ "$branch" != "main" && "$branch" != "dev" ]]; then
                log_error "Failed to fetch version ${branch}. Check if tag exists."
                exit 1
            fi
        fi
    fi
    stop_line_spinner

    start_line_spinner "Cloning Roomy source..."
    if command -v git > /dev/null 2>&1; then
        local git_args=("--depth=1")
        if [[ "$branch" != "main" ]]; then
            git_args+=("--branch" "$branch")
        fi

        if git clone "${git_args[@]}" https://github.com/jake-seo-cl/roomy.git "$tmp/roomy" > /dev/null 2>&1; then
            stop_line_spinner
            SOURCE_DIR="$tmp/roomy"
            return 0
        fi
    fi
    stop_line_spinner

    log_error "Failed to fetch source files. Ensure curl or git is available."
    exit 1
}

# Version helpers
get_source_version() {
    local source_roomy="$SOURCE_DIR/roomy"
    if [[ -f "$source_roomy" ]]; then
        sed -n 's/^VERSION="\(.*\)"$/\1/p' "$source_roomy" | head -n1
    fi
}

get_source_commit_hash() {
    # Try to get from local git repo first
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        git -C "$SOURCE_DIR" rev-parse --short HEAD 2> /dev/null && return
    fi
    # Fallback to GitHub API
    curl -fsSL --connect-timeout 3 \
        "https://api.github.com/repos/jake-seo-cl/roomy/commits/main" 2> /dev/null |
        sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{7\}\).*/\1/p' | head -1
}

installer_strip_version_prefix() {
    local version="$1"
    version="${version#v}"
    version="${version#V}"
    printf '%s\n' "$version"
}

installer_version_component_to_decimal() {
    local component="$1"

    while [[ "${#component}" -gt 1 && "$component" == 0* ]]; do
        component="${component#0}"
    done

    printf '%s\n' "${component:-0}"
}

installer_version_compare() {
    local left right
    left=$(installer_strip_version_prefix "$1")
    right=$(installer_strip_version_prefix "$2")

    [[ "$left" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 2
    [[ "$right" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 2

    local IFS=.
    local -a left_parts=()
    local -a right_parts=()
    read -r -a left_parts <<< "$left"
    read -r -a right_parts <<< "$right"

    local count="${#left_parts[@]}"
    if (( ${#right_parts[@]} > count )); then
        count="${#right_parts[@]}"
    fi

    local i left_part right_part
    for ((i = 0; i < count; i++)); do
        left_part=$(installer_version_component_to_decimal "${left_parts[$i]:-0}")
        right_part=$(installer_version_component_to_decimal "${right_parts[$i]:-0}")

        if (( left_part > right_part )); then
            printf '1\n'
            return 0
        fi
        if (( left_part < right_part )); then
            printf -- '-1\n'
            return 0
        fi
    done

    printf '0\n'
}

installer_version_gt() {
    local result
    result=$(installer_version_compare "$1" "$2") || return 2
    [[ "$result" == "1" ]]
}

installer_latest_version_tag() {
    local latest=""
    local candidate

    for candidate in "$@"; do
        [[ "$(installer_strip_version_prefix "$candidate")" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        if [[ -z "$latest" ]] || installer_version_gt "$candidate" "$latest"; then
            latest="$candidate"
        fi
    done

    [[ -n "$latest" ]] && printf '%s\n' "$latest"
    return 0
}

escape_sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    printf '%s\n' "$value"
}

get_latest_release_tag() {
    local tag
    if ! command -v curl > /dev/null 2>&1; then
        return 1
    fi
    tag=$(curl -fsSL --connect-timeout 2 --max-time 3 \
        "https://api.github.com/repos/jake-seo-cl/roomy/releases/latest" 2> /dev/null |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    if [[ -z "$tag" ]]; then
        return 1
    fi
    printf '%s\n' "$tag"
}

get_latest_release_tag_from_git() {
    if ! command -v git > /dev/null 2>&1; then
        return 1
    fi

    local -a tags=()
    local tag
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && tags+=("$tag")
    done < <(
        git ls-remote --tags --refs https://github.com/jake-seo-cl/roomy.git 2> /dev/null |
            awk -F/ '{print $NF}' |
            grep -E '^V[0-9]' || true
    )

    installer_latest_version_tag "${tags[@]}"
}

normalize_release_tag() {
    local tag="$1"
    while [[ "$tag" =~ ^[vV] ]]; do
        tag="${tag#v}"
        tag="${tag#V}"
    done
    [[ "$tag" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || return 1
    printf 'V%s\n' "$tag"
}

release_checksums_url() {
    local tag="$1"
    printf 'https://github.com/jake-seo-cl/roomy/releases/download/%s/SHA256SUMS\n' "$tag"
}

download_release_checksums() {
    local tag="$1"
    local output_file="$2"
    local url
    url="$(release_checksums_url "$tag")"

    curl -fsSL --connect-timeout 10 --max-time 60 -o "$output_file" "$url"
}

extract_release_checksum() {
    local checksums_file="$1"
    local asset_name="$2"

    awk -v asset="$asset_name" '
        $2 == asset && length($1) == 64 && $1 !~ /[^0-9a-f]/ {
            print $1
            found = 1
            exit
        }
        END {
            exit found ? 0 : 1
        }
    ' "$checksums_file"
}

calculate_file_sha256() {
    local file="$1"

    if command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1; exit}'
        return
    fi
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1; exit}'
        return
    fi

    return 1
}

verify_release_asset_checksum() {
    local tag="$1"
    local asset_name="$2"
    local file="$3"
    local checksums_file
    checksums_file="$(mktemp "${TMPDIR:-/tmp}/roomy-checksums.XXXXXX")" || return 1

    local expected=""
    local actual=""
    local result=1

    if download_release_checksums "$tag" "$checksums_file" > /dev/null 2>&1; then
        expected=$(extract_release_checksum "$checksums_file" "$asset_name" 2> /dev/null || true)
        actual=$(calculate_file_sha256 "$file" 2> /dev/null || true)
        if [[ -n "$expected" && -n "$actual" && "$expected" == "$actual" ]]; then
            result=0
        fi
    fi

    rm -f "$checksums_file"
    return "$result"
}

get_installed_version() {
    local binary="$INSTALL_DIR/roomy"
    if [[ -x "$binary" ]]; then
        local version
        version=$("$binary" --version 2> /dev/null | awk '/Roomy version/ {print $NF; exit}')
        if [[ -n "$version" ]]; then
            echo "$version"
        else
            sed -n 's/^VERSION="\(.*\)"$/\1/p' "$binary" | head -n1
        fi
    fi
}

resolve_install_channel() {
    case "${ROOMY_VERSION:-}" in
        main | latest)
            printf 'nightly\n'
            return 0
            ;;
        dev)
            printf 'dev\n'
            return 0
            ;;
    esac

    if [[ "${ROOMY_EDGE_INSTALL:-}" == "true" ]]; then
        printf 'nightly\n'
        return 0
    fi

    printf 'stable\n'
}

write_install_channel_metadata() {
    local channel="$1"
    local commit_hash="${2:-}"
    local metadata_file="$CONFIG_DIR/install_channel"

    mkdir -p "$CONFIG_DIR" 2> /dev/null || return 1
    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/install_channel.XXXXXX") || return 1
    # Use a plain if/fi so the block's exit code reflects only I/O failure.
    # The previous form `[[ -n "$h" ]] && printf ...` returned 1 whenever the
    # commit hash was empty (the stable channel always omits it), which made
    # the redirect look like it had failed and tripped the warning.
    {
        printf 'CHANNEL=%s\n' "$channel"
        if [[ -n "$commit_hash" ]]; then
            printf 'COMMIT_HASH=%s\n' "$commit_hash"
        fi
    } > "$tmp_file" || {
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    }

    mv -f "$tmp_file" "$metadata_file" || {
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    }
}

installer_stage_for_target() {
    local target_path="$1"
    local target_dir
    local target_base

    target_dir="$(dirname "$target_path")"
    target_base="$(basename "$target_path")"
    mktemp "${target_dir}/.${target_base}.XXXXXX"
}

installer_commit_staged_path() {
    local staged_path="$1"
    local target_path="$2"

    if [[ -L "$target_path" || -f "$target_path" ]]; then
        rm -f "$target_path" 2> /dev/null || {
            rm -rf "$staged_path" 2> /dev/null || true # SAFE: cleanup of installer-created staging path
            return 1
        }
    elif [[ -e "$target_path" ]]; then
        rm -rf "$target_path" 2> /dev/null || { # SAFE: replace exact Roomy support path under CONFIG_DIR
            rm -rf "$staged_path" 2> /dev/null || true # SAFE: cleanup of installer-created staging path
            return 1
        }
    fi

    mv -f "$staged_path" "$target_path" || {
        rm -rf "$staged_path" 2> /dev/null || true # SAFE: cleanup of installer-created staging path
        return 1
    }
}

installer_prepare_executable_stage() {
    local staged_path="$1"
    local label="$2"

    if [[ -d "$staged_path" && ! -L "$staged_path" ]]; then
        log_error "$label staging path must not be a directory: $staged_path"
        return 1
    fi

    if [[ -e "$staged_path" || -L "$staged_path" ]]; then
        maybe_sudo rm -f "$staged_path" 2> /dev/null || return 1
    fi
}

installer_commit_executable_stage() {
    local staged_path="$1"
    local target_path="$2"
    local label="$3"

    if [[ -L "$target_path" || -f "$target_path" ]]; then
        maybe_sudo rm -f "$target_path" 2> /dev/null || {
            maybe_sudo rm -f "$staged_path" 2> /dev/null || true
            return 1
        }
    elif [[ -e "$target_path" ]]; then
        log_error "$label target must be a regular file: $target_path"
        maybe_sudo rm -f "$staged_path" 2> /dev/null || true
        return 1
    fi

    maybe_sudo mv -f "$staged_path" "$target_path" || {
        maybe_sudo rm -f "$staged_path" 2> /dev/null || true
        return 1
    }
}

installer_copy_support_path() {
    local source_path="$1"
    local target_path="$2"
    local make_executable="${3:-false}"
    local staged_path

    staged_path="$(installer_stage_for_target "$target_path")" || return 1
    if [[ -d "$source_path" && ! -L "$source_path" ]]; then
        rm -f "$staged_path" 2> /dev/null || return 1
        mkdir "$staged_path" 2> /dev/null || return 1
        if ! cp -R "$source_path/." "$staged_path/"; then
            rm -rf "$staged_path" 2> /dev/null || true # SAFE: cleanup of installer-created staging path
            return 1
        fi
    else
        if ! cp "$source_path" "$staged_path"; then
            rm -f "$staged_path" 2> /dev/null || true
            return 1
        fi
    fi

    if [[ "$make_executable" == "true" ]]; then
        chmod -R +x "$staged_path" 2> /dev/null || true
    fi

    installer_commit_staged_path "$staged_path" "$target_path"
}

show_installer_usage() {
    cat << EOF
Roomy installer

Usage:
  install.sh [VERSION|main|latest|dev] [--prefix PATH] [--config PATH]
  install.sh --update [VERSION|main|latest|dev] [--prefix PATH] [--config PATH]

Options:
  --prefix PATH   Install roomy and mo into PATH (default: /usr/local/bin)
  --config PATH   Store Roomy support files in PATH (default: \$HOME/.config/roomy)
  --update        Update an existing manual install
  -h, --help      Show this help

Examples:
  install.sh
  install.sh V1.39.0
  install.sh --update V1.39.0
  install.sh main --prefix "\$HOME/.local/bin"
EOF
}

# CLI parsing (supports main/latest and version tokens).
parse_args() {
    local -a args=("$@")
    local version_token=""
    local i skip_next=false
    for i in "${!args[@]}"; do
        local token="${args[$i]}"
        [[ -z "$token" ]] && continue
        # Skip values for options that take arguments
        if [[ "$skip_next" == "true" ]]; then
            skip_next=false
            continue
        fi
        if [[ "$token" == "--prefix" || "$token" == "--config" ]]; then
            skip_next=true
            continue
        fi
        if [[ "$token" == -* ]]; then
            continue
        fi
        if [[ -n "$version_token" ]]; then
            log_error "Unexpected argument: $token"
            exit 1
        fi
        case "$token" in
            latest | main)
                export ROOMY_VERSION="main"
                export ROOMY_EDGE_INSTALL="true"
                version_token="$token"
                unset 'args[$i]'
                ;;
            dev)
                export ROOMY_VERSION="dev"
                export ROOMY_EDGE_INSTALL="true"
                version_token="$token"
                unset 'args[$i]'
                ;;
            [0-9]* | V[0-9]* | v[0-9]*)
                if ! normalize_release_tag "$token" > /dev/null; then
                    log_error "Invalid Roomy release version: $token"
                    exit 1
                fi
                export ROOMY_VERSION="$token"
                version_token="$token"
                unset 'args[$i]'
                ;;
            *)
                log_error "Unknown option: $token"
                exit 1
                ;;
        esac
    done
    if [[ ${#args[@]} -gt 0 ]]; then
        set -- ${args[@]+"${args[@]}"}
    else
        set --
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --prefix)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --prefix"
                    exit 1
                fi
                INSTALL_DIR="$2"
                shift 2
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --config"
                    exit 1
                fi
                CONFIG_DIR="$2"
                shift 2
                ;;
            --update)
                ACTION="update"
                shift 1
                ;;
            --verbose | -v)
                VERBOSE=1
                shift 1
                ;;
            --help | -h)
                show_installer_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Environment checks and directory setup
check_requirements() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_error "This tool is designed for macOS only"
        exit 1
    fi

    if command -v brew > /dev/null 2>&1 && brew list roomy > /dev/null 2>&1; then
        local roomy_path
        roomy_path=$(command -v roomy 2> /dev/null || true)
        local is_homebrew_binary=false

        if [[ -n "$roomy_path" && -L "$roomy_path" ]]; then
            if readlink "$roomy_path" | grep -q "Cellar/roomy"; then
                is_homebrew_binary=true
            fi
        fi

        if [[ "$is_homebrew_binary" == "true" ]]; then
            if [[ "$ACTION" == "update" ]]; then
                return 0
            fi

            echo -e "${YELLOW}Roomy is installed via Homebrew${NC}"
            echo ""
            echo "Choose one:"
            echo -e "  1. Update via Homebrew: ${GREEN}brew upgrade roomy${NC}"
            echo -e "  2. Switch to manual: ${GREEN}brew uninstall --force roomy${NC} then re-run this"
            echo ""
            exit 1
        else
            log_warning "Cleaning up stale Homebrew installation..."
            brew uninstall --force roomy > /dev/null 2>&1 || true
        fi
    fi

    if [[ ! -d "$(dirname "$INSTALL_DIR")" ]]; then
        log_error "Parent directory $(dirname "$INSTALL_DIR") does not exist"
        exit 1
    fi
}

installer_require_regular_dir_path() {
    local path="$1"
    local label="$2"
    local current="${path%/}"

    if [[ -z "$current" ]]; then
        log_error "$label is empty"
        return 1
    fi

    if [[ "$current" =~ [[:cntrl:]] ]]; then
        log_error "$label contains control characters: $path"
        return 1
    fi

    if [[ -L "$current" ]]; then
        log_error "$label must not be a symlink: $path"
        return 1
    fi

    while [[ "$current" != "/" && "$current" != "." && "$current" != "${HOME%/}" ]]; do
        if [[ -L "$current" ]]; then
            case "$(uname -s):$current" in
                Darwin:/tmp | Darwin:/var | Darwin:/etc)
                    ;;
                *)
                    log_error "$label must not include symlinked directories: $current"
                    return 1
                    ;;
            esac
            current="$(dirname "$current")"
            continue
        fi
        if [[ -e "$current" && ! -d "$current" ]]; then
            log_error "$label must not include non-directory paths: $current"
            return 1
        fi
        local parent
        parent="$(dirname "$current")"
        [[ "$parent" == "$current" ]] && break
        current="$parent"
    done

    if [[ -e "$path" && ! -d "$path" ]]; then
        log_error "$label must be a directory: $path"
        return 1
    fi
}

create_directories() {
    installer_require_regular_dir_path "$INSTALL_DIR" "Install directory" || return 1
    installer_require_regular_dir_path "$CONFIG_DIR" "Config directory" || return 1
    installer_require_regular_dir_path "$CONFIG_DIR/bin" "Config bin directory" || return 1
    installer_require_regular_dir_path "$CONFIG_DIR/lib" "Config lib directory" || return 1

    if [[ ! -d "$INSTALL_DIR" ]]; then
        maybe_sudo mkdir -p "$INSTALL_DIR"
    fi

    if ! mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib"; then
        log_error "Failed to create config directory: $CONFIG_DIR"
        return 1
    fi

}

# Binary install helpers
build_binary_from_source() {
    local binary_name="$1"
    local target_path="$2"
    local cmd_dir=""

    case "$binary_name" in
        analyze)
            cmd_dir="cmd/analyze"
            ;;
        status)
            cmd_dir="cmd/status"
            ;;
        *)
            return 1
            ;;
    esac

    if ! command -v go > /dev/null 2>&1; then
        return 1
    fi

    if [[ ! -d "$SOURCE_DIR/$cmd_dir" ]]; then
        return 1
    fi

    if [[ -t 1 ]]; then
        start_line_spinner "Building ${binary_name} from source..."
    else
        echo "Building ${binary_name} from source..."
    fi

    if (cd "$SOURCE_DIR" && go build -ldflags="-s -w" -o "$target_path" "./$cmd_dir" > /dev/null 2>&1); then
        if [[ -t 1 ]]; then stop_line_spinner; fi
        chmod +x "$target_path"
        log_success "Built ${binary_name} from source"
        return 0
    fi

    if [[ -t 1 ]]; then stop_line_spinner; fi
    log_warning "Failed to build ${binary_name} from source"
    return 1
}

install_built_binary_from_source() {
    local binary_name="$1"
    local target_path="$2"
    local staged_path

    staged_path="$(installer_stage_for_target "$target_path")" || return 1
    if build_binary_from_source "$binary_name" "$staged_path"; then
        chmod +x "$staged_path" 2> /dev/null || true
        installer_commit_staged_path "$staged_path" "$target_path"
        return $?
    fi

    rm -f "$staged_path" 2> /dev/null || true
    return 1
}

download_binary() {
    local binary_name="$1"
    local target_path="$CONFIG_DIR/bin/${binary_name}-go"
    local arch
    arch=$(uname -m)
    local arch_suffix="amd64"
    if [[ "$arch" == "arm64" ]]; then
        arch_suffix="arm64"
    fi

    if [[ -f "$SOURCE_DIR/bin/${binary_name}-go" ]]; then
        installer_copy_support_path "$SOURCE_DIR/bin/${binary_name}-go" "$target_path" true || return 1
        log_success "Installed local ${binary_name} binary"
        return 0
    elif [[ -f "$SOURCE_DIR/bin/${binary_name}-darwin-${arch_suffix}" ]]; then
        installer_copy_support_path "$SOURCE_DIR/bin/${binary_name}-darwin-${arch_suffix}" "$target_path" true || return 1
        log_success "Installed local ${binary_name} binary"
        return 0
    fi

    if [[ "${ROOMY_EDGE_INSTALL:-}" == "true" ]]; then
        if install_built_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
    fi

    local version
    version=$(get_source_version)
    if [[ -z "$version" ]]; then
        log_warning "Could not determine version for ${binary_name}, trying local build"
        if install_built_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
        return 1
    fi
    local release_tag
    if ! release_tag="$(normalize_release_tag "$version")"; then
        log_warning "Invalid source version ${version} for ${binary_name}, trying local build"
        if install_built_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
        return 1
    fi
    local asset_name="${binary_name}-darwin-${arch_suffix}"
    local url="https://github.com/jake-seo-cl/roomy/releases/download/${release_tag}/${asset_name}"

    # Skip preflight network checks to avoid false negatives.

    local download_tmp
    download_tmp="$(installer_stage_for_target "$target_path")" || return 1

    if [[ -t 1 ]]; then
        start_line_spinner "Downloading ${binary_name}..."
    else
        echo "Downloading ${binary_name}..."
    fi

    if curl -fsSL --connect-timeout 10 --max-time 60 -o "$download_tmp" "$url"; then
        if [[ -t 1 ]]; then stop_line_spinner; fi
        if verify_release_asset_checksum "$release_tag" "$asset_name" "$download_tmp"; then
            chmod +x "$download_tmp"
            xattr -c "$download_tmp" 2> /dev/null || true
            installer_commit_staged_path "$download_tmp" "$target_path" || return 1
            log_success "Downloaded ${binary_name} binary"
            return 0
        fi
        rm -f "$download_tmp"
        log_warning "Checksum verification failed for ${binary_name}, trying local build"
        if install_built_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
        log_error "Failed to install verified ${binary_name} binary"
        return 1
    fi
    rm -f "$download_tmp" 2> /dev/null || true
    if [[ -t 1 ]]; then stop_line_spinner; fi

    local fallback_tag
    fallback_tag=$(get_latest_release_tag 2> /dev/null || true)
    if [[ -n "$fallback_tag" ]]; then
        fallback_tag=$(normalize_release_tag "$fallback_tag" 2> /dev/null || true)
    fi
    if [[ -n "$fallback_tag" && "$fallback_tag" != "$release_tag" ]]; then
        local fallback_url="https://github.com/jake-seo-cl/roomy/releases/download/${fallback_tag}/${asset_name}"
        download_tmp="$(installer_stage_for_target "$target_path")" || return 1
        if [[ -t 1 ]]; then
            start_line_spinner "Retrying ${binary_name} from ${fallback_tag}..."
        else
            echo "Retrying ${binary_name} from ${fallback_tag}..."
        fi
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$download_tmp" "$fallback_url"; then
            if [[ -t 1 ]]; then stop_line_spinner; fi
            if verify_release_asset_checksum "$fallback_tag" "$asset_name" "$download_tmp"; then
                chmod +x "$download_tmp"
                xattr -c "$download_tmp" 2> /dev/null || true
                installer_commit_staged_path "$download_tmp" "$target_path" || return 1
                log_success "Downloaded ${binary_name} from ${fallback_tag} (v${version} not yet published)"
                return 0
            fi
            rm -f "$download_tmp"
            log_warning "Checksum verification failed for ${binary_name} from ${fallback_tag}"
        fi
        rm -f "$download_tmp" 2> /dev/null || true
        if [[ -t 1 ]]; then stop_line_spinner; fi
    fi

    log_warning "Could not download ${binary_name} binary, v${version}, trying local build"
    if install_built_binary_from_source "$binary_name" "$target_path"; then
        return 0
    fi
    log_error "Failed to install ${binary_name} binary"
    return 1
}

# File installation (bin/lib/scripts + go helpers).
install_files() {

    resolve_source_dir

    local source_dir_abs
    local install_dir_abs
    local config_dir_abs
    source_dir_abs="$(cd "$SOURCE_DIR" && pwd)"
    install_dir_abs="$(cd "$INSTALL_DIR" && pwd)"
    config_dir_abs="$(cd "$CONFIG_DIR" && pwd)"

    if [[ -f "$SOURCE_DIR/roomy" ]]; then
        if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
            if needs_sudo; then
                log_admin "Admin access required for /usr/local/bin"
                if [[ "${ROOMY_TEST_MODE:-0}" == "1" || "${ROOMY_TEST_NO_AUTH:-0}" == "1" ]]; then
                    log_error "Admin access required, blocked in test mode"
                    return 1
                fi
                sudo -v
            fi

            # Atomic update: copy to temporary name first, then move
            installer_prepare_executable_stage "$INSTALL_DIR/roomy.new" "Roomy executable" || return 1
            maybe_sudo cp "$SOURCE_DIR/roomy" "$INSTALL_DIR/roomy.new"
            maybe_sudo chmod +x "$INSTALL_DIR/roomy.new"
            installer_commit_executable_stage "$INSTALL_DIR/roomy.new" "$INSTALL_DIR/roomy" "Roomy executable" || return 1

            log_success "Installed roomy to $INSTALL_DIR"
        fi
    else
        log_error "roomy executable not found in ${SOURCE_DIR:-unknown}"
        exit 1
    fi

    if [[ -f "$SOURCE_DIR/mo" ]]; then
        if [[ "$source_dir_abs" == "$install_dir_abs" ]]; then
            log_success "mo alias already present"
        else
            installer_prepare_executable_stage "$INSTALL_DIR/mo.new" "mo alias" || return 1
            maybe_sudo cp "$SOURCE_DIR/mo" "$INSTALL_DIR/mo.new"
            maybe_sudo chmod +x "$INSTALL_DIR/mo.new"
            installer_commit_executable_stage "$INSTALL_DIR/mo.new" "$INSTALL_DIR/mo" "mo alias" || return 1
            log_success "Installed mo alias"
        fi
    fi

    if [[ -d "$SOURCE_DIR/bin" ]]; then
        local source_bin_abs="$(cd "$SOURCE_DIR/bin" && pwd)"
        local config_bin_abs="$(cd "$CONFIG_DIR/bin" && pwd)"
        if [[ "$source_bin_abs" == "$config_bin_abs" ]]; then
            log_success "Modules already synced"
        else
            local -a bin_files=("$SOURCE_DIR/bin"/*)
            if [[ ${#bin_files[@]} -gt 0 && -e "${bin_files[0]}" ]]; then
                for file in "${bin_files[@]}"; do
                    installer_copy_support_path "$file" "$CONFIG_DIR/bin/$(basename "$file")" true || return 1
                done
                log_success "Installed modules"
            fi
        fi
    fi

    if [[ -d "$SOURCE_DIR/lib" ]]; then
        local source_lib_abs="$(cd "$SOURCE_DIR/lib" && pwd)"
        local config_lib_abs="$(cd "$CONFIG_DIR/lib" && pwd)"
        if [[ "$source_lib_abs" == "$config_lib_abs" ]]; then
            log_success "Libraries already synced"
        else
            local -a lib_files=("$SOURCE_DIR/lib"/*)
            if [[ ${#lib_files[@]} -gt 0 && -e "${lib_files[0]}" ]]; then
                for file in "${lib_files[@]}"; do
                    installer_copy_support_path "$file" "$CONFIG_DIR/lib/$(basename "$file")" false || return 1
                done
                log_success "Installed libraries"
            fi
        fi
    fi

    if [[ "$config_dir_abs" != "$source_dir_abs" ]]; then
        for file in README.md LICENSE install.sh; do
            if [[ -f "$SOURCE_DIR/$file" ]]; then
                installer_copy_support_path "$SOURCE_DIR/$file" "$CONFIG_DIR/$file" false || return 1
            fi
        done
    fi

    if [[ -f "$CONFIG_DIR/install.sh" ]]; then
        chmod +x "$CONFIG_DIR/install.sh"
    fi

    if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
        # Use absolute /usr/bin/sed (always BSD on macOS) so PATH-shadowed
        # GNU sed from Homebrew gnu-sed does not break the -i '' syntax.
        local escaped_config_dir
        escaped_config_dir=$(escape_sed_replacement "$CONFIG_DIR")
        maybe_sudo /usr/bin/sed -i '' "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$escaped_config_dir\"|" "$INSTALL_DIR/roomy"
    fi

    if ! download_binary "analyze"; then
        exit 1
    fi
    if ! download_binary "status"; then
        exit 1
    fi
}

# Verification and PATH hint
verify_installation() {

    if [[ -x "$INSTALL_DIR/roomy" ]] && [[ -f "$CONFIG_DIR/lib/core/common.sh" ]]; then

        if "$INSTALL_DIR/roomy" --help > /dev/null 2>&1; then
            return 0
        else
            log_warning "Roomy command installed but may not be working properly"
        fi
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

setup_path() {
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        return
    fi

    if [[ "$INSTALL_DIR" != "/usr/local/bin" ]]; then
        log_warning "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "To use roomy from anywhere, add this line to your shell profile:"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        echo "For example, add it to ~/.zshrc or ~/.bash_profile"
    fi
}

print_usage_summary() {
    local action="$1"
    local new_version="$2"
    local previous_version="${3:-}"

    if [[ ${VERBOSE} -ne 1 ]]; then
        return
    fi

    echo ""

    local message="Roomy ${action} successfully"

    if [[ "$action" == "updated" && -n "$previous_version" && -n "$new_version" && "$previous_version" != "$new_version" ]]; then
        message+=", ${previous_version} -> ${new_version}"
    elif [[ -n "$new_version" ]]; then
        message+=", version ${new_version}"
    fi

    log_confirm "$message"

    echo ""
    echo "Usage:"
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        echo "  roomy                           # Interactive menu"
        echo "  roomy clean                     # Deep cleanup"
        echo "  roomy uninstall                 # Remove apps + leftovers"
        echo "  roomy optimize                  # Check and maintain system"
        echo "  roomy analyze                   # Explore disk usage"
        echo "  roomy status                    # Monitor system health"
        echo "  roomy touchid                   # Configure Touch ID for sudo"
        echo "  roomy update                    # Update to latest version"
        echo "  roomy --help                    # Show all commands"
    else
        echo "  $INSTALL_DIR/roomy                           # Interactive menu"
        echo "  $INSTALL_DIR/roomy clean                     # Deep cleanup"
        echo "  $INSTALL_DIR/roomy uninstall                 # Remove apps + leftovers"
        echo "  $INSTALL_DIR/roomy optimize                  # Check and maintain system"
        echo "  $INSTALL_DIR/roomy analyze                   # Explore disk usage"
        echo "  $INSTALL_DIR/roomy status                    # Monitor system health"
        echo "  $INSTALL_DIR/roomy touchid                   # Configure Touch ID for sudo"
        echo "  $INSTALL_DIR/roomy update                    # Update to latest version"
        echo "  $INSTALL_DIR/roomy --help                    # Show all commands"
    fi
    echo ""
}

# Main install/update flows
perform_install() {
    resolve_source_dir
    local source_version
    source_version="$(get_source_version || true)"

    check_requirements
    create_directories
    install_files
    verify_installation
    setup_path

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        installed_version="$source_version"
    fi

    local install_channel commit_hash=""
    install_channel="$(resolve_install_channel)"
    if [[ "$install_channel" == "nightly" ]]; then
        commit_hash=$(get_source_commit_hash)
    fi
    if ! write_install_channel_metadata "$install_channel" "$commit_hash"; then
        log_warning "Could not write install channel metadata"
    fi

    # Edge installs get a suffix to make the version explicit.
    if [[ "${ROOMY_EDGE_INSTALL:-}" == "true" ]]; then
        installed_version="${installed_version}-edge"
        echo ""
        local branch_name="${ROOMY_VERSION:-main}"
        log_warning "Edge version installed on ${branch_name} branch"
        log_info "This is a testing version; use 'roomy update' to switch to stable"
    fi

    print_usage_summary "installed" "$installed_version"
}

perform_update() {
    check_requirements

    if command -v brew > /dev/null 2>&1 && brew list roomy > /dev/null 2>&1; then
        resolve_source_dir 2> /dev/null || true
        local current_version
        current_version=$(get_installed_version || echo "unknown")
        if [[ -f "$SOURCE_DIR/lib/core/common.sh" ]]; then
            # shellcheck disable=SC1090,SC1091
            source "$SOURCE_DIR/lib/core/common.sh"
            update_via_homebrew "$current_version"
        else
            log_error "Cannot update Homebrew-managed Roomy without full installation"
            echo ""
            echo "Please update via Homebrew:"
            echo -e "  ${GREEN}brew upgrade roomy${NC}"
            exit 1
        fi
        exit 0
    fi

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        log_warning "Roomy is not currently installed in $INSTALL_DIR. Running fresh installation."
        perform_install
        return
    fi

    resolve_source_dir
    local target_version
    target_version="$(get_source_version || true)"

    if [[ -z "$target_version" ]]; then
        log_error "Unable to determine the latest Roomy version."
        exit 1
    fi

    if [[ "$installed_version" == "$target_version" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version, $installed_version"
        exit 0
    fi

    local old_verbose=$VERBOSE
    VERBOSE=0
    create_directories || {
        VERBOSE=$old_verbose
        log_error "Failed to create directories"
        exit 1
    }
    install_files || {
        VERBOSE=$old_verbose
        log_error "Failed to install files"
        exit 1
    }
    verify_installation || {
        VERBOSE=$old_verbose
        log_error "Failed to verify installation"
        exit 1
    }
    setup_path
    VERBOSE=$old_verbose

    local updated_version
    updated_version="$(get_installed_version || true)"

    if [[ -z "$updated_version" ]]; then
        updated_version="$target_version"
    fi

    local install_channel commit_hash=""
    install_channel="$(resolve_install_channel)"
    if [[ "$install_channel" == "nightly" ]]; then
        commit_hash=$(get_source_commit_hash)
    fi
    if ! write_install_channel_metadata "$install_channel" "$commit_hash"; then
        log_warning "Could not write install channel metadata"
    fi

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Updated to latest version, $updated_version"
}

parse_args "$@"

case "$ACTION" in
    update)
        perform_update
        ;;
    *)
        perform_install
        ;;
esac
