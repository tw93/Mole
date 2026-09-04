#!/usr/bin/env bats
# Verify color detection: NO_COLOR per https://no-color.org, TERM=dumb, and
# stdout that is not a terminal.

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT
}

setup() {
	PROBE="$BATS_TEST_TMPDIR/probe.sh"
	cat > "$PROBE" <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
printf '[%s]' "<${GREEN}x${NC}>"
EOF
}

@test "NO_COLOR strips ANSI escapes from base color vars" {
	run env NO_COLOR=1 PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
printf '%s' "<${GREEN}><${RED}><${YELLOW}><${BLUE}><${CYAN}><${PURPLE}><${PURPLE_BOLD}><${GRAY}><${NC}>"
EOF
	[ "$status" -eq 0 ]
	[ "$output" = "<><><><><><><><><>" ]
}

@test "NO_COLOR wins over the test-mode force" {
	run env NO_COLOR=1 MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 PROJECT_ROOT="$PROJECT_ROOT" \
		/bin/bash --noprofile --norc "$PROBE"
	[ "$status" -eq 0 ]
	[ "$output" = "[<x>]" ]
}

@test "empty NO_COLOR keeps ANSI escapes per spec" {
	run env NO_COLOR="" MOLE_TEST_MODE=1 PROJECT_ROOT="$PROJECT_ROOT" \
		/bin/bash --noprofile --norc "$PROBE"
	[ "$status" -eq 0 ]
	[ "$output" = "[<"$'\033'"[0;32mx"$'\033'"[0m>]" ]
}

@test "test mode keeps ANSI escapes without a terminal" {
	run env -u NO_COLOR MOLE_TEST_MODE=1 PROJECT_ROOT="$PROJECT_ROOT" \
		/bin/bash --noprofile --norc "$PROBE"
	[ "$status" -eq 0 ]
	[ "$output" = "[<"$'\033'"[0;32mx"$'\033'"[0m>]" ]
}

@test "stdout that is not a terminal drops ANSI escapes" {
	run env -u NO_COLOR -u MOLE_TEST_MODE -u MOLE_TEST_NO_AUTH \
		TERM=xterm-256color PROJECT_ROOT="$PROJECT_ROOT" \
		/bin/bash --noprofile --norc "$PROBE"
	[ "$status" -eq 0 ]
	[ "$output" = "[<x>]" ]
}

# Extract the fixture payload from COLOR[...] so the pty's carriage returns and
# expect's own echo of the spawned command line stay out of the comparison.
_color_payload() {
	printf '%s\n' "$1" | sed -n 's/.*COLOR\[\(.*\)\].*/\1/p' | head -1
}

@test "a terminal keeps ANSI escapes" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect ]]; then
		skip "macOS expect required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/color_tty.exp" "$PROJECT_ROOT" xterm-256color
	[ "$status" -eq 0 ]
	[ "$(_color_payload "$output")" = $'\033[0;32mx\033[0m' ]
}

@test "TERM=dumb drops ANSI escapes on a terminal" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect ]]; then
		skip "macOS expect required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/color_tty.exp" "$PROJECT_ROOT" dumb
	[ "$status" -eq 0 ]
	[ "$(_color_payload "$output")" = "x" ]
}
