#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
    cat << 'EOF'
Usage: scripts/check-clean-machine-drill-record.sh --tag TAG [--record PATH] [--commit SHA] [--evidence PATH_OR_URL]

Validates that a completed clean-machine CLI drill record exists for a public
release tag. By default the record path is docs/launch/records/TAG.md.

When Evidence location points to a local evidence directory, local .tar.gz
archive, or canonical release asset URL, the evidence must include non-empty
transcript.txt and results.tsv files. Every status in results.tsv must be zero,
and the file must include the required clean-machine drill command labels.
EOF
}

fail() {
    printf 'error: clean-machine drill record: %s\n' "$*" >&2
    exit 1
}

tag=""
record=""
expected_commit=""
evidence_override=""
cleanup_paths=()

cleanup_temp_paths() {
    local path

    set +u
    for path in "${cleanup_paths[@]}"; do
        [[ -n "$path" ]] || continue
        if [[ -d "$path" && ! -L "$path" ]]; then
            rm -rf "$path" # SAFE: verifier-owned temporary path created by mktemp
        else
            rm -f "$path"
        fi
    done
    set -u
}

track_temp_path() {
    cleanup_paths+=("$1")
}

trap cleanup_temp_paths EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tag"
            tag="$1"
            ;;
        --record)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --record"
            record="$1"
            ;;
        --commit)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --commit"
            expected_commit="$1"
            ;;
        --evidence)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --evidence"
            evidence_override="$1"
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

if [[ -z "$record" ]]; then
    [[ -n "$tag" ]] || fail "provide --tag or --record"
    record="docs/launch/records/${tag}.md"
fi

[[ -f "$record" ]] || fail "missing record: $record"

field_value() {
    local field="$1"
    awk -v field="$field" '
        index($0, field ":") == 1 {
            sub("^[^:]*:[[:space:]]*", "")
            print
            exit
        }
    ' "$record"
}

is_placeholder() {
    local value="$1"
    case "$value" in
        "" | *"<"* | *">"* | *[Tt][Oo][Dd][Oo]* | *[Tt][Bb][Dd]* | [Nn]/[Aa] | [Uu][Nn][Kk][Nn][Oo][Ww][Nn] | [Pp][Ee][Nn][Dd][Ii][Nn][Gg]*)
            return 0
            ;;
    esac
    return 1
}

is_placeholder_url() {
    local value="$1"
    case "$value" in
        http://example.* | https://example.* | \
            http://*.example.* | https://*.example.* | \
            http://localhost* | https://localhost* | \
            http://127.0.0.1* | https://127.0.0.1* | \
            http://0.0.0.0* | https://0.0.0.0*)
            return 0
            ;;
    esac
    return 1
}

is_release_tag() {
    local value="$1"
    [[ "$value" =~ ^V[0-9]+[.][0-9]+[.][0-9]+$ ]]
}

expected_evidence_url() {
    local record_tag
    record_tag="$(field_value "Release tag")"
    printf 'https://github.com/jake-seo-cl/roomy/releases/download/%s/clean-machine-drill-%s-evidence.tar.gz\n' "$record_tag" "$record_tag"
}

require_canonical_evidence_url() {
    local label="$1"
    local url="$2"
    local expected

    case "$url" in
        http://* | https://*)
            expected="$(expected_evidence_url)"
            [[ "$url" == "$expected" ]] || fail "$label URL must be the tag-specific Roomy release evidence asset: $expected (got '$url')"
            ;;
    esac
}

require_remote_evidence_archive() {
    local url="$1"
    local archive

    command -v curl > /dev/null 2>&1 || fail "curl is required to download evidence archive: $url"
    archive="$(mktemp "${TMPDIR:-/tmp}/roomy-evidence-download.XXXXXX")"
    track_temp_path "$archive"
    if ! curl -fsSL "$url" -o "$archive"; then
        fail "Unable to download evidence archive: $url"
    fi

    require_local_evidence_archive "$archive"
}

require_release_tag_value() {
    local value="$1"
    is_release_tag "$value" || fail "Release tag must use V<major>.<minor>.<patch> format (got '${value:-<missing>}')"
}

contains_record_control_chars() {
    local value="$1"

    case "$value" in
        *$'\r'* | *$'\t'*)
            return 0
            ;;
    esac

    return 1
}

require_field_metadata_safe() {
    local field="$1"
    local value
    value="$(field_value "$field")"

    if contains_record_control_chars "$value"; then
        fail "$field must not contain tab or carriage-return characters"
    fi
}

require_field() {
    local field="$1"
    local value
    value="$(field_value "$field")"
    if is_placeholder "$value"; then
        fail "$field is missing or still a placeholder"
    fi
}

require_field_equals() {
    local field="$1"
    local expected="$2"
    local value
    value="$(field_value "$field")"
    [[ "$value" == "$expected" ]] || fail "$field must be '$expected' (got '${value:-<missing>}')"
}

require_field_match() {
    local field="$1"
    local pattern="$2"
    local label="$3"
    local value
    value="$(field_value "$field")"
    if is_placeholder "$value" || ! [[ "$value" =~ $pattern ]]; then
        fail "$label (got '${value:-<missing>}')"
    fi
}

require_commit_value() {
    local label="$1"
    local value="$2"
    if is_placeholder "$value" || ! [[ "$value" =~ ^[0-9a-f]{40}$ ]]; then
        fail "$label must be a full 40-character lowercase hex SHA (got '${value:-<missing>}')"
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

require_sha256_field() {
    local field="$1"
    local value
    value="$(field_value "$field")"
    if is_placeholder "$value" || ! [[ "$value" =~ ^[0-9a-f]{64}$ ]]; then
        fail "$field must be a 64-character lowercase SHA-256 digest (got '${value:-<missing>}')"
    fi
}

require_file_sha256_matches_field() {
    local field="$1"
    local path="$2"
    local expected
    local actual

    expected="$(field_value "$field")"
    actual="$(file_sha256 "$path")"
    [[ "$actual" == "$expected" ]] || fail "$field does not match ${path} (expected '$expected', got '$actual')"
}

require_gate_passed() {
    local field="$1"
    require_field_equals "$field" "pass"
}

require_evidence_location() {
    local evidence
    local record_evidence
    record_evidence="$(field_value "Evidence location")"
    if contains_record_control_chars "$record_evidence"; then
        fail "Evidence location must not contain tab or carriage-return characters"
    fi
    if is_placeholder "$record_evidence"; then
        fail "Evidence location is missing or still a placeholder"
    fi
    if is_placeholder_url "$record_evidence"; then
        fail "Evidence location must not use a placeholder or local-only URL (got '$record_evidence')"
    fi
    require_canonical_evidence_url "Evidence location" "$record_evidence"

    if [[ -n "$evidence_override" ]]; then
        evidence="$evidence_override"
    else
        evidence="$record_evidence"
    fi
    if contains_record_control_chars "$evidence"; then
        fail "Evidence location must not contain tab or carriage-return characters"
    fi
    if is_placeholder "$evidence"; then
        fail "Evidence location is missing or still a placeholder"
    fi

    case "$evidence" in
        http://* | https://*)
            if is_placeholder_url "$evidence"; then
                fail "Evidence location must not use a placeholder or local-only URL (got '$evidence')"
            fi
            require_canonical_evidence_url "Evidence override" "$evidence"
            require_remote_evidence_archive "$evidence"
            return 0
            ;;
    esac

    [[ -e "$evidence" ]] || fail "Evidence location must be an existing path or http(s) URL (got '$evidence')"
    if [[ -d "$evidence" ]]; then
        require_local_evidence_dir "$evidence"
    elif [[ "$evidence" == *.tar.gz || "$evidence" == *.tgz ]]; then
        require_local_evidence_archive "$evidence"
    else
        fail "Evidence location must be a directory, .tar.gz archive, or http(s) URL (got '$evidence')"
    fi
}

require_local_evidence_dir() {
    local evidence_dir="$1"
    local transcript="${evidence_dir}/transcript.txt"
    local results="${evidence_dir}/results.tsv"

    [[ -f "$transcript" && ! -L "$transcript" && -s "$transcript" ]] || fail "Evidence directory must include a non-empty regular transcript.txt (got '$evidence_dir')"
    [[ -f "$results" && ! -L "$results" && -s "$results" ]] || fail "Evidence directory must include a non-empty regular results.tsv (got '$evidence_dir')"
    require_file_sha256_matches_field "Transcript SHA-256" "$transcript"
    require_file_sha256_matches_field "Results SHA-256" "$results"

    if ! awk -F '\t' '
        NF != 2 || $2 !~ /^[0-9]+$/ || $2 != 0 {
            exit 1
        }
    ' "$results"; then
        fail "Evidence results.tsv must contain exactly label/status fields with zero command statuses"
    fi

    require_local_evidence_results "$results"
}

require_safe_tar_entry() {
    local entry="$1"

    case "$entry" in
        "" | /* | ../* | */../* | */.. | ..)
            fail "Evidence archive contains an unsafe path: $entry"
            ;;
    esac
}

require_local_evidence_archive() {
    local archive="$1"
    local extract_dir
    local entry
    local entry_list
    local verbose_list
    local line
    local entry_type

    [[ -f "$archive" && ! -L "$archive" && -s "$archive" ]] || fail "Evidence archive must be a non-empty regular file (got '$archive')"

    entry_list="$(mktemp "${TMPDIR:-/tmp}/roomy-evidence-list.XXXXXX")"
    track_temp_path "$entry_list"
    verbose_list="$(mktemp "${TMPDIR:-/tmp}/roomy-evidence-verbose.XXXXXX")"
    track_temp_path "$verbose_list"
    tar -tzf "$archive" > "$entry_list"
    tar -tzvf "$archive" > "$verbose_list"

    while IFS= read -r entry; do
        require_safe_tar_entry "$entry"
    done < "$entry_list"

    while IFS= read -r line; do
        entry_type="${line:0:1}"
        case "$entry_type" in
            - | d)
                ;;
            *)
                fail "Evidence archive contains an unsupported entry type: $line"
                ;;
        esac
    done < "$verbose_list"

    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/roomy-evidence.XXXXXX")"
    track_temp_path "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"
    require_local_evidence_dir "$extract_dir"
}

require_result_label() {
    local results="$1"
    local pattern="$2"
    local label="$3"

    if awk -F '\t' -v pattern="$pattern" '
        $1 ~ pattern && $2 == 0 {
            found = 1
        }
        END {
            exit found ? 0 : 1
        }
    ' "$results"; then
        return 0
    fi

    fail "Evidence results.tsv is missing required passing command: $label"
}

require_local_evidence_results() {
    local results="$1"

    require_result_label "$results" '^release preflight$' "release preflight"
    require_result_label "$results" '^release version matches tag$' "release version matches tag"
    require_result_label "$results" '^go tests$' "go tests"
    require_result_label "$results" '^shell and integration tests without API$' "shell and integration tests without API"
    require_result_label "$results" '^API contract tests$' "API contract tests"
    require_result_label "$results" '^brew update$' "brew update"
    require_result_label "$results" '^brew install .+' "brew install <formula>"
    require_result_label "$results" '^homebrew roomy version$' "homebrew roomy version"
    require_result_label "$results" '^homebrew clean dry-run$' "homebrew clean dry-run"
    require_result_label "$results" '^homebrew uninstall dry-run$' "homebrew uninstall dry-run"
    require_result_label "$results" '^homebrew purge dry-run$' "homebrew purge dry-run"
    require_result_label "$results" '^homebrew installer dry-run$' "homebrew installer dry-run"
    require_result_label "$results" '^homebrew optimize dry-run$' "homebrew optimize dry-run"
    require_result_label "$results" '^homebrew status$' "homebrew status"
    require_result_label "$results" '^homebrew analyze json$' "homebrew analyze json"
    require_result_label "$results" '^brew uninstall roomy after drill$' "brew uninstall roomy after drill"
    require_result_label "$results" '^download install script$' "download install script"
    require_result_label "$results" '^download previous install script$' "download previous install script"
    require_result_label "$results" '^script install target release$' "script install target release"
    require_result_label "$results" '^script roomy version$' "script roomy version"
    require_result_label "$results" '^script clean dry-run$' "script clean dry-run"
    require_result_label "$results" '^script uninstall dry-run$' "script uninstall dry-run"
    require_result_label "$results" '^script update dry-run$' "script update dry-run"
    require_result_label "$results" '^script remove dry-run$' "script remove dry-run"
    require_result_label "$results" '^script remove after drill$' "script remove after drill"
    require_result_label "$results" '^install previous stable for update drill$' "install previous stable for update drill"
    require_result_label "$results" '^previous stable roomy version$' "previous stable roomy version"
    require_result_label "$results" '^update from previous stable with target installer$' "update from previous stable with target installer"
    require_result_label "$results" '^updated roomy version$' "updated roomy version"
    require_result_label "$results" '^remove dry-run after update$' "remove dry-run after update"
    require_result_label "$results" '^remove after update drill$' "remove after update drill"
    require_result_label "$results" '^reinstall through Homebrew after remove$' "reinstall through Homebrew after remove"
    require_result_label "$results" '^homebrew reinstall version$' "homebrew reinstall version"
    require_result_label "$results" '^cleanup Homebrew reinstall$' "cleanup Homebrew reinstall"
}

if [[ -n "$tag" ]]; then
    require_release_tag_value "$tag"
    require_field_equals "Release tag" "$tag"
else
    require_field "Release tag"
    require_release_tag_value "$(field_value "Release tag")"
fi

record_commit="$(field_value "Commit SHA")"
require_commit_value "Commit SHA" "$record_commit"
if [[ -n "$expected_commit" ]]; then
    require_commit_value "--commit" "$expected_commit"
    [[ "$record_commit" == "$expected_commit" ]] || fail "Commit SHA must match expected commit $expected_commit (got '$record_commit')"
fi
require_field_match "Drill date" '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' "Drill date must use YYYY-MM-DD"
require_field "Tester"
require_field_metadata_safe "Tester"
require_field "macOS version"
require_field_metadata_safe "macOS version"
require_field_match "CPU architecture" '^(arm64|x86_64)$' "CPU architecture must be arm64 or x86_64"
require_field_equals "Fresh environment" "yes"
require_field_equals "Existing Roomy state" "absent"
require_field_match "Full Disk Access" '^(available|not-available)$' "Full Disk Access must be available or not-available"
require_field_match "Admin privileges" '^(available|not-available)$' "Admin privileges must be available or not-available"
require_field_equals "Network access" "available"

require_gate_passed "Preflight"
require_gate_passed "Homebrew install"
require_gate_passed "Script install"
require_gate_passed "Checksum verification"
require_gate_passed "First-run dry-runs"
require_gate_passed "Update behavior"
require_gate_passed "Rollback/remove/reinstall"

require_sha256_field "Transcript SHA-256"
require_sha256_field "Results SHA-256"
require_evidence_location
require_field_equals "Launch decision" "go"
require_field "Decision notes"

printf 'Clean-machine drill record passed: %s\n' "$record"
