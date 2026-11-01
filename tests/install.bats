#!/usr/bin/env bats

load helpers

# A minimal release archive whose mole reports $1, plus its SHA256SUMS.txt.
make_release() {
    local version="$1" claims="${2:-$1}" dir="$TEST_ROOT/build/mole-$1-linux-x86_64"
    mkdir -p "$dir/lib/core"
    printf '#!/bin/bash\necho "Mole version %s"\n' "$claims" > "$dir/mole"
    echo "$version" > "$dir/VERSION"
    touch "$dir/lib/core/common.sh"
    tar -C "$TEST_ROOT/build" -czf "$TEST_ROOT/mole-$version-linux-x86_64.tar.gz" "mole-$version-linux-x86_64"
    (cd "$TEST_ROOT" && sha256sum "mole-$version-linux-x86_64.tar.gz" > SHA256SUMS.txt)
}

install_release() {
    run bash "$REPO/install.sh" --archive "$TEST_ROOT/mole-$1-linux-x86_64.tar.gz" --sums "$TEST_ROOT/SHA256SUMS.txt"
}

@test "installs, links mo and mole, and upgrades in place" {
    make_release 0.1.0
    install_release 0.1.0
    [ "$status" -eq 0 ]
    [ "$(readlink "$HOME/.local/bin/mo")" = "$HOME/.local/share/mole/mole" ]
    [ "$(cat "$HOME/.local/share/mole/VERSION")" = "0.1.0" ]
    make_release 0.2.0
    install_release 0.2.0
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.local/share/mole/VERSION")" = "0.2.0" ]
    [ -z "$(ls -d "$HOME/.local/share/mole".* 2> /dev/null)" ]
}

@test "a checksum mismatch installs nothing" {
    make_release 0.1.0
    sed -i 's/^[0-9a-f]\{64\}/'"$(printf '0%.0s' {1..64})"'/' "$TEST_ROOT/SHA256SUMS.txt"
    install_release 0.1.0
    [ "$status" -eq 1 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [ ! -e "$HOME/.local/share/mole" ]
}

@test "a release that reports another version installs nothing and leaves no copy" {
    make_release 0.1.0 9.9.9
    install_release 0.1.0
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.local/share/mole" ]
    [ -z "$(ls -d "$HOME/.local/share/mole".* 2> /dev/null)" ]
}

@test "a failed upgrade keeps the installed version" {
    make_release 0.1.0
    install_release 0.1.0
    make_release 0.2.0 9.9.9
    install_release 0.2.0
    [ "$status" -eq 1 ]
    [ "$(cat "$HOME/.local/share/mole/VERSION")" = "0.1.0" ]
    [ -z "$(ls -d "$HOME/.local/share/mole".* 2> /dev/null)" ]
}

@test "another program's mo is left alone" {
    mkdir -p "$HOME/.local/bin" "$HOME/tools"
    printf '#!/bin/sh\n' > "$HOME/tools/mo"
    ln -s "$HOME/tools/mo" "$HOME/.local/bin/mo"
    make_release 0.1.0
    install_release 0.1.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"belongs to another program"* ]]
    [ "$(readlink "$HOME/.local/bin/mo")" = "$HOME/tools/mo" ]
    [ "$(readlink "$HOME/.local/bin/mole")" = "$HOME/.local/share/mole/mole" ]
}

@test "a folder at the install path that is not an installed Mole is refused" {
    mkdir -p "$HOME/.local/share/mole"
    echo mine > "$HOME/.local/share/mole/notes.txt"
    make_release 0.1.0
    install_release 0.1.0
    [ "$status" -eq 1 ]
    [ -f "$HOME/.local/share/mole/notes.txt" ]
}

@test "only an exact V1.2.3-linux tag counts as a Linux release" {
    fake_command curl 'case "$*" in
        *"&page=1") printf "%s\n" "[{\"tag_name\": \"V1.67.0\"}, {\"tag_name\": \"V1.40.0-windows\"}, {\"tag_name\": \"V0.2.0-linux-beta\"}]" ;;
        *"&page=2") printf "%s\n" "[{\"tag_name\": \"V0.1.0-linux\"}]" ;;
        *) printf "[]\n" ;;
    esac'
    run bash "$REPO/install.sh" --latest
    [ "$status" -eq 0 ]
    [ "$output" = "0.1.0" ]
    fake_command curl 'case "$*" in *"&page=1") printf "[{\"tag_name\": \"V1.67.0\"}]\n" ;; *) printf "[]\n" ;; esac'
    run bash "$REPO/install.sh" --latest
    [ "$status" -eq 3 ]
}
