#!/usr/bin/env bats

load helpers/common

setup_file() {
    export MOLE_PURGE_YES=1
    mole_test_setup_home purge-config
}

teardown_file() {
    mole_test_teardown_home
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

@test "purge paths preserves a single custom path without a final newline" {
    local config_file="$HOME/.config/mole/purge_paths"
    local expected_file="$BATS_TEST_TMPDIR/expected-purge-paths"
    mkdir -p "$HOME/Projects" "$HOME/custom projects"
    printf '%s' "$HOME/custom projects" > "$config_file"
    cp "$config_file" "$expected_file"

    run env HOME="$HOME" EDITOR=/usr/bin/true MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Using custom config with 1 paths"* ]] || return 1
    cmp "$expected_file" "$config_file"
}

@test "load_purge_config includes the final custom path without a newline" {
    local config_file="$HOME/.config/mole/purge_paths"
    printf '%s\n%s' "$HOME/first" "$HOME/second project" > "$config_file"

    run env HOME="$HOME" /bin/bash -c "source '$PROJECT_ROOT/lib/clean/project.sh'; printf '%s\\n' \"\${PURGE_SEARCH_PATHS[@]}\""

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == "$HOME/first"$'\n'"$HOME/second project" ]]
}

@test "purge refuses unreadable custom paths without replacing them with discovered roots" {
    local option
    for option in --paths --dry-run; do
        local fixture_home="$BATS_TEST_TMPDIR/home-$option"
        local config_file="$fixture_home/.config/mole/purge_paths"
        local expected_file="$BATS_TEST_TMPDIR/expected-$option"
        mkdir -p "$fixture_home/.config/mole" "$fixture_home/custom projects" "$fixture_home/Projects/demo"
        touch "$fixture_home/Projects/demo/package.json"
        printf '%s\n' "$fixture_home/custom projects" > "$config_file"
        cp "$config_file" "$expected_file"
        chmod 000 "$config_file"
        if [[ -r "$config_file" ]]; then
            chmod 600 "$config_file"
            skip "requires a user that cannot read mode-000 files"
        fi

        run env HOME="$fixture_home" EDITOR=/usr/bin/true MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge "$option"

        chmod 600 "$config_file"
        cmp "$expected_file" "$config_file" || return 1
        [ "$status" -ne 0 ] || return 1
        [[ "$output" == *"Cannot read your purge paths:"* ]] || return 1
        [[ "$output" == *"chmod u+r"* ]] || return 1
        [[ "$output" != *"purge_shared.sh"* ]] || return 1
        [[ "$output" != *"Configuration updated"* ]] || return 1
    done
}

@test "purge paths preserves custom paths when the editor makes the configuration unreadable" {
    local fixture_home="$BATS_TEST_TMPDIR/editor-home"
    local config_file="$fixture_home/.config/mole/purge_paths"
    local expected_file="$BATS_TEST_TMPDIR/expected-editor-paths"
    mkdir -p "$fixture_home/.config/mole" "$fixture_home/custom projects" "$fixture_home/Projects/demo"
    touch "$fixture_home/Projects/demo/package.json"
    printf '%s\n' "$fixture_home/custom projects" > "$config_file"
    cp "$config_file" "$expected_file"
    chmod 000 "$config_file"
    if [[ -r "$config_file" ]]; then
        chmod 600 "$config_file"
        skip "requires a user that cannot read mode-000 files"
    fi
    chmod 600 "$config_file"

    run env HOME="$fixture_home" EDITOR="/bin/chmod 000" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    chmod 600 "$config_file"
    cmp "$expected_file" "$config_file" || return 1
    [ "$status" -ne 0 ] || return 1
    [[ "$output" == *"Cannot read your purge paths:"* ]] || return 1
    [[ "$output" == *"chmod u+r"* ]] || return 1
    [[ "$output" != *"purge_shared.sh"* ]] || return 1
    [[ "$output" != *"Configuration updated"* ]]
}

@test "purge refuses a config path that is not a readable file without discovering or rewriting" {
    local kind
    for kind in broken-link link-loop directory unsearchable-parent; do
        local fixture_home="$BATS_TEST_TMPDIR/home-$kind"
        local config_file="$fixture_home/.config/mole/purge_paths"
        mkdir -p "$fixture_home/.config/mole" "$fixture_home/Projects/demo"
        touch "$fixture_home/Projects/demo/package.json"
        case "$kind" in
            broken-link) ln -s "$fixture_home/unmounted/purge_paths" "$config_file" ;;
            link-loop) ln -s "$config_file" "$config_file" ;;
            directory) mkdir "$config_file" ;;
            unsearchable-parent)
                printf '%s\n' "$fixture_home/custom" > "$config_file"
                chmod 000 "$fixture_home/.config/mole"
                if [[ -x "$fixture_home/.config/mole" ]]; then
                    chmod 700 "$fixture_home/.config/mole"
                    skip "requires a user that cannot search mode-000 directories"
                fi
                ;;
        esac

        run env HOME="$fixture_home" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --dry-run

        [[ "$kind" != "unsearchable-parent" ]] || chmod 700 "$fixture_home/.config/mole"
        [ "$status" -ne 0 ] || return 1
        case "$kind" in
            broken-link | directory)
                [[ "$output" == *"Cannot read your purge paths: invalid path or broken link:"* ]] || return 1
                ;;
            link-loop)
                [[ "$output" == *"Cannot inspect your purge paths path:"* ]] || return 1
                ;;
            unsearchable-parent)
                [[ "$output" == *"Cannot access your purge paths directory:"* ]] || return 1
                [[ "$output" == *"chmod u+rx"* ]] || return 1
                ;;
        esac
        case "$kind" in
            directory)
                [[ -d "$config_file" ]] || return 1
                [[ -z "$(ls -A "$config_file")" ]] || return 1
                ;;
            unsearchable-parent)
                [[ "$(cat "$config_file")" == "$fixture_home/custom" ]] || return 1
                ;;
            *)
                [[ -L "$config_file" ]] || return 1
                ;;
        esac
    done
}

@test "load_purge_config keeps signal statuses silent and reports other read failures" {
    run env HOME="$HOME" /bin/bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\\n' '$HOME/custom' > \"\$PURGE_CONFIG_FILE\"
        mole_purge_read_paths_config() { return 130; }
        load_purge_config && echo 'signal=0' || echo \"signal=\$?\"
        mole_purge_read_paths_config() { return 1; }
        load_purge_config && echo 'failure=0' || echo \"failure=\$?\"
        cat \"\$PURGE_CONFIG_FILE\"
    "

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"signal=130"* ]] || return 1
    [[ "$output" == *"failure=1"* ]] || return 1
    [ "$(grep -c 'Cannot read your purge paths' <<< "$output")" -eq 1 ] || return 1
    [[ "$output" == *"$HOME/custom"* ]] || return 1
}

@test "mo clean readers of an unreadable purge config print no shell error" {
    local config_file="$HOME/.config/mole/purge_paths"
    mkdir -p "$HOME/.config/mole"
    printf '%s\n' "$HOME/custom" > "$config_file"
    chmod 000 "$config_file"
    if [[ -r "$config_file" ]]; then
        chmod 600 "$config_file"
        skip "requires a user that cannot read mode-000 files"
    fi

    run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc -c "
        source '$PROJECT_ROOT/bin/clean.sh'
        discover_project_cache_roots > /dev/null
        load_quick_purge_hint_paths > /dev/null
        echo finished
    "

    chmod 600 "$config_file"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"finished"* ]] || return 1
    [[ "$output" != *"Permission denied"* ]] || return 1
    [[ "$output" != *"purge_shared.sh"* ]] || return 1
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
[[ $PURGE_DISCOVERY_STATUS -eq 124 ]] || exit 1
[[ "${PURGE_SEARCH_PATHS[*]}" == *"$HOME/Alpha"* ]] || exit 1
[[ ! -e "$PURGE_CONFIG_FILE" ]]
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"discovery was incomplete"* ]] || return 1
}
