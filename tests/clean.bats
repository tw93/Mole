#!/usr/bin/env bats

load helpers

make_cache() {
    mkdir -p "$1/entry"
    head -c 65536 /dev/zero > "$1/entry/blob"
}

@test "a rule is skipped while its owner runs, and cleaned once it stops" {
    make_cache "$HOME/.cache/moletool"
    cp "$(command -v sleep)" "$TEST_ROOT/moleowner"
    "$TEST_ROOT/moleowner" 30 &
    OWNER_PID=$!
    mole_run clean 'clean_rule "Mole tool cache" "$HOME/.cache/moletool" "moleowner"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped while moleowner is running"* ]]
    [ -f "$HOME/.cache/moletool/entry/blob" ]

    kill "$OWNER_PID"
    wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""
    mole_run clean 'clean_rule "Mole tool cache" "$HOME/.cache/moletool" "moleowner"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole tool cache"* ]]
    [ -d "$HOME/.cache/moletool" ]
    [ ! -e "$HOME/.cache/moletool/entry" ]
}

@test "a rule is skipped when the owner probe cannot run" {
    make_cache "$HOME/.cache/moletool"
    fake_command pgrep 'exit 3'
    mole_run clean 'clean_rule "Mole tool cache" "$HOME/.cache/moletool" "anything"'
    [[ "$output" == *"Mole tool cache · skipped (process state unknown)"* ]]
    [[ "$output" != *"is running"* ]]
    [ -f "$HOME/.cache/moletool/entry/blob" ]
}

@test "a Flatpak app cache waits for flatpak to say the app is not running" {
    make_cache "$HOME/.var/app/org.test.App/cache"
    fake_command flatpak '[[ "$1" == ps ]] && echo org.test.App'
    mole_run clean 'clean_rule "org.test.App cache" "$HOME/.var/app/org.test.App/cache" "flatpak:org.test.App"'
    [[ "$output" == *"skipped while org.test.App is running"* ]]
    [ -f "$HOME/.var/app/org.test.App/cache/entry/blob" ]

    fake_command flatpak 'exit 1'
    mole_run clean 'clean_rule "org.test.App cache" "$HOME/.var/app/org.test.App/cache" "flatpak:org.test.App"'
    [[ "$output" == *"skipped (process state unknown)"* ]]
    [ -f "$HOME/.var/app/org.test.App/cache/entry/blob" ]

    fake_command flatpak '[[ "$1" == ps ]] && echo org.other.App'
    mole_run clean 'clean_rule "org.test.App cache" "$HOME/.var/app/org.test.App/cache" "flatpak:org.test.App"'
    [ ! -e "$HOME/.var/app/org.test.App/cache/entry" ]
}

@test "only a Flatpak app's cache folder becomes a rule, never its data" {
    mkdir -p "$HOME/.var/app/org.test.App/cache" "$HOME/.var/app/org.test.App/data" "$HOME/.var/app/org.nocache.App/config"
    mole_run clean 'mole_flatpak_cache_rules'
    [ "$status" -eq 0 ]
    [ "$output" = "Flatpak apps|org.test.App cache|$HOME/.var/app/org.test.App/cache|flatpak:org.test.App" ]
}

@test "every rule root sits under HOME and none is a model store or protected path" {
    mkdir -p "$HOME/.var/app/org.test.App/cache"
    mole_run clean '
        while IFS="|" read -r section label root owners; do
            [[ "$root" == "$HOME/"* ]] || { echo "outside home: $root"; exit 1; }
            case "$root" in
                *huggingface* | *ollama* | *lm-studio* | */.cache/doc*) echo "model or portal: $root"; exit 1 ;;
            esac
            mole_is_protected_path "$root" && { echo "protected: $root"; exit 1; }
        done < <(mole_clean_rules)
        echo ok'
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "dry run lists a rule without removing anything" {
    make_cache "$HOME/.cache/moletool"
    mole_run clean 'DRY_RUN=true; clean_rule "Mole tool cache" "$HOME/.cache/moletool" ""'
    [[ "$output" == *"Mole tool cache"*"dry"* ]]
    [ -f "$HOME/.cache/moletool/entry/blob" ]
}

@test "outside a terminal, clean never asks for a password and skips System" {
    fake_command sudo 'echo "$*" >> "'"$TEST_ROOT"'/sudo.log"; exit 1'
    fake_command journalctl 'exit 0'
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO" bash "$MOLE_TEST_REPO/bin/clean.sh" < /dev/null'
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped without sudo"* ]]
    [ -z "$(grep -- '-v' "$TEST_ROOT/sudo.log")" ]
}

@test "a sudo session the user already had survives Mole" {
    fake_command sudo 'echo "$*" >> "'"$TEST_ROOT"'/sudo.log"; exit 0'
    mole_run core 'mole_sudo_ready; mole_sudo_end'
    [ "$status" -eq 0 ]
    [ -z "$(grep -x -- '-k' "$TEST_ROOT/sudo.log")" ]
    [ -z "$(grep -- '-p' "$TEST_ROOT/sudo.log")" ]
}

# Run a stand-in process under a given name until the test ends.
start_owner() {
    cp "$(command -v sleep)" "$TEST_ROOT/$1"
    "$TEST_ROOT/$1" 30 &
    OWNER_PID=$!
}

@test "JetBrains: only each IDE's log folder is a rule, LocalHistory and index stay" {
    jb="$HOME/.cache/JetBrains/IntelliJIdea2026.2"
    make_cache "$jb/log"
    make_cache "$jb/LocalHistory"
    make_cache "$jb/index"
    mole_run clean 'mole_clean_rules | grep JetBrains'
    [ "$output" = "Developer tools|JetBrains IDE logs|$jb/log|idea,pycharm,webstorm,goland,clion,rustrover,rider,phpstorm,rubymine,datagrip,dataspell,aqua,fleet,studio,cmd:com[.]intellij[.]idea[.]Main" ]
    mole_run clean 'clean_user_rules'
    [ "$status" -eq 0 ]
    [ ! -e "$jb/log/entry" ]
    [ -f "$jb/LocalHistory/entry/blob" ]
    [ -f "$jb/index/entry/blob" ]
}

@test "JetBrains logs wait for an IDE that runs as java" {
    jb="$HOME/.cache/JetBrains/PyCharm2026.2"
    make_cache "$jb/log"
    bash -c 'sleep 30; :' -Didea.vendor.name=JetBrains com.intellij.idea.Main &
    OWNER_PID=$!
    mole_run clean 'clean_user_rules'
    [[ "$output" == *"JetBrains IDE logs · skipped while idea is running"* ]]
    [ -f "$jb/log/entry/blob" ]
}

@test "Deno: remote imports and compiled output go, location_data and runtimes stay" {
    for d in deps remote gen npm location_data dl; do make_cache "$HOME/.cache/deno/$d"; done
    mole_run clean 'clean_user_rules'
    [ "$status" -eq 0 ]
    for d in deps remote gen npm; do [ ! -e "$HOME/.cache/deno/$d/entry" ]; done
    [ -f "$HOME/.cache/deno/location_data/entry/blob" ]
    [ -f "$HOME/.cache/deno/dl/entry/blob" ]
}

@test "uv: uv cache prune runs when uv exists, the folder is never rm'd, and without uv nothing happens" {
    make_cache "$HOME/.cache/uv"
    mole_run clean 'mole_clean_rules | grep "|uv cache|"'
    [ "$output" = "Developer tools|uv cache|$HOME/.cache/uv|uv,uvx|tool:uv" ]
    mole_run clean 'clean_rule "uv cache" "$HOME/.cache/uv" "uv,uvx" "tool:uv"'
    [ "$status" -eq 0 ]
    [ -f "$HOME/.cache/uv/entry/blob" ]

    fake_command uv 'case "$1 $2" in "cache dir") echo "$HOME/.cache/uv" ;; "cache prune") echo prune >> "'"$TEST_ROOT"'/uv.log" ;; esac'
    mole_run clean 'clean_rule "uv cache" "$HOME/.cache/uv" "uv,uvx" "tool:uv"'
    [ "$status" -eq 0 ]
    grep -qx prune "$TEST_ROOT/uv.log"
    [ -f "$HOME/.cache/uv/entry/blob" ]

    mole_run clean 'DRY_RUN=true; clean_rule "uv cache" "$HOME/.cache/uv" "uv,uvx" "tool:uv"'
    [[ "$output" == *"would run uv cache prune"* ]]
    [ "$(grep -c prune "$TEST_ROOT/uv.log")" -eq 1 ]
}

@test "dry run sizes only the children a real run would remove" {
    mkdir -p "$HOME/.cache/tool/plain" "$HOME/.cache/tool/mnt"
    head -c 65536 /dev/zero > "$HOME/.cache/tool/plain/blob"
    head -c 4194304 /dev/zero > "$HOME/.cache/tool/mnt/blob"
    real_stat="$(command -v stat)"
    fake_command stat 'if [[ "${!#}" == */mnt ]]; then echo 99; else exec '"$real_stat"' "$@"; fi'
    mole_run clean 'DRY_RUN=true; clean_rule "Tool cache" "$HOME/.cache/tool" ""'
    [[ "$output" == *"Tool cache"*"KB"*"dry"* ]]
    [[ "$output" != *"MB"* ]]
}

@test "a redirected cache folder is named once and left alone" {
    mkdir -p "$TEST_ROOT/elsewhere"
    make_cache "$TEST_ROOT/elsewhere/chromium"
    make_cache "$TEST_ROOT/elsewhere/thumbnails"
    ln -s "$TEST_ROOT/elsewhere" "$HOME/.cache"
    mole_run clean 'clean_user_rules'
    [ "$status" -eq 0 ]
    [ "$(grep -c "is redirected elsewhere" <<< "$output")" -eq 1 ]
    [ -f "$TEST_ROOT/elsewhere/chromium/entry/blob" ]
    [ -f "$TEST_ROOT/elsewhere/thumbnails/entry/blob" ]

    rm "$HOME/.cache"
    export XDG_CACHE_HOME="$TEST_ROOT/elsewhere"
    mole_run clean 'clean_user_rules'
    [ "$(grep -c "is redirected elsewhere" <<< "$output")" -eq 1 ]
    [ -f "$TEST_ROOT/elsewhere/chromium/entry/blob" ]
}

@test "Bazel: only the repository cache goes, never an output base" {
    user=$(id -un)
    base="$HOME/.cache/bazel/_bazel_$user"
    make_cache "$base/cache/repos/v1"
    make_cache "$base/0123456789abcdef/execroot"
    chmod a-w "$base/0123456789abcdef/execroot/entry"
    mole_run clean 'mole_clean_rules | grep -i bazel'
    [ "$output" = "Developer tools|Bazel repository cache|$base/cache/repos|bazel,bazelisk,java" ]
    mole_run clean 'clean_user_rules'
    [ ! -e "$base/cache/repos/v1" ]
    [ -f "$base/0123456789abcdef/execroot/entry/blob" ]
}
