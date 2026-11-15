#!/bin/bash
# Mole CLI (Linux) - completion: print a tab-completion script for bash, zsh
# or fish. The command list is read from the router's MOLE_COMMANDS, so a new
# command completes without touching this file. Nothing is written to the
# user's shell files; the help says where to put the line.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"

completion_help() {
    echo "Usage: mo completion bash|zsh|fish"
    echo ""
    echo "Print a tab-completion script. To load it in every new shell:"
    echo "  bash: echo 'eval \"\$(mo completion bash)\"' >> ~/.bashrc"
    echo "  zsh:  echo 'eval \"\$(mo completion zsh)\"' >> ~/.zshrc"
    echo "  fish: mo completion fish > ~/.config/fish/completions/mo.fish"
}

# "name<tab>description" per command, from the router.
commands() {
    awk '/^MOLE_COMMANDS=\(/ { on = 1; next } on && /^\)/ { exit }
        on { gsub(/^[[:space:]]*"|"[[:space:]]*$/, ""); i = index($0, ":"); print substr($0, 1, i - 1) "\t" substr($0, i + 1) }' \
        "$SCRIPT_DIR/mole"
}

names() { commands | cut -f1 | tr '\n' ' '; }

case "${1:-}" in
    bash)
        cat << EOF
_mole_complete() {
    if [[ \$COMP_CWORD -eq 1 ]]; then
        COMPREPLY=(\$(compgen -W "$(names)" -- "\${COMP_WORDS[1]}"))
    else
        COMPREPLY=(\$(compgen -W "--dry-run --help --json --yes --debug" -- "\${COMP_WORDS[COMP_CWORD]}"))
    fi
}
complete -o default -F _mole_complete mo mole
EOF
        ;;
    zsh)
        printf '#compdef mo mole\n_mole() {\n  local -a cmds\n  cmds=(\n'
        commands | while IFS=$'\t' read -r name desc; do printf "    '%s:%s'\n" "$name" "${desc//\'/}"; done
        printf '  )\n  if (( CURRENT == 2 )); then _describe command cmds; else _arguments "*:file:_files" "--dry-run" "--help" "--json" "--yes" "--debug"; fi\n}\n'
        printf 'compdef _mole mo mole\n'
        ;;
    fish)
        commands | while IFS=$'\t' read -r name desc; do
            printf "complete -c mo -c mole -f -n __fish_use_subcommand -a %s -d '%s'\n" "$name" "${desc//\'/}"
        done
        printf "complete -c mo -c mole -n 'not __fish_use_subcommand' -l %s\n" dry-run help json yes debug
        ;;
    -h | --help | "")
        completion_help
        ;;
    *)
        echo "Unknown shell: $1" >&2
        completion_help >&2
        exit 1
        ;;
esac
