#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-installers-home.XXXXXX")"
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
	export TERM="xterm-256color"
	export ROOMY_DEBUG=0

	# Create standard scan directories
	mkdir -p "$HOME/Downloads"
	mkdir -p "$HOME/Desktop"
	mkdir -p "$HOME/Documents"
	mkdir -p "$HOME/Public"
	mkdir -p "$HOME/Library/Downloads"

	# Clear previous test files
	rm -rf "${HOME:?}/Downloads"/*
	rm -rf "${HOME:?}/Desktop"/*
	rm -rf "${HOME:?}/Documents"/*
}

# Test arguments

@test "installer.sh rejects unknown options" {
	run "$PROJECT_ROOT/bin/installer.sh" --unknown-option

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown option"* ]]
}

@test "installer.sh accepts --dry-run option" {
	run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/installer.sh" --dry-run

	[[ "$status" -eq 0 || "$status" -eq 2 ]]
	[[ "$output" == *"DRY RUN MODE"* ]]
}

@test "delete_selected_installers honors dry-run after selected confirmation" {
	target="$HOME/Downloads/Selected.dmg"
	printf 'installer-bytes' > "$target"

	run env HOME="$HOME" TERM="xterm-256color" bash --noprofile --norc <<'EOF'
set -euo pipefail
export ROOMY_TEST_MODE=1
export ROOMY_DRY_RUN=1
source "$PROJECT_ROOT/bin/installer.sh"

INSTALLER_PATHS=("$HOME/Downloads/Selected.dmg")
INSTALLER_SIZES=(15)
ROOMY_SELECTION_RESULT="0"

delete_selected_installers <<< $'\n'
show_summary

if [[ -f "$HOME/Downloads/Selected.dmg" ]]; then
	printf 'TARGET:present\n'
else
	printf 'TARGET:missing\n'
fi
printf 'TOTAL_DELETED:%s\n' "$total_deleted"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dry run complete - no changes made"* ]]
	[[ "$output" == *"Would remove"* ]]
	[[ "$output" == *"TARGET:present"* ]]
	[[ "$output" == *"TOTAL_DELETED:1"* ]]
	[ -f "$target" ]
}

# Test scan_installers_in_path function directly

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tests using find (forced fallback by hiding fd)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test "scan_installers_in_path (fallback find): finds .dmg files" {
	touch "$HOME/Downloads/Chrome.dmg"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Chrome.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): finds multiple installer types" {
	touch "$HOME/Downloads/App1.dmg"
	touch "$HOME/Downloads/App2.pkg"
	touch "$HOME/Downloads/App3.iso"
	touch "$HOME/Downloads/App.mpkg"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"App1.dmg"* ]]
	[[ "$output" == *"App2.pkg"* ]]
	[[ "$output" == *"App3.iso"* ]]
	[[ "$output" == *"App.mpkg"* ]]
}

@test "scan_installers_in_path (fallback find): detects uppercase installer extensions" {
	touch "$HOME/Downloads/App1.DMG"
	touch "$HOME/Downloads/App2.PKG"
	touch "$HOME/Downloads/App3.ISO"
	touch "$HOME/Downloads/App4.XIP"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"App1.DMG"* ]]
	[[ "$output" == *"App2.PKG"* ]]
	[[ "$output" == *"App3.ISO"* ]]
	[[ "$output" == *"App4.XIP"* ]]
}

@test "scan_installers_in_path (fallback find): respects max depth" {
	mkdir -p "$HOME/Downloads/level1/level2/level3"
	touch "$HOME/Downloads/shallow.dmg"
	touch "$HOME/Downloads/level1/mid.dmg"
	touch "$HOME/Downloads/level1/level2/deep.dmg"
	touch "$HOME/Downloads/level1/level2/level3/too-deep.dmg"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	# Default max depth is 2
	[[ "$output" == *"shallow.dmg"* ]]
	[[ "$output" == *"mid.dmg"* ]]
	[[ "$output" == *"deep.dmg"* ]]
	[[ "$output" != *"too-deep.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): honors ROOMY_INSTALLER_SCAN_MAX_DEPTH" {
	mkdir -p "$HOME/Downloads/level1"
	touch "$HOME/Downloads/top.dmg"
	touch "$HOME/Downloads/level1/nested.dmg"

	run env PATH="/usr/bin:/bin" ROOMY_INSTALLER_SCAN_MAX_DEPTH=1 bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"top.dmg"* ]]
	[[ "$output" != *"nested.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): handles non-existent directory" {
	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/NonExistent"

	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "scan_installers_in_path (fallback find): ignores non-installer files" {
	touch "$HOME/Downloads/document.pdf"
	touch "$HOME/Downloads/image.jpg"
	touch "$HOME/Downloads/archive.tar.gz"
	touch "$HOME/Downloads/Installer.dmg"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" != *"document.pdf"* ]]
	[[ "$output" != *"image.jpg"* ]]
	[[ "$output" != *"archive.tar.gz"* ]]
	[[ "$output" == *"Installer.dmg"* ]]
}

@test "scan_all_installers: handles missing paths gracefully" {
	# Don't create all scan directories, some may not exist
	# Only create Downloads, delete others if they exist
	rm -rf "$HOME/Desktop"
	rm -rf "$HOME/Documents"
	rm -rf "$HOME/Public"
	rm -rf "$HOME/Public/Downloads"
	rm -rf "$HOME/Library/Downloads"
	mkdir -p "$HOME/Downloads"

	# Add an installer to the one directory that exists
	touch "$HOME/Downloads/test.dmg"

	run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        scan_all_installers
    ' bash "$PROJECT_ROOT/bin/installer.sh"

	# Should succeed even with missing paths
	[ "$status" -eq 0 ]
	# Should still find the installer in the existing directory
	[[ "$output" == *"test.dmg"* ]]
}

# Test edge cases

@test "scan_installers_in_path (fallback find): handles filenames with spaces" {
	touch "$HOME/Downloads/My App Installer.dmg"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"My App Installer.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): handles filenames with special characters" {
	touch "$HOME/Downloads/App-v1.2.3_beta.pkg"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"App-v1.2.3_beta.pkg"* ]]
}

@test "scan_installers_in_path (fallback find): returns empty for directory with no installers" {
	# Create some non-installer files
	touch "$HOME/Downloads/document.pdf"
	touch "$HOME/Downloads/image.png"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

# Symlink handling tests

@test "scan_installers_in_path (fallback find): skips symlinks to regular files" {
	touch "$HOME/Downloads/real.dmg"
	ln -s "$HOME/Downloads/real.dmg" "$HOME/Downloads/symlink.dmg"
	ln -s /nonexistent "$HOME/Downloads/dangling.lnk"

	run env PATH="/usr/bin:/bin" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"real.dmg"* ]]
	[[ "$output" != *"symlink.dmg"* ]]
	[[ "$output" != *"dangling.lnk"* ]]
}

@test "scan_installers_in_path skips symlinked scan roots before invoking fd" {
	rm -rf "$HOME/Downloads"
	mkdir -p "$HOME/outside-downloads" "$HOME/fake-bin"
	touch "$HOME/outside-downloads/Outside.dmg"
	ln -s "$HOME/outside-downloads" "$HOME/Downloads"

	cat > "$HOME/fake-bin/fd" <<'SCRIPT'
#!/usr/bin/env bash
printf 'FD_INVOKED\n' >> "$FD_LOG"
printf '%s\0' "$OUTSIDE_FILE"
SCRIPT
	chmod +x "$HOME/fake-bin/fd"

	run env PATH="$HOME/fake-bin:/usr/bin:/bin" FD_LOG="$HOME/fd.log" OUTSIDE_FILE="$HOME/outside-downloads/Outside.dmg" bash -euo pipefail -c "
        export ROOMY_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
	[ ! -f "$HOME/fd.log" ]
}
