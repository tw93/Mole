#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/core/common.sh"
source "$ROOT_DIR/lib/core/commands.sh"

command_names=()
for entry in "${ROOMY_COMMANDS[@]}"; do
    command_names+=("${entry%%:*}")
done
command_words="${command_names[*]}"
clean_option_words="--dry-run -n --external --categories --exclude --list-categories --yes --max-delete-gb --max-risk --require-dry-run-age --whitelist --debug --help -h"
analyze_option_words="--json --duplicates --duplicates-min-size --duplicates-timeout --duplicates-max-candidates --help -h"
update_option_words="--dry-run -n --force -f --nightly"

emit_zsh_subcommands() {
    for entry in "${ROOMY_COMMANDS[@]}"; do
        printf "        '%s:%s'\n" "${entry%%:*}" "${entry#*:}"
    done
}

emit_fish_completions() {
    local cmd="$1"
    for entry in "${ROOMY_COMMANDS[@]}"; do
        local name="${entry%%:*}"
        local desc="${entry#*:}"
        printf 'complete -f -c %s -n "__fish_roomy_no_subcommand" -a %s -d "%s"\n' "$cmd" "$name" "$desc"
    done

    printf '\n'
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l dry-run -s n -d "Preview cleanup without making changes"\n' "$cmd"
    printf 'complete -c %s -n "__fish_seen_subcommand_from clean" -l external -r -a "(__fish_complete_directories)" -d "Clean OS metadata from an external volume"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l categories -r -d "Run only selected categories"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l exclude -r -d "Skip selected categories"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l list-categories -d "Show cleanup category keys"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l yes -d "Confirm non-interactive cleanup"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l max-delete-gb -r -d "Stop above estimated GiB limit"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l max-risk -r -a "low medium high" -d "Stop above allowed risk"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l require-dry-run-age -r -d "Require recent dry-run preview"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l whitelist -d "Manage protected paths"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l debug -d "Show detailed logs"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from clean" -l help -s h -d "Show help"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l json -d "Output analysis as JSON"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l duplicates -d "Include duplicate file groups in JSON output"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l duplicates-min-size -r -d "Minimum duplicate candidate size in bytes"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l duplicates-timeout -r -d "Maximum duplicate scan duration, for example 30s"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l duplicates-max-candidates -r -d "Maximum duplicate candidate files to inspect"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from analyze analyse" -l help -s h -d "Show help"\n' "$cmd"
    printf 'complete -c %s -n "__fish_seen_subcommand_from analyze analyse; and not __fish_seen_argument -l json -l help -s h" -a "(__fish_complete_directories)" -d "Path to analyze"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from update" -l dry-run -s n -d "Preview update source and target"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from update" -l force -s f -d "Force reinstall latest stable version"\n' "$cmd"
    printf 'complete -f -c %s -n "__fish_seen_subcommand_from update" -l nightly -d "Install latest unreleased main branch build"\n' "$cmd"
    printf '\n'
    printf 'complete -f -c %s -n "not __fish_roomy_no_subcommand" -a bash -d "generate bash completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
    printf 'complete -f -c %s -n "not __fish_roomy_no_subcommand" -a zsh -d "generate zsh completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
    printf 'complete -f -c %s -n "not __fish_roomy_no_subcommand" -a fish -d "generate fish completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
}

remove_stale_completion_entries() {
    local config_file="$1"
    local success_message="$2"

    if [[ ! -f "$config_file" ]] || ! grep -Eq "(^# Roomy shell completion$|(roomy|mo)[[:space:]]+completion)" "$config_file" 2> /dev/null; then
        return 1
    fi

    local original_mode=""
    local temp_file
    original_mode="$(stat -f '%Mp%Lp' "$config_file" 2> /dev/null || true)"
    temp_file="$(mktemp)"
    grep -Ev "(^# Roomy shell completion$|(roomy|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
    mv "$temp_file" "$config_file"
    [[ -n "$original_mode" ]] && chmod "$original_mode" "$config_file" 2> /dev/null || true
    [[ -n "$success_message" ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} $success_message"
    return 0
}

completion_require_regular_dir_path() {
    local dir="$1"
    local label="$2"
    local current="${dir%/}"

    if [[ -z "$current" ]]; then
        echo "$label is empty" >&2
        return 1
    fi

    while [[ "$current" != "/" && "$current" != "${HOME%/}" ]]; do
        if [[ -L "$current" ]]; then
            echo "$label must not include symlinked directories: $current" >&2
            return 1
        fi
        current="$(dirname "$current")"
    done

    if [[ -e "$dir" && ! -d "$dir" ]]; then
        echo "$label must be a directory: $dir" >&2
        return 1
    fi
}

write_generated_file_atomically() {
    local target="$1"
    local parent base temp_file

    parent="$(dirname "$target")"
    base="$(basename "$target")"
    completion_require_regular_dir_path "$parent" "Completion target directory" || return 1
    mkdir -p "$parent"
    temp_file="$(mktemp "$parent/.${base}.XXXXXX")" || return 1
    if ! cat > "$temp_file"; then
        rm -f "$temp_file" 2> /dev/null || true
        return 1
    fi
    commit_staged_user_file "$temp_file" "$target"
}

if [[ $# -gt 0 ]]; then
    normalized_args=()
    for arg in "$@"; do
        case "$arg" in
            "--dry-run" | "-n")
                export ROOMY_DRY_RUN=1
                ;;
            *)
                normalized_args+=("$arg")
                ;;
        esac
    done
    if [[ ${#normalized_args[@]} -gt 0 ]]; then
        set -- "${normalized_args[@]}"
    else
        set --
    fi
fi

# Auto-install mode when run without arguments
if [[ $# -eq 0 ]]; then
    if [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, shell config files will not be modified"
        echo ""
    fi

    # Detect current shell
    current_shell="${SHELL##*/}"
    if [[ -z "$current_shell" ]]; then
        current_shell="$(ps -p "$PPID" -o comm= 2> /dev/null | awk '{print $1}')"
    fi

    completion_name=""
    if command -v roomy > /dev/null 2>&1; then
        completion_name="roomy"
    elif command -v mo > /dev/null 2>&1; then
        completion_name="mo"
    fi

    # Fish uses a separate install path: write to ~/.config/fish/completions/ so
    # both `roomy` and `mo` load completions independently on terminal startup.
    if [[ "$current_shell" == "fish" ]]; then
        fish_dir="${HOME}/.config/fish/completions"
        roomy_file="${fish_dir}/roomy.fish"
        mo_file="${fish_dir}/mo.fish"
        config_fish="${HOME}/.config/fish/config.fish"

        if [[ -z "$completion_name" ]]; then
            # Clean up any stale config.fish entries even when roomy is not in PATH
            if [[ "${ROOMY_DRY_RUN:-0}" != "1" ]]; then
                remove_stale_completion_entries "$config_fish" "Removed stale completion entries from config.fish" || true
            fi
            log_error "roomy not found in PATH, install Roomy before enabling completion"
            exit 1
        fi

        if [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]; then
            echo -e "${GRAY}${ICON_REVIEW} [DRY RUN] Would write Fish completions to:${NC}"
            echo "  $roomy_file"
            echo "  $mo_file"
            echo ""
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Dry run complete, no changes made"
            exit 0
        fi

        # Remove stale config.fish source-based entries (previous install method)
        if remove_stale_completion_entries "$config_fish" "Removed stale source-based entries from config.fish"; then
            echo ""
        fi

        # Prompt only on first install; silently update if files exist
        if [[ ! -f "$roomy_file" ]]; then
            echo ""
            echo -e "${GRAY}Will write Fish completions to:${NC}"
            echo "  $roomy_file"
            echo "  $mo_file"
            echo ""
            key=""
            if [[ "${ROOMY_API_AUTO_CONFIRM:-0}" != "1" ]]; then
                echo -ne "${PURPLE}${ICON_ARROW}${NC} Enable completion for ${GREEN}fish${NC}? ${GRAY}Enter confirm / Q cancel${NC}: "
                IFS= read -r -s -n1 key || key=""
                drain_pending_input
                echo ""
            fi

            if [[ "${ROOMY_API_AUTO_CONFIRM:-0}" != "1" ]]; then
                case "$key" in
                    $'\e' | [Qq] | [Nn])
                        echo -e "${YELLOW}Cancelled${NC}"
                        exit 0
                        ;;
                    "" | $'\n' | $'\r' | [Yy]) ;;
                    *)
                        log_error "Invalid key"
                        exit 1
                        ;;
                esac
            fi
        fi

        mkdir -p "$fish_dir"
        "$completion_name" completion fish | write_generated_file_atomically "$roomy_file"
        # mo.fish sources roomy.fish so Fish loads mo completions on `mo<Tab>`
        {
            printf '# Roomy completions for mo (alias) -- auto-generated, do not edit\n'
            printf 'source %s\n' "$roomy_file"
        } | write_generated_file_atomically "$mo_file"

        if [[ -f "$roomy_file" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Fish completions written to $fish_dir"
        fi
        echo ""
        exit 0
    fi

    case "$current_shell" in
        bash)
            config_file="${HOME}/.bashrc"
            [[ -f "${HOME}/.bash_profile" ]] && config_file="${HOME}/.bash_profile"
            # shellcheck disable=SC2016
            completion_line='if output="$('"$completion_name"' completion bash 2>/dev/null)"; then eval "$output"; fi'
            ;;
        zsh)
            config_file="${HOME}/.zshrc"
            # shellcheck disable=SC2016
            completion_line='if output="$('"$completion_name"' completion zsh 2>/dev/null)"; then eval "$output"; fi'
            ;;
        *)
            log_error "Unsupported shell: $current_shell"
            echo "  roomy completion <bash|zsh|fish>"
            exit 1
            ;;
    esac

    if [[ -z "$completion_name" ]]; then
        if [[ -f "$config_file" ]] && grep -Eq "(^# Roomy shell completion$|(roomy|mo)[[:space:]]+completion)" "$config_file" 2> /dev/null; then
            if [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]; then
                echo -e "${GRAY}${ICON_REVIEW} [DRY RUN] Would remove stale completion entries from $config_file${NC}"
                echo ""
            else
                original_mode=""
                original_mode="$(stat -f '%Mp%Lp' "$config_file" 2> /dev/null || true)"
                temp_file="$(mktemp)"
                grep -Ev "(^# Roomy shell completion$|(roomy|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
                mv "$temp_file" "$config_file"
                if [[ -n "$original_mode" ]]; then
                    chmod "$original_mode" "$config_file" 2> /dev/null || true
                fi
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed stale completion entries from $config_file"
                echo ""
            fi
        fi
        log_error "roomy not found in PATH, install Roomy before enabling completion"
        exit 1
    fi

    # Check if already installed and normalize to latest line
    if [[ -f "$config_file" ]] && grep -Eq "(roomy|mo)[[:space:]]+completion" "$config_file" 2> /dev/null; then
        if [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]; then
            echo -e "${GRAY}${ICON_REVIEW} [DRY RUN] Would normalize completion entry in $config_file${NC}"
            echo ""
            exit 0
        fi

        original_mode=""
        original_mode="$(stat -f '%Mp%Lp' "$config_file" 2> /dev/null || true)"
        temp_file="$(mktemp)"
        grep -Ev "(^# Roomy shell completion$|(roomy|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
        mv "$temp_file" "$config_file"
        if [[ -n "$original_mode" ]]; then
            chmod "$original_mode" "$config_file" 2> /dev/null || true
        fi
        {
            echo ""
            echo "# Roomy shell completion"
            echo "$completion_line"
        } >> "$config_file"
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Shell completion updated in $config_file"
        echo ""
        exit 0
    fi

    # Prompt user for installation
    echo ""
    echo -e "${GRAY}Will add to ${config_file}:${NC}"
    echo "  $completion_line"
    echo ""
    if [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Dry run complete, no changes made"
        exit 0
    fi

    key=""
    if [[ "${ROOMY_API_AUTO_CONFIRM:-0}" != "1" ]]; then
        echo -ne "${PURPLE}${ICON_ARROW}${NC} Enable completion for ${GREEN}${current_shell}${NC}? ${GRAY}Enter confirm / Q cancel${NC}: "
        IFS= read -r -s -n1 key || key=""
        drain_pending_input
        echo ""
    fi

    if [[ "${ROOMY_API_AUTO_CONFIRM:-0}" != "1" ]]; then
        case "$key" in
            $'\e' | [Qq] | [Nn])
                echo -e "${YELLOW}Cancelled${NC}"
                exit 0
                ;;
            "" | $'\n' | $'\r' | [Yy]) ;;
            *)
                log_error "Invalid key"
                exit 1
                ;;
        esac
    fi

    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        mkdir -p "$(dirname "$config_file")"
        touch "$config_file"
    fi

    # Remove previous Roomy completion lines to avoid duplicates
    if [[ -f "$config_file" ]]; then
        original_mode=""
        original_mode="$(stat -f '%Mp%Lp' "$config_file" 2> /dev/null || true)"
        temp_file="$(mktemp)"
        grep -Ev "(^# Roomy shell completion$|(roomy|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
        mv "$temp_file" "$config_file"
        if [[ -n "$original_mode" ]]; then
            chmod "$original_mode" "$config_file" 2> /dev/null || true
        fi
    fi

    # Add completion line
    {
        echo ""
        echo "# Roomy shell completion"
        echo "$completion_line"
    } >> "$config_file"

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Completion added to $config_file"
    echo ""
    echo ""
    echo -e "${GRAY}To activate now:${NC}"
    echo -e "  ${GREEN}source $config_file${NC}"
    exit 0
fi

case "$1" in
    bash)
        cat << EOF
_roomy_completions()
{
    local cur_word prev_word subcommand
    cur_word="\${COMP_WORDS[\$COMP_CWORD]}"
    prev_word="\${COMP_WORDS[\$COMP_CWORD-1]}"
    subcommand="\${COMP_WORDS[1]}"

    if [ "\$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( \$(compgen -W "$command_words" -- "\$cur_word") )
    else
        case "\$subcommand" in
            clean)
                case "\$prev_word" in
                    --external)
                        COMPREPLY=( \$(compgen -d -- "\$cur_word") )
                        ;;
                    --max-risk)
                        COMPREPLY=( \$(compgen -W "low medium high" -- "\$cur_word") )
                        ;;
                    *)
                        COMPREPLY=( \$(compgen -W "$clean_option_words" -- "\$cur_word") )
                        ;;
                esac
                ;;
            analyze|analyse)
                if [[ "\$cur_word" == -* ]]; then
                    COMPREPLY=( \$(compgen -W "$analyze_option_words" -- "\$cur_word") )
                else
                    COMPREPLY=( \$(compgen -f -- "\$cur_word") )
                fi
                ;;
            completion)
                COMPREPLY=( \$(compgen -W "bash zsh fish" -- "\$cur_word") )
                ;;
            update)
                COMPREPLY=( \$(compgen -W "$update_option_words" -- "\$cur_word") )
                ;;
            *)
                COMPREPLY=()
                ;;
        esac
    fi
}

complete -F _roomy_completions roomy mo
EOF
        ;;
    zsh)
        printf '#compdef roomy mo\n\n'
        printf '_roomy() {\n'
        printf '    local -a subcommands\n'
        printf '    subcommands=(\n'
        emit_zsh_subcommands
        printf '    )\n'
        printf '    if (( CURRENT == 2 )); then\n'
        printf "        _describe 'subcommand' subcommands\n"
        printf '        return\n'
        printf '    fi\n'
        printf "    case \"\$words[2]\" in\n"
        printf '        clean)\n'
        printf '            _arguments \\\n'
        printf "                '--dry-run[Preview cleanup without making changes]' \\\\\n"
        printf "                '-n[Preview cleanup without making changes]' \\\\\n"
        printf "                '--external[Clean OS metadata from an external volume]:path:_files -/' \\\\\n"
        printf "                '--categories[Run only selected categories]:categories:' \\\\\n"
        printf "                '--exclude[Skip selected categories]:categories:' \\\\\n"
        printf "                '--list-categories[Show cleanup category keys]' \\\\\n"
        printf "                '--yes[Confirm non-interactive cleanup]' \\\\\n"
        printf "                '--max-delete-gb[Stop above estimated GiB limit]:gib:' \\\\\n"
        printf "                '--max-risk[Stop above allowed risk]:risk:(low medium high)' \\\\\n"
        printf "                '--require-dry-run-age[Require recent dry-run preview]:hours:' \\\\\n"
        printf "                '--whitelist[Manage protected paths]' \\\\\n"
        printf "                '--debug[Show detailed logs]' \\\\\n"
        printf "                '(-h --help)'{-h,--help}'[Show help]'\n"
        printf '            ;;\n'
        printf '        analyze|analyse)\n'
        printf '            _arguments \\\n'
        printf "                '--json[Output analysis as JSON]' \\\\\n"
        printf "                '--duplicates[Include duplicate file groups in JSON output]' \\\\\n"
        printf "                '--duplicates-min-size[Minimum duplicate candidate size in bytes]:bytes:' \\\\\n"
        printf "                '--duplicates-timeout[Maximum duplicate scan duration, for example 30s]:duration:' \\\\\n"
        printf "                '--duplicates-max-candidates[Maximum duplicate candidate files to inspect]:count:' \\\\\n"
        printf "                '(-h --help)'{-h,--help}'[Show help]' \\\\\n"
        printf "                '*:path:_files'\n"
        printf '            ;;\n'
        printf '        completion)\n'
        printf "            _arguments '1:shell:(bash zsh fish)'\n"
        printf '            ;;\n'
        printf '        update)\n'
        printf '            _arguments \\\n'
        printf "                '(-n --dry-run)'{-n,--dry-run}'[Preview update source and target]' \\\\\n"
        printf "                '(-f --force)'{-f,--force}'[Force reinstall latest stable version]' \\\\\n"
        printf "                '--nightly[Install latest unreleased main branch build]'\n"
        printf '            ;;\n'
        printf '        *)\n'
        printf "            _describe 'subcommand' subcommands\n"
        printf '            ;;\n'
        printf '    esac\n'
        printf '}\n\n'
        printf 'compdef _roomy roomy mo\n'
        ;;
    fish)
        printf '# Completions for roomy\n'
        emit_fish_completions roomy
        printf '\n# Completions for mo (alias)\n'
        emit_fish_completions mo
        printf '\nfunction __fish_roomy_no_subcommand\n'
        printf '    for i in (commandline -opc)\n'
        # shellcheck disable=SC2016
        printf '        if contains -- $i %s\n' "$command_words"
        printf '            return 1\n'
        printf '        end\n'
        printf '    end\n'
        printf '    return 0\n'
        printf 'end\n\n'
        printf 'function __fish_see_subcommand_path\n'
        printf '    string match -q -- "completion" (commandline -opc)[1]\n'
        printf 'end\n'
        ;;
    *)
        cat << 'EOF'
Usage: roomy completion [bash|zsh|fish]

Setup shell tab completion for roomy and mo commands.

Auto-install:
  roomy completion              # Auto-detect shell and install
  roomy completion --dry-run    # Preview config changes without writing files

Manual install:
  roomy completion bash         # Generate bash completion script
  roomy completion zsh          # Generate zsh completion script
  roomy completion fish         # Generate fish completion script

Examples:
  # Auto-install (recommended)
  roomy completion

  # Manual install - Bash
  eval "$(roomy completion bash)"

  # Manual install - Zsh
  eval "$(roomy completion zsh)"

  # Manual install - Fish
  roomy completion fish | source
EOF
        exit 1
        ;;
esac
