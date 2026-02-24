#!/bin/bash
# Test runner for Mole.
# Runs unit, Go, and integration tests.
# Exits non-zero on failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# shellcheck source=lib/core/file_ops.sh
source "$PROJECT_ROOT/lib/core/file_ops.sh"

echo "==============================="
echo "Mole Test Runner"
echo "==============================="
echo ""

FAILED=0

report_unit_result() {
    if [[ $1 -eq 0 ]]; then
        printf "${GREEN}${ICON_SUCCESS} Unit tests passed${NC}\n"
    else
        printf "${RED}${ICON_ERROR} Unit tests failed${NC}\n"
        ((FAILED++))
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
    use_color=false
    if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
        use_color=true
    fi
    if bats --help 2>&1 | grep -q -- "--formatter"; then
        formatter="${BATS_FORMATTER:-pretty}"
        if [[ "$formatter" == "tap" ]]; then
            if $use_color; then
                esc=$'\033'
                if bats --formatter tap "$@" |
                    sed -e "s/^ok /${esc}[32mok ${esc}[0m /" \
                        -e "s/^not ok /${esc}[31mnot ok ${esc}[0m /"; then
                    report_unit_result 0
                else
                    report_unit_result 1
                fi
            else
                if bats --formatter tap "$@"; then
                    report_unit_result 0
                else
                    report_unit_result 1
                fi
            fi
        else
            # Pretty format for local development
            if bats --formatter "$formatter" "$@"; then
                report_unit_result 0
            else
                report_unit_result 1
            fi
        fi
    else
        if $use_color; then
            esc=$'\033'
            if bats --tap "$@" |
                sed -e "s/^ok /${esc}[32mok ${esc}[0m /" \
                    -e "s/^not ok /${esc}[31mnot ok ${esc}[0m /"; then
                report_unit_result 0
            else
                report_unit_result 1
            fi
        else
            if bats --tap "$@"; then
                report_unit_result 0
            else
                report_unit_result 1
            fi
        fi
    fi
else
    printf "${YELLOW}${ICON_WARNING} bats not installed or no tests found, skipping${NC}\n"
fi
echo ""

echo "3. Running Go tests..."
if command -v go > /dev/null 2>&1; then
    if go build ./... > /dev/null 2>&1 && go vet ./... > /dev/null 2>&1 && go test ./... > /dev/null 2>&1; then
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
# Skip if Homebrew mole is installed (install.sh will refuse to overwrite)
if brew list mole &> /dev/null; then
    printf "${GREEN}${ICON_SUCCESS} Installation test skipped, Homebrew${NC}\n"
elif ./install.sh --prefix /tmp/mole-test > /dev/null 2>&1; then
    if [ -f /tmp/mole-test/mole ]; then
        printf "${GREEN}${ICON_SUCCESS} Installation test passed${NC}\n"
    else
        printf "${RED}${ICON_ERROR} Installation test failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${RED}${ICON_ERROR} Installation test failed${NC}\n"
    ((FAILED++))
fi
safe_remove "/tmp/mole-test" true || true
echo ""

echo "==============================="
if [[ $FAILED -eq 0 ]]; then
    printf "${GREEN}${ICON_SUCCESS} All tests passed!${NC}\n"
    exit 0
fi
printf "${RED}${ICON_ERROR} $FAILED tests failed!${NC}\n"
exit 1
