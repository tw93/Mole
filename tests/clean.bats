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
    [[ "$output" == *"skipped while anything is running"* ]]
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
    [[ "$output" == *"skipped while"* ]]
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
