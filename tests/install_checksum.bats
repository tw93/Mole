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
	if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		rm -rf "$HOME"
	fi
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

setup() {
	# Safety: refuse to operate on a real home directory.
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	rm -rf "${HOME:?}"/*
	mkdir -p "$HOME/source" "$HOME/config/bin" "$HOME/install"
	cat > "$HOME/source/mole" << 'MOLE'
VERSION="1.2.3"
MOLE
}

load_installer_binary_helpers() {
	eval "$(sed -n '/^curl_download_with_retry()/,/^}/p' "$PROJECT_ROOT/install.sh")"
	eval "$(sed -n '/^get_source_version()/,/^install_files()/p' "$PROJECT_ROOT/install.sh" | sed '$d')"
}
export -f load_installer_binary_helpers

@test "download_binary installs release asset only after checksum verification" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
# Exercise the checksum-only path deterministically: a real authenticated gh on
# the host would otherwise run `attestation verify` against the fake fixture and
# fail. Attestation policy itself is covered by its own test below.
verify_release_attestation() { return 2; }

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
	[[ "$output" == *"SUCCESS:Installed analyze"* ]]
}

@test "download_binary retries transient asset and checksum failures" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
verify_release_attestation() { return 2; }
sleep() { :; }

content="retried-binary"
asset="analyze-darwin-$(uname -m | sed 's/x86_64/amd64/')"
hash=$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')
asset_attempts="$HOME/asset.attempts"
checksum_attempts="$HOME/checksum.attempts"

curl() {
	local out="" url="" counter="" attempt=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o) out="$2"; shift 2 ;;
			http*) url="$1"; shift ;;
			*) shift ;;
		esac
	done

	case "$url" in
		*"SHA256SUMS") counter="$checksum_attempts" ;;
		*"${asset}") counter="$asset_attempts" ;;
		*) return 22 ;;
	esac
	[[ -f "$counter" ]] && attempt=$(cat "$counter")
	attempt=$((attempt + 1))
	printf '%s\n' "$attempt" > "$counter"
	if [[ "$attempt" -lt 3 ]]; then
		return 35
	fi

	case "$url" in
		*"SHA256SUMS") printf '%s  %s\n' "$hash" "$asset" > "$out" ;;
		*"${asset}") printf '%s' "$content" > "$out" ;;
	esac
}

download_binary "analyze"
[ "$(cat "$asset_attempts")" -eq 3 ] || exit 1
[ "$(cat "$checksum_attempts")" -eq 3 ] || exit 1
grep -qx "$content" "$CONFIG_DIR/bin/analyze-go"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"SUCCESS:Installed analyze"* ]]
}

@test "download_binary aborts on checksum mismatch without downgrading to a source build" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
# Keep the checksum path deterministic and offline: an authenticated gh on the
# host would run `attestation verify` against the fake fixture over the network.
# Attestation policy has its own test below.
verify_release_attestation() { return 2; }
# A tampered asset must NEVER reroute onto an unverified source build.
build_binary_from_source() {
	echo "SOURCE_BUILD_INVOKED"
	printf 'built-from-source' > "$2"
	chmod +x "$2"
	return 0
}
get_latest_release_tag() { echo "V1.2.3"; }

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

if download_binary "status"; then
	echo "UNEXPECTED_SUCCESS"
	exit 1
fi
# No unverified artifact left behind under the installed name.
if [[ -e "$CONFIG_DIR/bin/status-go" ]]; then
	grep -q "tampered-binary" "$CONFIG_DIR/bin/status-go" && echo "TAMPERED_INSTALLED"
	grep -q "built-from-source" "$CONFIG_DIR/bin/status-go" && echo "SOURCE_INSTALLED"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"SOURCE_BUILD_INVOKED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUCCESS"* ]] || return 1
	[[ "$output" != *"TAMPERED_INSTALLED"* ]] || return 1
	[[ "$output" != *"SOURCE_INSTALLED"* ]] || return 1
	[[ "$output" == *"aborting instead of falling back"* ]]
}

@test "download_binary preserves the installed helper when verification and rebuild fail (#1193)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
verify_release_asset_checksum() { return 1; }
get_latest_release_tag() { echo "V1.2.3"; }
build_binary_from_source() { return 1; }
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then
            out="$2"
            shift 2
        else
            shift
        fi
    done
    printf 'unverified-new-binary' > "$out"
}

printf 'known-good-old-binary' > "$CONFIG_DIR/bin/analyze-go"
chmod +x "$CONFIG_DIR/bin/analyze-go"

if download_binary "analyze"; then
    echo "UNEXPECTED_SUCCESS"
    exit 1
fi

grep -qx 'known-good-old-binary' "$CONFIG_DIR/bin/analyze-go"
if find "$CONFIG_DIR/bin" -maxdepth 1 -name '.analyze-go.*' -print -quit | grep -q .; then
    echo "STAGING_FILE_LEAKED"
    exit 1
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"UNEXPECTED_SUCCESS"* ]] || return 1
	[[ "$output" != *"STAGING_FILE_LEAKED"* ]]
}

@test "download_binary aborts when SHA256SUMS has no matching asset entry" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
# Keep the checksum path deterministic and offline: an authenticated gh on the
# host would run `attestation verify` against the fake fixture over the network.
# Attestation policy has its own test below.
verify_release_attestation() { return 2; }
build_binary_from_source() {
	echo "SOURCE_BUILD_INVOKED"
	printf 'rebuilt-after-missing-checksum' > "$2"
	chmod +x "$2"
	return 0
}
get_latest_release_tag() { echo "V1.2.3"; }

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

if download_binary "analyze"; then
	echo "UNEXPECTED_SUCCESS"
	exit 1
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"SOURCE_BUILD_INVOKED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUCCESS"* ]] || return 1
	[[ "$output" == *"aborting instead of falling back"* ]]
}

@test "download_binary aborts when SHA256SUMS cannot be downloaded" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
	echo "SOURCE_BUILD_INVOKED"
	printf 'rebuilt-after-checksum-404' > "$2"
	chmod +x "$2"
	return 0
}
get_latest_release_tag() { echo "V1.2.3"; }

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

# An unreachable/blocked SHA256SUMS is indistinguishable from a suppressed
# one, so it must fail closed too, not silently build from unverified source.
if download_binary "status"; then
	echo "UNEXPECTED_SUCCESS"
	exit 1
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"SOURCE_BUILD_INVOKED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUCCESS"* ]] || return 1
	[[ "$output" == *"aborting instead of falling back"* ]]
}

@test "download_binary verifies fallback release asset against fallback checksums" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
# See note above: keep the fallback-checksum path independent of host gh state.
verify_release_attestation() { return 2; }

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
	[[ "$output" == *"SUCCESS:Installed status from V1.2.2"* ]]
}

@test "download_binary aborts on fallback-tag checksum mismatch without a source build" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
verify_release_attestation() { return 2; }
# The fallback tag is the last verification gate before the source-build
# branch; a mismatch there is tampering evidence and must abort too.
build_binary_from_source() {
	echo "SOURCE_BUILD_INVOKED"
	printf 'built-from-source' > "$2"
	chmod +x "$2"
	return 0
}

asset="status-darwin-$(uname -m | sed 's/x86_64/amd64/')"
good_hash=$(printf 'expected-binary' | shasum -a 256 | awk '{print $1}')
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
		*"V1.2.2/${asset}") printf 'tampered-binary' > "$out" ;;
		*"V1.2.2/SHA256SUMS") printf '%s  %s\n' "$good_hash" "$asset" > "$out" ;;
		*) return 1 ;;
	esac
}

if download_binary "status"; then
	echo "UNEXPECTED_SUCCESS"
	exit 1
fi
if [[ -e "$CONFIG_DIR/bin/status-go" ]]; then
	echo "BINARY_INSTALLED_ANYWAY"
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" != *"SOURCE_BUILD_INVOKED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUCCESS"* ]] || return 1
	[[ "$output" != *"BINARY_INSTALLED_ANYWAY"* ]] || return 1
	[[ "$output" == *"aborting instead of falling back"* ]] || return 1
}

@test "install_files fails closed when sudo is unavailable, even under || caller (#update-incident)" {
	# Old moles invoke `install_files || {...}`, which disables errexit inside
	# the function. Uncached `sudo -n` then failed on every copy while the
	# install still reported success with the OLD entry script in place
	# ("Updated to latest version, 1.45.0" while fetching V1.47.0).
	# MOLE_TEST_NO_AUTH must not leak in: it would take the blocked-in-test-mode
	# branch instead of the real ensure_sudo_ready gate. sudo is a function mock.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=0 MOLE_TEST_MODE=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail

eval "$(sed -n '/^needs_sudo() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^ensure_sudo_ready() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^maybe_sudo() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^install_files() {/,/^}/p' "$PROJECT_ROOT/install.sh")"

INSTALL_DIR="$HOME/rooty-bin"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_SUCCESS='ok' ICON_ERROR='err' ICON_ADMIN='adm'
MOLE_ASSUME_SUDO_AUTH=1

mkdir -p "$CONFIG_DIR" "$SOURCE_DIR"
printf '#!/bin/bash\nVERSION="9.9.9"\n' > "$SOURCE_DIR/mole"
printf '#!/bin/bash\n' > "$SOURCE_DIR/mo"
# Non-writable install dir: needs_sudo must answer true for a plain user.
mkdir -m 555 "$INSTALL_DIR"

log_error() { echo "ERROR:$*"; }
log_success() { echo "SUCCESS:$*"; }
log_admin() { echo "ADMIN:$*"; }
download_binary() { echo "DOWNLOAD_CALLED:$1"; return 0; }
sudo() {
	echo "sudo: a password is required" >&2
	return 1
}

# Reproduce the exact caller shape from the update flow.
install_files || echo "HANDLED_FAILURE"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"HANDLED_FAILURE"* ]] || return 1
	[[ "$output" == *"sudo -v && mo update"* ]] || return 1
	[[ "$output" != *"SUCCESS:Installed mole"* ]] || return 1
	[[ "$output" != *"DOWNLOAD_CALLED"* ]] || return 1
}

@test "verify_installation rejects a stale entry script after an update (#update-incident)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -uo pipefail

eval "$(sed -n '/^get_source_version() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^get_installed_version() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^verify_installation() {/,/^}/p' "$PROJECT_ROOT/install.sh")"

INSTALL_DIR="$HOME/bin"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
GREEN='' RED='' YELLOW='' NC=''
ICON_ERROR='err'

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/lib/core" "$SOURCE_DIR"
touch "$CONFIG_DIR/lib/core/common.sh"
# The old entry script survived a failed copy: runnable, wrong version.
printf '#!/bin/bash\nVERSION="1.45.0"\nexit 0\n' > "$INSTALL_DIR/mole"
chmod +x "$INSTALL_DIR/mole"
printf '#!/bin/bash\nVERSION="1.47.0"\n' > "$SOURCE_DIR/mole"

log_error() { echo "ERROR:$*"; }
log_warning() { echo "WARNING:$*"; }

verify_installation
echo "UNEXPECTED_PASS"
EOF

	# verify_installation exits 1 on the mixed-version state.
	[ "$status" -eq 1 ] || return 1
	[[ "$output" != *"UNEXPECTED_PASS"* ]] || return 1
	[[ "$output" == *"was not replaced"* ]] || return 1
	[[ "$output" == *"1.45.0"* && "$output" == *"1.47.0"* ]] || return 1
}

@test "installer bounds installed binary version and help probes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
INSTALL_DIR="$HOME/install/bin"
CONFIG_DIR="$HOME/install/config"
fake_bin="$HOME/fake-bin"
trace="$HOME/probe.trace"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR/lib/core" "$fake_bin"
: > "$CONFIG_DIR/lib/core/common.sh"

cat > "$INSTALL_DIR/mole" <<'MOLE'
#!/bin/bash
VERSION="9.9.9"
sleep 3
MOLE
chmod +x "$INSTALL_DIR/mole"

cat > "$fake_bin/gtimeout" <<'TIMEOUT'
#!/bin/bash
printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$PROBE_TRACE"
exit 124
TIMEOUT
chmod +x "$fake_bin/gtimeout"

export PATH="$fake_bin:/usr/bin:/bin"
export PROBE_TRACE="$trace"
eval "$(sed -n '/^run_install_probe_with_timeout() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^get_installed_version() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^verify_installation() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
get_source_version() { printf '9.9.9\n'; }
log_error() { printf 'ERROR:%s\n' "$*"; }
log_warning() { printf 'WARNING:%s\n' "$*"; }

[[ "$(get_installed_version)" == "9.9.9" ]] || exit 1
if verify_installation; then
	echo "UNEXPECTED_HELP_PROBE_SUCCESS"
	exit 1
fi
grep -qF -- "-k|1|5|$INSTALL_DIR/mole|--version" "$trace"
grep -qF -- "-k|1|5|$INSTALL_DIR/mole|--help" "$trace"
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"UNEXPECTED_HELP_PROBE_SUCCESS"* ]]
}

@test "installer rejects macOS older than the release minimum before setup" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^check_requirements()/,/^}/p' "$PROJECT_ROOT/install.sh")"
log_error() { printf 'ERROR:%s\n' "$*"; }
homebrew_owns_mole() { return 1; }
run_install_probe_with_timeout() {
    [[ "$1" == 2 && "$2" == "/usr/bin/sw_vers" && "$3" == "-productVersion" ]] || return 98
    printf '%s\n' "$FAKE_MACOS_VERSION"
}
INSTALL_DIR="$HOME/bin"
ACTION=install
OSTYPE=darwin23

set +e
(FAKE_MACOS_VERSION=11.7.10 check_requirements)
old_rc=$?
set -e
printf 'OLD_RC=%s\n' "$old_rc"
[[ $old_rc -eq 1 ]] || exit 1

FAKE_MACOS_VERSION=12.0 check_requirements
printf 'SUPPORTED=yes\n'
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"OLD_RC=1"* ]] || return 1
	[[ "$output" == *"requires macOS 12 or newer"* ]] || return 1
	[[ "$output" == *"SUPPORTED=yes"* ]] || return 1
}

@test "fresh install checks platform support before resolving remote source" {
	run awk '
        /^perform_install\(\) \{/ { in_install = 1; next }
        in_install && /^}/ { exit seen_check ? 0 : 1 }
        in_install && /check_requirements/ { seen_check = 1; next }
        in_install && /resolve_source_dir/ && !seen_check { exit 1 }
    ' "$PROJECT_ROOT/install.sh"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "installer shell fallback stops TERM-ignoring verification probes" {
	local timeout_cmd="timeout"
	command -v timeout > /dev/null 2>&1 || timeout_cmd="gtimeout"
	command -v "$timeout_cmd" > /dev/null 2>&1 || skip "timeout command unavailable"

	run "$timeout_cmd" 3 env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
eval "$(sed -n '/^run_install_probe_with_timeout() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
run_install_probe_with_timeout 1 /bin/bash -c 'exit 0' || {
	echo "UNEXPECTED_FAST_PROBE_FAILURE"
	exit 1
}
if run_install_probe_with_timeout 0.1 /bin/bash -c 'trap "" TERM; sleep 5 & wait'; then
	echo "UNEXPECTED_PROBE_SUCCESS"
	exit 1
fi
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"UNEXPECTED_FAST_PROBE_FAILURE"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_PROBE_SUCCESS"* ]]
}

@test "standalone installer cleans source temp under trailing-slash TMPDIR" {
	local tmp_root="$HOME/installer-tmp"
	mkdir -p "$tmp_root"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TMPDIR="$tmp_root/" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
log_error() { printf 'ERROR:%s\n' "$*"; }
stop_line_spinner() { :; }
release_install_lock() { :; }

eval "$(sed -n '/^safe_rm() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^cleanup_installer() {/,/^}/p' "$PROJECT_ROOT/install.sh")"

INSTALL_SOURCE_TMP=$(mktemp -d "${TMPDIR}mole-source.XXXXXX")
source_tmp="$INSTALL_SOURCE_TMP"
printf 'downloaded source\n' > "$source_tmp/payload"
cleanup_installer

[[ -z "$INSTALL_SOURCE_TMP" ]] || exit 1
[[ ! -e "$source_tmp" ]] || exit 1
if safe_rm "${TMPDIR%/}"; then
	echo "UNEXPECTED_TEMP_ROOT_REMOVAL"
	exit 1
fi
[[ -d "${TMPDIR%/}" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"UNEXPECTED_TEMP_ROOT_REMOVAL"* ]] || return 1
	[[ "$output" != *"safe_rm: refusing to remove non-temp path"* ]] || return 1
}

@test "installer source temp stays removable by safe_rm when TMPDIR is unset" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
unset TMPDIR
log_error() { printf 'ERROR:%s\n' "$*"; }
stop_line_spinner() { :; }
release_install_lock() { :; }

eval "$(sed -n '/^safe_rm() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^cleanup_installer() {/,/^}/p' "$PROJECT_ROOT/install.sh")"

# Evaluate install.sh's own source-download mktemp lines with TMPDIR unset,
# then run the same EXIT-trap cleanup path against the created directory.
# Anchor on the assignment rather than the phrase: a comment above it that
# mentions `mktemp -d` would otherwise be scraped and eval'd to nothing,
# leaving INSTALL_SOURCE_TMP unset and the failure looking like a real one.
tmp_lines="$(sed -n '/^[[:space:]]*tmp="\$(mktemp -d/{p;n;p;q;}' "$PROJECT_ROOT/install.sh" | sed 's/^[[:space:]]*//')"
[[ -n "$tmp_lines" ]] || { echo "NO_MKTEMP_LINES"; exit 1; }
eval "$tmp_lines"
source_tmp="$INSTALL_SOURCE_TMP"
printf 'downloaded source\n' > "$source_tmp/payload"
cleanup_installer

[[ -z "$INSTALL_SOURCE_TMP" ]] || exit 1
[[ ! -e "$source_tmp" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"safe_rm: refusing to remove non-temp path"* ]] || return 1
}

@test "source download mktemp template derives from TMPDIR" {
	run grep -qE 'mktemp -d "\$\{TMPDIR:-/tmp\}/mole\.XXXXXX"' "$PROJECT_ROOT/install.sh"
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "standalone installer serializes writers with the stable install lock" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
INSTALL_DIR="$HOME/install/bin"
INSTALL_LOCK_PATH=""
INSTALL_LOCK_CONTROL=""
INSTALL_LOCK_HOLDER_PID=""
mkdir -p "$INSTALL_DIR"
/bin/chmod 0775 "$INSTALL_DIR"

eval "$(sed -n '/^safe_rm() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^needs_sudo() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^ensure_sudo_ready() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^maybe_sudo() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^install_lock_has_unsafe_ancestor() {/,/^get_remote_main_commit_hash() {/p' "$PROJECT_ROOT/install.sh" | sed '$d')"
log_error() { printf 'ERROR:%s\n' "$*"; }

[[ "$(/usr/bin/stat -f%Lp "$INSTALL_DIR")" == "775" ]] || exit 1
if ! install_lock_has_unsafe_ancestor true; then
	echo "UNEXPECTED_PRIVILEGED_GROUP_WRITABLE_PREFIX_ACCEPTED"
	exit 1
fi

acl_rule="everyone allow list,add_file,search,add_subdirectory,delete_child,file_inherit,directory_inherit"
/bin/chmod +a "$acl_rule" "$INSTALL_DIR"
/bin/mkdir -m 0700 "$INSTALL_DIR/acl-probe"
/bin/ls -lde "$INSTALL_DIR/acl-probe" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:'
/bin/rmdir "$INSTALL_DIR/acl-probe"
if acquire_install_lock; then
	echo "UNEXPECTED_WRITABLE_PARENT_ACL_ACCEPTED"
	exit 1
fi
# A refusal must name its own cause. Reporting an ancestor rejection as a busy
# lock is what sent #1335 reverse-engineering the check by hand.
[[ "$INSTALL_LOCK_FAILURE" == "unsafe_ancestor" ]] || exit 1
[[ "$INSTALL_LOCK_UNSAFE_ANCESTOR" == "$INSTALL_DIR" ]] || exit 1
/bin/chmod -N "$INSTALL_DIR"
acl_rule="everyone deny writeattr,file_inherit,directory_inherit"
/bin/chmod +a "$acl_rule" "$INSTALL_DIR"
acquire_install_lock
lock_path="$INSTALL_DIR/.mole-update.lock/kernel.lock"
[[ "$INSTALL_LOCK_PATH" == "$lock_path" ]] || exit 1
if /bin/ls -lde "$INSTALL_DIR/.mole-update.lock" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:'; then
	echo "UNEXPECTED_INHERITED_INSTALL_LOCK_ACL"
	exit 1
fi
if acquire_install_lock; then
	echo "UNEXPECTED_CONCURRENT_INSTALL_LOCK"
	exit 1
fi
[[ "$INSTALL_LOCK_FAILURE" == "busy" ]] || exit 1
release_install_lock
[[ -f "$lock_path" ]] || exit 1

holder_ready="$HOME/install-lock-holder.ready"
holder_ready_tmp="$holder_ready.tmp"
external_holder=""
holder_child_pid=""
cleanup_external_holder() {
	local child_pid
	if [[ "$holder_child_pid" =~ ^[0-9]+$ ]]; then
		kill "$holder_child_pid" 2> /dev/null || true
	fi
	if [[ "$external_holder" =~ ^[0-9]+$ ]]; then
		for child_pid in $(/usr/bin/pgrep -P "$external_holder" 2> /dev/null || true); do
			kill "$child_pid" 2> /dev/null || true
		done
		kill "$external_holder" 2> /dev/null || true
		wait "$external_holder" 2> /dev/null || true
	fi
	unlink "$holder_ready" 2> /dev/null || true
	unlink "$holder_ready_tmp" 2> /dev/null || true
}
trap cleanup_external_holder EXIT
/usr/bin/lockf -k -s -t 0 -w "$lock_path" /bin/sh -c '
	printf "%s\n" "$$" > "$1" || exit 1
	mv "$1" "$2" || exit 1
	exec /bin/sleep 30
' sh "$holder_ready_tmp" "$holder_ready" &
external_holder=$!
for _ in {1..200}; do
	if [[ -s "$holder_ready" ]]; then
		holder_child_pid=$(cat "$holder_ready")
		if [[ "$holder_child_pid" =~ ^[0-9]+$ ]] &&
			kill -0 "$external_holder" 2> /dev/null &&
			kill -0 "$holder_child_pid" 2> /dev/null; then
			break
		fi
		holder_child_pid=""
	fi
	kill -0 "$external_holder" 2> /dev/null || break
	/bin/sleep 0.01
done
if [[ ! "$holder_child_pid" =~ ^[0-9]+$ ]]; then
	exit 1
fi
external_lock_bypassed=false
if acquire_install_lock; then
	external_lock_bypassed=true
	release_install_lock
fi
cleanup_external_holder
trap - EXIT
if [[ "$external_lock_bypassed" == "true" ]]; then
	echo "UNEXPECTED_EXTERNAL_LOCK_BYPASS"
	exit 1
fi
acquire_install_lock
release_install_lock
[[ -f "$lock_path" ]] || exit 1

victim="$HOME/lock-symlink-victim"
printf 'DO-NOT-TOUCH\n' > "$victim"
/bin/rm -f "$lock_path"
ln -s "$victim" "$lock_path"
if acquire_install_lock; then
	echo "UNEXPECTED_LOCK_SYMLINK_FOLLOW"
	exit 1
fi
# A planted lock path is not contention, and must not be reported as such.
[[ "$INSTALL_LOCK_FAILURE" == "lock_path" ]] || exit 1
[[ "$(cat "$victim")" == "DO-NOT-TOUCH" ]] || exit 1
unlink "$lock_path"
mkfifo "$lock_path"
if acquire_install_lock; then
	echo "UNEXPECTED_LOCK_FIFO_OPEN"
	exit 1
fi
[[ "$INSTALL_LOCK_FAILURE" == "lock_path" ]] || exit 1
unlink "$lock_path"
acquire_install_lock
release_install_lock
! compgen -G "$INSTALL_DIR/.mole-update.lock/control.*" > /dev/null

declare -f acquire_install_lock | grep -q '/usr/bin/lockf'
! grep -q 'trap cleanup_tmp EXIT' "$PROJECT_ROOT/install.sh"
grep -q "trap 'cleanup_installer' EXIT" "$PROJECT_ROOT/install.sh"
! grep -qF 'Another Mole installation or update is already writing' "$PROJECT_ROOT/install.sh"
# Both call sites route through the reporter, and each cause keeps its own
# remedy. A single catch-all lock message is the regression being pinned.
! grep -qF 'Could not acquire the Mole installation lock for' "$PROJECT_ROOT/install.sh"
[[ "$(grep -c 'report_install_lock_failure$' "$PROJECT_ROOT/install.sh")" -eq 2 ]] || exit 1
# Pin the reason codes, not the wording. Pinning a sentence is what let the
# first fix swap one vague message for another and lock it in as a
# requirement, so assert instead that every cause the code can raise reaches a
# branch of its own, and that each branch says what happened and what to run.
for lock_reason in $(grep -oE 'INSTALL_LOCK_FAILURE="[a-z_]+"' "$PROJECT_ROOT/install.sh" |
    sed 's/.*="//;s/"//' | sort -u); do
    [[ "$lock_reason" == "busy" ]] && continue
    grep -qE "^[[:space:]]+${lock_reason}\)\$" "$PROJECT_ROOT/install.sh" || {
        echo "MISSING_LOCK_BRANCH:$lock_reason"
        exit 1
    }
done
# The ancestor check refuses for five independent reasons and each needs a
# different command: chown does not clear an ACL, chmod does not undo a
# symlink. One shared sentence sends the user to run something inert.
for ancestor_reason in $(grep -oE 'INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="[a-z_]+"' "$PROJECT_ROOT/install.sh" |
    sed 's/.*="//;s/"//' | sort -u); do
    grep -qE "^[[:space:]]+${ancestor_reason}\)\$" "$PROJECT_ROOT/install.sh" || {
        echo "MISSING_ANCESTOR_BRANCH:$ancestor_reason"
        exit 1
    }
done
# Every branch that speaks to the user tells them what to run next. Checked on
# leaf branches only: `unsafe_ancestor)` just opens a nested case and its
# children carry the messages, so a branch with no log_error of its own is a
# delegator, not a silent refusal.
awk '/^report_install_lock_failure\(\)/{inside=1; next}
     inside && /^\}$/{inside=0}
     inside && /^[[:space:]]+[a-z_*]+\)$/{
         if (name != "" && errors > 0 && !next_step) {print "NO_NEXT_STEP:" name; bad=1}
         name=$1; errors=0; next_step=0; next
     }
     inside && /log_error/{errors++; if ($0 ~ /retry/) next_step=1}
     END{
         if (name != "" && errors > 0 && !next_step) {print "NO_NEXT_STEP:" name; bad=1}
         exit bad
     }' "$PROJECT_ROOT/install.sh" || exit 1
# A lapsed session gets one terminal-bound retry, and never a silent prompt on
# captured stdio or a hang where there is no terminal to ask on.
grep -qF 'sudo -v < /dev/tty > /dev/tty 2> /dev/tty' "$PROJECT_ROOT/install.sh"
grep -qF '[[ -r /dev/tty && -w /dev/tty ]] || return 1' "$PROJECT_ROOT/install.sh"
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"UNEXPECTED_CONCURRENT_INSTALL_LOCK"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_EXTERNAL_LOCK_BYPASS"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_LOCK_SYMLINK_FOLLOW"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_LOCK_FIFO_OPEN"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_INHERITED_INSTALL_LOCK_ACL"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_WRITABLE_PARENT_ACL_ACCEPTED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_PRIVILEGED_GROUP_WRITABLE_PREFIX_ACCEPTED"* ]] || return 1
}

@test "standalone installer normalizes a relative prefix before lock validation" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cd "$HOME"
INSTALL_DIR="relative/bin"
mkdir -p "$INSTALL_DIR"

eval "$(sed -n '/^safe_rm() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^install_lock_has_unsafe_ancestor() {/,/^install_lock_process_start() {/p' "$PROJECT_ROOT/install.sh" | sed '$d')"
eval "$(sed -n '/^normalize_install_dir() {/,/^}/p' "$PROJECT_ROOT/install.sh")"

normalize_install_dir
[[ "$INSTALL_DIR" == "$(pwd -P)/relative/bin" ]] || exit 1
if install_lock_has_unsafe_ancestor false; then
    echo "UNEXPECTED_RELATIVE_PREFIX_REJECTED_AFTER_NORMALIZATION"
    exit 1
fi
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"UNEXPECTED_RELATIVE_PREFIX_REJECTED_AFTER_NORMALIZATION"* ]]
}

@test "write_install_channel_metadata succeeds for stable channel with empty commit hash" {
	# Regression: the previous `[[ -n "$h" ]] && printf` form returned 1
	# whenever the commit hash was empty (always the case on stable), making
	# the block redirect look like an I/O failure and tripping the warning.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
if ! write_install_channel_metadata "nightly" "deadbeef" "heal-123-456-789"; then
	echo "WRONG: nightly write failed"; exit 1
fi
grep -q '^CHANNEL=nightly$' "$CONFIG_DIR/install_channel" || { echo "WRONG: nightly channel"; exit 1; }
grep -q '^COMMIT_HASH=deadbeef$' "$CONFIG_DIR/install_channel" || { echo "WRONG: nightly commit"; exit 1; }
grep -q '^INSTALL_RECEIPT=heal-123-456-789$' "$CONFIG_DIR/install_channel" || { echo "WRONG: install receipt missing"; exit 1; }

if ! write_install_channel_metadata "stable" "" "update-123-456-789"; then
	echo "WRONG: update receipt rejected"; exit 1
fi
grep -q '^INSTALL_RECEIPT=update-123-456-789$' "$CONFIG_DIR/install_channel" || { echo "WRONG: update receipt missing"; exit 1; }

if write_install_channel_metadata "nightly" "badcafe" $'heal-valid\nCOMMIT_HASH=forged'; then
	echo "WRONG: malformed receipt accepted"; exit 1
fi
grep -q '^CHANNEL=stable$' "$CONFIG_DIR/install_channel" || { echo "WRONG: rejected receipt changed metadata"; exit 1; }

# No leftover temp files.
if ls "$CONFIG_DIR"/install_channel.?????? 2>/dev/null | grep -q .; then
	echo "WRONG: tmp file leaked"; ls "$CONFIG_DIR"; exit 1
fi
EOF

	[ "$status" -eq 0 ]
}

@test "main source archives are pinned when a commit is known" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
eval "$(sed -n '/^source_archive_url()/,/^}/p' "$PROJECT_ROOT/install.sh")"

commit="0123456789abcdef0123456789abcdef01234567"
[[ "$(source_archive_url main "$commit")" == "https://github.com/tw93/mole/archive/$commit.tar.gz" ]] || exit 1
[[ "$(source_archive_url main "")" == "https://github.com/tw93/mole/archive/refs/heads/main.tar.gz" ]] || exit 1
[[ "$(source_archive_url dev "")" == "https://github.com/tw93/mole/archive/refs/heads/dev.tar.gz" ]] || exit 1
[[ "$(source_archive_url V1.2.3 "")" == "https://github.com/tw93/mole/archive/refs/tags/V1.2.3.tar.gz" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "installer source-build guidance names the main branch explicitly" {
	run awk '
		/^[[:space:]]*#/ { next }
		/piping from curl:/ {
			seen = 1
			if ($0 !~ /\| bash -s -- main/) bad = 1
		}
		END { exit (!seen || bad) }
	' "$PROJECT_ROOT/install.sh"

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "verify_release_attestation maps gh availability and result to 2/0/1" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail

eval "$(sed -n '/^verify_release_attestation()/,/^}/p' "$PROJECT_ROOT/install.sh")"

stubdir="$(mktemp -d "${TMPDIR:-/tmp}/mole-gh-stub.XXXXXX")"
cat > "$stubdir/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_TRACE"
case "$1 $2" in
	"auth status") exit "${STUB_AUTH_RC:-0}" ;;
	"attestation verify") exit "${STUB_VERIFY_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$stubdir/gh"
target="$(mktemp "${TMPDIR:-/tmp}/mole-att-file.XXXXXX")"
GH_TRACE="$(mktemp "${TMPDIR:-/tmp}/mole-gh-trace.XXXXXX")"
export GH_TRACE

# gh missing -> cannot verify (2)
( PATH="/var/empty"; verify_release_attestation "$target" ) && rc=0 || rc=$?
[ "$rc" -eq 2 ] || { echo "WRONG: gh-missing rc=$rc want 2"; exit 1; }

# gh present but unauthenticated -> cannot verify (2)
( PATH="$stubdir:$PATH"; export STUB_AUTH_RC=1; verify_release_attestation "$target" ) && rc=0 || rc=$?
[ "$rc" -eq 2 ] || { echo "WRONG: unauth rc=$rc want 2"; exit 1; }

# gh authenticated + attestation verifies -> 0
( PATH="$stubdir:$PATH"; export STUB_AUTH_RC=0 STUB_VERIFY_RC=0; verify_release_attestation "$target" ) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || { echo "WRONG: verify-ok rc=$rc want 0"; exit 1; }

# gh authenticated + attestation fails -> 1
( PATH="$stubdir:$PATH"; export STUB_AUTH_RC=0 STUB_VERIFY_RC=1; verify_release_attestation "$target" ) && rc=0 || rc=$?
[ "$rc" -eq 1 ] || { echo "WRONG: verify-fail rc=$rc want 1"; exit 1; }

grep -Fq "attestation verify $target --repo tw93/Mole --deny-self-hosted-runners" "$GH_TRACE" || {
    echo "WRONG: attestation verification was not repository-scoped"
    cat "$GH_TRACE"
    exit 1
}
! grep -Fq -- '--owner tw93' "$GH_TRACE" || {
    echo "WRONG: owner-wide attestation scope remained enabled"
    cat "$GH_TRACE"
    exit 1
}

rm -rf "$stubdir" "$target" "$GH_TRACE"
EOF

	[ "$status" -eq 0 ]
}

@test "verify_release_asset_checksum enforces attestation policy gate" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail

eval "$(sed -n '/^extract_release_checksum()/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^calculate_file_sha256()/,/^}/p' "$PROJECT_ROOT/install.sh")"
eval "$(sed -n '/^verify_release_asset_checksum()/,/^}/p' "$PROJECT_ROOT/install.sh")"

log_success() { echo "SUCCESS:$*"; }
log_error() { echo "ERROR:$*"; }

asset="status-darwin-amd64"
file="$(mktemp "${TMPDIR:-/tmp}/mole-asset.XXXXXX")"
printf 'release-binary' > "$file"
hash="$(printf 'release-binary' | shasum -a 256 | awk '{print $1}')"
download_release_checksums() { printf '%s  %s\n' "$hash" "$asset" > "$2"; return 0; }

# attestation verification failed (status 1) -> fatal, never installs
verify_release_attestation() { return 1; }
out="$(verify_release_asset_checksum V1.0.0 "$asset" "$file")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || { echo "WRONG: status1 rc=$rc want 1"; exit 1; }
[[ "$out" == *"ERROR:Release attestation verification failed"* ]] || { echo "WRONG: status1 error missing: $out"; exit 1; }

# cannot verify (status 2) + MOLE_REQUIRE_ATTESTATION=1 -> fatal
verify_release_attestation() { return 2; }
out="$(MOLE_REQUIRE_ATTESTATION=1 verify_release_asset_checksum V1.0.0 "$asset" "$file")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || { echo "WRONG: require-gate rc=$rc want 1"; exit 1; }
[[ "$out" == *"ERROR:MOLE_REQUIRE_ATTESTATION=1 set but gh"* ]] || { echo "WRONG: require-gate error missing: $out"; exit 1; }

# cannot verify (status 2) without the gate -> falls back to checksum-only
verify_release_attestation() { return 2; }
out="$(verify_release_asset_checksum V1.0.0 "$asset" "$file")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || { echo "WRONG: checksum-only rc=$rc want 0"; exit 1; }

# attestation verified (status 0) + checksum match -> success with combined label
verify_release_attestation() { return 0; }
out="$(verify_release_asset_checksum V1.0.0 "$asset" "$file")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || { echo "WRONG: verified rc=$rc want 0"; exit 1; }
[[ "$out" == *"SUCCESS:Verified ${asset} · sha256 + attestation"* ]] || { echo "WRONG: verified success missing: $out"; exit 1; }

rm -f "$file"
EOF

	[ "$status" -eq 0 ]
}

@test "teardown never turns a finished install into a failure" {
	# cleanup_installer runs from the EXIT trap under `set -e`, so a refusal
	# inside it used to become the script's exit status and report a verified
	# install as failed (#1343). The refusal still prints; it just no longer
	# decides the verdict.
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
log_error() { printf 'ERROR:%s\n' "$*"; }
stop_line_spinner() { :; }
release_install_lock() { :; }
eval "$(sed -n '/^cleanup_installer() {/,/^}/p' "$PROJECT_ROOT/install.sh")"

# A path safe_rm must refuse, standing in for any future refusal.
safe_rm() { log_error "safe_rm: refusing to remove non-temp path: $1"; return 1; }
INSTALL_SOURCE_TMP="/not/a/temp/path"
trap 'cleanup_installer' EXIT
exit 0
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"refusing to remove"* ]] || return 1
}

@test "the source temp dir and safe_rm agree on the temp root" {
	# A bare `mktemp -d` ignores TMPDIR on macOS, so the creator and the
	# remover disagreed whenever TMPDIR was unset or pointed elsewhere.
	# Assert the behaviour, not the template: create the dir the way the
	# installer does, then hand it to the real safe_rm.
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
log_error() { printf 'ERROR:%s\n' "$*"; }
eval "$(sed -n '/^safe_rm() {/,/^}/p' "$PROJECT_ROOT/install.sh")"
# Anchor on the assignment, not the phrase: a comment that merely mentions
# `mktemp -d` would otherwise be picked up and eval'd to nothing.
mktemp_line=$(grep -m1 -E '^[[:space:]]*tmp="\$\(mktemp -d' "$PROJECT_ROOT/install.sh" | sed 's/^[[:space:]]*//')
[[ -n "$mktemp_line" ]] || { echo "NO_MKTEMP_LINE"; exit 1; }

for scenario in unset darwin slash; do
    case "$scenario" in
        unset)  unset TMPDIR ;;
        darwin) TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)"; export TMPDIR ;;
        slash)  TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)"; TMPDIR="${TMPDIR%/}/"; export TMPDIR ;;
    esac
    eval "$mktemp_line"
    [[ -d "$tmp" ]] || { echo "NO_DIR:$scenario"; exit 1; }
    safe_rm "$tmp" || { echo "REFUSED:$scenario"; exit 1; }
    [[ ! -e "$tmp" ]] || { echo "LEFT_BEHIND:$scenario"; exit 1; }
done
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"REFUSED"* ]] || return 1
}

@test "the install lock still works where /usr/bin/lockf was never shipped" {
	# lockf only ships with newer macOS. Requiring it made both install and
	# update exit before writing a file on every older release (#1348), so the
	# absent case falls back to an atomic mkdir. Simulate absence by pointing
	# the check at a path that cannot exist.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
patched="$HOME/install-nolockf.sh"
sed 's#/usr/bin/lockf#/usr/bin/lockf_absent_for_test#g' "$PROJECT_ROOT/install.sh" > "$patched"

INSTALL_DIR="$HOME/install"
INSTALL_LOCK_FAILURE=""
INSTALL_LOCK_UNSAFE_ANCESTOR=""
INSTALL_LOCK_UNSAFE_ANCESTOR_REASON=""
INSTALL_LOCK_PATH=""; INSTALL_LOCK_CONTROL=""; INSTALL_LOCK_HOLDER_PID=""; INSTALL_LOCK_USE_SUDO=false
log_error() { printf 'ERROR:%s\n' "$*"; }
# awk, not sed: a BSD sed address built from a function name trips over the
# parentheses for some of these, and the failure is a silent missing function.
for fn in install_lock_command install_lock_has_unsafe_ancestor install_lock_prepare_dir \
	install_lock_read_owner install_lock_remove_control install_lock_process_start \
	install_lock_current_shell_pid install_lock_reauthenticate acquire_install_lock \
	release_install_lock; do
	body="$(awk -v f="$fn" 'index($0, f "()")==1{p=1} p{print} p&&/^}$/{exit}' "$patched")"
	[[ -n "$body" ]] || { echo "NO_BODY:$fn"; exit 1; }
	eval "$body"
done

acquire_install_lock || { echo "ACQUIRE_FAILED:$INSTALL_LOCK_FAILURE"; exit 1; }
mutex="$INSTALL_DIR/.mole-update.lock/holder"
[[ -d "$mutex" ]] || { echo "NO_MUTEX_HELD"; exit 1; }

# A second acquire must be refused while this one holds the mutex.
( acquire_install_lock ) && { echo "DOUBLE_ACQUIRE"; exit 1; }

release_install_lock
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[[ -d "$mutex" ]] || break
	/bin/sleep 0.1
done
[[ ! -d "$mutex" ]] || { echo "MUTEX_LEAKED"; exit 1; }
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"DOUBLE_ACQUIRE"* ]] || return 1
	[[ "$output" != *"MUTEX_LEAKED"* ]] || return 1
}

@test "the update path never runs brew inside the pre-authed window" {
	# brew's entry point resets the sudo timestamp as a security measure;
	# running it after pre-auth killed the handed-over ticket within five
	# seconds (field ticket watchdog) and forced a second password prompt
	# on every update. Homebrew ownership is decided from the Cellar on
	# disk instead, so brew itself never runs in that window.
	# Comment lines are stripped first: the invariant is that install.sh does
	# not RUN this, and a comment explaining why it was dropped is not a call.
	# A bare grep flagged exactly that comment and read as a real regression.
	if command grep -vE '^[[:space:]]*#' "$PROJECT_ROOT/install.sh" |
		command grep -q 'brew list mole'; then
		echo "brew list mole is back in install.sh"
		return 1
	fi
	command grep -q 'homebrew_owns_mole()' "$PROJECT_ROOT/install.sh" || {
		echo "cellar-based ownership check missing"
		return 1
	}

	# The helper itself: a Cellar dir under HOMEBREW_PREFIX means owned,
	# no Cellar anywhere means not owned, and brew is never executed.
	eval "$(sed -n '/^homebrew_owns_mole()/,/^}/p' "$PROJECT_ROOT/install.sh")"
	local fake_prefix="$BATS_TEST_TMPDIR/fakebrew"
	mkdir -p "$fake_prefix/Cellar/mole"
	HOMEBREW_PREFIX="$fake_prefix" homebrew_owns_mole || {
		echo "cellar dir not detected"
		return 1
	}
	if HOMEBREW_PREFIX="$BATS_TEST_TMPDIR/empty" homebrew_owns_mole 2> /dev/null &&
		[[ ! -d /opt/homebrew/Cellar/mole && ! -d /usr/local/Cellar/mole ]]; then
		echo "claimed ownership with no cellar anywhere"
		return 1
	fi
}
