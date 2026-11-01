#!/bin/bash
# Mole CLI (Linux) - Clean's allowlist.
#
# One rule per line: section|label|root|owners|selector
#   root      a cache directory; children are removed, never the root itself
#   owners    comma-separated owners; while any runs, the rule is skipped, and
#             a probe that cannot tell skips it too. A plain name is an exact
#             process name (pgrep -x); "cmd:<ERE>" matches the full command
#             line (pgrep -f), for runtimes whose process is only `java`;
#             "flatpak:<app id>" asks flatpak whether that sandboxed app runs.
#   selector  empty (every child), or tool:uv (ask uv itself, never rm)
# Consecutive rules with the same label are reported as one line.
# A directory not named here is never selected. Profiles, config, model stores
# (~/.ollama, ~/.cache/huggingface, ~/.cache/lm-studio), package databases and
# downloaded toolchains are not caches and have no rule.
#
# Paths follow Mole CLI (macOS)'s developer list mapped to where each tool
# keeps its cache on Linux, plus BleachBit's per-app Flatpak cache (each app's
# own ~/.var/app/<id>/cache, never the app's data).

mole_clean_rules() {
    local c="$MOLE_CACHE_HOME"
    cat << RULES
Browsers|Chromium cache|$c/chromium|chromium
Browsers|Google Chrome cache|$c/google-chrome|chrome
Browsers|Brave cache|$c/BraveSoftware|brave
Browsers|Microsoft Edge cache|$c/microsoft-edge|msedge
Browsers|Vivaldi cache|$c/vivaldi|vivaldi-bin
Browsers|Firefox cache|$c/mozilla/firefox|firefox
Browsers|Zen cache|$c/zen|zen,zen-bin
User caches|Thumbnails|$c/thumbnails|
User caches|Mesa shader cache|$c/mesa_shader_cache|
User caches|Mesa shader cache (DB)|$c/mesa_shader_cache_db|
User caches|NVIDIA shader cache|$c/nvidia|
Developer tools|npm cache|$HOME/.npm/_cacache|npm,node
Developer tools|Yarn cache|$c/yarn|yarn,node
Developer tools|pnpm metadata cache|$c/pnpm|pnpm,node
Developer tools|Bun install cache|$HOME/.bun/install/cache|bun
RULES
    # DENO_DIR also holds location_data (localStorage, KV) and downloaded
    # runtimes, so only its remote-import, npm and compiled-output caches go
    # (Mac keeps the whole root out of its user-cache sweep).
    local dir
    for dir in deps remote gen npm registries; do
        printf 'Developer tools|Deno cache|%s|deno\n' "$c/deno/$dir"
    done
    cat << RULES
Developer tools|node-gyp headers|$c/node-gyp|node-gyp,node
Developer tools|Electron downloads|$c/electron|
Developer tools|ESLint cache|$c/eslint|node
Developer tools|Prettier cache|$c/prettier|node
Developer tools|Vite cache|$c/vite|node
Developer tools|webpack cache|$c/webpack|node
Developer tools|TypeScript cache|$c/typescript|tsserver,node
Developer tools|pip cache|$c/pip|pip,pip3,python,python3
Developer tools|uv cache|$c/uv|uv,uvx|tool:uv
Developer tools|Poetry cache|$c/pypoetry/cache|poetry
Developer tools|Poetry artifacts|$c/pypoetry/artifacts|poetry
Developer tools|pre-commit cache|$c/pre-commit|pre-commit
Developer tools|Ruff cache|$c/ruff|ruff
Developer tools|mypy cache|$c/mypy|mypy,dmypy
Developer tools|Go build cache|$c/go-build|go,gopls
Developer tools|rustup downloads|$HOME/.rustup/downloads|rustup,cargo
Developer tools|Zig cache|$c/zig|zig,zls
Developer tools|Composer cache|$c/composer|composer,php
Developer tools|Bundler cache|$HOME/.bundle/cache|bundle,ruby
Developer tools|Terraform plugin cache|$c/terraform|terraform
Developer tools|kubectl cache|$HOME/.kube/cache|kubectl,k9s
Developer tools|Android build cache|$HOME/.android/build-cache|java,studio
Developer tools|Android cache|$HOME/.android/cache|java,studio
Developer tools|mise download cache|$c/mise|mise
RULES
    local user
    user=$(id -un 2> /dev/null) || user="${USER:-}"
    # Bazel output bases hold read-only trees and live build state, so only
    # its repository download cache goes (plain files, fetched again).
    [[ -n "$user" ]] && printf 'Developer tools|Bazel repository cache|%s|bazel,bazelisk,java\n' "$c/bazel/_bazel_$user/cache/repos"
    # JetBrains IDEs run as their launcher (idea, pycharm, ...) or, started
    # from a script, as JetBrains Runtime java; the main class names them.
    mole_jetbrains_log_rules 'idea,pycharm,webstorm,goland,clion,rustrover,rider,phpstorm,rubymine,datagrip,dataspell,aqua,fleet,studio,cmd:com[.]intellij[.]idea[.]Main'
    cat << RULES
Package builds|yay build cache|$c/yay|yay,makepkg,pacman
Package builds|paru build cache|$c/paru|paru,makepkg,pacman
RULES
    mole_flatpak_cache_rules
}

# On Linux ~/.cache/JetBrains/<Product><version> is the IDE's system folder:
# indexes, LocalHistory (not recoverable) and logs. Only log/ goes, like the
# Mac's JetBrains IDE logs; the Mac keeps its JetBrains caches whitelisted.
mole_jetbrains_log_rules() {
    local owners="$1" dir
    for dir in "$MOLE_CACHE_HOME"/JetBrains/*/log "$MOLE_CACHE_HOME"/Google/AndroidStudio*/log; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        mole_rule_path_ok "$dir" || continue
        printf 'Developer tools|JetBrains IDE logs|%s|%s\n' "$dir" "$owners"
    done
}

# One rule per Flatpak app that has a cache folder in its sandbox home.
mole_flatpak_cache_rules() {
    local base="$HOME/.var/app" dir id
    [[ -d "$base" && ! -L "$base" ]] || return 0
    for dir in "$base"/*/cache; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        id="${dir%/cache}"
        id="${id##*/}"
        [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
        printf 'Flatpak apps|%s cache|%s|flatpak:%s\n' "$id" "$dir" "$id"
    done
}

# A path is usable as a rule field when it cannot break the line format.
mole_rule_path_ok() {
    [[ "$1" != *"|"* && "$1" != *$'\n'* ]]
}

# Children of root that a rule selects, NUL-separated.
mole_rule_children() {
    local root="$1" selector="${2:-}"
    case "$selector" in
        "") find "$root" -mindepth 1 -maxdepth 1 -print0 2> /dev/null ;;
        *) return 0 ;;
    esac
}
