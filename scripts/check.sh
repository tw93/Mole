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
  --format     Apply formatting fixes only, shfmt, gofmt
  --no-format  Skip formatting and run checks only
  --help     Show this help
EOF
}

check_diagnostic_guidance() {
    local file
    local status=0

    for file in "$@"; do
        [[ -f "$file" ]] || continue
        if ! awk '
        function inspect_block() {
            normalized = block
            gsub(/\$[\047"]/, "", normalized)
            gsub(/[\047"]/, "", normalized)
            while (match(normalized, /\\[[:alnum:]_]/)) {
                normalized = substr(normalized, 1, RSTART - 1) \
                    substr(normalized, RSTART + 1, 1) \
                    substr(normalized, RSTART + 2)
            }
            if (normalized ~ /Mole-Diagnose[.]command/ &&
                normalized ~ /\|[[:space:]]*([^|;&[:space:]]+[[:space:]]+)*([^|;&[:space:]]*\/)?(ba|z|da|k)?sh([^[:alnum:]_]|$)/) {
                printf "%s:%d: unsafe diagnostic pipe-to-shell guidance\n", FILENAME, block_start
                found = 1
            }
            block = ""
        }
        /^[[:space:]]*$/ {
            inspect_block()
            next
        }
        {
            if (block == "") block_start = FNR
            block = block " " $0
        }
        END {
            inspect_block()
            exit found ? 1 : 0
        }
        ' "$file"; then
            status=1
        fi
    done

    return "$status"
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

# Honor https://no-color.org: any non-empty NO_COLOR disables ANSI escapes.
if [[ -n "${NO_COLOR:-}" ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="●"
readonly ICON_LIST="•"

echo -e "${BLUE}=== Mole Check, ${MODE} ===${NC}\n"

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

    if command -v goimports > /dev/null 2>&1; then
        echo -e "${YELLOW}Formatting Go code, goimports...${NC}"
        goimports -w -local github.com/tw93/mole ./cmd ./internal
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting complete${NC}\n"
    elif command -v go > /dev/null 2>&1; then
        echo -e "${YELLOW}Formatting Go code, gofmt...${NC}"
        gofmt -w ./cmd ./internal
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

    if command -v goimports > /dev/null 2>&1; then
        echo -e "${YELLOW}2. Formatting Go code, goimports...${NC}"
        goimports -w -local github.com/tw93/mole ./cmd ./internal
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting applied${NC}\n"
    elif command -v go > /dev/null 2>&1; then
        echo -e "${YELLOW}2. Formatting Go code, gofmt...${NC}"
        gofmt -w ./cmd ./internal
        echo -e "${GREEN}${ICON_SUCCESS} Go formatting applied${NC}\n"
    fi
fi

echo -e "${YELLOW}3. Running Go linters...${NC}"
if command -v golangci-lint > /dev/null 2>&1; then
    if ! golangci-lint config verify; then
        echo -e "${RED}${ICON_ERROR} golangci-lint config invalid${NC}\n"
        exit 1
    fi
    if golangci-lint run ./...; then
        echo -e "${GREEN}${ICON_SUCCESS} golangci-lint passed${NC}\n"
    else
        echo -e "${RED}${ICON_ERROR} golangci-lint failed${NC}\n"
        echo -e "${YELLOW}If the output points to deleted temporary worktrees or non-existent paths, run:${NC}"
        echo -e "${YELLOW}  golangci-lint cache clean && golangci-lint run ./...${NC}\n"
        exit 1
    fi
elif command -v go > /dev/null 2>&1; then
    echo -e "${YELLOW}${ICON_WARNING} golangci-lint not installed, falling back to go vet${NC}"
    if go vet ./...; then
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
    if shellcheck mole install.sh bin/*.sh lib/*/*.sh scripts/*.sh; then
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
    echo -e "${RED}${ICON_ERROR} Syntax check failed, mole${NC}\n"
    exit 1
fi
if ! bash -n install.sh; then
    echo -e "${RED}${ICON_ERROR} Syntax check failed, install.sh${NC}\n"
    exit 1
fi
for script in bin/*.sh; do
    if ! bash -n "$script"; then
        echo -e "${RED}${ICON_ERROR} Syntax check failed, $script${NC}\n"
        exit 1
    fi
done
for script in scripts/*.sh; do
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

# Same body, different name. Grep cannot see this class once the variables have
# been renamed, and review reads the copies as separate helpers, so it needs a
# gate rather than a habit. Run with --list to inspect every group.
#
# python3 is a hard requirement here, not an optional tool like shfmt: six Bats
# files already fail without it, so a developer who can run the suite can run
# this. Mole itself never shells out to python3, so this stays a dev-only need.
if ! command -v python3 > /dev/null 2>&1; then
    echo -e "${RED}${ICON_ERROR} python3 not installed; it is required by the test suite and this check${NC}\n"
    exit 1
fi
if ! duplication_output=$(python3 "$SCRIPT_DIR/audit_function_duplication.py" 2>&1); then
    printf '%s\n' "$duplication_output"
    echo -e "${RED}${ICON_ERROR} Duplicate shell function bodies found${NC}\n"
    exit 1
fi
printf '%s\n' "$duplication_output"
echo -e "${GREEN}${ICON_SUCCESS} Function duplication check passed${NC}\n"

if ! destructive_output=$(python3 "$SCRIPT_DIR/audit_destructive_sinks.py" 2>&1); then
    printf '%s\n' "$destructive_output"
    echo -e "${RED}${ICON_ERROR} Destructive sink annotation check failed${NC}\n"
    exit 1
fi
printf '%s\n' "$destructive_output"
echo -e "${GREEN}${ICON_SUCCESS} Destructive sink annotation check passed${NC}\n"

diagnostic_guidance_files=(AGENTS.md README.md .claude/skills/*/SKILL.md)
if ! diagnostic_guidance_output=$(check_diagnostic_guidance "${diagnostic_guidance_files[@]}"); then
    [[ -n "$diagnostic_guidance_output" ]] && printf '%s\n' "$diagnostic_guidance_output"
    echo -e "${RED}${ICON_ERROR} Diagnostic instructions must download for review before execution${NC}\n"
    exit 1
fi
echo -e "${GREEN}${ICON_SUCCESS} Diagnostic install guidance passed${NC}\n"

echo -e "${GREEN}=== Checks Completed ===${NC}"
