#!/bin/bash
# Mole CLI (Linux) - installer.
#
#   curl -fsSL https://raw.githubusercontent.com/tw93/Mole/linux/install.sh | bash
#
# Installs the latest Mole CLI (Linux) release into ~/.local/share/mole and
# links mo and mole into ~/.local/bin. No sudo, nothing outside the home.
#
#   --version X.Y.Z          install that release instead of the latest
#   --nightly                install the newest linux branch commit, unreleased
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
NIGHTLY=false
COMMIT=""
PRINT_COMMIT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 && -n "$2" ]] || fail "--version needs a value."
            VERSION="$2"
            shift 2
            ;;
        --archive)
            [[ $# -ge 2 && -n "$2" ]] || fail "--archive needs a value."
            ARCHIVE="$2"
            shift 2
            ;;
        --sums)
            [[ $# -ge 2 && -n "$2" ]] || fail "--sums needs a value."
            SUMS="$2"
            shift 2
            ;;
        --latest)
            PRINT_LATEST=true
            shift
            ;;
        --nightly)
            NIGHTLY=true
            shift
            ;;
        --commit)
            [[ $# -ge 2 && -n "$2" ]] || fail "--commit needs a value."
            COMMIT="$2"
            shift 2
            ;;
        --latest-commit)
            PRINT_COMMIT=true
            shift
            ;;
        -h | --help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done
if [[ "$PRINT_COMMIT" == true ]]; then
    [[ "$NIGHTLY" == false && "$PRINT_LATEST" == false && -z "$VERSION$ARCHIVE$SUMS$COMMIT" ]] ||
        fail "--latest-commit takes no other option."
elif [[ "$NIGHTLY" == true ]]; then
    [[ -z "$VERSION$ARCHIVE$SUMS" && "$PRINT_LATEST" == false ]] ||
        fail "--nightly installs a commit; it does not take --version, --archive, --sums or --latest."
elif [[ -n "$COMMIT" ]]; then
    fail "--commit goes with --nightly."
elif [[ -n "$SUMS" && -z "$ARCHIVE" ]]; then
    fail "--sums goes with --archive."
fi
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

# The newest commit of the linux branch, as a full 40-digit hash.
latest_commit() {
    local sha
    sha=$(fetch -H 'Accept: application/vnd.github.sha' \
        "https://api.github.com/repos/$REPO/commits/linux") || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s' "$sha"
}

# Exit 1 when GitHub cannot be read, 3 when no Linux release is published.
if [[ "$PRINT_LATEST" == true ]]; then
    rc=0
    latest_version || rc=$?
    [[ $rc -eq 0 ]] && echo
    exit "$rc"
fi
if [[ "$PRINT_COMMIT" == true ]]; then
    latest_commit || exit 1
    echo
    exit 0
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

GO_ARCH=amd64
[[ "$ARCH" == aarch64 ]] && GO_ARCH=arm64
GO_ROOT="$(xdg_dir "${XDG_CACHE_HOME:-}" "$HOME/.cache")/mole/go"
HELPERS="trash status analyze"

# Build the three Go helpers of source tree $1 into $2 with the go binary $3;
# $4 = own marks Mole's toolchain. Modules stay in Mole's cache folder
# (writable, so mo remove can delete them), the build cache goes with this
# run, GOTOOLCHAIN=local keeps go from fetching another toolchain and
# GOWORK=off from reading a workspace. Mole's own go also gets this run's
# config folder, so its telemetry never lands in ~/.config/go. go's output
# is kept in $WORK/go.log for the failure line.
build_helpers() {
    local src="$1" out="$2" go="$3" own="${4:-}" tool config="${XDG_CONFIG_HOME:-}"
    [[ "$own" == own ]] && config="$WORK/go-config"
    for tool in $HELPERS; do
        (cd "$src" && XDG_CONFIG_HOME="$config" GOOS=linux GOARCH="$GO_ARCH" CGO_ENABLED=0 \
            GOTOOLCHAIN=local GOWORK=off GOPROXY="$GO_PROXY" \
            GOFLAGS=-modcacherw GOPATH="$GO_ROOT/path" GOCACHE="$WORK/go-build" \
            "$go" build -trimpath -ldflags "-s -w" -o "$out/$tool-go" "./cmd/$tool") > "$WORK/go.log" 2>&1 || return 1
    done
}

# 0 when go binary $1 is at least the go line of $2/go.mod.
go_new_enough() {
    local have need
    have=$(GOTOOLCHAIN=local "$1" env GOVERSION 2> /dev/null) || return 1
    have="${have#go}"
    need=$(awk '$1 == "go" { print $2; exit }' "$2/go.mod" 2> /dev/null)
    [[ -n "$have" && -n "$need" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" == "$need" ]]
}

# The newest stable Go, unpacked once into Mole's cache folder and checked
# against the SHA256 the download site lists (go.dev, or golang.google.cn
# where go.dev is unreachable; both serve the same files). Prints the path of
# its go binary. With neither listing readable, an earlier toolchain is used.
mole_go_toolchain() {
    local site json name sum unpacked old
    for site in https://go.dev https://golang.google.cn; do
        json=$(fetch "$site/dl/?mode=json") || continue
        name=$(grep -oE "\"filename\": *\"go[0-9.]+\.linux-$GO_ARCH\.tar\.gz\"" <<< "$json" | head -1 | awk -F'"' '{print $4}')
        [[ -n "$name" ]] || continue
        sum=$(awk -v n="$name" 'index($0, "\"" n "\"") { f = 1 } f && /"sha256"/ { gsub(/[^0-9a-f]/, "", $2); print $2; exit }' FS=: <<< "$json")
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || continue
        unpacked="$GO_ROOT/${name%.tar.gz}"
        if [[ -x "$unpacked/go/bin/go" ]]; then
            printf '%s' "$unpacked/go/bin/go"
            return 0
        fi
        printf '%sDownloading %s to build the nightly helpers...%s\n' "$GRAY" "${name%.linux-*}" "$NC" >&2
        # 70 MB: no overall cap, only a stall limit.
        curl -fsSL --retry 2 --connect-timeout 10 --speed-limit 1024 --speed-time 30 \
            -o "$WORK/$name" "$site/dl/$name" || continue
        [[ "$(sha256sum -- "$WORK/$name" | awk '{print $1}')" == "$sum" ]] || {
            printf '%sChecksum mismatch for %s; not used.%s\n' "$RED" "$name" "$NC" >&2
            return 1
        }
        mkdir -p "$GO_ROOT"
        # A folder of that name without a runnable go is a broken earlier copy.
        rm -rf -- "$unpacked.tmp" "$unpacked"
        mkdir -p "$unpacked.tmp"
        if ! tar -xzf "$WORK/$name" -C "$unpacked.tmp" --no-same-owner || ! mv -- "$unpacked.tmp" "$unpacked"; then
            rm -rf -- "$unpacked.tmp"
            return 1
        fi
        rm -f -- "$WORK/$name"
        # One toolchain is kept: the one just unpacked replaces older ones.
        for old in "$GO_ROOT"/go[0-9]*.linux-*; do
            [[ -d "$old" && ! -L "$old" && "$old" != "$unpacked" ]] && rm -rf -- "$old"
        done
        printf '%s' "$unpacked/go/bin/go"
        return 0
    done
    for old in "$GO_ROOT"/go[0-9]*.linux-"$GO_ARCH"; do
        [[ -x "$old/go/bin/go" && ! -L "$old" ]] && {
            printf '%s' "$old/go/bin/go"
            return 0
        }
    done
    return 1
}

if [[ "$NIGHTLY" == true ]]; then
    command -v curl > /dev/null 2>&1 || fail "curl is required."
    if [[ -z "$COMMIT" ]]; then
        COMMIT=$(latest_commit) || fail "Could not read the newest linux branch commit from GitHub. Try again later."
    fi
    [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Not a full commit hash: $COMMIT"
    printf '%sDownloading Mole nightly %s...%s\n' "$GRAY" "${COMMIT:0:7}" "$NC"
    fetch -o "$WORK/source.tar.gz" "https://codeload.github.com/$REPO/tar.gz/$COMMIT" ||
        fail "Download failed: https://codeload.github.com/$REPO/tar.gz/$COMMIT"
    mkdir -p "$WORK/source"
    tar -xzf "$WORK/source.tar.gz" -C "$WORK/source" --strip-components=1 --no-same-owner ||
        fail "Could not unpack the nightly source."
    # A commit of another branch (main is Mole CLI (macOS)) is not a nightly.
    [[ "$(sed -n 2p "$WORK/source/install.sh" 2> /dev/null)" == "# Mole CLI (Linux) - installer." ]] ||
        fail "${COMMIT:0:7} is not a Mole CLI (Linux) commit; nothing was installed."
    core="$(tr -d '[:space:]' 2> /dev/null < "$WORK/source/VERSION" || true)"
    valid_version "$core" || fail "The nightly source has no release VERSION; nothing was installed."
    VERSION="$core-nightly.${COMMIT:0:7}"
    stage="$WORK/stage"
    mkdir -p "$stage/bin"
    # The same files scripts/build-release.sh puts in a release archive, plus
    # the commit it came from.
    for f in mole mo install.sh LICENSE README.md; do cp -- "$WORK/source/$f" "$stage/"; done
    cp -- "$WORK/source"/bin/*.sh "$stage/bin/"
    cp -R -- "$WORK/source/lib" "$stage/lib"
    printf '%s\n' "$VERSION" > "$stage/VERSION"
    printf '%s\n' "$COMMIT" > "$stage/NIGHTLY"

    go_bin="$(command -v go 2> /dev/null || true)"
    # The user's own proxy (environment or go env -w) wins. Otherwise, where
    # proxy.golang.org hangs (China), go waits minutes per module instead of
    # falling back, so it is asked once up front. go.sum pins every module
    # hash, so the goproxy.cn mirror cannot change what gets built.
    GO_PROXY="${GOPROXY:-}"
    if [[ -z "$GO_PROXY" && -n "$go_bin" ]]; then
        GO_PROXY=$(GOTOOLCHAIN=local "$go_bin" env GOPROXY 2> /dev/null || true)
        [[ "$GO_PROXY" == "https://proxy.golang.org,direct" ]] && GO_PROXY=""
    fi
    if [[ -z "$GO_PROXY" ]]; then
        if curl -fsS -o /dev/null --connect-timeout 5 --max-time 8 https://proxy.golang.org/golang.org/x/sys/@v/list 2> /dev/null; then
            GO_PROXY="https://proxy.golang.org,direct"
        else
            GO_PROXY="https://goproxy.cn,direct"
        fi
    fi
    built=false
    if [[ -n "$go_bin" ]] && build_helpers "$WORK/source" "$stage/bin" "$go_bin"; then
        built=true
    elif [[ -n "$go_bin" ]] && go_new_enough "$go_bin" "$WORK/source"; then
        # A go new enough that still failed: another toolchain fails the same way.
        :
    elif own_go=$(mole_go_toolchain) && build_helpers "$WORK/source" "$stage/bin" "$own_go" own; then
        built=true
    fi
    if [[ "$built" == true ]]; then
        ok "Built the nightly helpers"
    else
        why=$(grep -v '^[[:space:]]*$' "$WORK/go.log" 2> /dev/null | tail -1 || true)
        [[ -n "$why" ]] && printf '%sgo build: %s%s\n' "$GRAY" "$why" "$NC"
        # Without the helpers there is no Trash; take the latest release's.
        stable=$(latest_version) || fail "Could not build the Go helpers or read a release to take them from; nothing was installed."
        sasset="mole-$stable-linux-$ARCH.tar.gz"
        sbase="https://github.com/$REPO/releases/download/V$stable-linux"
        fetch -o "$WORK/$sasset" "$sbase/$sasset" || fail "Download failed: $sbase/$sasset"
        fetch -o "$WORK/SHA256SUMS.txt" "$sbase/SHA256SUMS.txt" || fail "Download failed: $sbase/SHA256SUMS.txt"
        expected=$(awk -v a="$sasset" '$2 == a || $2 == "*" a { print $1; exit }' "$WORK/SHA256SUMS.txt")
        [[ "$expected" =~ ^[0-9a-f]{64}$ && "$(sha256sum -- "$WORK/$sasset" | awk '{print $1}')" == "$expected" ]] ||
            fail "Checksum mismatch for $sasset; nothing was installed."
        mkdir -p "$WORK/stable"
        tar -xzf "$WORK/$sasset" -C "$WORK/stable" --strip-components=1 --no-same-owner || fail "Could not unpack $sasset."
        for t in $HELPERS; do
            cp -- "$WORK/stable/bin/$t-go" "$stage/bin/" 2> /dev/null || fail "$sasset has no $t-go; nothing was installed."
        done
        printf '%sCould not build the Go helpers; using those of %s, so analyze, status and Trash changes since then are not included. Once Go builds, run mo update --nightly --force.%s\n' "$GRAY" "$stable" "$NC"
    fi
    for t in $HELPERS; do
        [[ -x "$stage/bin/$t-go" ]] || fail "The nightly has no runnable $t-go; nothing was installed."
    done
    mkdir -p "$DATA_HOME"
    mv -- "$stage" "$NEW"
elif [[ -n "$ARCHIVE" ]]; then
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

if [[ "$NIGHTLY" != true ]]; then
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
fi

# The unpacked tree must run and report the version it claims.
reported=$(bash "$NEW/mole" --version 2> /dev/null | awk '/^Mole version/ {print $3}') || reported=""
if [[ "$reported" != "$VERSION" ]]; then
    fail "The unpacked release reports '${reported:-nothing}', expected $VERSION; nothing was installed."
fi

if [[ -e "$INSTALL_ROOT" ]]; then
    # A Mole tree: its launcher plus VERSION, or plus its own core library
    # when VERSION went missing (mo update repairs that install).
    [[ -f "$INSTALL_ROOT/mole" && (-f "$INSTALL_ROOT/VERSION" || -f "$INSTALL_ROOT/lib/core/common.sh") &&
        ! -L "$INSTALL_ROOT" && ! -d "$INSTALL_ROOT/.git" ]] ||
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
