#!/bin/bash
# Build Universal Binary for status-go
# Supports both Apple Silicon and Intel Macs

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v go > /dev/null 2>&1; then
    echo "Error: Go not installed"
    echo "Install: brew install go"
    exit 1
fi

echo "Building status-go for multiple architectures..."

VERSION=$(git describe --tags --always --dirty 2> /dev/null || echo "dev")
BUILD_TIME=$(date -u '+%Y-%m-%d_%H:%M:%S')
LDFLAGS="-s -w -X main.Version=$VERSION -X main.BuildTime=$BUILD_TIME"

echo "  Version: $VERSION"
echo "  Build time: $BUILD_TIME"
echo ""

echo "  → Building for arm64..."
GOARCH=arm64 go build -ldflags="$LDFLAGS" -trimpath -o bin/status-go-arm64 ./cmd/status

echo "  → Building for amd64..."
GOARCH=amd64 go build -ldflags="$LDFLAGS" -trimpath -o bin/status-go-amd64 ./cmd/status

echo "  → Creating Universal Binary..."
lipo -create bin/status-go-arm64 bin/status-go-amd64 -output bin/status-go

rm bin/status-go-arm64 bin/status-go-amd64

echo ""
echo "✓ Build complete!"
echo ""
file bin/status-go
size_bytes=$(/usr/bin/stat -f%z bin/status-go 2> /dev/null || echo 0)
size_mb=$((size_bytes / 1024 / 1024))
printf "Size: %d MB (%d bytes)\n" "$size_mb" "$size_bytes"
echo ""
echo "Binary supports: arm64 (Apple Silicon) + x86_64 (Intel)"
