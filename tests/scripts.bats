#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-scripts-home.XXXXXX")"
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
    export TERM="dumb"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME"
}

@test "check.sh --help shows usage information" {
    run "$PROJECT_ROOT/scripts/check.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"--format"* ]]
    [[ "$output" == *"--no-format"* ]]
}

@test "check.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/check.sh" ]
    [ -x "$PROJECT_ROOT/scripts/check.sh" ]

    run bash -c "grep -q 'Mole Check' '$PROJECT_ROOT/scripts/check.sh'"
    [ "$status" -eq 0 ]
}

@test "test.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/test.sh" ]
    [ -x "$PROJECT_ROOT/scripts/test.sh" ]

    run bash -c "grep -q 'Mole Test Runner' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "test.sh includes test lint step" {
    run bash -c "grep -q 'Test script lint' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "Makefile has build target for Go binaries" {
    run bash -c "grep -q 'go build' '$PROJECT_ROOT/Makefile'"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh has detect_mo function" {
    run bash -c "grep -q 'detect_mo()' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh has Raycast script generation" {
    run bash -c "grep -q 'create_raycast_commands' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
    [ "$status" -eq 0 ]
    run bash -c "grep -q 'write_raycast_script' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh generates Raycast scripts with discoverable metadata" {
    local fake_bin="$HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/mo" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/mo"

    run env HOME="$HOME" TERM="dumb" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
    [ "$status" -eq 0 ]

    local raycast_dir="$HOME/Library/Application Support/Raycast/script-commands"
    [ -d "$raycast_dir" ]

    local clean_script="$raycast_dir/mole-clean.sh"
    local uninstall_script="$raycast_dir/mole-uninstall.sh"
    local optimize_script="$raycast_dir/mole-optimize.sh"
    local analyze_script="$raycast_dir/mole-analyze.sh"
    local status_script="$raycast_dir/mole-status.sh"

    [ -x "$clean_script" ]
    [ -x "$uninstall_script" ]
    [ -x "$optimize_script" ]
    [ -x "$analyze_script" ]
    [ -x "$status_script" ]

    run grep -q '^# @raycast.title Mole Clean$' "$clean_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Mole Uninstall$' "$uninstall_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Mole Optimize$' "$optimize_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Mole Analyze$' "$analyze_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Mole Status$' "$status_script"
    [ "$status" -eq 0 ]

    run grep -q '^# @raycast.description Deep system cleanup with Mole$' "$clean_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description Uninstall applications with Mole$' "$uninstall_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description System health checks and optimization$' "$optimize_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description Disk space analysis with Mole$' "$analyze_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description Live system status dashboard$' "$status_script"
    [ "$status" -eq 0 ]
}

@test "install.sh supports dev branch installs" {
    run bash -c "grep -q 'refs/heads/dev.tar.gz' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
    run bash -c "grep -q 'MOLE_VERSION=\"dev\"' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}
