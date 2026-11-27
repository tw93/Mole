#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_project_root
    # Shell-looking HOME bytes must remain data when passed to the editor.
    # shellcheck disable=SC2089,SC2090  # Quotes and shell syntax are literal path bytes.
    HOME="$BATS_TEST_TMPDIR/home 'quoted' \$(touch editor-injection)"
    # shellcheck disable=SC2090  # HOME is a path, not an editor command.
    export HOME
    mkdir -p "$HOME/.config/mole" "$HOME/project"
    printf '%s\n' "$HOME/project" > "$HOME/.config/mole/purge_paths"
    export EDITOR_ARGV="$BATS_TEST_TMPDIR/editor-argv"
    # shellcheck disable=SC2016  # Variables expand inside the fake editor.
    mole_test_fake_command code 'printf '\''%s\n'\'' "$@" > "$EDITOR_ARGV"; exit "${EDITOR_STATUS:-0}"'
    cd "$BATS_TEST_TMPDIR" || return 1
}

@test "purge paths accepts editor commands with arguments and keeps the config path literal" {
    run env EDITOR="code --wait" VISUAL=/usr/bin/false MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    printf '%s\n' --wait "$HOME/.config/mole/purge_paths" > "$BATS_TEST_TMPDIR/expected"
    cmp "$BATS_TEST_TMPDIR/expected" "$EDITOR_ARGV" || return 1
    [[ "$output" == *"Configuration updated"* ]] || return 1
    [[ ! -e "$BATS_TEST_TMPDIR/editor-injection" ]]
}

@test "purge paths accepts quoted editor paths and arguments" {
    local editor="$BATS_TEST_TMPDIR/Editor App"
    cp "$BATS_TEST_TMPDIR/fake-bin/code" "$editor"
    run env EDITOR="\"$editor\" --label \"purge paths\"" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    printf '%s\n' --label "purge paths" "$HOME/.config/mole/purge_paths" > "$BATS_TEST_TMPDIR/expected"
    cmp "$BATS_TEST_TMPDIR/expected" "$EDITOR_ARGV"
}

@test "purge paths preserves a literal editor executable path with spaces" {
    local editor="$BATS_TEST_TMPDIR/Editor App"
    cp "$BATS_TEST_TMPDIR/fake-bin/code" "$editor"
    run env EDITOR="$editor" VISUAL=/usr/bin/false MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    printf '%s\n' "$HOME/.config/mole/purge_paths" > "$BATS_TEST_TMPDIR/expected"
    cmp "$BATS_TEST_TMPDIR/expected" "$EDITOR_ARGV"
}

@test "purge paths falls back to a VISUAL command when EDITOR is empty" {
    run env EDITOR= VISUAL="code --wait" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    printf '%s\n' --wait "$HOME/.config/mole/purge_paths" > "$BATS_TEST_TMPDIR/expected"
    cmp "$BATS_TEST_TMPDIR/expected" "$EDITOR_ARGV"
}

@test "purge paths returns editor failures without reporting a configuration update" {
    local editor
    for editor in code "code --wait"; do
        run env EDITOR="$editor" EDITOR_STATUS=23 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

        [ "$status" -eq 23 ] || return 1
        [ -s "$EDITOR_ARGV" ] || return 1
        [[ "$output" != *"Configuration updated"* ]] || return 1
    done
}

@test "purge paths abbreviates HOME only at a path boundary" {
    # Purge resolves configured paths physically; a real HOME is physical too,
    # while the bats temp dir may sit under the /var or /tmp links.
    HOME=$(cd "$HOME" && pwd -P)
    local sibling="${HOME}er/projects"
    mkdir -p "$sibling"
    printf '%s\n' "$HOME/project" "$sibling" > "$HOME/.config/mole/purge_paths"
    run env EDITOR=code MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    # shellcheck disable=SC2088  # literal tilde is the expected display form
    [[ "$output" == *"~/project"* ]] || return 1
    [[ "$output" == *"$sibling"* ]] || return 1
    [[ "$output" != *"~er/projects"* ]]
}

@test "purge paths highlights existing unconfigured default paths when using custom config" {
    mkdir -p "$HOME/.codex/worktrees" "$HOME/Projects"
    printf '%s\n' "$HOME/project" "$HOME/Projects" > "$HOME/.config/mole/purge_paths"
    run env EDITOR=code NO_COLOR=1 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Unconfigured Default Paths Found:"* ]] || return 1
    # shellcheck disable=SC2088  # literal tilde is the expected display form
    [[ "$output" == *"  + ~/.codex/worktrees"* ]] || return 1
    # shellcheck disable=SC2088  # literal tilde is the expected display form
    [[ "$output" != *"  + ~/Projects"* ]]
}

@test "purge paths omits unconfigured default paths notice when all existing defaults are configured" {
    mkdir -p "$HOME/.codex/worktrees"
    printf '%s\n' "$HOME/project" "$HOME/.codex/worktrees" > "$HOME/.config/mole/purge_paths"
    run env EDITOR=code MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" purge --paths

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"Unconfigured Default Paths Found:"* ]]
}
