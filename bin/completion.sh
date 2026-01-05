#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/core/common.sh"
source "$ROOT_DIR/lib/core/commands.sh"

command_names=()
for entry in "${MOLE_COMMANDS[@]}"; do
    command_names+=("${entry%%:*}")
done
command_words="${command_names[*]}"

emit_zsh_subcommands() {
    for entry in "${MOLE_COMMANDS[@]}"; do
        printf "        '%s:%s'\n" "${entry%%:*}" "${entry#*:}"
    done
}

emit_fish_completions() {
    local cmd="$1"
    for entry in "${MOLE_COMMANDS[@]}"; do
        local name="${entry%%:*}"
        local desc="${entry#*:}"
        printf 'complete -c %s -n "__fish_mole_no_subcommand" -a %s -d "%s"\n' "$cmd" "$name" "$desc"
    done

    printf '\n'
    printf 'complete -c %s -n "not __fish_mole_no_subcommand" -a bash -d "generate bash completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
    printf 'complete -c %s -n "not __fish_mole_no_subcommand" -a zsh -d "generate zsh completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
    printf 'complete -c %s -n "not __fish_mole_no_subcommand" -a fish -d "generate fish completion" -n "__fish_see_subcommand_path completion"\n' "$cmd"
}

# Auto-install mode when run without arguments
if [[ $# -eq 0 ]]; then
    # Detect current shell
    current_shell="${SHELL##*/}"
    if [[ -z "$current_shell" ]]; then
        current_shell="$(ps -p "$PPID" -o comm= 2> /dev/null | awk '{print $1}')"
    fi

    completion_name=""
    if command -v mole > /dev/null 2>&1; then
        completion_name="mole"
    elif command -v mo > /dev/null 2>&1; then
        completion_name="mo"
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
        fish)
            config_file="${HOME}/.config/fish/config.fish"
            # shellcheck disable=SC2016
            completion_line='set -l output ('"$completion_name"' completion fish 2>/dev/null); and echo "$output" | source'
            ;;
        *)
            log_error "Unsupported shell: $current_shell"
            echo "  mole completion <bash|zsh|fish>"
            exit 1
            ;;
    esac

    if [[ -z "$completion_name" ]]; then
        if [[ -f "$config_file" ]] && grep -Eq "(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)" "$config_file" 2> /dev/null; then
            original_mode=""
            original_mode="$(stat -f '%Mp%Lp' -- "$config_file" 2> /dev/null || true)"
            temp_file="$(mktemp)"
            grep -Ev "(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
            mv -- "$temp_file" "$config_file"
            if [[ -n "$original_mode" ]]; then
                chmod -- "$original_mode" "$config_file" 2> /dev/null || true
            fi
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed stale completion entries from $config_file"
            echo ""
        fi
        log_error "mole not found in PATH - install Mole before enabling completion"
        exit 1
    fi

    # Check if already installed and normalize to latest line
    if [[ -f "$config_file" ]] && grep -Eq "(mole|mo)[[:space:]]+completion" "$config_file" 2> /dev/null; then
        original_mode=""
        original_mode="$(stat -f '%Mp%Lp' -- "$config_file" 2> /dev/null || true)"
        temp_file="$(mktemp)"
        grep -Ev "(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
        mv -- "$temp_file" "$config_file"
        if [[ -n "$original_mode" ]]; then
            chmod -- "$original_mode" "$config_file" 2> /dev/null || true
        fi
        {
            echo ""
            echo "# Mole shell completion"
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
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Enable completion for ${GREEN}${current_shell}${NC}? ${GRAY}Enter confirm / Q cancel${NC}: "
    IFS= read -r -s -n1 key || key=""
    drain_pending_input
    echo ""

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

    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        mkdir -p "$(dirname "$config_file")"
        touch -- "$config_file"
    fi

    # Remove previous Mole completion lines to avoid duplicates
    if [[ -f "$config_file" ]]; then
        original_mode=""
        original_mode="$(stat -f '%Mp%Lp' -- "$config_file" 2> /dev/null || true)"
        temp_file="$(mktemp)"
        grep -Ev "(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)" "$config_file" > "$temp_file" || true
        mv -- "$temp_file" "$config_file"
        if [[ -n "$original_mode" ]]; then
            chmod -- "$original_mode" "$config_file" 2> /dev/null || true
        fi
    fi

    # Add completion line
    {
        echo ""
        echo "# Mole shell completion"
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
_mole_completions()
{
    local cur_word prev_word
    cur_word="\${COMP_WORDS[\$COMP_CWORD]}"
    prev_word="\${COMP_WORDS[\$COMP_CWORD-1]}"

    if [ "\$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( \$(compgen -W "$command_words" -- "\$cur_word") )
    else
        case "\$prev_word" in
            completion)
                COMPREPLY=( \$(compgen -W "bash zsh fish" -- "\$cur_word") )
                ;;
            *)
                COMPREPLY=()
                ;;
        esac
    fi
}

complete -F _mole_completions mole mo
EOF
        ;;
    zsh)
        printf '#compdef mole mo\n\n'
        printf '_mole() {\n'
        printf '    local -a subcommands\n'
        printf '    subcommands=(\n'
        emit_zsh_subcommands
        printf '    )\n'
        printf "    _describe 'subcommand' subcommands\n"
        printf '}\n\n'
        printf 'compdef _mole mole mo\n'
        ;;
    fish)
        printf '# Completions for mole\n'
        emit_fish_completions mole
        printf '\n# Completions for mo (alias)\n'
        emit_fish_completions mo
        printf '\nfunction __fish_mole_no_subcommand\n'
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
Usage: mole completion [bash|zsh|fish]

Setup shell tab completion for mole and mo commands.

Auto-install:
  mole completion              # Auto-detect shell and install

Manual install:
  mole completion bash         # Generate bash completion script
  mole completion zsh          # Generate zsh completion script
  mole completion fish         # Generate fish completion script

Examples:
  # Auto-install (recommended)
  mole completion

  # Manual install - Bash
  eval "$(mole completion bash)"

  # Manual install - Zsh
  eval "$(mole completion zsh)"

  # Manual install - Fish
  mole completion fish | source
EOF
        exit 1
        ;;
esac
