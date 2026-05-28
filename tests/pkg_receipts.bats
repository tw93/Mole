#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-pkg-receipts.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "pkg receipt cache replaces symlinks without reading them" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

fake_bin="$HOME/fake-bin"
cache_file="$HOME/.cache/roomy/pkg_receipt_apps_v1"
protected_file="$HOME/protected-pkg-cache"
mkdir -p "$fake_bin" "$(dirname "$cache_file")" "$HOME/Protected.app"

cat > "$fake_bin/pkgutil" <<'SH'
#!/bin/bash
case "${1:-}" in
    --pkgs)
        printf '%s\n' "com.example.pkg"
        ;;
    --files)
        printf '%s\n' "Library/Application Support/NoApp/readme.txt"
        ;;
esac
SH
chmod +x "$fake_bin/pkgutil"
export PATH="$fake_bin:$PATH"

printf '%s\n' "$HOME/Protected.app" > "$protected_file"
ln -sf "$protected_file" "$cache_file"

source "$PROJECT_ROOT/lib/core/common.sh"

pkg_receipt_nonstandard_app_paths > "$HOME/pkg-output.txt"

! grep -Fxq "$HOME/Protected.app" "$HOME/pkg-output.txt"
[ ! -L "$cache_file" ]
[ "$(cat "$protected_file")" = "$HOME/Protected.app" ]

protected_dir="$HOME/protected-pkg-cache-dir"
mkdir -p "$protected_dir"
ln -sf "$protected_dir" "$cache_file"

pkg_receipt_nonstandard_app_paths > "$HOME/pkg-output-dir.txt"

[ ! -L "$cache_file" ]
[ -z "$(find "$protected_dir" -mindepth 1 -print -quit)" ]
EOF

    [ "$status" -eq 0 ]
}

@test "pkg receipt standalone cache fallback replaces symlink leaf without following it" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

fake_bin="$HOME/fake-bin"
cache_file="$HOME/.cache/roomy/pkg_receipt_apps_v1"
protected_dir="$HOME/protected-pkg-cache-dir"
mkdir -p "$fake_bin" "$(dirname "$cache_file")" "$protected_dir"

cat > "$fake_bin/pkgutil" <<'SH'
#!/bin/bash
case "${1:-}" in
    --pkgs)
        printf '%s\n' "com.example.pkg"
        ;;
    --files)
        printf '%s\n' "Library/Application Support/NoApp/readme.txt"
        ;;
esac
SH
chmod +x "$fake_bin/pkgutil"
export PATH="$fake_bin:$PATH"

ln -sf "$protected_dir" "$cache_file"

source "$PROJECT_ROOT/lib/core/pkg_receipts.sh"
pkg_receipt_nonstandard_app_paths > "$HOME/pkg-output.txt"

[ ! -L "$cache_file" ]
[ -f "$cache_file" ]
[ -z "$(find "$protected_dir" -mindepth 1 -print -quit)" ]
EOF

    [ "$status" -eq 0 ]
}
