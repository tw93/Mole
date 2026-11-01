#!/bin/bash
# Mole CLI (Linux) - Clean's allowlist.
#
# One rule per line: section|label|root|owners
#   root    a cache directory; its children are removed, never the root itself
#   owners  comma-separated process names (exact comm); while any runs, the
#           rule is skipped
# A directory not named here is never selected. Profiles, config, model stores
# and package databases are not caches and have no rule.

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
Developer tools|pip cache|$c/pip|pip,pip3,python,python3
Developer tools|uv cache|$c/uv|uv,uvx
Developer tools|Go build cache|$c/go-build|go,gopls
Developer tools|mise download cache|$c/mise|mise
Developer tools|TypeScript cache|$c/typescript|tsserver,node
Developer tools|JetBrains caches|$c/JetBrains|idea,goland,pycharm,webstorm,clion,rustrover,rider,phpstorm
Package builds|yay build cache|$c/yay|yay,makepkg,pacman
Package builds|paru build cache|$c/paru|paru,makepkg,pacman
RULES
}
