#!/bin/bash
# Developer Tools Cleanup Module

set -euo pipefail

# Helper function to clean tool caches using their built-in commands
# Args: $1 - description, $@ - command to execute
# Env: DRY_RUN
# Note: Try to estimate potential savings (many tool caches don't have a direct path,
#       so we just report the action if we can't easily find a path)
clean_tool_cache() {
    local description="$1"
    shift
    if [[ "$DRY_RUN" != "true" ]]; then
        if "$@" > /dev/null 2>&1; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $description"
        fi
    else
        echo -e "  ${YELLOW}→${NC} $description (would clean)"
    fi
}

# Clean npm cache (command + directories)
# npm cache clean clears official npm cache, safe_clean handles alternative package managers
# Env: DRY_RUN
clean_dev_npm() {
    if command -v npm > /dev/null 2>&1; then
        # clean_tool_cache now calculates size before cleanup for better statistics
        clean_tool_cache "npm cache" npm cache clean --force
        note_activity
    fi

    # Clean pnpm store cache
    local pnpm_default_store=~/Library/pnpm/store
    if command -v pnpm > /dev/null 2>&1; then
        # Use pnpm's built-in prune command
        clean_tool_cache "pnpm store prune" pnpm store prune
        note_activity
        # Get the actual store path to check if default is orphaned
        local pnpm_store_path
        pnpm_store_path=$(run_with_timeout 5 pnpm store path 2>/dev/null) || pnpm_store_path=""
        # If store path is different from default, clean the orphaned default
        if [[ -n "$pnpm_store_path" && "$pnpm_store_path" != "$pnpm_default_store" ]]; then
            safe_clean "$pnpm_default_store"/* "pnpm store (orphaned)"
        fi
    else
        # pnpm not installed, clean default location
        safe_clean "$pnpm_default_store"/* "pnpm store"
    fi

    # Clean alternative package manager caches
    safe_clean ~/.tnpm/_cacache/* "tnpm cache directory"
    safe_clean ~/.tnpm/_logs/* "tnpm logs"
    safe_clean ~/.yarn/cache/* "Yarn cache"
    safe_clean ~/.bun/install/cache/* "Bun cache"
}

# Clean Python/pip cache (command + directories)
# pip cache purge clears official pip cache, safe_clean handles other Python tools
# Env: DRY_RUN
clean_dev_python() {
    if command -v pip3 > /dev/null 2>&1; then
        # clean_tool_cache now calculates size before cleanup for better statistics
        clean_tool_cache "pip cache" bash -c 'pip3 cache purge >/dev/null 2>&1 || true'
        note_activity
    fi

    # Clean Python ecosystem caches
    safe_clean ~/.pyenv/cache/* "pyenv cache"
    safe_clean ~/.cache/poetry/* "Poetry cache"
    safe_clean ~/.cache/uv/* "uv cache"
    safe_clean ~/.cache/ruff/* "Ruff cache"
    safe_clean ~/.cache/mypy/* "MyPy cache"
    safe_clean ~/.pytest_cache/* "Pytest cache"
    safe_clean ~/.jupyter/runtime/* "Jupyter runtime cache"
    safe_clean ~/.cache/huggingface/* "Hugging Face cache"
    safe_clean ~/.cache/torch/* "PyTorch cache"
    safe_clean ~/.cache/tensorflow/* "TensorFlow cache"
    safe_clean ~/.conda/pkgs/* "Conda packages cache"
    safe_clean ~/anaconda3/pkgs/* "Anaconda packages cache"
    safe_clean ~/.cache/wandb/* "Weights & Biases cache"
}

# Clean Go cache (command + directories)
# go clean handles build and module caches comprehensively
# Env: DRY_RUN
clean_dev_go() {
    if command -v go > /dev/null 2>&1; then
        # clean_tool_cache now calculates size before cleanup for better statistics
        clean_tool_cache "Go cache" bash -c 'go clean -modcache >/dev/null 2>&1 || true; go clean -cache >/dev/null 2>&1 || true'
        note_activity
    fi
}

# Clean Rust/cargo cache directories
clean_dev_rust() {
    safe_clean ~/.cargo/registry/cache/* "Rust cargo cache"
    safe_clean ~/.cargo/git/* "Cargo git cache"
    safe_clean ~/.rustup/downloads/* "Rust downloads cache"
}

# Clean Docker cache (command + directories)
# Env: DRY_RUN
clean_dev_docker() {
    if command -v docker > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            # Check if Docker daemon is running (with timeout to prevent hanging)
            if run_with_timeout 3 docker info > /dev/null 2>&1; then
                clean_tool_cache "Docker build cache" docker builder prune -af
            else
                note_activity
                echo -e "  ${GRAY}${ICON_SUCCESS}${NC} Docker build cache (daemon not running)"
            fi
        else
            note_activity
            echo -e "  ${YELLOW}→${NC} Docker build cache (would clean)"
        fi
    fi

    safe_clean ~/.docker/buildx/cache/* "Docker BuildX cache"
}

# Clean Nix package manager
# Env: DRY_RUN
clean_dev_nix() {
    if command -v nix-collect-garbage > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Nix garbage collection" nix-collect-garbage --delete-older-than 30d
        else
            echo -e "  ${YELLOW}→${NC} Nix garbage collection (would clean)"
        fi
        note_activity
    fi
}

# Clean cloud CLI tools cache
clean_dev_cloud() {
    safe_clean ~/.kube/cache/* "Kubernetes cache"
    safe_clean ~/.local/share/containers/storage/tmp/* "Container storage temp"
    safe_clean ~/.aws/cli/cache/* "AWS CLI cache"
    safe_clean ~/.config/gcloud/logs/* "Google Cloud logs"
    safe_clean ~/.azure/logs/* "Azure CLI logs"
}

# Clean frontend build tool caches
clean_dev_frontend() {
    safe_clean ~/.pnpm-store/* "pnpm store cache"
    safe_clean ~/.local/share/pnpm/store/* "pnpm global store"
    safe_clean ~/.cache/typescript/* "TypeScript cache"
    safe_clean ~/.cache/electron/* "Electron cache"
    safe_clean ~/.cache/node-gyp/* "node-gyp cache"
    safe_clean ~/.node-gyp/* "node-gyp build cache"
    safe_clean ~/.turbo/cache/* "Turbo cache"
    safe_clean ~/.vite/cache/* "Vite cache"
    safe_clean ~/.cache/vite/* "Vite global cache"
    safe_clean ~/.cache/webpack/* "Webpack cache"
    safe_clean ~/.parcel-cache/* "Parcel cache"
    safe_clean ~/.cache/eslint/* "ESLint cache"
    safe_clean ~/.cache/prettier/* "Prettier cache"
}

# Clean mobile development tools
# iOS simulator cleanup can free significant space (70GB+ in some cases)
# DeviceSupport files accumulate for each iOS version connected
# Simulator runtime caches can grow large over time
clean_dev_mobile() {
    # Clean Xcode unavailable simulators
    # Removes old and unused local iOS simulator data from old unused runtimes
    # Can free up significant space (70GB+ in some cases)
    if command -v xcrun > /dev/null 2>&1; then
        debug_log "Checking for unavailable Xcode simulators"

        if [[ "$DRY_RUN" == "true" ]]; then
            clean_tool_cache "Xcode unavailable simulators" xcrun simctl delete unavailable
        else
            if [[ -t 1 ]]; then
                MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking unavailable simulators..."
            fi

            # Run command manually to control UI output order
            if xcrun simctl delete unavailable > /dev/null 2>&1; then
                if [[ -t 1 ]]; then stop_inline_spinner; fi
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode unavailable simulators"
            else
                if [[ -t 1 ]]; then stop_inline_spinner; fi
                # Silently fail or log error if needed, matching clean_tool_cache behavior
            fi
        fi
        note_activity
    fi

    # Clean iOS DeviceSupport - more comprehensive cleanup
    # DeviceSupport directories store debug symbols for each iOS version
    # Safe to clean caches and logs, but preserve device support files themselves
    safe_clean ~/Library/Developer/Xcode/iOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "iOS device symbol cache"
    safe_clean ~/Library/Developer/Xcode/iOS\ DeviceSupport/*.log "iOS device support logs"
    safe_clean ~/Library/Developer/Xcode/watchOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "watchOS device symbol cache"
    safe_clean ~/Library/Developer/Xcode/tvOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "tvOS device symbol cache"

    # Clean simulator runtime caches
    # RuntimeRoot caches can accumulate system library caches
    safe_clean ~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/* "Simulator runtime cache"

    safe_clean ~/Library/Caches/Google/AndroidStudio*/* "Android Studio cache"
    safe_clean ~/Library/Caches/CocoaPods/* "CocoaPods cache"
    safe_clean ~/.cache/flutter/* "Flutter cache"
    safe_clean ~/.android/build-cache/* "Android build cache"
    safe_clean ~/.android/cache/* "Android SDK cache"
    safe_clean ~/Library/Developer/Xcode/UserData/IB\ Support/* "Xcode Interface Builder cache"
    safe_clean ~/.cache/swift-package-manager/* "Swift package manager cache"
}

# Clean JVM ecosystem tools
clean_dev_jvm() {
    safe_clean ~/.gradle/caches/* "Gradle caches"
    safe_clean ~/.gradle/daemon/* "Gradle daemon logs"
    safe_clean ~/.sbt/* "SBT cache"
    safe_clean ~/.ivy2/cache/* "Ivy cache"
}

# Clean other language tools
clean_dev_other_langs() {
    safe_clean ~/.bundle/cache/* "Ruby Bundler cache"
    safe_clean ~/.composer/cache/* "PHP Composer cache"
    safe_clean ~/.nuget/packages/* "NuGet packages cache"
    safe_clean ~/.pub-cache/* "Dart Pub cache"
    safe_clean ~/.cache/bazel/* "Bazel cache"
    safe_clean ~/.cache/zig/* "Zig cache"
    safe_clean ~/Library/Caches/deno/* "Deno cache"
}

# Clean CI/CD and DevOps tools
clean_dev_cicd() {
    safe_clean ~/.cache/terraform/* "Terraform cache"
    safe_clean ~/.grafana/cache/* "Grafana cache"
    safe_clean ~/.prometheus/data/wal/* "Prometheus WAL cache"
    safe_clean ~/.jenkins/workspace/*/target/* "Jenkins workspace cache"
    safe_clean ~/.cache/gitlab-runner/* "GitLab Runner cache"
    safe_clean ~/.github/cache/* "GitHub Actions cache"
    safe_clean ~/.circleci/cache/* "CircleCI cache"
    safe_clean ~/.sonar/* "SonarQube cache"
}

# Clean database tools
clean_dev_database() {
    safe_clean ~/Library/Caches/com.sequel-ace.sequel-ace/* "Sequel Ace cache"
    safe_clean ~/Library/Caches/com.eggerapps.Sequel-Pro/* "Sequel Pro cache"
    safe_clean ~/Library/Caches/redis-desktop-manager/* "Redis Desktop Manager cache"
    safe_clean ~/Library/Caches/com.navicat.* "Navicat cache"
    safe_clean ~/Library/Caches/com.dbeaver.* "DBeaver cache"
    safe_clean ~/Library/Caches/com.redis.RedisInsight "Redis Insight cache"
}

# Clean API/network debugging tools
clean_dev_api_tools() {
    safe_clean ~/Library/Caches/com.postmanlabs.mac/* "Postman cache"
    safe_clean ~/Library/Caches/com.konghq.insomnia/* "Insomnia cache"
    safe_clean ~/Library/Caches/com.tinyapp.TablePlus/* "TablePlus cache"
    safe_clean ~/Library/Caches/com.getpaw.Paw/* "Paw API cache"
    safe_clean ~/Library/Caches/com.charlesproxy.charles/* "Charles Proxy cache"
    safe_clean ~/Library/Caches/com.proxyman.NSProxy/* "Proxyman cache"
}

# Clean misc dev tools
clean_dev_misc() {
    safe_clean ~/Library/Caches/com.unity3d.*/* "Unity cache"
    safe_clean ~/Library/Caches/com.mongodb.compass/* "MongoDB Compass cache"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Caches/com.github.GitHubDesktop/* "GitHub Desktop cache"
    safe_clean ~/Library/Caches/SentryCrash/* "Sentry crash reports"
    safe_clean ~/Library/Caches/KSCrash/* "KSCrash reports"
    safe_clean ~/Library/Caches/com.crashlytics.data/* "Crashlytics data"
}

# Clean shell and version control
clean_dev_shell() {
    safe_clean ~/.gitconfig.lock "Git config lock"
    safe_clean ~/.gitconfig.bak* "Git config backup"
    safe_clean ~/.oh-my-zsh/cache/* "Oh My Zsh cache"
    safe_clean ~/.config/fish/fish_history.bak* "Fish shell backup"
    safe_clean ~/.bash_history.bak* "Bash history backup"
    safe_clean ~/.zsh_history.bak* "Zsh history backup"
    safe_clean ~/.cache/pre-commit/* "pre-commit cache"
}

# Clean network utilities
clean_dev_network() {
    safe_clean ~/.cache/curl/* "curl cache"
    safe_clean ~/.cache/wget/* "wget cache"
    safe_clean ~/Library/Caches/curl/* "curl cache (macOS)"
    safe_clean ~/Library/Caches/wget/* "wget cache (macOS)"
}

# Main developer tools cleanup function
# Calls all specialized cleanup functions
# Env: DRY_RUN
clean_developer_tools() {
    clean_dev_npm
    clean_dev_python
    clean_dev_go
    clean_dev_rust
    clean_dev_docker
    clean_dev_cloud
    clean_dev_nix
    clean_dev_shell
    clean_dev_frontend

    # Project build caches (delegated to clean_caches module)
    clean_project_caches

    clean_dev_mobile
    clean_dev_jvm
    clean_dev_other_langs
    clean_dev_cicd
    clean_dev_database
    clean_dev_api_tools
    clean_dev_network
    clean_dev_misc

    # Homebrew caches and cleanup (delegated to clean_brew module)
    safe_clean ~/Library/Caches/Homebrew/* "Homebrew cache"

    # Clean Homebrew locks intelligently (avoid repeated sudo prompts)
    local brew_lock_dirs=(
        "/opt/homebrew/var/homebrew/locks"
        "/usr/local/var/homebrew/locks"
    )

    for lock_dir in "${brew_lock_dirs[@]}"; do
        if [[ -d "$lock_dir" && -w "$lock_dir" ]]; then
            # User can write, safe to clean
            safe_clean "$lock_dir"/* "Homebrew lock files"
        elif [[ -d "$lock_dir" ]]; then
            # Directory exists but not writable. Check if empty to avoid noise.
            if find "$lock_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                # Only try sudo ONCE if we really need to, or just skip to avoid spam
                # Decision: Skip strict system/root owned locks to avoid nag.
                debug_log "Skipping read-only Homebrew locks in $lock_dir"
            fi
        fi
    done

    clean_homebrew
}
