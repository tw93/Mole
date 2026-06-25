#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
    cat << 'EOF'
Usage: scripts/check-release-notes.sh --tag TAG [--notes PATH]

Validates curated release notes for a public release tag. By default the notes
path is docs/release/notes/TAG.md.
EOF
}

fail() {
    printf 'error: release notes: %s\n' "$*" >&2
    exit 1
}

is_release_tag() {
    local value="$1"
    [[ "$value" =~ ^V[0-9]+[.][0-9]+[.][0-9]+$ ]]
}

require_match() {
    local pattern="$1"
    local label="$2"

    if ! grep -Eq -- "$pattern" "$notes"; then
        fail "$label"
    fi
}

require_section_body() {
    local heading="$1"
    local label="$2"

    if ! awk -v heading="$heading" '
        $0 == heading {
            found = 1
            next
        }
        found && /^##[[:space:]]/ {
            exit
        }
        found && $0 ~ /[^[:space:]]/ {
            ok = 1
        }
        END {
            exit ok ? 0 : 1
        }
    ' "$notes"; then
        fail "$label section must include release-specific content"
    fi
}

require_verification_line() {
    local keyword_pattern="$1"
    local status_pattern="$2"
    local label="$3"

    if ! awk -v keyword_pattern="$keyword_pattern" -v status_pattern="$status_pattern" '
        $0 == "## Verification" {
            found = 1
            next
        }
        found && /^##[[:space:]]/ {
            exit
        }
        found {
            line = tolower($0)
            if (line ~ keyword_pattern && line ~ status_pattern) {
                ok = 1
            }
        }
        END {
            exit ok ? 0 : 1
        }
    ' "$notes"; then
        fail "Verification section must confirm ${label}"
    fi
}

tag=""
notes=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --tag"
            tag="$1"
            ;;
        --notes)
            shift
            [[ $# -gt 0 ]] || fail "missing value for --notes"
            notes="$1"
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
is_release_tag "$tag" || fail "--tag must use V<major>.<minor>.<patch> format"

if [[ -z "$notes" ]]; then
    notes="docs/release/notes/${tag}.md"
fi

[[ -f "$notes" ]] || fail "missing notes: $notes"

if grep -Eq -- '(<[^>]+>|TODO|TBD)' "$notes"; then
    fail "notes still contain placeholders"
fi

grep -Fq "$tag" "$notes" || fail "notes must mention release tag $tag"
grep -Fxq "# Roomy ${tag} Release Notes" "$notes" || fail "notes title must be '# Roomy ${tag} Release Notes'"

require_match '^Launch scope: CLI$' "notes must declare CLI launch scope"
require_match '^## Compatibility And Scope$' "missing Compatibility And Scope section"
require_match '^## User-Visible Changes$' "missing User-Visible Changes section"
require_match '^## Safety And Destructive Workflows$' "missing Safety And Destructive Workflows section"
require_match '^## Install, Update, And Remove$' "missing Install, Update, And Remove section"
require_match '^## License And Source$' "missing License And Source section"
require_match '^## Known Limitations$' "missing Known Limitations section"
require_match '^## Verification$' "missing Verification section"
require_section_body "## Compatibility And Scope" "Compatibility And Scope"
require_section_body "## User-Visible Changes" "User-Visible Changes"
require_section_body "## Safety And Destructive Workflows" "Safety And Destructive Workflows"
require_section_body "## Install, Update, And Remove" "Install, Update, And Remove"
require_section_body "## License And Source" "License And Source"
require_section_body "## Known Limitations" "Known Limitations"
require_section_body "## Verification" "Verification"
require_match 'RoomyUI.*preview|preview.*RoomyUI' "notes must state RoomyUI preview limitation"
require_match 'GPL-3[.]0|corresponding source|NOTICE' "notes must state license/source impact"
tag_lower="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"
require_verification_line 'clean-machine|clean machine|drill record' "docs/launch/records/${tag_lower}[.]md|verified|validated|passed" "clean-machine validation source"
require_verification_line 'sha256sums|checksum' 'release manifest|generated|published|available|attached' "checksum evidence source"
require_verification_line 'attestation' 'release manifest|generated|published|available|attached' "attestation evidence source"

printf 'Release notes passed: %s\n' "$notes"
