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

@test "completion scripts include update dry-run options" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"--dry-run -n --force -f --nightly"* ]]

	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"--dry-run"* ]]
	[[ "$output" == *"--force"* ]]
	[[ "$output" == *"--nightly"* ]]

	run "$PROJECT_ROOT/bin/completion.sh" fish
	[ "$status" -eq 0 ]
	[[ "$output" == *"__fish_seen_subcommand_from update"* ]]
	[[ "$output" == *"-l dry-run"* ]]
	[[ "$output" == *"-l force"* ]]
	[[ "$output" == *"-l nightly"* ]]
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

@test "completion fish replaces generated file symlinks without following them" {
	local test_shell=/usr/local/bin/fish
	local fish_dir="$HOME/.config/fish/completions"
	local protected_roomy="$HOME/protected-roomy.fish"
	local protected_mo="$HOME/protected-mo.fish"
	mkdir -p "$fish_dir"
	printf 'keep-roomy\n' > "$protected_roomy"
	printf 'keep-mo\n' > "$protected_mo"
	ln -s "$protected_roomy" "$fish_dir/roomy.fish"
	ln -s "$protected_mo" "$fish_dir/mo.fish"

	run env SHELL="$test_shell" PATH="$PROJECT_ROOT:$PATH" "$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Fish completions written"* ]]
	[ ! -L "$fish_dir/roomy.fish" ]
	[ ! -L "$fish_dir/mo.fish" ]
	[[ "$(cat "$protected_roomy")" == "keep-roomy" ]]
	[[ "$(cat "$protected_mo")" == "keep-mo" ]]
	grep -q "complete -f -c roomy" "$fish_dir/roomy.fish"
	grep -q "source $fish_dir/roomy.fish" "$fish_dir/mo.fish"
}

@test "completion fish replaces generated file symlinks to directories without writing through them" {
	local test_shell=/usr/local/bin/fish
	local fish_dir="$HOME/.config/fish/completions"
	local protected_dir="$HOME/protected-fish-completion-dir"
	mkdir -p "$fish_dir" "$protected_dir"
	ln -s "$protected_dir" "$fish_dir/roomy.fish"

	run env SHELL="$test_shell" PATH="$PROJECT_ROOT:$PATH" "$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Fish completions written"* ]]
	[ ! -L "$fish_dir/roomy.fish" ]
	grep -q "complete -f -c roomy" "$fish_dir/roomy.fish"
	[ -z "$(find "$protected_dir" -mindepth 1 -print -quit)" ]
}

@test "completion fish refuses symlinked completions directory" {
	local test_shell=/usr/local/bin/fish
	local fish_root="$HOME/.config/fish"
	local fish_dir="$fish_root/completions"
	local redirected="$HOME/redirected-completions"
	mkdir -p "$fish_root" "$redirected"
	ln -s "$redirected" "$fish_dir"

	run env SHELL="$test_shell" PATH="$PROJECT_ROOT:$PATH" "$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Completion target directory must not include symlinked directories"* ]]
	[ -z "$(find "$redirected" -mindepth 1 -print -quit)" ]
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
