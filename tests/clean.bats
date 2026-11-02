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
    make_cache "$HOME/.cache/moletool/wild/keep"
    make_cache "$HOME/.cache/moletool/wild2"
    mkdir -p "$HOME/.config/mole"
    printf '%s\n' "~/.cache/thumbnails/large" "~/.npm/_cacache/*" "~/.cache/moletool/keep/inner" "~/.cache/moletool/w*d/keep" > "$HOME/.config/mole/whitelist"
    run_three='mole_whitelist_load
clean_rule "Thumbnails" "$HOME/.cache/thumbnails" "moletestowner"
clean_rule "npm cache" "$HOME/.npm/_cacache" "moletestowner"
clean_rule "Mole tool cache" "$HOME/.cache/moletool" "moletestowner"'
    mole_run clean "DRY_RUN=true; $run_three"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Thumbnails · "*"KB dry"* ]]
    [[ "$output" != *"Thumbnails · 2 items"* ]]
    [[ "$output" == *"npm cache · would skip (whitelist)"* ]]
    [[ "$output" == *"Mole tool cache · 2 items, "*"KB dry"* ]]
    mole_run clean "$run_three"
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache · skipped (whitelist)"* ]]
    [ -f "$HOME/.cache/thumbnails/large/entry/blob" ]
    [ ! -e "$HOME/.cache/thumbnails/normal" ]
    [ -f "$HOME/.npm/_cacache/index-v5/entry/blob" ]
    [ -f "$HOME/.npm/_cacache/content-v2/entry/blob" ]
    [ -f "$HOME/.cache/moletool/keep/inner/entry/blob" ]
    [ ! -e "$HOME/.cache/moletool/other" ]
    # A wildcard in the child's own segment: ~/.cache/moletool/w*d/keep keeps wild.
    [ -f "$HOME/.cache/moletool/wild/keep/entry/blob" ]
    [ ! -e "$HOME/.cache/moletool/wild2" ]
}

@test "whitelist checks per rule and per child start no subshell; patterns are worked out at load" {
    mkdir -p "$HOME/.config/mole"
    printf '%s\n' "Thumbnails" "~/.cache/a/" "/opt/b" > "$HOME/.config/mole/whitelist"
    mole_run clean 'mole_whitelist_load; printf "%s\n" "${MOLE_WHITELIST_PATTERNS[@]}"; echo ---; declare -f mole_whitelisted mole_whitelist_keeps_child'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$HOME/.cache/a" ]
    [ "${lines[1]}" = "/opt/b" ]
    [ "${lines[2]}" = "---" ]
    body="${output#*---}"
    # $( ... ) or backticks would fork; $(( )) is arithmetic.
    [ -z "$(grep -E '\$\([^(]|`' <<< "$body")" ]
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
    fake_command flatpak 'echo "$*" >> "'"$TEST_ROOT"'/flatpak.log"; [[ "$1" == list ]] && echo org.gnome.Platform/x86_64/48; exit 0'
    fake_command sudo 'echo "$*" >> "'"$TEST_ROOT"'/sudo.log"; [[ "$1" == -* ]] && exit 0; exec "$@"'
    fake_command paccache 'exit 0'
    fake_command journalctl 'exit 0'
    mole_run clean 'SYSTEM_FLATPAK_DIR="'"$TEST_ROOT"'/sysflatpak"; SYSTEM_READY=true; clean_system; echo "label=[$(sudo_items_label)]"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unused Flatpak runtimes (system) · "*"sudo flatpak uninstall --system --unused"* ]]
    [[ "$output" != *"label=["*"Flatpak"* ]]
    [ -z "$(grep -- flatpak "$TEST_ROOT/sudo.log" 2> /dev/null)" ]
    [ -z "$(grep -- "uninstall.*--system" "$TEST_ROOT/flatpak.log")" ]
    grep -qx -- "uninstall --user --unused --noninteractive" "$TEST_ROOT/flatpak.log"
    mole_run clean 'SYSTEM_FLATPAK_DIR="'"$TEST_ROOT"'/sysflatpak"; DRY_RUN=true; clean_system'
    [[ "$output" == *"sudo flatpak uninstall --system --unused"* ]]
    [ -z "$(grep -- flatpak "$TEST_ROOT/sudo.log" 2> /dev/null)" ]
}

@test "container storage: podman is not asked before its storage exists, docker not without a socket" {
    fake_command podman 'echo "$*" >> "'"$TEST_ROOT"'/podman.log"; printf "Images\t200MB (50%%)\n"'
    fake_command docker 'echo "$*" >> "'"$TEST_ROOT"'/docker.log"; printf "Images\t300MB (50%%)\n"'
    mole_run clean 'unset DOCKER_HOST; MOLE_DOCKER_SYSTEM_SOCKETS="'"$TEST_ROOT"'/no.sock"; XDG_RUNTIME_DIR="'"$TEST_ROOT"'/run"; report_container_storage'
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
    # Docker Desktop's socket.
    rm -f "$TEST_ROOT/docker.log"
    mkdir -p "$HOME/.docker/desktop"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$HOME/.docker/desktop/docker.sock"
    mole_run clean 'unset DOCKER_HOST; MOLE_DOCKER_SYSTEM_SOCKETS="'"$TEST_ROOT"'/no.sock"; XDG_RUNTIME_DIR="'"$TEST_ROOT"'/run"; report_container_storage'
    grep -q "system df" "$TEST_ROOT/docker.log"
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
    mole_run clean '_MOLE_PROC_ROOT="$HOME/none"; clean_rule "Claude Code old versions" "$HOME/.local/share/claude/versions" "" "versions:$HOME/.local/bin/claude"'
    [[ "$output" == *"Claude Code old versions · skipped (process state unknown)"* ]]
    [ -f "$v/1.0.0" ] && [ -f "$v/1.1.0" ]
    fake_proc "$TEST_ROOT/proc" 100 "$(id -u)" 1.1.0 -
    mole_run clean '_MOLE_PROC_ROOT="'"$TEST_ROOT"'/proc"; mole_select_old_versions "$HOME/.local/share/claude/versions" "$HOME/.local/bin/claude" | tr "\0" "\n"'
    [ "$status" -eq 0 ]
    [ "$output" = "$v/1.0.0" ]
}

@test "folder-style agent versions: a hidden node or cursor-agent process keeps every version" {
    v="$HOME/.local/share/cursor-agent/versions"
    mkdir -p "$HOME/.local/bin"
    for n in 2025.1.1 2025.1.2 2025.1.3 2025.1.4; do make_cache "$v/$n"; done
    touch -d '4 days ago' "$v/2025.1.1"
    touch -d '3 days ago' "$v/2025.1.2"
    touch -d '2 days ago' "$v/2025.1.4"
    touch -d '1 days ago' "$v/2025.1.3"
    ln -s "$v/2025.1.4/cursor-agent" "$HOME/.local/bin/cursor-agent"
    touch "$v/2025.1.4/cursor-agent"
    rule='clean_rule "Cursor Agent old versions" "$HOME/.local/share/cursor-agent/versions" "" "versions:$HOME/.local/bin/cursor-agent"'
    for comm in node cursor-agent; do
        rm -rf "$TEST_ROOT/proc"
        fake_proc "$TEST_ROOT/proc" 100 "$(id -u)" "$comm" -
        mole_run clean '_MOLE_PROC_ROOT="'"$TEST_ROOT"'/proc"; '"$rule"
        [[ "$output" == *"Cursor Agent old versions · skipped (process state unknown)"* ]]
        [ -d "$v/2025.1.1" ] && [ -d "$v/2025.1.2" ]
    done
    # Another hidden process does not block.
    rm -rf "$TEST_ROOT/proc"
    fake_proc "$TEST_ROOT/proc" 100 "$(id -u)" keepassxc -
    mole_run clean '_MOLE_PROC_ROOT="'"$TEST_ROOT"'/proc"; '"$rule"
    [ ! -e "$v/2025.1.1" ] && [ ! -e "$v/2025.1.2" ]
    [ -d "$v/2025.1.3" ] && [ -d "$v/2025.1.4" ]
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

@test "the system Flatpak line stays quiet when the system installation has no runtime" {
    mkdir -p "$TEST_ROOT/sysflatpak/repo"
    fake_command flatpak 'exit 0'
    mole_run clean 'SYSTEM_FLATPAK_DIR="'"$TEST_ROOT"'/sysflatpak"; report_system_flatpak_unused; echo done'
    [ "$status" -eq 0 ]
    [[ "$output" != *"Unused Flatpak runtimes (system)"* ]]
}

# A btrfs root at $TEST_ROOT/sys that snapper snapshots, holding the package cache.
snapshotted_pkg_cache() {
    mkdir -p "$TEST_ROOT/sys/var/cache/pacman/pkg" "$TEST_ROOT/snapper/configs"
    printf '1 0 0:1 / / rw - ext4 /dev/vda1 rw\n2 1 0:2 / %s rw - %s /dev/vda2 rw\n' "$TEST_ROOT/sys" "$1" > "$TEST_ROOT/mountinfo"
    printf 'SUBVOLUME="%s"\n' "$TEST_ROOT/sys" > "$TEST_ROOT/snapper/configs/root"
    fake_command paccache 'echo "$*" >> "'"$TEST_ROOT"'/paccache.log"; echo "==> finished dry run: 3 candidates (disk space saved: 2.00 MiB)"'
    fake_command sudo '[[ "$1" == -* ]] && exit 0; exec "$@"'
}

pkg_cache_run() {
    mole_run clean '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/mountinfo"
        _MOLE_SNAPPER_CONFIGS="'"$TEST_ROOT"'/snapper/configs"; _MOLE_SNAPPER_SYSCONFIGS=()
        PACMAN_CACHE_DIR="'"$TEST_ROOT"'/sys/var/cache/pacman/pkg"; SYSTEM_READY=true; '"$1"'
        clean_system_sudo_items true false; echo "total=$TOTAL_KB items=$TOTAL_ITEMS"'
}

@test "package cache on a snapshotted subvolume: removed, shown as held, not counted as freed" {
    snapshotted_pkg_cache btrfs
    pkg_cache_run 'DRY_RUN=true;'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Package cache, older versions · 3 items, 2.1MB"*"(keeps 2, freed as snapshots rotate)"* ]]
    [[ "$output" == *"total=0 items=3"* ]]
    [ -z "$(grep -- '-rk2' "$TEST_ROOT/paccache.log")" ]
    pkg_cache_run ''
    [[ "$output" == *"(keeps 2, freed as snapshots rotate)"* ]]
    [[ "$output" == *"total=0 items=3"* ]]
    grep -qx -- '-rk2' "$TEST_ROOT/paccache.log"
    grep -q "paccache -rk2, 3 files" "$HOME/.local/state/mole/operations.log"
}

@test "package cache off snapshots, or when the probe cannot tell, counts as freed" {
    snapshotted_pkg_cache ext4
    pkg_cache_run 'DRY_RUN=true;'
    [[ "$output" != *"snapshots"* ]]
    [[ "$output" == *"(keeps 2)"* ]]
    [[ "$output" == *"total=2048 items=3"* ]]
    snapshotted_pkg_cache btrfs
    rm "$TEST_ROOT/mountinfo"
    pkg_cache_run 'DRY_RUN=true;'
    [[ "$output" != *"snapshots"* ]]
    [[ "$output" == *"total=2048 items=3"* ]]
}

# pgrep that never sees a node process, so a node the test machine happens to
# run cannot decide a test; every other question goes to the real pgrep.
pgrep_without_node() {
    local real
    real=$(command -v pgrep)
    fake_command pgrep 'for a in "$@"; do [[ "$a" == node ]] && exit 1; done; exec '"$real"' "$@"'
}

@test "Playwright, Cypress and sccache wait for their owners and go when idle" {
    pgrep_without_node
    make_cache "$HOME/.cache/ms-playwright/chromium-1140"
    make_cache "$HOME/.cache/Cypress/13.6.0"
    make_cache "$HOME/.cache/sccache/a"
    start_owner sccache
    # A browser Playwright started carries its folder on the command line.
    bash -c 'sleep 30; :' "$HOME/.cache/ms-playwright/chromium-1140/chrome-linux/chrome" &
    PW_PID=$!
    mole_run clean 'clean_user_rules'
    kill "$PW_PID"; wait "$PW_PID" 2> /dev/null || true
    [[ "$output" == *"sccache · skipped while sccache is running"* ]]
    [[ "$output" == *"Playwright browsers · skipped while"*"is running"* ]]
    [ -f "$HOME/.cache/sccache/a/entry/blob" ]
    [ -f "$HOME/.cache/ms-playwright/chromium-1140/entry/blob" ]
    [ ! -e "$HOME/.cache/Cypress/13.6.0" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""

    mkdir -p "$HOME/.config/mole"
    echo "~/.cache/sccache" > "$HOME/.config/mole/whitelist"
    mole_run clean 'mole_whitelist_load; clean_user_rules'
    [[ "$output" == *"sccache · skipped (whitelist)"* ]]
    [ -f "$HOME/.cache/sccache/a/entry/blob" ]
    [ ! -e "$HOME/.cache/ms-playwright/chromium-1140" ]
    [ -d "$HOME/.cache/ms-playwright" ]
}

@test "Steam: only shadercache children go, once, never through ~/.steam/steam or out of the root" {
    s="$HOME/.local/share/Steam/steamapps"
    make_cache "$s/shadercache/570"
    make_cache "$s/common/Game"
    make_cache "$s/compatdata/570"
    make_cache "$HOME/.local/share/Steam/userdata/1"
    make_cache "$HOME/.local/share/Steam/config"
    make_cache "$TEST_ROOT/outside"
    ln -s "$TEST_ROOT/outside" "$s/shadercache/999"
    mkdir -p "$HOME/.steam"
    ln -s "$HOME/.local/share/Steam" "$HOME/.steam/steam"
    make_cache "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache/730"
    mole_run clean 'mole_game_cache_rules | grep Steam'
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<< "$output")" -eq 2 ]
    [[ "$output" == *"|$s/shadercache|steam,steamwebhelper,fossilize_replay"* ]]
    [[ "$output" == *"|$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache|flatpak:com.valvesoftware.Steam"* ]]

    start_owner steamwebhelper
    fake_command flatpak '[[ "$1" == ps ]] && echo com.valvesoftware.Steam'
    mole_run clean 'clean_user_rules'
    [[ "$output" == *"Steam shader cache · skipped while"*"is running"* ]]
    [ -f "$s/shadercache/570/entry/blob" ]
    [ -f "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache/730/entry/blob" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""

    fake_command flatpak '[[ "$1" == ps ]] && echo org.other.App'
    mole_run clean 'clean_user_rules'
    [ "$(grep -c "Steam shader cache" <<< "$output")" -eq 1 ]
    [ ! -e "$s/shadercache/570" ]
    [ ! -e "$s/shadercache/999" ]
    [ ! -e "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache/730" ]
    [ -d "$s/shadercache" ]
    [ -f "$TEST_ROOT/outside/entry/blob" ]
    for d in "$s/common/Game" "$s/compatdata/570" "$HOME/.local/share/Steam/userdata/1" "$HOME/.local/share/Steam/config"; do
        [ -f "$d/entry/blob" ]
    done
}

@test "Steam: a Steam folder that is a link out of the home is no rule" {
    make_cache "$TEST_ROOT/elsewhere/steamapps/shadercache/570"
    mkdir -p "$HOME/.local/share"
    ln -s "$TEST_ROOT/elsewhere" "$HOME/.local/share/Steam"
    mole_run clean 'mole_game_cache_rules | grep -c Steam || true'
    [ "$output" = "0" ]
}

@test "WebKitGTK: only the HTTP and media caches go; CacheStorage and HSTS stay" {
    w="$HOME/.cache/webkitgtk"
    for d in WebKitCache MediaCache CacheStorage HSTS AlternativeServices; do make_cache "$w/$d"; done
    start_owner WebKitNetworkProcess
    mole_run clean 'clean_user_rules'
    [[ "$output" == *"WebKitGTK cache · skipped while WebKitNetworkProcess is running"* ]]
    [ -f "$w/WebKitCache/entry/blob" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""
    mole_run clean 'clean_user_rules'
    [ "$(grep -c "WebKitGTK cache" <<< "$output")" -eq 1 ]
    [ ! -e "$w/WebKitCache/entry" ]
    [ ! -e "$w/MediaCache/entry" ]
    for d in CacheStorage HSTS AlternativeServices; do [ -f "$w/$d/entry/blob" ]; done
}

@test "Thunderbird, Telegram, Heroic and GNOME Software: caches go, profiles, keys and settings stay" {
    tb="$HOME/.cache/thunderbird/ab12.default-release"
    make_cache "$tb/cache2"
    make_cache "$tb/startupCache"
    make_cache "$HOME/.thunderbird/ab12.default-release/ImapMail"
    tg="$HOME/.local/share/TelegramDesktop/tdata"
    make_cache "$tg/user_data/cache/0"
    make_cache "$tg/user_data/media_cache/0"
    make_cache "$tg/user_data#2/cache/0"
    make_cache "$tg/user_data/settings"
    make_cache "$tg/D877F783D5D3EF8C"
    echo key > "$tg/key_datas"
    h="$HOME/.config/heroic"
    make_cache "$h/Cache"
    make_cache "$h/GPUCache"
    make_cache "$h/store_cache"
    echo '{}' > "$h/config.json"
    make_cache "$HOME/.cache/gnome-software/icons"

    start_owner telegram-desktop
    TG_PID=$OWNER_PID
    start_owner heroic
    mole_run clean 'clean_user_rules'
    kill "$TG_PID"; wait "$TG_PID" 2> /dev/null || true
    [[ "$output" == *"Telegram cache · skipped while telegram-desktop is running"* ]]
    [[ "$output" == *"Heroic cache · skipped while heroic is running"* ]]
    [ -f "$tg/user_data/cache/0/entry/blob" ]
    [ -f "$h/Cache/entry/blob" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""

    mole_run clean 'clean_user_rules'
    [ ! -e "$tb/cache2/entry" ]
    [ ! -e "$tg/user_data/cache/0" ]
    [ ! -e "$tg/user_data/media_cache/0" ]
    [ ! -e "$tg/user_data#2/cache/0" ]
    [ ! -e "$h/Cache/entry" ]
    [ ! -e "$h/GPUCache/entry" ]
    [ ! -e "$HOME/.cache/gnome-software/icons" ]
    for d in "$tb/startupCache" "$HOME/.thunderbird/ab12.default-release/ImapMail" "$tg/user_data/settings" "$tg/D877F783D5D3EF8C" "$h/store_cache"; do
        [ -f "$d/entry/blob" ]
    done
    [ -f "$tg/key_datas" ]
    [ -f "$h/config.json" ]
}

@test "Lutris and Wine: shader and installer caches and .msi downloads go, sign-in tokens stay" {
    l="$HOME/.cache/lutris"
    make_cache "$l/shaders/wine"
    make_cache "$l/installer/some-game"
    make_cache "$l/gogdl"
    echo token > "$l/.gog.token"
    echo token > "$l/gogdl-auth.json"
    mkdir -p "$HOME/.cache/wine"
    head -c 65536 /dev/zero > "$HOME/.cache/wine/wine-gecko-2.47.4-x86_64.msi"
    make_cache "$HOME/.cache/wine/other"
    start_owner wineserver
    mole_run clean 'clean_user_rules'
    [[ "$output" == *"Lutris cache · skipped while"*"is running"* ]]
    [[ "$output" == *"Wine downloads · skipped while"*"is running"* ]]
    [ -f "$l/shaders/wine/entry/blob" ]
    [ -f "$HOME/.cache/wine/wine-gecko-2.47.4-x86_64.msi" ]
    kill "$OWNER_PID"; wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""

    mole_run clean 'clean_user_rules'
    [ "$(grep -c "Lutris cache" <<< "$output")" -eq 1 ]
    [ ! -e "$l/shaders/wine" ]
    [ ! -e "$l/installer/some-game" ]
    [ ! -e "$HOME/.cache/wine/wine-gecko-2.47.4-x86_64.msi" ]
    [ -f "$l/.gog.token" ]
    [ -f "$l/gogdl-auth.json" ]
    [ -f "$l/gogdl/entry/blob" ]
    [ -f "$HOME/.cache/wine/other/entry/blob" ]
}

@test "snap caches: common and revision .cache become rules, never a linked revision, another folder or a linked .cache" {
    f="$HOME/snap/firefox"
    make_cache "$f/common/.cache/mozilla"
    make_cache "$f/1234/.cache/fontconfig"
    make_cache "$f/1234/.mozilla"
    ln -s 1234 "$f/current"
    ln -s 1234 "$f/9999"
    make_cache "$f/notarevision/.cache/x"
    mkdir -p "$f/1235"
    ln -s ../common/.cache "$f/1235/.cache"
    make_cache "$HOME/snap/Bad_Name/common/.cache/x"
    mole_run clean 'mole_snap_cache_rules'
    [ "$status" -eq 0 ]
    [ "$output" = "Snap apps|firefox snap cache|$f/1234/.cache|snap:firefox
Snap apps|firefox snap cache|$f/common/.cache|snap:firefox" ]
}

# fake_snap_proc <proc root> <pid> <cgroup line or -> <exe or ->
fake_snap_proc() {
    fake_proc "$1" "$2" "$(id -u)" app "$4"
    [[ "$3" == - ]] || printf '%s\n' "$3" > "$1/$2/cgroup"
}

@test "snap owner: a process in the snap's cgroup or running from /snap/<name>/ blocks; an unreadable cgroup cannot tell" {
    p="$TEST_ROOT/proc"
    scope="0::/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"
    fake_snap_proc "$p" 100 "$scope/snap.firefox.firefox-1b2c.scope" -
    mole_run clean '_MOLE_PROC_ROOT="'"$p"'"; rc=0; mole_snap_running firefox || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=0" ]
    mole_run clean '_MOLE_PROC_ROOT="'"$p"'"; rc=0; mole_snap_running fire || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]

    rm -rf "$p"
    fake_snap_proc "$p" 100 "$scope/app-foot.scope" /snap/firefox/1234/usr/lib/firefox/firefox
    mole_run clean '_MOLE_PROC_ROOT="'"$p"'"; rc=0; mole_snap_running firefox || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=0" ]

    rm -rf "$p"
    fake_snap_proc "$p" 100 "$scope/app-foot.scope" /usr/bin/foot
    fake_snap_proc "$p" 101 - -
    mole_run clean '_MOLE_PROC_ROOT="'"$p"'"; rc=0; mole_snap_running firefox || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=2" ]
    mole_run clean '_MOLE_PROC_ROOT="'"$TEST_ROOT"'/noproc"; rc=0; mole_snap_running firefox || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=2" ]
}

@test "snap caches wait for the snap and go when it is not running" {
    f="$HOME/snap/firefox"
    make_cache "$f/common/.cache/mozilla"
    make_cache "$f/1234/.mozilla"
    p="$TEST_ROOT/proc"
    fake_snap_proc "$p" 100 "0::/user.slice/app.slice/snap.firefox.firefox-1b2c.scope" -
    mole_run clean '_MOLE_PROC_ROOT="'"$p"'"; clean_user_rules'
    [[ "$output" == *"firefox snap cache · skipped while firefox is running"* ]]
    [ -f "$f/common/.cache/mozilla/entry/blob" ]

    printf '%s\n' "0::/user.slice/app.slice/app-foot.scope" > "$p/100/cgroup"
    mole_run clean '_MOLE_PROC_ROOT="'"$p"'"; clean_user_rules'
    [[ "$output" == *"firefox snap cache"* ]]
    [ ! -e "$f/common/.cache/mozilla" ]
    [ -d "$f/common/.cache" ]
    [ -f "$f/1234/.mozilla/entry/blob" ]
}
