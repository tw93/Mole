#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_home completion-home

	ORIGINAL_PATH="${PATH:-}"
	export ORIGINAL_PATH

	PATH="$PROJECT_ROOT:$PATH"
	export PATH
}

teardown_file() {
	mole_test_teardown_home
	if [[ -n "${ORIGINAL_PATH:-}" ]]; then
		export PATH="$ORIGINAL_PATH"
	fi
}

setup() {
	# Safety: refuse to operate on a real home directory.
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
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
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage: mole completion"* ]] || return 1
	[[ "$output" == *"Auto-install"* ]]
}

@test "completion bash generates valid bash script" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"_mole_completions"* ]] || return 1
	[[ "$output" == *"complete -F _mole_completions mole mo"* ]]
}

@test "completion bash script includes all commands" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"optimize"* ]] || return 1
	[[ "$output" == *"clean"* ]] || return 1
	[[ "$output" == *"uninstall"* ]] || return 1
	[[ "$output" == *"analyze"* ]] || return 1
	[[ "$output" == *"status"* ]] || return 1
	[[ "$output" == *"history"* ]] || return 1
	[[ "$output" == *"purge"* ]] || return 1
	[[ "$output" == *"touchid"* ]] || return 1
	[[ "$output" == *"completion"* ]]
}

@test "completion bash script supports mo command" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"complete -F _mole_completions mole mo"* ]]
}

@test "completion bash includes current clean, analyze, history, and purge options only" {
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[ "$status" -eq 0 ]
	[[ "$output" == *"--dry-run -n --external --whitelist --debug --help -h"* ]] || return 1
	[[ "$output" == *"--json --help -h"* ]] || return 1
	[[ "$output" == *"--json --limit --help -h"* ]] || return 1
	[[ "$output" == *"--paths --dry-run -n --yes --include-empty --debug --help -h"* ]] || return 1
	[[ "$output" != *"--select"* ]] || return 1
	[[ "$output" != *"--categories"* ]] || return 1
	[[ "$output" != *"--exclude-paths"* ]]
}

@test "completion bash can be loaded in bash" {
	run /bin/bash -c "eval \"\$(\"$PROJECT_ROOT/bin/completion.sh\" bash)\" && complete -p mole"
	[ "$status" -eq 0 ]
	[[ "$output" == *"_mole_completions"* ]]
}

@test "completion zsh generates valid zsh script" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"#compdef mole mo"* ]] || return 1
	[[ "$output" == *"_mole()"* ]]
}

@test "completion zsh includes command descriptions" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"optimize:Refresh caches and services"* ]] || return 1
	[[ "$output" == *"clean:Free up disk space"* ]] || return 1
	[[ "$output" == *"history:Review cleanup activity"* ]]
}

@test "completion zsh includes current clean, analyze, history, and purge options only" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ]
	[[ "$output" == *"--dry-run"* ]] || return 1
	[[ "$output" == *"--external"* ]] || return 1
	[[ "$output" == *"--whitelist"* ]] || return 1
	[[ "$output" == *"--json"* ]] || return 1
	[[ "$output" == *"--limit"* ]] || return 1
	[[ "$output" == *"--include-empty"* ]] || return 1
	[[ "$output" == *"--yes[Confirm unattended cleanup of eligible artifacts]"* ]] || return 1
	[[ "$output" != *"--select"* ]] || return 1
	[[ "$output" != *"--categories"* ]] || return 1
	[[ "$output" != *"--exclude-paths"* ]]
}

@test "completion fish generates valid fish script" {
	run "$PROJECT_ROOT/bin/completion.sh" fish
	[ "$status" -eq 0 ]
	[[ "$output" == *"complete -f -c mole"* ]] || return 1
	[[ "$output" == *"complete -f -c mo"* ]]
}

@test "completion fish includes both mole and mo commands" {
	output="$("$PROJECT_ROOT/bin/completion.sh" fish)"
	mole_count=$(echo "$output" | grep -c "complete -f -c mole")
	mo_count=$(echo "$output" | grep -c "complete -f -c mo")

	[ "$mole_count" -gt 0 ]
	[ "$mo_count" -gt 0 ]
}

@test "completion fish includes current clean, analyze, history, and purge options only" {
	run "$PROJECT_ROOT/bin/completion.sh" fish
	[ "$status" -eq 0 ]
	[[ "$output" == *"-l dry-run"* ]] || return 1
	[[ "$output" == *"-l external"* ]] || return 1
	[[ "$output" == *"-l whitelist"* ]] || return 1
	[[ "$output" == *"-l json"* ]] || return 1
	[[ "$output" == *"-l limit"* ]] || return 1
	[[ "$output" == *"-l include-empty"* ]] || return 1
	[[ "$output" != *"-l select"* ]] || return 1
	[[ "$output" != *"-l categories"* ]] || return 1
	[[ "$output" != *"-l exclude-paths"* ]]
}

@test "completion auto-install detects zsh" {
	# shellcheck disable=SC2030,SC2031
	export SHELL=/bin/zsh

	# Simulate auto-install (no interaction)
	run /bin/bash -c "echo 'y' | \"$PROJECT_ROOT/bin/completion.sh\""

	if [[ "$output" == *"Already configured"* ]]; then
		skip "Already configured from previous test"
	fi

	[ -f "$HOME/.zshrc" ] || skip "Auto-install didn't create .zshrc"

	run grep -E "mole[[:space:]]+completion" "$HOME/.zshrc"
	[ "$status" -eq 0 ]
}

@test "completion auto-install detects already installed" {
	mkdir -p "$HOME"
	# shellcheck disable=SC2016
	echo 'eval "$(mole completion zsh)"' >"$HOME/.zshrc"

	run env SHELL=/bin/zsh "$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"updated"* ]]
}

@test "completion --dry-run previews changes without writing config" {
	run env SHELL=/bin/zsh "$PROJECT_ROOT/bin/completion.sh" --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY RUN MODE"* ]] || return 1
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

@test "completion fish includes explicit unattended purge consent" {
    run "$PROJECT_ROOT/bin/completion.sh" fish
    [ "$status" -eq 0 ]
    [[ "$output" == *'__fish_seen_subcommand_from purge" -l yes -d "Confirm unattended cleanup of eligible artifacts"'* ]]
}

@test "completion auto-install preserves a symlinked zshrc" {
	mkdir -p "$HOME/dotfiles"
	printf '# user zsh setting\n' >"$HOME/dotfiles/zshrc"
	ln -s "$HOME/dotfiles/zshrc" "$HOME/.zshrc"

	run /bin/bash -c "echo 'y' | SHELL=/bin/zsh \"$PROJECT_ROOT/bin/completion.sh\""
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ -L "$HOME/.zshrc" ] || return 1
	[ "$(readlink "$HOME/.zshrc")" = "$HOME/dotfiles/zshrc" ] || return 1
	grep -Fq '# user zsh setting' "$HOME/dotfiles/zshrc" || return 1
	grep -Eq '(mole|mo)[[:space:]]+completion' "$HOME/dotfiles/zshrc"
}

@test "completion auto-install does not mistake another tool's completion line for Mole" {
	printf 'gizmo completion zsh\n' >"$HOME/.zshrc"

	run env SHELL=/bin/zsh "$PROJECT_ROOT/bin/completion.sh" --dry-run
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"Would normalize completion entry"* ]] || return 1
	[ "$(cat "$HOME/.zshrc")" = "gizmo completion zsh" ]
}

@test "completion normalization keeps user lines mentioning Mole completion" {
    cat > "$HOME/expected-user-lines" <<'RC'
export NOTE="mo completion zsh"
alias setup='mo completion zsh; echo keep'
if command -v mole; then source <(mole completion zsh); export KEEP=yes; fi
# Run mole completion zsh to inspect the script
RC
    cat "$HOME/expected-user-lines" > "$HOME/.zshrc"
    # shellcheck disable=SC2016 # Assert literal shell configuration, not execution.
    printf '%s\n' '# Mole shell completion' 'eval "$(mole completion zsh)"' >> "$HOME/.zshrc"
    run env SHELL=/bin/zsh "$PROJECT_ROOT/bin/completion.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    while IFS= read -r line; do
        grep -Fxq "$line" "$HOME/.zshrc" || return 1
    done < "$HOME/expected-user-lines"
    # shellcheck disable=SC2016 # Assert literal shell configuration.
    ! grep -Fxq 'eval "$(mole completion zsh)"' "$HOME/.zshrc" || return 1
    # shellcheck disable=SC2016 # Assert literal shell configuration.
    grep -Fxq 'if output="$(mole completion zsh 2>/dev/null)"; then eval "$output"; fi' "$HOME/.zshrc" || return 1
}

@test "completion confirmation cancels on closed input (#1837)" {
	run /bin/bash -c "SHELL=/bin/zsh \"$PROJECT_ROOT/bin/completion.sh\" </dev/null"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Cancelled"* ]] || return 1
	[ ! -f "$HOME/.zshrc" ]
}

@test "completion fish confirmation cancels on closed input (#1837)" {
	run /bin/bash -c "SHELL=/bin/fish \"$PROJECT_ROOT/bin/completion.sh\" </dev/null"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Cancelled"* ]] || return 1
	[ ! -f "$HOME/.config/fish/completions/mole.fish" ]
	[ ! -f "$HOME/.config/fish/completions/mo.fish" ]
}

