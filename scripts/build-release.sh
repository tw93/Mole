#!/bin/bash
# Build the Mole CLI (Linux) release archives into release/:
#   mole-<version>-linux-x86_64.tar.gz, mole-<version>-linux-aarch64.tar.gz,
#   SHA256SUMS.txt
# Each archive holds one top folder with the scripts, lib/ and the three Go
# helpers built for that architecture. Usage: scripts/build-release.sh [version]

set -euo pipefail

cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.."
version="${1:-$(tr -d '[:space:]' < VERSION)}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Not a release version: $version" >&2
    exit 1
}
[[ "$(tr -d '[:space:]' < VERSION)" == "$version" ]] || {
    echo "VERSION says $(tr -d '[:space:]' < VERSION), asked for $version" >&2
    exit 1
}

out="release"
rm -rf -- "$out"
mkdir -p "$out"

for pair in x86_64:amd64 aarch64:arm64; do
    arch="${pair%%:*}"
    goarch="${pair#*:}"
    name="mole-$version-linux-$arch"
    stage="$out/stage/$name"
    mkdir -p "$stage/bin"
    cp mole mo install.sh VERSION LICENSE README.md "$stage/"
    cp bin/*.sh "$stage/bin/"
    cp -R lib "$stage/lib"
    for tool in trash status analyze; do
        GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
            -o "$stage/bin/$tool-go" "./cmd/$tool"
    done
    # Files belong to root:root in the archive; the installer unpacks them
    # with --no-same-owner, so they end up owned by the installing user.
    if tar --version 2> /dev/null | grep -q 'GNU tar'; then
        tar --owner=0 --group=0 --numeric-owner -C "$out/stage" -czf "$out/$name.tar.gz" "$name"
    else
        COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 -C "$out/stage" -czf "$out/$name.tar.gz" "$name"
    fi
done
rm -rf -- "$out/stage"

(cd "$out" && sha256sum -- *.tar.gz > SHA256SUMS.txt)
ls -l "$out"
cat "$out/SHA256SUMS.txt"
