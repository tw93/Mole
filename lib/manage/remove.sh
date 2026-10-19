#!/bin/bash
# Mole self-removal: Homebrew formula, manual binaries, config and cache.
# Extracted from the `mole` dispatcher, which now only routes.

set -euo pipefail

if [[ -n "${MOLE_MANAGE_REMOVE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_MANAGE_REMOVE_LOADED=1

# Read the shipped launcher signatures, never execute a discovered command.
# Both main headers and common.sh locations are used by released Mole builds.
# Read bytes, not characters: a non-ASCII config path pinned by a UTF-8 printf
# %q is a raw lead byte plus \NNN escapes, and a UTF-8 awk rejects that record,
# which would hide an installed launcher from removal.
_remove_is_mole_launcher() {
    [[ -f "$1" ]] || return 1
    LC_ALL=C /usr/bin/awk '
        NR == 1 { bash = ($0 == "#!/bin/bash") }
        $0 == "# Mole - Main CLI entrypoint." || $0 == "# Mole - Main Entry Point" { main = 1 }
        /^VERSION=/ { version = 1 }
        $0 == "source \"$SCRIPT_DIR/lib/core/common.sh\"" || $0 == "source \"$SCRIPT_DIR/lib/common.sh\"" { library = 1 }
        $0 == "# Lightweight alias to run Mole via `mo`" { alias = 1 }
        $0 == "exec \"$SCRIPT_DIR/mole\" \"$@\"" { dispatch = 1 }
        NR >= 256 { exit }
        END { exit !(bash && ((main && version && library) || (alias && dispatch))) }
    ' "$1" 2> /dev/null
}

# Every removal performed by `mo remove` is a change to the Mac and has to
# leave one operations.log row (the logs themselves are kept).
_remove_log_removed() {
    local path="$1"
    local detail="${2:-}"
    if declare -f log_operation > /dev/null 2>&1; then
        log_operation "${MOLE_CURRENT_COMMAND:-remove}" "REMOVED" "$path" "$detail"
    fi
}

# Shell integration written by `mo completion`: one marker line in a shell rc
# file, and generated Fish completion files. Only these exact paths and this
# exact marker pattern (MOLE_COMPLETION_LINE_PATTERN, shared with
# bin/completion.sh) are touched; every other rc line is kept.

# Rc files that still carry a Mole completion entry.
_remove_completion_rc_files() {
    local candidate
    for candidate in \
        "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" \
        "$HOME/.config/fish/config.fish"; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        local target
        target=$(mole_resolve_link_chain "$candidate") || continue
        [[ -f "$target" ]] || continue
        if grep -Eq "$MOLE_COMPLETION_LINE_PATTERN" "$target"; then
            printf '%s\n' "$candidate"
        fi
    done
}

_remove_completion_fish_files() {
    local candidate
    for candidate in \
        "$HOME/.config/fish/completions/mole.fish" \
        "$HOME/.config/fish/completions/mo.fish"; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        printf '%s\n' "$candidate"
    done
}

# Remove only Mole's own completion entries. A symlinked rc file is rewritten
# through its target so the user's dotfile link survives, and the original mode
# is preserved. Returns nonzero when anything could not be cleaned.
_remove_completion_integration() {
    local rc_file target original_mode temp_file grep_rc helper_rc=0
    while IFS= read -r rc_file; do
        [[ -n "$rc_file" ]] || continue
        if ! target=$(mole_resolve_link_chain "$rc_file"); then
            log_warning "Could not resolve shell completion file: $rc_file"
            helper_rc=1
            continue
        fi
        original_mode=$("$STAT_BSD" -f '%Mp%Lp' "$target" 2> /dev/null || true)
        temp_file=$(mktemp "${TMPDIR:-/tmp}/mole-completion-clean.XXXXXX") || {
            log_warning "Could not prepare a temporary file to clean shell completion in $rc_file"
            helper_rc=1
            continue
        }
        grep_rc=0
        grep -Ev "$MOLE_COMPLETION_LINE_PATTERN" "$target" > "$temp_file" || grep_rc=$?
        if [[ "$grep_rc" -gt 1 ]]; then
            log_warning "Could not read shell completion entries from $target"
            rm -f "$temp_file" || true # SAFE: exact mktemp-created scratch file
            helper_rc=1
            continue
        fi
        # The target is fully resolved, so renaming over it leaves every rc
        # symlink in the chain pointing at the same file. Resolving only one
        # link used to replace an intermediate link with a plain file.
        if ! mv -f "$temp_file" "$target"; then
            log_warning "Could not remove shell completion from $rc_file"
            rm -f "$temp_file" || true # SAFE: exact mktemp-created scratch file
            helper_rc=1
            continue
        fi
        if [[ -n "$original_mode" ]]; then
            chmod "$original_mode" "$target" 2> /dev/null || true
        fi
        _remove_log_removed "$rc_file" "shell completion"
        log_success "Removed shell completion from $rc_file"
    done < <(_remove_completion_rc_files)

    local fish_file
    while IFS= read -r fish_file; do
        [[ -n "$fish_file" ]] || continue
        if rm -f "$fish_file"; then # SAFE: exact Fish completion files written by mo completion
            _remove_log_removed "$fish_file" "fish completion"
            log_success "Removed Fish completions: $fish_file"
        else
            log_warning "Could not remove Fish completions: $fish_file"
            helper_rc=1
        fi
    done < <(_remove_completion_fish_files)

    return "$helper_rc"
}

# Resolve this install without using directory contents as ownership proof.
# Source checkouts and Homebrew keep settings at the default path; install.sh
# records the chosen config in SCRIPT_DIR, including colocated installations.
_remove_config_dir() {
    local candidate="${MOLE_CONFIG_DIR:-${SCRIPT_DIR:-}}"
    local launcher="${SCRIPT_PATH:-}"
    if [[ -z "${MOLE_CONFIG_DIR:-}" ]]; then
        if declare -f is_homebrew_install > /dev/null 2>&1 && is_homebrew_install; then
            candidate=""
        elif [[ "${candidate%/}" == "${launcher%/*}" &&
            -f "$candidate/AGENTS.md" && -f "$candidate/go.mod" &&
            ! -f "$candidate/install_channel" && ! -f "$candidate/.helper_install_incomplete" ]]; then
            candidate=""
        fi
    fi
    candidate="${candidate:-${HOME%/}/.config/mole}"
    printf '%s\n' "${candidate%/}"
}

# Remove flow (Homebrew + manual + config/cache).
remove_mole() {
    local dry_run_mode="${1:-false}"
    # The router loads update.sh before remove.sh; isolated helper tests may not.
    if declare -f is_nix_install > /dev/null 2>&1 && is_nix_install; then
        local review_icon="${ICON_REVIEW:-⊙}"
        log_error "Mole was installed via Nix. Self-removal is disabled."
        printf '%s To remove Mole: nix profile remove mole or remove from your Nix configuration\n' "$review_icon"
        exit 1
    fi

    local remove_config_dir
    local test_mode=false
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        test_mode=true
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "Detecting Mole installations..."
    else
        echo "Detecting installations..."
    fi

    local is_homebrew=false
    local brew_cmd=""
    local brew_has_mole="false"
    local -a manual_installs=()
    local -a alias_installs=()

    if [[ "$test_mode" != "true" ]]; then
        if command -v brew > /dev/null 2>&1; then
            brew_cmd="brew"
        elif [[ -x "/opt/homebrew/bin/brew" ]]; then
            brew_cmd="/opt/homebrew/bin/brew"
        elif [[ -x "/usr/local/bin/brew" ]]; then
            brew_cmd="/usr/local/bin/brew"
        fi

        if [[ -n "$brew_cmd" ]]; then
            if brew_mole_formula_installed "$brew_cmd"; then
                brew_has_mole="true"
            fi
        fi

        if [[ "$brew_has_mole" == "true" ]] || is_homebrew_install; then
            is_homebrew=true
        fi
    fi

    local found_mole
    found_mole=""
    if [[ "$test_mode" != "true" ]]; then
        found_mole=$(command -v mole 2> /dev/null || true)
        if [[ -n "$found_mole" ]] && _remove_is_mole_launcher "$found_mole"; then
            if [[ ! -L "$found_mole" ]] || ! readlink "$found_mole" | grep -q "Cellar/mole"; then
                manual_installs+=("$found_mole")
            fi
        fi
    fi

    local -a fallback_paths=()
    if [[ "$test_mode" == "true" ]]; then
        fallback_paths=("$HOME/.local/bin/mole")
    else
        fallback_paths=(
            "/usr/local/bin/mole"
            "$HOME/.local/bin/mole"
            "/opt/local/bin/mole"
        )
    fi

    for path in "${fallback_paths[@]}"; do
        if [[ "$path" != "$found_mole" ]] && _remove_is_mole_launcher "$path"; then
            if [[ ! -L "$path" ]] || ! readlink "$path" | grep -q "Cellar/mole"; then
                manual_installs+=("$path")
            fi
        fi
    done

    local found_mo
    found_mo=""
    if [[ "$test_mode" != "true" ]]; then
        found_mo=$(command -v mo 2> /dev/null || true)
        if [[ -n "$found_mo" ]] && _remove_is_mole_launcher "$found_mo"; then
            if [[ ! -L "$found_mo" ]] || ! readlink "$found_mo" | grep -q "Cellar/mole"; then
                alias_installs+=("$found_mo")
            fi
        fi
    fi

    local -a alias_fallback=()
    if [[ "$test_mode" == "true" ]]; then
        alias_fallback=("$HOME/.local/bin/mo")
    else
        alias_fallback=(
            "/usr/local/bin/mo"
            "$HOME/.local/bin/mo"
            "/opt/local/bin/mo"
        )
    fi

    for alias in "${alias_fallback[@]}"; do
        if [[ "$alias" != "$found_mo" ]] && _remove_is_mole_launcher "$alias"; then
            if [[ ! -L "$alias" ]] || ! readlink "$alias" | grep -q "Cellar/mole"; then
                alias_installs+=("$alias")
            fi
        fi
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    printf '\n'

    remove_config_dir="$(_remove_config_dir)"

    local manual_count=${#manual_installs[@]}
    local alias_count=${#alias_installs[@]}
    if [[ "$is_homebrew" == "false" && ${manual_count:-0} -eq 0 && ${alias_count:-0} -eq 0 ]]; then
        printf '%s\n\n' "${YELLOW}No Mole installation detected${NC}"
        exit 0
    fi

    # Dry-run mode: show preview and exit without confirmation
    if [[ "$dry_run_mode" == "true" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, no files will be removed"
        echo ""
        echo -e "${YELLOW}Remove Mole${NC}, would delete the following:"
        if [[ "$is_homebrew" == "true" ]]; then
            echo -e "  ${GRAY}${ICON_LIST} Would run: brew uninstall --force mole${NC}"
        fi
        if [[ ${manual_count:-0} -gt 0 ]]; then
            for install in "${manual_installs[@]}"; do
                [[ -f "$install" ]] && echo -e "  ${GRAY}${ICON_LIST} Would remove: ${install}${NC}"
            done
        fi
        if [[ ${alias_count:-0} -gt 0 ]]; then
            for alias in "${alias_installs[@]}"; do
                [[ -f "$alias" ]] && echo -e "  ${GRAY}${ICON_LIST} Would remove: ${alias}${NC}"
            done
        fi
        local completion_rc
        while IFS= read -r completion_rc; do
            [[ -n "$completion_rc" ]] || continue
            echo -e "  ${GRAY}${ICON_LIST} Would remove: Mole shell completion from $completion_rc${NC}"
        done < <(_remove_completion_rc_files)
        local completion_fish
        while IFS= read -r completion_fish; do
            [[ -n "$completion_fish" ]] || continue
            echo -e "  ${GRAY}${ICON_LIST} Would remove: $completion_fish${NC}"
        done < <(_remove_completion_fish_files)
        [[ -d "$HOME/.cache/mole" ]] && echo -e "  ${GRAY}${ICON_LIST} Would remove: $HOME/.cache/mole${NC}"
        if [[ -d "$remove_config_dir" ]]; then
            if [[ "$remove_config_dir" == "${HOME%/}/.config/mole" ]]; then
                echo -e "  ${GRAY}${ICON_LIST} Would move to Trash: $remove_config_dir${NC}"
            else
                echo "  ${ICON_LIST} $remove_config_dir (kept for manual review)"
            fi
        fi
        [[ -d "$HOME/Library/Logs/mole" ]] && echo "  ${ICON_LIST} $HOME/Library/Logs/mole (kept, operation history)"

        printf '\n%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} Dry run complete, no changes made"
        exit 0
    fi

    echo -e "${YELLOW}Remove Mole${NC}, will delete the following:"
    if [[ "$is_homebrew" == "true" ]]; then
        echo "  ${ICON_LIST} Mole via Homebrew"
    fi
    for install in ${manual_installs[@]+"${manual_installs[@]}"} ${alias_installs[@]+"${alias_installs[@]}"}; do
        echo "  ${ICON_LIST} $install"
    done
    local completion_rc
    while IFS= read -r completion_rc; do
        [[ -n "$completion_rc" ]] || continue
        echo "  ${ICON_LIST} Mole shell completion in $completion_rc"
    done < <(_remove_completion_rc_files)
    local completion_fish
    while IFS= read -r completion_fish; do
        [[ -n "$completion_fish" ]] || continue
        echo "  ${ICON_LIST} $completion_fish"
    done < <(_remove_completion_fish_files)
    if [[ "$remove_config_dir" == "${HOME%/}/.config/mole" ]]; then
        echo "  ${ICON_LIST} ~/.config/mole (to Trash)"
    elif [[ -d "$remove_config_dir" ]]; then
        echo "  ${ICON_LIST} $remove_config_dir (kept for manual review)"
    fi
    echo "  ${ICON_LIST} ~/.cache/mole"
    [[ -d "$HOME/Library/Logs/mole" ]] && echo "  ${ICON_LIST} ~/Library/Logs/mole (kept, operation history)"
    # A read from a non-terminal fails and becomes an empty key, which the
    # case below treats as Enter: a script or background runner could confirm
    # removal without user consent. Only a real terminal may answer; tests
    # opt in through MOLE_TEST_MODE and drive the prompt explicitly.
    if [[ ! -t 0 && "${MOLE_TEST_MODE:-0}" != "1" ]]; then
        echo ""
        log_error "Removal confirmation needs an interactive terminal; Mole was not removed."
        log_info "Run mo remove from an interactive terminal, or use mo remove --dry-run to preview"
        exit 1
    fi

    echo -ne "${PURPLE}${ICON_ARROW}${NC} Press ${GREEN}Enter${NC} to confirm, ${GRAY}ESC${NC} to cancel: "

    drain_pending_input # Clean up any pending input before confirmation
    local key="" key_rc=0
    IFS= read -r -s -n1 key || key_rc=$?
    if [[ $key_rc -ne 0 ]]; then
        # Test fixtures drive the prompt through a pipe and may have
        # already consumed it; production only reaches here on a real
        # terminal, where EOF is not consent.
        if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
            key=""
        else
            echo ""
            log_error "Could not read the removal confirmation; Mole was not removed."
            log_info "Run mo remove from an interactive terminal; nothing was changed"
            exit 1
        fi
    fi
    drain_pending_input # Clean up any escape sequence remnants
    case "$key" in
        $'\e')
            exit 0
            ;;
        "" | $'\n' | $'\r')
            printf "\r\033[K" # Clear the prompt line
            ;;
        *)
            exit 0
            ;;
    esac

    local has_error=false
    if [[ "$is_homebrew" == "true" ]]; then
        if [[ -z "$brew_cmd" ]]; then
            log_error "Homebrew command not found. Please ensure Homebrew is installed and in your PATH."
            log_warning "Manual step: brew uninstall --force mole"
            exit 1
        fi

        log_info "Attempting to uninstall Mole via Homebrew..."
        local brew_uninstall_output
        if ! brew_uninstall_output=$("$brew_cmd" uninstall --force mole 2>&1); then
            has_error=true
            log_error "Homebrew uninstallation failed:"
            printf "%s\n" "$brew_uninstall_output" | sed "s/^/${RED}  | ${NC}/" >&2
            log_warning "Manual step: ${YELLOW}brew uninstall --force mole${NC}"
            echo "" # Add a blank line for readability
        else
            log_success "Mole uninstalled via Homebrew."
        fi
    fi
    # Aliases can be links to mole, so remove them while their target can
    # still prove ownership. Recheck after confirmation in case it changed.
    local install
    for install in ${alias_installs[@]+"${alias_installs[@]}"} ${manual_installs[@]+"${manual_installs[@]}"}; do
        if ! _remove_is_mole_launcher "$install"; then
            continue
        fi
        if [[ ! -w "$(dirname "$install")" ]]; then
            if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
                log_warning "Could not remove $install: admin access is unavailable in test mode"
                has_error=true
            elif ! sudo rm -f "$install"; then
                log_warning "Could not remove $install"
                has_error=true
            else
                _remove_log_removed "$install" "launcher"
            fi
        elif ! rm -f "$install"; then
            log_warning "Could not remove $install"
            has_error=true
        else
            _remove_log_removed "$install" "launcher"
        fi
    done
    # Shell completion is installed outside the config folder, so removing the
    # launchers alone hides it rather than taking it out.
    if ! _remove_completion_integration; then
        has_error=true
    fi
    if [[ -d "$HOME/.cache/mole" ]]; then
        if ! rm -rf "$HOME/.cache/mole"; then # SAFE: hardcoded Mole-owned dir, -d guarded
            log_warning "Could not remove $HOME/.cache/mole"
            has_error=true
        else
            _remove_log_removed "$HOME/.cache/mole" "cache"
        fi
    fi
    # --config can merge into a shared tree such as ~/.local. Neither known
    # top-level names nor a recursive filename inventory proves ownership.
    # Only the reserved default config root can be moved as a whole.
    if [[ "$remove_config_dir" == "${HOME%/}/.config/mole" && -d "$remove_config_dir" ]]; then
        # The config dir holds user-authored state (whitelist, purge config),
        # which is the one thing here a reinstall cannot rebuild. Move it to
        # Trash so it stays recoverable (#1346); the cache around it is
        # rebuildable and stays a permanent removal. On failure leave it in
        # place rather than falling back to deletion.
        local config_trash="$HOME/.Trash/mole-config"
        local config_trash_n=1
        while [[ -e "$config_trash" || -L "$config_trash" ]]; do
            config_trash="$HOME/.Trash/mole-config-$config_trash_n"
            config_trash_n=$((config_trash_n + 1))
        done
        if ! mkdir -p "$HOME/.Trash" 2> /dev/null ||
            ! mv -f "$remove_config_dir" "$config_trash" 2> /dev/null; then
            has_error=true
            log_warning "Could not move $remove_config_dir to Trash; left in place"
        fi
    fi
    # ~/Library/Logs/mole stays. operations.log and deletions.log are the
    # only record of what Mole removed, support answers deletion reports from
    # them, and Mole Mac reads the same folder for its own history.

    local final_message
    if [[ "$has_error" == "true" ]]; then
        final_message="${YELLOW}${ICON_ERROR} Mole uninstalled with some errors, thank you for using Mole!${NC}"
    else
        final_message="${GREEN}${ICON_SUCCESS} Mole uninstalled successfully, thank you for using Mole!${NC}"
    fi
    printf '\n%s\n\n' "$final_message"

    if [[ "$has_error" == "true" ]]; then
        exit 1
    fi
    exit 0
}
