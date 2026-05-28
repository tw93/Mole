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

load_installer_archive_helpers() {
	eval "$(sed -n '/^archive_entries_are_safe()/,/^# Install defaults/p' "$PROJECT_ROOT/install.sh" | sed '$d')"
}
export -f load_installer_archive_helpers

@test "installer version helper is macOS portable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

load_installer_binary_helpers
latest="$(installer_latest_version_tag "V1.9.0" "V1.10.0" "V1.2.0" "not-a-version")"
[[ "$latest" == "V1.10.0" ]]
[[ "$(normalize_release_tag "v1.2.3")" == "V1.2.3" ]]
if normalize_release_tag "1.2.bad" > /dev/null; then
	echo "WRONG: invalid release tag accepted"
	exit 1
fi
printf '%s\n' "$latest"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == "V1.10.0" ]]
}

@test "installer SCRIPT_DIR replacement escapes sed metacharacters" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

load_installer_binary_helpers
config_dir="${HOME}/config & pipe|back\\slash"
escaped="$(escape_sed_replacement "$config_dir")"
line="$(printf 'SCRIPT_DIR="old"\n' | /usr/bin/sed "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$escaped\"|")"
printf '%s\n' "$line"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == "SCRIPT_DIR=\"$HOME/config & pipe|back\\slash\"" ]]
}

@test "installer rejects unsafe source archive entries before extraction" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

load_installer_archive_helpers

tar() {
	printf '%s\n' 'roomy-main/' 'roomy-main/roomy' 'roomy-main/lib/core/common.sh'
}
archive_entries_are_safe "$HOME/source.tar.gz"

tar() {
	printf '%s\n' 'roomy-main/' '../escape'
}
if archive_entries_are_safe "$HOME/source.tar.gz"; then
	echo "WRONG: parent traversal accepted"
	exit 1
fi

tar() {
	printf '%s\n' 'roomy-main/' '/tmp/escape'
}
if archive_entries_are_safe "$HOME/source.tar.gz"; then
	echo "WRONG: absolute archive entry accepted"
	exit 1
fi

tar() {
	printf '%s\n' 'roomy-main/' 'roomy-main/../escape'
}
if archive_entries_are_safe "$HOME/source.tar.gz"; then
	echo "WRONG: nested traversal accepted"
	exit 1
fi

tar() {
	:
}
if archive_entries_are_safe "$HOME/source.tar.gz"; then
	echo "WRONG: empty archive listing accepted"
	exit 1
fi

tar() {
	printf 'roomy-main/bad\tname\n'
}
if archive_entries_are_safe "$HOME/source.tar.gz"; then
	echo "WRONG: control-character archive entry accepted"
	exit 1
fi

tar() {
	case "$1" in
		-tzf)
			printf '%s\n' 'roomy-main/' 'roomy-main/lib'
			;;
		-tvzf)
			printf '%s\n' 'drwxr-xr-x  0 owner group 0 Jan  1 00:00 roomy-main/' \
				'lrwxr-xr-x  0 owner group 0 Jan  1 00:00 roomy-main/lib -> /tmp/escape'
			;;
	esac
}
if archive_entries_are_safe "$HOME/source.tar.gz"; then
	echo "WRONG: symlink archive entry accepted"
	exit 1
fi
EOF

	[ "$status" -eq 0 ]
}

@test "installer refuses symlinked support directories" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

load_installer_binary_helpers

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'
log_error() { echo "ERROR:$*"; }
maybe_sudo() { "$@"; }

rm -rf "$INSTALL_DIR" "$HOME/real-install"
mkdir -p "$HOME/real-install"
ln -s "$HOME/real-install" "$INSTALL_DIR"
if create_directories; then
	echo "WRONG: symlinked install dir accepted"
	exit 1
fi

rm -rf "$INSTALL_DIR" "$HOME/real-install-parent" "$HOME/install-parent"
mkdir -p "$HOME/real-install-parent"
ln -s "$HOME/real-install-parent" "$HOME/install-parent"
INSTALL_DIR="$HOME/install-parent/bin"
if create_directories; then
	echo "WRONG: symlinked install parent accepted"
	exit 1
fi

INSTALL_DIR="$HOME/install"
rm -rf "$CONFIG_DIR" "$HOME/real-config"
mkdir -p "$HOME/real-config"
ln -s "$HOME/real-config" "$CONFIG_DIR"
if create_directories; then
	echo "WRONG: symlinked config dir accepted"
	exit 1
fi

rm -rf "$CONFIG_DIR" "$HOME/real-bin"
mkdir -p "$CONFIG_DIR" "$HOME/real-bin"
ln -s "$HOME/real-bin" "$CONFIG_DIR/bin"
if create_directories; then
	echo "WRONG: symlinked config bin dir accepted"
	exit 1
fi

rm -rf "$CONFIG_DIR" "$HOME/real-lib"
mkdir -p "$CONFIG_DIR" "$HOME/real-lib"
ln -s "$HOME/real-lib" "$CONFIG_DIR/lib"
if create_directories; then
	echo "WRONG: symlinked config lib dir accepted"
	exit 1
fi

rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR/bin" "$CONFIG_DIR/lib"
create_directories

INSTALL_DIR="/tmp/roomy-install-symlink-parent-$$"
CONFIG_DIR="$HOME/config-allowed"
rm -rf "$INSTALL_DIR" "$CONFIG_DIR" # SAFE: test-owned temporary install/config paths
create_directories
[[ -d "$INSTALL_DIR" ]]
rm -rf "$INSTALL_DIR" "$CONFIG_DIR" # SAFE: test-owned temporary install/config paths
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Install directory must not be a symlink"* ]]
	[[ "$output" == *"Install directory must not include symlinked directories"* ]]
	[[ "$output" == *"Config directory must not be a symlink"* ]]
	[[ "$output" == *"Config bin directory must not be a symlink"* ]]
	[[ "$output" == *"Config lib directory must not be a symlink"* ]]
}

@test "installer executable commit replaces symlinks and refuses directory targets" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

load_installer_binary_helpers

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok'
ICON_ERROR='err'
log_error() { echo "ERROR:$*"; }
maybe_sudo() { "$@"; }

protected="$HOME/protected-roomy"
target="$INSTALL_DIR/roomy"
staged="$INSTALL_DIR/roomy.new"
printf 'keep\n' > "$protected"
ln -sf "$protected" "$target"
printf 'new roomy\n' > "$staged"

installer_commit_executable_stage "$staged" "$target" "Roomy executable"
[[ ! -L "$target" ]]
[[ "$(cat "$target")" == "new roomy" ]]
[[ "$(cat "$protected")" == "keep" ]]

rm -rf "$target" "$staged"
mkdir "$target"
printf 'new roomy\n' > "$staged"
if installer_commit_executable_stage "$staged" "$target" "Roomy executable"; then
	echo "WRONG: directory executable target accepted"
	exit 1
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Roomy executable target must be a regular file"* ]]
}

@test "download_binary replaces support binary symlinks without following them" {
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

log_success() { echo "SUCCESS:$*"; }
log_warning() { echo "WARNING:$*"; }
log_error() { echo "ERROR:$*"; }

mkdir -p "$SOURCE_DIR/bin" "$CONFIG_DIR/bin"
printf 'local-binary' > "$SOURCE_DIR/bin/analyze-go"
chmod +x "$SOURCE_DIR/bin/analyze-go"
printf 'protected' > "$HOME/protected-target"
ln -sf "$HOME/protected-target" "$CONFIG_DIR/bin/analyze-go"

download_binary "analyze"

grep -q "local-binary" "$CONFIG_DIR/bin/analyze-go"
grep -q "^protected$" "$HOME/protected-target"
[[ ! -L "$CONFIG_DIR/bin/analyze-go" ]]
test -x "$CONFIG_DIR/bin/analyze-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"SUCCESS:Installed local analyze binary"* ]]
}

@test "download_binary fallback build replaces symlinks without following them" {
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
curl() { return 1; }
get_latest_release_tag() { return 1; }
build_binary_from_source() {
	printf 'built-safely' > "$2"
	chmod +x "$2"
	return 0
}

mkdir -p "$CONFIG_DIR/bin"
printf 'protected' > "$HOME/protected-build-target"
ln -sf "$HOME/protected-build-target" "$CONFIG_DIR/bin/status-go"

download_binary "status"

grep -q "built-safely" "$CONFIG_DIR/bin/status-go"
grep -q "^protected$" "$HOME/protected-build-target"
[[ ! -L "$CONFIG_DIR/bin/status-go" ]]
test -x "$CONFIG_DIR/bin/status-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING:Could not download status binary, v1.2.3, trying local build"* ]]
}

@test "installer support copy replaces directory symlinks without following them" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"

load_installer_binary_helpers

mkdir -p "$SOURCE_DIR/lib/core" "$CONFIG_DIR/lib" "$HOME/protected-lib"
printf 'roomy-common' > "$SOURCE_DIR/lib/core/common.sh"
ln -sf "$HOME/protected-lib" "$CONFIG_DIR/lib/core"

installer_copy_support_path "$SOURCE_DIR/lib/core" "$CONFIG_DIR/lib/core" false

grep -q "roomy-common" "$CONFIG_DIR/lib/core/common.sh"
[[ ! -L "$CONFIG_DIR/lib/core" ]]
[[ ! -e "$HOME/protected-lib/common.sh" ]]
EOF

	[ "$status" -eq 0 ]
}

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

@test "download_binary rejects malformed SHA256SUMS digest for matching asset" {
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
	printf 'rebuilt-after-malformed-checksum' > "$2"
	chmod +x "$2"
	return 0
}

asset="analyze-darwin-$(uname -m | sed 's/x86_64/amd64/')"
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
		*"SHA256SUMS") printf 'not-a-sha256  %s\n' "$asset" > "$out" ;;
		*) return 1 ;;
	esac
}

download_binary "analyze"
grep -q "rebuilt-after-malformed-checksum" "$CONFIG_DIR/bin/analyze-go"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING:Checksum verification failed for analyze, trying local build"* ]]
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
