#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-suggest-home.XXXXXX")"
	export HOME

	mkdir -p "$HOME"
}

teardown_file() {
	if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		rm -rf "$HOME"
	fi
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

# Pinned to /bin/bash, which is 3.2 on macOS: mole_suggest_command builds its
# distance matrix out of two indexed arrays precisely because 3.2 has no
# associative arrays, so a newer bash from PATH would not test that.
suggest() {
	/bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/commands.sh'; mole_suggest_command '$1'"
}

@test "mole_suggest_command corrects single-character typos" {
	[[ "$(suggest clena)" == "clean" ]]
	[[ "$(suggest analzye)" == "analyze" ]]
	[[ "$(suggest optimze)" == "optimize" ]]
	[[ "$(suggest statuss)" == "status" ]]
	[[ "$(suggest histroy)" == "history" ]]
}

@test "mole_suggest_command corrects two-character typos" {
	[[ "$(suggest unistall)" == "uninstall" ]]
	[[ "$(suggest instaler)" == "installer" ]]
}

@test "mole_suggest_command resolves an unambiguous prefix" {
	[[ "$(suggest unins)" == "uninstall" ]]
	[[ "$(suggest compl)" == "completion" ]]
}

@test "mole_suggest_command folds case" {
	[[ "$(suggest CLEAN)" == "clean" ]]
	[[ "$(suggest Clena)" == "clean" ]]
}

@test "mole_suggest_command stays silent when nothing is close" {
	[[ -z "$(suggest xyzzy)" ]]
	[[ -z "$(suggest deploy)" ]]
	[[ -z "$(suggest '')" ]]
}

# A short input is close to several commands at once, and a wrong guess is worse
# than none on a tool that deletes files.
@test "mole_suggest_command does not guess from a two-character input" {
	[[ -z "$(suggest rm)" ]]
	[[ -z "$(suggest up)" ]]
}

@test "mole_suggest_command only ever returns a real command" {
	local suggestion
	suggestion="$(suggest clena)"
	run /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/commands.sh'; printf '%s\n' \"\${MOLE_COMMANDS[@]}\""
	[[ "$output" == *"$suggestion:"* ]]
}

@test "mole unknown command suggests the closest match" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" clena
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: clena"* ]]
	[[ "$output" == *"Did you mean 'mo clean'?"* ]]
}

@test "mole unknown command with no close match omits the suggestion" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" xyzzy
	[ "$status" -ne 0 ]
	[[ "$output" == *"Unknown command: xyzzy"* ]]
	[[ "$output" != *"Did you mean"* ]]
}

# Diagnostics belong on stderr so `mo $cmd > out` still shows the user what went
# wrong instead of writing it into the redirected file.
@test "mole unknown command writes the error to stderr" {
	run /bin/bash --noprofile --norc -c "env HOME='$HOME' '$PROJECT_ROOT/mole' clena 2>/dev/null"
	[ "$status" -ne 0 ]
	[[ -z "$output" ]]

	run /bin/bash --noprofile --norc -c "env HOME='$HOME' '$PROJECT_ROOT/mole' clena 2>&1 >/dev/null"
	[[ "$output" == *"Unknown command: clena"* ]]
	[[ "$output" == *"Did you mean 'mo clean'?"* ]]
}
