#!/usr/bin/env bats

load helpers

# The release layout: GitHub's releases list (newest first, macOS and Windows
# tags mixed in), assets under releases/download/V<version>-linux/. curl is a
# fake that serves $FIX and logs every URL; nothing here touches the network.

setup() {
    TEST_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mole-test.XXXXXX")"
    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin" "$TEST_ROOT/fix"
    unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME GOPROXY
    export PATH="$TEST_ROOT/bin:$PATH"
    export MOLE_TEST_REPO="$REPO" TEST_ROOT
    export FIX="$TEST_ROOT/fix" CURL_LOG="$TEST_ROOT/curl.log"
    cat > "$TEST_ROOT/bin/curl" << 'CURL'
#!/bin/bash
url="" out="" args=("$@")
for ((i = 0; i < $#; i++)); do
    case "${args[i]}" in
        -o) out="${args[i + 1]}" ;;
        http*) url="${args[i]}" ;;
    esac
done
echo "$url" >> "$CURL_LOG"
case "$url" in
    *"/releases?per_page"*)
        [[ -f "$FIX/api-down" ]] && exit 22
        f="$FIX/releases-${url##*page=}.json"
        if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi
        ;;
    *"/releases/download/"* | *"/dl/go"*.tar.gz)
        f="$FIX/${url##*/}"
        [[ -f "$f" ]] || exit 22
        if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi
        ;;
    *"/commits/linux")
        [[ -f "$FIX/commit" ]] || exit 22
        cat "$FIX/commit"
        ;;
    *"codeload.github.com/"*)
        [[ -f "$FIX/source-${url##*/}.tar.gz" ]] || exit 22
        cp "$FIX/source-${url##*/}.tar.gz" "$out"
        ;;
    "https://proxy.golang.org/"*)
        [[ -f "$FIX/proxy-up" ]] || exit 28
        ;;
    "https://go.dev/dl/?mode=json")
        [[ -f "$FIX/godev-down" || ! -f "$FIX/go.json" ]] && exit 22
        cat "$FIX/go.json"
        ;;
    "https://golang.google.cn/dl/?mode=json")
        [[ -f "$FIX/go.json" ]] || exit 22
        cat "$FIX/go.json"
        ;;
    *) exit 22 ;;
esac
CURL
    chmod +x "$TEST_ROOT/bin/curl"
}

# An installed Mole at version $1: the real scripts, so mo update runs for real.
install_current() {
    local root="$HOME/.local/share/mole"
    mkdir -p "$root"
    cp -R "$REPO/lib" "$REPO/bin" "$REPO/mole" "$REPO/install.sh" "$root/"
    echo "$1" > "$root/VERSION"
}

# A release asset set for version $1 in the fixture folder.
publish() {
    local version="$1" dir="$TEST_ROOT/build/mole-$1-linux-x86_64" arch
    arch="$(uname -m)"
    case "$arch" in aarch64 | arm64) arch=aarch64 ;; *) arch=x86_64 ;; esac
    dir="$TEST_ROOT/build/mole-$version-linux-$arch"
    mkdir -p "$dir/lib/core"
    printf '#!/bin/bash\necho "Mole version %s"\n' "$version" > "$dir/mole"
    echo "$version" > "$dir/VERSION"
    touch "$dir/lib/core/common.sh"
    tar -C "$TEST_ROOT/build" -czf "$FIX/mole-$version-linux-$arch.tar.gz" "mole-$version-linux-$arch"
    (cd "$FIX" && sha256sum "mole-$version-linux-$arch.tar.gz" > SHA256SUMS.txt)
}

# releases-1.json: $1 is the JSON array body.
releases() { printf '%s\n' "$1" > "$FIX/releases-1.json"; }

installed_version() { cat "$HOME/.local/share/mole/VERSION"; }

no_leftovers() { [ -z "$(ls -d "$HOME/.local/share/mole".* 2> /dev/null)" ]; }

run_update() { run bash "$HOME/.local/share/mole/bin/update.sh" "$@"; }

@test "mo update picks the newest stable linux tag among mac, windows and prerelease tags" {
    install_current 0.1.0
    publish 0.2.0
    releases '[{"tag_name": "V1.67.0", "prerelease": false}, {"tag_name": "V0.9.0-linux", "prerelease": true}, {"tag_name": "V1.40.0-windows", "prerelease": false}, {"tag_name": "V0.2.0-linux", "draft": false, "prerelease": false}, {"tag_name": "V0.1.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updating Mole 0.1.0 to 0.2.0"* ]]
    [ "$(installed_version)" = "0.2.0" ]
    [ "$(readlink "$HOME/.local/bin/mo")" = "$HOME/.local/share/mole/mole" ]
    no_leftovers
    grep -q 'releases/download/V0.2.0-linux/' "$CURL_LOG"
}

@test "mo update reads on to the next page when the first holds no linux release" {
    install_current 0.1.0
    publish 0.2.0
    releases '[{"tag_name": "V1.67.0", "prerelease": false}]'
    printf '%s\n' '[{"tag_name": "V0.2.0-linux", "prerelease": false}]' > "$FIX/releases-2.json"
    run_update
    [ "$status" -eq 0 ]
    [ "$(installed_version)" = "0.2.0" ]
}

@test "mo update on the latest version downloads nothing; --force reinstalls it" {
    install_current 0.2.0
    publish 0.2.0
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole 0.2.0 is the latest version"* ]]
    if grep -q 'releases/download' "$CURL_LOG"; then return 1; fi
    echo "marker" > "$HOME/.local/share/mole/marker"
    run_update --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reinstalling Mole 0.2.0"* ]]
    grep -q 'releases/download/V0.2.0-linux/' "$CURL_LOG"
    [ ! -e "$HOME/.local/share/mole/marker" ]
    [ "$(installed_version)" = "0.2.0" ]
    no_leftovers
}

@test "mo update --force with a newer release installs it, -f is the same, other flags fail" {
    install_current 0.1.0
    publish 0.2.0
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    run_update --beta
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown update option: --beta"* ]]
    run_update --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--force"* ]]
    [ ! -e "$CURL_LOG" ]
    run_update -f
    [ "$status" -eq 0 ]
    [ "$(installed_version)" = "0.2.0" ]
}

@test "a checksum mismatch installs nothing and keeps the old version" {
    install_current 0.1.0
    publish 0.2.0
    sed -i 's/^[0-9a-f]\{64\}/'"$(printf '0%.0s' {1..64})"'/' "$FIX/SHA256SUMS.txt"
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [ "$(installed_version)" = "0.1.0" ]
    no_leftovers
}

@test "a missing archive or checksum file fails with the URL and keeps the old version" {
    install_current 0.1.0
    publish 0.2.0
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    rm "$FIX/SHA256SUMS.txt"
    run_update
    [ "$status" -ne 0 ]
    [[ "$output" == *"Download failed"*"SHA256SUMS.txt"* ]]
    [ "$(installed_version)" = "0.1.0" ]
    publish 0.2.0
    rm "$FIX"/mole-0.2.0-linux-*.tar.gz
    run_update
    [ "$status" -ne 0 ]
    [[ "$output" == *"Download failed"*".tar.gz"* ]]
    [ "$(installed_version)" = "0.1.0" ]
    no_leftovers
}

@test "an archive that matches its checksum but will not unpack keeps the old version" {
    install_current 0.1.0
    publish 0.2.0
    local asset
    asset="$(ls "$FIX"/mole-0.2.0-linux-*.tar.gz)"
    echo "not a tarball" > "$asset"
    (cd "$FIX" && sha256sum "$(basename "$asset")" > SHA256SUMS.txt)
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not unpack"* ]]
    [ "$(installed_version)" = "0.1.0" ]
    no_leftovers
}

@test "a release whose files report another version keeps the old version" {
    install_current 0.1.0
    publish 0.2.0
    local asset dir
    asset="$(ls "$FIX"/mole-0.2.0-linux-*.tar.gz)"
    dir="$(ls -d "$TEST_ROOT"/build/mole-0.2.0-linux-*)"
    printf '#!/bin/bash\necho "Mole version 9.9.9"\n' > "$dir/mole"
    tar -C "$TEST_ROOT/build" -czf "$asset" "$(basename "$dir")"
    (cd "$FIX" && sha256sum "$(basename "$asset")" > SHA256SUMS.txt)
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -ne 0 ]
    [ "$(installed_version)" = "0.1.0" ]
    no_leftovers
}

@test "GitHub unreachable or rate limited reads as unreachable, never as no release" {
    install_current 0.1.0
    touch "$FIX/api-down"
    run_update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not reach GitHub"* ]]
    [ "$(installed_version)" = "0.1.0" ]
}

@test "no linux release, or only a prerelease, says so and changes nothing" {
    install_current 0.1.0
    releases '[{"tag_name": "V1.67.0", "prerelease": false}, {"tag_name": "V0.2.0-linux", "prerelease": true}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Mole CLI (Linux) release found"* ]]
    [ "$(installed_version)" = "0.1.0" ]
}

@test "mo update refuses a source checkout and a copy that is not the installed one" {
    run bash "$REPO/bin/update.sh"
    [ "$status" -ne 0 ]
    mkdir -p "$TEST_ROOT/elsewhere"
    cp -R "$REPO/lib" "$REPO/bin" "$REPO/mole" "$REPO/install.sh" "$REPO/VERSION" "$TEST_ROOT/elsewhere/"
    run bash "$TEST_ROOT/elsewhere/bin/update.sh" --force
    [ "$status" -ne 0 ]
    [[ "$output" == *"not an installed copy"* ]]
    ! [ -e "$HOME/.local/share/mole" ]
}

@test "help and --help name the update flags in Mac's wording" {
    run bash "$REPO/mole" --help
    [[ "$output" == *"mo update --force"*"Force reinstall latest version"* ]]
    [[ "$output" == *"mo update --nightly"*"Install latest unreleased build"* ]]
    [[ "$output" == *"mo update "*"Update to latest version"* ]]
    [[ "$output" == *"Remove Mole from system"* ]]
}

# ---- the main-menu notice ---------------------------------------------------

# Runs $1 with the update-notice library and a stubbed lookup (no network).
notice_run() {
    mkdir -p "$HOME/.local/share/mole"
    mole_run core "source \"\$MOLE_TEST_REPO/lib/core/update_notice.sh\"
SCRIPT_DIR=\"\$HOME/.local/share/mole\"
VERSION=0.1.0
mole_update_fetch_latest() { echo x >> \"\$TEST_ROOT/calls\"; echo \"\$NOTICE_LATEST\"; }
calls=0
count() { calls=\$(wc -l < \"\$TEST_ROOT/calls\" 2> /dev/null || echo 0); calls=\${calls// /}; }
$1"
}

@test "notice looks once a day and shows the line only when newer" {
    export NOTICE_LATEST=0.2.0
    notice_run 'mole_update_notice_check wait; mole_update_notice_check wait; count; echo "calls=$calls"; mole_update_notice_message'
    [[ "$output" == *"calls=1"* ]]
    [[ "$output" == *"Update 0.2.0 available, run mo update"* ]]
}

@test "notice looks again after a day and when the clock went backwards" {
    export NOTICE_LATEST=0.2.0
    mkdir -p "$HOME/.cache/mole"
    echo "$(($(date +%s) - 90000)) 86400" > "$HOME/.cache/mole/update_check"
    notice_run 'mole_update_notice_check wait; count; echo "calls=$calls"'
    [[ "$output" == *"calls=1"* ]]
    echo "$(($(date +%s) + 90000)) 86400" > "$HOME/.cache/mole/update_check"
    notice_run 'mole_update_notice_check wait; count; echo "calls=$calls"'
    [[ "$output" == *"calls=2"* ]]
}

@test "notice stays quiet when current or older, and a failed lookup retries in an hour" {
    export NOTICE_LATEST=0.1.0
    notice_run 'mole_update_notice_check wait; echo "msg=[$(mole_update_notice_message)]"'
    [[ "$output" == *"msg=[]"* ]]
    export NOTICE_LATEST=0.0.9
    rm -rf "$HOME/.cache/mole"
    notice_run 'mole_update_notice_check wait; echo "msg=[$(mole_update_notice_message)]"'
    [[ "$output" == *"msg=[]"* ]]
    export NOTICE_LATEST="<html>rate limited"
    rm -rf "$HOME/.cache/mole"
    notice_run 'mole_update_notice_check wait; echo "msg=[$(mole_update_notice_message)]"; cat "$MOLE_CACHE_HOME/mole/update_check"'
    [[ "$output" == *"msg=[]"* && "$output" == *" 3600"* ]]
}

@test "notice drops once the installed version catches up" {
    export NOTICE_LATEST=0.2.0
    notice_run 'mole_update_notice_check wait; echo "before=[$(mole_update_notice_message)]"; VERSION=0.2.0; echo "msg=[$(mole_update_notice_message)]"'
    [[ "$output" == *"before=[Update 0.2.0"* && "$output" == *"msg=[]"* ]]
}

@test "notice is off in a source checkout, and no environment variable switches it" {
    export NOTICE_LATEST=0.2.0
    # MOLE_NO_UPDATE_CHECK was a switch until 2026-11-10; the lookup is one
    # background request a day and needs no setting.
    MOLE_NO_UPDATE_CHECK=1 notice_run 'mole_update_notice_check wait; count; echo "calls=$calls msg=[$(mole_update_notice_message)]"'
    [[ "$output" == *"calls=1 msg=[Update 0.2.0"* ]]
    rm -f "$TEST_ROOT/calls"
    mkdir -p "$TEST_ROOT/co/.git"
    notice_run "SCRIPT_DIR='$TEST_ROOT/co'; mole_update_notice_check wait; count; echo \"calls=\$calls\""
    [[ "$output" == *"calls=0"* ]]
}

@test "notice stays quiet in a copy that is not the installed one" {
    export NOTICE_LATEST=0.2.0
    mkdir -p "$TEST_ROOT/elsewhere"
    notice_run "SCRIPT_DIR='$TEST_ROOT/elsewhere'; mole_update_notice_check wait; count; echo \"calls=\$calls\""
    [[ "$output" == *"calls=0"* ]]
    # A cached answer from the installed copy is not shown in the other one.
    notice_run 'mole_update_notice_check wait; SCRIPT_DIR='"$TEST_ROOT/elsewhere"'; echo "msg=[$(mole_update_notice_message)]"'
    [[ "$output" == *"msg=[]"* ]]
}

@test "mo update --force refuses to replace a newer installed version with an older release" {
    install_current 1.3.0
    publish 1.2.0
    releases '[{"tag_name": "V1.2.0-linux", "prerelease": false}]'
    run_update --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole 1.3.0 is newer than the latest release 1.2.0"* ]]
    [ -z "$(grep 'releases/download' "$CURL_LOG")" ]
    [ "$(installed_version)" = "1.3.0" ]
    install_current 0.10.0
    publish 0.9.0
    releases '[{"tag_name": "V0.9.0-linux", "prerelease": false}]'
    run_update -f
    [[ "$output" == *"newer than the latest release 0.9.0"* ]]
    [ "$(installed_version)" = "0.10.0" ]
}

@test "versions compare by their X.Y.Z core: a prerelease or broken VERSION is replaced, never downgraded" {
    install_current 0.2.0-rc1
    publish 0.2.0
    releases '[{"tag_name": "V0.2.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updating Mole 0.2.0-rc1 to"* ]]
    [ "$(installed_version)" = "0.2.0" ]

    rm -f "$CURL_LOG"
    install_current 0.1.0
    rm -f "$HOME/.local/share/mole/VERSION"
    publish 0.1.0
    releases '[{"tag_name": "V0.1.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updating Mole unknown to"* ]]
    [ "$(installed_version)" = "0.1.0" ]
    install_current unknown
    run_update --force
    [ "$status" -eq 0 ]
    [ "$(installed_version)" = "0.1.0" ]

    rm -f "$CURL_LOG"
    install_current 0.1.0
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole 0.1.0 is the latest version"* ]]
    [ -z "$(grep 'releases/download' "$CURL_LOG")" ]

    install_current 0.10.0
    publish 0.9.0
    releases '[{"tag_name": "V0.9.0-linux", "prerelease": false}]'
    run_update --force
    [[ "$output" == *"Mole 0.10.0 is newer than the latest release 0.9.0"* ]]
    [ "$(installed_version)" = "0.10.0" ]
}

@test "the notice offers a release over a prerelease of the same version, not over a newer core" {
    export NOTICE_LATEST=0.2.0
    notice_run 'VERSION=0.2.0-rc1; mole_update_notice_check wait; echo "rc=[$(mole_update_notice_message)]"; VERSION=0.3.0-rc1; echo "newer=[$(mole_update_notice_message)]"'
    [[ "$output" == *"rc=[Update 0.2.0 available"* ]]
    [[ "$output" == *"newer=[]"* ]]
}

@test "the background check returns at once even when the lookup hangs" {
    notice_run 'mole_update_fetch_latest() { sleep 30; }
        start=$SECONDS; mole_update_notice_check; echo "took=$((SECONDS - start))"'
    [[ "$output" == *"took=0"* || "$output" == *"took=1"* ]]
}

# ---- nightly ----------------------------------------------------------------

SHA=0123456789abcdef0123456789abcdef01234567

# The linux branch at $SHA: this repository's files with release core $1,
# plus source-only folders a release archive never holds.
nightly_source() {
    local top="$TEST_ROOT/src/Mole-$SHA"
    rm -rf "$TEST_ROOT/src"
    mkdir -p "$top/tests" "$top/cmd/trash" "$top/.github"
    cp -R "$REPO/lib" "$REPO/bin" "$REPO/mole" "$REPO/mo" "$REPO/install.sh" "$REPO/LICENSE" "$REPO/README.md" "$REPO/go.mod" "$top/"
    rm -f "$top"/bin/*-go
    echo "$1" > "$top/VERSION"
    [[ "${2:-}" == main ]] && sed -i '2s/.*/# Mole - installer for macOS./' "$top/install.sh"
    tar -C "$TEST_ROOT/src" -czf "$FIX/source-$SHA.tar.gz" "Mole-$SHA"
    printf '%s' "$SHA" > "$FIX/commit"
}

# A go at $2 (default first on PATH) that logs its settings and, by mode $1:
# ok builds an executable stub at each -o; fail fails everything, like a go
# older than go.mod asks for; newfail reports go9.9.9 but cannot build.
fake_go() {
    local dest="${2:-$TEST_ROOT/bin/go}"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" << GO
#!/bin/bash
echo "\$0 \$1 GOTOOLCHAIN=\$GOTOOLCHAIN GOPROXY=\$GOPROXY GOPATH=\$GOPATH GOWORK=\$GOWORK GOFLAGS=\$GOFLAGS GOCACHE=\$GOCACHE XDG_CONFIG_HOME=\$XDG_CONFIG_HOME" >> "$TEST_ROOT/go.log"
# Without GOTOOLCHAIN=local an old go switches to the toolchain go.mod asks for.
[[ "$1" == fail && "\$1 \$2" == "env GOVERSION" && "\$GOTOOLCHAIN" != local ]] && { echo go9.9.9; exit 0; }
[[ "$1" == fail ]] && exit 1
if [[ "\$1" == env ]]; then
    [[ "\$2" == GOVERSION && "$1" == newfail ]] && echo go9.9.9
    [[ "\$2" == GOPROXY ]] && echo "\${FAKE_GOENV_PROXY:-https://proxy.golang.org,direct}"
    exit 0
fi
[[ "$1" == newfail ]] && { echo "dial tcp: lookup proxy: no such host" >&2; exit 1; }
mkdir -p "\$GOCACHE" && touch "\$GOCACHE/marker"
while [[ \$# -gt 0 ]]; do [[ "\$1" == -o ]] && printf '#!/bin/sh\necho %s\n' "\$2" > "\$2" && chmod +x "\$2"; shift; done
GO
    chmod +x "$dest"
}

# go.dev's listing and archive for a toolchain whose go builds; $1 = bad
# lists a wrong checksum.
publish_go() {
    local arch=amd64 name sum
    case "$(uname -m)" in aarch64 | arm64) arch=arm64 ;; esac
    name="go9.9.9.linux-$arch.tar.gz"
    fake_go ok "$TEST_ROOT/gobuild/go/bin/go"
    tar -C "$TEST_ROOT/gobuild" -czf "$FIX/$name" go
    sum=$(sha256sum "$FIX/$name" | awk '{print $1}')
    [[ "${1:-}" == bad ]] && sum=$(printf '0%.0s' {1..64})
    printf '[\n {\n  "version": "go9.9.9",\n  "files": [\n   {\n    "filename": "%s",\n    "os": "linux",\n    "sha256": "%s",\n    "kind": "archive"\n   }\n  ]\n }\n]\n' "$name" "$sum" > "$FIX/go.json"
}

# Release 0.4.0 whose archive holds the helpers named in $@.
publish_with_helpers() {
    local arch=x86_64 t
    case "$(uname -m)" in aarch64 | arm64) arch=aarch64 ;; esac
    mkdir -p "$TEST_ROOT/build/mole-0.4.0-linux-$arch/bin"
    for t in "$@"; do
        printf '#!/bin/sh\necho release-%s\n' "$t" > "$TEST_ROOT/build/mole-0.4.0-linux-$arch/bin/$t-go"
        chmod +x "$TEST_ROOT/build/mole-0.4.0-linux-$arch/bin/$t-go"
    done
    publish 0.4.0
    releases '[{"tag_name": "V0.4.0-linux", "prerelease": false}]'
}

go_dir() { ls -d "$HOME/.cache/mole/go/go9.9.9.linux-"* 2> /dev/null; }

@test "mo update --nightly builds the helpers with the user's go and installs that commit" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go ok
    run_update --nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updating Mole 0.4.0 to nightly 0123456"* ]]
    [[ "$output" == *"Built the nightly helpers"* ]]
    [ "$(installed_version)" = "0.4.0-nightly.0123456" ]
    [ "$(cat "$HOME/.local/share/mole/NIGHTLY")" = "$SHA" ]
    for t in trash status analyze; do [ -x "$HOME/.local/share/mole/bin/$t-go" ] || return 1; done
    grep -q "codeload.github.com/tw93/Mole/tar.gz/$SHA" "$CURL_LOG"
    if grep -q 'mode=json' "$CURL_LOG"; then return 1; fi
    # The fake curl refuses proxy.golang.org, as a blocked network does.
    grep -q "build GOTOOLCHAIN=local GOPROXY=https://goproxy.cn,direct GOPATH=$HOME/.cache/mole/go/path GOWORK=off GOFLAGS=-modcacherw GOCACHE=[^ ]*/mole-install\.[^ /]*/go-build XDG_CONFIG_HOME= *$" "$TEST_ROOT/go.log"
    for d in tests cmd .github; do [ ! -e "$HOME/.local/share/mole/$d" ] || return 1; done
    [ ! -e "$HOME/.cache/mole/go/build" ]
    no_leftovers
    run bash "$HOME/.local/share/mole/mole" --version
    [[ "$output" == *"Install: Nightly (0123456)"* ]]
}

@test "the same nightly again downloads nothing; --force reinstalls it" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go ok
    run_update --nightly
    [ "$status" -eq 0 ]
    : > "$CURL_LOG"
    run_update --nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already on the latest nightly, 0123456"* ]]
    if grep -q codeload "$CURL_LOG"; then return 1; fi
    run_update --nightly --force
    [ "$status" -eq 0 ]
    grep -q codeload "$CURL_LOG"
}

@test "plain mo update on a nightly switches back to the stable release" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go ok
    run_update --nightly
    [ "$status" -eq 0 ]
    publish 0.4.0
    releases '[{"tag_name": "V0.4.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching Mole 0.4.0-nightly.0123456 to the stable release 0.4.0"* ]]
    [ "$(installed_version)" = "0.4.0" ]
    [ ! -e "$HOME/.local/share/mole/NIGHTLY" ]
}

@test "without a usable go, nightly downloads a checksum-checked Go into Mole's cache and reuses it" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go fail
    publish_go
    touch "$FIX/godev-down"
    mkdir -p "$HOME/.cache/mole/go/go1.0.0.linux-amd64/go/bin"
    run_update --nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"Built the nightly helpers"* ]]
    grep -q '^https://golang.google.cn/dl/go9.9.9' "$CURL_LOG"
    [ -x "$(go_dir)/go/bin/go" ]
    [ -x "$HOME/.local/share/mole/bin/trash-go" ]
    grep -q "/go9.9.9.linux-[a-z0-9]*/go/bin/go build .*XDG_CONFIG_HOME=.*/go-config$" "$TEST_ROOT/go.log"
    [ -z "$(ls -d "$HOME/.cache/mole/go/"*.tmp 2> /dev/null)" ]
    [ ! -e "$HOME/.cache/mole/go/go1.0.0.linux-amd64" ]
    : > "$CURL_LOG"
    run_update --nightly --force
    [ "$status" -eq 0 ]
    if grep -q '/dl/go9' "$CURL_LOG"; then return 1; fi
    # Both listings down: the cached toolchain still builds.
    rm -f "$FIX/go.json"
    run_update --nightly --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Built the nightly helpers"* ]]
}

@test "a cached toolchain folder without a runnable go is replaced" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go fail
    publish_go
    local arch=amd64
    case "$(uname -m)" in aarch64 | arm64) arch=arm64 ;; esac
    mkdir -p "$HOME/.cache/mole/go/go9.9.9.linux-$arch/junk"
    run_update --nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"Built the nightly helpers"* ]]
    [ -x "$HOME/.cache/mole/go/go9.9.9.linux-$arch/go/bin/go" ]
    [ ! -e "$HOME/.cache/mole/go/go9.9.9.linux-$arch/junk" ]
}

@test "a Go checksum mismatch is never used; nightly takes the release's helpers instead" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go fail
    publish_go bad
    publish_with_helpers trash status analyze
    run_update --nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checksum mismatch for go9.9.9"* ]]
    [[ "$output" == *"using those of 0.4.0"*"run mo update --nightly --force"* ]]
    [ -z "$(go_dir)" ]
    [ "$("$HOME/.local/share/mole/bin/trash-go")" = release-trash ]
    [ "$(installed_version)" = "0.4.0-nightly.0123456" ]
}

@test "a go new enough that still fails downloads no other Go and names the cause" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go newfail
    publish_go
    publish_with_helpers trash status analyze
    run_update --nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"go build: dial tcp: lookup proxy: no such host"* ]]
    [[ "$output" == *"using those of 0.4.0"* ]]
    if grep -q 'mode=json' "$CURL_LOG"; then return 1; fi
}

@test "a nightly missing any helper installs nothing" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go fail
    publish_with_helpers trash analyze
    run_update --nightly
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no status-go; nothing was installed"* ]]
    [ "$(installed_version)" = "0.4.0" ]
    no_leftovers
}

@test "nightly with GitHub unreachable, a non-Linux commit or no helpers anywhere changes nothing" {
    install_current 0.4.0
    run_update --nightly
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not read the newest nightly commit"* ]]
    [ "$(installed_version)" = "0.4.0" ]
    nightly_source 0.4.0 main
    fake_go ok
    run_update --nightly
    [ "$status" -eq 1 ]
    [[ "$output" == *"0123456 is not a Mole CLI (Linux) commit"* ]]
    [ "$(installed_version)" = "0.4.0" ]
    nightly_source 0.4.0
    fake_go fail
    run_update --nightly
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not build the Go helpers or read a release"* ]]
    [ "$(installed_version)" = "0.4.0" ]
    no_leftovers
}

@test "install.sh refuses a missing value and flags that do not go with --nightly" {
    for args in "--version" "--commit" "--nightly --version 0.4.0" "--nightly --latest" "--commit $SHA" \
        "--nightly --archive x" "--nightly --sums x" "--latest-commit --nightly" "--latest-commit --version 1.0.0" "--sums x"; do
        # shellcheck disable=SC2086 # each case is a word list
        run bash "$REPO/install.sh" $args
        [ "$status" -eq 1 ] || return 1
        [[ "$output" == *"needs a value"* || "$output" == *"does not take"* || "$output" == *"goes with --"* || "$output" == *"takes no other option"* ]] || return 1
    done
    if [ -e "$CURL_LOG" ]; then return 1; fi
}

@test "the notice on a nightly offers only a newer release core" {
    export NOTICE_LATEST=0.4.0
    notice_run 'VERSION=0.4.0-nightly.0123456; mole_update_notice_check wait; mole_update_notice_message; echo "[end]"'
    [ "$output" = "[end]" ]
    rm -rf "$HOME/.cache/mole"
    export NOTICE_LATEST=0.4.1
    notice_run 'VERSION=0.4.0-nightly.0123456; mole_update_notice_check wait; mole_update_notice_message'
    [ "$output" = "Update 0.4.1 available, run mo update" ]
}

@test "nightly builds use the user's GOPROXY, then go env -w, then proxy.golang.org when it answers" {
    install_current 0.4.0
    nightly_source 0.4.0
    fake_go ok
    GOPROXY=https://env.example run_update --nightly
    [ "$status" -eq 0 ]
    grep -q "build .*GOPROXY=https://env.example " "$TEST_ROOT/go.log"
    : > "$TEST_ROOT/go.log"
    FAKE_GOENV_PROXY=https://corp.example run_update --nightly --force
    [ "$status" -eq 0 ]
    grep -q "build .*GOPROXY=https://corp.example " "$TEST_ROOT/go.log"
    : > "$TEST_ROOT/go.log"
    touch "$FIX/proxy-up"
    run_update --nightly --force
    [ "$status" -eq 0 ]
    grep -q "build .*GOPROXY=https://proxy.golang.org,direct " "$TEST_ROOT/go.log"
}

@test "plain mo update leaves a nightly whose core is above the latest release" {
    install_current 0.4.0
    nightly_source 0.5.0
    fake_go ok
    run_update --nightly
    [ "$status" -eq 0 ]
    [ "$(installed_version)" = "0.5.0-nightly.0123456" ]
    publish 0.4.0
    releases '[{"tag_name": "V0.4.0-linux", "prerelease": false}]'
    run_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching Mole 0.5.0-nightly.0123456 to the stable release 0.4.0"* ]]
    [ "$(installed_version)" = "0.4.0" ]
}
