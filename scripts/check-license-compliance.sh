#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    printf 'error: license compliance: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local file="$1"

    [[ -f "$file" ]] || fail "missing required file: $file"
}

require_match() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    require_file "$file"
    if ! grep -Eq -- "$pattern" "$file"; then
        fail "$label ($file)"
    fi
}

require_absent() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    require_file "$file"
    if grep -Eq -- "$pattern" "$file"; then
        fail "$label ($file)"
    fi
}

printf 'Checking license and attribution compliance...\n'

require_match "LICENSE" 'GNU GENERAL PUBLIC LICENSE' "LICENSE must contain GPL-3.0 text"
require_match "LICENSE" 'Version 3, 29 June 2007' "LICENSE must be GPL version 3"
require_match "NOTICE" 'modified and renamed fork of Mole' "NOTICE must identify upstream fork status"
require_match "NOTICE" 'https://github[.]com/tw93/mole' "NOTICE must link upstream Mole"
require_match "README.md" 'GPL-3[.]0' "README must state GPL-3.0 licensing"
require_match "README.md" 'modified and renamed fork of .*Mole' "README must identify upstream fork status"
require_match "docs/legal/open-source-compliance.md" 'GPL-3[.]0-only derivative' "legal compliance doc must state conservative derivative posture"
require_match "docs/legal/open-source-compliance.md" 'not imply Roomy is endorsed by Mole or tw93' "legal compliance doc must guard endorsement claims"
require_match "docs/launch/distribution-automation.md" 'Do not run a public launch from .jake-seo-cl/Mole.' "distribution plan must block public Mole-name launch"
require_match "docs/marketing/pricing-strategy.md" 'Do not sell a proprietary Roomy CLI tier' "pricing strategy must avoid GPL-incompatible paid CLI gates"
require_match "docs/release/release-integrity.md" 'Corresponding source' "release integrity runbook must cover source availability"
require_match ".github/workflows/release.yml" 'jake-seo-cl/roomy' "release workflow must use Roomy canonical repository"
require_match "scripts/update_homebrew_tap_formula.sh" 'jake-seo-cl/roomy/releases/download' "tap updater must use Roomy release URLs"
require_match "site/pricing.html" 'same GPL CLI' "pricing page must avoid proprietary CLI feature locks"
require_absent "README.md" 'MIT License' "README must not claim MIT license"
require_absent "site/pricing.html" 'Pro unlocks|exclusive cleanup' "pricing page must not sell proprietary CLI feature gates"

printf 'License and attribution compliance passed.\n'
