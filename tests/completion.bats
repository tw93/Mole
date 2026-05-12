#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	ORIGINAL_PATH="${PATH:-}"
	export ORIGINAL_PATH

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-completion-home.XXXXXX")"
	export HOME

	mkdir -p "$HOME"

	PATH="$PROJECT_ROOT:$PATH"
	export PATH
}

teardown_file() {
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
	if [[ -n "${ORIGINAL_PATH:-}" ]]; then
		export PATH="$ORIGINAL_PATH"
	fi
}

setup() {
	rm -rf "$HOME/.config"
	rm -rf "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"
	mkdir -p "$HOME"
}

@test "completion script exists and is executable" {
	[ -f "$PROJECT_ROOT/bin/completion.sh" ]
	[ -x "$PROJECT_ROOT/bin/completion.sh" ]
}

@test "completion script has valid bash syntax" {
	run bash -n "$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ]
}

@test "completion --help shows usage" {
	run "$PROJECT_ROOT/bin/completion.sh" --help
	[ "$status" -ne 0 ]
	[[ "$output" == *"Usage: roomy completion"* ]]
	[[ "$output" == *"Auto-install"* ]]
}

@test "completion bash generates valid bash script" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"_roomy_completions"* ]]
	[[ "$output" == *"complete -F _roomy_completions roomy mo"* ]]
}

@test "completion bash script includes all commands" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"optimize"* ]]
	[[ "$output" == *"clean"* ]]
	[[ "$output" == *"uninstall"* ]]
	[[ "$output" == *"analyze"* ]]
	[[ "$output" == *"status"* ]]
	[[ "$output" == *"purge"* ]]
	[[ "$output" == *"touchid"* ]]
	[[ "$output" == *"completion"* ]]
}

@test "completion bash script supports roomy and mo commands" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"complete -F _roomy_completions roomy mo"* ]]
}

@test "completion bash includes current clean and analyze options only" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"--dry-run -n --external --whitelist --debug --help -h"* ]]
	[[ "$output" == *"--json --help -h"* ]]
	[[ "$output" != *"--select"* ]]
	[[ "$output" != *"--categories"* ]]
	[[ "$output" != *"--exclude-paths"* ]]
}

@test "completion bash can be loaded in bash" {
	run bash -c "eval \"\$(\"$PROJECT_ROOT/bin/completion.sh\" bash)\" && complete -p roomy"
	[ "$status" -eq 0 ]
	[[ "$output" == *"_roomy_completions"* ]]
}

@test "completion zsh generates valid zsh script" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"#compdef roomy mo"* ]]
	[[ "$output" == *"_roomy()"* ]]
}

@test "completion zsh includes command descriptions" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"optimize:Refresh caches and services"* ]]
	[[ "$output" == *"clean:Free up disk space"* ]]
}

@test "completion zsh includes current clean and analyze options only" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"--dry-run"* ]]
	[[ "$output" == *"--external"* ]]
	[[ "$output" == *"--whitelist"* ]]
	[[ "$output" == *"--json"* ]]
	[[ "$output" != *"--select"* ]]
	[[ "$output" != *"--categories"* ]]
	[[ "$output" != *"--exclude-paths"* ]]
}

@test "completion fish generates valid fish script" {
	run "$PROJECT_ROOT/bin/completion.sh" fish
	[ "$status" -eq 0 ]
	[[ "$output" == *"complete -f -c roomy"* ]]
	[[ "$output" == *"complete -f -c mo"* ]]
}

@test "completion fish includes both roomy and mo commands" {
	output="$("$PROJECT_ROOT/bin/completion.sh" fish)"
	roomy_count=$(echo "$output" | grep -c "complete -f -c roomy")
	mo_count=$(echo "$output" | grep -c "complete -f -c mo")

	[ "$roomy_count" -gt 0 ]
	[ "$mo_count" -gt 0 ]
}

@test "completion fish includes current clean and analyze options only" {
	run "$PROJECT_ROOT/bin/completion.sh" fish
	[ "$status" -eq 0 ]
	[[ "$output" == *"-l dry-run"* ]]
	[[ "$output" == *"-l external"* ]]
	[[ "$output" == *"-l whitelist"* ]]
	[[ "$output" == *"-l json"* ]]
	[[ "$output" != *"-l select"* ]]
	[[ "$output" != *"-l categories"* ]]
	[[ "$output" != *"-l exclude-paths"* ]]
}

@test "completion auto-install detects zsh" {
	# shellcheck disable=SC2030,SC2031
	export SHELL=/bin/zsh

	# Simulate auto-install (no interaction)
	run bash -c "echo 'y' | \"$PROJECT_ROOT/bin/completion.sh\""

	if [[ "$output" == *"Already configured"* ]]; then
		skip "Already configured from previous test"
	fi

	[ -f "$HOME/.zshrc" ] || skip "Auto-install didn't create .zshrc"

	run grep -E "roomy[[:space:]]+completion" "$HOME/.zshrc"
	[ "$status" -eq 0 ]
}

@test "completion auto-install detects already installed" {
	mkdir -p "$HOME"
	# shellcheck disable=SC2016
	echo 'eval "$(roomy completion zsh)"' >"$HOME/.zshrc"

	run env SHELL=/bin/zsh "$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"updated"* ]]
}

@test "completion --dry-run previews changes without writing config" {
	run env SHELL=/bin/zsh "$PROJECT_ROOT/bin/completion.sh" --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY RUN MODE"* ]]
	[ ! -f "$HOME/.zshrc" ]
}

@test "completion script handles invalid shell argument" {
	run "$PROJECT_ROOT/bin/completion.sh" invalid-shell
	[ "$status" -ne 0 ]
}

@test "completion subcommand supports bash/zsh/fish" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]

	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]

	run "$PROJECT_ROOT/bin/completion.sh" fish
	[ "$status" -eq 0 ]
}
