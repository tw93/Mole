#!/usr/bin/env bats

load helpers

# The release layout: GitHub's releases list (newest first, macOS and Windows
# tags mixed in), assets under releases/download/V<version>-linux/. curl is a
# fake that serves $FIX and logs every URL; nothing here touches the network.

setup() {
    TEST_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mole-test.XXXXXX")"
    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin" "$TEST_ROOT/fix"
    unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
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
    *"/releases/download/"*)
        f="$FIX/${url##*/}"
        [[ -f "$f" ]] || exit 22
        if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi
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
    ! grep -q 'releases/download' "$CURL_LOG"
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
    run_update --nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown update option: --nightly"* ]]
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
    [[ "$output" == *"mo update "*"Update to latest version"* ]]
    [[ "$output" == *"Remove Mole from system"* ]]
}

# ---- the main-menu notice ---------------------------------------------------

# Runs $1 with the update-notice library and a stubbed lookup (no network).
notice_run() {
    mole_run core "source \"\$MOLE_TEST_REPO/lib/core/update_notice.sh\"
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

@test "notice is off with MOLE_NO_UPDATE_CHECK=1 and in a source checkout" {
    export NOTICE_LATEST=0.2.0
    MOLE_NO_UPDATE_CHECK=1 notice_run 'mole_update_notice_check wait; count; echo "calls=$calls msg=[$(mole_update_notice_message)]"'
    [[ "$output" == *"calls=0 msg=[]"* ]]
    mkdir -p "$TEST_ROOT/co/.git"
    notice_run "SCRIPT_DIR='$TEST_ROOT/co'; mole_update_notice_check wait; count; echo \"calls=\$calls\""
    [[ "$output" == *"calls=0"* ]]
}

@test "the background check returns at once even when the lookup hangs" {
    notice_run 'mole_update_fetch_latest() { sleep 30; }
        start=$SECONDS; mole_update_notice_check; echo "took=$((SECONDS - start))"'
    [[ "$output" == *"took=0"* || "$output" == *"took=1"* ]]
}
