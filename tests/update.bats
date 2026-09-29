#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_project_root
}

setup() {
	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-update-home.XXXXXX")"
	TEST_ROOT="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-update-case.XXXXXX")"
	export HOME TEST_ROOT
}

teardown() {
	case "${HOME:-}" in
		"${BATS_TEST_DIRNAME}/tmp-update-home."*) rm -rf "$HOME" ;;
	esac
	case "${TEST_ROOT:-}" in
		"${BATS_TEST_DIRNAME}/tmp-update-case."*) rm -rf "$TEST_ROOT" ;;
	esac
}

make_manual_mole_install() {
	local install_dir="$1"
	local config_dir="$2"
	local version="$3"
	mkdir -p "$install_dir" "$config_dir/bin"
	sed \
		-e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$config_dir\"|" \
		-e "s/^VERSION=\".*\"$/VERSION=\"$version\"/" \
		"$PROJECT_ROOT/mole" > "$install_dir/mole"
	cp "$PROJECT_ROOT/mo" "$install_dir/mo"
	cp -R "$PROJECT_ROOT/lib" "$config_dir/lib"
	printf '#!/bin/bash\nexit 0\n' > "$config_dir/bin/analyze-go"
	printf '#!/bin/bash\nexit 0\n' > "$config_dir/bin/status-go"
	chmod +x "$install_dir/mole" "$install_dir/mo" "$config_dir/bin/analyze-go" "$config_dir/bin/status-go"
}

make_homebrew_shadow() {
	local bin_dir="$1"
	local cellar_mole="$2"
	mkdir -p "$bin_dir" "$(dirname "$cellar_mole")"
	cp "$PROJECT_ROOT/mole" "$cellar_mole"
	cp -R "$PROJECT_ROOT/lib" "$bin_dir/lib"
	chmod +x "$cellar_mole"
	ln -sf "$cellar_mole" "$bin_dir/mole"
	ln -sf "$cellar_mole" "$bin_dir/mo"

	cat > "$bin_dir/brew" << 'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_LOG"
case "${1:-}" in
	list)
		if [[ "${2:-}" == "--versions" ]]; then
			printf 'mole 9.9.9\n'
		fi
		exit 0
		;;
	update)
		exit 0
		;;
	upgrade)
		if [[ -n "${BREW_UPGRADE_OUTPUT:-}" ]]; then
			printf '%s\n' "$BREW_UPGRADE_OUTPUT"
		fi
		exit "${BREW_UPGRADE_STATUS:-0}"
		;;
esac
exit 0
SCRIPT
	chmod +x "$bin_dir/brew"
}

make_update_curl_stub() {
	local bin_dir="$1"
	local latest_version="$2"
	cat > "$bin_dir/curl" << SCRIPT
#!/usr/bin/env bash
out=""
url=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		-o)
			out="\$2"
			shift 2
			;;
		http*://*)
			url="\$1"
			shift
			;;
		*)
			shift
			;;
	esac
done
[[ -n "\$url" ]] && printf '%s\n' "\$url" >> "\$CURL_URL_LOG"

if [[ -n "\$out" ]]; then
	if [[ -n "\${CURL_TRANSIENT_FAILURES:-}" && -n "\${CURL_ATTEMPT_LOG:-}" ]]; then
		attempt=0
		[[ -f "\$CURL_ATTEMPT_LOG" ]] && attempt=\$(cat "\$CURL_ATTEMPT_LOG")
		attempt=\$((attempt + 1))
		printf '%s\n' "\$attempt" > "\$CURL_ATTEMPT_LOG"
		if [[ "\$attempt" -le "\$CURL_TRANSIENT_FAILURES" ]]; then
			exit "\${CURL_TRANSIENT_STATUS:-35}"
		fi
	fi
	cat > "\$out" <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\$INSTALLER_ARGS_LOG"
printf '%s\n' "\${MOLE_VERSION:-}" > "\$INSTALLER_VERSION_LOG"
if [[ -n "\${INSTALLER_SUDO_AUTH_LOG:-}" ]]; then
	printf '%s\n' "\${MOLE_ASSUME_SUDO_AUTH:-}" > "\$INSTALLER_SUDO_AUTH_LOG"
fi
prefix=""
config=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		--prefix) prefix="\$2"; shift 2 ;;
		--config) config="\$2"; shift 2 ;;
		*) shift ;;
	esac
done
# A handed-over sudo session means root would write regardless of the
# directory's mode bits; emulate that by unlocking the prefix the test
# made read-only to trigger the sudo path in the first place.
if [[ "\${MOLE_ASSUME_SUDO_AUTH:-0}" == "1" ]]; then
	chmod u+w "\$prefix" 2>/dev/null || true
fi
mkdir -p "\$prefix" "\$config/bin"
printf '#!/bin/bash\necho "Mole version %s"\n' "\${MOLE_VERSION#V}" > "\$prefix/mole.next"
printf '#!/bin/bash\nexit 0\n' > "\$config/bin/analyze-go"
cp "\$config/bin/analyze-go" "\$config/bin/status-go"
chmod +x "\$prefix/mole.next" "\$config/bin/analyze-go" "\$config/bin/status-go"
mv "\$prefix/mole.next" "\$prefix/mole"
printf 'CHANNEL=stable\nINSTALL_RECEIPT=%s\n' "\${MOLE_INSTALL_RECEIPT:-}" > "\$config/install_channel"
rm -f "\$config/.helper_install_incomplete"
echo "Updated to latest version, \${MOLE_VERSION#V}"
INSTALLER
	exit 0
fi

if [[ "\$url" == *"api.github.com"* ]]; then
	printf '{"tag_name":"%s"}\n' "$latest_version"
	exit 0
fi

printf 'VERSION="%s"\n' "$latest_version"
SCRIPT
	chmod +x "$bin_dir/curl"
}

make_nightly_update_curl_stub() {
	local bin_dir="$1"
	local latest_commit="$2"
	cat > "$bin_dir/curl" << SCRIPT
#!/usr/bin/env bash
out=""
url=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		-o)
			out="\$2"
			shift 2
			;;
		http*://*)
			url="\$1"
			shift
			;;
		*)
			shift
			;;
	esac
done
[[ -n "\$url" ]] && printf '%s\n' "\$url" >> "\$CURL_URL_LOG"

if [[ -n "\$out" ]]; then
	cat > "\$out" <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\$INSTALLER_ARGS_LOG"
printf '%s\n' "\${MOLE_VERSION:-}" > "\$INSTALLER_VERSION_LOG"
if [[ -n "\${INSTALLER_COMMIT_LOG:-}" ]]; then
	printf '%s\n' "\${MOLE_INSTALL_COMMIT:-}" > "\$INSTALLER_COMMIT_LOG"
fi
if [[ -n "\${INSTALLER_SUDO_AUTH_LOG:-}" ]]; then
	printf '%s\n' "\${MOLE_ASSUME_SUDO_AUTH:-}" > "\$INSTALLER_SUDO_AUTH_LOG"
fi
prefix=""
config=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		--prefix) prefix="\$2"; shift 2 ;;
		--config) config="\$2"; shift 2 ;;
		*) shift ;;
	esac
done
mkdir -p "\$prefix" "\$config/bin"
printf '#!/bin/bash\necho "Mole version nightly"\n' > "\$prefix/mole.next"
printf '#!/bin/bash\nexit 0\n' > "\$config/bin/analyze-go"
cp "\$config/bin/analyze-go" "\$config/bin/status-go"
chmod +x "\$prefix/mole.next" "\$config/bin/analyze-go" "\$config/bin/status-go"
mv "\$prefix/mole.next" "\$prefix/mole"
printf 'CHANNEL=nightly\nCOMMIT_HASH=%s\nINSTALL_RECEIPT=%s\n' \
	"\${MOLE_INSTALL_COMMIT:0:7}" "\${MOLE_INSTALL_RECEIPT:-}" > "\$config/install_channel"
rm -f "\$config/.helper_install_incomplete"
echo "Updated to latest version, \${MOLE_VERSION#V}"
INSTALLER
	exit 0
fi

if [[ "\$url" == *"api.github.com/repos/tw93/mole/commits/main"* ]]; then
	printf '{"sha":"%s"}\n' "$latest_commit"
	exit 0
fi

exit 1
SCRIPT
	chmod +x "$bin_dir/curl"
}

make_nightly_api_failure_stubs() {
	local bin_dir="$1"
	local latest_commit="${2:-}"
	cat > "$bin_dir/curl" <<'SCRIPT'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o)
			out="$2"
			shift 2
			;;
		http*://*)
			url="$1"
			shift
			;;
		*) shift ;;
	esac
done
[[ -n "$url" ]] && printf '%s\n' "$url" >> "$CURL_URL_LOG"

if [[ -n "$out" ]]; then
	cat > "$out" <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$INSTALLER_ARGS_LOG"
printf '%s\n' "${MOLE_INSTALL_COMMIT:-}" > "$INSTALLER_COMMIT_LOG"
prefix=""
config=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--prefix) prefix="$2"; shift 2 ;;
		--config) config="$2"; shift 2 ;;
		*) shift ;;
	esac
done
mkdir -p "$prefix" "$config/bin"
printf '#!/bin/bash\necho "Mole version nightly"\n' > "$prefix/mole.next"
printf '#!/bin/bash\nexit 0\n' > "$config/bin/analyze-go"
cp "$config/bin/analyze-go" "$config/bin/status-go"
chmod +x "$prefix/mole.next" "$config/bin/analyze-go" "$config/bin/status-go"
mv "$prefix/mole.next" "$prefix/mole"
# Nightly success is bound to a per-attempt receipt plus the resolved commit.
# A stub that skips them is rejected by _update_verify_installed_generation.
printf 'CHANNEL=nightly\nCOMMIT_HASH=%s\nINSTALL_RECEIPT=%s\n' \
	"${MOLE_INSTALL_COMMIT:0:7}" "${MOLE_INSTALL_RECEIPT:-}" > "$config/install_channel"
rm -f "$config/.helper_install_incomplete"
echo "Updated to latest version, ${MOLE_VERSION#V}"
INSTALLER
	exit 0
fi

exit 22
SCRIPT
	cat > "$bin_dir/git" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GIT_ARGS_LOG"
if [[ -n "\${GIT_CONFIG_PARAMETERS:-}" || -n "\${GIT_EXEC_PATH:-}" ]]; then
	[[ -n "\${GIT_POISON_LOG:-}" ]] && : > "\$GIT_POISON_LOG"
	printf 'badc0de0000000000000000000000000000000000\trefs/heads/main\n'
	exit 0
fi
if [[ -n "\${GIT_ENV_LOG:-}" ]]; then
	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"\${GIT_TERMINAL_PROMPT:-}" "\${GIT_ASKPASS:-}" "\${SSH_ASKPASS:-}" \
		"\${GIT_CONFIG_NOSYSTEM:-}" "\${GIT_CONFIG_GLOBAL:-}" \
		"\${GIT_CONFIG_COUNT:-}" "\${LC_ALL:-}" > "\$GIT_ENV_LOG"
fi
if [[ -n "$latest_commit" ]]; then
	printf '%s\trefs/heads/main\n' "$latest_commit"
	case "\${GIT_STUB_MODE:-success}" in
		nonzero) exit 1 ;;
		hang) sleep 30 ;;
	esac
	exit 0
fi
exit 1
SCRIPT
	chmod +x "$bin_dir/curl" "$bin_dir/git"
}

@test "mo update repairs missing helpers at the current stable version (#1193)" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_version_log="$TEST_ROOT/installer.version"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local current_version

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "$current_version"
	make_update_curl_stub "$fake_bin" "$current_version"
	rm -f "$manual_config/bin/analyze-go"
	touch "$manual_config/.helper_install_incomplete"
	: > "$curl_url_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_VERSION_LOG="$installer_version_log" \
		"$manual_bin/mo" update

	[ "$status" -eq 0 ]
	[[ "$output" == *"Mole installation needs repair"* ]] || return 1
	[[ "$output" == *"missing analyze-go"* ]] || return 1
	[ -f "$installer_args_log" ]
	if grep -q -- "--update" "$installer_args_log"; then
		return 1
	fi
	[ "$(cat "$installer_version_log")" = "V$current_version" ]
}

@test "mo update retries transient installer download failures" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_version_log="$TEST_ROOT/installer.version"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local curl_attempt_log="$TEST_ROOT/curl.attempts"
	local current_version

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"
	make_update_curl_stub "$fake_bin" "$current_version"
	printf '#!/bin/bash\nexit 0\n' > "$fake_bin/sleep"
	chmod +x "$fake_bin/sleep"
	: > "$curl_url_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		CURL_ATTEMPT_LOG="$curl_attempt_log" \
		CURL_TRANSIENT_FAILURES=2 \
		CURL_TRANSIENT_STATUS=35 \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_VERSION_LOG="$installer_version_log" \
		"$manual_bin/mo" update

	[ "$status" -eq 0 ] || return 1
	[ -f "$installer_args_log" ] || return 1
	[ "$(cat "$curl_attempt_log")" -eq 3 ] || return 1
	[ "$(cat "$installer_version_log")" = "V$current_version" ]
}

@test "mo update reports unreachable version discovery instead of exiting silently" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_attempt_log="$TEST_ROOT/discovery.attempts"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"

	# Every request fails the way a flaky local proxy fails. Version discovery
	# runs inside `latest=$(...)`, so before the fix the nonzero pipeline tripped
	# errexit and killed `mo update` with an empty screen and no diagnosis.
	cat > "$fake_bin/curl" << 'SCRIPT'
#!/usr/bin/env bash
printf 'x\n' >> "$CURL_ATTEMPT_LOG"
exit 28
SCRIPT
	printf '#!/bin/bash\nexit 0\n' > "$fake_bin/sleep"
	chmod +x "$fake_bin/curl" "$fake_bin/sleep"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_ATTEMPT_LOG="$curl_attempt_log" \
		"$manual_bin/mo" update

	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"Unable to check for updates"* ]] || return 1
	[[ "$output" == *"https://github.com"* ]] || return 1
	# The bounded retry must not run behind a blank screen.
	[[ "$output" == *"Checking for updates"* ]] || return 1
	# Two endpoints per round, three bounded rounds.
	[ "$(wc -l < "$curl_attempt_log" | tr -d ' ')" -eq 6 ]
}

@test "mo update announces the check before the bounded retry, not after it" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_attempt_log="$TEST_ROOT/announce.attempts"
	local out_file="$TEST_ROOT/announce.out"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"
	cat > "$fake_bin/curl" << 'SCRIPT'
#!/usr/bin/env bash
printf 'x\n' >> "$CURL_ATTEMPT_LOG"
exit 28
SCRIPT
	chmod +x "$fake_bin/curl"
	: > "$out_file"
	: > "$curl_attempt_log"

	# Sampled mid-flight on purpose. Asserting the final output cannot tell an
	# announcement before the retry loop from one after it, which is the whole
	# point: three rounds of failing requests behind a blank screen is the
	# "looks hung" report this retry was added for. `sleep` is deliberately not
	# stubbed here, so the resolver's real 1s pause between rounds leaves a wide
	# sampling window.
	env HOME="$HOME" PATH="$fake_bin:/usr/bin:/bin" \
		CURL_ATTEMPT_LOG="$curl_attempt_log" \
		"$manual_bin/mo" update > "$out_file" 2>&1 &
	local update_pid=$!

	local waited=0
	while [[ "$(wc -l < "$curl_attempt_log" 2> /dev/null || echo 0)" -lt 2 ]]; do
		sleep 0.05
		waited=$((waited + 1))
		if [[ "$waited" -gt 200 ]]; then
			break
		fi
	done

	local mid_output
	mid_output=$(cat "$out_file")
	wait "$update_pid" || true

	# Round one is done but the resolver has not finished: the label must already
	# be visible, and the final verdict must not be.
	[[ "$mid_output" == *"Checking for updates"* ]] || return 1
	[[ "$mid_output" != *"Unable to check for updates"* ]]
}

@test "mo update targets the invoked manual install, not another Homebrew mole in PATH" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_brew_bin="$TEST_ROOT/homebrew/bin"
	local fake_brew_mole="$TEST_ROOT/homebrew/Cellar/mole/9.9.9/bin/mole"
	local brew_log="$TEST_ROOT/brew.log"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_version_log="$TEST_ROOT/installer.version"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local current_version
	local stale_version="0.0.1"

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	make_manual_mole_install "$manual_bin" "$manual_config" "$stale_version"
	make_homebrew_shadow "$fake_brew_bin" "$fake_brew_mole"
	make_update_curl_stub "$fake_brew_bin" "$current_version"
	: > "$brew_log"
	: > "$curl_url_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_brew_bin:/usr/bin:/bin" \
		BREW_LOG="$brew_log" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_VERSION_LOG="$installer_version_log" \
		"$manual_bin/mo" update

	[ "$status" -eq 0 ]
	[ -f "$installer_args_log" ]
	grep -q -- "--prefix" "$installer_args_log"
	grep -q -- "$manual_bin" "$installer_args_log"
	[ "$(cat "$installer_version_log")" = "V$current_version" ]
	grep -q "raw.githubusercontent.com/tw93/mole/V${current_version#V}/install.sh" "$curl_url_log"
	if grep -q "raw.githubusercontent.com/tw93/mole/main/install.sh" "$curl_url_log"; then
		return 1
	fi
	if grep -q '^upgrade mole$' "$brew_log"; then
		return 1
	fi
}

@test "mo update --nightly skips reinstall when the installed commit is current" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_version_log="$TEST_ROOT/installer.version"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local latest_commit="e31d46faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_nightly_update_curl_stub "$fake_bin" "$latest_commit"
	printf 'CHANNEL=nightly\nCOMMIT_HASH=e31d46f\n' > "$manual_config/install_channel"
	: > "$curl_url_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_VERSION_LOG="$installer_version_log" \
		"$manual_bin/mo" update --nightly

	[ "$status" -eq 0 ]
	[[ "$output" == *"Already on latest nightly, e31d46f"* ]] || return 1
	[ ! -e "$installer_args_log" ]
	grep -q "api.github.com/repos/tw93/mole/commits/main" "$curl_url_log"
	if grep -q "raw.githubusercontent.com/tw93/mole/main/install.sh" "$curl_url_log"; then
		return 1
	fi
}

@test "mo update --nightly falls back to git when the commit API is unavailable" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local git_args_log="$TEST_ROOT/git.args"
	local git_env_log="$TEST_ROOT/git.env"
	local git_poison_log="$TEST_ROOT/git.poison"
	local installer_args_log="$TEST_ROOT/installer.args"
	local latest_commit="e31d46faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_nightly_api_failure_stubs "$fake_bin" "$latest_commit"
	printf 'CHANNEL=nightly\nCOMMIT_HASH=e31d46f\n' > "$manual_config/install_channel"
	: > "$curl_url_log"
	: > "$git_args_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		GIT_ARGS_LOG="$git_args_log" \
		GIT_ENV_LOG="$git_env_log" \
		GIT_POISON_LOG="$git_poison_log" \
		GIT_CONFIG_PARAMETERS=poison-rewrite \
		GIT_EXEC_PATH="$TEST_ROOT/untrusted-git-exec" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		"$manual_bin/mo" update --nightly

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Already on latest nightly, e31d46f"* ]] || return 1
	[ ! -e "$installer_args_log" ] || return 1
	[ ! -e "$git_poison_log" ] || return 1
	grep -qF 'ls-remote https://github.com/tw93/mole.git refs/heads/main' "$git_args_log" || return 1
	[ "$(cat "$git_env_log")" = '0|/usr/bin/false|/usr/bin/false|1|/dev/null|0|C' ] || return 1
	grep -qF -- '-c credential.helper= -c core.askPass=/usr/bin/false' "$git_args_log" || return 1
	grep -qF -- '-c protocol.allow=never -c protocol.https.allow=always -c http.sslVerify=true -C /' "$git_args_log" || return 1
	if grep -q 'raw.githubusercontent.com/tw93/mole/main/install.sh' "$curl_url_log"; then
		return 1
	fi
}

@test "background nightly checks skip the git fallback while explicit lookups retain it" {
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local git_args_log="$TEST_ROOT/git.args"
	local lookup_scope_log="$TEST_ROOT/lookup.scope"
	local latest_commit="e31d46faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	mkdir -p "$fake_bin"
	make_nightly_api_failure_stubs "$fake_bin" "$latest_commit"
	: > "$curl_url_log"
	: > "$git_args_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		PROJECT_ROOT="$PROJECT_ROOT" \
		LATEST_COMMIT="$latest_commit" \
		CURL_URL_LOG="$curl_url_log" \
		GIT_ARGS_LOG="$git_args_log" \
		LOOKUP_SCOPE_LOG="$lookup_scope_log" \
		/bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME/config"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

background_commit=$(get_latest_commit_from_github api-only)
[[ -z "$background_commit" ]] || exit 1
[[ ! -s "$GIT_ARGS_LOG" ]] || exit 1

explicit_commit=$(get_latest_commit_from_github)
[[ "$explicit_commit" == "$LATEST_COMMIT" ]] || exit 1
grep -qF 'ls-remote https://github.com/tw93/mole.git refs/heads/main' "$GIT_ARGS_LOG"

get_install_channel() {
	printf 'nightly\n'
}
get_install_commit() {
	printf 'e31d46f\n'
}
get_latest_commit_from_github() {
	printf '%s\n' "${1:-}" > "$LOOKUP_SCOPE_LOG"
	printf '\n'
}
check_for_updates

attempt=0
while [[ ! -s "$LOOKUP_SCOPE_LOG" && "$attempt" -lt 100 ]]; do
	sleep 0.01
	attempt=$((attempt + 1))
done
[[ "$(cat "$LOOKUP_SCOPE_LOG")" == "api-only" ]] || exit 1
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "mo update --nightly refuses an unforced reinstall when HEAD is unknown" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local git_args_log="$TEST_ROOT/git.args"
	local installer_args_log="$TEST_ROOT/installer.args"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_nightly_api_failure_stubs "$fake_bin" ""
	printf 'CHANNEL=nightly\n' > "$manual_config/install_channel"
	: > "$curl_url_log"
	: > "$git_args_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		GIT_ARGS_LOG="$git_args_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		"$manual_bin/mo" update --nightly

	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"Unable to resolve latest nightly commit"* ]] || return 1
	[[ "$output" == *"mo update --nightly --force"* ]] || return 1
	[ ! -e "$installer_args_log" ] || return 1
	grep -qF 'ls-remote https://github.com/tw93/mole.git refs/heads/main' "$git_args_log" || return 1
	if grep -q 'raw.githubusercontent.com/tw93/mole/main/install.sh' "$curl_url_log"; then
		return 1
	fi
}

@test "mo update --nightly rejects partial output from a failed or timed-out git probe" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local git_args_log="$TEST_ROOT/git.args"
	local installer_args_log="$TEST_ROOT/installer.args"
	local latest_commit="f42c0debbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	local mode start elapsed

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_nightly_api_failure_stubs "$fake_bin" "$latest_commit"
	printf 'CHANNEL=nightly\nCOMMIT_HASH=deadbee\n' > "$manual_config/install_channel"

	for mode in nonzero hang; do
		: > "$curl_url_log"
		: > "$git_args_log"
		rm -f "$installer_args_log"
		start=$SECONDS
		run env \
			HOME="$HOME" \
			PATH="$fake_bin:/usr/bin:/bin" \
			MOLE_TIMEOUT_MEDIUM_PROBE_SEC=0.2 \
			GIT_STUB_MODE="$mode" \
			CURL_URL_LOG="$curl_url_log" \
			GIT_ARGS_LOG="$git_args_log" \
			INSTALLER_ARGS_LOG="$installer_args_log" \
			"$manual_bin/mo" update --nightly
		elapsed=$((SECONDS - start))

		[ "$status" -eq 1 ] || return 1
		[[ "$output" == *"Unable to resolve latest nightly commit"* ]] || return 1
		[ ! -e "$installer_args_log" ] || return 1
		[ "$elapsed" -lt 5 ] || return 1
	done
}

@test "mo update --nightly forwards the git-resolved commit to the installer" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local git_args_log="$TEST_ROOT/git.args"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_commit_log="$TEST_ROOT/installer.commit"
	local latest_commit="f42c0debbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_nightly_api_failure_stubs "$fake_bin" "$latest_commit"
	printf 'CHANNEL=nightly\nCOMMIT_HASH=deadbee\n' > "$manual_config/install_channel"
	: > "$curl_url_log"
	: > "$git_args_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		GIT_ARGS_LOG="$git_args_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_COMMIT_LOG="$installer_commit_log" \
		"$manual_bin/mo" update --nightly

	[ "$status" -eq 0 ] || return 1
	[ -f "$installer_args_log" ] || return 1
	[ "$(cat "$installer_commit_log")" = "$latest_commit" ] || return 1
	grep -q 'raw.githubusercontent.com/tw93/mole/main/install.sh' "$curl_url_log" || return 1
}

@test "mo update --nightly --force reinstalls even when the installed commit is current" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_version_log="$TEST_ROOT/installer.version"
	local installer_commit_log="$TEST_ROOT/installer.commit"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local latest_commit="e31d46faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_nightly_update_curl_stub "$fake_bin" "$latest_commit"
	printf 'CHANNEL=nightly\nCOMMIT_HASH=e31d46f\n' > "$manual_config/install_channel"
	: > "$curl_url_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_VERSION_LOG="$installer_version_log" \
		INSTALLER_COMMIT_LOG="$installer_commit_log" \
		"$manual_bin/mo" update --nightly --force

	[ "$status" -eq 0 ]
	[ -f "$installer_args_log" ]
	grep -q -- "--prefix" "$installer_args_log"
	[ "$(cat "$installer_version_log")" = "main" ]
	[ "$(cat "$installer_commit_log")" = "$latest_commit" ] || return 1
	grep -q "raw.githubusercontent.com/tw93/mole/main/install.sh" "$curl_url_log"
}

@test "mo update tells installer to reuse sudo after parent authentication" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local installer_version_log="$TEST_ROOT/installer.version"
	local installer_sudo_auth_log="$TEST_ROOT/installer.sudo-auth"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local sudo_log="$TEST_ROOT/sudo.log"
	local current_version

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_update_curl_stub "$fake_bin" "$current_version"
	chmod a-w "$manual_bin"
	cat > "$fake_bin/sudo" << 'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
exit 0
SCRIPT
	chmod +x "$fake_bin/sudo"
	: > "$curl_url_log"
	: > "$sudo_log"

	run env \
		HOME="$HOME" \
		MOLE_TEST_MODE=0 \
		MOLE_TEST_NO_AUTH=0 \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		INSTALLER_VERSION_LOG="$installer_version_log" \
		INSTALLER_SUDO_AUTH_LOG="$installer_sudo_auth_log" \
		SUDO_LOG="$sudo_log" \
		"$manual_bin/mo" update --force

	chmod u+w "$manual_bin"

	[ "$status" -eq 0 ]
	[ -f "$installer_sudo_auth_log" ]
	[ "$(cat "$installer_sudo_auth_log")" = "1" ]
	grep -q -- "-n true" "$sudo_log"
	grep -q "raw.githubusercontent.com/tw93/mole/V${current_version#V}/install.sh" "$curl_url_log"
}

@test "mo update aborts when the sudo session cannot reach the installer child" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local sudo_log="$TEST_ROOT/sudo.log"
	local sudo_count="$TEST_ROOT/sudo.count"
	local current_version

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	make_update_curl_stub "$fake_bin" "$current_version"
	chmod a-w "$manual_bin"

	# macOS scopes the sudo timestamp to the controlling terminal and falls back
	# to the parent PID when there is none, so a credential this shell holds does
	# not reach a child process. Model exactly that: the first `-n true` (the one
	# request_sudo_access runs in-process) succeeds, the probe's child call does
	# not. Without the guard the installer runs and fails on a swallowed sudo.
	cat > "$fake_bin/sudo" << 'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
if [[ "$*" == "-n true" ]]; then
	count=0
	[[ -s "$SUDO_COUNT" ]] && count=$(cat "$SUDO_COUNT")
	count=$((count + 1))
	printf '%s\n' "$count" > "$SUDO_COUNT"
	[[ "$count" -eq 1 ]] || exit 1
fi
exit 0
SCRIPT
	chmod +x "$fake_bin/sudo"
	: > "$curl_url_log"
	: > "$sudo_log"
	: > "$sudo_count"

	run env \
		HOME="$HOME" \
		MOLE_TEST_MODE=0 \
		MOLE_TEST_NO_AUTH=0 \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		SUDO_LOG="$sudo_log" \
		SUDO_COUNT="$sudo_count" \
		"$manual_bin/mo" update --force

	chmod u+w "$manual_bin"

	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"Admin access cannot be handed to the installer"* ]] || return 1
	[[ "$output" == *"sudo -v && mo update"* ]] || return 1
	[ ! -e "$installer_args_log" ] || return 1
	[ "$(cat "$sudo_count")" -ge 2 ] || return 1
}

@test "installer sudo reuse uses non-interactive sudo checks" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mole_source_installer

INSTALL_DIR="$HOME/install"
CONFIG_DIR="$HOME/config"
SOURCE_DIR="$HOME/source"
VERBOSE=1
GREEN='' BLUE='' YELLOW='' RED='' NC=''
ICON_ERROR='err'
SUDO_LOG="$HOME/sudo.log"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$SOURCE_DIR"
chmod a-w "$INSTALL_DIR"


log_error() { echo "ERROR:$*"; }
sudo() {
	printf '%s\n' "$*" >> "$SUDO_LOG"
	return 0
}

MOLE_ASSUME_SUDO_AUTH=1 ensure_sudo_ready
grep -qx -- "-n -v" "$SUDO_LOG" || { echo "WRONG: sudo validation was interactive"; cat "$SUDO_LOG"; exit 1; }

: > "$SUDO_LOG"
MOLE_ASSUME_SUDO_AUTH=1 maybe_sudo true
grep -qx -- "-n true" "$SUDO_LOG" || { echo "WRONG: sudo command was interactive"; cat "$SUDO_LOG"; exit 1; }

chmod u+w "$INSTALL_DIR"
EOF

	[ "$status" -eq 0 ]
}

@test "mo update keeps Homebrew installs on the Homebrew update path" {
	local fake_brew_bin="$TEST_ROOT/homebrew/bin"
	local fake_brew_mole="$TEST_ROOT/homebrew/Cellar/mole/9.9.9/bin/mole"
	local brew_log="$TEST_ROOT/brew.log"

	make_homebrew_shadow "$fake_brew_bin" "$fake_brew_mole"
	: > "$brew_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_brew_bin:/usr/bin:/bin" \
		BREW_LOG="$brew_log" \
		"$fake_brew_bin/mo" update

	[ "$status" -eq 0 ]
	grep -q '^update$' "$brew_log"
	grep -q '^upgrade mole$' "$brew_log"
}

@test "Homebrew update bounds fallback installed-binary version probes" {
	run env HOME="$HOME/bounded-homebrew-version" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
trace="$HOME/timeout.trace"

run_with_timeout() {
	local timeout="$1"
	shift
	printf '%s|%s\n' "$timeout" "$*" >> "$trace"
	case "$*" in
		"brew upgrade mole") printf 'already installed\n' ;;
		"mo --version") printf 'Mole version 9.9.9\n' ;;
	esac
}
mo() {
	printf 'UNEXPECTED_DIRECT_MO\n'
	return 1
}
export -f mo

update_via_homebrew "1.0.0"
grep -qFx "$MOLE_TIMEOUT_QUICK_DETECT_SEC|mo --version" "$trace"
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"Already on latest version, 9.9.9"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_DIRECT_MO"* ]]
}

@test "mo update preserves actionable Homebrew diagnostics on failure (#1247)" {
	local fake_brew_bin="$TEST_ROOT/homebrew/bin"
	local fake_brew_mole="$TEST_ROOT/homebrew/Cellar/mole/9.9.9/bin/mole"
	local brew_log="$TEST_ROOT/brew.log"
	local brew_upgrade_output
	brew_upgrade_output=$'Error: Your Xcode (26.0.1) at /Applications/Xcode.app is too outdated.\nPlease update to Xcode 27.0 (or delete it).\nXcode can be updated from:\n  https://developer.apple.com/download/all/'

	make_homebrew_shadow "$fake_brew_bin" "$fake_brew_mole"
	: > "$brew_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_brew_bin:/usr/bin:/bin" \
		BREW_LOG="$brew_log" \
		BREW_UPGRADE_OUTPUT="$brew_upgrade_output" \
		BREW_UPGRADE_STATUS=1 \
		"$fake_brew_bin/mo" update

	[ "$status" -ne 0 ]
	[[ "$output" == *"Homebrew upgrade failed"* ]] || return 1
	[[ "$output" == *"Please update to Xcode 27.0 (or delete it)."* ]] || return 1
	[[ "$output" == *"https://developer.apple.com/download/all/"* ]]
}

@test "mo update trusts a nonzero Homebrew exit without Error text (#1247)" {
	local fake_brew_bin="$TEST_ROOT/homebrew/bin"
	local fake_brew_mole="$TEST_ROOT/homebrew/Cellar/mole/9.9.9/bin/mole"
	local brew_log="$TEST_ROOT/brew.log"

	make_homebrew_shadow "$fake_brew_bin" "$fake_brew_mole"
	: > "$brew_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_brew_bin:/usr/bin:/bin" \
		BREW_LOG="$brew_log" \
		BREW_UPGRADE_OUTPUT="The upgrade command was interrupted" \
		BREW_UPGRADE_STATUS=124 \
		"$fake_brew_bin/mo" update

	[ "$status" -ne 0 ]
	[[ "$output" == *"Homebrew upgrade failed"* ]] || return 1
	[[ "$output" == *"The upgrade command was interrupted"* ]] || return 1
	[[ "$output" != *"Updated to latest version"* ]]
}

@test "mo update never treats mixed failure output as already installed" {
	local fake_brew_bin="$TEST_ROOT/homebrew/bin"
	local fake_brew_mole="$TEST_ROOT/homebrew/Cellar/mole/9.9.9/bin/mole"
	local brew_log="$TEST_ROOT/brew.log"
	local brew_upgrade_output
	brew_upgrade_output=$'mole 1.48.0 already installed\nError: simulated upgrade failure'

	make_homebrew_shadow "$fake_brew_bin" "$fake_brew_mole"
	: > "$brew_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_brew_bin:/usr/bin:/bin" \
		BREW_LOG="$brew_log" \
		BREW_UPGRADE_OUTPUT="$brew_upgrade_output" \
		BREW_UPGRADE_STATUS=1 \
		"$fake_brew_bin/mo" update

	[ "$status" -ne 0 ]
	[[ "$output" == *"Homebrew upgrade failed"* ]] || return 1
	[[ "$output" == *"Error: simulated upgrade failure"* ]] || return 1
	[[ "$output" != *"Already on latest version"* ]]
}

make_self_heal_curl_stub() {
	local bin_dir="$1"
	local latest_version="$2"
	local heal_mode="$3"
	cat > "$bin_dir/curl" << SCRIPT
#!/usr/bin/env bash
out=""
url=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		-o)
			out="\$2"
			shift 2
			;;
		http*://*)
			url="\$1"
			shift
			;;
		*)
			shift
			;;
	esac
done
[[ -n "\$url" ]] && printf '%s\n' "\$url" >> "\$CURL_URL_LOG"

if [[ -n "\$out" ]]; then
	cat > "\$out" <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$INSTALLER_ARGS_LOG"
exit 1
INSTALLER
	exit 0
fi

if [[ "\$url" == *"/main/install.sh"* ]]; then
	if [[ "$heal_mode" == "fail" ]]; then
		exit 22
	fi
	cat <<'HEAL'
#!/usr/bin/env bash
prefix=""
config=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		--prefix)
			prefix="\$2"
			shift 2
			;;
		--config)
			config="\$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done
printf '%s|%s|%s\n' "\${MOLE_VERSION:-}" "\$prefix" "\$config" >> "\$HEAL_LOG"
mkdir -p "\$prefix" "\$config/bin"
printf '#!/bin/bash\necho "Mole version %s"\n' "\${MOLE_VERSION#V}" > "\$prefix/mole.healed"
printf '#!/bin/bash\nexit 0\n' > "\$config/bin/analyze-go"
cp "\$config/bin/analyze-go" "\$config/bin/status-go"
chmod +x "\$prefix/mole.healed"
chmod +x "\$config/bin/analyze-go" "\$config/bin/status-go"
mv "\$prefix/mole.healed" "\$prefix/mole"
printf 'CHANNEL=stable\nINSTALL_RECEIPT=%s\n' "\${MOLE_INSTALL_RECEIPT:-}" > "\$config/install_channel"
rm -f "\$config/.helper_install_incomplete"
HEAL
	exit 0
fi

if [[ "\$url" == *"api.github.com"* ]]; then
	printf '{"tag_name":"%s"}\n' "$latest_version"
	exit 0
fi

printf 'VERSION="%s"\n' "$latest_version"
SCRIPT
	chmod +x "$bin_dir/curl"
}

make_false_success_curl_stub() {
	local bin_dir="$1"
	cat > "$bin_dir/curl" <<'SCRIPT'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		http*://*) url="$1"; shift ;;
		*) shift ;;
	esac
done

if [[ -n "$out" ]]; then
	cat > "$out" <<'INSTALLER'
#!/usr/bin/env bash
echo "Updated to latest version, ${MOLE_VERSION#V}"
exit 0
INSTALLER
	exit 0
fi

if [[ "$url" == *"api.github.com/repos/tw93/mole/commits/main"* ]]; then
	printf '{"sha":"%s"}\n' "$FALSE_SUCCESS_COMMIT"
	exit 0
fi
if [[ "$url" == *"api.github.com"* ]]; then
	printf '{"tag_name":"%s"}\n' "$FALSE_SUCCESS_VERSION"
	exit 0
fi
if [[ "$url" == *"/main/install.sh"* ]]; then
	exit 22
fi
printf 'VERSION="%s"\n' "$FALSE_SUCCESS_VERSION"
SCRIPT
	chmod +x "$bin_dir/curl"
}

@test "mo update rejects staged installer success when the stable generation did not change" {
	local manual_bin="$TEST_ROOT/false-stable/bin"
	local manual_config="$TEST_ROOT/false-stable/config"
	local fake_bin="$TEST_ROOT/false-stable/fake-bin"
	local current_version
	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"
	make_false_success_curl_stub "$fake_bin"

	run env HOME="$HOME" PATH="$fake_bin:/usr/bin:/bin" \
		FALSE_SUCCESS_VERSION="$current_version" \
		FALSE_SUCCESS_COMMIT="abc1234aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
		"$manual_bin/mo" update

	[ "$status" -ne 0 ]
	[[ "$output" == *"Retrying with a direct reinstall"* ]] || return 1
	[[ "$output" == *"Update failed"* ]] || return 1
	[[ "$output" != *"Updated to latest version"* ]] || return 1
	[ "$("$manual_bin/mole" --version | awk 'NF {print $NF; exit}')" = "0.0.1" ]
}

@test "mo update rejects staged installer success when nightly receipt and commit stay stale" {
	local manual_bin="$TEST_ROOT/false-nightly/bin"
	local manual_config="$TEST_ROOT/false-nightly/config"
	local fake_bin="$TEST_ROOT/false-nightly/fake-bin"
	local latest_commit="abc1234aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "1.41.0"
	printf 'CHANNEL=nightly\nCOMMIT_HASH=deadbee\nINSTALL_RECEIPT=old-receipt\n' > "$manual_config/install_channel"
	make_false_success_curl_stub "$fake_bin"

	run env HOME="$HOME" PATH="$fake_bin:/usr/bin:/bin" \
		FALSE_SUCCESS_VERSION="1.49.0" FALSE_SUCCESS_COMMIT="$latest_commit" \
		"$manual_bin/mo" update --nightly

	[ "$status" -ne 0 ]
	[[ "$output" == *"Retrying with a direct reinstall"* ]] || return 1
	[[ "$output" == *"Nightly update failed"* ]] || return 1
	[[ "$output" != *"Updated to latest version"* ]] || return 1
	grep -qFx 'COMMIT_HASH=deadbee' "$manual_config/install_channel"
}

@test "mo update self-heals with a direct reinstall when the staged installer fails (#1297)" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local heal_log="$TEST_ROOT/heal.log"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local current_version

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"
	make_self_heal_curl_stub "$fake_bin" "$current_version" "heal"
	: > "$curl_url_log"
	: > "$installer_args_log"
	: > "$heal_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		HEAL_LOG="$heal_log" \
		"$manual_bin/mo" update

	[ "$status" -eq 0 ] || return 1
	grep -q -- "--update" "$installer_args_log" || return 1
	[[ "$output" == *"Retrying with a direct reinstall"* ]] || return 1
	[[ "$output" == *"Updated to latest version, $current_version"* ]] || return 1
	[ "$(cat "$heal_log")" = "V$current_version|$manual_bin|$manual_config" ]
}

@test "mo update prints the manual reinstall command when self-heal fails too" {
	local manual_bin="$TEST_ROOT/manual/bin"
	local manual_config="$TEST_ROOT/manual/config"
	local fake_bin="$TEST_ROOT/fake-bin"
	local installer_args_log="$TEST_ROOT/installer.args"
	local heal_log="$TEST_ROOT/heal.log"
	local curl_url_log="$TEST_ROOT/curl.urls"
	local current_version

	current_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"
	make_self_heal_curl_stub "$fake_bin" "$current_version" "fail"
	: > "$curl_url_log"
	: > "$installer_args_log"
	: > "$heal_log"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		CURL_URL_LOG="$curl_url_log" \
		INSTALLER_ARGS_LOG="$installer_args_log" \
		HEAL_LOG="$heal_log" \
		"$manual_bin/mo" update

	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"Retrying with a direct reinstall"* ]] || return 1
	[[ "$output" == *"Update failed"* ]] || return 1
	[[ "$output" == *"MOLE_VERSION=V$current_version"* ]] || return 1
	[[ "$output" == *"--prefix $manual_bin"* ]] || return 1
	[[ "$output" == *"--config $manual_config"* ]]
}

make_nightly_self_heal_curl_stub() {
	local bin_dir="$1"
	local latest_commit="$2"
	cat > "$bin_dir/curl" << SCRIPT
#!/usr/bin/env bash
out=""
url=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		-o)
			out="\$2"
			shift 2
			;;
		http*://*)
			url="\$1"
			shift
			;;
		*)
			shift
			;;
	esac
done

if [[ -n "\$out" ]]; then
	cat > "\$out" <<'INSTALLER'
#!/usr/bin/env bash
exit 1
INSTALLER
	exit 0
fi

if [[ "\$url" == *"api.github.com/repos/tw93/mole/commits/main"* ]]; then
	printf '{"sha":"%s"}\n' "$latest_commit"
	exit 0
fi

if [[ "\$url" == *"/main/install.sh"* ]]; then
cat <<'HEAL'
#!/usr/bin/env bash
prefix=""
config=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		--prefix)
			prefix="\$2"
			shift 2
			;;
		--config)
			config="\$2"
			shift 2
			;;
		*) shift ;;
	esac
done
mkdir -p "\$config"
printf 'CHANNEL=nightly\nCOMMIT_HASH=%s\n' "\${LATEST_COMMIT:0:7}" > "\$config/install_channel"
printf '%s|%s|%s\n' "\${MOLE_VERSION:-}" "\$prefix" "\$config" > "\$HEAL_LOG"
[[ "\${MOLE_INSTALL_COMMIT:-}" == "$latest_commit" ]] || exit 1
[[ "\${MOLE_INSTALL_RECEIPT:-}" == heal-* ]] || exit 1
printf 'CHANNEL=nightly\nCOMMIT_HASH=%s\nINSTALL_RECEIPT=%s\n' \
	"\${MOLE_INSTALL_COMMIT:0:7}" "\$MOLE_INSTALL_RECEIPT" > "\$config/install_channel"
HEAL
	exit 0
fi

exit 22
SCRIPT
	chmod +x "$bin_dir/curl"
}

@test "mo update --nightly self-heals the selected install and verifies the main commit" {
	local manual_bin="$TEST_ROOT/manual-nightly/bin"
	local manual_config="$TEST_ROOT/manual-nightly/config"
	local fake_bin="$TEST_ROOT/nightly-fake-bin"
	local heal_log="$TEST_ROOT/nightly-heal.log"
	local latest_commit="abc1234aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	mkdir -p "$fake_bin"
	make_manual_mole_install "$manual_bin" "$manual_config" "0.0.1"
	make_nightly_self_heal_curl_stub "$fake_bin" "$latest_commit"

	run env \
		HOME="$HOME" \
		PATH="$fake_bin:/usr/bin:/bin" \
		LATEST_COMMIT="$latest_commit" \
		HEAL_LOG="$heal_log" \
		"$manual_bin/mo" update --nightly

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"Retrying with a direct reinstall"* ]] || return 1
	[[ "$output" == *"Updated to nightly build, abc1234"* ]] || return 1
	[ "$(cat "$heal_log")" = "main|$manual_bin|$manual_config" ] || return 1
	grep -qFx 'CHANNEL=nightly' "$manual_config/install_channel" || return 1
	grep -qFx 'COMMIT_HASH=abc1234' "$manual_config/install_channel"
}

@test "update lock rejects a live holder and reacquires after release" {
	run env HOME="$HOME/update-lock" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

mkdir -p "$HOME/install/bin"
/bin/chmod 0775 "$HOME/install/bin"
[[ "$(/usr/bin/stat -f%Lp "$HOME/install/bin")" == "775" ]] || exit 1
if ! _update_lock_path_has_unsafe_ancestor "$HOME/install/bin" true; then
	echo "UNEXPECTED_PRIVILEGED_GROUP_WRITABLE_UPDATE_PREFIX_ACCEPTED"
	exit 1
fi
acl_rule="everyone allow list,add_file,search,add_subdirectory,delete_child,file_inherit,directory_inherit"
/bin/chmod +a "$acl_rule" "$HOME/install/bin"
/bin/mkdir -m 0700 "$HOME/install/bin/acl-probe"
/bin/ls -lde "$HOME/install/bin/acl-probe" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:'
/bin/rmdir "$HOME/install/bin/acl-probe"
if _update_lock_mode_for_install_dir "$HOME/install/bin" > /dev/null; then
	echo "UNEXPECTED_WRITABLE_UPDATE_PARENT_ACL_ACCEPTED"
	exit 1
fi
/bin/chmod -N "$HOME/install/bin"
acl_rule="everyone deny writeattr,file_inherit,directory_inherit"
/bin/chmod +a "$acl_rule" "$HOME/install/bin"
[[ "$(_update_lock_mode_for_install_dir "$HOME/install/bin")" == "false" ]] || exit 1
lock_path=$(_update_lock_path "$HOME/install/bin")
_update_acquire_lock "$lock_path"
if /bin/ls -lde "$(dirname "$lock_path")" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:'; then
	echo "UNEXPECTED_INHERITED_UPDATE_LOCK_ACL"
	exit 1
fi
if _update_acquire_lock "$lock_path"; then
	echo "UNEXPECTED_CONCURRENT_LOCK"
	exit 1
fi
_update_release_lock "$lock_path" false "$UPDATE_LOCK_CONTROL" "$UPDATE_LOCK_HOLDER_PID" "$UPDATE_LOCK_ACQUIRED"
[[ -f "$lock_path" ]] || exit 1

holder_ready="$HOME/update-lock-holder.ready"
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
if _update_acquire_lock "$lock_path"; then
	external_lock_bypassed=true
	_update_release_lock "$lock_path" false "$UPDATE_LOCK_CONTROL" "$UPDATE_LOCK_HOLDER_PID" "$UPDATE_LOCK_ACQUIRED"
fi
cleanup_external_holder
trap - EXIT
if [[ "$external_lock_bypassed" == "true" ]]; then
	echo "UNEXPECTED_EXTERNAL_LOCK_BYPASS"
	exit 1
fi
_update_acquire_lock "$lock_path"
_update_release_lock "$lock_path" false "$UPDATE_LOCK_CONTROL" "$UPDATE_LOCK_HOLDER_PID" "$UPDATE_LOCK_ACQUIRED"
[[ -f "$lock_path" ]] || exit 1

victim="$HOME/update-lock-victim"
printf 'DO-NOT-TOUCH\n' > "$victim"
/bin/rm -f "$lock_path"
ln -s "$victim" "$lock_path"
if _update_acquire_lock "$lock_path"; then
	echo "UNEXPECTED_UPDATE_LOCK_SYMLINK_FOLLOW"
	exit 1
fi
[[ "$(cat "$victim")" == "DO-NOT-TOUCH" ]] || exit 1
unlink "$lock_path"

(
	actual_pid=""
	_update_lock_current_shell_pid actual_pid
	[[ "$actual_pid" =~ ^[0-9]+$ && "$actual_pid" != "$$" ]] || exit 1
	_update_acquire_lock "$lock_path"
	case "$(cat "$lock_path")" in
		"$actual_pid|"*) ;;
		*) exit 1 ;;
	esac
	_update_release_lock "$lock_path" false "$UPDATE_LOCK_CONTROL" "$UPDATE_LOCK_HOLDER_PID" "$UPDATE_LOCK_ACQUIRED"
)

! compgen -G "$HOME/install/bin/.mole-update.lock/control.*" > /dev/null || exit 1

declare -f _update_acquire_lock | grep -q '/usr/bin/lockf'
declare -f update_mole | grep -q 'local UPDATE_LOCK_CONTROL=""'
if _update_lock_remove_control "/tmp/not-a-mole-control" false "$lock_path"; then
	echo "UNEXPECTED_AMBIENT_CONTROL_REMOVAL"
	exit 1
fi
declare -f _update_verify_installed_generation | grep -q '_update_acquire_lock'
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"UNEXPECTED_CONCURRENT_LOCK"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_EXTERNAL_LOCK_BYPASS"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_UPDATE_LOCK_SYMLINK_FOLLOW"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_AMBIENT_CONTROL_REMOVAL"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_INHERITED_UPDATE_LOCK_ACL"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_WRITABLE_UPDATE_PARENT_ACL_ACCEPTED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_PRIVILEGED_GROUP_WRITABLE_UPDATE_PREFIX_ACCEPTED"* ]] || return 1
}

@test "nightly commit lookup and self-heal fall back to wget" {
	run env HOME="$HOME/wget-self-heal" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME/config/bin" "$HOME/bin"
printf '#!/bin/bash\necho "Mole version 0.0.1"\n' > "$HOME/bin/mole"
printf '#!/bin/bash\nexit 0\n' > "$HOME/config/bin/analyze-go"
cp "$HOME/config/bin/analyze-go" "$HOME/config/bin/status-go"
chmod +x "$HOME/bin/mole" "$HOME/config/bin/analyze-go" "$HOME/config/bin/status-go"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

expected_commit="def5678bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export expected_commit
command() {
	if [[ "$1" == "-v" && "$2" == "curl" ]]; then
		return 1
	fi
	builtin command "$@"
}
wget() {
	if [[ "$*" == *"api.github.com/repos/tw93/mole/commits/main"* ]]; then
		printf '{"sha":"%s"}\n' "$expected_commit"
		return 0
	fi
	cat <<'INSTALLER'
#!/usr/bin/env bash
config=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			config="$2"
			shift 2
			;;
		*) shift ;;
	esac
done
mkdir -p "$config"
[[ "${MOLE_INSTALL_COMMIT:-}" == "$expected_commit" ]] || exit 1
[[ "${MOLE_INSTALL_RECEIPT:-}" == heal-* ]] || exit 1
printf 'CHANNEL=nightly\nCOMMIT_HASH=def5678\nINSTALL_RECEIPT=%s\n' "$MOLE_INSTALL_RECEIPT" > "$config/install_channel"
INSTALLER
}

[[ "$(get_latest_commit_from_github)" == "$expected_commit" ]] || exit 1
_update_self_heal_reinstall 0 main "$HOME/bin" "$HOME/config" "$HOME/bin/mole" "nightly build" "$expected_commit"
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"Updated to nightly build, def5678"* ]]
}

@test "nightly self-heal accepts a fresh receipt without reusing a stale commit when HEAD is unknown" {
	run env HOME="$HOME/unknown-head-self-heal" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME/config/bin" "$HOME/bin"
printf '#!/bin/bash\necho "Mole version 0.0.1"\n' > "$HOME/bin/mole"
printf '#!/bin/bash\nexit 0\n' > "$HOME/config/bin/analyze-go"
cp "$HOME/config/bin/analyze-go" "$HOME/config/bin/status-go"
chmod +x "$HOME/bin/mole" "$HOME/config/bin/analyze-go" "$HOME/config/bin/status-go"
printf 'CHANNEL=nightly\nCOMMIT_HASH=deadbee\nINSTALL_RECEIPT=old-receipt\n' > "$HOME/config/install_channel"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

curl() {
	cat <<'INSTALLER'
#!/usr/bin/env bash
config=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			config="$2"
			shift 2
			;;
		*) shift ;;
	esac
done
mkdir -p "$config"
[[ -z "${MOLE_INSTALL_COMMIT:-}" ]] || exit 1
[[ "${MOLE_INSTALL_RECEIPT:-}" == heal-* ]] || exit 1
printf 'CHANNEL=nightly\nINSTALL_RECEIPT=%s\n' "$MOLE_INSTALL_RECEIPT" > "$config/install_channel"
INSTALLER
}

# A GitHub API rate limit leaves the expected commit empty. The verified
# reinstall must still report success instead of "Nightly update failed".
_update_self_heal_reinstall 0 main "$HOME/bin" "$HOME/config" "$HOME/bin/mole" "nightly build" ""
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"Updated to nightly build"* ]] || return 1
	[[ "$output" != *"deadbee"* ]] || return 1
	run grep -q '^COMMIT_HASH=' "$HOME/unknown-head-self-heal/config/install_channel"
	[ "$status" -eq 1 ]
}

@test "nightly self-heal rejects stale metadata when this install writes no receipt" {
	run env HOME="$HOME/stale-receipt-self-heal" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME/config" "$HOME/bin"
printf '#!/bin/bash\necho "Mole version 0.0.1"\n' > "$HOME/bin/mole"
chmod +x "$HOME/bin/mole"
printf 'CHANNEL=nightly\nCOMMIT_HASH=deadbee\nINSTALL_RECEIPT=old-receipt\n' > "$HOME/config/install_channel"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

curl() {
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0'
}

if _update_self_heal_reinstall 0 main "$HOME/bin" "$HOME/config" "$HOME/bin/mole" "nightly build" ""; then
	exit 1
fi
exit 0
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"Updated to nightly build"* ]]
}

@test "nightly self-heal bounds the installed binary version probe" {
	local timeout_cmd="timeout"
	command -v timeout > /dev/null 2>&1 || timeout_cmd="gtimeout"
	command -v "$timeout_cmd" > /dev/null 2>&1 || skip "timeout command unavailable"

	# The inner 0.1-second probe is the behavior under test. Keep the outer
	# timeout as a generous deadman for a real regression so a loaded parallel
	# CI runner cannot fail the correct path merely from scheduling delay.
	run "$timeout_cmd" 10 env HOME="$HOME/bounded-version-self-heal" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TIMEOUT_QUICK_DETECT_SEC=0.1 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME/config" "$HOME/bin"
printf '#!/bin/bash\nsleep 30\n' > "$HOME/bin/mole"
chmod +x "$HOME/bin/mole"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

curl() {
	cat <<'INSTALLER'
#!/usr/bin/env bash
config=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--config) config="$2"; shift 2 ;;
		*) shift ;;
	esac
done
mkdir -p "$config"
printf 'CHANNEL=nightly\nCOMMIT_HASH=fee1bad\nINSTALL_RECEIPT=%s\n' "$MOLE_INSTALL_RECEIPT" > "$config/install_channel"
INSTALLER
}

if _update_self_heal_reinstall 0 main "$HOME/bin" "$HOME/config" "$HOME/bin/mole" "nightly build" ""; then
	exit 1
fi
exit 0
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "nightly self-heal fails when the installed binary does not answer" {
	run env HOME="$HOME/dead-binary-self-heal" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
mkdir -p "$HOME/config" "$HOME/bin"
source "$PROJECT_ROOT/lib/core/common.sh"
VERSION="0.0.1"
SCRIPT_DIR="$HOME/config"
source "$PROJECT_ROOT/lib/manage/update.sh"

curl() {
	cat <<'INSTALLER'
#!/usr/bin/env bash
config=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			config="$2"
			shift 2
			;;
		*) shift ;;
	esac
done
mkdir -p "$config"
printf 'CHANNEL=nightly\nCOMMIT_HASH=fee1bad\n' > "$config/install_channel"
INSTALLER
}

# The registry claims success but no binary exists at the install path.
# Success asserted from installer output alone is the V1.47.1 shape.
if _update_self_heal_reinstall 0 main "$HOME/bin" "$HOME/config" "$HOME/bin/mole" "nightly build" ""; then
	exit 1
fi
exit 0
INNER

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"Updated to nightly build"* ]]
}

@test "update sudo predicate agrees with the installer's needs_sudo" {
	# The two sides must decide sudo identically. An existing writable
	# install dir needs none even under a root-owned parent (the installer
	# only touches the dir itself); a missing dir defers to the parent; an
	# unwritable dir or entry script needs sudo. Getting the first case
	# wrong forced authentication and aborted non-interactive updates the
	# installer could have completed without sudo.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
VERSION="0.0.0"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"

root="$HOME/sudo-predicate"
mkdir -p "$root/locked-parent/bin" "$root/locked-parent-missing" "$root/locked-bin/bin"
chmod 555 "$root/locked-parent-missing" "$root/locked-bin/bin"
trap 'chmod -R 755 "$root" 2>/dev/null || true' EXIT

if ! update_install_requires_sudo "$root/locked-parent/bin"; then
    chmod 555 "$root/locked-parent"
    if ! update_install_requires_sudo "$root/locked-parent/bin"; then
        echo "EXISTING_WRITABLE=no-sudo"
    fi
    chmod 755 "$root/locked-parent"
fi
if update_install_requires_sudo "$root/locked-parent-missing/bin"; then
    echo "MISSING_UNDER_LOCKED=needs-sudo"
fi
if update_install_requires_sudo "$root/locked-bin/bin"; then
    echo "UNWRITABLE_DIR=needs-sudo"
fi
mkdir -p "$root/readonly-mole/bin"
touch "$root/readonly-mole/bin/mole"
chmod 444 "$root/readonly-mole/bin/mole"
if ! update_install_requires_sudo "$root/readonly-mole/bin"; then
    echo "READONLY_MOLE=no-sudo"
fi
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"EXISTING_WRITABLE=no-sudo"* ]] || return 1
	[[ "$output" == *"MISSING_UNDER_LOCKED=needs-sudo"* ]] || return 1
	[[ "$output" == *"UNWRITABLE_DIR=needs-sudo"* ]] || return 1
	# A read-only entry script in a writable dir is replaced by atomic mv,
	# which needs directory write only; the installer never sudos for it.
	[[ "$output" == *"READONLY_MOLE=no-sudo"* ]] || return 1
}

@test "a Cellar symlink is a Homebrew install even when brew cannot confirm (#1488)" {
	local case_root="$TEST_ROOT/cellar-evidence"
	local cellar_mole="$case_root/Cellar/mole/9.9.9/bin/mole"
	mkdir -p "$(dirname "$cellar_mole")" "$case_root/bin"
	: > "$cellar_mole"
	ln -s "$cellar_mole" "$case_root/bin/mole"

	run env PROJECT_ROOT="$PROJECT_ROOT" CASE_ROOT="$case_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"
# A flaky or absent brew must not flip the on-disk evidence to "manual":
# that verdict is what let the manual updater overwrite brew's symlinks.
brew_mole_formula_installed() { return 1; }
is_homebrew_mole_path "$CASE_ROOT/bin/mole" false || exit 1
is_homebrew_mole_path "$CASE_ROOT/bin/mole" true || exit 1
echo "CELLAR_EVIDENCE_OK"
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"CELLAR_EVIDENCE_OK"* ]]
}

@test "brew update repairs only launchers pinning a removed keg (#1488)" {
	local prefix="$TEST_ROOT/heal-prefix"
	mkdir -p "$prefix/bin" "$prefix/Cellar/mole/9.9.9/libexec"
	local brew_log="$TEST_ROOT/heal-brew.log"
	: > "$brew_log"

	run env PROJECT_ROOT="$PROJECT_ROOT" PREFIX="$prefix" BREW_LOG="$brew_log" HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() { shift; "$@"; }
brew() {
	printf '%s\n' "$*" >> "$BREW_LOG"
	case "${1:-}" in
		--prefix) printf '%s\n' "$PREFIX" ;;
	esac
	return 0
}

# 1. Stale brew wrapper: SCRIPT_DIR pins a Cellar keg that no longer exists.
printf "#!/bin/bash\nSCRIPT_DIR='%s'\n" "$PREFIX/Cellar/mole/1.49.1/libexec" > "$PREFIX/bin/mole"
_mole_repair_stale_brew_entries
grep -q "link --overwrite mole" "$BREW_LOG" || { echo "MISSING_REPAIR"; exit 1; }

# 2. Healthy brew wrapper: keg exists, no relink.
: > "$BREW_LOG"
printf "#!/bin/bash\nSCRIPT_DIR='%s'\n" "$PREFIX/Cellar/mole/9.9.9/libexec" > "$PREFIX/bin/mole"
_mole_repair_stale_brew_entries
grep -q "link --overwrite" "$BREW_LOG" && { echo "UNEXPECTED_REPAIR_HEALTHY"; exit 1; }

# 3. Manual launcher: SCRIPT_DIR points at the config dir, never touched.
: > "$BREW_LOG"
printf '#!/bin/bash\nSCRIPT_DIR="%s"\n' "$HOME/.config/mole" > "$PREFIX/bin/mole"
_mole_repair_stale_brew_entries
grep -q "link --overwrite" "$BREW_LOG" && { echo "UNEXPECTED_REPAIR_MANUAL"; exit 1; }

# 4. Dangling symlink into a removed keg is evidence too.
: > "$BREW_LOG"
rm -f "$PREFIX/bin/mole"
ln -s "$PREFIX/Cellar/mole/1.49.1/bin/mole" "$PREFIX/bin/mole"
_mole_repair_stale_brew_entries
grep -q "link --overwrite mole" "$BREW_LOG" || { echo "MISSING_REPAIR_DANGLING"; exit 1; }

echo "HEAL_SHAPE_OK"
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"HEAL_SHAPE_OK"* ]]
}

@test "install channel comes from this install's own receipt, not a stale default (#1589)" {
	# install.sh --config moves the config dir and the launcher records where it
	# went in SCRIPT_DIR. Reading the default path first let a receipt left by an
	# earlier default install decide which channel a relocated install updates
	# from, which is how a stable install could silently start taking nightlies.
	local relocated="$TEST_ROOT/relocated"
	mkdir -p "$relocated" "$HOME/.config/mole"
	printf 'CHANNEL=nightly\n' > "$HOME/.config/mole/install_channel"
	printf 'CHANNEL=stable\n' > "$relocated/install_channel"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" RELOCATED="$relocated" \
		/bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
SCRIPT_DIR="$RELOCATED"
source "$PROJECT_ROOT/lib/core/common.sh" > /dev/null 2>&1
source "$PROJECT_ROOT/lib/manage/update.sh" > /dev/null 2>&1
get_install_channel
INNER

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"stable"* ]] || { echo "got: $output"; return 1; }
	[[ "$output" != *"nightly"* ]] || { echo "got: $output"; return 1; }
}
