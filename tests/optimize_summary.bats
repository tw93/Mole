#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_project_root

	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-summary.XXXXXX")"
	export TEST_HOME
}

teardown_file() {
	if [[ "$TEST_HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-summary."* ]]; then
		rm -rf "$TEST_HOME"
	fi
}

@test "optimize dry-run summary reports outcomes instead of catalog size" {
	# Give both Spotlight commands used by the dry run stable replies.
	mole_test_fake_command mdfind
	# shellcheck disable=SC2016 # The generated stub reads its own arguments.
	mole_test_fake_command mdutil '[[ "$#" -eq 2 && "$1" == -s && "$2" == / ]] || exit 97
printf "/:\n\tIndexing disabled.\n"'
	# defaults uses cfprefsd's user domain even with a fixture HOME. Model
	# missing preferences so this summary never depends on the host settings.
	# shellcheck disable=SC2016 # The generated stub reads its own arguments.
	mole_test_fake_command defaults '[[ "${1:-}" == read ]] && exit 1
printf "UNEXPECTED defaults %s\n" "$*" >&2
exit 97'
	run env HOME="$TEST_HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 NO_COLOR=1 "$PROJECT_ROOT/mole" optimize --dry-run

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" =~ Would\ apply\ [0-9]+\ optimizations ]] || { echo "$output"; return 1; }
	local applied_count="${BASH_REMATCH[0]#Would apply }"
	applied_count="${applied_count% optimizations}"
	[[ "$output" != *"Would apply 23 optimizations"* ]] || return 1
	[[ "$output" =~ [0-9]+\ unchanged ]] || return 1
	[[ "$output" =~ [0-9]+\ skipped ]] || return 1
	[[ "$output" != *"System fully optimized"* ]] || return 1

	run env HOME="$TEST_HOME" "$PROJECT_ROOT/mole" history --json
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"\"items\": $applied_count"* ]] || return 1
	[[ "$output" == *"\"failed_tasks\": 0"* ]] || return 1
}

@test "optimize failure reaches terminal exit and history contracts" {
	local config_dir="$TEST_HOME/.config/mole"
	local stub_dir="$TEST_HOME/bin"
	mkdir -p "$config_dir" "$stub_dir"

	run env PROJECT_ROOT="$PROJECT_ROOT" CONFIG_FILE="$config_dir/whitelist_optimize" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"
for action in "${MOLE_OPTIMIZE_ACTIONS[@]}"; do
    [[ "$action" == "cache_refresh" ]] || printf '%s\n' "$action"
done > "$CONFIG_FILE"
EOF
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

	cat > "$stub_dir/qlmanage" <<'EOF'
#!/bin/bash
exit 9
EOF
	chmod +x "$stub_dir/qlmanage"

	run env HOME="$TEST_HOME" MOLE_TEST_NO_AUTH=1 NO_COLOR=1 PATH="$stub_dir:$PATH" \
		"$PROJECT_ROOT/mole" optimize
	[[ "$status" -eq 1 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"1 failed"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to rebuild 2 Finder cache service(s)"* ]] || return 1

	run env HOME="$TEST_HOME" "$PROJECT_ROOT/mole" history --json
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	printf '%s\n' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
session = data["sessions"][0]
assert session["command"] == "optimize"
assert session["items"] == 0
assert session["failed_tasks"] == 1
'
}

@test "optimize cleanup records startup and interrupt failures in history" {
	run env HOME="$TEST_HOME/cleanup-history" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"
eval "$(sed -n '/^cleanup_all() {/,/^}/p' "$PROJECT_ROOT/bin/optimize.sh")"

stop_inline_spinner() { :; }
stop_sudo_session() { :; }
cleanup_temp_files() { :; }
log_operation_session_end() { :; }
log_operation() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }

optimize_outcomes_reset
cleanup_all 1
cleanup_all 130
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"optimize|TASK_FAILED|session|exit status 1"* ]] || return 1
	[[ "$output" == *"optimize|TASK_FAILED|interrupted|exit status 130"* ]]
}

@test "optimize cleanup records each applied task, and none for a preview" {
	run env HOME="$TEST_HOME/cleanup-applied" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"
eval "$(sed -n '/^cleanup_all() {/,/^}/p' "$PROJECT_ROOT/bin/optimize.sh")"

stop_inline_spinner() { :; }
stop_sudo_session() { :; }
cleanup_temp_files() { :; }
log_operation_session_end() { :; }
log_operation() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }

record() {
	optimize_task_start
	optimize_task_result "$2"
	optimize_task_finish "$1"
}
optimize_outcomes_reset
record quarantine_cleanup applied
record dns_flush unchanged
record spotlight_rules applied
record disk_verify failed
cleanup_all 0
echo "---"
MOLE_DRY_RUN=1 cleanup_all 0
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	local real="${output%%---*}" preview="${output#*---}"
	[[ "$real" == *"optimize|REBUILT|quarantine_cleanup|task outcome"* ]] || return 1
	[[ "$real" == *"optimize|REBUILT|spotlight_rules|task outcome"* ]] || return 1
	[[ "$real" == *"optimize|TASK_FAILED|disk_verify|task outcome"* ]] || return 1
	[[ "$real" != *"dns_flush"* ]] || return 1
	[[ "$preview" != *"REBUILT"* ]] || return 1
}

@test "optimize EXIT trap forwards the terminal status to cleanup" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
grep -qF "trap 'cleanup_all \"\$?\"' EXIT" "$PROJECT_ROOT/bin/optimize.sh"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
