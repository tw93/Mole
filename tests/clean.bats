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

@test "browser profile caches never touch cookies, history, sessions or storage" {
    p="$HOME/.config/chromium/Default"
    mkdir -p "$p"
    echo '{}' > "$p/Preferences"
    for f in Cookies History "Login Data" "Web Data"; do echo x > "$p/$f"; done
    for d in "Local Storage" "Session Storage" IndexedDB Sessions "Service Worker"; do make_cache "$p/$d"; done
    make_cache "$p/GPUCache"
    make_cache "$p/Code Cache"
    make_cache "$HOME/.config/chromium/component_crx_cache"
    mole_run clean 'clean_user_rules'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Chromium profile caches"* ]]
    [ "$(grep -c "Chromium profile caches" <<< "$output")" -eq 1 ]
    [ ! -e "$p/GPUCache/entry" ]
    [ ! -e "$p/Code Cache/entry" ]
    [ ! -e "$HOME/.config/chromium/component_crx_cache/entry" ]
    for f in Cookies History "Login Data" "Web Data" Preferences; do [ -f "$p/$f" ]; done
    for d in "Local Storage" "Session Storage" IndexedDB Sessions "Service Worker"; do [ -f "$p/$d/entry/blob" ]; done
}

@test "new rules wait for their owners: Chromium profiles and an Electron app on system electron" {
    p="$HOME/.config/chromium/Default"
    mkdir -p "$p"
    echo '{}' > "$p/Preferences"
    make_cache "$p/GPUCache"
    start_owner chromium
    mole_run clean 'clean_user_rules'
    [[ "$output" == *"Chromium profile caches · skipped while chromium is running"* ]]
    [ -f "$p/GPUCache/entry/blob" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true

    make_cache "$HOME/.config/obsidian/Cache"
    echo '{}' > "$HOME/.config/obsidian/obsidian.json"
    start_owner electron37
    mole_run clean 'clean_user_rules'
    [[ "$output" == *"Obsidian cache · skipped while obsidian is running"* ]]
    [ -f "$HOME/.config/obsidian/Cache/entry/blob" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""
    mole_run clean 'clean_user_rules'
    [ ! -e "$HOME/.config/obsidian/Cache/entry" ]
    [ -f "$HOME/.config/obsidian/obsidian.json" ]
}

@test "a whitelisted rule is skipped and shown, by label or by path, and the Trash can be kept" {
    make_cache "$HOME/.cache/thumbnails"
    make_cache "$HOME/.cache/go-build"
    mkdir -p "$HOME/.local/share/Trash/files" "$HOME/.local/share/Trash/info"
    echo x > "$HOME/.local/share/Trash/files/old"
    mkdir -p "$HOME/.config/mole"
    printf '%s\n' "# keep" "Thumbnails" "~/.cache/go-build" "Trash" > "$HOME/.config/mole/whitelist"
    mole_run clean 'mole_whitelist_load; DRY_RUN=true; clean_user_rules; clean_trash'
    [[ "$output" == *"Thumbnails · would skip (whitelist)"* ]]
    [[ "$output" == *"Go build cache · would skip (whitelist)"* ]]
    [[ "$output" == *"Trash · would skip (whitelist)"* ]]
    mole_run clean 'mole_whitelist_load; clean_user_rules; clean_trash'
    [[ "$output" == *"Thumbnails · skipped (whitelist)"* ]]
    [ -f "$HOME/.cache/thumbnails/entry/blob" ]
    [ -f "$HOME/.cache/go-build/entry/blob" ]
    [ -f "$HOME/.local/share/Trash/files/old" ]
}

@test "a whitelisted path keeps single children: a folder under a rule, a Mac-style glob, a path inside" {
    make_cache "$HOME/.cache/thumbnails/large"
    make_cache "$HOME/.cache/thumbnails/normal"
    make_cache "$HOME/.npm/_cacache/index-v5"
    make_cache "$HOME/.npm/_cacache/content-v2"
    make_cache "$HOME/.cache/moletool/keep/inner"
    make_cache "$HOME/.cache/moletool/other"
    mkdir -p "$HOME/.config/mole"
    printf '%s\n' "~/.cache/thumbnails/large" "~/.npm/_cacache/*" "~/.cache/moletool/keep/inner" > "$HOME/.config/mole/whitelist"
    run_three='mole_whitelist_load
clean_rule "Thumbnails" "$HOME/.cache/thumbnails" "moletestowner"
clean_rule "npm cache" "$HOME/.npm/_cacache" "moletestowner"
clean_rule "Mole tool cache" "$HOME/.cache/moletool" "moletestowner"'
    mole_run clean "DRY_RUN=true; $run_three"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Thumbnails · "*"KB dry"* ]]
    [[ "$output" != *"Thumbnails · 2 items"* ]]
    [[ "$output" == *"npm cache · would skip (whitelist)"* ]]
    [[ "$output" == *"Mole tool cache · "*"KB dry"* ]]
    [[ "$output" != *"Mole tool cache · 2 items"* ]]
    mole_run clean "$run_three"
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache · skipped (whitelist)"* ]]
    [ -f "$HOME/.cache/thumbnails/large/entry/blob" ]
    [ ! -e "$HOME/.cache/thumbnails/normal" ]
    [ -f "$HOME/.npm/_cacache/index-v5/entry/blob" ]
    [ -f "$HOME/.npm/_cacache/content-v2/entry/blob" ]
    [ -f "$HOME/.cache/moletool/keep/inner/entry/blob" ]
    [ ! -e "$HOME/.cache/moletool/other" ]
}

@test "an unreadable whitelist stops clean before anything is removed" {
    make_cache "$HOME/.cache/thumbnails"
    mkdir -p "$HOME/.config/mole/whitelist"
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO" bash "$MOLE_TEST_REPO/bin/clean.sh" < /dev/null'
    [ "$status" -ne 0 ]
    [ -f "$HOME/.cache/thumbnails/entry/blob" ]
}

@test "flatpak unused runtimes are removed only when flatpak and a user installation exist" {
    mole_run clean 'DRY_RUN=true; clean_system'
    [[ "$output" != *"Flatpak"* ]]

    fake_command flatpak 'echo "$*" >> "'"$TEST_ROOT"'/flatpak.log"'
    mole_run clean 'clean_system'
    [ ! -e "$TEST_ROOT/flatpak.log" ]

    mkdir -p "$HOME/.local/share/flatpak/repo"
    mole_run clean 'clean_system'
    grep -qx -- "uninstall --user --unused --noninteractive" "$TEST_ROOT/flatpak.log"
    [ -z "$(grep -- "--system" "$TEST_ROOT/flatpak.log")" ]
}

@test "the system Flatpak installation is only reported: nothing runs sudo flatpak, the prompt omits it" {
    mkdir -p "$TEST_ROOT/sysflatpak/repo" "$HOME/.local/share/flatpak/repo"
    fake_command flatpak 'echo "$*" >> "'"$TEST_ROOT"'/flatpak.log"'
    fake_command sudo 'echo "$*" >> "'"$TEST_ROOT"'/sudo.log"; [[ "$1" == -* ]] && exit 0; exec "$@"'
    fake_command paccache 'exit 0'
    fake_command journalctl 'exit 0'
    mole_run clean 'SYSTEM_FLATPAK_DIR="'"$TEST_ROOT"'/sysflatpak"; SYSTEM_READY=true; clean_system; echo "label=[$(sudo_items_label)]"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unused Flatpak runtimes (system) · "*"sudo flatpak uninstall --system --unused"* ]]
    [[ "$output" != *"label=["*"Flatpak"* ]]
    [ -z "$(grep -- flatpak "$TEST_ROOT/sudo.log" 2> /dev/null)" ]
    [ -z "$(grep -- --system "$TEST_ROOT/flatpak.log")" ]
    grep -qx -- "uninstall --user --unused --noninteractive" "$TEST_ROOT/flatpak.log"
    mole_run clean 'SYSTEM_FLATPAK_DIR="'"$TEST_ROOT"'/sysflatpak"; DRY_RUN=true; clean_system'
    [[ "$output" == *"sudo flatpak uninstall --system --unused"* ]]
    [ -z "$(grep -- flatpak "$TEST_ROOT/sudo.log" 2> /dev/null)" ]
}

@test "container storage: podman is not asked before its storage exists, docker not without a socket" {
    fake_command podman 'echo "$*" >> "'"$TEST_ROOT"'/podman.log"; printf "Images\t200MB (50%%)\n"'
    fake_command docker 'echo "$*" >> "'"$TEST_ROOT"'/docker.log"; printf "Images\t300MB (50%%)\n"'
    mole_run clean 'unset DOCKER_HOST; XDG_RUNTIME_DIR="'"$TEST_ROOT"'/run"; report_container_storage'
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_ROOT/podman.log" ]
    [ ! -e "$HOME/.local/share/containers" ]
    [ ! -e "$TEST_ROOT/docker.log" ]
    mkdir -p "$HOME/.local/share/containers"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TEST_ROOT/d.sock"
    mole_run clean 'DOCKER_HOST="unix://'"$TEST_ROOT"'/d.sock"; report_container_storage'
    grep -q "system df" "$TEST_ROOT/podman.log"
    grep -q "system df" "$TEST_ROOT/docker.log"
    [[ "$output" == *"Podman reclaimable"* && "$output" == *"Docker reclaimable"* ]]
}

@test "old agent versions: the active one and the newest other stay" {
    v="$HOME/.local/share/claude/versions"
    mkdir -p "$v" "$HOME/.local/bin"
    for n in 1.0.0 1.1.0 1.2.0 1.3.0; do head -c 65536 /dev/zero > "$v/$n"; done
    touch -d '4 days ago' "$v/1.0.0"
    touch -d '3 days ago' "$v/1.1.0"
    touch -d '2 days ago' "$v/1.3.0"
    touch -d '1 days ago' "$v/1.2.0"
    ln -s "$v/1.3.0" "$HOME/.local/bin/claude"
    mole_run clean 'clean_user_rules'
    [ "$status" -eq 0 ]
    [ -f "$v/1.3.0" ]
    [ -f "$v/1.2.0" ]
    [ ! -e "$v/1.1.0" ]
    [ ! -e "$v/1.0.0" ]
}

@test "old agent versions: unreadable /proc selects nothing, a non-dumpable runner keeps its version" {
    v="$HOME/.local/share/claude/versions"
    mkdir -p "$v" "$HOME/.local/bin"
    for n in 1.0.0 1.1.0 1.2.0 1.3.0; do head -c 65536 /dev/zero > "$v/$n"; done
    touch -d '4 days ago' "$v/1.0.0"
    touch -d '3 days ago' "$v/1.1.0"
    touch -d '2 days ago' "$v/1.3.0"
    touch -d '1 days ago' "$v/1.2.0"
    ln -s "$v/1.3.0" "$HOME/.local/bin/claude"
    mole_run clean '_MOLE_PROC_ROOT="$HOME/none"; mole_select_old_versions "$HOME/.local/share/claude/versions" "$HOME/.local/bin/claude" | tr "\0" "\n"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    fake_proc "$TEST_ROOT/proc" 100 "$(id -u)" 1.1.0 -
    mole_run clean '_MOLE_PROC_ROOT="'"$TEST_ROOT"'/proc"; mole_select_old_versions "$HOME/.local/share/claude/versions" "$HOME/.local/bin/claude" | tr "\0" "\n"'
    [ "$status" -eq 0 ]
    [ "$output" = "$v/1.0.0" ]
}

@test "old agent versions are kept when the active link is missing" {
    v="$HOME/.local/share/claude/versions"
    mkdir -p "$v"
    for n in 1.0.0 1.1.0 1.2.0; do head -c 65536 /dev/zero > "$v/$n"; done
    mole_run clean 'clean_user_rules'
    [ -f "$v/1.0.0" ] && [ -f "$v/1.1.0" ] && [ -f "$v/1.2.0" ]
}

@test "editor extensions go only when .obsolete lists them" {
    e="$HOME/.vscode/extensions"
    make_cache "$e/ms-python.python-1.0.0"
    make_cache "$e/ms-python.python-2.0.0"
    printf '{"ms-python.python-1.0.0":true,"../escape":true}' > "$e/.obsolete"
    mole_run clean 'clean_user_rules'
    [ ! -e "$e/ms-python.python-1.0.0" ]
    [ -f "$e/ms-python.python-2.0.0/entry/blob" ]
}

@test "unknown large cache folders are listed with their size, never removed" {
    mkdir -p "$HOME/.cache/bigtool" "$HOME/.cache/huggingface"
    head -c 110000000 /dev/zero > "$HOME/.cache/bigtool/blob"
    head -c 1000 /dev/zero > "$HOME/.cache/huggingface/small"
    mole_run clean 'report_unknown_caches'
    [[ "$output" == *"Not cleaned"* ]]
    [[ "$output" == *"~/.cache/bigtool"*"MB"* ]]
    [[ "$output" != *"huggingface"* ]]
    [ -f "$HOME/.cache/bigtool/blob" ]
}
