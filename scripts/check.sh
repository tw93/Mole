#!/bin/bash
# Code quality checks for Roomy.
# Auto-formats code, then runs lint and syntax checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="all"
STRICT=0

usage() {
    cat << 'EOF'
Usage: ./scripts/check.sh [--format|--no-format] [--strict]

Options:
  --format     Apply formatting fixes only, shfmt, gofmt
  --no-format  Skip formatting and run checks only
  --strict     Fail when optional tools are missing and run native UI/API checks
  --help       Show this help
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
        --strict)
            STRICT=1
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

if [[ -z "${GOCACHE:-}" ]]; then
    export GOCACHE="$PROJECT_ROOT/.cache/go-build"
fi
if [[ -z "${GOLANGCI_LINT_CACHE:-}" ]]; then
    export GOLANGCI_LINT_CACHE="$PROJECT_ROOT/.cache/golangci-lint"
fi
mkdir -p "$GOCACHE" "$GOLANGCI_LINT_CACHE" 2> /dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="●"
readonly ICON_LIST="•"

echo -e "${BLUE}=== Roomy Check, ${MODE} ===${NC}\n"

require_strict_tool() {
    local tool="$1"
    local install_hint="$2"

    if [[ $STRICT -eq 0 ]]; then
        return 0
    fi
    if command -v "$tool" > /dev/null 2>&1; then
        return 0
    fi

    echo -e "${RED}${ICON_ERROR} $tool not installed${NC}"
    echo -e "${YELLOW}${ICON_WARNING} $install_hint${NC}\n"
    exit 1
}

SHELL_FILES=$(find . -type f \( -name "*.sh" -o -name "roomy" \) \
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

    if command -v goimports > /dev/null 2>&1; then
        echo -e "${YELLOW}Formatting Go code, goimports...${NC}"
        goimports -w -local github.com/jake-seo-cl/roomy ./cmd
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting complete${NC}\n"
    elif command -v go > /dev/null 2>&1; then
        echo -e "${YELLOW}Formatting Go code, gofmt...${NC}"
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
        require_strict_tool "shfmt" "Install shfmt, for example: brew install shfmt"
        echo -e "${YELLOW}${ICON_WARNING} shfmt not installed, skipping${NC}\n"
    fi

    if command -v goimports > /dev/null 2>&1; then
        echo -e "${YELLOW}2. Formatting Go code, goimports...${NC}"
        goimports -w -local github.com/jake-seo-cl/roomy ./cmd
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting applied${NC}\n"
    elif command -v go > /dev/null 2>&1; then
        echo -e "${YELLOW}2. Formatting Go code, gofmt...${NC}"
        gofmt -w ./cmd
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting applied${NC}\n"
    fi
fi

echo -e "${YELLOW}3. Running Go linters...${NC}"
if command -v golangci-lint > /dev/null 2>&1; then
    if ! golangci-lint config verify; then
        echo -e "${RED}${ICON_ERROR} golangci-lint config invalid${NC}\n"
        exit 1
    fi
    if golangci-lint run ./cmd/...; then
        echo -e "${GREEN}${ICON_SUCCESS} golangci-lint passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} golangci-lint failed${NC}\n"
        exit 1
    fi
elif command -v go > /dev/null 2>&1; then
    require_strict_tool "golangci-lint" "Install golangci-lint to run strict checks"
    echo -e "${YELLOW}${ICON_WARNING} golangci-lint not installed, falling back to go vet${NC}"
    if go vet ./cmd/...; then
        echo -e "${GREEN}${ICON_SUCCESS} go vet passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} go vet failed${NC}\n"
        exit 1
    fi
else
    require_strict_tool "go" "Install Go to run strict checks"
    echo -e "${YELLOW}${ICON_WARNING} Go not installed, skipping Go checks${NC}\n"
fi

echo -e "${YELLOW}4. Running ShellCheck...${NC}"
if command -v shellcheck > /dev/null 2>&1; then
    if shellcheck roomy bin/*.sh lib/*/*.sh scripts/*.sh; then
        echo -e "${GREEN}${ICON_SUCCESS} ShellCheck passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} ShellCheck failed${NC}\n"
        exit 1
    fi
else
    require_strict_tool "shellcheck" "Install ShellCheck, for example: brew install shellcheck"
    echo -e "${YELLOW}${ICON_WARNING} shellcheck not installed, skipping${NC}\n"
fi

echo -e "${YELLOW}5. Running syntax check...${NC}"
if ! bash -n roomy; then
    echo -e "${RED}${ICON_ERROR} Syntax check failed, roomy${NC}\n"
    exit 1
fi
for script in bin/*.sh; do
    if ! bash -n "$script"; then
        echo -e "${RED}${ICON_ERROR} Syntax check failed, $script${NC}\n"
        exit 1
    fi
done
find lib -name "*.sh" | while read -r script; do
    if ! bash -n "$script"; then
        echo -e "${RED}${ICON_ERROR} Syntax check failed, $script${NC}\n"
        exit 1
    fi
done
echo -e "${GREEN}${ICON_SUCCESS} Syntax check passed${NC}\n"

echo -e "${YELLOW}6. Running license and safety hygiene checks...${NC}"
if scripts/check-license-compliance.sh; then
    echo -e "${GREEN}${ICON_SUCCESS} License compliance checks passed${NC}\n"
else
    echo -e "${RED}${ICON_ERROR} License compliance checks failed${NC}\n"
    exit 1
fi

if scripts/check-unsafe-rm.sh; then
    echo -e "${GREEN}${ICON_SUCCESS} Safety hygiene checks passed${NC}\n"
else
    echo -e "${RED}${ICON_ERROR} Safety hygiene checks failed${NC}\n"
    exit 1
fi

if [[ $STRICT -eq 1 ]]; then
    echo -e "${YELLOW}7. Running strict test and native UI/API checks...${NC}"
    require_strict_tool "bats" "Install Bats, for example: brew install bats-core"
    require_strict_tool "npm" "Install Node.js/npm to run API and UX checks"
    require_strict_tool "swift" "Install Xcode or Swift toolchain to run native tests"

    ROOMY_SKIP_API_TESTS=1 ./scripts/test.sh

    if [[ -f "package-lock.json" ]]; then
        npm ci
    else
        echo -e "${RED}${ICON_ERROR} package-lock.json missing${NC}\n"
        exit 1
    fi

    npm run test:api
    swift test --package-path macos/RoomyUI
    npm run test:ux
    npm run macos:build
    echo -e "${GREEN}${ICON_SUCCESS} Strict test and native UI/API checks passed${NC}\n"
fi

echo -e "${GREEN}=== Checks Completed ===${NC}"
