#!/bin/bash
# Code quality checks for Mole.
# Auto-formats code, then runs lint and syntax checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="all"

usage() {
    cat << 'EOF'
Usage: ./scripts/check.sh [--format|--no-format]

Options:
  --format     Apply formatting fixes only (shfmt, gofmt)
  --no-format  Skip formatting and run checks only
  --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)
            MODE="format"
            shift
            ;;
        --no-format)
            MODE="check"
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="●"
readonly ICON_LIST="•"

echo -e "${BLUE}=== Mole Check (${MODE}) ===${NC}\n"

SHELL_FILES=$(find . -type f \( -name "*.sh" -o -name "mole" \) \
    -not -path "./.git/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/tests/tmp-*/*" \
    -not -path "*/.*" \
    2> /dev/null)

if [[ "$MODE" == "format" ]]; then
    echo -e "${YELLOW}Formatting shell scripts...${NC}"
    if command -v shfmt > /dev/null 2>&1; then
        echo "$SHELL_FILES" | xargs shfmt -i 4 -ci -sr -w
        echo -e "${GREEN}${ICON_SUCCESS} Shell formatting complete${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} shfmt not installed${NC}"
        exit 1
    fi

    if command -v go > /dev/null 2>&1; then
        echo -e "${YELLOW}Formatting Go code...${NC}"
        gofmt -w ./cmd
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting complete${NC}\n"
    else
        echo -e "${YELLOW}${ICON_WARNING} go not installed, skipping gofmt${NC}\n"
    fi

    echo -e "${GREEN}=== Format Completed ===${NC}"
    exit 0
fi

if [[ "$MODE" != "check" ]]; then
    echo -e "${YELLOW}1. Formatting shell scripts...${NC}"
    if command -v shfmt > /dev/null 2>&1; then
        echo "$SHELL_FILES" | xargs shfmt -i 4 -ci -sr -w
        echo -e "${GREEN}${ICON_SUCCESS} Shell formatting applied${NC}\n"
    else
        echo -e "${YELLOW}${ICON_WARNING} shfmt not installed, skipping${NC}\n"
    fi

    if command -v go > /dev/null 2>&1; then
        echo -e "${YELLOW}2. Formatting Go code...${NC}"
        gofmt -w ./cmd
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting applied${NC}\n"
    fi
fi

echo -e "${YELLOW}3. Running Go linters...${NC}"
if command -v golangci-lint > /dev/null 2>&1; then
    if golangci-lint run ./cmd/...; then
        echo -e "${GREEN}${ICON_SUCCESS} golangci-lint passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} golangci-lint failed${NC}\n"
        exit 1
    fi
elif command -v go > /dev/null 2>&1; then
    echo -e "${YELLOW}${ICON_WARNING} golangci-lint not installed, falling back to go vet${NC}"
    if go vet ./cmd/...; then
        echo -e "${GREEN}${ICON_SUCCESS} go vet passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} go vet failed${NC}\n"
        exit 1
    fi
else
    echo -e "${YELLOW}${ICON_WARNING} Go not installed, skipping Go checks${NC}\n"
fi

echo -e "${YELLOW}4. Running ShellCheck...${NC}"
if command -v shellcheck > /dev/null 2>&1; then
    if shellcheck mole bin/*.sh lib/*/*.sh scripts/*.sh; then
        echo -e "${GREEN}${ICON_SUCCESS} ShellCheck passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} ShellCheck failed${NC}\n"
        exit 1
    fi
else
    echo -e "${YELLOW}${ICON_WARNING} shellcheck not installed, skipping${NC}\n"
fi

echo -e "${YELLOW}5. Running syntax check...${NC}"
if ! bash -n mole; then
    echo -e "${RED}${ICON_ERROR} Syntax check failed (mole)${NC}\n"
    exit 1
fi
for script in bin/*.sh; do
    if ! bash -n "$script"; then
        echo -e "${RED}${ICON_ERROR} Syntax check failed ($script)${NC}\n"
        exit 1
    fi
done
find lib -name "*.sh" | while read -r script; do
    if ! bash -n "$script"; then
        echo -e "${RED}${ICON_ERROR} Syntax check failed ($script)${NC}\n"
        exit 1
    fi
done
echo -e "${GREEN}${ICON_SUCCESS} Syntax check passed${NC}\n"

echo -e "${YELLOW}6. Checking optimizations...${NC}"
OPTIMIZATION_SCORE=0
TOTAL_CHECKS=0

((TOTAL_CHECKS++))
if grep -q "read -r -s -n 1 -t 1" lib/core/ui.sh; then
    echo -e "${GREEN}  ${ICON_SUCCESS} Keyboard timeout configured${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ${ICON_WARNING} Keyboard timeout may be misconfigured${NC}"
fi

((TOTAL_CHECKS++))
DRAIN_PASSES=$(grep -c "while IFS= read -r -s -n 1" lib/core/ui.sh 2> /dev/null || true)
DRAIN_PASSES=${DRAIN_PASSES:-0}
if [[ $DRAIN_PASSES -eq 1 ]]; then
    echo -e "${GREEN}  ${ICON_SUCCESS} drain_pending_input optimized${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ${ICON_WARNING} drain_pending_input has multiple passes${NC}"
fi

((TOTAL_CHECKS++))
if grep -q "rotate_log_once" lib/core/log.sh; then
    echo -e "${GREEN}  ${ICON_SUCCESS} Log rotation optimized${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ${ICON_WARNING} Log rotation not optimized${NC}"
fi

((TOTAL_CHECKS++))
if ! grep -q "cache_meta\|cache_dir_mtime" bin/uninstall.sh; then
    echo -e "${GREEN}  ${ICON_SUCCESS} Cache validation simplified${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ${ICON_WARNING} Cache still uses redundant metadata${NC}"
fi

((TOTAL_CHECKS++))
if grep -q "Consecutive slashes" bin/clean.sh; then
    echo -e "${GREEN}  ${ICON_SUCCESS} Path validation enhanced${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ${ICON_WARNING} Path validation not enhanced${NC}"
fi

echo -e "${BLUE}  Optimization score: $OPTIMIZATION_SCORE/$TOTAL_CHECKS${NC}\n"

echo -e "${GREEN}=== Checks Completed ===${NC}"
if [[ $OPTIMIZATION_SCORE -eq $TOTAL_CHECKS ]]; then
    echo -e "${GREEN}${ICON_SUCCESS} All optimizations applied${NC}"
else
    echo -e "${YELLOW}${ICON_WARNING} Some optimizations missing${NC}"
fi
