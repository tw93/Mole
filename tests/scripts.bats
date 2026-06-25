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

current_roomy_version() {
    sed -n 's/^VERSION="\([0-9][0-9]*[.][0-9][0-9]*[.][0-9][0-9]*\)"$/\1/p' "$PROJECT_ROOT/roomy" | head -n 1
}

current_roomy_tag() {
    printf 'V%s\n' "$(current_roomy_version)"
}

write_passing_drill_results() {
    cat > "$1" <<'EOF'
release preflight	0
release version matches tag	0
go tests	0
shell and integration tests without API	0
API contract tests	0
brew update	0
brew install jake-seo-cl/tap/roomy	0
homebrew roomy version	0
homebrew clean dry-run	0
homebrew uninstall dry-run	0
homebrew purge dry-run	0
homebrew installer dry-run	0
homebrew optimize dry-run	0
homebrew status	0
homebrew analyze json	0
brew uninstall roomy after drill	0
download install script	0
download previous install script	0
script install target release	0
script roomy version	0
script clean dry-run	0
script uninstall dry-run	0
script update dry-run	0
script remove dry-run	0
script remove after drill	0
install previous stable for update drill	0
previous stable roomy version	0
update from previous stable with target installer	0
updated roomy version	0
remove dry-run after update	0
remove after update drill	0
reinstall through Homebrew after remove	0
homebrew reinstall version	0
cleanup Homebrew reinstall	0
EOF
}

file_sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

update_record_evidence_hashes() {
    local record="$1"
    local evidence_dir="$2"
    local transcript_sha
    local results_sha

    transcript_sha="$(file_sha256 "$evidence_dir/transcript.txt")"
    results_sha="$(file_sha256 "$evidence_dir/results.tsv")"
    sed -i.bak "s/^Transcript SHA-256: .*/Transcript SHA-256: ${transcript_sha}/" "$record"
    sed -i.bak "s/^Results SHA-256: .*/Results SHA-256: ${results_sha}/" "$record"
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

    run bash -c "grep -q 'Roomy Check' '$PROJECT_ROOT/scripts/check.sh'"
    [ "$status" -eq 0 ]
}

@test "test.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/test.sh" ]
    [ -x "$PROJECT_ROOT/scripts/test.sh" ]

    run bash -c "grep -q 'Roomy Test Runner' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "test.sh includes test lint step" {
    run bash -c "grep -q 'Test script lint' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]

    run grep -q "tests/tmp-\\*" "$PROJECT_ROOT/scripts/test.sh"
    [ "$status" -eq 0 ]
}

@test "clean-machine drill record verifier rejects template placeholders" {
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --record "$PROJECT_ROOT/docs/launch/clean-machine-cli-drill-record-template.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Release tag is missing or still a placeholder"* ]]
}

@test "clean-machine drill record verifier requires tag-specific go decision" {
    local record="$HOME/V9.9.9.md"
    local evidence_dir="$HOME/evidence"
    mkdir -p "$evidence_dir"
    printf 'clean-machine transcript\n' > "$evidence_dir/transcript.txt"
    write_passing_drill_results "$evidence_dir/results.tsv"
    cat > "$record" <<'EOF'
# Clean-Machine CLI Drill Record: V9.9.9

## Environment

Release tag: V9.9.9
Commit SHA: 0123456789abcdef0123456789abcdef01234567
Drill date: 2026-05-21
Tester: release-tester
macOS version: macOS 15.5 (24F74)
CPU architecture: arm64
Fresh environment: yes
Existing Roomy state: absent
Full Disk Access: available
Admin privileges: available
Network access: available

## Required Gate Results

Preflight: pass
Homebrew install: pass
Script install: pass
Checksum verification: pass
First-run dry-runs: pass
Update behavior: pass
Rollback/remove/reinstall: pass

## Evidence

Evidence location: EVIDENCE_DIR_PLACEHOLDER
Transcript SHA-256: pending
Results SHA-256: pending

## Launch Decision

Launch decision: go
Decision notes: All required gates passed in a clean VM.
EOF
    sed -i.bak "s#EVIDENCE_DIR_PLACEHOLDER#${evidence_dir}#" "$record"
    update_record_evidence_hashes "$record" "$evidence_dir"

    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Clean-machine drill record passed"* ]]

    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record" \
        --commit "0123456789abcdef0123456789abcdef01234567"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Clean-machine drill record passed"* ]]

    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record" \
        --commit "abcdef0123456789abcdef0123456789abcdef01"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Commit SHA must match expected commit"* ]]

    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.8" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Release tag must be 'V9.9.8'"* ]]

    sed -i.bak 's/Commit SHA: 0123456789abcdef0123456789abcdef01234567/Commit SHA: short-sha/' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Commit SHA must be a full 40-character lowercase hex SHA"* ]]
    sed -i.bak 's/Commit SHA: short-sha/Commit SHA: 0123456789abcdef0123456789abcdef01234567/' "$record"

    sed -i.bak 's/^Transcript SHA-256: .*/Transcript SHA-256: 0000000000000000000000000000000000000000000000000000000000000000/' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Transcript SHA-256 does not match"* ]]
    update_record_evidence_hashes "$record" "$evidence_dir"

    sed -i.bak $'s/Tester: release-tester/Tester: release\ttester/' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Tester must not contain tab or carriage-return characters"* ]]
    sed -i.bak $'s/Tester: release\ttester/Tester: release-tester/' "$record"

    sed -i.bak $'s#Evidence location: '"${evidence_dir}"$'#Evidence location: '"${evidence_dir}"$'\tcorrupt#' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence location must not contain tab or carriage-return characters"* ]]
    sed -i.bak $'s#Evidence location: '"${evidence_dir}"$'\tcorrupt#Evidence location: '"${evidence_dir}"$'#' "$record"

    sed -i.bak 's/Existing Roomy state: absent/Existing Roomy state: manual-or-unknown/' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Existing Roomy state must be 'absent'"* ]]
    sed -i.bak 's/Existing Roomy state: manual-or-unknown/Existing Roomy state: absent/' "$record"

    sed -i.bak "s#Evidence location: ${evidence_dir}#Evidence location: /missing/roomy/transcript#" "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence location must be an existing path or http(s) URL"* ]]
    sed -i.bak 's#Evidence location: /missing/roomy/transcript#Evidence location: https://example.invalid/transcript#' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence location must not use a placeholder or local-only URL"* ]]
    sed -i.bak 's#Evidence location: https://example.invalid/transcript#Evidence location: https://github.com/jake-seo-cl/roomy/releases/download/V9.9.8/clean-machine-drill-V9.9.8-evidence.tar.gz#' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence location URL must be the tag-specific Roomy release evidence asset"* ]]
    sed -i.bak "s#Evidence location: https://github.com/jake-seo-cl/roomy/releases/download/V9.9.8/clean-machine-drill-V9.9.8-evidence.tar.gz#Evidence location: ${evidence_dir}#" "$record"

    local unsupported_evidence="$HOME/evidence.txt"
    printf 'not an evidence directory or archive\n' > "$unsupported_evidence"
    sed -i.bak "s#Evidence location: ${evidence_dir}#Evidence location: ${unsupported_evidence}#" "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence location must be a directory, .tar.gz archive, or http(s) URL"* ]]
    sed -i.bak "s#Evidence location: ${unsupported_evidence}#Evidence location: ${evidence_dir}#" "$record"

    rm "$evidence_dir/transcript.txt"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence directory must include a non-empty transcript.txt"* ]]
    printf 'clean-machine transcript\n' > "$evidence_dir/transcript.txt"
    update_record_evidence_hashes "$record" "$evidence_dir"

    printf 'release preflight\t1\n' > "$evidence_dir/results.tsv"
    update_record_evidence_hashes "$record" "$evidence_dir"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence results.tsv must contain exactly label/status fields with zero command statuses"* ]]
    write_passing_drill_results "$evidence_dir/results.tsv"
    update_record_evidence_hashes "$record" "$evidence_dir"

    printf 'release preflight\t0\textra-field\n' > "$evidence_dir/results.tsv"
    update_record_evidence_hashes "$record" "$evidence_dir"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence results.tsv must contain exactly label/status fields with zero command statuses"* ]]
    write_passing_drill_results "$evidence_dir/results.tsv"
    update_record_evidence_hashes "$record" "$evidence_dir"

    grep -v '^script remove after drill	' "$evidence_dir/results.tsv" > "$evidence_dir/results.tmp"
    mv "$evidence_dir/results.tmp" "$evidence_dir/results.tsv"
    update_record_evidence_hashes "$record" "$evidence_dir"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence results.tsv is missing required passing command: script remove after drill"* ]]
    write_passing_drill_results "$evidence_dir/results.tsv"
    update_record_evidence_hashes "$record" "$evidence_dir"

    local evidence_archive="$HOME/clean-machine-evidence.tar.gz"
    tar -czf "$evidence_archive" -C "$evidence_dir" .
    sed -i.bak "s#Evidence location: ${evidence_dir}#Evidence location: ${evidence_archive}#" "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Clean-machine drill record passed"* ]]

    sed -i.bak "s#Evidence location: ${evidence_archive}#Evidence location: https://github.com/jake-seo-cl/roomy/releases/download/V9.9.9/clean-machine-drill-V9.9.9-evidence.tar.gz#" "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record" \
        --evidence "$evidence_archive"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Clean-machine drill record passed"* ]]

    local fake_curl_bin="$HOME/fake-curl-bin"
    mkdir -p "$fake_curl_bin"
    cat > "$fake_curl_bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            shift
            out="$1"
            ;;
        -*)
            ;;
        *)
            url="$1"
            ;;
    esac
    shift
done
[[ -n "$out" ]] || exit 2
[[ "$url" == "https://github.com/jake-seo-cl/roomy/releases/download/V9.9.9/clean-machine-drill-V9.9.9-evidence.tar.gz" ]] || exit 22
cp "$ROOMY_TEST_REMOTE_EVIDENCE_ARCHIVE" "$out"
SCRIPT
    chmod +x "$fake_curl_bin/curl"
    run env PATH="$fake_curl_bin:$PATH" ROOMY_TEST_REMOTE_EVIDENCE_ARCHIVE="$evidence_archive" \
        "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Clean-machine drill record passed"* ]]

    ln -s transcript.txt "$evidence_dir/link-to-transcript.txt"
    local symlink_archive="$HOME/clean-machine-evidence-symlink.tar.gz"
    tar -czf "$symlink_archive" -C "$evidence_dir" .
    rm "$evidence_dir/link-to-transcript.txt"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record" \
        --evidence "$symlink_archive"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence archive contains an unsupported entry type"* ]]

    sed -i.bak "s#Evidence location: https://github.com/jake-seo-cl/roomy/releases/download/V9.9.9/clean-machine-drill-V9.9.9-evidence.tar.gz#Evidence location: ${evidence_archive}#" "$record"

    sed -i.bak "s#Evidence location: ${evidence_archive}#Evidence location: ${evidence_dir}#" "$record"

    sed -i.bak 's/Launch decision: go/Launch decision: no-go/' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Launch decision must be 'go'"* ]]
    sed -i.bak 's/Launch decision: no-go/Launch decision: go/' "$record"

    sed -i.bak 's/Decision notes: All required gates passed in a clean VM./Decision notes: pending/' "$record"
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" \
        --tag "V9.9.9" \
        --record "$record"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Decision notes is missing or still a placeholder"* ]]
}

@test "clean-machine drill tooling rejects non-release tag names" {
    run "$PROJECT_ROOT/scripts/check-clean-machine-drill-record.sh" --tag main
    [ "$status" -ne 0 ]
    [[ "$output" == *"V<major>.<minor>.<patch>"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag main --previous-tag V9.9.8 --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"--tag must use V<major>.<minor>.<patch>"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag main --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"--previous-tag must use V<major>.<minor>.<patch>"* ]]
}

@test "clean-machine drill runner requires explicit previous tag and confirmation" {
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"provide --previous-tag"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag V9.9.8
    [ "$status" -ne 0 ]
    [[ "$output" == *"pass --yes"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag V9.9.8 --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"pass --fresh-environment"* ]]

    run env USER=unknown "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag V9.9.8 --fresh-environment --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"provide --tester with a real tester name or handle"* ]]

    local bad_tester=$'release\ntester'
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" \
        --tag V9.9.9 \
        --previous-tag V9.9.8 \
        --fresh-environment \
        --yes \
        --tester "$bad_tester"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Tester must not contain tab or newline characters"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag V9.9.8 --fresh-environment --yes --homebrew-tap
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing value for --homebrew-tap"* ]]

    local bad_tap=$'jake-seo-cl/tap\nbad'
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" \
        --tag V9.9.9 \
        --previous-tag V9.9.8 \
        --fresh-environment \
        --yes \
        --tester release-tester \
        --homebrew-tap "$bad_tap"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Homebrew tap must not contain tab or newline characters"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag V9.9.8 --fresh-environment --yes --homebrew-package
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing value for --homebrew-package"* ]]

    local bad_package=$'jake-seo-cl/tap/roomy\tbad'
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" \
        --tag V9.9.9 \
        --previous-tag V9.9.8 \
        --fresh-environment \
        --yes \
        --tester release-tester \
        --homebrew-package "$bad_package"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Homebrew package must not contain tab or newline characters"* ]]

    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" --tag V9.9.9 --previous-tag V9.9.8 --fresh-environment --yes --evidence-location
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing value for --evidence-location"* ]]

    local bad_evidence_location=$'https://github.com/jake-seo-cl/roomy/releases/download/V9.9.9/evidence.tar.gz\nbad'
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" \
        --tag V9.9.9 \
        --previous-tag V9.9.8 \
        --fresh-environment \
        --yes \
        --tester release-tester \
        --evidence-location "$bad_evidence_location"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence location must not contain tab or newline characters"* ]]

    local protected_record="$HOME/protected-drill-record.md"
    local record_link="$HOME/drill-record-link.md"
    printf 'keep-record\n' > "$protected_record"
    ln -s "$protected_record" "$record_link"
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" \
        --tag V9.9.9 \
        --previous-tag V9.9.8 \
        --fresh-environment \
        --yes \
        --tester release-tester \
        --record "$record_link"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Record output must not include parent traversal or symlinked path components"* ]]
    [[ "$(cat "$protected_record")" == "keep-record" ]]

    local protected_evidence="$HOME/protected-evidence-dir"
    local evidence_link="$HOME/drill-evidence-link"
    mkdir -p "$protected_evidence"
    ln -s "$protected_evidence" "$evidence_link"
    run "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh" \
        --tag V9.9.9 \
        --previous-tag V9.9.8 \
        --fresh-environment \
        --yes \
        --tester release-tester \
        --evidence-dir "$evidence_link"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Evidence output directory must not include parent traversal or symlinked path components"* ]]
    [ -z "$(find "$protected_evidence" -mindepth 1 -print -quit)" ]

    run grep -q "ROOMY_VERSION=\"\$previous_tag\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "raw.githubusercontent.com/jake-seo-cl/roomy/\\\${previous_tag}/install.sh" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "Evidence location: \${evidence_location}" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "brew tap \"\\\$homebrew_tap\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "brew install \"\\\$homebrew_package\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "check-release-version.sh --tag \"\\\$tag\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "raw.githubusercontent.com/jake-seo-cl/roomy/\\\${tag}/install.sh" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "run_version_command()" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "run_version_command \"homebrew roomy version\" \"\\\$tag\" roomy --version" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "run_version_command \"script roomy version\" \"\\\$tag\" roomy --version" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "run_version_command \"previous stable roomy version\" \"\\\$previous_tag\" roomy --version" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "run_command \"update from previous stable with target installer\" env ROOMY_VERSION=\"\\\$tag\" bash \"\\\$installer\" --update" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "run_version_command \"updated roomy version\" \"\\\$tag\" roomy --version" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "check-clean-machine-drill-record.sh --tag \"\\\$tag\" --record \"\\\$record\" --evidence \"\\\$evidence_dir\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "detect_full_disk_access()" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "detect_admin_privileges()" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "detect_network_access()" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "Full Disk Access: \${full_disk_access}" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "Admin privileges: \${admin_privileges}" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "Network access: \${network_access}" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "require_safe_metadata_value \"Tester\" \"\\\$tester\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "require_safe_metadata_value \"Evidence location\" \"\\\$evidence_location\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "require_safe_output_path \"Record output\" \"\\\$record\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "require_safe_output_path \"Evidence output directory\" \"\\\$evidence_dir\"" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "Transcript SHA-256: \\\${transcript_sha}" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]

    run grep -q "Results SHA-256: \\\${results_sha}" "$PROJECT_ROOT/scripts/run-clean-machine-cli-drill.sh"
    [ "$status" -eq 0 ]
}

@test "release notes verifier rejects placeholders and requires tag-specific content" {
    run "$PROJECT_ROOT/scripts/check-release-notes.sh" \
        --tag V9.9.9 \
        --notes "$PROJECT_ROOT/docs/release/release-notes-template.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"notes still contain placeholders"* ]]

    local notes="$HOME/V9.9.9-release-notes.md"
    cat > "$notes" <<'EOF'
# Roomy V9.9.9 Release Notes

Launch scope: CLI

## Compatibility And Scope

Roomy V9.9.9 ships the supported command-line product for macOS users.

## User-Visible Changes

This release improves preview-first cleanup workflows and command output.

## Safety And Destructive Workflows

Dry-run, protected path, confirmation, restore, and audit log behavior remain covered.

## Install, Update, And Remove

Homebrew, install script, update, rollback, and remove flows are validated for this tag.

## License And Source

This release preserves GPL-3.0 licensing, NOTICE attribution, and corresponding source for V9.9.9.

## Known Limitations

RoomyUI remains preview-only and is not published as a production native app.

## Verification

Clean-machine drill record: docs/launch/records/V9.9.9.md, verified by the public release gate before publication.
SHA256SUMS checksum evidence is generated in the release manifest.
Artifact attestation evidence is generated by the release workflow.
EOF

    run "$PROJECT_ROOT/scripts/check-release-notes.sh" --tag V9.9.9 --notes "$notes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Release notes passed"* ]]

    local empty_notes="$HOME/V9.9.9-empty-release-notes.md"
    cat > "$empty_notes" <<'EOF'
# Roomy V9.9.9 Release Notes

Launch scope: CLI

## Compatibility And Scope

Roomy V9.9.9 ships the supported command-line product for macOS users.

## User-Visible Changes

## Safety And Destructive Workflows

Dry-run, protected path, confirmation, restore, and audit log behavior remain covered.

## Install, Update, And Remove

Homebrew, install script, update, rollback, and remove flows are validated for this tag.

## License And Source

This release preserves GPL-3.0 licensing, NOTICE attribution, and corresponding source for V9.9.9.

## Known Limitations

RoomyUI remains preview-only and is not published as a production native app.

## Verification

Clean-machine drill record: docs/launch/records/V9.9.9.md, verified by the public release gate before publication.
SHA256SUMS checksum evidence is generated in the release manifest.
Artifact attestation evidence is generated by the release workflow.
EOF

    run "$PROJECT_ROOT/scripts/check-release-notes.sh" --tag V9.9.9 --notes "$empty_notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"User-Visible Changes section must include release-specific content"* ]]

    local pending_notes="$HOME/V9.9.9-pending-release-notes.md"
    cat > "$pending_notes" <<'EOF'
# Roomy V9.9.9 Release Notes

Launch scope: CLI

## Compatibility And Scope

Roomy V9.9.9 ships the supported command-line product for macOS users.

## User-Visible Changes

This release improves preview-first cleanup workflows and command output.

## Safety And Destructive Workflows

Dry-run, protected path, confirmation, restore, and audit log behavior remain covered.

## Install, Update, And Remove

Homebrew, install script, update, rollback, and remove flows are validated for this tag.

## License And Source

This release preserves GPL-3.0 licensing, NOTICE attribution, and corresponding source for V9.9.9.

## Known Limitations

RoomyUI remains preview-only and is not published as a production native app.

## Verification

Clean-machine drill record pending, checksum evidence pending, and artifact attestation pending.
EOF

    run "$PROJECT_ROOT/scripts/check-release-notes.sh" --tag V9.9.9 --notes "$pending_notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Verification section must confirm clean-machine validation source"* ]]

    run "$PROJECT_ROOT/scripts/check-release-notes.sh" --tag main --notes "$notes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"V<major>.<minor>.<patch>"* ]]
}

@test "release version verifier requires tag to match roomy VERSION" {
    local release_version
    release_version="$(current_roomy_version)"
    local release_tag
    release_tag="$(current_roomy_tag)"

    [[ -n "$release_version" ]]

    run "$PROJECT_ROOT/scripts/check-release-version.sh" --tag "$release_tag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches VERSION=\"$release_version\""* ]]

    local fake_roomy="$HOME/roomy"
    printf '%s\n' '#!/bin/bash' 'VERSION="9.9.8"' > "$fake_roomy"

    run "$PROJECT_ROOT/scripts/check-release-version.sh" --tag V9.9.9 --roomy "$fake_roomy"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match roomy VERSION=\"9.9.8\""* ]]

    printf '%s\n' '#!/bin/bash' 'VERSION="9.9.9"' > "$fake_roomy"
    run "$PROJECT_ROOT/scripts/check-release-version.sh" --tag V9.9.9 --roomy "$fake_roomy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches VERSION=\"9.9.9\""* ]]

    run "$PROJECT_ROOT/scripts/check-release-version.sh" --tag main
    [ "$status" -ne 0 ]
    [[ "$output" == *"V<major>.<minor>.<patch>"* ]]
}

@test "unsafe rm verifier scans top-level commands" {
    local fixture="$HOME/unsafe-rm-fixture"
    mkdir -p "$fixture/scripts" "$fixture/bin" "$fixture/lib"
    cp "$PROJECT_ROOT/scripts/check-unsafe-rm.sh" "$fixture/scripts/check-unsafe-rm.sh"
    chmod +x "$fixture/scripts/check-unsafe-rm.sh"

    cat > "$fixture/roomy" <<'EOF'
#!/usr/bin/env bash
rm -rf "$HOME/not-roomy-owned"
EOF
    cat > "$fixture/install.sh" <<'EOF'
#!/usr/bin/env bash
rm -fr "$HOME/installer-work"
EOF
    cat > "$fixture/bin/helper.sh" <<'EOF'
#!/usr/bin/env bash
/bin/rm -r -f "$HOME/helper-work"
EOF
cat > "$fixture/lib/remove.sh" <<'EOF'
#!/usr/bin/env bash
find "$HOME/remove-work" -type f -delete
find "$HOME/remove-work" -type f -exec rm -f {} +
xargs rm -f < "$HOME/remove-list"
printf '%s\n' "$HOME/remove-work" | xargs rm -rf
EOF

    run env ROOMY_UNSAFE_RM_ROOT_DIR="$fixture" "$fixture/scripts/check-unsafe-rm.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsafe deletion usage found"* ]]
    [[ "$output" == *"roomy:2:"* ]]
    [[ "$output" == *"install.sh:2:"* ]]
    [[ "$output" == *"bin/helper.sh:2:"* ]]
    [[ "$output" == *"lib/remove.sh:2:"* ]]
    [[ "$output" == *"lib/remove.sh:3:"* ]]
    [[ "$output" == *"lib/remove.sh:4:"* ]]
    [[ "$output" == *"lib/remove.sh:5:"* ]]

    cat > "$fixture/roomy" <<'EOF'
#!/usr/bin/env bash
command rm -rf "$HOME/.cache/roomy" # SAFE: exact Roomy-owned fixture path
EOF
    cat > "$fixture/install.sh" <<'EOF'
#!/usr/bin/env bash
command rm -rf "$HOME/installer-work" # SAFE: fixture-owned installer workspace
EOF
    cat > "$fixture/bin/helper.sh" <<'EOF'
#!/usr/bin/env bash
/bin/rm -r -f "$HOME/helper-work" # SAFE: fixture-owned helper workspace
EOF
cat > "$fixture/lib/remove.sh" <<'EOF'
#!/usr/bin/env bash
find "$HOME/remove-work" -type f -delete # SAFE: fixture-owned remove workspace
find "$HOME/remove-work" -type f -exec rm -f {} + # SAFE: fixture-owned remove workspace
xargs rm -f < "$HOME/remove-list" # SAFE: fixture-owned remove list
printf '%s\n' "$HOME/remove-work" | xargs rm -rf # SAFE: fixture-owned remove pipeline
EOF

    run env ROOMY_UNSAFE_RM_ROOT_DIR="$fixture" "$fixture/scripts/check-unsafe-rm.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No unsafe deletion usage found"* ]]
}

@test "public release gate composes release blockers" {
    local release_tag
    release_tag="$(current_roomy_tag)"

    run "$PROJECT_ROOT/scripts/check-public-release.sh" --tag "$release_tag" --skip-site
    [ "$status" -ne 0 ]
    [[ "$output" == *"worktree has uncommitted or untracked source changes"* ]]
    [[ "$output" == *"missing record"* ]]
    [[ "$output" == *"one or more public release checks failed"* ]]

    run grep -q ':(exclude)node_modules/\*\*' "$PROJECT_ROOT/scripts/check-public-release.sh"
    [ "$status" -eq 0 ]

    run grep -q 'git update-index -q --refresh || true' "$PROJECT_ROOT/scripts/check-public-release.sh"
    [ "$status" -eq 0 ]

    run grep -q -- '--evidence' "$PROJECT_ROOT/scripts/check-public-release.sh"
    [ "$status" -eq 0 ]

    run grep -q -- '--final' "$PROJECT_ROOT/scripts/check-public-release.sh"
    [ "$status" -eq 0 ]

    run "$PROJECT_ROOT/scripts/check-public-release.sh" --tag "$release_tag" --final --allow-dirty
    [ "$status" -ne 0 ]
    [[ "$output" == *"--final cannot be combined with --allow-dirty"* ]]

    run "$PROJECT_ROOT/scripts/check-public-release.sh" --tag "$release_tag" --final --skip-site
    [ "$status" -ne 0 ]
    [[ "$output" == *"--final cannot be combined with --skip-site"* ]]

    run "$PROJECT_ROOT/scripts/check-public-release.sh" --tag "$release_tag" --final --skip-clean-machine
    [ "$status" -ne 0 ]
    [[ "$output" == *"--final cannot be combined with --skip-clean-machine"* ]]

    local mismatch_roomy="$HOME/mismatch-roomy"
    printf '%s\n' '#!/bin/bash' 'VERSION="9.9.8"' > "$mismatch_roomy"

    run "$PROJECT_ROOT/scripts/check-public-release.sh" \
        --tag V9.9.9 \
        --roomy "$mismatch_roomy" \
        --skip-site \
        --allow-dirty
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match roomy VERSION=\"9.9.8\""* ]]
    [[ "$output" == *"missing notes"* ]]
    [[ "$output" == *"missing record"* ]]
    [[ "$output" == *"one or more public release checks failed"* ]]

    run "$PROJECT_ROOT/scripts/check-public-release.sh" --tag "$release_tag" --skip-site --allow-dirty
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing record"* ]]
    [[ "$output" == *"one or more public release checks failed"* ]]

    run "$PROJECT_ROOT/scripts/check-public-release.sh" --tag "$release_tag" --skip-site --allow-dirty --skip-clean-machine
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping clean-machine drill record check for pre-asset draft staging"* ]]
    [[ "$output" == *"Public release gate passed"* ]]

    local release_roomy="$HOME/release-roomy"
    printf '%s\n' '#!/bin/bash' 'VERSION="9.9.9"' > "$release_roomy"

    local notes="$HOME/V9.9.9-release-notes.md"
    cat > "$notes" <<'EOF'
# Roomy V9.9.9 Release Notes

Launch scope: CLI

## Compatibility And Scope

Roomy V9.9.9 ships the supported command-line product for macOS users.

## User-Visible Changes

This release improves preview-first cleanup workflows and command output.

## Safety And Destructive Workflows

Dry-run, protected path, confirmation, restore, and audit log behavior remain covered.

## Install, Update, And Remove

Homebrew, install script, update, rollback, and remove flows are validated for this tag.

## License And Source

This release preserves GPL-3.0 licensing, NOTICE attribution, and corresponding source for V9.9.9.

## Known Limitations

RoomyUI remains preview-only and is not published as a production native app.

## Verification

Clean-machine drill record: docs/launch/records/V9.9.9.md, verified by the public release gate before publication.
SHA256SUMS checksum evidence is generated in the release manifest.
Artifact attestation evidence is generated by the release workflow.
EOF

    local record="$HOME/V9.9.9-drill-record.md"
    local evidence_dir="$HOME/public-release-evidence"
    local release_head
    mkdir -p "$evidence_dir"
    printf 'clean-machine transcript\n' > "$evidence_dir/transcript.txt"
    write_passing_drill_results "$evidence_dir/results.tsv"
    release_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
    cat > "$record" <<EOF
# Clean-Machine CLI Drill Record: V9.9.9

## Environment

Release tag: V9.9.9
Commit SHA: ${release_head}
Drill date: 2026-05-21
Tester: release-tester
macOS version: macOS 15.5 (24F74)
CPU architecture: arm64
Fresh environment: yes
Existing Roomy state: absent
Full Disk Access: available
Admin privileges: available
Network access: available

## Required Gate Results

Preflight: pass
Homebrew install: pass
Script install: pass
Checksum verification: pass
First-run dry-runs: pass
Update behavior: pass
Rollback/remove/reinstall: pass

## Evidence

Evidence location: ${evidence_dir}
Transcript SHA-256: $(file_sha256 "$evidence_dir/transcript.txt")
Results SHA-256: $(file_sha256 "$evidence_dir/results.tsv")

## Launch Decision

Launch decision: go
Decision notes: All required gates passed in a clean VM.
EOF

    run "$PROJECT_ROOT/scripts/check-public-release.sh" \
        --tag V9.9.9 \
        --roomy "$release_roomy" \
        --notes "$notes" \
        --record "$record" \
        --skip-site \
        --allow-dirty
    [ "$status" -eq 0 ]
    [[ "$output" == *"Public release gate passed for V9.9.9"* ]]

    sed -i.bak "s#Evidence location: ${evidence_dir}#Evidence location: /missing-public-release-evidence#" "$record"
    run "$PROJECT_ROOT/scripts/check-public-release.sh" \
        --tag V9.9.9 \
        --roomy "$release_roomy" \
        --notes "$notes" \
        --record "$record" \
        --evidence "$evidence_dir" \
        --skip-site \
        --allow-dirty
    [ "$status" -eq 0 ]
    [[ "$output" == *"Public release gate passed for V9.9.9"* ]]

    sed -i.bak "s/${release_head}/0123456789abcdef0123456789abcdef01234567/" "$record"
    run "$PROJECT_ROOT/scripts/check-public-release.sh" \
        --tag V9.9.9 \
        --roomy "$release_roomy" \
        --notes "$notes" \
        --record "$record" \
        --evidence "$evidence_dir" \
        --skip-site \
        --allow-dirty
    [ "$status" -ne 0 ]
    [[ "$output" == *"Commit SHA must match expected commit"* ]]
}

@test "public release gate retries transient landing smoke failures" {
    local release_tag fake_bin calls
    release_tag="$(current_roomy_tag)"
    fake_bin="$HOME/fake-bin"
    calls="$HOME/npm-calls"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/npm" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROOMY_TEST_NPM_CALLS"
count="$(wc -l < "$ROOMY_TEST_NPM_CALLS" | tr -d ' ')"
if [[ "$*" == "run site:check" && "$count" -eq 1 ]]; then
    exit 1
fi
exit 0
SCRIPT
    chmod +x "$fake_bin/npm"

    run env PATH="$fake_bin:$PATH" ROOMY_TEST_NPM_CALLS="$calls" ROOMY_SITE_CHECK_RETRIES=2 ROOMY_SITE_CHECK_RETRY_DELAY_SEC=0 \
        "$PROJECT_ROOT/scripts/check-public-release.sh" \
        --tag "$release_tag" \
        --skip-clean-machine \
        --allow-dirty
    [ "$status" -eq 0 ]
    [[ "$output" == *"retrying (1/2)"* ]]
    [[ "$output" == *"Public release gate passed"* ]]
    [ "$(wc -l < "$calls" | tr -d ' ')" -eq 2 ]
}

@test "release workflow validates canonical repository before Homebrew publishing" {
    local workflow="$PROJECT_ROOT/.github/workflows/release.yml"
    local repo_line secrets_line stage_line

    run grep -q 'Validate release repository' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q "\\\${GITHUB_REPOSITORY,,}.*jake-seo-cl/roomy" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Homebrew publishing is only allowed from jake-seo-cl/roomy' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'cleanup_release_asset_dir' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Downloaded release checksums are missing or empty' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'expected_release_files=(' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Unexpected release asset:' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Missing expected release asset:' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'expected_assets=(' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Unexpected release asset before stable promotion:' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Missing release asset before stable promotion:' "$workflow"
    [ "$status" -eq 0 ]

    run grep -Fq "grep -Fxq \"Tag: \${TAG}\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -Fq "grep -Fxq \"Commit: \${GITHUB_SHA}\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Release body does not start with curated' "$workflow"
    [ "$status" -eq 0 ]

    run grep -Fq "scripts/check-release-notes.sh --tag \"\$TAG\" --notes \"\${asset_dir}/RELEASE_BODY.md\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -Fq "grep -Fxq \"# Release Manifest: \${TAG}\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Release body manifest commit does not match' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'sha256sum --check SHA256SUMS' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'manifest_value()' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'require_manifest_sha "analyze-darwin-amd64 SHA-256" "analyze-darwin-amd64"' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Release manifest source archive checksum does not match' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q "Release manifest checksum for \${file} does not match SHA256SUMS" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'files: |' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'bin/RELEASE_MANIFEST.md' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'bin/RELEASE_BODY.md' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'bin/analyze-darwin-amd64' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'bin/analyze-darwin-\*' "$workflow"
    [ "$status" -ne 0 ]

    run grep -q 'bin/status-darwin-\*' "$workflow"
    [ "$status" -ne 0 ]

    run grep -q 'bin/binaries-darwin-\*.tar.gz' "$workflow"
    [ "$status" -ne 0 ]

    run grep -q 'files: bin/\*' "$workflow"
    [ "$status" -ne 0 ]

    run grep -q 'Curated release notes are missing or empty' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q "check-release-notes.sh --tag \"\\\$TAG\" --notes \"\\\$NOTES_PATH\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'Validate generated clean-machine record' "$workflow"
    [ "$status" -eq 0 ]

    run grep -Fq "check-public-release.sh --tag \"\${TAG}\" --final --record \"\${RECORD_PATH}\" --evidence \"\${EVIDENCE_PATH}\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -Fq -- "--evidence \"\${{ steps.drill.outputs.evidence_dir }}\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q '/tmp/SHA256SUMS' "$workflow"
    [ "$status" -ne 0 ]

    run grep -q "tap_checkout_dir=\"\\\$(mktemp -d)\"" "$workflow"
    [ "$status" -eq 0 ]

    run grep -q 'temporary Homebrew tap checkout directory created by mktemp' "$workflow"
    [ "$status" -eq 0 ]

    run grep -q '/tmp/homebrew-tap' "$workflow"
    [ "$status" -ne 0 ]

    repo_line="$(grep -n 'Validate release repository' "$workflow" | head -n 1 | cut -d: -f1)"
    secrets_line="$(grep -n 'Validate formula publishing secrets' "$workflow" | head -n 1 | cut -d: -f1)"
    stage_line="$(grep -n 'Stage GitHub prerelease for install-channel drill' "$workflow" | head -n 1 | cut -d: -f1)"

    [[ -n "$repo_line" && -n "$secrets_line" && -n "$stage_line" ]]
    [[ "$repo_line" -lt "$secrets_line" ]]
    [[ "$repo_line" -lt "$stage_line" ]]
}

@test "Makefile has build target for Go binaries" {
    run bash -c "grep -Eq '(^|[[:space:]])(go|\\$\\(GO\\))[[:space:]]+build' '$PROJECT_ROOT/Makefile'"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh has detect_roomy function" {
    run bash -c "grep -q 'detect_roomy()' '$PROJECT_ROOT/scripts/setup-quick-launchers.sh'"
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
    cat > "$fake_bin/roomy" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/roomy"

    run env HOME="$HOME" TERM="dumb" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Raycast: Roomy Clean | Alfred keyword: clean"* ]]
    [[ "$output" == *"Raycast: Roomy Status | Alfred keyword: status"* ]]

    local raycast_dir="$HOME/Library/Application Support/Raycast/script-commands"
    [ -d "$raycast_dir" ]

    local clean_script="$raycast_dir/roomy-clean.sh"
    local uninstall_script="$raycast_dir/roomy-uninstall.sh"
    local optimize_script="$raycast_dir/roomy-optimize.sh"
    local analyze_script="$raycast_dir/roomy-analyze.sh"
    local status_script="$raycast_dir/roomy-status.sh"

    [ -x "$clean_script" ]
    [ -x "$uninstall_script" ]
    [ -x "$optimize_script" ]
    [ -x "$analyze_script" ]
    [ -x "$status_script" ]

    run grep -q '^# @raycast.title Roomy Clean$' "$clean_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Roomy Uninstall$' "$uninstall_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Roomy Optimize$' "$optimize_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Roomy Analyze$' "$analyze_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Roomy Status$' "$status_script"
    [ "$status" -eq 0 ]

    run grep -q '^# @raycast.description Deep system cleanup with Roomy$' "$clean_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description Uninstall applications with Roomy$' "$uninstall_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description System health checks and optimization$' "$optimize_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description Disk space analysis with Roomy$' "$analyze_script"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.description Live system status dashboard$' "$status_script"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh replaces generated Raycast symlinks without following them" {
    local fake_bin="$HOME/fake-bin"
    local raycast_dir="$HOME/Library/Application Support/Raycast/script-commands"
    local protected_script="$HOME/protected-raycast-script"
    local protected_dir="$HOME/protected-raycast-dir"
    mkdir -p "$fake_bin" "$raycast_dir" "$protected_dir"
    cat > "$fake_bin/roomy" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/roomy"
    printf 'keep-raycast\n' > "$protected_script"
    ln -s "$protected_script" "$raycast_dir/roomy-clean.sh"
    ln -s "$protected_dir" "$raycast_dir/roomy-status.sh"

    run env HOME="$HOME" TERM="dumb" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
    [ "$status" -eq 0 ]
    [ ! -L "$raycast_dir/roomy-clean.sh" ]
    [ ! -L "$raycast_dir/roomy-status.sh" ]
    [[ "$(cat "$protected_script")" == "keep-raycast" ]]
    [ -z "$(find "$protected_dir" -mindepth 1 -print -quit)" ]
    run grep -q '^# @raycast.title Roomy Clean$' "$raycast_dir/roomy-clean.sh"
    [ "$status" -eq 0 ]
    run grep -q '^# @raycast.title Roomy Status$' "$raycast_dir/roomy-status.sh"
    [ "$status" -eq 0 ]
}

@test "setup-quick-launchers.sh refuses symlinked Raycast script directory" {
    local fake_bin="$HOME/fake-bin"
    local raycast_root="$HOME/Library/Application Support/Raycast"
    local raycast_dir="$raycast_root/script-commands"
    local redirected="$HOME/redirected-raycast"
    mkdir -p "$fake_bin" "$raycast_root" "$redirected"
    cat > "$fake_bin/roomy" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/roomy"
    ln -s "$redirected" "$raycast_dir"

    run env HOME="$HOME" TERM="dumb" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Launcher target directory must not include symlinked directories"* ]]
    [ -z "$(find "$redirected" -mindepth 1 -print -quit)" ]
}

@test "setup-quick-launchers.sh refuses symlinked Alfred workflows directory" {
    local fake_bin="$HOME/fake-bin"
    local alfred_prefs="$HOME/Alfred/Alfred.alfredpreferences"
    local redirected="$HOME/redirected-alfred-workflows"
    mkdir -p "$fake_bin" "$alfred_prefs" "$redirected"
    cat > "$fake_bin/roomy" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/roomy"
    ln -s "$redirected" "$alfred_prefs/workflows"

    run env HOME="$HOME" TERM="dumb" ALFRED_PREFS_DIR="$alfred_prefs" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Launcher target directory must not include symlinked directories"* ]]
    [ -z "$(find "$redirected" -mindepth 1 -print -quit)" ]
}

@test "setup-quick-launchers.sh quotes generated launcher command paths" {
    local fake_bin="$HOME/fake bin"
    local fake_roomy="$fake_bin/roomy & 'quoted'"
    local alfred_prefs="$HOME/Alfred/Alfred.alfredpreferences"
    mkdir -p "$fake_bin" "$alfred_prefs/workflows"
    cat > "$fake_roomy" <<'EOF'
#!/bin/bash
printf 'argv0=%s\narg1=%s\n' "$0" "${1:-}" > "$HOME/launcher-args.txt"
EOF
    chmod +x "$fake_roomy"

    run env HOME="$HOME" TERM="dumb" ROOMY_CLI_PATH="$fake_roomy" ALFRED_PREFS_DIR="$alfred_prefs" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        "$PROJECT_ROOT/scripts/setup-quick-launchers.sh"
    [ "$status" -eq 0 ]

    local clean_script="$HOME/Library/Application Support/Raycast/script-commands/roomy-clean.sh"
    [ -x "$clean_script" ]

    run env HOME="$HOME" TERM="xterm-256color" "$clean_script"
    [ "$status" -eq 0 ]
    run grep -Fx "argv0=$fake_roomy" "$HOME/launcher-args.txt"
    [ "$status" -eq 0 ]
    run grep -Fx "arg1=clean" "$HOME/launcher-args.txt"
    [ "$status" -eq 0 ]

    run grep -R '&amp;' "$alfred_prefs/workflows"
    [ "$status" -eq 0 ]
    run grep -R '&apos;' "$alfred_prefs/workflows"
    [ "$status" -eq 0 ]
}

@test "install.sh supports dev branch installs" {
    run bash -c "grep -q 'refs/heads/dev.tar.gz' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
    run bash -c "grep -q 'ROOMY_VERSION=\"dev\"' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh help is available without starting installation" {
    run "$PROJECT_ROOT/install.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Roomy installer"* ]]
    [[ "$output" == *"--prefix PATH"* ]]
    [[ "$output" == *"--update"* ]]
}

@test "install.sh rejects invalid release version tokens before installation" {
    run "$PROJECT_ROOT/install.sh" 1.2.bad
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid Roomy release version: 1.2.bad"* ]]
}

@test "update_homebrew_tap_formula.sh updates all release artifacts" {
    local formula_file="$HOME/roomy.rb"
    local old_source_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old_arm_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local old_amd_sha="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    local new_source_sha="1111111111111111111111111111111111111111111111111111111111111111"
    local new_arm_sha="2222222222222222222222222222222222222222222222222222222222222222"
    local new_amd_sha="3333333333333333333333333333333333333333333333333333333333333333"
    cat > "$formula_file" <<'EOF'
class Roomy < Formula
  desc "Roomy"
  homepage "https://github.com/jake-seo-cl/Roomy"
  url "https://github.com/jake-seo-cl/Roomy/archive/refs/tags/V1.32.0.tar.gz"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  on_arm do
    url "https://github.com/jake-seo-cl/Roomy/releases/download/V1.32.0/binaries-darwin-arm64.tar.gz"
    sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  end

  on_intel do
    url "https://github.com/jake-seo-cl/Roomy/releases/download/V1.32.0/binaries-darwin-amd64.tar.gz"
    sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  end
end
EOF

    run "$PROJECT_ROOT/scripts/update_homebrew_tap_formula.sh" \
        --formula "$formula_file" \
        --tag "V1.33.0" \
        --source-sha "$new_source_sha" \
        --arm-sha "$new_arm_sha" \
        --amd-sha "$new_amd_sha"
    [ "$status" -eq 0 ]

    run grep -q 'url "https://github.com/jake-seo-cl/roomy/archive/refs/tags/V1.33.0.tar.gz"' "$formula_file"
    [ "$status" -eq 0 ]
    run grep -q "sha256 \"$new_source_sha\"" "$formula_file"
    [ "$status" -eq 0 ]
    run grep -q 'url "https://github.com/jake-seo-cl/roomy/releases/download/V1.33.0/binaries-darwin-arm64.tar.gz"' "$formula_file"
    [ "$status" -eq 0 ]
    run grep -q "sha256 \"$new_arm_sha\"" "$formula_file"
    [ "$status" -eq 0 ]
    run grep -q 'url "https://github.com/jake-seo-cl/roomy/releases/download/V1.33.0/binaries-darwin-amd64.tar.gz"' "$formula_file"
    [ "$status" -eq 0 ]
    run grep -q "sha256 \"$new_amd_sha\"" "$formula_file"
    [ "$status" -eq 0 ]

    [[ "$old_source_sha" != "$new_source_sha" ]]
    [[ "$old_arm_sha" != "$new_arm_sha" ]]
    [[ "$old_amd_sha" != "$new_amd_sha" ]]
}

@test "update_homebrew_tap_formula.sh validates release tags and checksums" {
    local formula_file="$HOME/roomy-invalid-input.rb"
    cat > "$formula_file" <<'EOF'
class Roomy < Formula
  desc "Roomy"
  homepage "https://github.com/jake-seo-cl/Roomy"
  url "https://github.com/jake-seo-cl/Roomy/archive/refs/tags/V1.32.0.tar.gz"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  on_arm do
    url "https://github.com/jake-seo-cl/Roomy/releases/download/V1.32.0/binaries-darwin-arm64.tar.gz"
    sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  end

  on_intel do
    url "https://github.com/jake-seo-cl/Roomy/releases/download/V1.32.0/binaries-darwin-amd64.tar.gz"
    sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  end
end
EOF

    run "$PROJECT_ROOT/scripts/update_homebrew_tap_formula.sh" \
        --formula "$formula_file" \
        --tag "1.33.0" \
        --source-sha "1111111111111111111111111111111111111111111111111111111111111111" \
        --arm-sha "2222222222222222222222222222222222222222222222222222222222222222" \
        --amd-sha "3333333333333333333333333333333333333333333333333333333333333333"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid tag"* ]]

    run "$PROJECT_ROOT/scripts/update_homebrew_tap_formula.sh" \
        --formula "$formula_file" \
        --tag "V1.33.0" \
        --source-sha "not-a-sha" \
        --arm-sha "2222222222222222222222222222222222222222222222222222222222222222" \
        --amd-sha "3333333333333333333333333333333333333333333333333333333333333333"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid SHA-256 checksum"* ]]
}

@test "update_homebrew_tap_formula.sh fails when expected sections are missing" {
    local formula_file="$HOME/roomy-missing-intel.rb"
    cat > "$formula_file" <<'EOF'
class Roomy < Formula
  desc "Roomy"
  homepage "https://github.com/jake-seo-cl/Roomy"
  url "https://github.com/jake-seo-cl/Roomy/archive/refs/tags/V1.32.0.tar.gz"
  sha256 "old-source-sha"

  on_arm do
    url "https://github.com/jake-seo-cl/Roomy/releases/download/V1.32.0/binaries-darwin-arm64.tar.gz"
    sha256 "old-arm-sha"
  end
end
EOF

    run "$PROJECT_ROOT/scripts/update_homebrew_tap_formula.sh" \
        --formula "$formula_file" \
        --tag "V1.33.0" \
        --source-sha "1111111111111111111111111111111111111111111111111111111111111111" \
        --arm-sha "2222222222222222222222222222222222222222222222222222222222222222" \
        --amd-sha "3333333333333333333333333333333333333333333333333333333333333333"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to update formula"* ]]
}
