#!/bin/bash
# Test runner for Mole.
# Runs unit, Go, and integration tests.
# Exits non-zero on failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# Never allow the scripted test run to trigger real sudo or Touch ID prompts.
export MOLE_TEST_NO_AUTH=1

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

if ! command -v gtimeout > /dev/null 2>&1 && ! command -v timeout > /dev/null 2>&1; then
    cat > "$TEST_SYSTEM_STUB_DIR/gtimeout" << 'EOF'
#!/usr/bin/env perl
use strict;
use warnings;

my $seconds = shift @ARGV;
exit 125 unless defined $seconds && @ARGV;
exit 125 unless $seconds =~ /^[0-9]+(?:[.][0-9]+)?$/;

my $pid = fork();
exit 125 unless defined $pid;

if ($pid == 0) {
    exec @ARGV;
    exit 126;
}

$SIG{ALRM} = sub {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid;
    waitpid $pid, 0;
    exit 124;
};
alarm int($seconds) || 1;
waitpid $pid, 0;
my $status = $?;
alarm 0;
exit($status & 127 ? 128 + ($status & 127) : (($status >> 8) & 255));
EOF
fi

chmod +x "$TEST_SYSTEM_STUB_DIR/sudo" "$TEST_SYSTEM_STUB_DIR/osascript" "$TEST_SYSTEM_STUB_DIR/launchctl"
if [[ -f "$TEST_SYSTEM_STUB_DIR/gtimeout" ]]; then
    chmod +x "$TEST_SYSTEM_STUB_DIR/gtimeout"
fi
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

    # core_performance.bats has wall-clock timing assertions that are skewed by
    # CPU contention from parallel test workers. When parallel mode is active,
    # split it out to run sequentially after the parallel batch completes.
    _perf_files=()
    if [[ ${#bats_opts[@]} -gt 0 ]]; then
        _all=("$@")
        _rest=()
        if [[ ${#_all[@]} -eq 1 && -d "${_all[0]}" ]]; then
            while IFS= read -r _f; do
                case "$_f" in
                    *core_performance.bats) _perf_files+=("$_f") ;;
                    *) _rest+=("$_f") ;;
                esac
            done < <(find "${_all[0]}" -type f -name '*.bats' | sort)
        else
            for _f in "${_all[@]}"; do
                case "$_f" in
                    *core_performance.bats) _perf_files+=("$_f") ;;
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

    # Post-run: timing-sensitive perf tests run after parallel workers have
    # finished so CPU contention does not skew wall-clock assertions.
    for _pf in ${_perf_files[@]+"${_perf_files[@]}"}; do
        if [[ "${MOLE_TEST_TIMING:-0}" == "1" ]]; then
            bats --timing "$_pf" || _unit_rc=1
        else
            bats "$_pf" || _unit_rc=1
        fi
    done
    unset _perf_files _pf

    report_unit_result "$_unit_rc"
else
    printf "${YELLOW}${ICON_WARNING} bats not installed or no tests found, skipping${NC}\n"
fi
echo ""

echo "3. Running API contract tests..."
if [[ "${MOLE_SKIP_API_TESTS:-0}" == "1" ]]; then
    printf "${YELLOW}${ICON_WARNING} API contract tests skipped by MOLE_SKIP_API_TESTS${NC}\n"
elif command -v node > /dev/null 2>&1 && [[ -f "tests/api_contract.test.mjs" ]]; then
    if node --test tests/api_contract.test.mjs; then
        printf "${GREEN}${ICON_SUCCESS} API contract tests passed${NC}\n"
    else
        printf "${RED}${ICON_ERROR} API contract tests failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${YELLOW}${ICON_WARNING} node not installed or API contract tests missing, skipping${NC}\n"
fi
echo ""

echo "4. Running Go tests..."
if command -v go > /dev/null 2>&1; then
    mkdir -p "$GO_TEST_CACHE"
    if GOCACHE="$GO_TEST_CACHE" go build ./... > /dev/null 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go vet ./cmd/... > /dev/null 2>&1 &&
        GOCACHE="$GO_TEST_CACHE" go test ./cmd/... > /dev/null 2>&1; then
        printf "${GREEN}${ICON_SUCCESS} Go tests passed${NC}\n"
    else
        printf "${RED}${ICON_ERROR} Go tests failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${YELLOW}${ICON_WARNING} Go not installed, skipping Go tests${NC}\n"
fi
echo ""

echo "5. Testing module loading..."
if bash -c 'source lib/core/common.sh && echo "OK"' > /dev/null 2>&1; then
    printf "${GREEN}${ICON_SUCCESS} Module loading passed${NC}\n"
else
    printf "${RED}${ICON_ERROR} Module loading failed${NC}\n"
    ((FAILED++))
fi
echo ""

echo "6. Running integration tests..."
# Quick syntax check for main scripts
if bash -n mole && bash -n bin/clean.sh && bash -n bin/optimize.sh; then
    printf "${GREEN}${ICON_SUCCESS} Integration tests passed${NC}\n"
else
    printf "${RED}${ICON_ERROR} Integration tests failed${NC}\n"
    ((FAILED++))
fi
echo ""

echo "7. Testing installation..."
# Installation script is macOS-specific; skip this test on non-macOS platforms
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf "${YELLOW}${ICON_WARNING} Installation test skipped (non-macOS)${NC}\n"
else
    # Skip if Homebrew mole is installed (install.sh will refuse to overwrite)
    install_test_home=""
    if command -v brew > /dev/null 2>&1 && brew list mole &> /dev/null; then
        printf "${GREEN}${ICON_SUCCESS} Installation test skipped, Homebrew${NC}\n"
    else
        install_test_home="$(mktemp -d /tmp/mole-test-home.XXXXXX 2> /dev/null || true)"
        if [[ -z "$install_test_home" ]]; then
            install_test_home="/tmp/mole-test-home"
            mkdir -p "$install_test_home"
        fi
    fi
    if [[ -z "$install_test_home" ]]; then
        :
    elif HOME="$install_test_home" \
        XDG_CONFIG_HOME="$install_test_home/.config" \
        XDG_CACHE_HOME="$install_test_home/.cache" \
        MO_NO_OPLOG=1 \
        ./install.sh --prefix /tmp/mole-test > /dev/null 2>&1; then
        if [[ -f "/tmp/mole-test/mole" ]]; then
            printf "${GREEN}${ICON_SUCCESS} Installation test passed${NC}\n"
        else
            printf "${RED}${ICON_ERROR} Installation test failed${NC}\n"
            ((FAILED++))
        fi
    else
        printf "${RED}${ICON_ERROR} Installation test failed${NC}\n"
        ((FAILED++))
    fi
    MO_NO_OPLOG=1 safe_remove "/tmp/mole-test" true || true
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
