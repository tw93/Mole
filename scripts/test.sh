#!/bin/bash
# Test runner for Mole.
# Runs unit, Go, and integration tests.
# Exits non-zero on failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# Sweep orphaned per-test HOME dirs left behind by killed bats runs.
# Normal teardown removes them; this only catches the ones that escaped.
# 60-minute threshold avoids racing with a long-running test in progress.
if [[ -d "$PROJECT_ROOT/tests" ]]; then
    find "$PROJECT_ROOT/tests" -maxdepth 1 -type d -name 'tmp-*' -mmin +60 \
        -exec rm -rf {} + 2> /dev/null || true # SAFE: confined to tests/tmp-*
fi

# Never allow the scripted test run to trigger real sudo or Touch ID prompts.
export MOLE_TEST_NO_AUTH=1

# Tests assert deterministic ANSI escape output. The suite runs without a
# terminal, so lib/core/base.sh would otherwise drop color; the MOLE_TEST_NO_AUTH
# export above is what forces it back on. Strip any NO_COLOR the developer has
# set in their shell, since that still wins over the force, so the color-escape
# assertions match regardless of the host environment.
unset NO_COLOR

TEST_SYSTEM_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mole-test-stubs.XXXXXX")"
TEST_GO_HELPER_DIR=""
# shellcheck disable=SC2329  # Invoked by trap.
cleanup_test_stubs() {
    rm -rf "$TEST_SYSTEM_STUB_DIR"
    if [[ -n "$TEST_GO_HELPER_DIR" ]]; then
        rm -rf "$TEST_GO_HELPER_DIR"
    fi
}
trap cleanup_test_stubs EXIT

cat > "$TEST_SYSTEM_STUB_DIR/sudo" << 'EOF'
#!/bin/bash
case "${1:-}" in
    -k)
        exit 0
        ;;
    -n)
        exit 1
        ;;
esac

printf 'mole test blocked sudo: %s\n' "$*" >&2
exit 1
EOF

cat > "$TEST_SYSTEM_STUB_DIR/osascript" << 'EOF'
#!/bin/bash
printf 'mole test blocked osascript: %s\n' "$*" >&2
exit 1
EOF

cat > "$TEST_SYSTEM_STUB_DIR/launchctl" << 'EOF'
#!/bin/bash
printf 'mole test blocked launchctl: %s\n' "$*" >&2
exit 0
EOF

chmod +x "$TEST_SYSTEM_STUB_DIR/sudo" "$TEST_SYSTEM_STUB_DIR/osascript" "$TEST_SYSTEM_STUB_DIR/launchctl"
export PATH="$TEST_SYSTEM_STUB_DIR:$PATH"

# shellcheck source=lib/core/file_ops.sh
source "$PROJECT_ROOT/lib/core/file_ops.sh"

echo "==============================="
echo "Mole Test Runner"
echo "==============================="
echo ""

FAILED=0

enforce_timeout_dependency_in_ci() {
    if [[ "${CI:-}" != "true" && "${GITHUB_ACTIONS:-}" != "true" ]]; then
        return 0
    fi

    if command -v gtimeout > /dev/null 2>&1 || command -v timeout > /dev/null 2>&1; then
        return 0
    fi

    printf "${RED}${ICON_ERROR} Missing timeout binary (gtimeout/timeout) in CI${NC}\n"
    printf "${YELLOW}${ICON_WARNING} Install coreutils to provide gtimeout${NC}\n"
    exit 1
}

# Print the slowest test files from the JUnit report written during the run.
# Attribution is per file, which is what a parallel run hides: wall clock is
# set by the single slowest file, not by the total.
report_slowest_test_files() {
    local report="${MOLE_TEST_REPORT_DIR:-}/report.xml"
    [[ -n "${MOLE_TEST_REPORT_DIR:-}" && -f "$report" ]] || return 0

    printf "\n%s\n" "Slowest test files (seconds):"
    sed -n 's/.*<testsuite name="\([^"]*\)".*time="\([0-9.]*\)".*/\2 \1/p' "$report" |
        sort -rn | head -n 10 |
        awk '{ printf "  %8.1f  %s\n", $1, $2 }'
}

report_unit_result() {
    if [[ $1 -eq 0 ]]; then
        printf "${GREEN}${ICON_SUCCESS} Unit tests passed${NC}\n"
    else
        printf "${RED}${ICON_ERROR} Unit tests failed${NC}\n"
        ((FAILED++))
    fi
}

enforce_timeout_dependency_in_ci

GO_TEST_CACHE="${MOLE_GO_TEST_CACHE:-/tmp/mole-go-build-cache}"
export MOLE_GO_TEST_CACHE="$GO_TEST_CACHE"

test_selection_needs_go_helpers() {
    local test_file
    for test_file in "$@"; do
        case "$test_file" in
            tests | ./tests | */tests | tests/cli.bats | ./tests/cli.bats | */tests/cli.bats)
                return 0
                ;;
        esac
    done
    return 1
}

prepare_go_test_helpers() {
    command -v go > /dev/null 2>&1 || return 0

    TEST_GO_HELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mole-go-helpers.XXXXXX")"
    mkdir -p "$GO_TEST_CACHE"

    if GOCACHE="$GO_TEST_CACHE" go build -o "$TEST_GO_HELPER_DIR/analyze-go" ./cmd/analyze > /dev/null 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go build -o "$TEST_GO_HELPER_DIR/status-go" ./cmd/status > /dev/null 2>&1; then
        export MOLE_TEST_ANALYZE_BIN="$TEST_GO_HELPER_DIR/analyze-go"
        export MOLE_TEST_STATUS_BIN="$TEST_GO_HELPER_DIR/status-go"
    else
        rm -rf "$TEST_GO_HELPER_DIR"
        TEST_GO_HELPER_DIR=""
    fi
}

echo "1. Linting test scripts..."
if command -v shellcheck > /dev/null 2>&1; then
    TEST_FILES=()
    while IFS= read -r file; do
        TEST_FILES+=("$file")
    done < <(find tests -type f \( -name '*.bats' -o -name '*.sh' \) | sort)
    if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
        if shellcheck --rcfile "$PROJECT_ROOT/.shellcheckrc" "${TEST_FILES[@]}"; then
            printf "${GREEN}${ICON_SUCCESS} Test script lint passed${NC}\n"
        else
            printf "${RED}${ICON_ERROR} Test script lint failed${NC}\n"
            ((FAILED++))
        fi
    else
        printf "${YELLOW}${ICON_WARNING} No test scripts found, skipping${NC}\n"
    fi
else
    printf "${YELLOW}${ICON_WARNING} shellcheck not installed, skipping${NC}\n"
fi
echo ""

echo "2. Running unit tests..."
if command -v bats > /dev/null 2>&1 && [ -d "tests" ]; then
    if [[ -z "${TERM:-}" ]]; then
        export TERM="xterm-256color"
    fi
    if [[ $# -eq 0 ]]; then
        fd_available=0
        zip_available=0
        zip_list_available=0
        if command -v fd > /dev/null 2>&1; then
            fd_available=1
        fi
        if command -v zip > /dev/null 2>&1; then
            zip_available=1
        fi
        if command -v zipinfo > /dev/null 2>&1 || command -v unzip > /dev/null 2>&1; then
            zip_list_available=1
        fi

        TEST_FILES=()
        while IFS= read -r file; do
            case "$file" in
                tests/installer_fd.bats)
                    if [[ $fd_available -eq 1 ]]; then
                        TEST_FILES+=("$file")
                    fi
                    ;;
                tests/installer_zip.bats)
                    if [[ $zip_available -eq 1 && $zip_list_available -eq 1 ]]; then
                        TEST_FILES+=("$file")
                    fi
                    ;;
                *)
                    TEST_FILES+=("$file")
                    ;;
            esac
        done < <(find tests -type f -name '*.bats' | sort)

        if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
            set -- "${TEST_FILES[@]}"
        else
            set -- tests
        fi
    fi
    if test_selection_needs_go_helpers "$@"; then
        prepare_go_test_helpers
    fi
    use_color=false
    if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
        use_color=true
    fi

    bats_help="$(bats --help 2>&1 || true)"
    bats_has_jobs=false
    bats_has_formatter=false
    if grep -q -- "--jobs" <<< "$bats_help"; then
        bats_has_jobs=true
    fi
    if grep -q -- "--formatter" <<< "$bats_help"; then
        bats_has_formatter=true
    fi

    # Enable parallel execution across test files when Bats and its backend support it.
    # Cap at 6 jobs by default to balance speed vs. system load during CI.
    bats_opts=()
    if $bats_has_jobs && { command -v parallel > /dev/null 2>&1 || command -v rush > /dev/null 2>&1; }; then
        _ncpu="$(sysctl -n hw.logicalcpu 2> /dev/null || nproc 2> /dev/null || echo 4)"
        if [[ "${MOLE_TEST_JOBS:-}" =~ ^[0-9]+$ && "${MOLE_TEST_JOBS:-0}" -gt 0 ]]; then
            _jobs="$MOLE_TEST_JOBS"
        else
            _jobs="$((_ncpu > 6 ? 6 : (_ncpu < 2 ? 2 : _ncpu)))"
        fi
        # --no-parallelize-within-files ensures each test file's tests run
        # sequentially (they share a $HOME set by setup_file and are not safe
        # to run concurrently). Parallelism is only across files.
        bats_opts+=("--jobs" "$_jobs" "--no-parallelize-within-files")
        unset _ncpu _jobs
    fi
    if [[ "${MOLE_TEST_TIMING:-0}" == "1" ]]; then
        bats_opts+=("--timing")
    fi

    # Per-file timings. Parallel TAP output cannot be attributed back to a file,
    # so one slow file is invisible until it dominates the whole run. The JUnit
    # report carries one <testsuite name= time=> per file; CI sets this and the
    # slowest files are printed after the run.
    if [[ -n "${MOLE_TEST_REPORT_DIR:-}" ]] && $bats_has_formatter; then
        mkdir -p "$MOLE_TEST_REPORT_DIR"
        bats_opts+=("--report-formatter" "junit" "--output" "$MOLE_TEST_REPORT_DIR")
    fi

    # Some test files include wall-clock timing assertions that are skewed by
    # CPU contention from parallel test workers. When parallel mode is active,
    # split them out to run sequentially after the parallel batch completes.
    _sequential_files=()
    if [[ ${#bats_opts[@]} -gt 0 ]]; then
        _all=("$@")
        _rest=()
        if [[ ${#_all[@]} -eq 1 && -d "${_all[0]}" ]]; then
            while IFS= read -r _f; do
                case "$_f" in
                    *core_performance.bats | *regression.bats) _sequential_files+=("$_f") ;;
                    *) _rest+=("$_f") ;;
                esac
            done < <(find "${_all[0]}" -type f -name '*.bats' | sort)
        else
            for _f in "${_all[@]}"; do
                case "$_f" in
                    *core_performance.bats | *regression.bats) _sequential_files+=("$_f") ;;
                    *) _rest+=("$_f") ;;
                esac
            done
        fi
        if [[ ${#_rest[@]} -gt 0 ]]; then
            set -- "${_rest[@]}"
        else
            set --
        fi
        unset _all _rest _f
    fi

    # Accumulate pass/fail across all bats invocations.
    _unit_rc=0

    # Main run (parallel when bats_opts has --jobs, skipped if no files remain).
    if [[ $# -gt 0 ]]; then
        if $bats_has_formatter; then
            formatter="${BATS_FORMATTER:-pretty}"
            if [[ "$formatter" == "tap" ]]; then
                if $use_color; then
                    esc=$'\033'
                    bats ${bats_opts[@]+"${bats_opts[@]}"} --formatter tap "$@" |
                        sed -e "s/^ok /${esc}[32mok ${esc}[0m /" \
                            -e "s/^not ok /${esc}[31mnot ok ${esc}[0m /" || _unit_rc=1
                else
                    bats ${bats_opts[@]+"${bats_opts[@]}"} --formatter tap "$@" || _unit_rc=1
                fi
            else
                # Pretty format for local development
                bats ${bats_opts[@]+"${bats_opts[@]}"} --formatter "$formatter" "$@" || _unit_rc=1
            fi
        else
            if $use_color; then
                esc=$'\033'
                bats ${bats_opts[@]+"${bats_opts[@]}"} --tap "$@" |
                    sed -e "s/^ok /${esc}[32mok ${esc}[0m /" \
                        -e "s/^not ok /${esc}[31mnot ok ${esc}[0m /" || _unit_rc=1
            else
                bats ${bats_opts[@]+"${bats_opts[@]}"} --tap "$@" || _unit_rc=1
            fi
        fi
    fi

    # Post-run: timing-sensitive tests run after parallel workers have finished
    # so CPU contention does not skew wall-clock assertions.
    for _pf in ${_sequential_files[@]+"${_sequential_files[@]}"}; do
        if [[ "${MOLE_TEST_TIMING:-0}" == "1" ]]; then
            bats --timing "$_pf" || _unit_rc=1
        else
            bats "$_pf" || _unit_rc=1
        fi
    done
    unset _sequential_files _pf

    report_slowest_test_files
    report_unit_result "$_unit_rc"
else
    printf "${YELLOW}${ICON_WARNING} bats not installed or no tests found, skipping${NC}\n"
fi
echo ""

echo "3. Running Go tests..."
if command -v go > /dev/null 2>&1; then
    mkdir -p "$GO_TEST_CACHE"
    if GOCACHE="$GO_TEST_CACHE" go build ./... > /dev/null 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go vet ./... > /dev/null 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go test ./... > /dev/null 2>&1; then
        printf "${GREEN}${ICON_SUCCESS} Go tests passed${NC}\n"
    else
        printf "${RED}${ICON_ERROR} Go tests failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${YELLOW}${ICON_WARNING} Go not installed, skipping Go tests${NC}\n"
fi
echo ""

echo "4. Testing module loading..."
if bash -c 'source lib/core/common.sh && echo "OK"' > /dev/null 2>&1; then
    printf "${GREEN}${ICON_SUCCESS} Module loading passed${NC}\n"
else
    printf "${RED}${ICON_ERROR} Module loading failed${NC}\n"
    ((FAILED++))
fi
echo ""

echo "5. Running integration tests..."
# Quick syntax check for main scripts
if bash -n mole && bash -n bin/clean.sh && bash -n bin/optimize.sh; then
    printf "${GREEN}${ICON_SUCCESS} Integration tests passed${NC}\n"
else
    printf "${RED}${ICON_ERROR} Integration tests failed${NC}\n"
    ((FAILED++))
fi
echo ""

echo "6. Testing installation..."
# Installation script is macOS-specific; skip this test on non-macOS platforms
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf "${YELLOW}${ICON_WARNING} Installation test skipped (non-macOS)${NC}\n"
else
    # Skip if Homebrew mole is installed (install.sh will refuse to overwrite)
    install_test_home=""
    install_test_prefix=""
    if command -v brew > /dev/null 2>&1 && brew list mole &> /dev/null; then
        printf "${GREEN}${ICON_SUCCESS} Installation test skipped, Homebrew${NC}\n"
    else
        install_test_home="$(mktemp -d "$PROJECT_ROOT/tests/tmp-install-home.XXXXXX" 2> /dev/null || true)"
        if [[ -z "$install_test_home" ]]; then
            install_test_home="$PROJECT_ROOT/tests/tmp-install-home"
            mkdir -p "$install_test_home"
        fi
    fi
    if [[ -z "$install_test_home" ]]; then
        :
    else
        install_test_prefix="$install_test_home/mole-bin"
    fi
    if [[ -z "$install_test_home" ]]; then
        :
    elif HOME="$install_test_home" \
        XDG_CONFIG_HOME="$install_test_home/.config" \
        XDG_CACHE_HOME="$install_test_home/.cache" \
        MO_NO_OPLOG=1 \
        ./install.sh --prefix "$install_test_prefix" > /dev/null 2>&1; then
        if [[ -f "$install_test_prefix/mole" ]]; then
            printf "${GREEN}${ICON_SUCCESS} Installation test passed${NC}\n"
        else
            printf "${RED}${ICON_ERROR} Installation test failed${NC}\n"
            ((FAILED++))
        fi
    else
        printf "${RED}${ICON_ERROR} Installation test failed${NC}\n"
        ((FAILED++))
    fi
    if [[ -n "$install_test_prefix" ]]; then
        MO_NO_OPLOG=1 safe_remove "$install_test_prefix" true || true
    fi
    if [[ -n "$install_test_home" ]]; then
        MO_NO_OPLOG=1 safe_remove "$install_test_home" true || true
    fi
fi
echo ""

echo "==============================="
if [[ $FAILED -eq 0 ]]; then
    printf "${GREEN}${ICON_SUCCESS} All tests passed!${NC}\n"
    exit 0
fi
printf "${RED}${ICON_ERROR} $FAILED tests failed!${NC}\n"
exit 1
