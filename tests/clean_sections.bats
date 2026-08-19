#!/usr/bin/env bats

# Tests for `mo clean --only` / `--skip` section selection.
#
# Selection is resolved in start_section, which is the single point every
# section name passes through. The behavioural test below therefore drives
# start_section directly and asserts that a deselected section performs no
# deletion, rather than only asserting on the parser.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-sections.XXXXXX")"
    export SANDBOX
    export MOLE_TEST_MODE=1
    export MOLE_TEST_NO_AUTH=1
}

teardown() {
    rm -rf "$SANDBOX"
}

run_clean() {
    run env HOME="$SANDBOX/home" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc "$PROJECT_ROOT/bin/clean.sh" "$@"
}

source_clean() {
    cat <<EOF
set -euo pipefail
export HOME="$SANDBOX/home"
mkdir -p "\$HOME"
export MOLE_TEST_MODE=1
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
EOF
}

@test "--list-sections prints every selectable key" {
    mkdir -p "$SANDBOX/home"
    run_clean --list-sections

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"system"* ]] || return 1
    [[ "$output" == *"app-caches"* ]] || return 1
    [[ "$output" == *"project-artifacts"* || "$output" == *"projects"* ]] || return 1
    [[ "$output" == *"Developer tools"* ]] || return 1
}

@test "an unknown section key is rejected instead of ignored" {
    mkdir -p "$SANDBOX/home"
    run_clean --only definitely-not-a-section

    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"Unknown section"* ]] || return 1
}

@test "--only and --skip cannot be combined" {
    mkdir -p "$SANDBOX/home"
    run_clean --only dev --skip browsers

    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"either --only or --skip"* ]] || return 1
}

@test "section flags are rejected alongside --external" {
    mkdir -p "$SANDBOX/home" "$SANDBOX/volume"
    run_clean --external "$SANDBOX/volume" --skip dev

    [ "$status" -eq 1 ] || return 1
}

@test "clean_section_enabled honours --only" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
CLEAN_ONLY_SECTIONS=(browsers)
clean_section_enabled "Browsers" || echo "browsers:blocked"
clean_section_enabled "Developer tools" && echo "dev:allowed"
echo done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"browsers:blocked"* ]] || return 1
    [[ "$output" != *"dev:allowed"* ]] || return 1
    [[ "$output" == *"done"* ]] || return 1
}

@test "clean_section_enabled honours --skip" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
CLEAN_SKIP_SECTIONS=(dev)
clean_section_enabled "Developer tools" && echo "dev:allowed"
clean_section_enabled "Browsers" || echo "browsers:blocked"
echo done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"dev:allowed"* ]] || return 1
    [[ "$output" != *"browsers:blocked"* ]] || return 1
    [[ "$output" == *"done"* ]] || return 1
}

@test "an unknown section label fails open" {
    # A nested section is only reachable through a step whose own section was
    # already selected, so an unrecognised label must not block it.
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
CLEAN_ONLY_SECTIONS=(browsers)
clean_section_enabled "Some Future Section" || echo "blocked"
echo done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"blocked"* ]] || return 1
    [[ "$output" == *"done"* ]] || return 1
}

@test "a deselected section deletes nothing" {
    local victim="$SANDBOX/dev_cache"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
CLEAN_SKIP_SECTIONS=(dev)
start_section "Developer tools"
safe_clean "$victim" "Test cache"
end_section
EOF

    [ "$status" -eq 0 ] || return 1
    [[ -d "$victim" ]] || return 1
    [[ -f "$victim/data.txt" ]] || return 1
    # A deselected section prints no header either.
    [[ "$output" != *"Developer tools"* ]] || return 1
}

@test "a selected section still deletes" {
    local victim="$SANDBOX/dev_cache_kept"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
CLEAN_SKIP_SECTIONS=(browsers)
start_section "Developer tools"
safe_clean "$victim" "Test cache"
end_section
EOF

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$victim" ]] || return 1
}

@test "CLEAN_SECTION_ACTIVE resets after a deselected section ends" {
    # Steps that run between sections must not inherit the previous
    # section's deselection.
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
stop_section_spinner() { :; }
CLEAN_SKIP_SECTIONS=(dev)
start_section "Developer tools"
end_section
echo "active=\$CLEAN_SECTION_ACTIVE"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"active=1"* ]] || return 1
}

@test "a deselected System section never asks for admin access" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
DRY_RUN=false
adopt_sudo_session() { echo "ADOPT_CALLED"; return 0; }
CLEAN_ONLY_SECTIONS=(browsers)
start_cleanup < /dev/null
echo "SYSTEM_CLEAN=\$SYSTEM_CLEAN"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"ADOPT_CALLED"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=false"* ]] || return 1
}
