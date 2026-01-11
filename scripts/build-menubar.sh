#!/bin/bash
# Build script for Mole Menu Bar app
# This script builds both the Go shared library and the Swift macOS app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
MENUBAR_DIR="$PROJECT_ROOT/menubar-app"
BUILD_DIR="$MENUBAR_DIR/build"
DYLIB_NAME="libmolemetrics.dylib"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Mole Menu Bar Build Script ===${NC}\n"

# Step 1: Build Go shared library
echo -e "${YELLOW}Step 1: Building Go shared library...${NC}"
cd "$PROJECT_ROOT"

if ! command -v go &> /dev/null; then
    echo -e "${RED}Error: Go is not installed or not in PATH${NC}"
    exit 1
fi

make menubar-lib

if [ ! -f "$BIN_DIR/$DYLIB_NAME" ]; then
    echo -e "${RED}Error: Failed to build Go shared library${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Go shared library built successfully${NC}\n"

# Step 2: Check if Xcode project exists
echo -e "${YELLOW}Step 2: Checking for Xcode project...${NC}"

XCODE_PROJECT="$MENUBAR_DIR/MoleMenuBar.xcodeproj"

if [ ! -d "$XCODE_PROJECT" ]; then
    echo -e "${YELLOW}Warning: Xcode project not found at $XCODE_PROJECT${NC}"
    echo -e "${YELLOW}You need to create the Xcode project manually.${NC}"
    echo -e "${YELLOW}See menubar-app/README.md for instructions.${NC}\n"
    echo -e "${GREEN}The Go library is ready at: $BIN_DIR/$DYLIB_NAME${NC}"
    exit 0
fi

echo -e "${GREEN}✓ Xcode project found${NC}\n"

# Step 3: Build Swift app with xcodebuild
echo -e "${YELLOW}Step 3: Building Swift app with xcodebuild...${NC}"

if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}Error: xcodebuild is not installed (requires Xcode)${NC}"
    exit 1
fi

cd "$MENUBAR_DIR"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build the app
xcodebuild \
    -project "$XCODE_PROJECT" \
    -scheme MoleMenuBar \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE="Manual" \
    DEVELOPMENT_TEAM="" \
    clean build

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: xcodebuild failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Swift app built successfully${NC}\n"

# Step 4: Copy dylib into app bundle
echo -e "${YELLOW}Step 4: Copying dylib into app bundle...${NC}"

APP_BUNDLE="$BUILD_DIR/MoleMenuBar.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}Error: App bundle not found at $APP_BUNDLE${NC}"
    exit 1
fi

FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

cp "$BIN_DIR/$DYLIB_NAME" "$FRAMEWORKS_DIR/"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to copy dylib into app bundle${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Dylib copied to app bundle${NC}\n"

# Step 5: Code sign (ad-hoc for local use)
echo -e "${YELLOW}Step 5: Code signing app bundle...${NC}"

codesign --force --deep --sign - "$APP_BUNDLE"

if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Warning: Code signing failed (non-fatal)${NC}"
else
    echo -e "${GREEN}✓ App bundle signed (ad-hoc)${NC}\n"
fi

# Done
echo -e "${GREEN}=== Build Complete ===${NC}"
echo -e "${GREEN}App bundle: $APP_BUNDLE${NC}"
echo -e ""
echo -e "To run:"
echo -e "  open $APP_BUNDLE"
echo -e ""
echo -e "To install:"
echo -e "  cp -r $APP_BUNDLE /Applications/"
echo -e ""
