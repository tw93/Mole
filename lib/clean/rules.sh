#!/bin/bash
# Mole CLI (Linux) - Clean's allowlist.
#
# One rule per line: section|label|root|owners
#   root    a cache directory; its children are removed, never the root itself
#   owners  comma-separated process names (exact comm); while any runs, the
#           rule is skipped. "flatpak:<app id>" asks flatpak whether that
#           sandboxed app runs instead.
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
Developer tools|Deno cache|$c/deno|deno
Developer tools|node-gyp headers|$c/node-gyp|node-gyp,node
Developer tools|Electron downloads|$c/electron|
Developer tools|ESLint cache|$c/eslint|node
Developer tools|Prettier cache|$c/prettier|node
Developer tools|Vite cache|$c/vite|node
Developer tools|webpack cache|$c/webpack|node
Developer tools|TypeScript cache|$c/typescript|tsserver,node
Developer tools|pip cache|$c/pip|pip,pip3,python,python3
Developer tools|uv cache|$c/uv|uv,uvx
Developer tools|Poetry cache|$c/pypoetry/cache|poetry
Developer tools|Poetry artifacts|$c/pypoetry/artifacts|poetry
Developer tools|pre-commit cache|$c/pre-commit|pre-commit
Developer tools|Ruff cache|$c/ruff|ruff
Developer tools|mypy cache|$c/mypy|mypy,dmypy
Developer tools|Go build cache|$c/go-build|go,gopls
Developer tools|rustup downloads|$HOME/.rustup/downloads|rustup,cargo
Developer tools|Zig cache|$c/zig|zig,zls
Developer tools|Bazel cache|$c/bazel|bazel,bazelisk,java
Developer tools|Composer cache|$c/composer|composer,php
Developer tools|Bundler cache|$HOME/.bundle/cache|bundle,ruby
Developer tools|Terraform plugin cache|$c/terraform|terraform
Developer tools|kubectl cache|$HOME/.kube/cache|kubectl,k9s
Developer tools|Android build cache|$HOME/.android/build-cache|java,studio
Developer tools|Android cache|$HOME/.android/cache|java,studio
Developer tools|mise download cache|$c/mise|mise
Developer tools|JetBrains caches|$c/JetBrains|idea,goland,pycharm,webstorm,clion,rustrover,rider,phpstorm
Package builds|yay build cache|$c/yay|yay,makepkg,pacman
Package builds|paru build cache|$c/paru|paru,makepkg,pacman
RULES
    mole_flatpak_cache_rules
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
