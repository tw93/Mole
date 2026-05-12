#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-install-checksum-home.XXXXXX")"
	export HOME
}

teardown_file() {
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

setup() {
	rm -rf "${HOME:?}"/*
	mkdir -p "$HOME/source" "$HOME/config/bin" "$HOME/install"
	cat > "$HOME/source/roomy" <<'ROOMY'
VERSION="1.2.3"
ROOMY
}

load_installer_binary_helpers() {
	eval "$(sed -n '/^get_source_version()/,/^install_files()/p' "$PROJECT_ROOT/install.sh" | sed '$d')"
}
export -f load_installer_binary_helpers

@test "download_binary installs release asset only after checksum verification" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'

load_installer_binary_helpers

start_line_spinner() { :; }
stop_line_spinner() { :; }
log_success() { echo "SUCCESS:$*"; }
log_warning() { echo "WARNING:$*"; }
log_error() { echo "ERROR:$*"; }

content="verified-binary"
asset="analyze-darwin-$(uname -m | sed 's/x86_64/amd64/')"
hash=$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')

curl() {
	local out="" url=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o) out="$2"; shift 2 ;;
			http*) url="$1"; shift ;;
			*) shift ;;
		esac
	done
	case "$url" in
		*"${asset}") printf '%s' "$content" > "$out" ;;
		*"SHA256SUMS") printf '%s  %s\n' "$hash" "$asset" > "$out" ;;
		*) return 1 ;;
	esac
}

download_binary "analyze"
grep -q "verified-binary" "$CONFIG_DIR/bin/analyze-go"
test -x "$CONFIG_DIR/bin/analyze-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"SUCCESS:Downloaded analyze binary"* ]]
}

@test "download_binary rejects checksum mismatch and falls back to local build" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'

load_installer_binary_helpers

start_line_spinner() { :; }
stop_line_spinner() { :; }
log_success() { echo "SUCCESS:$*"; }
log_warning() { echo "WARNING:$*"; }
log_error() { echo "ERROR:$*"; }
build_binary_from_source() {
	printf 'built-from-source' > "$2"
	chmod +x "$2"
	return 0
}

asset="status-darwin-$(uname -m | sed 's/x86_64/amd64/')"
curl() {
	local out="" url=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o) out="$2"; shift 2 ;;
			http*) url="$1"; shift ;;
			*) shift ;;
		esac
	done
	case "$url" in
		*"${asset}") printf 'tampered-binary' > "$out" ;;
		*"SHA256SUMS") printf '%064d  %s\n' 0 "$asset" > "$out" ;;
		*) return 1 ;;
	esac
}

download_binary "status"
grep -q "built-from-source" "$CONFIG_DIR/bin/status-go"
! grep -q "tampered-binary" "$CONFIG_DIR/bin/status-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING:Checksum verification failed for status, trying local build"* ]]
}

@test "download_binary rejects SHA256SUMS without matching asset entry" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'

load_installer_binary_helpers

start_line_spinner() { :; }
stop_line_spinner() { :; }
log_success() { echo "SUCCESS:$*"; }
log_warning() { echo "WARNING:$*"; }
log_error() { echo "ERROR:$*"; }
build_binary_from_source() {
	printf 'rebuilt-after-missing-checksum' > "$2"
	chmod +x "$2"
	return 0
}

asset="analyze-darwin-$(uname -m | sed 's/x86_64/amd64/')"
hash=$(printf 'release-binary' | shasum -a 256 | awk '{print $1}')
curl() {
	local out="" url=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o) out="$2"; shift 2 ;;
			http*) url="$1"; shift ;;
			*) shift ;;
		esac
	done
	case "$url" in
		*"${asset}") printf 'release-binary' > "$out" ;;
		*"SHA256SUMS") printf '%s  other-asset\n' "$hash" > "$out" ;;
		*) return 1 ;;
	esac
}

download_binary "analyze"
grep -q "rebuilt-after-missing-checksum" "$CONFIG_DIR/bin/analyze-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING:Checksum verification failed for analyze, trying local build"* ]]
}

@test "download_binary rejects release asset when SHA256SUMS cannot be downloaded" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'

load_installer_binary_helpers

start_line_spinner() { :; }
stop_line_spinner() { :; }
log_success() { echo "SUCCESS:$*"; }
log_warning() { echo "WARNING:$*"; }
log_error() { echo "ERROR:$*"; }
build_binary_from_source() {
	printf 'rebuilt-after-checksum-404' > "$2"
	chmod +x "$2"
	return 0
}

asset="status-darwin-$(uname -m | sed 's/x86_64/amd64/')"
curl() {
	local out="" url=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o) out="$2"; shift 2 ;;
			http*) url="$1"; shift ;;
			*) shift ;;
		esac
	done
	case "$url" in
		*"${asset}") printf 'release-binary' > "$out" ;;
		*"SHA256SUMS") return 22 ;;
		*) return 1 ;;
	esac
}

download_binary "status"
grep -q "rebuilt-after-checksum-404" "$CONFIG_DIR/bin/status-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING:Checksum verification failed for status, trying local build"* ]]
}

@test "download_binary verifies fallback release asset against fallback checksums" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'

load_installer_binary_helpers

start_line_spinner() { :; }
stop_line_spinner() { :; }
log_success() { echo "SUCCESS:$*"; }
log_warning() { echo "WARNING:$*"; }
log_error() { echo "ERROR:$*"; }
get_latest_release_tag() { echo "V1.2.2"; }

content="fallback-binary"
asset="status-darwin-$(uname -m | sed 's/x86_64/amd64/')"
hash=$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')
curl() {
	local out="" url=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o) out="$2"; shift 2 ;;
			http*) url="$1"; shift ;;
			*) shift ;;
		esac
	done
	case "$url" in
		*"V1.2.3/${asset}") return 22 ;;
		*"V1.2.2/${asset}") printf '%s' "$content" > "$out" ;;
		*"V1.2.2/SHA256SUMS") printf '%s  %s\n' "$hash" "$asset" > "$out" ;;
		*) return 1 ;;
	esac
}

download_binary "status"
grep -q "fallback-binary" "$CONFIG_DIR/bin/status-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"SUCCESS:Downloaded status from V1.2.2"* ]]
}


@test "write_install_channel_metadata succeeds for stable channel with empty commit hash" {
	# Regression: the previous `[[ -n "$h" ]] && printf` form returned 1
	# whenever the commit hash was empty (always the case on stable), making
	# the block redirect look like an I/O failure and tripping the warning.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
CONFIG_DIR="$HOME/config"
mkdir -p "$CONFIG_DIR"

eval "$(sed -n '/^write_install_channel_metadata()/,/^}/p' "$PROJECT_ROOT/install.sh")"

if ! write_install_channel_metadata "stable" ""; then
	echo "WRONG: stable write reported failure"; exit 1
fi
[[ -f "$CONFIG_DIR/install_channel" ]] || { echo "WRONG: file not created"; exit 1; }
grep -q '^CHANNEL=stable$' "$CONFIG_DIR/install_channel" || { echo "WRONG: channel value missing"; cat "$CONFIG_DIR/install_channel"; exit 1; }
grep -q '^COMMIT_HASH=' "$CONFIG_DIR/install_channel" && { echo "WRONG: commit hash leaked"; exit 1; }

# Nightly path with a commit hash should still work.
if ! write_install_channel_metadata "nightly" "deadbeef"; then
	echo "WRONG: nightly write failed"; exit 1
fi
grep -q '^CHANNEL=nightly$' "$CONFIG_DIR/install_channel" || { echo "WRONG: nightly channel"; exit 1; }
grep -q '^COMMIT_HASH=deadbeef$' "$CONFIG_DIR/install_channel" || { echo "WRONG: nightly commit"; exit 1; }

# No leftover temp files.
if ls "$CONFIG_DIR"/install_channel.?????? 2>/dev/null | grep -q .; then
	echo "WRONG: tmp file leaked"; ls "$CONFIG_DIR"; exit 1
fi
EOF

	[ "$status" -eq 0 ]
}
