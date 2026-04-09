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
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "$HOME/.config"
    mkdir -p "$HOME/.config/mole"
}

@test "load_purge_config loads default paths when config file is missing" {
    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/Projects"* ]]
    [[ "$output" == *"$HOME/GitHub"* ]]
    [[ "$output" == *"$HOME/dev"* ]]
}

@test "load_purge_config loads custom paths from config file" {
    local config_file="$HOME/.config/mole/purge_paths"
    
    cat > "$config_file" << EOF
$HOME/custom/projects
$HOME/work
EOF

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/custom/projects"* ]]
    [[ "$output" == *"$HOME/work"* ]]
    [[ "$output" != *"$HOME/GitHub"* ]]
}

@test "load_purge_config expands tilde in paths" {
    local config_file="$HOME/.config/mole/purge_paths"
    
    cat > "$config_file" << EOF
~/tilde/expanded
~/another/one
EOF

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/tilde/expanded"* ]]
    [[ "$output" == *"$HOME/another/one"* ]]
    [[ "$output" != *"~"* ]]
}

@test "load_purge_config ignores comments and empty lines" {
    local config_file="$HOME/.config/mole/purge_paths"
    
    cat > "$config_file" << EOF
$HOME/valid/path

   
$HOME/another/path
EOF

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${#PURGE_SEARCH_PATHS[@]}\"; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    local lines
    read -r -a lines <<< "$output"
    local count="${lines[0]}"
    
    [ "$count" -eq 2 ]
    [[ "$output" == *"$HOME/valid/path"* ]]
    [[ "$output" == *"$HOME/another/path"* ]]
}

@test "load_purge_config falls back to defaults if config file is empty" {
    local config_file="$HOME/.config/mole/purge_paths"
    touch "$config_file"

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    [[ "$output" == *"$HOME/Projects"* ]]
}

@test "load_purge_config falls back to defaults if config file has only comments" {
    local config_file="$HOME/.config/mole/purge_paths"
    echo "# Just a comment" > "$config_file"

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""

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

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${#PURGE_SEARCH_PATHS[@]}\""

    [ "$status" -eq 0 ]

    # On case-insensitive FS (macOS default) both resolve to the same path,
    # so count should be 1. On case-sensitive FS, Code doesn't exist, so
    # resolve_path_case returns it unchanged — count may be 2 which is correct
    # since they really are different directories.
    if [[ -d "$HOME/Code" && "$(cd "$HOME/Code" && pwd -P)" == "$(cd "$HOME/code" && pwd -P)" ]]; then
        [ "$output" = "1" ]
    fi
}

@test "discover_project_dirs deduplicates default Code vs actual code" {
    # Simulate: $HOME/code exists (actual dir), $HOME/Code is in defaults
    mkdir -p "$HOME/code/myproject"
    touch "$HOME/code/myproject/package.json"

    # No config file — triggers discovery
    run env HOME="$HOME" bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        discover_project_dirs
    "

    [ "$status" -eq 0 ]

    # On case-insensitive FS, $HOME/code should appear only once
    if [[ -d "$HOME/Code" && "$(cd "$HOME/Code" && pwd -P)" == "$(cd "$HOME/code" && pwd -P)" ]]; then
        local count
        count=$(echo "$output" | grep -c "$HOME/code" || true)
        [ "$count" -le 1 ]
    fi
}
