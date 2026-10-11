#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_project_root

	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-removals.XXXXXX")"
	export TEST_HOME
}

teardown_file() {
	if [[ "$TEST_HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-removals."* ]]; then
		rm -rf "$TEST_HOME"
	fi
}

@test "cache refresh reports a failed cache removal" {
	run env HOME="$TEST_HOME/cache" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/Library/Caches/com.apple.iconservices"
should_protect_path() { return 1; }
safe_remove() { return 1; }
qlmanage() { return 0; }

execute_optimization cache_refresh
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "${OPTIMIZE_CACHE_CLEANED_KB:-missing}" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to remove 1 Finder cache target(s)"* ]] || return 1
}

@test "cache refresh reports failed rebuild commands" {
	run env HOME="$TEST_HOME/cache-command" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

qlmanage() { return 9; }

execute_optimization cache_refresh
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to rebuild 2 Finder cache service(s)"* ]] || return 1
	[[ "$output" != *"QuickLook thumbnails refreshed"* ]] || return 1
}

@test "saved state cleanup reports a failed removal" {
	run env HOME="$TEST_HOME/saved-state" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

state_path="$HOME/Library/Saved Application State/Test.savedState"
mkdir -p "$state_path"
touch -t 202001010000 "$state_path"
should_protect_path() { return 1; }
safe_remove() { return 1; }

execute_optimization saved_state_cleanup
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to remove 1 old saved state(s)"* ]] || return 1
	[[ "$output" != *"App saved states optimized"* ]] || return 1
}

@test "shared file list repair reports a failed removal" {
	run env HOME="$TEST_HOME/shared-list" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

sfl_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
mkdir -p "$sfl_dir"
touch "$sfl_dir/com.test.invalid.sfl3"
plutil() { return 1; }
safe_remove() { return 1; }

execute_optimization shared_file_list_repair
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to repair 1 corrupted shared file list(s)"* ]] || return 1
}

@test "shared file list repair inspects and removes corrupted .sfl4 files" {
	run env HOME="$TEST_HOME/shared-list-sfl4" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

sfl_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
mkdir -p "$sfl_dir"
touch "$sfl_dir/com.test.invalid.sfl4"
plutil() { return 1; }
safe_remove() {
	printf '%s\n' "$1" >> "$HOME/removed.trace"
	return 0
}

execute_optimization shared_file_list_repair
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
[[ "$(cat "$HOME/removed.trace")" == "$sfl_dir/com.test.invalid.sfl4" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Repaired 1 corrupted shared file list(s)"* ]] || return 1
}

@test "CoreDuet cleanup leaves sidecars to SQLite even when pruning fails" {
	run env HOME="$TEST_HOME/coreduet" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

knowledge_dir="$HOME/Library/Application Support/Knowledge"
mkdir -p "$knowledge_dir"
printf 'database' > "$knowledge_dir/knowledgeC.db"
printf 'committed recovery data' > "$knowledge_dir/knowledgeC.db-wal"
printf 'shared state' > "$knowledge_dir/knowledgeC.db-shm"
run_with_timeout() { echo "112640 total"; }
# Task call sites send safe_remove output to /dev/null, so a printed marker
# would never reach $output. Record the call in a file the checks below read.
safe_remove() { printf '%s\n' "$1" >> "$HOME/unexpected-removals"; return 1; }
sqlite3() { echo 'SQL_ATTEMPT'; return 1; }

execute_optimization coreduet_cleanup
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(cat "$knowledge_dir/knowledgeC.db-wal")" == "committed recovery data" ]] || exit 1
[[ "$(cat "$knowledge_dir/knowledgeC.db-shm")" == "shared state" ]] || exit 1
[[ ! -e "$HOME/unexpected-removals" ]] || { cat "$HOME/unexpected-removals"; exit 1; }
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"busy or locked"* ]] || return 1
	[[ "$output" == *"SQL_ATTEMPT"* ]]
}

@test "CoreDuet cleanup preserves sidecars when sqlite3 is unavailable" {
	run env HOME="$TEST_HOME/coreduet-unavailable" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

knowledge_dir="$HOME/Library/Application Support/Knowledge"
wal_file="$knowledge_dir/knowledgeC.db-wal"
mkdir -p "$knowledge_dir"
touch "$knowledge_dir/knowledgeC.db" "$wal_file"
run_with_timeout() { echo "112640 total"; }
awk() { echo "112640"; }
safe_remove() {
    echo "UNEXPECTED_REMOVE:$1"
    return 0
}
PATH="/nonexistent"

execute_optimization coreduet_cleanup
[[ "$(optimize_outcome_count unavailable)" == "1" ]] || exit 1
[[ -f "$wal_file" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"sqlite3 not available"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
}
