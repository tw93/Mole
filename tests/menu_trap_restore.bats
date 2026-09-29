#!/usr/bin/env bats

load helpers/common

# The paginated/simple selectors override EXIT/INT/TERM while they run.
# They must restore the caller's traps on exit, or an outer handler (e.g.
# bin/uninstall.sh's session-end operation-log writer) is silently dropped.

setup_file() {
    mole_test_setup_project_root
}

@test "paginated_multi_select preserves the caller's EXIT trap" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

# Neutralize terminal control so the menu runs headless.
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
clear() { :; }
printf_at() { :; }
export MOLE_MANAGED_ALT_SCREEN=1
export MOLE_READ_KEY_FORCE_CHAR=1

# Arm an outer EXIT trap exactly like bin/uninstall.sh does.
trap 'echo OUTER_EXIT_MARKER' EXIT

# A single ENTER confirms the current (empty) selection.
# Feed input via redirection, NOT a pipe: a pipe would run the menu in a
# subshell and hide its trap manipulation from this shell.
paginated_multi_select "Pick" "alpha" "beta" < <(printf '\n') > /dev/null 2>&1 || true

# The caller's EXIT trap must still be armed after the menu returns.
current_exit_trap=$(trap -p EXIT)
[[ "$current_exit_trap" == *OUTER_EXIT_MARKER* ]] || { echo "OUTER EXIT TRAP LOST: $current_exit_trap"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # The outer trap should also actually fire when the shell exits.
    [[ "$output" == *OUTER_EXIT_MARKER* ]] || return 1
}

@test "paginated_multi_select restores a caller that had no EXIT trap" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
export MOLE_MANAGED_ALT_SCREEN=1
export MOLE_READ_KEY_FORCE_CHAR=1

# Feed input via redirection, NOT a pipe: a pipe would run the menu in a
# subshell and hide its trap manipulation from this shell.
paginated_multi_select "Pick" "alpha" "beta" < <(printf '\n') > /dev/null 2>&1 || true

# No caller EXIT trap existed; the menu's own cleanup trap must be gone,
# not left dangling.
current_exit_trap=$(trap -p EXIT)
[[ -z "$current_exit_trap" ]] || { echo "STRAY EXIT TRAP: $current_exit_trap"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "paginated_multi_select does not replace the caller cleanup function" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
export MOLE_MANAGED_ALT_SCREEN=1

cleanup() { echo OUTER_CLEANUP_MARKER; }
trap cleanup EXIT
original_cleanup=$(declare -f cleanup)

paginated_multi_select "Pick" "alpha" "beta" < <(printf 'q') > /dev/null 2>&1 || true

current_cleanup=$(declare -f cleanup)
[[ "$current_cleanup" == "$original_cleanup" ]] || {
    printf 'caller cleanup function was replaced:\n%s\n' "$current_cleanup" >&2
    exit 1
}
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *OUTER_CLEANUP_MARKER* ]] || return 1
}

@test "simple paginated_multi_select keeps the caller's cleanup and interrupt handlers" {
    # lib/ui/menu_simple.sh backs `mo clean --whitelist`, where bin/clean.sh
    # has already armed `trap 'cleanup EXIT $?' EXIT` with its own cleanup().
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_simple.sh"

enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
export MOLE_MANAGED_ALT_SCREEN=1

cleanup() { echo "OUTER_CLEANUP_MARKER $1"; }
handle_interrupt() { echo OUTER_INTERRUPT_MARKER; }
trap 'cleanup EXIT' EXIT
trap handle_interrupt INT TERM
original_cleanup=$(declare -f cleanup)
original_interrupt=$(declare -f handle_interrupt)

paginated_multi_select "Pick" "alpha" "beta" < <(printf 'q') > /dev/null 2>&1 || true

current_cleanup=$(declare -f cleanup)
[[ "$current_cleanup" == "$original_cleanup" ]] || {
    printf 'caller cleanup function was replaced:\n%s\n' "$current_cleanup" >&2
    exit 1
}
current_interrupt=$(declare -f handle_interrupt)
[[ "$current_interrupt" == "$original_interrupt" ]] || {
    printf 'caller handle_interrupt function was replaced:\n%s\n' "$current_interrupt" >&2
    exit 1
}
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"OUTER_CLEANUP_MARKER EXIT"* ]] || return 1
}

@test "footer never drops the Space Select hint before secondary controls (#1382)" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail

# The footer is the only place that teaches multi-select. Dropping it on a
# narrow terminal made `mo uninstall` read as single-select (#1382), so every
# control-footer variant except the filter-mode one must keep it.
awk '
    /^[[:space:]]*#/ { next }
    /_segs=\(|_segs_simple=\(/ {
        seen++
        if ($0 !~ /\$space_select/) { bad++; print "missing space_select: " $0 }
    }
    END { exit (!seen || bad) }
' "$PROJECT_ROOT/lib/ui/menu_paginated.sh" || exit 1
echo ok
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"ok"* ]]
}
