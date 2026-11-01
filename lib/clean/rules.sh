#!/bin/bash
# Mole CLI (Linux) - Clean's allowlist.
#
# One rule per line: section|label|root|owners|selector
#   root      a cache directory; children are removed, never the root itself
#   owners    comma-separated owners; while any runs, the rule is skipped, and
#             a probe that cannot tell skips it too. A plain name is an exact
#             process name (pgrep -x, so `electron[0-9]*` covers versioned
#             system Electron); "cmd:<ERE>" matches the full command line
#             (pgrep -f), for runtimes whose process is only `java`;
#             "flatpak:<app id>" asks flatpak whether that sandboxed app runs.
#   selector  which children go (default: all of them):
#             versions:<link>  keep the version <link> points at and the
#                              newest other one; nothing when <link> is not a
#                              link into root
#             obsolete         only folders an editor's .obsolete file lists
#             suffix:<.ext>    only regular files ending in <.ext>
#             tool:uv          ask uv itself (uv cache prune), never rm
# Consecutive rules with the same label are reported as one line.
# A directory not named here is never selected. Profiles, config, model stores
# (~/.ollama, ~/.cache/huggingface, ~/.cache/lm-studio), package databases and
# downloaded toolchains are not caches and have no rule.
#
# Paths follow Mole CLI (macOS)'s lists (lib/clean/user.sh browsers,
# lib/clean/app_caches.sh editors and chat apps, lib/clean/dev.sh developer
# tools) mapped to where each tool keeps its cache on Linux, plus BleachBit's
# per-app Flatpak cache (each app's own ~/.var/app/<id>/cache, never its data).

# Owners of the Electron apps Arch packages against the system electron: their
# process is `electron` or `electron37`, not the app's name.
readonly MOLE_SYSTEM_ELECTRON='electron[0-9]*'

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
RULES
    mole_browser_profile_rules
    cat << RULES
User caches|Thumbnails|$c/thumbnails|
User caches|Mesa shader cache|$c/mesa_shader_cache|
User caches|Mesa shader cache (DB)|$c/mesa_shader_cache_db|
User caches|NVIDIA shader cache|$c/nvidia|
RULES
    mole_electron_app_rules
    mole_developer_rules
    cat << RULES
Package builds|yay build cache|$c/yay|yay,makepkg,pacman
Package builds|paru build cache|$c/paru|paru,makepkg,pacman
RULES
    mole_flatpak_cache_rules
}

# A path is usable as a rule field when it cannot break the line format.
mole_rule_path_ok() {
    [[ "$1" != *"|"* && "$1" != *$'\n'* ]]
}

# Chromium-family profile caches (Mac: lib/clean/user.sh clean_browsers and
# _clean_chrome_profile_caches_guarded). GPU, shader and code caches, the
# component updater's download cache, on-device model stores Chrome downloads
# again on demand, and crash reports already sent. Never Cookies, History,
# Sessions, Local or Session Storage, IndexedDB, Service Worker, Preferences.
mole_browser_profile_rules() {
    local g="$MOLE_CONFIG_HOME" spec dir label owners profile leaf
    local -a browser_leaves=(
        "ShaderCache" "GrShaderCache" "GraphiteDawnCache" "GPUPersistentCache"
        "component_crx_cache" "OptGuideOnDeviceModel" "OptGuideOnDeviceClassifierModel"
        "optimization_guide_model_store" "Crashpad/completed" "Crash Reports/completed"
    )
    local -a profile_leaves=(
        "GPUCache" "Code Cache" "DawnCache" "DawnGraphiteCache" "DawnWebGPUCache"
        "GrShaderCache" "GraphiteDawnCache"
    )
    for spec in \
        "chromium|Chromium|chromium" \
        "google-chrome|Google Chrome|chrome" \
        "google-chrome-beta|Google Chrome Beta|chrome" \
        "google-chrome-unstable|Google Chrome Dev|chrome" \
        "BraveSoftware/Brave-Browser|Brave|brave" \
        "BraveSoftware/Brave-Browser-Beta|Brave Beta|brave" \
        "BraveSoftware/Brave-Browser-Nightly|Brave Nightly|brave" \
        "microsoft-edge|Microsoft Edge|msedge" \
        "microsoft-edge-beta|Microsoft Edge Beta|msedge" \
        "microsoft-edge-dev|Microsoft Edge Dev|msedge" \
        "vivaldi|Vivaldi|vivaldi-bin"; do
        IFS='|' read -r dir label owners <<< "$spec"
        dir="$g/$dir"
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        for leaf in "${browser_leaves[@]}"; do
            [[ -d "$dir/$leaf" && ! -L "$dir/$leaf" ]] || continue
            printf 'Browsers|%s profile caches|%s|%s|\n' "$label" "$dir/$leaf" "$owners"
        done
        # A profile is a folder holding Chromium's Preferences file: Default,
        # "Profile 1", "Guest Profile", "System Profile".
        for profile in "$dir"/*/; do
            profile="${profile%/}"
            [[ -f "$profile/Preferences" && ! -L "$profile" ]] || continue
            mole_rule_path_ok "$profile" || continue
            for leaf in "${profile_leaves[@]}"; do
                [[ -d "$profile/$leaf" && ! -L "$profile/$leaf" ]] || continue
                printf 'Browsers|%s profile caches|%s|%s|\n' "$label" "$profile/$leaf" "$owners"
            done
        done
    done
}

# Electron apps' Chromium caches under ~/.config/<App>/ (Mac:
# lib/clean/app_caches.sh clean_code_editors, clean_communication_apps).
# Only Cache, Code Cache, GPUCache and Dawn caches, plus the editors' own
# CachedData, downloaded VSIXs and logs. Never User/, workspaceStorage,
# globalStorage, IndexedDB, Local Storage or the apps' databases. Spotify is
# left out like on the Mac, since its cache can hold offline music.
mole_electron_app_rules() {
    local g="$MOLE_CONFIG_HOME" e="$MOLE_SYSTEM_ELECTRON" spec dir label owners kind leaf
    local -a app_leaves=("Cache" "Code Cache" "GPUCache" "DawnCache" "DawnGraphiteCache" "DawnWebGPUCache" "Crashpad/completed")
    local -a editor_leaves=("CachedData" "CachedExtensionVSIXs" "logs")
    for spec in \
        "Code|VS Code|code,$e|editor" \
        "Code - OSS|Code - OSS|code-oss,$e|editor" \
        "Code - Insiders|VS Code Insiders|code-insiders|editor" \
        "VSCodium|VSCodium|codium,vscodium,$e|editor" \
        "Cursor|Cursor|cursor|editor" \
        "obsidian|Obsidian|obsidian,$e|app" \
        "discord|Discord|Discord,discord|app" \
        "Slack|Slack|slack|app" \
        "Signal|Signal|signal-desktop,$e|app" \
        "Typora|Typora|Typora,typora|app"; do
        IFS='|' read -r dir label owners kind <<< "$spec"
        dir="$g/$dir"
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        for leaf in "${app_leaves[@]}"; do
            [[ -d "$dir/$leaf" && ! -L "$dir/$leaf" ]] || continue
            printf 'Apps|%s cache|%s|%s|\n' "$label" "$dir/$leaf" "$owners"
        done
        [[ "$kind" == editor ]] || continue
        for leaf in "${editor_leaves[@]}"; do
            [[ -d "$dir/$leaf" && ! -L "$dir/$leaf" ]] || continue
            printf 'Apps|%s cache|%s|%s|\n' "$label" "$dir/$leaf" "$owners"
        done
    done
    # Extension folders an editor marked obsolete after an update (Mac:
    # clean_editor_obsolete_extensions).
    for spec in \
        "$HOME/.vscode/extensions|VS Code|code,$e" \
        "$HOME/.vscode-insiders/extensions|VS Code Insiders|code-insiders" \
        "$HOME/.vscode-oss/extensions|VSCodium|codium,vscodium,code-oss,$e" \
        "$HOME/.cursor/extensions|Cursor|cursor"; do
        IFS='|' read -r dir label owners <<< "$spec"
        [[ -f "$dir/.obsolete" && -d "$dir" && ! -L "$dir" ]] || continue
        printf 'Apps|Obsolete %s extensions|%s|%s|obsolete\n' "$label" "$dir" "$owners"
    done
}

mole_developer_rules() {
    local c="$MOLE_CACHE_HOME" user dir
    user=$(id -un 2> /dev/null) || user="${USER:-}"
    local cargo="$HOME/.cargo" corepack="$c/node/corepack"
    # Only a CARGO_HOME / COREPACK_HOME inside the home is followed; anything
    # else keeps the default, so an odd variable cannot point a rule elsewhere.
    [[ "${CARGO_HOME:-}" == "$HOME/"* ]] && cargo="${CARGO_HOME%/}"
    [[ "${COREPACK_HOME:-}" == "$HOME/"* ]] && corepack="${COREPACK_HOME%/}"
    local rust='cargo,rustc,rustdoc,clippy-driver,cargo-nextest'
    local gradle='gradle,gradlew,cmd:org[.]gradle[.]launcher[.]daemon,cmd:GradleDaemon'
    # JetBrains IDEs run as their launcher (idea, pycharm, ...) or, started
    # from a script, as JetBrains Runtime java; the main class names them.
    local jetbrains='idea,pycharm,webstorm,goland,clion,rustrover,rider,phpstorm,rubymine,datagrip,dataspell,aqua,fleet,studio,cmd:com[.]intellij[.]idea[.]Main'
    cat << RULES
Developer tools|npm cache|$HOME/.npm/_cacache|npm,node
Developer tools|Yarn cache|$c/yarn|yarn,node
Developer tools|pnpm metadata cache|$c/pnpm|pnpm,node
Developer tools|Corepack cache|$corepack|corepack,node,pnpm,yarn
Developer tools|Bun install cache|$HOME/.bun/install/cache|bun,bunx
RULES
    # DENO_DIR also holds location_data (localStorage, KV) and downloaded
    # runtimes, so only its remote-import, npm and compiled-output caches go
    # (Mac keeps the whole root out of its user-cache sweep).
    for dir in deps remote gen npm registries; do
        printf 'Developer tools|Deno cache|%s|deno\n' "$c/deno/$dir"
    done
    cat << RULES
Developer tools|node-gyp headers|$c/node-gyp|node-gyp,node
Developer tools|node-gyp build cache|$HOME/.node-gyp|node-gyp,node
Developer tools|Electron downloads|$c/electron|
Developer tools|ESLint cache|$c/eslint|node
Developer tools|Prettier cache|$c/prettier|node
Developer tools|Vite cache|$c/vite|node
Developer tools|webpack cache|$c/webpack|node
Developer tools|Turbo cache|$HOME/.turbo/cache|turbo,node
Developer tools|Parcel cache|$HOME/.parcel-cache|parcel,node
Developer tools|TypeScript cache|$c/typescript|tsserver,node
Developer tools|Prisma engines cache|$c/prisma|prisma,node
Developer tools|Puppeteer browsers|$c/puppeteer|node,chrome,chrome-headless-shell
Developer tools|pip cache|$c/pip|pip,pip3,python,python3
Developer tools|uv cache|$c/uv|uv,uvx|tool:uv
Developer tools|Poetry cache|$c/pypoetry/cache|poetry
Developer tools|Poetry artifacts|$c/pypoetry/artifacts|poetry
Developer tools|pyenv cache|$HOME/.pyenv/cache|pyenv,python-build
Developer tools|pre-commit cache|$c/pre-commit|pre-commit
Developer tools|Ruff cache|$c/ruff|ruff
Developer tools|mypy cache|$c/mypy|mypy,dmypy
Developer tools|Go build cache|$c/go-build|go,gopls
Developer tools|Cargo download cache|$cargo/registry/cache|$rust
Developer tools|rustup downloads|$HOME/.rustup/downloads|rustup,cargo
Developer tools|Zig cache|$c/zig|zig,zls
Developer tools|Composer cache|$c/composer|composer,php
Developer tools|Bundler cache|$HOME/.bundle/cache|bundle,ruby
Developer tools|RubyGems spec cache|$HOME/.gem/specs|gem,ruby,bundle
Developer tools|CPAN build files|$HOME/.cpan/build|cpan,cpanm,perl
Developer tools|Hex cache|$HOME/.hex/cache|mix,elixir,erl,beam.smp
Developer tools|opam download cache|$HOME/.opam/download-cache|opam
Developer tools|Gradle notifications|$HOME/.gradle/notifications|$gradle
Developer tools|Terraform plugin cache|$c/terraform|terraform
Developer tools|kubectl cache|$HOME/.kube/cache|kubectl,k9s
Developer tools|Docker Buildx cache|$HOME/.docker/buildx/cache|docker,docker-buildx,buildx,buildkitd
Developer tools|AWS CLI cache|$HOME/.aws/cli/cache|aws
Developer tools|Google Cloud logs|$MOLE_CONFIG_HOME/gcloud/logs|gcloud,cmd:gcloud[.]py
Developer tools|Azure CLI logs|$HOME/.azure/logs|az,cmd:azure[.]cli
Developer tools|GitLab Runner cache|$c/gitlab-runner|gitlab-runner
Developer tools|GitHub Actions cache|$HOME/.github/cache|act
Developer tools|CircleCI cache|$HOME/.circleci/cache|circleci
Developer tools|SonarQube cache|$HOME/.sonar/cache|sonar-scanner,cmd:org[.]sonar
Developer tools|OpenCode cache|$c/opencode|opencode
Developer tools|Oh My Zsh cache|$HOME/.oh-my-zsh/cache|
Developer tools|Android build cache|$HOME/.android/build-cache|studio,$gradle
Developer tools|Android cache|$HOME/.android/cache|studio,$gradle
Developer tools|mise download cache|$c/mise|mise
RULES
    # Bazel output bases hold read-only trees and live build state, so only
    # its repository download cache goes (plain files, fetched again).
    [[ -n "$user" ]] && printf 'Developer tools|Bazel repository cache|%s|bazel,bazelisk,java\n' "$c/bazel/_bazel_$user/cache/repos"
    # RubyGems keeps each downloaded .gem beside the unpacked gem; only the
    # .gem files go (Mac: ~/.gem/ruby/*/cache/*.gem).
    for dir in "$HOME"/.gem/ruby/*/cache; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        mole_rule_path_ok "$dir" || continue
        printf 'Developer tools|RubyGems package cache|%s|gem,ruby,bundle|suffix:.gem\n' "$dir"
    done
    mole_jetbrains_log_rules "$jetbrains"
    # Coding agents keep every self-update; the running one and the newest
    # other stay (Mac: clean_dev_ai_agents).
    printf 'Developer tools|Claude Code old versions|%s||versions:%s\n' \
        "$MOLE_DATA_HOME/claude/versions" "$HOME/.local/bin/claude"
    printf 'Developer tools|Cursor Agent old versions|%s||versions:%s\n' \
        "$MOLE_DATA_HOME/cursor-agent/versions" "$HOME/.local/bin/cursor-agent"
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

# Children of root that a rule selects, NUL-separated.
mole_rule_children() {
    local root="$1" selector="${2:-}"
    case "$selector" in
        "") find "$root" -mindepth 1 -maxdepth 1 -print0 2> /dev/null ;;
        versions:*) mole_select_old_versions "$root" "${selector#versions:}" ;;
        obsolete) mole_select_obsolete_extensions "$root" ;;
        suffix:*) find "$root" -mindepth 1 -maxdepth 1 -type f -name "*${selector#suffix:}" -print0 2> /dev/null ;;
        *) return 0 ;;
    esac
}

# Executables the user's processes run, one per line; a process whose
# executable cannot be read (non-dumpable) prints comm:<its comm> instead.
# Returns 2 when /proc cannot be read at all.
mole_running_exes() {
    local pid exe comm
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 2
    for pid in "$_MOLE_PROC_ROOT"/[0-9]*; do
        mole_pid_mine "$pid" || continue
        if exe=$(readlink -- "$pid/exe" 2> /dev/null); then
            printf '%s\n' "${exe% (deleted)}"
        else
            comm=""
            IFS= read -r comm 2> /dev/null < "$pid/comm" || true
            [[ -n "$comm" ]] && printf 'comm:%s\n' "$comm"
        fi
    done
    return 0
}

# 0 when which agent version runs can be told, 2 when it cannot: /proc cannot
# be read, or one of the user's processes hides its executable (non-dumpable)
# and its comm is the tool's (the link's name) or node, which runs a
# folder-style version (Cursor Agent versions/<v>/) or a renamed one.
mole_versions_probe() {
    local link="$1" tool="${1##*/}" exes line name
    exes=$(mole_running_exes) || return 2
    while IFS= read -r line; do
        [[ "$line" == comm:* ]] || continue
        name="${line#comm:}"
        [[ "$name" == node || "$name" == "${tool:0:15}" || "$name" == cursor-agent ]] && return 2
    done <<< "$exes"
    return 0
}

# Old versions under root: everything except the one <link> resolves into and
# the newest other one by mtime, and never a version a process runs from.
# Without a link that resolves into root nothing is selected: which version is
# live cannot be told.
mole_select_old_versions() {
    local root="$1" link="$2" root_real active entry name
    [[ -L "$link" ]] || return 0
    active=$(readlink -e -- "$link" 2> /dev/null) || return 0
    root_real=$(readlink -e -- "$root" 2> /dev/null) || return 0
    [[ "$active" == "$root_real/"* ]] || return 0
    active="${active#"$root_real/"}"
    active="${active%%/*}"
    [[ -n "$active" && -e "$root/$active" ]] || return 0

    local -a others=()
    while IFS= read -r -d '' entry; do
        name="${entry#*$'\t'}"
        [[ "$name" == [0-9]* && "$name" != "$active" ]] || continue
        others+=("$name")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -printf '%T@\t%f\0' 2> /dev/null | sort -z -t $'\t' -k1,1 -rn)
    ((${#others[@]} > 1)) || return 0

    # Which versions run cannot be told: nothing is selected (clean says so).
    mole_versions_probe "$link" || return 0
    local exes
    exes=$(mole_running_exes) || return 0
    local i path in_use exe
    for ((i = 1; i < ${#others[@]}; i++)); do
        path="$root/${others[i]}"
        in_use=false
        while IFS= read -r exe; do
            [[ "$exe" == "$path" || "$exe" == "$path/"* || "$exe" == "$root_real/${others[i]}" || "$exe" == "$root_real/${others[i]}/"* ]] && in_use=true && break
            # An unreadable executable whose comm is this version's file name.
            [[ "$exe" == "comm:${others[i]:0:15}" ]] && in_use=true && break
        done <<< "$exes"
        [[ "$in_use" == false ]] && printf '%s\0' "$path"
    done
    return 0
}

# Extension folders an editor's .obsolete file marks (keys set to true).
mole_select_obsolete_extensions() {
    local root="$1" key
    [[ -f "$root/.obsolete" && ! -L "$root/.obsolete" ]] || return 0
    while IFS= read -r key; do
        [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
        [[ -d "$root/$key" && ! -L "$root/$key" ]] || continue
        printf '%s\0' "$root/$key"
    done < <(grep -oE '"[^"\\]+"[[:space:]]*:[[:space:]]*true' "$root/.obsolete" 2> /dev/null | sed -E 's/^"([^"]+)".*/\1/')
    return 0
}
