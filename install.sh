#!/bin/bash
# Mole CLI (Linux) - installer.
#
#   curl -fsSL https://raw.githubusercontent.com/tw93/Mole/linux/install.sh | bash
#
# Installs the latest Mole CLI (Linux) release into ~/.local/share/mole and
# links mo and mole into ~/.local/bin. No sudo, nothing outside the home.
#
#   --version X.Y.Z          install that release instead of the latest
#   --archive FILE --sums FILE   install a local release archive (testing)
#   --latest                 print the latest release version and exit

set -euo pipefail

REPO="tw93/Mole"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf '%s\n' 'Run the installer without sudo; Mole installs into your home folder.' >&2
    exit 1
fi
if [[ "$(uname -s)" != Linux ]]; then
    printf '%s\n' 'This installer is for Linux. On a Mac, see https://github.com/tw93/Mole.' >&2
    exit 1
fi

if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    GREEN='' RED='' GRAY='' NC=''
else
    GREEN=$'\033[0;32m' RED=$'\033[0;31m' GRAY=$'\033[38;5;244m' NC=$'\033[0m'
fi
ok() { printf '%s✓%s %s\n' "$GREEN" "$NC" "$1"; }
fail() {
    printf '%s☻%s %s\n' "$RED" "$NC" "$1" >&2
    exit 1
}

xdg_dir() { if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
DATA_HOME="$(xdg_dir "${XDG_DATA_HOME:-}" "$HOME/.local/share")"
INSTALL_ROOT="$DATA_HOME/mole"
BIN_DIR="$HOME/.local/bin"

case "$(uname -m)" in
    x86_64 | amd64) ARCH=x86_64 ;;
    aarch64 | arm64) ARCH=aarch64 ;;
    *) fail "No Mole build for $(uname -m) yet." ;;
esac

VERSION=""
ARCHIVE=""
SUMS=""
PRINT_LATEST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --archive)
            ARCHIVE="${2:-}"
            shift 2
            ;;
        --sums)
            SUMS="${2:-}"
            shift 2
            ;;
        --latest)
            PRINT_LATEST=true
            shift
            ;;
        -h | --help)
            sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done
VERSION="${VERSION#[Vv]}"
VERSION="${VERSION%-linux}"

valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

fetch() { curl -fsSL --retry 2 --connect-timeout 10 --max-time 300 "$@"; }

# Newest published stable Mole CLI (Linux) release. Releases are listed newest
# first; macOS (V1.2.3) and Windows (V1.2.3-windows) share the repository and
# release far more often, so pages are read until an exact V1.2.3-linux tag
# that is not a prerelease shows up. Drafts are not visible here.
latest_version() {
    local body tag page
    for page in 1 2 3 4 5 6 7 8 9 10; do
        body=$(fetch -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page") || return 1
        # Each release lists tag_name, then prerelease; a prerelease never counts.
        tag=$(grep -oE '"tag_name": *"[^"]*"|"prerelease": *(true|false)' <<< "$body" |
            awk -F'"' 'function ok() { return t ~ /^V[0-9]+\.[0-9]+\.[0-9]+-linux$/ && !pre }
                /tag_name/ { if (ok()) { print t; done = 1; exit } t = $4; pre = 0; next }
                /prerelease/ && /true/ { pre = 1 }
                END { if (!done && ok()) print t }') || tag=""
        if [[ -n "$tag" ]]; then
            tag="${tag#V}"
            printf '%s' "${tag%-linux}"
            return 0
        fi
        grep -q '"tag_name"' <<< "$body" || break
    done
    return 3
}

# Exit 1 when GitHub cannot be read, 3 when no Linux release is published.
if [[ "$PRINT_LATEST" == true ]]; then
    rc=0
    latest_version || rc=$?
    [[ $rc -eq 0 ]] && echo
    exit "$rc"
fi

command -v tar > /dev/null 2>&1 || fail "tar is required."
command -v sha256sum > /dev/null 2>&1 || fail "sha256sum is required."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mole-install.XXXXXX")"
NEW="$INSTALL_ROOT.new.$$"
OLD="$INSTALL_ROOT.old.$$"
# Whatever happens, leave either the old install or the new one in place and
# no half-unpacked copy beside it.
cleanup() {
    rm -rf -- "$WORK"
    [[ -e "$NEW" ]] && rm -rf -- "$NEW"
    if [[ -e "$OLD" ]]; then
        if [[ -e "$INSTALL_ROOT" ]]; then
            rm -rf -- "$OLD"
        else
            mv -- "$OLD" "$INSTALL_ROOT"
        fi
    fi
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

if [[ -n "$ARCHIVE" ]]; then
    [[ -f "$ARCHIVE" && -f "$SUMS" ]] || fail "--archive needs an archive and --sums its SHA256SUMS.txt."
    asset="$(basename -- "$ARCHIVE")"
    cp -- "$ARCHIVE" "$WORK/$asset"
    cp -- "$SUMS" "$WORK/SHA256SUMS.txt"
    if [[ -z "$VERSION" ]]; then
        VERSION="${asset#mole-}"
        VERSION="${VERSION%%-linux-*}"
    fi
    valid_version "$VERSION" || fail "Cannot read a version from $asset."
else
    command -v curl > /dev/null 2>&1 || fail "curl is required."
    if [[ -z "$VERSION" ]]; then
        rc=0
        VERSION=$(latest_version) || rc=$?
        [[ $rc -eq 3 ]] && fail "No Mole CLI (Linux) release is published yet."
        [[ $rc -eq 0 ]] || fail "Could not read the latest release from GitHub. Try again, or pass --version."
    fi
    valid_version "$VERSION" || fail "Not a release version: $VERSION"
    asset="mole-$VERSION-linux-$ARCH.tar.gz"
    base="https://github.com/$REPO/releases/download/V$VERSION-linux"
    printf '%sDownloading Mole %s for %s...%s\n' "$GRAY" "$VERSION" "$ARCH" "$NC"
    fetch -o "$WORK/$asset" "$base/$asset" || fail "Download failed: $base/$asset"
    fetch -o "$WORK/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || fail "Download failed: $base/SHA256SUMS.txt"
fi

# The archive must be listed, by its exact name, with a matching checksum.
expected=$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }' "$WORK/SHA256SUMS.txt")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "$asset is not listed in SHA256SUMS.txt."
actual=$(sha256sum -- "$WORK/$asset" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || fail "Checksum mismatch for $asset; nothing was installed."
ok "Verified $asset"

mkdir -p "$DATA_HOME"
mkdir -p "$NEW"
tar -xzf "$WORK/$asset" -C "$NEW" --strip-components=1 --no-same-owner ||
    fail "Could not unpack $asset."

# The unpacked tree must run and report the version it claims.
reported=$(bash "$NEW/mole" --version 2> /dev/null | awk '/^Mole version/ {print $3}') || reported=""
if [[ "$reported" != "$VERSION" ]]; then
    fail "The unpacked release reports '${reported:-nothing}', expected $VERSION; nothing was installed."
fi

if [[ -e "$INSTALL_ROOT" ]]; then
    [[ -f "$INSTALL_ROOT/mole" && -f "$INSTALL_ROOT/VERSION" && ! -L "$INSTALL_ROOT" && ! -d "$INSTALL_ROOT/.git" ]] ||
        fail "$INSTALL_ROOT exists and is not an installed Mole; move it away and retry."
    mv -- "$INSTALL_ROOT" "$OLD"
fi
mv -- "$NEW" "$INSTALL_ROOT" || fail "Could not move the new version into $INSTALL_ROOT."

mkdir -p "$BIN_DIR"
for name in mo mole; do
    link="$BIN_DIR/$name"
    # Replace only a missing or broken link, or one that already points at a
    # Mole install; another tool's mo stays.
    if [[ -e "$link" || -L "$link" ]]; then
        target="$(readlink -f -- "$link" 2> /dev/null || true)"
        if [[ -e "$link" && ! ( -L "$link" && -f "$(dirname -- "$target")/VERSION" && -f "$(dirname -- "$target")/lib/core/common.sh" ) ]]; then
            printf '%s%s belongs to another program; left as is, run Mole as %s.%s\n' "$GRAY" "$link" "$INSTALL_ROOT/mole" "$NC"
            continue
        fi
    fi
    ln -sfn -- "$INSTALL_ROOT/mole" "$link"
done
ok "Installed Mole $VERSION to $INSTALL_ROOT"

# shellcheck disable=SC2016 # the export line is shown literally
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf '%sAdd %s to PATH to run mo, for example in ~/.bashrc:%s\n  export PATH="$HOME/.local/bin:$PATH"\n' "$GRAY" "$BIN_DIR" "$NC" ;;
esac
printf '\nRun %smo%s to start, %smo --help%s for every command.\n' "$GREEN" "$NC" "$GREEN" "$NC"
