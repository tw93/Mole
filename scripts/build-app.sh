#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos/RoomyUI"
APP_NAME="RoomyUI"
DISPLAY_NAME="Roomy"
CONFIGURATION="${CONFIGURATION:-release}"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/.build/$APP_NAME.app}"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CLI_PAYLOAD_DIR="$RESOURCES_DIR/RoomyCLI"
LAUNCH_SERVICES_DIR="$CONTENTS_DIR/Library/LaunchServices"
LAUNCH_DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
ICON_FILE="$RESOURCES_DIR/Roomy.icns"
HELPER_NAME="RoomyPrivilegedHelper"
HELPER_LABEL="dev.roomy.native-ui.privileged-helper"
HELPER_PLIST="$LAUNCH_DAEMONS_DIR/$HELPER_LABEL.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SKIP_SIGN="${SKIP_SIGN:-0}"
NOTARIZE_APP="${NOTARIZE_APP:-0}"
NOTARIZATION_PROFILE="${NOTARIZATION_PROFILE:-}"
NOTARIZATION_ZIP="${NOTARIZATION_ZIP:-$ROOT_DIR/.build/$APP_NAME-notarization.zip}"

sign_target() {
    local target="$1"
    [[ "$SKIP_SIGN" != "1" ]] || return 0

    if ! command -v codesign > /dev/null 2>&1; then
        echo "warning: codesign not available; leaving $target unsigned" >&2
        return 0
    fi

    local -a args=(--force --sign "$SIGN_IDENTITY")
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        args+=(--timestamp --options runtime)
    fi

    codesign "${args[@]}" "$target"
}

notarize_app_bundle() {
    [[ "$NOTARIZE_APP" == "1" ]] || return 0

    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "error: notarization requires a Developer ID signing identity" >&2
        exit 1
    fi
    command -v xcrun > /dev/null 2>&1 || {
        echo "error: xcrun is required for notarization" >&2
        exit 1
    }
    command -v ditto > /dev/null 2>&1 || {
        echo "error: ditto is required to package notarization input" >&2
        exit 1
    }

    rm -f "$NOTARIZATION_ZIP"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZATION_ZIP"

    local -a submit_args=(notarytool submit "$NOTARIZATION_ZIP" --wait)
    if [[ -n "$NOTARIZATION_PROFILE" ]]; then
        submit_args+=(--keychain-profile "$NOTARIZATION_PROFILE")
    else
        [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || {
            echo "error: set NOTARIZATION_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD" >&2
            exit 1
        }
        submit_args+=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
    fi

    xcrun "${submit_args[@]}"
    xcrun stapler staple "$APP_BUNDLE"
}

if [[ ! -x "$ROOT_DIR/roomy" ]]; then
    echo "error: expected executable Roomy CLI at $ROOT_DIR/roomy" >&2
    exit 1
fi

VERSION="$("$ROOT_DIR/roomy" --version 2> /dev/null | sed -nE 's/.*([0-9]+[.][0-9]+[.][0-9]+).*/\1/p' | head -n 1)"
VERSION="${VERSION:-1.0.0}"

if command -v go > /dev/null 2>&1; then
    echo "Building Roomy helper binaries..."
    (cd "$ROOT_DIR" && go build -o "$ROOT_DIR/bin/analyze-go" ./cmd/analyze)
    (cd "$ROOT_DIR" && go build -o "$ROOT_DIR/bin/status-go" ./cmd/status)
elif [[ ! -x "$ROOT_DIR/bin/analyze-go" || ! -x "$ROOT_DIR/bin/status-go" ]]; then
    echo "error: go is required to build missing analyze-go/status-go helpers" >&2
    exit 1
else
    echo "Using existing Roomy helper binaries."
fi

echo "Building $APP_NAME ($CONFIGURATION)..."
swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION"

BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
HELPER_EXECUTABLE="$BIN_DIR/$HELPER_NAME"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: Swift build did not produce $EXECUTABLE" >&2
    exit 1
fi
if [[ ! -x "$HELPER_EXECUTABLE" ]]; then
    echo "error: Swift build did not produce $HELPER_EXECUTABLE" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE" # SAFE: generated app bundle under repo-local .build
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CLI_PAYLOAD_DIR" "$LAUNCH_SERVICES_DIR" "$LAUNCH_DAEMONS_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"
cp "$HELPER_EXECUTABLE" "$LAUNCH_SERVICES_DIR/$HELPER_NAME"
chmod 755 "$LAUNCH_SERVICES_DIR/$HELPER_NAME"

cp "$ROOT_DIR/roomy" "$CLI_PAYLOAD_DIR/"
[[ ! -x "$ROOT_DIR/mo" ]] || cp "$ROOT_DIR/mo" "$CLI_PAYLOAD_DIR/"
cp -R "$ROOT_DIR/bin" "$CLI_PAYLOAD_DIR/bin"
cp -R "$ROOT_DIR/lib" "$CLI_PAYLOAD_DIR/lib"
mkdir -p "$CLI_PAYLOAD_DIR/scripts"
cp "$ROOT_DIR/scripts/setup-quick-launchers.sh" "$CLI_PAYLOAD_DIR/scripts/setup-quick-launchers.sh"
[[ ! -f "$ROOT_DIR/install_channel" ]] || cp "$ROOT_DIR/install_channel" "$CLI_PAYLOAD_DIR/install_channel"
chmod 755 "$CLI_PAYLOAD_DIR/roomy" "$CLI_PAYLOAD_DIR"/bin/*.sh "$CLI_PAYLOAD_DIR"/bin/*-go "$CLI_PAYLOAD_DIR/scripts/setup-quick-launchers.sh" 2> /dev/null || true
[[ ! -f "$CLI_PAYLOAD_DIR/mo" ]] || chmod 755 "$CLI_PAYLOAD_DIR/mo"

printf '%s\n' "$CLI_PAYLOAD_DIR" > "$RESOURCES_DIR/roomy-project-root"

if command -v iconutil > /dev/null 2>&1; then
    ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/roomy-icon.XXXXXX")"
    swift "$PACKAGE_DIR/Support/GenerateIcon.swift" "$ICON_WORK_DIR/Roomy.iconset"
    iconutil -c icns "$ICON_WORK_DIR/Roomy.iconset" -o "$ICON_FILE"
    rm -rf "$ICON_WORK_DIR" # SAFE: removes mktemp icon workspace
else
    echo "warning: iconutil not available; building app without a custom icon" >&2
fi

cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>dev.roomy.native-ui</string>
  <key>CFBundleIconFile</key>
  <string>Roomy</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Roomy scans Desktop only when you explicitly preview or clean files there.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Roomy scans Documents only when you explicitly preview or clean files there.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Roomy scans Downloads only when you explicitly find installers or clean files there.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>Roomy scans network volumes only when you explicitly choose one.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Roomy scans removable volumes only when you explicitly choose one.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat > "$HELPER_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_LABEL</string>
  <key>MachServices</key>
  <dict>
    <key>$HELPER_LABEL</key>
    <true/>
  </dict>
  <key>BundleProgram</key>
  <string>Contents/Library/LaunchServices/$HELPER_NAME</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>dev.roomy.native-ui</string>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

sign_target "$LAUNCH_SERVICES_DIR/$HELPER_NAME"
sign_target "$APP_BUNDLE"
notarize_app_bundle

echo "Created $APP_BUNDLE"
if [[ "$SKIP_SIGN" == "1" ]]; then
    echo "Signing skipped"
elif [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Signed with ad-hoc identity"
else
    echo "Signed with identity: $SIGN_IDENTITY"
fi
if [[ "$NOTARIZE_APP" == "1" ]]; then
    echo "Notarized and stapled $APP_BUNDLE"
fi
echo "Open it with: open \"$APP_BUNDLE\""
