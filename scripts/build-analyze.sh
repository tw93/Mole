#!/bin/bash
# Build Universal Binary for analyze-go
# Supports both Apple Silicon and Intel Macs

set -euo pipefail

cd "$(dirname "$0")/.."

# Check if Go is installed
if ! command -v go > /dev/null 2>&1; then
    echo "Error: Go not installed"
    echo "Install: brew install go"
    exit 1
fi

echo "Building analyze-go for multiple architectures..."

# Get version info
VERSION=$(git describe --tags --always --dirty 2> /dev/null || echo "dev")
BUILD_TIME=$(date -u '+%Y-%m-%d_%H:%M:%S')
LDFLAGS="-s -w -X main.Version=$VERSION -X main.BuildTime=$BUILD_TIME"

echo "  Version: $VERSION"
echo "  Build time: $BUILD_TIME"
echo ""

# Build for arm64 (Apple Silicon)
echo "  → Building for arm64..."
GOARCH=arm64 go build -ldflags="$LDFLAGS" -trimpath -o bin/analyze-go-arm64 ./cmd/analyze

# Build for amd64 (Intel)
echo "  → Building for amd64..."
GOARCH=amd64 go build -ldflags="$LDFLAGS" -trimpath -o bin/analyze-go-amd64 ./cmd/analyze

# Create Universal Binary
echo "  → Creating Universal Binary..."
lipo -create bin/analyze-go-arm64 bin/analyze-go-amd64 -output bin/analyze-go

# Clean up temporary files
rm bin/analyze-go-arm64 bin/analyze-go-amd64

# Verify
echo ""
echo "✓ Build complete!"
echo ""
file bin/analyze-go
size_bytes=$(/usr/bin/stat -f%z bin/analyze-go 2> /dev/null || echo 0)
size_mb=$((size_bytes / 1024 / 1024))
printf "Size: %d MB (%d bytes)\n" "$size_mb" "$size_bytes"
echo ""
echo "Binary supports: arm64 (Apple Silicon) + x86_64 (Intel)"
