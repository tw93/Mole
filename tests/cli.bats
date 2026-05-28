#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	# Capture real GOCACHE before HOME is replaced with a temp dir.
	# Without this, go build would use $HOME/Library/Caches/go-build inside the
	# temp dir (empty), causing a full cold rebuild on every test run (~6s).
	ORIGINAL_GOCACHE="$(go env GOCACHE 2>/dev/null || true)"
	export ORIGINAL_GOCACHE

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-cli-home.XXXXXX")"
	export HOME

	mkdir -p "$HOME"

	CLI_OWNS_GO_HELPERS=0
	export CLI_OWNS_GO_HELPERS

	if [[ -x "${ROOMY_TEST_ANALYZE_BIN:-}" && -x "${ROOMY_TEST_STATUS_BIN:-}" ]]; then
		ANALYZE_BIN="$ROOMY_TEST_ANALYZE_BIN"
		STATUS_BIN="$ROOMY_TEST_STATUS_BIN"
		export ANALYZE_BIN STATUS_BIN
	elif command -v go > /dev/null 2>&1; then
		# Build Go binaries from current source for JSON tests.
		# Point GOPATH/GOMODCACHE/GOCACHE at the real home so local focused runs
		# can reuse caches when the full runner did not prebuild helpers.
		ANALYZE_BIN="$(mktemp "${TMPDIR:-/tmp}/analyze-go.XXXXXX")"
		STATUS_BIN="$(mktemp "${TMPDIR:-/tmp}/status-go.XXXXXX")"
		GOPATH="${ORIGINAL_HOME}/go" GOMODCACHE="${ORIGINAL_HOME}/go/pkg/mod" \
			GOCACHE="${ORIGINAL_GOCACHE}" \
			go build -o "$ANALYZE_BIN" "$PROJECT_ROOT/cmd/analyze" 2>/dev/null
		GOPATH="${ORIGINAL_HOME}/go" GOMODCACHE="${ORIGINAL_HOME}/go/pkg/mod" \
			GOCACHE="${ORIGINAL_GOCACHE}" \
			go build -o "$STATUS_BIN" "$PROJECT_ROOT/cmd/status" 2>/dev/null
		CLI_OWNS_GO_HELPERS=1
		export ANALYZE_BIN STATUS_BIN
	fi
}

teardown_file() {
	rm -rf "$HOME/.config/roomy"
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
	if [[ "${CLI_OWNS_GO_HELPERS:-0}" == "1" ]]; then
		rm -f "${ANALYZE_BIN:-}" "${STATUS_BIN:-}"
	fi
}

create_fake_utils() {
	local dir="$1"
	mkdir -p "$dir"

	cat >"$dir/sudo" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-n" || "$1" == "-v" ]]; then
    exit 0
fi
exec "$@"
SCRIPT
	chmod +x "$dir/sudo"

	cat >"$dir/bioutil" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-r" ]]; then
    echo "Touch ID: 1"
    exit 0
fi
exit 0
SCRIPT
	chmod +x "$dir/bioutil"
}

setup() {
	rm -rf "$HOME/.config/roomy"
	mkdir -p "$HOME/.config/roomy"
}

@test "roomy --help prints command overview" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"roomy clean"* ]]
	[[ "$output" == *"roomy optimize"* ]]
	[[ "$output" == *"roomy analyze"* ]]
	[[ "$output" == *"roomy schedule"* ]]
	[[ "$output" == *"roomy restore"* ]]
	[[ "$output" == *"roomy report"* ]]
	[[ "$output" == *"roomy profile"* ]]
	[[ "$output" != *"roomy optimise"* ]]
}

@test "roomy clean lists selectable categories" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" clean --list-categories
	[ "$status" -eq 0 ]
	[[ "$output" == *"browsers"* ]]
	[[ "$output" == *"developer"* ]]
	[[ "$output" == *"project-artifacts"* ]]
}

@test "roomy schedule dry-run shows launchd plan" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" schedule enable --dry-run --weekly --time 03:15 --command clean
	[ "$status" -eq 0 ]
	[[ "$output" == *"Would enable Roomy schedule"* ]]
	[[ "$output" == *"weekly"* ]]
	[[ "$output" == *"03:15"* ]]
}

@test "roomy schedule status treats schedule config as data" {
	local config_dir="$HOME/.config/roomy"
	local launch_dir="$HOME/Library/LaunchAgents"
	local marker="$HOME/schedule-pwned"
	mkdir -p "$config_dir" "$launch_dir"
	: > "$launch_dir/com.roomy.maintenance.plist"
	# shellcheck disable=SC2016
	printf '%s\n' \
		'CADENCE=weekly' \
		'TIME=03:15' \
		'COMMAND=$(touch "$HOME/schedule-pwned")' \
		'EXECUTE=false' \
		> "$config_dir/schedule.conf"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" schedule status
	[ "$status" -eq 0 ]
	[[ "$output" == *"Roomy schedule: enabled"* ]]
	[[ "$output" != *"schedule-pwned"* ]]
	[[ ! -e "$marker" ]]
}

@test "roomy schedule enable writes plist and readable config" {
	local config_dir="$HOME/config dir"
	local launch_dir="$HOME/Launch Agents"
	local plist="$launch_dir/com.roomy.maintenance.plist"

	run env HOME="$HOME" ROOMY_CONFIG_DIR="$config_dir" ROOMY_LAUNCH_AGENTS_DIR="$launch_dir" \
		"$PROJECT_ROOT/roomy" schedule enable --daily --time 04:20 --command purge --execute
	[ "$status" -eq 0 ]
	[[ "$output" == *"Roomy schedule enabled"* ]]
	[[ -f "$plist" ]]
	[[ -f "$config_dir/schedule.conf" ]]

	run env HOME="$HOME" ROOMY_CONFIG_DIR="$config_dir" ROOMY_LAUNCH_AGENTS_DIR="$launch_dir" \
		"$PROJECT_ROOT/roomy" schedule status
	[ "$status" -eq 0 ]
	[[ "$output" == *"Cadence: daily"* ]]
	[[ "$output" == *"Time: 04:20"* ]]
	[[ "$output" == *"Command: purge"* ]]
	[[ "$output" == *"Mode: execute"* ]]

	run grep -F "<string>purge</string>" "$plist"
	[ "$status" -eq 0 ]
	run grep -F "<string>--dry-run</string>" "$plist"
	[ "$status" -ne 0 ]
}

@test "roomy schedule enable replaces schedule file symlinks without following them" {
	local config_dir="$HOME/config"
	local launch_dir="$HOME/LaunchAgents"
	local plist="$launch_dir/com.roomy.maintenance.plist"
	local outside_plist="$HOME/outside.plist"
	local outside_config="$HOME/outside.conf"
	mkdir -p "$config_dir" "$launch_dir"
	printf 'keep plist\n' > "$outside_plist"
	printf 'keep config\n' > "$outside_config"
	ln -s "$outside_plist" "$plist"
	ln -s "$outside_config" "$config_dir/schedule.conf"

	run env HOME="$HOME" ROOMY_CONFIG_DIR="$config_dir" ROOMY_LAUNCH_AGENTS_DIR="$launch_dir" \
		"$PROJECT_ROOT/roomy" schedule enable --daily --time 04:20 --command purge
	[ "$status" -eq 0 ]
	[[ "$output" == *"Roomy schedule enabled"* ]]

	run cat "$outside_plist"
	[ "$status" -eq 0 ]
	[[ "$output" == "keep plist" ]]
	run cat "$outside_config"
	[ "$status" -eq 0 ]
	[[ "$output" == "keep config" ]]
	[[ -f "$plist" && ! -L "$plist" ]]
	[[ -f "$config_dir/schedule.conf" && ! -L "$config_dir/schedule.conf" ]]
	run grep -F "<string>purge</string>" "$plist"
	[ "$status" -eq 0 ]
	run grep -F "COMMAND=purge" "$config_dir/schedule.conf"
	[ "$status" -eq 0 ]
}

@test "roomy schedule refuses unsafe schedule file overrides" {
	local outside_plist="$BATS_TEST_TMPDIR/outside.plist"
	local outside_config="$BATS_TEST_TMPDIR/outside.conf"
	printf 'keep\n' > "$outside_plist"
	printf 'keep\n' > "$outside_config"

	run env HOME="$HOME" ROOMY_SCHEDULE_PLIST="$outside_plist" "$PROJECT_ROOT/roomy" schedule disable
	[ "$status" -ne 0 ]
	[[ "$output" == *"Schedule plist path must be under HOME"* ]]
	run cat "$outside_plist"
	[ "$status" -eq 0 ]
	[[ "$output" == "keep" ]]

	run env HOME="$HOME" ROOMY_SCHEDULE_CONFIG="$outside_config" "$PROJECT_ROOT/roomy" schedule enable --daily
	[ "$status" -ne 0 ]
	[[ "$output" == *"Schedule config path must be under HOME"* ]]
	run cat "$outside_config"
	[ "$status" -eq 0 ]
	[[ "$output" == "keep" ]]
}

@test "roomy schedule refuses symlinked schedule directories" {
	local outside_launch="$HOME/outside-launch"
	local launch_link="$HOME/LaunchAgentsLink"
	local outside_config="$HOME/outside-config"
	local config_link="$HOME/config-link"
	mkdir -p "$outside_launch" "$outside_config"
	ln -s "$outside_launch" "$launch_link"
	ln -s "$outside_config" "$config_link"

	run env HOME="$HOME" ROOMY_LAUNCH_AGENTS_DIR="$launch_link" "$PROJECT_ROOT/roomy" schedule enable --daily
	[ "$status" -ne 0 ]
	[[ "$output" == *"Schedule LaunchAgents directory must not be a symlink"* ]]

	run env HOME="$HOME" ROOMY_CONFIG_DIR="$config_link" "$PROJECT_ROOT/roomy" schedule enable --daily
	[ "$status" -ne 0 ]
	[[ "$output" == *"Schedule config directory must not be a symlink"* ]]
}

@test "roomy schedule refuses label path injection" {
	run env HOME="$HOME" ROOMY_SCHEDULE_LABEL='../evil' "$PROJECT_ROOT/roomy" schedule enable --daily
	[ "$status" -ne 0 ]
	[[ "$output" == *"Invalid schedule label"* ]]
	[[ ! -e "$HOME/Library/evil.plist" ]]
}

@test "roomy profile saves and lists current config" {
	printf '/tmp/keep\n' > "$HOME/.config/roomy/whitelist"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile saved: dev"* ]]

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile list
	[ "$status" -eq 0 ]
	[[ "$output" == *"dev"* ]]
}

@test "roomy profile exports imports and applies known config files" {
	local archive="$BATS_TEST_TMPDIR/dev-profile.tar.gz"
	local tmp_root="$BATS_TEST_TMPDIR/profile tmp"
	mkdir -p "$tmp_root"
	printf '/tmp/keep\n' > "$HOME/.config/roomy/whitelist"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -eq 0 ]

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile export dev --to "$archive"
	[ "$status" -eq 0 ]
	[[ -f "$archive" ]]

	printf '/tmp/changed\n' > "$HOME/.config/roomy/whitelist"

	run env HOME="$HOME" TMPDIR="$tmp_root" "$PROJECT_ROOT/roomy" profile import imported --from "$archive"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile imported: imported"* ]]
	run find "$tmp_root" -maxdepth 1 -name 'roomy.*' -print
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile apply imported
	[ "$status" -eq 0 ]
	run cat "$HOME/.config/roomy/whitelist"
	[ "$status" -eq 0 ]
	[[ "$output" == "/tmp/keep" ]]
}

@test "roomy profile create replaces stale profile snapshots" {
	printf '/tmp/keep\n' > "$HOME/.config/roomy/whitelist"
	printf "$HOME/Projects\n" > "$HOME/.config/roomy/purge_paths"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -eq 0 ]
	[[ -f "$HOME/.config/roomy/profiles/dev/purge_paths" ]]

	rm -f "$HOME/.config/roomy/purge_paths"
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -eq 0 ]
	[[ -f "$HOME/.config/roomy/profiles/dev/whitelist" ]]
	[[ ! -e "$HOME/.config/roomy/profiles/dev/purge_paths" ]]
}

@test "roomy profile create rejects symlinked config files" {
	printf 'secret\n' > "$HOME/secret"
	ln -s "$HOME/secret" "$HOME/.config/roomy/whitelist"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"Config file whitelist is not a regular file"* ]]
	[[ ! -e "$HOME/.config/roomy/profiles/dev" ]]
}

@test "roomy profile create refuses symlinked config and profile roots" {
	local outside_config="$HOME/outside-config"
	local outside_profiles="$HOME/outside-profiles"

	rm -rf "$HOME/.config/roomy"
	mkdir -p "$outside_config"
	ln -s "$outside_config" "$HOME/.config/roomy"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"Profile config directory must not be a symlink"* ]]
	[[ ! -e "$outside_config/profiles/dev" ]]

	rm -rf "$HOME/.config/roomy"
	mkdir -p "$HOME/.config/roomy" "$outside_profiles"
	ln -s "$outside_profiles" "$HOME/.config/roomy/profiles"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -ne 0 ]
	[[ "$output" == *"Profile directory must not be a symlink"* ]]
	[[ ! -e "$outside_profiles/dev" ]]
}

@test "roomy profile apply replaces config files without following symlinks" {
	mkdir -p "$HOME/.config/roomy/profiles/dev"
	printf '/tmp/profile\n' > "$HOME/.config/roomy/profiles/dev/whitelist"
	printf 'outside\n' > "$HOME/outside"
	printf "$HOME/Projects\n" > "$HOME/.config/roomy/purge_paths"
	ln -s "$HOME/outside" "$HOME/.config/roomy/whitelist"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile apply dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile applied: dev (1 files)"* ]]

	run cat "$HOME/outside"
	[ "$status" -eq 0 ]
	[[ "$output" == "outside" ]]
	[[ ! -L "$HOME/.config/roomy/whitelist" ]]
	run cat "$HOME/.config/roomy/whitelist"
	[ "$status" -eq 0 ]
	[[ "$output" == "/tmp/profile" ]]
	[[ ! -e "$HOME/.config/roomy/purge_paths" ]]
}

@test "roomy profile import rejects symlink entries" {
	local src="$BATS_TEST_TMPDIR/profile-archive"
	local archive="$BATS_TEST_TMPDIR/profile-symlink.tar.gz"
	mkdir -p "$src/bad"
	printf 'secret\n' > "$HOME/secret"
	ln -s "$HOME/secret" "$src/bad/whitelist"
	tar -C "$src" -czf "$archive" bad

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile import bad --from "$archive"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsafe link or special file"* ]]
	[[ ! -e "$HOME/.config/roomy/profiles/bad" ]]
}

@test "roomy profile import rejects path traversal archive entries" {
	local src="$BATS_TEST_TMPDIR/profile-traversal"
	local archive="$BATS_TEST_TMPDIR/profile-traversal.tar.gz"
	mkdir -p "$src"
	printf '/tmp/unsafe\n' > "$src/whitelist"
	if ! tar -C "$src" -czf "$archive" -s '|^whitelist$|bad/../whitelist|' whitelist 2> /dev/null; then
		if ! tar -C "$src" --transform='s#^whitelist$#bad/../whitelist#' -czf "$archive" whitelist 2> /dev/null; then
			skip "tar cannot rewrite archive member names"
		fi
	fi

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile import bad --from "$archive"
	[ "$status" -ne 0 ]
	[[ "$output" == *"path traversal"* ]]
	[[ ! -e "$HOME/.config/roomy/profiles/bad" ]]
}

@test "roomy profile import rejects multiple top-level archive roots" {
	local src="$BATS_TEST_TMPDIR/profile-multiroot"
	local archive="$BATS_TEST_TMPDIR/profile-multiroot.tar.gz"
	mkdir -p "$src/one" "$src/two"
	printf '/tmp/one\n' > "$src/one/whitelist"
	printf '/tmp/two\n' > "$src/two/whitelist"
	tar -C "$src" -czf "$archive" one two

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile import bad --from "$archive"
	[ "$status" -ne 0 ]
	[[ "$output" == *"exactly one top-level directory"* ]]
	[[ ! -e "$HOME/.config/roomy/profiles/bad" ]]
}

@test "roomy profile delete removes saved profile" {
	printf '/tmp/keep\n' > "$HOME/.config/roomy/whitelist"

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile create dev
	[ "$status" -eq 0 ]
	[[ -d "$HOME/.config/roomy/profiles/dev" ]]

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" profile delete dev
	[ "$status" -eq 0 ]
	[[ "$output" == *"Profile deleted: dev"* ]]
	[[ ! -e "$HOME/.config/roomy/profiles/dev" ]]
}

@test "roomy report summarizes operation journal" {
	local log_dir="$HOME/logs"
	local now
	now="$(date '+%Y-%m-%d %H:%M:%S')"
	mkdir -p "$log_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"$now\",\"record_type\":\"session\",\"command\":\"clean\",\"action\":\"ENDED\",\"path\":\"\",\"detail\":\"2 items, 2 MB\"}" \
		"{\"schema_version\":1,\"timestamp\":\"$now\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"REMOVED\",\"path\":\"/tmp/a\",\"detail\":\"1 MB\"}" \
		> "$log_dir/operation_journal.jsonl"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" report --last 1d
	[ "$status" -eq 0 ]
	[[ "$output" == *"Sessions: 1"* ]]
	[[ "$output" == *"REMOVED: 1"* ]]
	[[ "$output" == *"clean: 1 sessions"* ]]
}

@test "roomy report cleans temporary files" {
	local log_dir="$HOME/logs"
	local tmp_root="$BATS_TEST_TMPDIR/report tmp"
	mkdir -p "$log_dir" "$tmp_root"
	printf '%s\n' \
		'{"schema_version":1,"timestamp":"2026-05-13 10:00:00","record_type":"session","command":"clean","action":"ENDED","path":"","detail":"1 items, 1 KB"}' \
		'{"schema_version":1,"timestamp":"2026-05-13 10:00:01","record_type":"operation","command":"clean","action":"REMOVED","path":"/tmp/a","detail":"1 KB"}' \
		> "$log_dir/operation_journal.jsonl"

	run env HOME="$HOME" TMPDIR="$tmp_root" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" report --json
	[ "$status" -eq 0 ]
	[[ "$output" == *'"sessions":1'* ]]

	run find "$tmp_root" -maxdepth 1 -name 'roomy.*' -print
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "roomy report preserves escaped control-character paths" {
	local log_dir="$HOME/logs"
	local original="$BATS_TEST_TMPDIR/path"$'\t'"with"$'\n'"newline.txt"
	local escaped="$original"
	mkdir -p "$log_dir"

	escaped="${escaped//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\t'/\\t}"
	escaped="${escaped//$'\r'/\\r}"
	escaped="${escaped//$'\n'/\\n}"
	printf '{"schema_version":1,"timestamp":"2026-05-13 10:00:00","record_type":"operation","command":"clean","action":"REMOVED","path":"%s","detail":"1 KB"}\n' "$escaped" \
		> "$log_dir/operation_journal.jsonl"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" report --json
	[ "$status" -eq 0 ]
	[[ "$output" == *'\\twith\\nnewline.txt'* ]]
	[[ "$output" != *"pathtwithnnewline.txt"* ]]
}

@test "roomy restore previews a restorable Trash item" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local original="$BATS_TEST_TMPDIR/original.txt"
	mkdir -p "$log_dir" "$trash_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"uninstall\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	printf 'x' > "$trash_dir/original.txt"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --dry-run "$original"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Would restore"* ]]
	[[ "$output" == *"$original"* ]]
}

@test "roomy restore decodes escaped control-character paths before validation" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local parent="$BATS_TEST_TMPDIR/control restore"
	local original="$parent/path"$'\t'"with"$'\n'"newline.txt"
	local escaped="$original"
	local base
	mkdir -p "$log_dir" "$trash_dir" "$parent"
	base="$(basename "$original")"
	printf 'x' > "$trash_dir/$base"

	escaped="${escaped//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\t'/\\t}"
	escaped="${escaped//$'\r'/\\r}"
	escaped="${escaped//$'\n'/\\n}"
	printf '{"schema_version":1,"timestamp":"2026-05-13 10:00:00","record_type":"operation","command":"uninstall","action":"TRASHED","path":"%s","detail":"5KB"}\n' "$escaped" \
		> "$log_dir/operation_journal.jsonl"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --dry-run "$original"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe restore destination:"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
}

@test "roomy restore skips forged protected destinations" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local original="/etc/roomy-restore-owned"
	mkdir -p "$log_dir" "$trash_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	printf 'x' > "$trash_dir/roomy-restore-owned"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe restore destination: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ -f "$trash_dir/roomy-restore-owned" ]]
	[[ ! -e "$original" ]]
}

@test "roomy restore skips forged relative destinations" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local original="relative-restore-target"
	mkdir -p "$log_dir" "$trash_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	printf 'x' > "$trash_dir/relative-restore-target"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe restore destination: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ -f "$trash_dir/relative-restore-target" ]]
	[[ ! -e "$PROJECT_ROOT/$original" ]]
}

@test "roomy restore reports missing Trash items as not found" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local original="$BATS_TEST_TMPDIR/missing-restore-target"
	rm -rf "$trash_dir"
	mkdir -p "$log_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, Trash item not found or ambiguous: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ ! -e "$original" ]]
}

@test "roomy restore skips destinations through symlinked parents" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local link_parent="$BATS_TEST_TMPDIR/linked-parent"
	local original="$link_parent/roomy-restore-owned"
	mkdir -p "$log_dir" "$trash_dir"
	ln -s /etc "$link_parent"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	printf 'x' > "$trash_dir/roomy-restore-owned"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe restore destination: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ -f "$trash_dir/roomy-restore-owned" ]]
}

@test "roomy restore skips destinations through safe-looking symlinked parents" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local redirected="$BATS_TEST_TMPDIR/redirected-parent"
	local link_parent="$BATS_TEST_TMPDIR/safe-link-parent"
	local original="$link_parent/roomy-restore-owned"
	mkdir -p "$log_dir" "$trash_dir" "$redirected"
	ln -s "$redirected" "$link_parent"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	printf 'x' > "$trash_dir/roomy-restore-owned"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe restore destination: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ -f "$trash_dir/roomy-restore-owned" ]]
	[[ ! -e "$redirected/roomy-restore-owned" ]]
}

@test "roomy restore skips symlinked Trash directories" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local redirected_trash="$BATS_TEST_TMPDIR/redirected-trash"
	local original="$BATS_TEST_TMPDIR/redirected-file"
	rm -rf "$trash_dir"
	mkdir -p "$log_dir" "$redirected_trash"
	ln -s "$redirected_trash" "$trash_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	printf 'x' > "$redirected_trash/redirected-file"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe Trash directory: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ -f "$redirected_trash/redirected-file" ]]
	[[ ! -e "$original" ]]
}

@test "roomy restore skips unsafe Trash symlink candidates" {
	local log_dir="$HOME/logs"
	local trash_dir="$HOME/.Trash"
	local original="$BATS_TEST_TMPDIR/restore-link"
	rm -rf "$trash_dir"
	mkdir -p "$log_dir" "$trash_dir"
	printf '%s\n' \
		"{\"schema_version\":1,\"timestamp\":\"2026-05-13 10:00:00\",\"record_type\":\"operation\",\"command\":\"clean\",\"action\":\"TRASHED\",\"path\":\"$original\",\"detail\":\"5KB\"}" \
		> "$log_dir/operation_journal.jsonl"
	ln -s /etc/passwd "$trash_dir/restore-link"

	run env HOME="$HOME" ROOMY_LOG_DIR="$log_dir" "$PROJECT_ROOT/roomy" restore restore --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped, unsafe Trash item: $original"* ]]
	[[ "$output" == *"Restore complete: 0 restored, 1 skipped"* ]]
	[[ -L "$trash_dir/restore-link" ]]
	[[ ! -e "$original" && ! -L "$original" ]]
}

@test "roomy --version reports script version" {
	expected_version="$(grep '^VERSION=' "$PROJECT_ROOT/roomy" | head -1 | sed 's/VERSION=\"\(.*\)\"/\1/')"
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"$expected_version"* ]]
}

@test "roomy --version does not hang on slow Homebrew detection" {
	local fake_bin
	fake_bin="$(mktemp -d "${BATS_TEST_TMPDIR}/fake-bin.XXXXXX")"
	ln -s "$PROJECT_ROOT/roomy" "$fake_bin/roomy"
	cat > "$fake_bin/brew" <<'SCRIPT'
#!/usr/bin/env bash
sleep 3
exit 1
SCRIPT
	chmod +x "$fake_bin/brew"

	run env HOME="$HOME" PATH="$fake_bin:$PATH" ROOMY_HOMEBREW_DETECT_TIMEOUT=1 "$PROJECT_ROOT/roomy" --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Install: Manual"* ]]
}

@test "roomy --version shows nightly channel metadata" {
	expected_version="$(grep '^VERSION=' "$PROJECT_ROOT/roomy" | head -1 | sed 's/VERSION=\"\(.*\)\"/\1/')"
	mkdir -p "$HOME/.config/roomy"
	cat > "$HOME/.config/roomy/install_channel" <<'EOF'
CHANNEL=nightly
EOF

	run env HOME="$HOME" "$PROJECT_ROOT/roomy" --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Roomy version $expected_version"* ]]
	[[ "$output" == *"Channel: Nightly"* ]]
}

@test "roomy unknown command returns error" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" unknown-command
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: unknown-command"* ]]
}

@test "roomy --help does not list check command" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" --help
	[ "$status" -eq 0 ]
	[[ "$output" != *"roomy check"* ]]
}

@test "roomy check is not a public command" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" check --help
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: check"* ]]
}

@test "roomy doctor is not a public command" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" doctor --help
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: doctor"* ]]
}

@test "roomy optimize --check is not a public option" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" optimize --check
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown optimize option: --check"* ]]
}

@test "roomy uninstall --whitelist returns unsupported option error" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" uninstall --whitelist
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown uninstall option: --whitelist"* ]]
}

@test "show_main_menu hides update shortcut when no update notice is available" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME ROOMY_TEST_MODE=1 ROOMY_SKIP_MAIN=1
source "$PROJECT_ROOT/roomy"
show_brand_banner() { printf 'banner\n'; }
show_menu_option() { printf '%s' "$2"; }
MAIN_MENU_BANNER=""
MAIN_MENU_UPDATE_MESSAGE=""
MAIN_MENU_SHOW_UPDATE=false
show_main_menu 1 true
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"U Update"* ]]
}

@test "update message cache replaces symlinks and skips symlink reads" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME ROOMY_TEST_MODE=1 ROOMY_SKIP_MAIN=1
source "$PROJECT_ROOT/roomy"

cache_dir="$HOME/.cache/roomy"
msg_cache="$cache_dir/update_message"
protected="$HOME/protected-update-message"
mkdir -p "$cache_dir"
printf 'keep-update\n' > "$protected"
ln -s "$protected" "$msg_cache"

write_update_message_cache "$msg_cache" "safe update"
[[ ! -L "$msg_cache" ]]
[[ "$(cat "$protected")" == "keep-update" ]]
[[ "$(cat "$msg_cache")" == "safe update" ]]

rm -f "$msg_cache"
ln -s "$protected" "$msg_cache"
show_update_notification
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"keep-update"* ]]
}

@test "interactive_main_menu ignores U shortcut when update notice is hidden" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME ROOMY_TEST_MODE=1 ROOMY_SKIP_MAIN=1
source "$PROJECT_ROOT/roomy"
show_brand_banner() { :; }
show_main_menu() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
update_roomy() { echo "UPDATE_CALLED"; }
state_file="$HOME/read_key_state"
read_key() {
    if [[ ! -f "$state_file" ]]; then
        : > "$state_file"
        echo "UPDATE"
    else
        echo "QUIT"
    fi
}
interactive_main_menu
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"UPDATE_CALLED"* ]]
}

@test "interactive_main_menu accepts U shortcut when update notice is visible" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
HOME="$(mktemp -d)"
export HOME ROOMY_TEST_MODE=1 ROOMY_SKIP_MAIN=1
mkdir -p "$HOME/.cache/roomy"
printf 'update available\n' > "$HOME/.cache/roomy/update_message"
source "$PROJECT_ROOT/roomy"
show_brand_banner() { :; }
show_main_menu() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
update_roomy() { echo "UPDATE_CALLED"; }
read_key() { echo "UPDATE"; }
interactive_main_menu
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"UPDATE_CALLED"* ]]
}

@test "touchid status reports current configuration" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" touchid status
	[ "$status" -eq 0 ]
	[[ "$output" == *"Touch ID"* ]]
}

@test "roomy optimize command is recognized" {
	run bash -c "grep -Eq '\"optimi[sz]e\"[[:space:]]*\\|[[:space:]]*\"optimi[sz]e\"' '$PROJECT_ROOT/roomy'"
	[ "$status" -eq 0 ]
}

@test "roomy analyze binary is valid" {
	if [[ -f "$PROJECT_ROOT/bin/analyze-go" ]]; then
		[ -x "$PROJECT_ROOT/bin/analyze-go" ]
		run file "$PROJECT_ROOT/bin/analyze-go"
		[[ "$output" == *"Mach-O"* ]] || [[ "$output" == *"executable"* ]]
	else
		skip "analyze-go binary not built"
	fi
}

@test "roomy clean --debug creates debug log file" {
	mkdir -p "$HOME/.config/roomy"
	run env HOME="$HOME" TERM="xterm-256color" ROOMY_TEST_MODE=1 ROOMY_DEBUG=1 "$PROJECT_ROOT/roomy" clean --dry-run
	[ "$status" -eq 0 ]
	ROOMY_OUTPUT="$output"

	DEBUG_LOG="$HOME/Library/Logs/roomy/roomy_debug_session.log"
	[ -f "$DEBUG_LOG" ]

	run grep "Roomy Debug Session" "$DEBUG_LOG"
	[ "$status" -eq 0 ]

	[[ "$ROOMY_OUTPUT" =~ "Debug session log saved to" ]]
}

@test "roomy clean without debug does not show debug log path" {
	mkdir -p "$HOME/.config/roomy"
	run env HOME="$HOME" TERM="xterm-256color" ROOMY_TEST_MODE=1 ROOMY_DEBUG=0 "$PROJECT_ROOT/roomy" clean --dry-run
	[ "$status" -eq 0 ]

	[[ "$output" != *"Debug session log saved to"* ]]
}

@test "roomy clean --debug logs system info" {
	mkdir -p "$HOME/.config/roomy"
	run env HOME="$HOME" TERM="xterm-256color" ROOMY_TEST_MODE=1 ROOMY_DEBUG=1 "$PROJECT_ROOT/roomy" clean --dry-run
	[ "$status" -eq 0 ]

	DEBUG_LOG="$HOME/Library/Logs/roomy/roomy_debug_session.log"

	run grep "User:" "$DEBUG_LOG"
	[ "$status" -eq 0 ]

	run grep "Architecture:" "$DEBUG_LOG"
	[ "$status" -eq 0 ]
}

@test "roomy clean --help includes external volume option" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" clean --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--external PATH"* ]]
	[[ "$output" == *"already-uninstalled apps"* ]]
}

@test "roomy uninstall --help directs leftover-only cleanup to clean" {
	run env HOME="$HOME" "$PROJECT_ROOT/roomy" uninstall --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"already gone, use roomy clean"* ]]
}

@test "roomy clean --external accepts canonicalized custom root" {
	real_root="$(mktemp -d "$HOME/ext-real.XXXXXX")"
	link_root="$HOME/ext-link"
	ln -s "$real_root" "$link_root"
	mkdir -p "$link_root/USB/.Trashes"
	touch "$link_root/USB/.Trashes/cache.tmp"

	mock_bin="$HOME/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/diskutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$mock_bin/diskutil"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" ROOMY_EXTERNAL_VOLUMES_ROOT="$link_root" \
		ROOMY_TEST_NO_AUTH=1 "$PROJECT_ROOT/roomy" clean --external "$link_root/USB" --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"Clean External Volume"* ]]
	[[ "$output" == *"External volume cleanup"* ]]
}

@test "touchid status reflects pam file contents" {
	pam_file="$HOME/pam_test"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	run env ROOMY_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"not configured"* ]]

	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
EOF

	run env ROOMY_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"enabled"* ]]
}

@test "enable_touchid inserts pam_tid line in pam file" {
	pam_file="$HOME/pam_enable"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" ROOMY_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" enable
	[ "$status" -eq 0 ]
	grep -q "pam_tid.so" "$pam_file"
	[[ -f "${pam_file}.roomy-backup" ]]
}

@test "disable_touchid removes pam_tid line" {
	pam_file="$HOME/pam_disable"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
auth       sufficient     pam_opendirectory.so
EOF

	fake_bin="$HOME/fake-bin-disable"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" ROOMY_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" disable
	[ "$status" -eq 0 ]
	run grep "pam_tid.so" "$pam_file"
	[ "$status" -ne 0 ]
}

@test "touchid enable --dry-run does not modify pam file" {
	pam_file="$HOME/pam_enable_dry_run"
	cat >"$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

	run env ROOMY_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" enable --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY RUN MODE"* ]]

	run grep "pam_tid.so" "$pam_file"
	[ "$status" -ne 0 ]
}

@test "touchid enable refuses symlinked PAM targets" {
	pam_target="$HOME/pam_target"
	pam_link="$HOME/pam_link"
	cat >"$pam_target" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF
	ln -s "$pam_target" "$pam_link"

	fake_bin="$HOME/fake-bin-touchid-symlink"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" ROOMY_PAM_SUDO_FILE="$pam_link" "$PROJECT_ROOT/bin/touchid.sh" enable
	[ "$status" -ne 0 ]
	[[ "$output" == *"PAM sudo file must not be a symlink"* ]]

	run grep "pam_tid.so" "$pam_target"
	[ "$status" -ne 0 ]

	pam_file="$HOME/pam_with_sudo_local"
	sudo_local_target="$HOME/sudo_local_target"
	sudo_local_link="$HOME/sudo_local_link"
	cat >"$pam_file" <<'EOF'
auth       include        sudo_local
auth       sufficient     pam_opendirectory.so
EOF
	cat >"$sudo_local_target" <<'EOF'
# sudo_local: local customizations for sudo
EOF
	ln -s "$sudo_local_target" "$sudo_local_link"

	run env PATH="$fake_bin:$PATH" ROOMY_PAM_SUDO_FILE="$pam_file" ROOMY_PAM_SUDO_LOCAL_FILE="$sudo_local_link" \
		"$PROJECT_ROOT/bin/touchid.sh" enable
	[ "$status" -ne 0 ]
	[[ "$output" == *"PAM sudo_local file must not be a symlink"* ]]

	run grep "pam_tid.so" "$sudo_local_target"
	[ "$status" -ne 0 ]
}

@test "touchid disable refuses symlinked PAM sudo file" {
	pam_target="$HOME/pam_disable_target"
	pam_link="$HOME/pam_disable_link"
	cat >"$pam_target" <<'EOF'
auth       sufficient     pam_tid.so
auth       sufficient     pam_opendirectory.so
EOF
	ln -s "$pam_target" "$pam_link"

	fake_bin="$HOME/fake-bin-touchid-disable-symlink"
	create_fake_utils "$fake_bin"

	run env PATH="$fake_bin:$PATH" ROOMY_PAM_SUDO_FILE="$pam_link" "$PROJECT_ROOT/bin/touchid.sh" disable
	[ "$status" -ne 0 ]
	[[ "$output" == *"PAM sudo file must not be a symlink"* ]]

	grep -q "pam_tid.so" "$pam_target"
}

# --- JSON output mode tests ---

@test "roomy analyze --json outputs valid JSON with expected fields" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json /tmp
	[ "$status" -eq 0 ]

	# Validate it is parseable JSON
	echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"

	# Check required top-level keys
	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'path' in data, 'missing path'
assert 'overview' in data, 'missing overview'
assert 'entries' in data, 'missing entries'
assert 'total_size' in data, 'missing total_size'
assert 'total_files' in data, 'missing total_files'
assert isinstance(data['entries'], list), 'entries is not a list'
"
}

@test "roomy analyze --json entries contain required fields" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json /tmp
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data['overview'] is False, 'explicit path should not be overview mode'
for entry in data['entries']:
    assert 'name' in entry, 'entry missing name'
    assert 'path' in entry, 'entry missing path'
    assert 'size' in entry, 'entry missing size'
    assert 'is_dir' in entry, 'entry missing is_dir'
"
}

@test "roomy analyze --json path reflects target directory" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json /tmp
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data['path'] == '/tmp' or data['path'] == '/private/tmp', \
    f\"unexpected path: {data['path']}\"
"
}

@test "roomy analyze --json overview mode returns expected schema" {
	if [[ ! -x "${ANALYZE_BIN:-}" ]]; then
		skip "analyze binary not available (go not installed?)"
	fi

	run "$ANALYZE_BIN" --json
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'path' in data, 'missing path'
assert 'overview' in data, 'missing overview'
assert data['overview'] is True, 'overview scan should have overview: true'
assert 'entries' in data, 'missing entries'
assert 'total_size' in data, 'missing total_size'
assert isinstance(data['entries'], list), 'entries is not a list'
"
}

@test "roomy status --json outputs valid JSON with expected fields" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run "$STATUS_BIN" --json
	[ "$status" -eq 0 ]

	# Validate it is parseable JSON
	echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"

	# Check required top-level keys
	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key in ['cpu', 'memory', 'disks', 'health_score', 'host', 'uptime']:
    assert key in data, f'missing key: {key}'
"
}

@test "roomy status --json cpu section has expected structure" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run "$STATUS_BIN" --json
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cpu = data['cpu']
assert 'usage' in cpu, 'cpu missing usage'
assert 'logical_cpu' in cpu, 'cpu missing logical_cpu'
assert isinstance(cpu['usage'], (int, float)), 'cpu usage is not a number'
"
}

@test "roomy status --json memory section has expected structure" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	run "$STATUS_BIN" --json
	[ "$status" -eq 0 ]

	echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
mem = data['memory']
assert 'total' in mem, 'memory missing total'
assert 'used' in mem, 'memory missing used'
assert 'used_percent' in mem, 'memory missing used_percent'
assert mem['total'] > 0, 'memory total should be positive'
"
}

@test "roomy status --json piped to stdout auto-detects JSON mode" {
	if [[ ! -x "${STATUS_BIN:-}" ]]; then
		skip "status binary not available (go not installed?)"
	fi

	# When piped (not a tty), status should auto-detect and output JSON
	output=$("$STATUS_BIN" 2>/dev/null)
	echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)"
}
