#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home scripts-home
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

@test "diagnostic placement check keeps the support-only script off public surfaces" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(awk '/^check_diagnostic_placement\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$PROJECT_ROOT/scripts/check.sh")"

clean="$HOME/public-clean.md"
printf 'Run `mo status --json` and paste the output.\n' > "$clean"
check_diagnostic_placement "$clean" || { echo "UNEXPECTED_CLEAN_FAIL"; exit 1; }

leaked="$HOME/public-leaked.yml"
printf 'intro\nrun curl -fsSL https://mole.fit/downloads/Mole-Diagnose.command | bash\n' > "$leaked"
if check_diagnostic_placement "$clean" "$leaked"; then
	echo "UNEXPECTED_LEAK_PASS"
	exit 1
fi
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"public-leaked.yml:2:"*"support-only diagnostic script on a public surface"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"public-clean.md"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"UNEXPECTED"* ]]
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

@test "bats assertion audit catches negated assertions that cannot fail" {
    local audit="$PROJECT_ROOT/scripts/audit_bats_assertions.py"
    local live_fixture="$HOME/negation-live.bats"
    local vacuous_fixture="$HOME/negation-vacuous.bats"
    # Bats would read a literal test header here as a test of this file.
    sed 's/^TEST /@test /' > "$live_fixture" <<'BATS'
TEST "negations that can still fail" {
    ! grep -q gone "$trace" || return 1
    run /bin/bash -c "
        source lib.sh
        ! is_protected /tmp/x
    "
    cat > "$HOME/mock" <<'EOF'
! grep -q data "$file"
echo done
EOF
    run env HOME="$HOME" /bin/bash --noprofile --norc <<'EOF'
stub() {
    ! true
    :
}
! grep -q gone "$trace" || exit 1
! grep -q gone "$trace"
EOF
    ! grep -q gone "$trace"
}
BATS
    sed 's/^TEST /@test /' > "$vacuous_fixture" <<'BATS'
TEST "negations that never fail" {
    ! grep -q gone "$trace"
    run env HOME="$HOME" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
! grep -q gone "$trace"
[[ -f "$trace" ]]
EOF
    [ "$status" -eq 0 ]
}
BATS

    run python3 "$audit" "$live_fixture"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"bats-assertion-audit-ok"* ]] || return 1

    run python3 "$audit" "$vacuous_fixture"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$vacuous_fixture:2:"* ]] || return 1
    [[ "$output" == *"$vacuous_fixture:5:"* ]] || return 1
    [[ "$(grep -c "bare '! cmd'" <<< "$output")" -eq 2 ]] || { echo "$output"; return 1; }
}

@test "bats assertion audit catches bare brackets and arithmetic in test and heredoc bodies" {
    local audit="$PROJECT_ROOT/scripts/audit_bats_assertions.py"
    local live_fixture="$BATS_TEST_TMPDIR/bracket-live.bats"
    local vacuous_fixture="$BATS_TEST_TMPDIR/bracket-vacuous.bats"
    # Bats would read a literal test header here as a test of this file.
    sed 's/^TEST /@test /' > "$live_fixture" <<'BATS'
TEST "assertions that can still fail" {
    [[ -f "$trace" ]] || return 1
    (( count++ ))
    (( bits <<= 1 ))
    (( bits >>= 1 ))
    (( elapsed < 5 )) || return 1
    run env HOME="$HOME" /bin/bash --noprofile --norc <<'EOF'
stub() {
    [[ -f "$mock" ]]
    :
}
(( n += 1 ))
[[ -f "$trace" ]] || exit 1
(( total > 3 )) || exit 1
[[ -f "$last" ]]
EOF
    cat > "$HOME/data" <<'EOF'
[[ -f "$data" ]]
:
EOF
    (( elapsed < 5 ))
}
BATS
    sed 's/^TEST /@test /' > "$vacuous_fixture" <<'BATS'
TEST "assertions that never fail" {
    [[ -f "$trace" ]]
    (( elapsed < 5 ))
    run env HOME="$HOME" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
[[ -f "$trace" ]]
(( total > 3 ))
:
EOF
    [ "$status" -eq 0 ]
}
BATS

    # Positive control: the guarded forms, a mock body, a data heredoc and a
    # computation without a comparison are all accepted.
    run python3 "$audit" "$live_fixture"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"bats-assertion-audit-ok"* ]] || return 1

    run python3 "$audit" "$vacuous_fixture"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    local line
    for line in 2 3 6 7; do
        [[ "$output" == *"$vacuous_fixture:$line:"* ]] || { echo "line $line not flagged"; echo "$output"; return 1; }
    done
    [[ "$(grep -c "bare \[\[ \]\]" <<< "$output")" -eq 2 ]] || { echo "$output"; return 1; }
    [[ "$(grep -c "bare (( ))" <<< "$output")" -eq 2 ]] || { echo "$output"; return 1; }
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
mole_source_installer
[[ "$(source_archive_url dev "")" == "https://github.com/tw93/mole/archive/refs/heads/dev.tar.gz" ]]
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run /bin/bash -c "grep -q 'MOLE_VERSION=\"dev\"' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "release gate inherits path-filtered workflows only through skippable commits" {
    command -v python3 > /dev/null 2>&1 || skip "python3 not available"
    run grep -F 'run: python3 scripts/release_workflow_gate.py' "$PROJECT_ROOT/.github/workflows/release.yml"
    [ "$status" -eq 0 ]
    run env PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_ROOT/tests/release_gate_test.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Validation serial shard lists exactly the files test.sh runs sequentially" {
    command -v python3 > /dev/null 2>&1 || skip "python3 not available"
    run python3 - "$PROJECT_ROOT" <<'EOF'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
workflow = (root / ".github/workflows/test.yml").read_text()
runner = (root / "scripts/test.sh").read_text()
serial = re.findall(r"^\s+SERIAL: (.+)$", workflow, re.M)
patterns = re.findall(r"^\s+(\*core_performance\.bats .*)\) _sequential_files\+=", runner, re.M)
if len(serial) != 1 or len(patterns) != 2 or len(set(patterns)) != 1:
    sys.exit(f"expected one SERIAL line and two identical case lines, got {serial!r} {patterns!r}")
want = {p.strip().lstrip("*").removesuffix(".bats") for p in patterns[0].split("|")}
got = set(serial[0].split())
if want != got:
    sys.exit(f"test.sh sequential files {sorted(want)} != workflow SERIAL {sorted(got)}")
missing = sorted(n for n in got if not (root / "tests" / f"{n}.bats").is_file())
if missing:
    sys.exit(f"SERIAL names missing test files: {missing}")
# test.sh matches by suffix (*cli.bats); the workflow by exact name.
shadowed = sorted(f.name for f in (root / "tests").glob("*.bats")
                  if f.stem not in got and any(f.name.endswith(f"{n}.bats") for n in got))
if shadowed:
    sys.exit(f"test.sh runs these sequentially but SERIAL misses them: {shadowed}")
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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

@test "test runner only passes parallel flags for multiple jobs" {
    local options_script="$HOME/bats-options.sh"
    # Exercise the actual option-selection block without starting another
    # full test runner. Both anchors must exist exactly once.
    python3 - "$PROJECT_ROOT/scripts/test.sh" "$options_script" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = '\n    bats_help="$(bats --help 2>&1 || true)"'
end = '\n    if [[ "${MOLE_TEST_TIMING:-0}" == "1" ]]; then'
assert source.count(start) == source.count(end) == 1
Path(sys.argv[2]).write_text(start + source.split(start, 1)[1].split(end, 1)[0])
PYTHON
    local jobs
    for jobs in 1 2; do
        run env MOLE_TEST_JOBS="$jobs" OPTIONS_SCRIPT="$options_script" \
            /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
bats() { printf '%s\n' '--jobs --formatter'; }
parallel() { :; }
sysctl() { echo 4; }
source "$OPTIONS_SCRIPT"
printf 'COUNT=%s\n' "${#bats_opts[@]}"
if [[ ${#bats_opts[@]} -gt 0 ]]; then
    printf 'ARG=%s\n' "${bats_opts[@]}"
fi
SCRIPT
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        if [[ "$jobs" == 1 ]]; then
            [[ "$output" == 'COUNT=0' ]] || { echo "$output"; return 1; }
        else
            [[ "$output" == $'COUNT=3\nARG=--jobs\nARG=2\nARG=--no-parallelize-within-files' ]] || { echo "$output"; return 1; }
        fi
    done
}

@test "skill command audit rejects commands and flags the CLI does not have" {
    local audit="$PROJECT_ROOT/scripts/audit_skill_commands.py"
    local skill="$BATS_TEST_TMPDIR/skill"
    mkdir -p "$skill/references"
    cat > "$skill/SKILL.md" <<'EOF'
---
name: mole
description: "Short."
when_to_use: "short"
---
Run `mo clean --dry-run`, then `mo status --json`.
EOF
    cat > "$skill/references/macos.md" <<'EOF'
```bash
brew install mole
mo history --json --limit 5   # recent runs
mo analyze --json ~/Library
```
EOF
    printf 'Windows notes without commands.\n' > "$skill/references/windows.md"

    run python3 "$audit" --skill-dir "$skill" --windows-ref refs/heads/mole-audit-missing-ref
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Windows side skipped"* ]] || return 1
    [[ "$output" == *"skill-commands-audit-ok (4 command checks)"* ]] || { echo "$output"; return 1; }

    run python3 "$audit" --skill-dir "$skill" --windows-ref refs/heads/mole-audit-missing-ref --require-windows
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }

    cat >> "$skill/references/macos.md" <<'EOF'
Then `mo clean --yes` or `mo frobnicate`.
EOF
    run python3 "$audit" --skill-dir "$skill" --windows-ref refs/heads/mole-audit-missing-ref
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"macos.md:6: \`mo clean --yes\` is not in the macOS source"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"macos.md:6: \`mo frobnicate\` is not a macOS command"* ]] || { echo "$output"; return 1; }
}

@test "skill command audit rejects a Codex plugin copy that drifted from the skill" {
    local audit="$PROJECT_ROOT/scripts/audit_skill_commands.py"
    local skill="$BATS_TEST_TMPDIR/skill"
    local copy="$BATS_TEST_TMPDIR/copy"
    mkdir -p "$skill/references"
    cat > "$skill/SKILL.md" <<'EOF'
---
name: mole
description: "Short."
when_to_use: "short"
---
Run `mo clean --dry-run`.
EOF
    : > "$skill/references/macos.md"
    : > "$skill/references/windows.md"
    cp -R "$skill" "$copy"

    run python3 "$audit" --skill-dir "$skill" --plugin-copy "$copy" --windows-ref refs/heads/mole-audit-missing-ref
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    printf 'stale\n' > "$copy/references/macos.md"
    run python3 "$audit" --skill-dir "$skill" --plugin-copy "$copy" --windows-ref refs/heads/mole-audit-missing-ref
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$copy/references/macos.md: differs from $skill"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"fix with: rm -rf $copy && cp -R $skill $copy"* ]] || { echo "$output"; return 1; }
}

@test "skill command audit rejects a description DeepSeek Harness would cut off" {
    local audit="$PROJECT_ROOT/scripts/audit_skill_commands.py"
    local skill="$BATS_TEST_TMPDIR/skill"
    mkdir -p "$skill/references"
    : > "$skill/references/macos.md"
    : > "$skill/references/windows.md"
    local long
    long=$(printf 'x%.0s' {1..300})
    local body="$BATS_TEST_TMPDIR/body.md"
    cat > "$body" <<'EOF'
Run `mo clean --dry-run`.
EOF
    { printf -- '---\nname: mole\ndescription: "%s"\nwhen_to_use: "%s"\n---\n' "$long" "$long"; cat "$body"; } > "$skill/SKILL.md"

    run python3 "$audit" --skill-dir "$skill" --plugin-copy "$skill" --windows-ref refs/heads/mole-audit-missing-ref
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"join to 611 characters, over 500"* ]] || { echo "$output"; return 1; }

    { printf -- '---\nname: mole\ndescription: "%s"\nwhen_to_use: "short"\n---\n' "$long"; cat "$body"; } > "$skill/SKILL.md"
    run python3 "$audit" --skill-dir "$skill" --plugin-copy "$skill" --windows-ref refs/heads/mole-audit-missing-ref
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "CI checks the published skill against both CLIs" {
    run grep -F 'audit_skill_commands.py' "$PROJECT_ROOT/scripts/check.sh"
    [ "$status" -eq 0 ]
    run grep -F 'git fetch --no-tags --depth=1 origin windows' "$PROJECT_ROOT/.github/workflows/check.yml"
    [ "$status" -eq 0 ]
}

@test "test runner isolates module-loading temp state before sourcing core" {
    local bootstrap="$HOME/runner-bootstrap.sh"
    # Execute the complete real bootstrap; redirect only its repository path to
    # a fixture so its orphan-test sweep cannot touch another test's HOME.
    python3 - "$PROJECT_ROOT/scripts/test.sh" "$bootstrap" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
end = '\necho "==============================="\necho "Mole Test Runner"'
anchor = 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
assert source.count(end) == source.count(anchor) == 1
prefix = source.split(end, 1)[0]
prefix = prefix.replace(anchor, 'SCRIPT_DIR="$FIXTURE_REPO/scripts"')
Path(sys.argv[2]).write_text(prefix)
PYTHON
    run env BOOTSTRAP="$bootstrap" SOURCE_REPO="$PROJECT_ROOT" \
        FIXTURE_REPO="$BATS_TEST_TMPDIR/repo" HOME="$BATS_TEST_TMPDIR/runner-home" \
        TMPDIR="$BATS_TEST_TMPDIR/ambient-link" MOLE_RESOLVED_TMPDIR="$BATS_TEST_TMPDIR/ambient" \
        MOLE_TEMP_REGISTRY_FILE="$BATS_TEST_TMPDIR/ambient/mole.registry.parent" /bin/bash <<'SCRIPT'
set -euo pipefail
mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/tests" "$HOME" "${TMPDIR%-link}"
ln -s "${TMPDIR%-link}" "$TMPDIR"
ln -s "$SOURCE_REPO/lib" "$FIXTURE_REPO/lib"
ambient="$TMPDIR"
printf keep > "$MOLE_TEMP_REGISTRY_FILE"
source "$BOOTSTRAP"
# This is the runner's real module-loading consumer, outside the Bats helper.
source "$PROJECT_ROOT/lib/core/common.sh"
test_file=$(create_temp_file)
# Shell and canonicalizing consumers must see the same root (including /var).
[[ "$TMPDIR" == "$(cd -P "$TMPDIR" && pwd -P)" ]] || exit 1
[[ "$TMPDIR" == "$TEST_SYSTEM_STUB_DIR/tmp" ]] || exit 1
[[ "$test_file" == "$TMPDIR/"* && -f "$test_file" ]] || exit 1
[[ "$(cat "$ambient/mole.registry.parent")" == keep ]] || exit 1
printf 'PASS\n'
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *PASS* ]]
}

incident_ledger() {
    printf '## Incidents\n\n| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |\n|---|---|---|---|---|---|---|\n%s\n' "$1" > "$BATS_TEST_TMPDIR/incidents.md"
}

@test "incident audit names each broken cell of a ledger row" {
    local audit="$PROJECT_ROOT/scripts/audit_incidents.py"
    local head good row expected
    head=$(git -C "$PROJECT_ROOT" rev-parse --short=8 HEAD)
    good="| I-01 | 2026-10-26 | A defect | unknown | $head | unit | \`check.sh --help shows usage information\` |"

    incident_ledger "$good"
    run python3 "$audit" --ledger "$BATS_TEST_TMPDIR/incidents.md"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"incidents-audit-ok rows=1"* ]] || { echo "$output"; return 1; }

    local -a cases=(
        "layer nightly is not one of=${good/| unit |/| nightly |}"
        "is not a test or gate=${good/usage information/usage informatio}"
        "no catcher named=${good/\`check.sh --help shows usage information\`/a test}"
        "Fixed is not a commit=${good/$head/later}"
        "Introduced is not a commit=${good/unknown/soon}"
        "Reported is not a date=${good/2026-10-26/Oct 26}"
        "I-01 repeats=$good"$'\n'"$good"
        "expected 7 cells=${good/ unit |/}"
    )
    local case_entry
    for case_entry in "${cases[@]}"; do
        expected="${case_entry%%=*}"
        row="${case_entry#*=}"
        incident_ledger "$row"
        run python3 "$audit" --ledger "$BATS_TEST_TMPDIR/incidents.md"
        [ "$status" -eq 1 ] || { echo "$expected: $output"; return 1; }
        [[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]] || { echo "$expected: $output"; return 1; }
        [[ "$output" == *"$expected"* ]] || { echo "$expected: $output"; return 1; }
    done
}

@test "incident audit finds Bats, Go and Python tests and gate scripts as catchers" {
    local audit="$PROJECT_ROOT/scripts/audit_incidents.py"
    local head catchers
    head=$(git -C "$PROJECT_ROOT" rev-parse --short=8 HEAD)
    catchers="\`check.sh --help shows usage information\`, \`TestDuIgnoresUseSystemDuWhenGNUDuIsFirstInPath\`, \`test_default_stops_after_first_failure\`, \`scripts/audit_timeout_status.py\`"

    incident_ledger "| I-01 | 2026-10-26 | A defect | $head | $head | review | $catchers |"
    run python3 "$audit" --ledger "$BATS_TEST_TMPDIR/incidents.md"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    incident_ledger "| I-01 | 2026-10-26 | A defect | unknown | $head | review | \`TestNoSuchCatcher\`, \`scripts/audit_no_such_gate.py\` |"
    run python3 "$audit" --ledger "$BATS_TEST_TMPDIR/incidents.md"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"\`TestNoSuchCatcher\` is not a test or gate"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"\`scripts/audit_no_such_gate.py\` is not a test or gate"* ]] || { echo "$output"; return 1; }
}

@test "incident audit fails a commit that does not resolve" {
    if [[ "$(git -C "$PROJECT_ROOT" rev-parse --is-shallow-repository)" == "true" ]]; then
        skip "commits cannot be resolved in a shallow clone"
    fi
    incident_ledger "| I-01 | 2026-10-26 | A defect | unknown | 0000000 | unit | \`check.sh --help shows usage information\` |"
    run python3 "$PROJECT_ROOT/scripts/audit_incidents.py" --ledger "$BATS_TEST_TMPDIR/incidents.md"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"incidents.md:5: Fixed 0000000 does not resolve"* ]] || { echo "$output"; return 1; }
}

@test "the incident ledger passes its audit" {
    run python3 "$PROJECT_ROOT/scripts/audit_incidents.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"incidents-audit-ok rows="* ]]
}

@test "risk tiers follow the paths a change touches, highest first" {
    local tiers="$PROJECT_ROOT/scripts/risk_tier.py"

    run python3 "$tiers" lib/core/file_ops.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "risk: deletion "*$'\n'"risk: privilege "* ]] || { echo "$output"; return 1; }

    run python3 "$tiers" .github/workflows/release.yml install.sh lib/manage/update.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "risk: release "*$'\n'"risk: ci "*$'\n'"risk: install-update (install.sh and 1 more) "* ]] || { echo "$output"; return 1; }

    run python3 "$tiers" docs/incidents.md .claude/rules/clean.md cmd/status/view.go tests/clean_core.bats
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -z "$output" ]
}

@test "every risk tier pattern matches a tracked file" {
    run python3 "$PROJECT_ROOT/scripts/risk_tier.py" --self-check
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # The self-check must be able to fail: a pattern left behind by a rename.
    run env PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT_ROOT/scripts" <<'PYTHON'
import sys
sys.path.insert(0, sys.argv[1])
import risk_tier
risk_tier.TIERS.append(("deletion", "gates", ["lib/core/renamed_away.sh"]))
print(risk_tier.dead_patterns())
PYTHON
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "['deletion: lib/core/renamed_away.sh']" ]] || { echo "$output"; return 1; }
}

@test "the incident breaker trips at five recent rows and shows only beside a tier" {
    run env PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT_ROOT/scripts" <<'PYTHON'
import datetime
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, sys.argv[1])
import risk_tier as risk


class BreakerTests(unittest.TestCase):
    """The incident circuit breaker in risk_tier.py: counted by Reported date, shown only beside a tier."""

    TODAY = datetime.date(2026, 10, 27)

    def ledger(self, dates_and_layers):
        rows = "\n".join(f"| I-{n:02d} | {day} | symptom | unknown | abc1234 | {layer} | `t` |"
                         for n, (day, layer) in enumerate(dates_and_layers, 1))
        text = ("# Incidents\n\n| ID | Reported | Symptom |\n|---|---|---|\n| X-01 | 2026-10-27 | outside |\n\n"
                "## Incidents\n\n| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |\n"
                f"|---|---|---|---|---|---|---|\n{rows}\n")
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "incidents.md"
        path.write_text(text, "utf-8")
        return path

    def recent(self, dates_and_layers):
        return risk.recent_incidents(today=self.TODAY, ledger=self.ledger(dates_and_layers))

    def test_only_rows_reported_in_the_last_seven_days_count(self):
        recent = self.recent([("2026-10-27", "unit"), ("2026-10-21", "unit"), ("2026-10-20", "unit"),
                              ("2026-10-28", "unit")])
        # Day 0 and day 6 count; day 7 has aged out; a future date (a clock set back) is never counted.
        self.assertEqual(["I-01", "I-02"], [ident for ident, _ in recent])

    def test_it_trips_at_five_rows_and_names_the_layers_by_count(self):
        self.assertIsNone(risk.breaker_line(self.recent([("2026-10-26", "unit")] * 4)))
        line = risk.breaker_line(self.recent([("2026-10-26", "review")] * 3 + [("2026-10-25", "unit")] * 2))
        self.assertIn("5 incidents in the last 7 days", line)
        self.assertIn(risk.BREAKER_GATE, line)
        self.assertTrue(line.endswith("(review 3, unit 2)"), line)

    def test_a_missing_ledger_never_trips_it(self):
        self.assertEqual([], risk.recent_incidents(today=self.TODAY, ledger=Path("/nonexistent/incidents.md")))

    def test_it_is_printed_only_beside_a_tier(self):
        tripped = [("I-01", "unit")] * risk.BREAKER_ROWS
        tiered = next(p for _, _, patterns in risk.TIERS for p in patterns if "*" not in p)
        for paths, shown in ((["zz-untiered/none.txt"], False), ([tiered], True)):
            with self.subTest(paths=paths), \
                    mock.patch.object(risk, "recent_incidents", return_value=tripped), \
                    mock.patch.object(sys, "argv", ["risk_tier.py", *paths]), \
                    redirect_stdout(io.StringIO()) as out:
                risk.main(paths) if risk.main.__code__.co_argcount else risk.main()
                self.assertEqual(shown, "risk: breaker" in out.getvalue(), out.getvalue())


result = unittest.TextTestRunner(stream=sys.stdout, verbosity=0).run(
    unittest.defaultTestLoader.loadTestsFromTestCase(BreakerTests))
sys.exit(0 if result.wasSuccessful() and result.testsRun == 4 else 1)
PYTHON
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "CI and local checks run the incident audit and the risk tiers" {
    run grep -F 'audit_incidents.py' "$PROJECT_ROOT/scripts/check.sh"
    [ "$status" -eq 0 ]
    run grep -F 'risk_tier.py' "$PROJECT_ROOT/scripts/check.sh"
    [ "$status" -eq 0 ]
    run grep -F 'python3 scripts/audit_incidents.py' "$PROJECT_ROOT/.github/workflows/test.yml"
    [ "$status" -eq 0 ]
}
