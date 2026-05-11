#!/usr/bin/env bash
# Install local development dependencies for Mole.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_PLAYWRIGHT=1
RUN_STRICT_CHECK=0

usage() {
    cat << 'EOF'
Usage: scripts/bootstrap-dev.sh [--skip-playwright] [--check]

Options:
  --skip-playwright  Do not install the Chromium browser used by UX tests
  --check            Run scripts/check.sh --no-format --strict after setup
  --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-playwright)
            INSTALL_PLAYWRIGHT=0
            shift
            ;;
        --check)
            RUN_STRICT_CHECK=1
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

cd "$PROJECT_ROOT"

if ! command -v brew > /dev/null 2>&1; then
    echo "error: Homebrew is required. Install it from https://brew.sh/ and rerun this script." >&2
    exit 1
fi

if ! xcode-select -p > /dev/null 2>&1; then
    echo "error: Xcode Command Line Tools are required. Run: xcode-select --install" >&2
    exit 1
fi

echo "Installing Homebrew dependencies..."
brew bundle --file "$PROJECT_ROOT/Brewfile"

echo "Installing Node dependencies..."
npm ci

if [[ $INSTALL_PLAYWRIGHT -eq 1 ]]; then
    echo "Installing Playwright Chromium..."
    npx playwright install chromium
fi

echo "Installing goimports..."
go install golang.org/x/tools/cmd/goimports@latest

if [[ $RUN_STRICT_CHECK -eq 1 ]]; then
    ./scripts/check.sh --no-format --strict
else
    echo "Bootstrap complete. Run ./scripts/check.sh --no-format --strict for the full local preflight."
fi
