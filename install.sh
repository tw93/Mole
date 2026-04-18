#!/bin/bash
# Mole - Installer for manual installs.
# Fetches source/binaries and installs to prefix.
# Supports update and edge installs.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

_INSTALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_INSTALL_ROOT/lib/core/tr.sh" ]]; then
    # shellcheck disable=SC1091
    source "$_INSTALL_ROOT/lib/core/tr.sh"
fi

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
        find "$target" -depth \( -type f -o -type l \) -exec rm -f {} + 2> /dev/null || true
        find "$target" -depth -type d -exec rmdir {} + 2> /dev/null || true
    else
        rm -f "$target" 2> /dev/null || true
    fi
}

# Install defaults
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/mole"
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
        sudo "$@"
    else
        "$@"
    fi
}

resolve_source_dir() {
    if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" && -f "$SOURCE_DIR/mole" ]]; then
        return 0
    fi

    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$script_dir/mole" ]]; then
            SOURCE_DIR="$script_dir"
            return 0
        fi
    fi

    if [[ -n "${CLEAN_SOURCE_DIR:-}" && -d "$CLEAN_SOURCE_DIR" && -f "$CLEAN_SOURCE_DIR/mole" ]]; then
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

    local branch="${MOLE_VERSION:-}"
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
        branch="$(normalize_release_tag "$branch")"
    fi
    local url="https://github.com/tw93/mole/archive/refs/heads/main.tar.gz"

    if [[ "$branch" == "dev" ]]; then
        url="https://github.com/tw93/mole/archive/refs/heads/dev.tar.gz"
    elif [[ "$branch" != "main" ]]; then
        url="https://github.com/tw93/mole/archive/refs/tags/${branch}.tar.gz"
    fi

    start_line_spinner "$(printf "${TR_INSTALL_FETCH_SRC:-Fetching Mole source, %s...}" "$branch")"
    if command -v curl > /dev/null 2>&1; then
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp/mole.tar.gz" "$url" 2> /dev/null; then
            if tar -xzf "$tmp/mole.tar.gz" -C "$tmp" 2> /dev/null; then
                stop_line_spinner

                local extracted_dir
                extracted_dir=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)

                if [[ -n "$extracted_dir" && -f "$extracted_dir/mole" ]]; then
                    SOURCE_DIR="$extracted_dir"
                    return 0
                fi
            fi
        else
            stop_line_spinner
            # Only exit early for version tags (not for main/dev branches)
            if [[ "$branch" != "main" && "$branch" != "dev" ]]; then
                log_error "$(printf "${TR_INSTALL_ERR_TAG:-Failed to fetch version %s. Check if tag exists.}" "$branch")"
                exit 1
            fi
        fi
    fi
    stop_line_spinner

    start_line_spinner "${TR_INSTALL_CLONE_SRC:-Cloning Mole source...}"
    if command -v git > /dev/null 2>&1; then
        local git_args=("--depth=1")
        if [[ "$branch" != "main" ]]; then
            git_args+=("--branch" "$branch")
        fi

        if git clone "${git_args[@]}" https://github.com/tw93/mole.git "$tmp/mole" > /dev/null 2>&1; then
            stop_line_spinner
            SOURCE_DIR="$tmp/mole"
            return 0
        fi
    fi
    stop_line_spinner

    log_error "${TR_INSTALL_ERR_FETCH_SRC:-Failed to fetch source files. Ensure curl or git is available.}"
    exit 1
}

# Version helpers
get_source_version() {
    local source_mole="$SOURCE_DIR/mole"
    if [[ -f "$source_mole" ]]; then
        sed -n 's/^VERSION="\(.*\)"$/\1/p' "$source_mole" | head -n1
    fi
}

get_source_commit_hash() {
    # Try to get from local git repo first
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        git -C "$SOURCE_DIR" rev-parse --short HEAD 2> /dev/null && return
    fi
    # Fallback to GitHub API
    curl -fsSL --connect-timeout 3 \
        "https://api.github.com/repos/tw93/mole/commits/main" 2> /dev/null |
        sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{7\}\).*/\1/p' | head -1
}

get_latest_release_tag() {
    local tag
    if ! command -v curl > /dev/null 2>&1; then
        return 1
    fi
    tag=$(curl -fsSL --connect-timeout 2 --max-time 3 \
        "https://api.github.com/repos/tw93/mole/releases/latest" 2> /dev/null |
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
    git ls-remote --tags --refs https://github.com/tw93/mole.git 2> /dev/null |
        awk -F/ '{print $NF}' |
        grep -E '^V[0-9]' |
        sort -V |
        tail -n 1
}

normalize_release_tag() {
    local tag="$1"
    while [[ "$tag" =~ ^[vV] ]]; do
        tag="${tag#v}"
        tag="${tag#V}"
    done
    if [[ -n "$tag" ]]; then
        printf 'V%s\n' "$tag"
    fi
}

get_installed_version() {
    local binary="$INSTALL_DIR/mole"
    if [[ -x "$binary" ]]; then
        local version
        version=$("$binary" --version 2> /dev/null | awk '/Mole version/ {print $NF; exit}')
        if [[ -n "$version" ]]; then
            echo "$version"
        else
            sed -n 's/^VERSION="\(.*\)"$/\1/p' "$binary" | head -n1
        fi
    fi
}

resolve_install_channel() {
    case "${MOLE_VERSION:-}" in
        main | latest)
            printf 'nightly\n'
            return 0
            ;;
        dev)
            printf 'dev\n'
            return 0
            ;;
    esac

    if [[ "${MOLE_EDGE_INSTALL:-}" == "true" ]]; then
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
    {
        printf 'CHANNEL=%s\n' "$channel"
        [[ -n "$commit_hash" ]] && printf 'COMMIT_HASH=%s\n' "$commit_hash"
    } > "$tmp_file" || {
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    }

    mv -f "$tmp_file" "$metadata_file" || {
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    }
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
                export MOLE_VERSION="main"
                export MOLE_EDGE_INSTALL="true"
                version_token="$token"
                unset 'args[$i]'
                ;;
            dev)
                export MOLE_VERSION="dev"
                export MOLE_EDGE_INSTALL="true"
                version_token="$token"
                unset 'args[$i]'
                ;;
            [0-9]* | V[0-9]* | v[0-9]*)
                export MOLE_VERSION="$token"
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
                log_error "Unknown option: $1"
                exit 1
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
        log_error "${TR_INSTALL_ERR_MACOS_ONLY:-This tool is designed for macOS only}"
        exit 1
    fi

    if command -v brew > /dev/null 2>&1 && brew list mole > /dev/null 2>&1; then
        local mole_path
        mole_path=$(command -v mole 2> /dev/null || true)
        local is_homebrew_binary=false

        if [[ -n "$mole_path" && -L "$mole_path" ]]; then
            if readlink "$mole_path" | grep -q "Cellar/mole"; then
                is_homebrew_binary=true
            fi
        fi

        if [[ "$is_homebrew_binary" == "true" ]]; then
            if [[ "$ACTION" == "update" ]]; then
                return 0
            fi

            echo -e "${YELLOW}${TR_INSTALL_HB_DETECTED:-Mole is installed via Homebrew}${NC}"
            echo ""
            echo "${TR_INSTALL_CHOOSE:-Choose one:}"
            echo -e "  ${TR_INSTALL_OPT_HB:-1. Update via Homebrew:} ${GREEN}brew upgrade mole${NC}"
            echo -e "  ${TR_INSTALL_OPT_MANUAL:-2. Switch to manual:} ${GREEN}brew uninstall --force mole${NC} then re-run this"
            echo ""
            exit 1
        else
            log_warning "${TR_INSTALL_WARN_HB_STALE:-Cleaning up stale Homebrew installation...}"
            brew uninstall --force mole > /dev/null 2>&1 || true
        fi
    fi

    if [[ ! -d "$(dirname "$INSTALL_DIR")" ]]; then
        log_error "$(printf "${TR_INSTALL_ERR_PARENT_DIR:-Parent directory %s does not exist}" "$(dirname "$INSTALL_DIR")")"
        exit 1
    fi
}

create_directories() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        maybe_sudo mkdir -p "$INSTALL_DIR"
    fi

    if ! mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib"; then
        log_error "$(printf "${TR_INSTALL_ERR_CONFIG_MK:-Failed to create config directory: %s}" "$CONFIG_DIR")"
        exit 1
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
        start_line_spinner "$(printf "${TR_INSTALL_BUILDING_SRC:-Building %s from source...}" "$binary_name")"
    else
        echo "$(printf "${TR_INSTALL_BUILDING_SRC:-Building %s from source...}" "$binary_name")"
    fi

    if (cd "$SOURCE_DIR" && go build -ldflags="-s -w" -o "$target_path" "./$cmd_dir" > /dev/null 2>&1); then
        if [[ -t 1 ]]; then stop_line_spinner; fi
        chmod +x "$target_path"
        log_success "$(printf "${TR_INSTALL_OK_BUILT:-Built %s from source}" "$binary_name")"
        return 0
    fi

    if [[ -t 1 ]]; then stop_line_spinner; fi
    log_warning "$(printf "${TR_INSTALL_WARN_BUILD_FAIL:-Failed to build %s from source}" "$binary_name")"
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
        cp "$SOURCE_DIR/bin/${binary_name}-go" "$target_path"
        chmod +x "$target_path"
        log_success "$(printf "${TR_INSTALL_OK_INST_LOCAL:-Installed local %s binary}" "$binary_name")"
        return 0
    elif [[ -f "$SOURCE_DIR/bin/${binary_name}-darwin-${arch_suffix}" ]]; then
        cp "$SOURCE_DIR/bin/${binary_name}-darwin-${arch_suffix}" "$target_path"
        chmod +x "$target_path"
        log_success "$(printf "${TR_INSTALL_OK_INST_LOCAL:-Installed local %s binary}" "$binary_name")"
        return 0
    fi

    if [[ "${MOLE_EDGE_INSTALL:-}" == "true" ]]; then
        if build_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
    fi

    local version
    version=$(get_source_version)
    if [[ -z "$version" ]]; then
        log_warning "$(printf "${TR_INSTALL_WARN_NO_VER:-Could not determine version for %s, trying local build}" "$binary_name")"
        if build_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
        return 1
    fi
    local url="https://github.com/tw93/mole/releases/download/V${version}/${binary_name}-darwin-${arch_suffix}"

    # Skip preflight network checks to avoid false negatives.

    if [[ -t 1 ]]; then
        start_line_spinner "$(printf "${TR_INSTALL_DOWNLOADING:-Downloading %s...}" "$binary_name")"
    else
        echo "$(printf "${TR_INSTALL_DOWNLOADING:-Downloading %s...}" "$binary_name")"
    fi

    if curl -fsSL --connect-timeout 10 --max-time 60 -o "$target_path" "$url"; then
        if [[ -t 1 ]]; then stop_line_spinner; fi
        chmod +x "$target_path"
        xattr -c "$target_path" 2> /dev/null || true
        log_success "$(printf "${TR_INSTALL_OK_DOWNLOADED:-Downloaded %s binary}" "$binary_name")"
    else
        if [[ -t 1 ]]; then stop_line_spinner; fi
        log_warning "$(printf "${TR_INSTALL_WARN_DL_FAIL:-Could not download %s binary, v%s, trying local build}" "$binary_name" "$version")"
        if build_binary_from_source "$binary_name" "$target_path"; then
            return 0
        fi
        log_error "$(printf "${TR_INSTALL_ERR_INST_BIN:-Failed to install %s binary}" "$binary_name")"
        return 1
    fi
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

    if [[ -f "$SOURCE_DIR/mole" ]]; then
        if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
            if needs_sudo; then
                log_admin "${TR_INSTALL_MSG_ADMIN_USR_LOCAL:-Admin access required for /usr/local/bin}"
                sudo -v
            fi

            # Atomic update: copy to temporary name first, then move
            maybe_sudo cp "$SOURCE_DIR/mole" "$INSTALL_DIR/mole.new"
            maybe_sudo chmod +x "$INSTALL_DIR/mole.new"
            maybe_sudo mv -f "$INSTALL_DIR/mole.new" "$INSTALL_DIR/mole"

            log_success "$(printf "${TR_INSTALL_OK_MOLE_TO:-Installed mole to %s}" "$INSTALL_DIR")"
        fi
    else
        log_error "$(printf "${TR_INSTALL_ERR_MOLE_MISSING:-mole executable not found in %s}" "${SOURCE_DIR:-unknown}")"
        exit 1
    fi

    if [[ -f "$SOURCE_DIR/mo" ]]; then
        if [[ "$source_dir_abs" == "$install_dir_abs" ]]; then
            log_success "${TR_INSTALL_OK_MO_ALIAS:-mo alias already present}"
        else
            maybe_sudo cp "$SOURCE_DIR/mo" "$INSTALL_DIR/mo.new"
            maybe_sudo chmod +x "$INSTALL_DIR/mo.new"
            maybe_sudo mv -f "$INSTALL_DIR/mo.new" "$INSTALL_DIR/mo"
            log_success "${TR_INSTALL_OK_MO_INST:-Installed mo alias}"
        fi
    fi

    if [[ -d "$SOURCE_DIR/bin" ]]; then
        local source_bin_abs="$(cd "$SOURCE_DIR/bin" && pwd)"
        local config_bin_abs="$(cd "$CONFIG_DIR/bin" && pwd)"
        if [[ "$source_bin_abs" == "$config_bin_abs" ]]; then
            log_success "${TR_INSTALL_OK_MOD_SYNC:-Modules already synced}"
        else
            local -a bin_files=("$SOURCE_DIR/bin"/*)
            if [[ ${#bin_files[@]} -gt 0 ]]; then
                cp -r "${bin_files[@]}" "$CONFIG_DIR/bin/"
                for file in "$CONFIG_DIR/bin/"*; do
                    [[ -e "$file" ]] && chmod +x "$file"
                done
                log_success "${TR_INSTALL_OK_MOD_INST:-Installed modules}"
            fi
        fi
    fi

    if [[ -d "$SOURCE_DIR/lib" ]]; then
        local source_lib_abs="$(cd "$SOURCE_DIR/lib" && pwd)"
        local config_lib_abs="$(cd "$CONFIG_DIR/lib" && pwd)"
        if [[ "$source_lib_abs" == "$config_lib_abs" ]]; then
            log_success "${TR_INSTALL_OK_LIB_SYNC:-Libraries already synced}"
        else
            local -a lib_files=("$SOURCE_DIR/lib"/*)
            if [[ ${#lib_files[@]} -gt 0 ]]; then
                cp -r "${lib_files[@]}" "$CONFIG_DIR/lib/"
                log_success "${TR_INSTALL_OK_LIB_INST:-Installed libraries}"
            fi
        fi
    fi

    if [[ "$config_dir_abs" != "$source_dir_abs" ]]; then
        for file in README.md LICENSE install.sh; do
            if [[ -f "$SOURCE_DIR/$file" ]]; then
                cp -f "$SOURCE_DIR/$file" "$CONFIG_DIR/"
            fi
        done
    fi

    if [[ -f "$CONFIG_DIR/install.sh" ]]; then
        chmod +x "$CONFIG_DIR/install.sh"
    fi

    if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
        maybe_sudo sed -i '' "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$CONFIG_DIR\"|" "$INSTALL_DIR/mole"
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

    if [[ -x "$INSTALL_DIR/mole" ]] && [[ -f "$CONFIG_DIR/lib/core/common.sh" ]]; then

        if "$INSTALL_DIR/mole" --help > /dev/null 2>&1; then
            return 0
        else
            log_warning "${TR_INSTALL_WARN_VERIFY:-Mole command installed but may not be working properly}"
        fi
    else
        log_error "${TR_INSTALL_ERR_VERIFY:-Installation verification failed}"
        exit 1
    fi
}

setup_path() {
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        return
    fi

    if [[ "$INSTALL_DIR" != "/usr/local/bin" ]]; then
        log_warning "$(printf "${TR_INSTALL_NOT_IN_PATH:-%s is not in your PATH}" "$INSTALL_DIR")"
        echo ""
        echo "${TR_INSTALL_PATH_HINT1:-To use mole from anywhere, add this line to your shell profile:}"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        echo "${TR_INSTALL_PATH_HINT2:-For example, add it to ~/.zshrc or ~/.bash_profile}"
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

    local message
    message="$(printf "${TR_INSTALL_SUCCESS_FMT:-Mole %s successfully}" "$action")"

    if [[ "$action" == "updated" && -n "$previous_version" && -n "$new_version" && "$previous_version" != "$new_version" ]]; then
        message+=", ${previous_version} -> ${new_version}"
    elif [[ -n "$new_version" ]]; then
        message+=", version ${new_version}"
    fi

    log_confirm "$message"

    echo ""
    echo "${TR_HELP_USAGE:-Usage}:"
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        echo "  mo                           # ${TR_HELP_MAIN_MENU_DESC:-Interactive menu}"
        echo "  mo clean                     # ${TR_CMD_CLEAN:-Deep cleanup}"
        echo "  mo uninstall                 # ${TR_CMD_UNINSTALL:-Remove apps + leftovers}"
        echo "  mo optimize                  # ${TR_CMD_OPTIMIZE:-Check and maintain system}"
        echo "  mo analyze                   # ${TR_CMD_ANALYZE:-Explore disk usage}"
        echo "  mo status                    # ${TR_CMD_STATUS:-Monitor system health}"
        echo "  mo touchid                   # ${TR_CMD_TOUCHID:-Configure Touch ID for sudo}"
        echo "  mo update                    # ${TR_CMD_UPDATE:-Update to latest version}"
        echo "  mo --help                    # ${TR_CMD_HELP:-Show all commands}"
    else
        echo "  $INSTALL_DIR/mo                           # ${TR_HELP_MAIN_MENU_DESC:-Interactive menu}"
        echo "  $INSTALL_DIR/mo clean                     # ${TR_CMD_CLEAN:-Deep cleanup}"
        echo "  $INSTALL_DIR/mo uninstall                 # ${TR_CMD_UNINSTALL:-Remove apps + leftovers}"
        echo "  $INSTALL_DIR/mo optimize                  # ${TR_CMD_OPTIMIZE:-Check and maintain system}"
        echo "  $INSTALL_DIR/mo analyze                   # ${TR_CMD_ANALYZE:-Explore disk usage}"
        echo "  $INSTALL_DIR/mo status                    # ${TR_CMD_STATUS:-Monitor system health}"
        echo "  $INSTALL_DIR/mo touchid                   # ${TR_CMD_TOUCHID:-Configure Touch ID for sudo}"
        echo "  $INSTALL_DIR/mo update                    # ${TR_CMD_UPDATE:-Update to latest version}"
        echo "  $INSTALL_DIR/mo --help                    # ${TR_CMD_HELP:-Show all commands}"
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
    if [[ "${MOLE_EDGE_INSTALL:-}" == "true" ]]; then
        installed_version="${installed_version}-edge"
        echo ""
        local branch_name="${MOLE_VERSION:-main}"
        log_warning "$(printf "${TR_INSTALL_WARN_EDGE:-Edge version installed on %s branch}" "$branch_name")"
        log_info "${TR_INSTALL_MSG_EDGE_HINT:-This is a testing version; use 'mo update' to switch to stable}"
    fi

    print_usage_summary "installed" "$installed_version"
}

perform_update() {
    check_requirements

    if command -v brew > /dev/null 2>&1 && brew list mole > /dev/null 2>&1; then
        resolve_source_dir 2> /dev/null || true
        local current_version
        current_version=$(get_installed_version || echo "unknown")
        if [[ -f "$SOURCE_DIR/lib/core/common.sh" ]]; then
            # shellcheck disable=SC1090,SC1091
            source "$SOURCE_DIR/lib/core/common.sh"
            update_via_homebrew "$current_version"
        else
            log_error "${TR_INSTALL_ERR_HB_MANAGED:-Cannot update Homebrew-managed Mole without full installation}"
            echo ""
            echo "${TR_INSTALL_UPDATE_VIA_HB:-Please update via Homebrew:}"
            echo -e "  ${GREEN}brew upgrade mole${NC}"
            exit 1
        fi
        exit 0
    fi

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        log_warning "$(printf "${TR_INSTALL_WARN_NOT_INST:-Mole is not currently installed in %s. Running fresh installation.}" "$INSTALL_DIR")"
        perform_install
        return
    fi

    resolve_source_dir
    local target_version
    target_version="$(get_source_version || true)"

    if [[ -z "$target_version" ]]; then
        log_error "${TR_INSTALL_ERR_LATEST_VER:-Unable to determine the latest Mole version.}"
        exit 1
    fi

    if [[ "$installed_version" == "$target_version" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} ${TR_UPDATE_LATEST:-Already on latest version}, $installed_version"
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

    echo -e "${GREEN}${ICON_SUCCESS}${NC} ${TR_UPD_UPDATED:-Updated to latest version}, $updated_version"
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
