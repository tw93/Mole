#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-installers-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"

    if command -v zip > /dev/null 2>&1; then
        ZIP_AVAILABLE=1
    else
        ZIP_AVAILABLE=0
    fi
    if command -v zipinfo > /dev/null 2>&1 || command -v unzip > /dev/null 2>&1; then
        ZIP_LIST_AVAILABLE=1
    else
        ZIP_LIST_AVAILABLE=0
    fi
    if command -v unzip > /dev/null 2>&1; then
        UNZIP_AVAILABLE=1
    else
        UNZIP_AVAILABLE=0
    fi
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    export TERM="xterm-256color"
    export ROOMY_DEBUG=0

    # Create standard scan directories
    mkdir -p "$HOME/Downloads"
    mkdir -p "$HOME/Desktop"
    mkdir -p "$HOME/Documents"
    mkdir -p "$HOME/Public"
    mkdir -p "$HOME/Library/Downloads"

    # Clear previous test files
    rm -rf "${HOME:?}/Downloads"/*
    rm -rf "${HOME:?}/Desktop"/*
    rm -rf "${HOME:?}/Documents"/*
}

zip_list_available() {
    [[ "${ZIP_LIST_AVAILABLE:-0}" -eq 1 ]]
}

require_zip_list() {
    zip_list_available
}

require_zip_support() {
    [[ "${ZIP_AVAILABLE:-0}" -eq 1 && "${ZIP_LIST_AVAILABLE:-0}" -eq 1 ]]
}

require_unzip_support() {
    [[ "${ZIP_AVAILABLE:-0}" -eq 1 && "${UNZIP_AVAILABLE:-0}" -eq 1 ]]
}

# Test ZIP installer detection

@test "is_installer_zip: detects ZIP with installer content even with many entries" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a ZIP with many files (more than old MAX_ZIP_ENTRIES=5)
    # Include a .app file to have installer content
    mkdir -p "$HOME/Downloads/large-app"
    touch "$HOME/Downloads/large-app/MyApp.app"
    for i in {1..9}; do
        touch "$HOME/Downloads/large-app/file$i.txt"
    done
    (cd "$HOME/Downloads" && zip -q -r large-installer.zip large-app)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        if is_installer_zip "'"$HOME/Downloads/large-installer.zip"'"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == "INSTALLER" ]]
}

@test "is_installer_zip: detects ZIP with app content" {
    if ! require_zip_support; then
        return 0
    fi

    mkdir -p "$HOME/Downloads/app-content"
    touch "$HOME/Downloads/app-content/MyApp.app"
    (cd "$HOME/Downloads" && zip -q -r app.zip app-content)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        if is_installer_zip "'"$HOME/Downloads/app.zip"'"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == "INSTALLER" ]]
}

@test "is_installer_zip: detects ZIP with uppercase installer payload extension" {
    if ! require_zip_support; then
        return 0
    fi

    mkdir -p "$HOME/Downloads/upper-content"
    touch "$HOME/Downloads/upper-content/MyApp.APP"
    (cd "$HOME/Downloads" && zip -q -r upper.zip upper-content)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        if is_installer_zip "'"$HOME/Downloads/upper.zip"'"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == "INSTALLER" ]]
}

@test "is_installer_zip: rejects ZIP when installer pattern appears after MAX_ZIP_ENTRIES" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a ZIP where .app appears after the 50th entry
    mkdir -p "$HOME/Downloads/deep-content"
    # Create 51 regular files first
    for i in {1..51}; do
        touch "$HOME/Downloads/deep-content/file$i.txt"
    done
    # Add .app file at the end (52nd entry)
    touch "$HOME/Downloads/deep-content/MyApp.app"
    (cd "$HOME/Downloads" && zip -q -r deep.zip deep-content)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        if is_installer_zip "'"$HOME/Downloads/deep.zip"'"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_INSTALLER" ]]
}

@test "is_installer_zip: detects ZIP with real app bundle structure" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a realistic .app bundle structure (directory, not just a file)
    mkdir -p "$HOME/Downloads/RealApp.app/Contents/MacOS"
    mkdir -p "$HOME/Downloads/RealApp.app/Contents/Resources"
    echo "#!/bin/bash" > "$HOME/Downloads/RealApp.app/Contents/MacOS/RealApp"
    chmod +x "$HOME/Downloads/RealApp.app/Contents/MacOS/RealApp"
    cat > "$HOME/Downloads/RealApp.app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>RealApp</string>
</dict>
</plist>
EOF
    (cd "$HOME/Downloads" && zip -q -r realapp.zip RealApp.app)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        if is_installer_zip "'"$HOME/Downloads/realapp.zip"'"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == "INSTALLER" ]]
}

@test "is_installer_zip: rejects ZIP with only regular files" {
    if ! require_zip_support; then
        return 0
    fi

    mkdir -p "$HOME/Downloads/data"
    touch "$HOME/Downloads/data/file1.txt"
    touch "$HOME/Downloads/data/file2.pdf"
    (cd "$HOME/Downloads" && zip -q -r data.zip data)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        if is_installer_zip "'"$HOME/Downloads/data.zip"'"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_INSTALLER" ]]
}

@test "is_installer_zip: returns NOT_INSTALLER when ZIP list command is unavailable" {
    touch "$HOME/Downloads/empty.zip"

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        ZIP_LIST_CMD=()
        if is_installer_zip "$2"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads/empty.zip"

    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_INSTALLER" ]]
}

@test "is_installer_zip: works with unzip list command" {
    if ! require_unzip_support; then
        return 0
    fi

    mkdir -p "$HOME/Downloads/app-content"
    touch "$HOME/Downloads/app-content/MyApp.app"
    (cd "$HOME/Downloads" && zip -q -r app.zip app-content)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        ZIP_LIST_CMD=(unzip -Z -1)
        if is_installer_zip "$2"; then
            echo "INSTALLER"
        else
            echo "NOT_INSTALLER"
        fi
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads/app.zip"

    [ "$status" -eq 0 ]
    [[ "$output" == "INSTALLER" ]]
}

# Integration tests: ZIP scanning inside scan_all_installers

@test "scan_all_installers: finds installer ZIP in Downloads" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a valid installer ZIP (contains .app)
    mkdir -p "$HOME/Downloads/app-content"
    touch "$HOME/Downloads/app-content/MyApp.app"
    (cd "$HOME/Downloads" && zip -q -r installer.zip app-content)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        scan_all_installers
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"installer.zip"* ]]
}

@test "scan_all_installers: ignores non-installer ZIP in Downloads" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a non-installer ZIP (only regular files)
    mkdir -p "$HOME/Downloads/data"
    touch "$HOME/Downloads/data/file1.txt"
    touch "$HOME/Downloads/data/file2.pdf"
    (cd "$HOME/Downloads" && zip -q -r data.zip data)

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        scan_all_installers
    ' bash "$PROJECT_ROOT/bin/installer.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"data.zip"* ]]
}

# Failure path tests for scan_installers_in_path

@test "scan_installers_in_path: skips corrupt ZIP files" {
    if ! require_zip_list; then
        return 0
    fi

    # Create a corrupt ZIP file by just writing garbage data
    echo "This is not a valid ZIP file" > "$HOME/Downloads/corrupt.zip"

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        scan_installers_in_path "$2"
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

    # Should succeed (return 0) and silently skip the corrupt ZIP
    [ "$status" -eq 0 ]
    # Output should be empty since corrupt.zip is not a valid installer
    [[ -z "$output" ]]
}

@test "scan_installers_in_path: handles permission-denied files" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a valid installer ZIP
    mkdir -p "$HOME/Downloads/app-content"
    touch "$HOME/Downloads/app-content/MyApp.app"
    (cd "$HOME/Downloads" && zip -q -r readable.zip app-content)

    # Create a readable installer ZIP alongside a permission-denied file
    mkdir -p "$HOME/Downloads/restricted-app"
    touch "$HOME/Downloads/restricted-app/App.app"
    (cd "$HOME/Downloads" && zip -q -r restricted.zip restricted-app)

    # Remove read permissions from restricted.zip
    chmod 000 "$HOME/Downloads/restricted.zip"

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        scan_installers_in_path "$2"
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

    # Should succeed and find the readable.zip but skip restricted.zip
    [ "$status" -eq 0 ]
    [[ "$output" == *"readable.zip"* ]]
    [[ "$output" != *"restricted.zip"* ]]

    # Cleanup: restore permissions for teardown
    chmod 644 "$HOME/Downloads/restricted.zip"
}

@test "scan_installers_in_path: finds installer ZIP alongside corrupt ZIPs" {
    if ! require_zip_support; then
        return 0
    fi

    # Create a valid installer ZIP
    mkdir -p "$HOME/Downloads/app-content"
    touch "$HOME/Downloads/app-content/MyApp.app"
    (cd "$HOME/Downloads" && zip -q -r valid-installer.zip app-content)

    # Create a corrupt ZIP
    echo "garbage data" > "$HOME/Downloads/corrupt.zip"

    run bash -euo pipefail -c '
        export ROOMY_TEST_MODE=1
        source "$1"
        scan_installers_in_path "$2"
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

    # Should find the valid ZIP and silently skip the corrupt one
    [ "$status" -eq 0 ]
    [[ "$output" == *"valid-installer.zip"* ]]
    [[ "$output" != *"corrupt.zip"* ]]
}
