#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
    cat << 'EOF'
Usage: scripts/run-clean-machine-cli-drill.sh --tag TAG --previous-tag TAG --fresh-environment --yes [options]

Runs the clean-machine CLI drill on a fresh macOS environment, captures command
evidence, and writes docs/launch/records/TAG.md.

Required:
  --tag TAG           Release tag being validated, for example V1.39.0
  --previous-tag TAG  Previous stable tag used to test update behavior
  --fresh-environment Confirm this is a clean macOS user/VM/snapshot
  --yes              Confirm this script may install, update, and remove Roomy

Options:
  --tester NAME      Tester name/handle for the record
  --record PATH      Output record path
  --evidence-dir DIR Output transcript directory
  --evidence-location LOCATION
                    Evidence location to write in the record
  --homebrew-tap TAP Tap before Homebrew install, for example tw93/tap
  --homebrew-package FORMULA
                    Formula to install, for example tw93/tap/roomy
  --help             Show this help
EOF
}

fail() {
    printf 'error: clean-machine drill: %s\n' "$*" >&2
    exit 1
}

is_release_tag() {
    local value="$1"
    [[ "$value" =~ ^V[0-9]+[.][0-9]+[.][0-9]+$ ]]
}

is_placeholder_value() {
    local value="$1"
    case "$value" in
        "" | *"<"* | *">"* | *[Tt][Oo][Dd][Oo]* | *[Tt][Bb][Dd]* | [Nn]/[Aa] | [Uu][Nn][Kk][Nn][Oo][Ww][Nn] | [Pp][Ee][Nn][Dd][Ii][Nn][Gg]*)
            return 0
            ;;
    esac
    return 1
}

require_release_tag() {
    local flag="$1"
    local value="$2"
    is_release_tag "$value" || fail "${flag} must use V<major>.<minor>.<patch> format"
}

contains_evidence_control_chars() {
    local value="$1"

    case "$value" in
        *$'\n'* | *$'\r'* | *$'\t'*)
            return 0
            ;;
    esac

    return 1
}

require_safe_metadata_value() {
    local label="$1"
    local value="$2"

    if contains_evidence_control_chars "$value"; then
        fail "${label} must not contain tab or newline characters"
    fi
}

path_has_symlink_component() {
    local path="$1"
    local current
    local part
    local -a path_parts

    if [[ "$path" == /* ]]; then
        current=""
    else
        current="."
    fi

    IFS='/' read -r -a path_parts <<< "$path"
    for part in "${path_parts[@]}"; do
        [[ -n "$part" && "$part" != "." ]] || continue
        if [[ "$part" == ".." ]]; then
            return 0
        fi

        if [[ -z "$current" ]]; then
            current="/$part"
        elif [[ "$current" == "." ]]; then
            current="./$part"
        else
            current="${current%/}/$part"
        fi

        [[ -L "$current" ]] && return 0
    done

    return 1
}

require_safe_output_path() {
    local label="$1"
    local path="$2"

    [[ -n "$path" ]] || fail "${label} path is empty"
    require_safe_metadata_value "$label" "$path"
    if path_has_symlink_component "$path"; then
        fail "${label} must not include parent traversal or symlinked path components: $path"
    fi
}

file_sha256() {
    local path="$1"

    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$path" | awk '{ print $1 }'
    else
        shasum -a 256 "$path" | awk '{ print $1 }'
    fi
}

tag=""
previous_tag=""
tester="${USER:-unknown}"
record=""
evidence_dir=""
evidence_location=""
homebrew_tap=""
homebrew_package="roomy"
confirmed=0
fresh_confirmed=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tag"
            tag="$1"
            ;;
        --previous-tag)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --previous-tag"
            previous_tag="$1"
            ;;
        --tester)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tester"
            tester="$1"
            ;;
        --record)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --record"
            record="$1"
            ;;
        --evidence-dir)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --evidence-dir"
            evidence_dir="$1"
            ;;
        --evidence-location)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --evidence-location"
            evidence_location="$1"
            ;;
        --homebrew-tap)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --homebrew-tap"
            homebrew_tap="$1"
            ;;
        --homebrew-package)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --homebrew-package"
            homebrew_package="$1"
            ;;
        --fresh-environment)
            fresh_confirmed=1
            ;;
        --yes)
            confirmed=1
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
    shift
done

[[ -n "$tag" ]] || fail "provide --tag"
[[ -n "$previous_tag" ]] || fail "provide --previous-tag to validate an actual update path"
require_release_tag "--tag" "$tag"
require_release_tag "--previous-tag" "$previous_tag"
[[ "$confirmed" -eq 1 ]] || fail "pass --yes after reading the runbook; this script mutates Roomy installs"
[[ "$fresh_confirmed" -eq 1 ]] || fail "pass --fresh-environment after confirming this is a clean macOS user, VM, or reset snapshot"
if is_placeholder_value "$tester"; then
    fail "provide --tester with a real tester name or handle"
fi
require_safe_metadata_value "Tester" "$tester"
if [[ -n "$homebrew_tap" ]]; then
    require_safe_metadata_value "Homebrew tap" "$homebrew_tap"
fi
require_safe_metadata_value "Homebrew package" "$homebrew_package"

if [[ -z "$record" ]]; then
    record="docs/launch/records/${tag}.md"
fi
if [[ -z "$evidence_dir" ]]; then
    evidence_dir="test-results/clean-machine-drill/${tag}-$(date -u '+%Y%m%dT%H%M%SZ')"
fi
if [[ -z "$evidence_location" ]]; then
    evidence_location="$evidence_dir"
fi

require_safe_metadata_value "Evidence location" "$evidence_location"
require_safe_output_path "Record output" "$record"
require_safe_output_path "Evidence output directory" "$evidence_dir"
[[ "$(uname -s)" == "Darwin" ]] || fail "clean-machine drill must run on macOS"

mkdir -p "$evidence_dir" "$(dirname "$record")"

transcript="$evidence_dir/transcript.txt"
results_file="$evidence_dir/results.tsv"
installer="$evidence_dir/install.sh"
previous_installer="$evidence_dir/install-${previous_tag}.sh"
: > "$transcript"
: > "$results_file"

run_command() {
    local label="$1"
    shift

    {
        printf '\n## %s\n' "$label"
        printf '$'
        printf ' %q' "$@"
        printf '\n'
    } >> "$transcript"

    set +e
    "$@" >> "$transcript" 2>&1
    local status=$?
    set -e

    printf '%s\t%s\n' "$label" "$status" >> "$results_file"
    return "$status"
}

run_shell() {
    local label="$1"
    local command="$2"
    run_command "$label" bash -lc "$command"
}

run_version_command() {
    local label="$1"
    local expected_tag="$2"
    shift 2
    local expected_version="${expected_tag#V}"
    local expected_pattern
    local output_file
    local status

    expected_pattern="$(printf '%s' "$expected_version" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
    output_file="$(mktemp "${evidence_dir}/version-output.XXXXXX")"

    {
        printf '\n## %s\n' "$label"
        printf '$'
        printf ' %q' "$@"
        printf '\n'
    } >> "$transcript"

    set +e
    "$@" > "$output_file" 2>&1
    status=$?
    set -e

    cat "$output_file" >> "$transcript"

    if [[ "$status" -eq 0 ]] && grep -Eq "(^|[^0-9])${expected_pattern}([^0-9]|$)" "$output_file"; then
        status=0
    else
        {
            printf '\nExpected Roomy version: %s\n' "$expected_version"
            printf 'Version check failed for %s\n' "$label"
        } >> "$transcript"
        status=1
    fi

    rm -f "$output_file"
    printf '%s\t%s\n' "$label" "$status" >> "$results_file"
    return "$status"
}

mark_gate() {
    local current="$1"
    local status="$2"
    if [[ "$current" == "fail" || "$status" -ne 0 ]]; then
        printf 'fail\n'
    else
        printf 'pass\n'
    fi
}

detect_existing_roomy_state() {
    if command -v brew > /dev/null 2>&1 && brew list roomy > /dev/null 2>&1; then
        printf 'previous-stable\n'
    elif command -v roomy > /dev/null 2>&1; then
        printf 'manual-or-unknown\n'
    else
        printf 'absent\n'
    fi
}

detect_full_disk_access() {
    local probe
    for probe in "$HOME/Library/Mail" "$HOME/Library/Messages" "$HOME/Library/Safari"; do
        [[ -e "$probe" ]] || continue
        if ls "$probe" > /dev/null 2>&1; then
            printf 'available\n'
        else
            printf 'not-available\n'
        fi
        return
    done
    printf 'not-available\n'
}

detect_admin_privileges() {
    if id -Gn | tr ' ' '\n' | grep -qx 'admin'; then
        printf 'available\n'
    else
        printf 'not-available\n'
    fi
}

detect_network_access() {
    if command -v curl > /dev/null 2>&1 && curl -fsI --max-time 10 https://github.com > /dev/null 2>&1; then
        printf 'available\n'
    else
        printf 'not-available\n'
    fi
}

macos_version="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
arch="$(uname -m)"
commit_sha="$(git rev-parse HEAD 2> /dev/null || printf 'unknown')"
existing_state="$(detect_existing_roomy_state)"
full_disk_access="$(detect_full_disk_access)"
admin_privileges="$(detect_admin_privileges)"
network_access="$(detect_network_access)"

if [[ "$existing_state" != "absent" ]]; then
    fail "Roomy appears to be installed (${existing_state}); rerun on a fresh user, VM, or reset snapshot"
fi

preflight_gate="pass"
run_command "release preflight" scripts/release-preflight.sh || preflight_gate="fail"
run_command "release version matches tag" scripts/check-release-version.sh --tag "$tag" || preflight_gate="fail"
run_command "go tests" go test ./... || preflight_gate="fail"
run_command "shell and integration tests without API" env ROOMY_SKIP_API_TESTS=1 scripts/test.sh || preflight_gate="fail"
run_command "API contract tests" npm run test:api || preflight_gate="fail"

homebrew_gate="pass"
first_run_gate="pass"
if ! command -v brew > /dev/null 2>&1; then
    homebrew_gate="fail"
    printf 'Homebrew is not available\n' >> "$transcript"
else
    if [[ -n "$homebrew_tap" ]]; then
        run_command "brew tap ${homebrew_tap}" brew tap "$homebrew_tap" || homebrew_gate="fail"
    fi
    run_command "brew update" brew update || homebrew_gate="fail"
    run_command "brew install ${homebrew_package}" brew install "$homebrew_package" || homebrew_gate="fail"
    run_version_command "homebrew roomy version" "$tag" roomy --version || homebrew_gate="fail"
    run_command "homebrew clean dry-run" roomy clean --dry-run || first_run_gate="fail"
    run_command "homebrew uninstall dry-run" roomy uninstall --dry-run || first_run_gate="fail"
    run_command "homebrew purge dry-run" roomy purge --dry-run || first_run_gate="fail"
    run_command "homebrew installer dry-run" roomy installer --dry-run || first_run_gate="fail"
    run_command "homebrew optimize dry-run" roomy optimize --dry-run || first_run_gate="fail"
    run_command "homebrew status" roomy status || first_run_gate="fail"
    run_command "homebrew analyze json" roomy analyze --json "$HOME" || first_run_gate="fail"
    run_command "brew uninstall roomy after drill" brew uninstall roomy || homebrew_gate="fail"
fi

script_gate="pass"
checksum_gate="pass"
update_gate="pass"
rollback_gate="pass"
run_command "download install script" curl -fsSL -o "$installer" "https://raw.githubusercontent.com/tw93/roomy/${tag}/install.sh" || script_gate="fail"
run_command "download previous install script" curl -fsSL -o "$previous_installer" "https://raw.githubusercontent.com/tw93/roomy/${previous_tag}/install.sh" || update_gate="fail"
installer_ready=0
previous_installer_ready=0
if [[ -f "$installer" ]]; then
    chmod +x "$installer"
    installer_ready=1
    run_command "script install target release" env ROOMY_VERSION="$tag" bash "$installer" || script_gate="fail"
    run_version_command "script roomy version" "$tag" roomy --version || script_gate="fail"
    run_command "script clean dry-run" roomy clean --dry-run || first_run_gate="fail"
    run_command "script uninstall dry-run" roomy uninstall --dry-run || first_run_gate="fail"
    run_command "script update dry-run" roomy update --dry-run || script_gate="fail"
    run_command "script remove dry-run" roomy remove --dry-run || script_gate="fail"
    run_command "script remove after drill" roomy remove || script_gate="fail"
else
    script_gate="fail"
    checksum_gate="fail"
    printf 'Installer download did not produce %s\n' "$installer" >> "$transcript"
fi
if [[ -f "$previous_installer" ]]; then
    chmod +x "$previous_installer"
    previous_installer_ready=1
else
    update_gate="fail"
    printf 'Previous installer download did not produce %s\n' "$previous_installer" >> "$transcript"
fi

if ! grep -q 'Downloaded analyze binary' "$transcript" || ! grep -q 'Downloaded status binary' "$transcript"; then
    checksum_gate="fail"
fi
if grep -q 'Checksum verification failed' "$transcript"; then
    checksum_gate="fail"
fi

if [[ "$installer_ready" -eq 1 && "$previous_installer_ready" -eq 1 ]]; then
    run_command "install previous stable for update drill" env ROOMY_VERSION="$previous_tag" bash "$previous_installer" || update_gate="fail"
    run_version_command "previous stable roomy version" "$previous_tag" roomy --version || update_gate="fail"
    run_command "update from previous stable with target installer" env ROOMY_VERSION="$tag" bash "$installer" --update || update_gate="fail"
    run_version_command "updated roomy version" "$tag" roomy --version || update_gate="fail"
    run_command "remove dry-run after update" roomy remove --dry-run || rollback_gate="fail"
    run_command "remove after update drill" roomy remove || rollback_gate="fail"
    if command -v brew > /dev/null 2>&1; then
        if [[ -n "$homebrew_tap" ]]; then
            run_command "brew tap ${homebrew_tap} before reinstall" brew tap "$homebrew_tap" || rollback_gate="fail"
        fi
        run_command "reinstall through Homebrew after remove" brew install "$homebrew_package" || rollback_gate="fail"
        run_version_command "homebrew reinstall version" "$tag" roomy --version || rollback_gate="fail"
        run_command "cleanup Homebrew reinstall" brew uninstall roomy || rollback_gate="fail"
    fi
else
    update_gate="fail"
    rollback_gate="fail"
    printf 'Skipping update and rollback drills because installer is unavailable\n' >> "$transcript"
fi

launch_decision="go"
decision_notes="All required gates passed in a clean macOS drill."
for gate in "$preflight_gate" "$homebrew_gate" "$script_gate" "$checksum_gate" "$first_run_gate" "$update_gate" "$rollback_gate"; do
    if [[ "$gate" != "pass" ]]; then
        launch_decision="no-go"
        decision_notes="One or more required gates failed. See ${transcript}."
        break
    fi
done
transcript_sha="$(file_sha256 "$transcript")"
results_sha="$(file_sha256 "$results_file")"

cat > "$record" << EOF
# Clean-Machine CLI Drill Record: ${tag}

## Environment

Release tag: ${tag}
Commit SHA: ${commit_sha}
Drill date: $(date -u '+%Y-%m-%d')
Tester: ${tester}
macOS version: ${macos_version}
CPU architecture: ${arch}
Fresh environment: yes
Existing Roomy state: ${existing_state}
Full Disk Access: ${full_disk_access}
Admin privileges: ${admin_privileges}
Network access: ${network_access}

## Required Gate Results

Preflight: ${preflight_gate}
Homebrew install: ${homebrew_gate}
Script install: ${script_gate}
Checksum verification: ${checksum_gate}
First-run dry-runs: ${first_run_gate}
Update behavior: ${update_gate}
Rollback/remove/reinstall: ${rollback_gate}

## Evidence

Evidence location: ${evidence_location}
Transcript SHA-256: ${transcript_sha}
Results SHA-256: ${results_sha}

## Failures, Skips, Or Waivers

See ${results_file}.

## Launch Decision

Launch decision: ${launch_decision}
Decision notes: ${decision_notes}
EOF

printf 'Wrote drill record: %s\n' "$record"
printf 'Wrote evidence transcript: %s\n' "$transcript"

if [[ "$launch_decision" != "go" ]]; then
    exit 1
fi

scripts/check-clean-machine-drill-record.sh --tag "$tag" --record "$record" --evidence "$evidence_dir"
