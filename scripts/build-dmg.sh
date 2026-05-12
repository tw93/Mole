#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/.build/Roomy.app}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Roomy}"
DMGMAKER_REPO="${DMGMAKER_REPO:-https://github.com/saihgupr/DMGMaker.git}"
DMGMAKER_REF="${DMGMAKER_REF:-v1.0.3}"
DMGMAKER_DIR="${DMGMAKER_DIR:-$ROOT_DIR/.build/DMGMaker}"
BUILD_APP="${BUILD_APP:-1}"
SKIP_SIGN="${SKIP_SIGN:-1}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    local tool="$1"
    command -v "$tool" > /dev/null 2>&1 || fail "$tool is required to build the DMG"
}

prepare_dmgmaker() {
    if [[ -f "$DMGMAKER_DIR/Package.swift" ]]; then
        return 0
    fi

    require_tool git
    mkdir -p "$(dirname "$DMGMAKER_DIR")"
    git clone --depth 1 --branch "$DMGMAKER_REF" "$DMGMAKER_REPO" "$DMGMAKER_DIR"
}

require_tool swift

if [[ "$BUILD_APP" == "1" ]]; then
    printf 'Building unsigned RoomyUI app bundle for DMG packaging...\n'
    SKIP_SIGN="$SKIP_SIGN" NOTARIZE_APP=0 APP_BUNDLE="$APP_BUNDLE" "$ROOT_DIR/scripts/build-app.sh"
fi

[[ -d "$APP_BUNDLE" ]] || fail "expected app bundle at $APP_BUNDLE"

prepare_dmgmaker
[[ -f "$DMGMAKER_DIR/Package.swift" ]] || fail "DMGMaker checkout is missing Package.swift: $DMGMAKER_DIR"

DMG_DIR="$(cd "$(dirname "$APP_BUNDLE")" && pwd)"
DMG_PATH="$DMG_DIR/$DMG_VOLUME_NAME.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"

printf 'Creating %s with DMGMaker...\n' "$DMG_PATH"
swift run --package-path "$DMGMAKER_DIR" "DMG Maker" --app "$APP_BUNDLE" --name "$DMG_VOLUME_NAME"

[[ -f "$DMG_PATH" ]] || fail "DMGMaker did not create $DMG_PATH"

if command -v hdiutil > /dev/null 2>&1; then
    hdiutil verify "$DMG_PATH"
fi

if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"
    printf 'Wrote %s\n' "$CHECKSUM_PATH"
fi

printf 'Created %s\n' "$DMG_PATH"
