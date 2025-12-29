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
    # Source the file in a subshell to avoid polluting test environment variables
    # We need to export HOME so it's picked up by the script
    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    # Check for a few expected default paths
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
    # Should NOT have default paths
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
# This is a comment
$HOME/valid/path

   # Indented comment
   
$HOME/another/path
EOF

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${#PURGE_SEARCH_PATHS[@]}\"; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    local lines
    read -r -a lines <<< "$output"
    # First line of output is count
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
    
    # Should have default paths
    [[ "$output" == *"$HOME/Projects"* ]]
}

@test "load_purge_config falls back to defaults if config file has only comments" {
    local config_file="$HOME/.config/mole/purge_paths"
    echo "# Just a comment" > "$config_file"

    run env HOME="$HOME" bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; echo \"\${PURGE_SEARCH_PATHS[*]}\""
    
    [ "$status" -eq 0 ]
    
    # Should have default paths
    [[ "$output" == *"$HOME/Projects"* ]]
}
