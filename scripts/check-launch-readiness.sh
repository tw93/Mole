#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    printf 'error: launch readiness: %s\n' "$*" >&2
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

require_order() {
    local file="$1"
    local before="$2"
    local after="$3"
    local label="$4"
    local before_line
    local after_line

    require_file "$file"
    before_line="$(grep -En -- "$before" "$file" | head -n 1 | cut -d: -f1 || true)"
    after_line="$(grep -En -- "$after" "$file" | head -n 1 | cut -d: -f1 || true)"
    [[ -n "$before_line" && -n "$after_line" ]] || fail "$label ($file)"
    ((before_line < after_line)) || fail "$label ($file)"
}

check_anchor() {
    local label="$1"
    local file="$2"
    local pattern="$3"

    require_match "$file" "$pattern" "missing safety regression anchor: $label"
    printf '  ok: %s\n' "$label"
}

printf 'Checking launch scope lock...\n'
require_match "LAUNCH_READINESS.md" '^Production launch scope: CLI$' "production launch scope must stay explicit"
require_match "LAUNCH_READINESS.md" 'RoomyUI is excluded from production release' "RoomyUI exclusion must stay explicit"
require_match "LAUNCH_READINESS.md" 'Scope-change rule:' "scope-change rule must be documented"
require_absent ".github/workflows/release.yml" 'RoomyUI\.app|Roomy\.dmg|\.dmg|notarization\.zip' "release workflow must not publish RoomyUI artifacts while launch scope is CLI-only"
printf 'Launch scope lock passed.\n\n'

printf 'Checking launch goal runbooks...\n'
require_match "LAUNCH_READINESS.md" '^## Goal 2: Clean-Machine CLI Release Drill$' "clean-machine CLI drill goal must be documented"
require_match "LAUNCH_READINESS.md" '^## Goal 3: Release Integrity Manifest$' "release integrity goal must be documented"
require_match "LAUNCH_READINESS.md" 'release must remain a draft until release assets, checksums, and attestations exist' "release integrity goal must keep assets draft until checksums exist"
require_match "LAUNCH_READINESS.md" 'staged as a prerelease so Homebrew and install-script URLs are publicly downloadable before formula publication and the clean-machine drill' "release integrity goal must allow only prerelease staging before install-channel drill"
require_match "LAUNCH_READINESS.md" '^## Goal 5: Destructive Workflow UX Gate$' "destructive workflow UX gate must be documented"
require_match "LAUNCH_READINESS.md" '^## Goal 6: Roomy API Stability Contract$' "API stability goal must be documented"
require_match "LAUNCH_READINESS.md" '^## Goal 7: RoomyUI Release Decision$' "RoomyUI release decision goal must be documented"
require_match "LAUNCH_READINESS.md" '^## Goal 8: Performance Baselines$' "performance baseline goal must be documented"
require_match "LAUNCH_READINESS.md" '^## Goal 9: Sales Launch Surface$' "sales launch surface goal must be documented"

require_match "docs/launch/clean-machine-cli-drill.md" '^# Clean-Machine CLI Release Drill$' "clean-machine drill runbook must exist"
require_match "docs/launch/clean-machine-cli-drill.md" 'check-clean-machine-drill-record\.sh --tag <TAG>' "clean-machine drill must name the record verifier"
require_match "docs/launch/clean-machine-cli-drill.md" 'run-clean-machine-cli-drill\.sh --tag <TAG> --previous-tag <PREVIOUS_TAG>' "clean-machine drill must name the automated drill runner"
require_match "docs/launch/clean-machine-cli-drill.md" '--fresh-environment' "clean-machine drill runner must require explicit fresh-environment attestation"
require_match "docs/launch/clean-machine-cli-drill.md" 'Fresh Homebrew Install' "clean-machine drill must cover Homebrew install"
require_match "docs/launch/clean-machine-cli-drill.md" 'Fresh Script Install' "clean-machine drill must cover script install"
require_match "docs/launch/clean-machine-cli-drill.md" 'Update And Rollback/Remove' "clean-machine drill must cover update and rollback/remove"
require_match "docs/launch/clean-machine-cli-drill.md" 'checksum verification' "clean-machine drill must cover checksum verification"
require_match "docs/launch/clean-machine-cli-drill.md" '[.]tar[.]gz' "clean-machine drill must support archived evidence verification"
require_match "docs/launch/clean-machine-cli-drill.md" 'transcript[.]txt' "clean-machine drill must require transcript evidence for local evidence"
require_match "docs/launch/clean-machine-cli-drill.md" 'results[.]tsv' "clean-machine drill must require command status evidence for local evidence"
require_match "docs/launch/clean-machine-cli-drill.md" 'Transcript SHA-256' "clean-machine drill must bind records to transcript evidence digests"
require_match "docs/launch/clean-machine-cli-drill.md" 'Results SHA-256' "clean-machine drill must bind records to results evidence digests"
require_match "docs/launch/clean-machine-cli-drill.md" 'core drill command labels' "clean-machine drill must require generated command labels in local evidence"
require_match "docs/launch/clean-machine-cli-drill.md" 'absolute or parent-traversal paths' "clean-machine drill must reject unsafe local evidence archive entries"
require_match "docs/launch/clean-machine-cli-drill.md" 'symlinks, hardlinks, devices' "clean-machine drill must reject special entries in evidence archives"
require_match "docs/launch/clean-machine-cli-drill.md" '--evidence <archive>' "clean-machine drill must document evidence override for downloaded assets"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" '^# Clean-Machine CLI Drill Record: <TAG>$' "clean-machine drill record template must exist"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" '[.]tar[.]gz' "clean-machine drill record template must cover archived evidence"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" 'transcript[.]txt' "clean-machine drill record template must require transcript evidence"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" 'results[.]tsv' "clean-machine drill record template must require command status evidence"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" 'Transcript SHA-256:' "clean-machine drill record template must include transcript digest field"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" 'Results SHA-256:' "clean-machine drill record template must include results digest field"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" 'generated drill command labels' "clean-machine drill record template must require generated command labels"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" 'symlinks, hardlinks' "clean-machine drill record template must reject special archive entries"
require_match "docs/launch/clean-machine-cli-drill-record-template.md" '--evidence <archive>' "clean-machine drill record template must document evidence override"
require_match "docs/launch/records/README.md" '^# Clean-Machine Drill Records$' "clean-machine drill records directory must be documented"
require_match "docs/launch/go-no-go-audit.md" '^# Launch Go/No-Go Audit$' "launch go/no-go audit checklist must exist"
require_match "docs/launch/go-no-go-audit.md" 'scripts/check-clean-machine-drill-record\.sh --tag <TAG>' "go/no-go audit must require tag-specific clean-machine validation"
require_match "docs/launch/go-no-go-audit.md" 'scripts/check-public-release\.sh --tag <TAG> --full' "go/no-go audit must require consolidated public release gate"
require_match "docs/launch/go-no-go-audit.md" 'npm run site:check' "go/no-go audit must require sales page smoke checks"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_gate_passed "Homebrew install"' "clean-machine drill record verifier must cover Homebrew install"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_gate_passed "Script install"' "clean-machine drill record verifier must cover script install"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_gate_passed "Update behavior"' "clean-machine drill record verifier must cover update behavior"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_gate_passed "Rollback/remove/reinstall"' "clean-machine drill record verifier must cover rollback/remove"
require_match "scripts/check-clean-machine-drill-record.sh" 'transcript[.]txt' "clean-machine drill record verifier must require local transcript evidence"
require_match "scripts/check-clean-machine-drill-record.sh" 'results[.]tsv' "clean-machine drill record verifier must require local command status evidence"
require_match "scripts/check-clean-machine-drill-record.sh" '--evidence' "clean-machine drill record verifier must support explicit evidence override"
require_match "scripts/check-clean-machine-drill-record.sh" 'clean-machine-drill-%s-evidence[.]tar[.]gz' "clean-machine drill record verifier must require tag-specific release evidence URLs"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_remote_evidence_archive' "clean-machine drill record verifier must download canonical remote evidence archives"
require_match "scripts/check-clean-machine-drill-record.sh" 'exactly label/status fields with zero command statuses' "clean-machine drill record verifier must reject malformed or failed local evidence statuses"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_local_evidence_archive' "clean-machine drill record verifier must inspect local evidence archives"
require_match "scripts/check-clean-machine-drill-record.sh" 'Evidence location must be a directory, [.][t]ar[.]gz archive, or http' "clean-machine drill record verifier must reject unsupported local evidence files"
require_match "scripts/check-clean-machine-drill-record.sh" 'unsafe path' "clean-machine drill record verifier must reject unsafe archive entries"
require_match "scripts/check-clean-machine-drill-record.sh" 'unsupported entry type' "clean-machine drill record verifier must reject special archive entries"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_result_label' "clean-machine drill record verifier must require generated command labels"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_field_metadata_safe "Tester"' "clean-machine drill record verifier must reject unsafe tester metadata"
require_match "scripts/check-clean-machine-drill-record.sh" 'Evidence location must not contain tab or carriage-return characters' "clean-machine drill record verifier must reject unsafe evidence location metadata"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_sha256_field "Transcript SHA-256"' "clean-machine drill record verifier must require transcript digest field"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_sha256_field "Results SHA-256"' "clean-machine drill record verifier must require results digest field"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_file_sha256_matches_field "Transcript SHA-256"' "clean-machine drill record verifier must match transcript evidence digest"
require_match "scripts/check-clean-machine-drill-record.sh" 'require_file_sha256_matches_field "Results SHA-256"' "clean-machine drill record verifier must match results evidence digest"
require_match "scripts/check-clean-machine-drill-record.sh" 'script install target release' "clean-machine drill record verifier must require script install evidence"
require_match "scripts/check-clean-machine-drill-record.sh" 'update from previous stable with target installer' "clean-machine drill record verifier must require update evidence"
require_match "scripts/check-clean-machine-drill-record.sh" 'reinstall through Homebrew after remove' "clean-machine drill record verifier must require reinstall evidence"
require_match "scripts/run-clean-machine-cli-drill.sh" 'provide --previous-tag to validate an actual update path' "automated clean-machine drill must require a previous tag"
require_match "scripts/run-clean-machine-cli-drill.sh" 'pass --fresh-environment after confirming this is a clean macOS user' "automated clean-machine drill must require fresh-environment attestation"
require_match "scripts/run-clean-machine-cli-drill.sh" '--homebrew-tap' "automated clean-machine drill must support explicit release tap validation"
require_match "scripts/run-clean-machine-cli-drill.sh" '--homebrew-package' "automated clean-machine drill must support explicit Homebrew formula validation"
require_match "scripts/run-clean-machine-cli-drill.sh" "check-release-version[.]sh --tag \"\\\$tag\"" "automated clean-machine drill must verify tag/version match"
require_match "scripts/run-clean-machine-cli-drill.sh" 'raw[.]githubusercontent[.]com/tw93/roomy/\$\{tag\}/install[.]sh' "automated clean-machine drill must download the tag-specific install script"
require_match "scripts/run-clean-machine-cli-drill.sh" "ROOMY_VERSION=\"\\\$previous_tag\"" "automated clean-machine drill must exercise previous stable update"
require_match "scripts/run-clean-machine-cli-drill.sh" 'raw[.]githubusercontent[.]com/tw93/roomy/\$\{previous_tag\}/install[.]sh' "automated clean-machine drill must download the previous stable installer"
require_match "scripts/run-clean-machine-cli-drill.sh" 'run_version_command\(\)' "automated clean-machine drill must assert installed versions"
require_match "scripts/run-clean-machine-cli-drill.sh" "run_version_command \"homebrew roomy version\" \"\\\$tag\" roomy --version" "automated clean-machine drill must assert Homebrew installs the release tag"
require_match "scripts/run-clean-machine-cli-drill.sh" "run_version_command \"updated roomy version\" \"\\\$tag\" roomy --version" "automated clean-machine drill must assert update reaches the release tag"
require_match "scripts/run-clean-machine-cli-drill.sh" 'detect_full_disk_access\(\)' "automated clean-machine drill must record observed Full Disk Access"
require_match "scripts/run-clean-machine-cli-drill.sh" 'detect_admin_privileges\(\)' "automated clean-machine drill must record observed admin privileges"
require_match "scripts/run-clean-machine-cli-drill.sh" 'detect_network_access\(\)' "automated clean-machine drill must record observed network access"
require_match "scripts/run-clean-machine-cli-drill.sh" "require_safe_metadata_value \"Tester\" \"\\\$tester\"" "automated clean-machine drill must reject unsafe tester metadata"
require_match "scripts/run-clean-machine-cli-drill.sh" "require_safe_metadata_value \"Evidence location\" \"\\\$evidence_location\"" "automated clean-machine drill must reject unsafe evidence location metadata"
require_match "scripts/run-clean-machine-cli-drill.sh" "require_safe_output_path \"Record output\" \"\\\$record\"" "automated clean-machine drill must reject unsafe record output paths"
require_match "scripts/run-clean-machine-cli-drill.sh" "require_safe_output_path \"Evidence output directory\" \"\\\$evidence_dir\"" "automated clean-machine drill must reject unsafe evidence output paths"
require_match "scripts/run-clean-machine-cli-drill.sh" 'Transcript SHA-256: \$\{transcript_sha\}' "automated clean-machine drill must write transcript evidence digest"
require_match "scripts/run-clean-machine-cli-drill.sh" 'Results SHA-256: \$\{results_sha\}' "automated clean-machine drill must write results evidence digest"
require_match "scripts/run-clean-machine-cli-drill.sh" "check-clean-machine-drill-record[.]sh --tag \"\\\$tag\" --record \"\\\$record\" --evidence \"\\\$evidence_dir\"" "automated clean-machine drill must validate generated local evidence before upload"
require_match "scripts/check-release-version.sh" 'VERSION declared by the Roomy CLI' "release version verifier must exist"
require_match "scripts/check-release-version.sh" 'already exists at' "release version verifier must reject reused tags on different commits"
require_match "scripts/check-public-release.sh" "version_args=\\(--tag \"\\\$tag\"\\)" "public release gate must build tag/version arguments"
require_match "scripts/check-public-release.sh" "check-release-version[.]sh \"\\\$\\{version_args\\[@\\]\\}\"" "public release gate must require tag/version match"
require_match "scripts/check-public-release.sh" '--roomy' "public release gate must support testable version override"
require_match "scripts/check-public-release.sh" '--evidence' "public release gate must support explicit clean-machine evidence override"
require_match "scripts/check-public-release.sh" "check-clean-machine-drill-record[.]sh \"\\\$\\{record_args\\[@\\]\\}\"" "public release gate must require clean-machine drill record"
require_match "scripts/check-public-release.sh" "record_args[+]\\=\\(--evidence \"\\\$evidence\"\\)" "public release gate must pass explicit clean-machine evidence to the verifier"
require_match "scripts/check-public-release.sh" "record_args[+]\\=\\(--commit \"\\\$head_sha\"\\)" "public release gate must require the drill record commit to match the gated commit"
require_match "scripts/check-public-release.sh" 'worktree has uncommitted or untracked source changes' "public release gate must reject dirty source worktrees by default"
require_match "scripts/check-public-release.sh" ':\(exclude\)node_modules/\*\*' "public release gate must tolerate CI-installed node_modules"
require_match ".github/workflows/release.yml" 'NOTES_PATH="\$\{PWD\}/../source/docs/release/notes/\$\{TAG\}\.md"' "release workflow must read curated notes from isolated source checkout"
require_match ".github/workflows/release.yml" 'Curated release notes are missing or empty' "release workflow must fail clearly when curated notes are missing"
require_match ".github/workflows/release.yml" "check-release-notes[.]sh --tag \"\\\$TAG\" --notes \"\\\$NOTES_PATH\"" "release workflow must validate the exact release notes it publishes"
require_match ".github/workflows/release.yml" 'Install public release test tools' "release workflow must install full-gate shell test tools"
require_match ".github/workflows/release.yml" 'brew install bats-core shellcheck coreutils parallel' "release workflow must install Bats, ShellCheck, coreutils, and parallel for full gate"
require_match ".github/workflows/release.yml" 'go-version-file: go\.mod' "release workflow must set up Go before the full release gate"
require_match ".github/workflows/release.yml" "check-public-release[.]sh --tag \"\\\$\\{GITHUB_REF_NAME\\}\" --full --skip-clean-machine" "release workflow must run full source gate before draft release"
require_match ".github/workflows/release.yml" 'Validate release repository' "release workflow must validate canonical release repository before Homebrew publishing"
require_match ".github/workflows/release.yml" '\$\{GITHUB_REPOSITORY,,\}.*tw93/roomy' "release workflow must restrict Homebrew publishing to canonical repository"
require_match ".github/workflows/release.yml" 'Validate formula publishing secrets' "release workflow must validate Homebrew publishing secrets before public staging"
require_order ".github/workflows/release.yml" 'Validate release repository' 'Validate formula publishing secrets' "release workflow must validate canonical repository before publishing secrets"
require_match ".github/workflows/release.yml" 'Stage GitHub prerelease for install-channel drill' "release workflow must stage a public prerelease before install-channel validation"
require_order ".github/workflows/release.yml" 'Validate formula publishing secrets' 'Stage GitHub prerelease for install-channel drill' "release workflow must validate publishing secrets before prerelease staging"
require_order ".github/workflows/release.yml" 'Stage GitHub prerelease for install-channel drill' 'Update Homebrew formula [(]Personal Tap[)]' "release workflow must stage prerelease before formula publication"
require_match ".github/workflows/release.yml" 'Install Channel Drill And Publish' "release workflow must run install-channel drill before stable publication"
require_match ".github/workflows/release.yml" 'run-clean-machine-cli-drill[.]sh' "release workflow must run the automated clean-machine drill"
require_match ".github/workflows/release.yml" '--homebrew-package tw93/tap/roomy' "release workflow must validate the release tap formula before stable publication"
require_match ".github/workflows/release.yml" 'https://github[.]com/tw93/roomy/releases/download/\$\{TAG\}/\$\{evidence_asset\}' "release workflow must write canonical clean-machine evidence asset URLs"
require_match "scripts/run-clean-machine-cli-drill.sh" "run_command \"update from previous stable with target installer\" env ROOMY_VERSION=\"\\\$tag\" bash \"\\\$installer\" --update" "clean-machine drill must update to the staged release tag deterministically"
require_match ".github/workflows/release.yml" 'check-clean-machine-drill-record[.]sh --tag "\$\{\{ steps[.]previous_tag[.]outputs[.]tag \}\}" --record "\$\{\{ steps[.]drill[.]outputs[.]record_path \}\}" --commit "\$\{GITHUB_SHA\}" --evidence "\$\{\{ steps[.]drill[.]outputs[.]evidence_dir \}\}"' "release workflow must validate generated clean-machine record and local evidence against the release commit"
require_match ".github/workflows/release.yml" 'check-public-release[.]sh --tag "\$\{TAG\}" --final --record "\$\{RECORD_PATH\}" --evidence "\$\{EVIDENCE_PATH\}"' "release workflow must run final public gate with generated clean-machine record and evidence"
require_match ".github/workflows/release.yml" 'Verify clean-machine release assets' "release workflow must verify clean-machine assets before stable promotion"
require_match ".github/workflows/release.yml" "gh release download \"\\\$TAG\"" "release workflow must download uploaded clean-machine assets before stable promotion"
require_match ".github/workflows/release.yml" '--evidence "\$\{asset_dir\}/\$\{release_evidence\}"' "release workflow must validate uploaded clean-machine evidence archive contents"
require_match ".github/workflows/release.yml" 'expected_assets=\(' "release workflow must verify an explicit final release asset allowlist before stable promotion"
require_match ".github/workflows/release.yml" 'Unexpected release asset before stable promotion:' "release workflow must reject unexpected uploaded release assets before stable promotion"
require_match ".github/workflows/release.yml" 'Missing release asset before stable promotion:' "release workflow must reject missing uploaded release assets before stable promotion"
require_match ".github/workflows/release.yml" 'grep -Fxq "Tag: \$\{TAG\}"' "release workflow must verify the uploaded release manifest tag before stable promotion"
require_match ".github/workflows/release.yml" 'grep -Fxq "Commit: \$\{GITHUB_SHA\}"' "release workflow must verify the uploaded release manifest commit before stable promotion"
require_match ".github/workflows/release.yml" 'Release body does not start with curated' "release workflow must verify the uploaded release body starts with curated notes"
require_match ".github/workflows/release.yml" "check-release-notes[.]sh --tag \"\\\$TAG\" --notes \"\\\$\\{asset_dir\\}/RELEASE_BODY[.]md\"" "release workflow must revalidate the uploaded release body before stable promotion"
require_match ".github/workflows/release.yml" 'grep -Fxq "# Release Manifest: \$\{TAG\}"' "release workflow must verify the uploaded release body includes the manifest"
require_match ".github/workflows/release.yml" 'Release body manifest commit does not match' "release workflow must verify the release body manifest commit before stable promotion"
require_match ".github/workflows/release.yml" 'sha256sum --check SHA256SUMS' "release workflow must verify uploaded release asset checksums before stable promotion"
require_match ".github/workflows/release.yml" 'manifest_value[(][)]' "release workflow must parse uploaded manifest values before stable promotion"
require_match ".github/workflows/release.yml" 'Release manifest source archive checksum does not match' "release workflow must verify uploaded manifest source archive checksum before stable promotion"
require_match ".github/workflows/release.yml" 'require_manifest_sha "analyze-darwin-amd64 SHA-256" "analyze-darwin-amd64"' "release workflow must compare manifest helper checksums with SHA256SUMS"
require_match ".github/workflows/release.yml" 'Release manifest checksum for \$\{file\} does not match SHA256SUMS' "release workflow must reject manifest checksum mismatches before stable promotion"
require_order ".github/workflows/release.yml" 'Verify clean-machine release assets' 'Promote GitHub release to stable latest' "release workflow must verify drill assets before stable/latest promotion"
require_match ".github/workflows/release.yml" 'Create Draft Release' "release workflow must create a draft release first"
require_match ".github/workflows/release.yml" 'draft: true' "release workflow must create release assets in draft state first"
require_match ".github/workflows/release.yml" 'expected_release_files=\(' "release workflow must checksum an explicit release asset allowlist"
require_match ".github/workflows/release.yml" 'Unexpected release asset:' "release workflow must reject unexpected release artifact files"
require_match ".github/workflows/release.yml" 'Missing expected release asset:' "release workflow must reject missing release artifact files"
require_match ".github/workflows/release.yml" 'files: \|' "release workflow must upload an explicit release asset list"
require_match ".github/workflows/release.yml" 'bin/RELEASE_MANIFEST[.]md' "release workflow explicit asset list must include release manifest"
require_match ".github/workflows/release.yml" 'bin/RELEASE_BODY[.]md' "release workflow explicit asset list must include release body"
require_match ".github/workflows/release.yml" 'bin/analyze-darwin-amd64' "release workflow explicit asset list must include amd64 analyzer"
require_match ".github/workflows/release.yml" 'bin/analyze-darwin-arm64' "release workflow explicit asset list must include arm64 analyzer"
require_match ".github/workflows/release.yml" 'bin/binaries-darwin-arm64[.]tar[.]gz' "release workflow explicit asset list must include Homebrew tarballs"
require_absent ".github/workflows/release.yml" 'bin/analyze-darwin-\*' "release workflow must not attest broad analyzer globs"
require_absent ".github/workflows/release.yml" 'bin/status-darwin-\*' "release workflow must not attest broad status globs"
require_absent ".github/workflows/release.yml" 'bin/binaries-darwin-\*[.]tar[.]gz' "release workflow must not attest broad tarball globs"
require_absent ".github/workflows/release.yml" 'files: bin/\*' "release workflow must not upload broad bin glob release assets"
require_match ".github/workflows/release.yml" 'gh release download "\$\{TAG\}"' "formula job must read checksums from the staged release"
require_match ".github/workflows/release.yml" 'cleanup_release_asset_dir' "formula job must clean temporary release checksum downloads"
require_match ".github/workflows/release.yml" 'Downloaded release checksums are missing or empty' "formula job must reject missing downloaded release checksums"
require_absent ".github/workflows/release.yml" '/tmp/SHA256SUMS' "formula job must not use a shared global checksum temp file"
require_match ".github/workflows/release.yml" 'tap_checkout_dir="\$[(]mktemp -d[)]"' "formula job must use a job-owned temporary tap checkout"
require_match ".github/workflows/release.yml" 'temporary Homebrew tap checkout directory created by mktemp' "formula job must clean temporary tap checkout"
require_absent ".github/workflows/release.yml" '/tmp/homebrew-tap' "formula job must not use a shared global Homebrew tap checkout"
require_match ".github/workflows/release.yml" 'SOURCE_SHA=\$\(curl -fsSL "https://github\.com/\$\{GITHUB_REPOSITORY\}/archive/refs/tags/\$\{TAG\}\.tar\.gz"' "formula job must compute source checksum from the repository being released"
require_match ".github/workflows/release.yml" 'gh release edit "\$\{TAG\}"' "release workflow must stage the draft as a prerelease before install-channel validation"
require_match ".github/workflows/release.yml" '--draft=false' "release workflow must explicitly publish the staged prerelease before install-channel validation"
require_match ".github/workflows/release.yml" '--prerelease=false' "release workflow must clear prerelease status only after install-channel drill"
require_absent ".github/workflows/release.yml" 'continue-on-error: true' "release workflow must not ignore release or formula update failures"
require_absent ".github/workflows/release.yml" '--allow-dirty' "release workflow must not bypass clean worktree gate"

require_match "docs/release/release-integrity.md" '^# Release Integrity$' "release integrity runbook must exist"
require_match "docs/release/release-integrity.md" 'Required Release Manifest' "release integrity runbook must include manifest template"
require_match "docs/release/release-integrity.md" 'SHA-256' "release integrity runbook must cover checksums"
require_match "docs/release/release-integrity.md" 'artifact attestations' "release integrity runbook must cover attestations"
require_match "docs/release/release-integrity.md" 'Homebrew' "release integrity runbook must cover Homebrew verification"
require_match "docs/release/release-integrity.md" 'stays in draft state until release assets, checksums, and attestations exist' "release integrity runbook must require draft publication gate"
require_match "docs/release/release-integrity.md" 'staged as a prerelease before formula publication' "release integrity runbook must document prerelease install-channel staging"
require_match "docs/release/release-integrity.md" 'leave the release as a prerelease for diagnosis so Homebrew URLs remain publicly downloadable' "release integrity runbook must preserve tap asset availability on drill failure"
require_match "docs/release/release-integrity.md" 'Homebrew core update is opened successfully' "release integrity runbook must require Homebrew core update success"
require_match "docs/release/release-integrity.md" 'rejects malformed release tags and non-SHA-256 checksum inputs' "release integrity runbook must require formula input validation"
require_match "docs/release/release-integrity.md" 'PAT_TOKEN' "release integrity runbook must require personal tap publishing secret validation"
require_match "docs/release/release-integrity.md" 'HOMEBREW_GITHUB_API_TOKEN' "release integrity runbook must require Homebrew core publishing secret validation"
require_match "docs/release/release-integrity.md" 'clean-machine-drill-<TAG>-evidence\.tar\.gz' "release integrity runbook must require clean-machine evidence release asset"
require_match "docs/release/release-integrity.md" 'downloads the uploaded clean-machine record and evidence archive' "release integrity runbook must require downloaded evidence asset validation"
require_match "scripts/update_homebrew_tap_formula.sh" 'Invalid tag:' "Homebrew tap updater must validate release tag input"
require_match "scripts/update_homebrew_tap_formula.sh" 'Invalid SHA-256 checksum:' "Homebrew tap updater must validate checksum input"
require_match "scripts/update_homebrew_tap_formula.sh" 'https://github\.com/tw93/roomy/archive/refs/tags' "Homebrew tap updater must emit canonical lowercase source archive URLs"
require_match "scripts/update_homebrew_tap_formula.sh" 'https://github\.com/tw93/roomy/releases/download' "Homebrew tap updater must emit canonical lowercase binary release URLs"
require_match "install.sh" 'release_checksums_url[(][)]' "installer must download release checksum manifests"
require_match "install.sh" 'verify_release_asset_checksum[(][)]' "installer must verify downloaded release helper assets"
require_match "install.sh" 'Checksum verification failed' "installer must fail closed on checksum mismatch"
require_match "install.sh" "length\\(\\\$1\\) == 64 && \\\$1 !~ /\\[\\^0-9a-f\\]/" "installer must reject malformed SHA256SUMS digest entries"
require_match "tests/install_checksum.bats" 'checksum mismatch' "install tests must cover checksum mismatch fallback"
require_match "tests/install_checksum.bats" 'malformed SHA256SUMS digest' "install tests must cover malformed checksum entries"
require_match "tests/install_checksum.bats" 'SHA256SUMS cannot be downloaded' "install tests must cover missing checksum manifest"
require_match "docs/release/release-integrity.md" 'check-public-release\.sh --tag <TAG> --full' "release integrity runbook must require consolidated gate"
require_match "docs/release/release-integrity.md" 'check-public-release\.sh --tag <TAG> --final' "release integrity runbook must require final gate mode"
require_match "docs/release/release-integrity.md" 'check-release-version\.sh --tag <TAG>' "release integrity runbook must require tag/version match"
require_match "docs/release/release-integrity.md" 'The CLI release path does not require local `[.]env` files' "release integrity runbook must state local .env files are not required"
require_match "scripts/check-public-release.sh" '--final' "public release gate must expose final mode"
require_match "scripts/check-public-release.sh" '--final cannot be combined with --allow-dirty' "final public release gate must reject dirty release mode"
require_match "scripts/check-public-release.sh" '--final cannot be combined with --skip-site' "final public release gate must reject skipped landing checks"
require_match "scripts/check-public-release.sh" '--final cannot be combined with --skip-clean-machine' "final public release gate must reject skipped clean-machine checks"
require_match "scripts/check-public-release.sh" 'CLI release gates do not load [.]env files' "public release gate help must explain local .env files are not loaded"
require_match "scripts/check-public-release.sh" 'local [.]env files are ignored by CLI release gates' "public release gate must warn about ignored local .env files"
require_match "docs/launch/go-no-go-audit.md" 'Formula publishing secrets are validated before public staging' "go/no-go audit must require publishing secret preflight"
require_match "docs/launch/go-no-go-audit.md" 'Local `[.]env` files are not required for the CLI release path' "go/no-go audit must explain local .env files are not required"
require_match "docs/launch/go-no-go-audit.md" 'check-public-release\.sh --tag <TAG> --final' "go/no-go audit must require final gate mode"
require_match "docs/launch/go-no-go-audit.md" 'clean-machine-drill-<TAG>-evidence\.tar\.gz' "go/no-go audit must require clean-machine evidence release asset"
require_match "docs/launch/go-no-go-audit.md" 'downloaded evidence archive contents' "go/no-go audit must require downloaded evidence archive validation"
require_match "docs/launch/go-no-go-audit.md" 'Buyer-facing privacy and support docs are published' "go/no-go audit must require buyer privacy and support docs"
require_match "docs/release/release-notes-template.md" '^# Roomy <TAG> Release Notes$' "release notes template must exist"
require_match "docs/release/notes/README.md" '^# Release Notes$' "release notes directory must be documented"
require_match "scripts/check-release-notes.sh" "docs/release/notes/\\\$\\{tag\\}[.]md" "release notes verifier must use tag-specific notes by default"
require_match "scripts/check-public-release.sh" "check-release-notes[.]sh \"\\\$\\{notes_args\\[@\\]\\}\"" "public release gate must require tag-specific release notes"
require_match ".github/workflows/release.yml" 'body_path: bin/RELEASE_BODY\.md' "release workflow must publish curated notes before the manifest"
require_match ".github/workflows/release.yml" 'Personal Homebrew tap updated: gated before stable/latest promotion by update-formula job' "release manifest must state Homebrew tap publication gate"
require_match ".github/workflows/release.yml" 'Homebrew core PR/status: gated before stable/latest promotion by update-formula job' "release manifest must state Homebrew core publication gate"
require_match ".github/workflows/release.yml" 'GitHub release publication: draft until assets/checksums/attestations exist, prerelease for install-channel validation, stable/latest after install-channel-drill job' "release manifest must state GitHub release publication progression"
require_match ".github/workflows/release.yml" 'Clean-machine drill record: clean-machine-drill-\$\{TAG\}\.md uploaded before stable/latest promotion by install-channel-drill job' "release manifest must name the verified clean-machine drill record"
require_match ".github/workflows/release.yml" 'Clean-machine drill evidence: clean-machine-drill-\$\{TAG\}-evidence\.tar\.gz uploaded before stable/latest promotion by install-channel-drill job' "release manifest must name the verified clean-machine drill evidence"
require_match ".github/workflows/release.yml" 'Formula publishing secrets validated: gated before public prerelease staging by update-formula job' "release manifest must state formula publishing secret preflight gate"

require_match "docs/ux/destructive-workflows.md" '^# Destructive Workflow UX$' "destructive UX runbook must exist"
require_match "docs/ux/destructive-workflows.md" 'Preview state' "destructive UX runbook must cover preview language"
require_match "docs/ux/destructive-workflows.md" 'Protected paths' "destructive UX runbook must cover protected paths"
require_match "docs/ux/destructive-workflows.md" 'roomy remove' "destructive UX runbook must cover remove flow"
require_match "docs/ux/destructive-workflows.md" 'roomy api <domain> execute' "destructive UX runbook must cover API execution"

require_match "docs/api/stability-contract.md" '^# Roomy API Stability Contract$' "API stability runbook must exist"
require_match "docs/api/stability-contract.md" 'schema_version' "API stability runbook must cover schema versions"
require_match "docs/api/stability-contract.md" 'NDJSON' "API stability runbook must cover event streams"
require_match "docs/api/stability-contract.md" 'Execution Plan Rules' "API stability runbook must cover execution plans"
require_match "docs/api/stability-contract.md" 'tests/fixtures/api/contracts.json' "API stability runbook must name contract fixtures"

require_match "docs/macos/roomyui-release-decision.md" 'Current decision: RoomyUI is preview-only' "RoomyUI release decision must stay preview-only"
require_match "docs/macos/roomyui-release-decision.md" "Do not upload a \`\\.app\`, \`\\.dmg\`, or notarization zip" "RoomyUI decision must block app artifact publishing"
require_match "docs/macos/roomyui-release-decision.md" 'Developer ID signing' "RoomyUI decision must cover signing"
require_match "docs/macos/roomyui-release-decision.md" 'Privileged helper' "RoomyUI decision must cover helper deployment"

require_match "docs/performance/baselines.md" '^# Performance Baselines$' "performance baseline runbook must exist"
require_match "docs/performance/baselines.md" 'roomy analyze --json' "performance baseline runbook must cover analyzer traversal"
require_match "docs/performance/baselines.md" 'Regression Policy' "performance baseline runbook must include regression policy"
require_match "docs/performance/baselines.md" 'tests/performance_uninstall_scan.sh' "performance baseline runbook must name automated anchors"

require_match "docs/marketing/competitor-benchmark.md" '^# Roomy Competitor Benchmark$' "competitor benchmark must exist"
require_match "docs/marketing/competitor-benchmark.md" 'transparent, local, preview-first Mac maintenance' "competitor benchmark must state Roomy's sellable position"
require_match "PRIVACY.md" '^# Privacy$' "privacy document must exist"
require_match "PRIVACY.md" 'Roomy does not require a Roomy account, cloud cleanup engine, or telemetry' "privacy document must state local/no-telemetry posture"
require_match "PRIVACY.md" 'Do not share secrets' "privacy document must warn against sharing sensitive logs"
require_match "SUPPORT.md" '^# Support$' "support document must exist"
require_match "SUPPORT.md" 'Commercial, team, or support inquiries' "support document must include commercial support path"
require_match "README.md" 'PRIVACY[.]md' "README must link privacy guidance"
require_match "README.md" 'SUPPORT[.]md' "README must link support guidance"
require_match "site/README.md" '^# Roomy Landing Page$' "landing page README must exist"
require_match "site/index.html" '<h1 id="hero-title">Roomy</h1>' "landing page must lead with Roomy as the product"
require_match "site/index.html" 'The production product today is the command-line tool' "landing page must sell the supported CLI product"
require_match "site/index.html" 'RoomyUI remains a preview' "landing page must not imply RoomyUI is production-ready"
require_match "site/index.html" 'PRIVACY[.]md' "landing page must link privacy guidance"
require_match "site/index.html" 'SUPPORT[.]md' "landing page must link support guidance"
require_match "site/index.html" 'assets/roomy-demo\.mp4' "landing page must embed generated demo video"
require_match "site/scripts/check-site.mjs" 'expectedTitle: "Roomy"' "landing smoke check must name the hero product"
require_match "site/scripts/check-site.mjs" 'h1Text !== sitePage[.]expectedTitle' "landing smoke check must verify the hero product name"
require_match "site/scripts/check-site.mjs" 'sectionsPresent' "landing smoke check must verify required sections"
require_match "site/scripts/check-site.mjs" 'overflow > 2' "landing smoke check must reject horizontal overflow"
require_match "package.json" '"site:check": "node site/scripts/check-site.mjs"' "package scripts must expose landing smoke check"
require_match ".github/workflows/test.yml" 'npm run site:check' "CI must run landing page smoke checks"
require_match "scripts/check-public-release.sh" 'npm run site:check' "public release gate must run landing page smoke checks before publishing"
require_match ".github/workflows/release.yml" 'npx playwright install chromium' "release workflow must install browser for landing page smoke checks"
printf 'Launch goal runbooks passed.\n\n'

printf 'Checking safety regression matrix...\n'
require_match "LAUNCH_READINESS.md" '^## Goal 4: Safety Regression Matrix$' "safety regression matrix must be documented"
require_match "LAUNCH_READINESS.md" 'Safety gate: every destructive command must keep dry-run, protected-path, path traversal/symlink, sudo-boundary, and restore/logging coverage\.' "safety gate must be documented"

check_anchor "clean dry-run" "tests/clean_core.bats" 'roomy clean --dry-run'
check_anchor "uninstall dry-run" "tests/api_contract.test.mjs" 'const uninstallPlan'
check_anchor "optimize dry-run" "tests/optimize.bats" 'dry-run'
check_anchor "purge dry-run" "tests/purge.bats" 'roomy purge: accepts --dry-run flag'
check_anchor "installer dry-run" "tests/installer.bats" 'installer\.sh accepts --dry-run option'
check_anchor "remove dry-run" "tests/uninstall.bats" 'remove_roomy dry-run keeps manual binaries and caches'
check_anchor "completion dry-run" "tests/completion.bats" 'completion --dry-run previews changes without writing config'
check_anchor "touchid dry-run" "tests/cli.bats" 'touchid enable --dry-run does not modify pam file'
check_anchor "update dry-run" "tests/api_contract.test.mjs" 'const updatePlan'
check_anchor "storage trash dry-run" "tests/api_contract.test.mjs" 'storage execute dry-runs Trash actions'
check_anchor "launcher dry-run" "tests/api_contract.test.mjs" 'const launcherPlan'
check_anchor "plan confirmation" "tests/api_contract.test.mjs" 'execute plan schemas reject malformed and partial plans'
check_anchor "protected paths" "tests/core_safe_functions.bats" 'rejects protected extension paths'
check_anchor "path traversal" "tests/core_safe_functions.bats" 'rejects path traversal'
check_anchor "protected symlink target" "tests/core_safe_functions.bats" 'rejects symlink to protected system path'
check_anchor "protected symlinked parent" "tests/core_safe_functions.bats" 'rejects paths through protected symlinked parents'
check_anchor "sudo symlink refusal" "tests/core_safe_functions.bats" 'safe_sudo_remove refuses symlink paths'
check_anchor "no-auth sudo boundary" "tests/core_common.bats" 'sudo helpers do not invoke sudo in no-auth test mode'
check_anchor "denied sudo boundary" "tests/optimize.bats" 'sudo-required optimize tasks short-circuit without invoking sudo when access denied'
check_anchor "brew dry-run sudo boundary" "tests/brew_uninstall.bats" 'skips brew sudo pre-auth in dry-run mode'
check_anchor "restore preview" "tests/cli.bats" 'roomy restore previews a restorable Trash item'
check_anchor "deletion audit log" "tests/file_ops_roomy_delete.bats" 'writes a tab-separated log line per call'
check_anchor "operation journal" "tests/core_common.bats" 'writes structured operation journal JSONL'
check_anchor "unsafe deletion workflow" ".github/workflows/test.yml" 'Check for unsafe deletion usage'

printf 'Safety regression matrix passed.\n'
