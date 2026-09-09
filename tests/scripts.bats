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
    export TERM="dumb"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME"
}

@test "check.sh --help shows usage information" {
    run "$PROJECT_ROOT/scripts/check.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || return 1
    [[ "$output" == *"--format"* ]] || return 1
    [[ "$output" == *"--no-format"* ]]
}

@test "check.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/check.sh" ]
    [ -x "$PROJECT_ROOT/scripts/check.sh" ]

    run /bin/bash -c "grep -q 'Mole Check' '$PROJECT_ROOT/scripts/check.sh'"
	[ "$status" -eq 0 ]
}

@test "check workflow pins the shfmt version" {
	local workflow="$PROJECT_ROOT/.github/workflows/check.yml"

	run grep -F "go install mvdan.cc/sh/v3/cmd/shfmt@v3.13.1" "$workflow"
	[ "$status" -eq 0 ] || return 1

	run grep -E "brew install .*shfmt" "$workflow"
	[ "$status" -ne 0 ] || return 1
}

@test "check workflow pins goimports to the project Go toolchain" {
	run grep -F 'golang.org/x/tools/cmd/goimports@v0.49.0' \
		"$PROJECT_ROOT/.github/workflows/check.yml"
	[ "$status" -eq 0 ]
	run grep -F 'golang.org/x/tools/cmd/goimports@latest' \
		"$PROJECT_ROOT/.github/workflows/check.yml"
	[ "$status" -ne 0 ]
}

@test "diagnostic guidance check rejects equivalent pipe-to-shell spellings across lines" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^check_diagnostic_guidance()/,/^}/p' "$PROJECT_ROOT/scripts/check.sh")"

safe="$HOME/safe-guidance.md"
cat > "$safe" <<'SAFE'
Download `Mole-Diagnose.command` with `curl -o`, inspect it, then open it manually.
SAFE
check_diagnostic_guidance "$safe"

assert_unsafe() {
	local name="$1"
	local guidance="$2"
	local unsafe="$HOME/unsafe-${name}.md"
	printf '%s\n' "$guidance" > "$unsafe"
	if check_diagnostic_guidance "$unsafe"; then
		echo "UNEXPECTED_UNSAFE_PASS:$name"
		exit 1
	fi
}

assert_unsafe path '`curl https://example.test/Mole-Diagnose.command | /bin/bash`'
assert_unsafe command '`curl https://example.test/Mole-Diagnose.command | command bash`'
assert_unsafe sudo '`curl https://example.test/Mole-Diagnose.command | sudo -u root bash`'
assert_unsafe env $'`curl https://example.test/Mole-Diagnose.command \\\n  | env MODE=1 zsh`'
assert_unsafe tee $'`curl https://example.test/Mole-Diagnose.command |\n  tee /tmp/diagnose | dash`'
assert_unsafe quoted "\`curl https://example.test/Mole-Diagnose.command | 'bash'\`"
assert_unsafe ansi_c "\`curl https://example.test/Mole-Diagnose.command | \$'bash'\`"
assert_unsafe ksh '`curl https://example.test/Mole-Diagnose.command | ksh`'
assert_unsafe escaped '`curl https://example.test/Mole-Diagnose.command | ba\sh`'
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"UNEXPECTED_UNSAFE_PASS:"* ]]
}

@test "test.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/test.sh" ]
    [ -x "$PROJECT_ROOT/scripts/test.sh" ]

    run /bin/bash -c "grep -q 'Mole Test Runner' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "test.sh includes test lint step" {
    run /bin/bash -c "grep -q 'Test script lint' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "destructive sink audit catches recursive rm variants and find delete" {
    local audit="$PROJECT_ROOT/scripts/audit_destructive_sinks.py"
    [ -x "$audit" ]

    local safe_fixture="$HOME/destructive-safe.sh"
    local unsafe_fixture="$HOME/destructive-unsafe.sh"
    cat > "$safe_fixture" <<'EOF'
rm -rf "$scratch" # SAFE: exact test scratch directory
/bin/rm -r -f "$scratch" # SAFE: exact test scratch directory
find "$scratch" -delete # SAFE: exact test scratch directory
echo "rm -rf appears only in guidance"
printf '%s\n' 'find example -delete'
EOF
    cat > "$unsafe_fixture" <<'EOF'
command rm -fr "$target"
sudo -n /bin/rm -r -f "$target"
find "$target" -depth -delete
echo "starting"; rm -rf "$target"
printf 'starting' && find "$target" -delete
rm "$target" -Rf
rm --recursive --force "$target"
find "$target" -delete; echo done
printf '%s\0' "$target" | xargs -0 rm -rf
echo "$(rm -rf "$target")"
command r\m -rf "$target"
# A comment ending in a backslash does not continue onto the next shell line. \
rm -rf "$target"
EOF

    run python3 "$audit" "$safe_fixture"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"destructive-sink-audit-ok"* ]] || return 1

    run python3 "$audit" "$unsafe_fixture"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$unsafe_fixture:1:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:2:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:3:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:4:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:5:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:6:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:7:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:8:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:9:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:10:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:11:"* ]] || return 1
    [[ "$output" == *"$unsafe_fixture:13:"* ]] || return 1
    [[ "$output" == *"# SAFE:"* ]] || return 1
}

@test "CI and local checks share the destructive sink audit" {
    run grep -F 'audit_destructive_sinks.py' "$PROJECT_ROOT/scripts/check.sh"
    [ "$status" -eq 0 ]
    run grep -F 'scripts/audit_destructive_sinks.py' "$PROJECT_ROOT/.github/workflows/test.yml"
    [ "$status" -eq 0 ]
}

@test "Makefile has build target for Go binaries" {
    run /bin/bash -c "grep -Eq '(^|[[:space:]])(go|\\$\\(GO\\))[[:space:]]+build' '$PROJECT_ROOT/Makefile'"
    [ "$status" -eq 0 ]
}

@test "release builds disable cgo and check minimum macOS version" {
    run /bin/bash -c "grep -q '^RELEASE_GO_ENV := CGO_ENABLED=0$' '$PROJECT_ROOT/Makefile'"
    [ "$status" -eq 0 ]
    run /bin/bash -c "grep -q 'scripts/check_release_minos.sh' '$PROJECT_ROOT/.github/workflows/release.yml'"
    [ "$status" -eq 0 ]
    [ -x "$PROJECT_ROOT/scripts/check_release_minos.sh" ]
    run grep -F 'MAX_RELEASE_MINOS:-12.0' "$PROJECT_ROOT/scripts/check_release_minos.sh"
    [ "$status" -eq 0 ]
}

@test "contributor requirements match the release and Go toolchains" {
    local go_version
    go_version=$(awk '$1 == "go" { print $2; exit }' "$PROJECT_ROOT/go.mod")
    local go_major_minor="${go_version%.*}"
    local release_minos
    release_minos=$(sed -n 's/.*MAX_RELEASE_MINOS:-\([^}]*\).*/\1/p' \
        "$PROJECT_ROOT/scripts/check_release_minos.sh" | head -1)
    local macos_major="${release_minos%%.*}"

    [[ "$go_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$release_minos" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    for requirements_doc in "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/CONTRIBUTING.md"; do
        run grep -F "macOS $macos_major or newer" "$requirements_doc"
        [ "$status" -eq 0 ]
    done
    run grep -F "Go $go_major_minor+" "$PROJECT_ROOT/CONTRIBUTING.md"
    [ "$status" -eq 0 ]
}

@test "release minos gate accepts 12.0 and rejects a newer deployment target" {
    local fake_bin="$HOME/minos-bin"
    local fake_binary="$HOME/analyze-darwin-arm64"
    mkdir -p "$fake_bin"
    touch "$fake_binary"
    cat > "$fake_bin/otool" <<'EOF'
#!/bin/bash
printf '      cmd LC_BUILD_VERSION\n'
printf '    minos %s\n' "$FAKE_MINOS"
EOF
    chmod +x "$fake_bin/otool"

    run env PATH="$fake_bin:$PATH" FAKE_MINOS=12.0 \
        "$PROJECT_ROOT/scripts/check_release_minos.sh" "$fake_binary"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"minos 12.0 <= 12.0"* ]] || return 1

    run env PATH="$fake_bin:$PATH" FAKE_MINOS=12.1 \
        "$PROJECT_ROOT/scripts/check_release_minos.sh" "$fake_binary"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"minos 12.1 exceeds allowed 12.0"* ]] || return 1
}

@test "release workflow rejects a tag that differs from the source version" {
    local workflow="$PROJECT_ROOT/.github/workflows/release.yml"

    run grep -F 'name: Verify release tag matches source version' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "SOURCE_VERSION=\$(sed -n" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "EXPECTED_TAG=\"V\${SOURCE_VERSION}\"" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "\"\$RELEASE_TAG\" != \"\$EXPECTED_TAG\"" "$workflow"
    [ "$status" -eq 0 ]
}

@test "release workflow keeps the Homebrew Core PR open (#1209)" {
    local workflow="$PROJECT_ROOT/.github/workflows/release.yml"

    run grep -F "Have you followed the [guidelines for contributing]" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "pulls?state=all&head=tw93:" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'PR_STATE" != "open"' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'core_status=published' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'core_status=pr-open' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'url_matches != 1 || sha_matches != 1' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'already exists; refusing to overwrite it.' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "git push \"--force-with-lease=refs/heads/\${BRANCH}:\" origin \"\$BRANCH\"" "$workflow"
    [ "$status" -eq 0 ]

    run awk '
        /name: Update Homebrew formula \(Official Core\)/ { in_step = 1 }
        in_step && /continue-on-error:/ { found = 1 }
        in_step && /name: Verify formula updates/ { exit found ? 1 : 0 }
        END { if (!in_step) exit 1 }
    ' "$workflow"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh has detect_mo function" {
    run /bin/bash -c "grep -q 'detect_mo()' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh has Raycast script generation" {
    run /bin/bash -c "grep -q 'create_raycast_commands' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
    [ "$status" -eq 0 ]
    run /bin/bash -c "grep -q 'write_raycast_script' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
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
    [[ "$output" == *"Raycast: Mole Clean | Alfred keyword: clean"* ]] || return 1
    [[ "$output" == *"Raycast: Mole Status | Alfred keyword: status"* ]] || return 1

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
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^source_archive_url()/,/^}/p' "$PROJECT_ROOT/install.sh")"
[[ "$(source_archive_url dev "")" == "https://github.com/tw93/mole/archive/refs/heads/dev.tar.gz" ]]
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run /bin/bash -c "grep -q 'MOLE_VERSION=\"dev\"' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "release workflow keeps Homebrew distribution on official core only" {
    run grep -q 'update-homebrew-core:' "$PROJECT_ROOT/.github/workflows/release.yml"
    [ "$status" -eq 0 ]

    run grep -Eq 'update-personal-tap:|tw93/homebrew-tap|PAT_TOKEN' "$PROJECT_ROOT/.github/workflows/release.yml"
    [ "$status" -ne 0 ]

    [ ! -e "$PROJECT_ROOT/scripts/update_homebrew_tap_formula.sh" ]

    run grep -Eq 'Homebrew tap|personal tap' "$PROJECT_ROOT/.claude/skills/release-notes/SKILL.md"
    [ "$status" -ne 0 ]
    run grep -q 'Homebrew Core PR is workflow-driven' "$PROJECT_ROOT/.claude/skills/release-notes/SKILL.md"
    [ "$status" -eq 0 ]
}

@test "no shell function shares another's body under a different name" {
    # This gate also lives in check.sh, but CI runs scripts/test.sh and never
    # check.sh, so without this case it could not block a pull request. The
    # class it catches is invisible to grep: the copies that matter have
    # already had their variables renamed, which is why review reads them as
    # separate helpers. Run the script with --list to inspect every group.
    run python3 "$PROJECT_ROOT/scripts/audit_function_duplication.py"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}
