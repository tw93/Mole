#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    
    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-purge-config.XXXXXX")"
    export HOME
    
    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "$HOME/.config"
    mkdir -p "$HOME/.config/mole"
}

@test "load_purge_config loads default paths when config file is missing" {
    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/Projects"* ]] || return 1
    [[ "$output" == *"$HOME/GitHub"* ]] || return 1
    [[ "$output" == *"$HOME/dev"* ]]
}

@test "load_purge_config loads custom paths from config file" {
    local config_file="$HOME/.config/mole/purge_paths"
    
    cat > "$config_file" << EOF
$HOME/custom/projects
$HOME/work
EOF

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/custom/projects"* ]] || return 1
    [[ "$output" == *"$HOME/work"* ]] || return 1
    [[ "$output" != *"$HOME/GitHub"* ]]
}

@test "load_purge_config can exclude default cloud storage roots" {
    local config_file="$HOME/.config/mole/purge_paths"

    cat > "$config_file" << EOF
$HOME/custom/projects
EOF

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; printf '%s\n' \"\${PURGE_SEARCH_PATHS[@]}\""

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == "$HOME/custom/projects" ]] || return 1
    [[ "$output" != *"$HOME/Library/CloudStorage"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Mobile Documents"* ]] || return 1
}

@test "load_purge_config expands tilde in paths" {
    local config_file="$HOME/.config/mole/purge_paths"
    
    cat > "$config_file" << EOF
~/tilde/expanded
~/another/one
EOF

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/tilde/expanded"* ]] || return 1
    [[ "$output" == *"$HOME/another/one"* ]] || return 1
    [[ "$output" != *"~"* ]]
}

@test "load_purge_config ignores comments and empty lines" {
    local config_file="$HOME/.config/mole/purge_paths"
    
    cat > "$config_file" << EOF
$HOME/valid/path

   
$HOME/another/path
EOF

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${#PURGE_SEARCH_PATHS[@]}\"; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    local lines
    read -r -a lines <<< "$output"
    local count="${lines[0]}"
    
    [ "$count" -eq 2 ]
    [[ "$output" == *"$HOME/valid/path"* ]] || return 1
    [[ "$output" == *"$HOME/another/path"* ]]
}

@test "load_purge_config falls back to defaults if config file is empty" {
    local config_file="$HOME/.config/mole/purge_paths"
    touch "$config_file"

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/Projects"* ]]
}

@test "load_purge_config falls back to defaults if config file has only comments" {
    local config_file="$HOME/.config/mole/purge_paths"
    echo "# Just a comment" > "$config_file"

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""

    [ "$status" -eq 0 ]

    [[ "$output" == *"$HOME/Projects"* ]]
}

@test "load_purge_config deduplicates case variants on case-insensitive FS" {
    # Create a real directory so resolve_path_case can cd into it
    mkdir -p "$HOME/code"

    local config_file="$HOME/.config/mole/purge_paths"
    cat > "$config_file" << EOF
$HOME/code
$HOME/Code
EOF

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${#PURGE_SEARCH_PATHS[@]}\""

    [ "$status" -eq 0 ]

    # On case-insensitive FS (macOS default) both resolve to the same path,
    # so count should be 1. On case-sensitive FS, Code doesn't exist, so
    # resolve_path_case returns it unchanged, count may be 2 which is correct
    # since they really are different directories. /bin/pwd queries the
    # filesystem (getcwd) so the case-folding test actually fires here,
    # unlike the bash builtin `pwd -P` which reuses the cd argument's
    # casing and makes this guard a no-op on APFS (#1416).
    if [[ -d "$HOME/Code" && "$(cd "$HOME/Code" && /bin/pwd -P)" == "$(cd "$HOME/code" && /bin/pwd -P)" ]]; then
        [ "$output" = "1" ]
    fi
}

@test "discover_project_dirs deduplicates default Code vs actual code" {
    # Simulate: $HOME/code exists (actual dir), $HOME/Code is in defaults
    mkdir -p "$HOME/code/myproject"
    touch "$HOME/code/myproject/package.json"

    # No config file, triggers discovery
    run env HOME="$HOME" /bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        discover_project_dirs
    "

    [ "$status" -eq 0 ]

    # On case-insensitive FS, $HOME/code should appear only once. See the
    # load_purge_config test above for why the guard uses /bin/pwd -P.
    if [[ -d "$HOME/Code" && "$(cd "$HOME/Code" && /bin/pwd -P)" == "$(cd "$HOME/code" && /bin/pwd -P)" ]]; then
        local count
        count=$(echo "$output" | grep -c "$HOME/code" || true)
        [ "$count" -le 1 ]
    fi
}

@test "discover_project_dirs shows a Workspace default once when the on-disk dir is workspace (#1416)" {
    # The default search paths include ~/Workspace (capital W). When the
    # real on-disk directory is ~/workspace (lowercase) on a
    # case-insensitive APFS volume, mole_purge_resolve_path_case used to
    # return ~/Workspace (bash's `pwd -P` reuses the cd argument's casing
    # instead of querying the filesystem), so the string dedup failed and
    # the project appeared twice in `mo purge` output.
    mkdir -p "$HOME/workspace/myproject"
    touch "$HOME/workspace/myproject/package.json"

    run env HOME="$HOME" /bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        discover_project_dirs
    "

    [ "$status" -eq 0 ]

    # Only run the count assertion where ~/Workspace folds onto
    # ~/workspace. On a case-sensitive FS ~/Workspace genuinely does not
    # exist and is correctly absent, so there is nothing to dedup.
    if [[ -d "$HOME/Workspace" && "$(cd "$HOME/Workspace" && /bin/pwd -P)" == "$(cd "$HOME/workspace" && /bin/pwd -P)" ]]; then
        local workspace_count
        workspace_count=$(printf '%s\n' "$output" | grep -c -iE "${HOME//\//\\/}/[Ww]orkspace$" || true)
        [ "$workspace_count" -eq 1 ]
    fi
}

@test "incomplete discovery keeps completed roots without saving a partial scope" {
    mkdir -p "$HOME/discovery"
    run env HOME="$HOME/discovery" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/Alpha/app" "$HOME/Slow/app"
touch "$HOME/Alpha/app/package.json"
run_with_timeout() {
    shift
    case "$2" in
        */Slow) return 124 ;;
        *) "$@" ;;
    esac
}
load_purge_config
[[ $PURGE_DISCOVERY_STATUS -eq 124 ]]
[[ "${PURGE_SEARCH_PATHS[*]}" == *"$HOME/Alpha"* ]]
[[ ! -e "$PURGE_CONFIG_FILE" ]]
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"discovery was incomplete"* ]] || return 1
}
