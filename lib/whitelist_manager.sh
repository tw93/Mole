#!/bin/bash
# Whitelist management functionality
# Shows actual files that would be deleted by dry-run

set -euo pipefail

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/menu_simple.sh"

# Config file path
WHITELIST_CONFIG="$HOME/.config/mole/whitelist"

# Default whitelist patterns (preselected on first run)
declare -a DEFAULT_WHITELIST_PATTERNS=(
    "$HOME/Library/Caches/ms-playwright*"
    "$HOME/.cache/huggingface*"
    "$HOME/.m2/repository/*"
    "$HOME/.ollama/models/*"
    "$HOME/Library/Caches/com.nssurge.surge-mac/*"
    "$HOME/Library/Application Support/com.nssurge.surge-mac/*"
)

# Save whitelist patterns to config
save_whitelist_patterns() {
    local -a patterns
    patterns=("$@")
    mkdir -p "$(dirname "$WHITELIST_CONFIG")"

    cat > "$WHITELIST_CONFIG" << 'EOF'
# Mole Whitelist - Protected paths won't be deleted
# Default protections: Playwright browsers, HuggingFace models, Maven repo, Ollama models, Surge Mac
# Add one pattern per line to keep items safe.
EOF

    if [[ ${#patterns[@]} -gt 0 ]]; then
        local -a unique_patterns=()
        for pattern in "${patterns[@]}"; do
            local duplicate="false"
            if [[ ${#unique_patterns[@]} -gt 0 ]]; then
                for existing in "${unique_patterns[@]}"; do
                    if patterns_equivalent "$pattern" "$existing"; then
                        duplicate="true"
                        break
                    fi
                done
            fi
            [[ "$duplicate" == "true" ]] && continue
            unique_patterns+=("$pattern")
        done

        if [[ ${#unique_patterns[@]} -gt 0 ]]; then
            printf '\n' >> "$WHITELIST_CONFIG"
            for pattern in "${unique_patterns[@]}"; do
                echo "$pattern" >> "$WHITELIST_CONFIG"
            done
        fi
    fi
}

# Get all cache items with their patterns
get_all_cache_items() {
    # Format: "display_name|pattern|category"
    cat << 'EOF'
Apple Mail cache|$HOME/Library/Caches/com.apple.mail/*|system_cache
Gradle build cache (Android Studio, Gradle projects)|$HOME/.gradle/caches/*|ide_cache
Gradle daemon processes cache|$HOME/.gradle/daemon/*|ide_cache
Xcode DerivedData (build outputs, indexes)|$HOME/Library/Developer/Xcode/DerivedData/*|ide_cache
Xcode internal cache files|$HOME/Library/Caches/com.apple.dt.Xcode/*|ide_cache
Xcode iOS device support symbols|$HOME/Library/Developer/Xcode/iOS DeviceSupport/*/Symbols/System/Library/Caches/*|ide_cache
Maven local repository (Java dependencies)|$HOME/.m2/repository/*|ide_cache
JetBrains IDEs cache (IntelliJ, PyCharm, WebStorm)|$HOME/Library/Caches/JetBrains/*|ide_cache
Android Studio cache and indexes|$HOME/Library/Caches/Google/AndroidStudio*/*|ide_cache
Android build cache|$HOME/.android/build-cache/*|ide_cache
VS Code runtime cache|$HOME/Library/Application Support/Code/Cache/*|ide_cache
VS Code extension and update cache|$HOME/Library/Application Support/Code/CachedData/*|ide_cache
VS Code system cache (Cursor, VSCodium)|$HOME/Library/Caches/com.microsoft.VSCode/*|ide_cache
Cursor editor cache|$HOME/Library/Caches/com.todesktop.230313mzl4w4u92/*|ide_cache
Bazel build cache|$HOME/.cache/bazel/*|compiler_cache
Go build cache and module cache|$HOME/Library/Caches/go-build/*|compiler_cache
Go module cache|$HOME/go/pkg/mod/cache/*|compiler_cache
Rust Cargo registry cache|$HOME/.cargo/registry/cache/*|compiler_cache
Rustup toolchain downloads|$HOME/.rustup/downloads/*|compiler_cache
ccache compiler cache|$HOME/.ccache/*|compiler_cache
sccache distributed compiler cache|$HOME/.cache/sccache/*|compiler_cache
SBT Scala build cache|$HOME/.sbt/*|compiler_cache
Ivy dependency cache|$HOME/.ivy2/cache/*|compiler_cache
Turbo monorepo build cache|$HOME/.turbo/*|compiler_cache
Next.js build cache|$HOME/.next/*|compiler_cache
Vite build cache|$HOME/.vite/*|compiler_cache
Parcel bundler cache|$HOME/.parcel-cache/*|compiler_cache
pre-commit hooks cache|$HOME/.cache/pre-commit/*|compiler_cache
Ruff Python linter cache|$HOME/.cache/ruff/*|compiler_cache
MyPy type checker cache|$HOME/.cache/mypy/*|compiler_cache
Pytest test cache|$HOME/.pytest_cache/*|compiler_cache
Flutter SDK cache|$HOME/.cache/flutter/*|compiler_cache
Swift Package Manager cache|$HOME/.cache/swift-package-manager/*|compiler_cache
Zig compiler cache|$HOME/.cache/zig/*|compiler_cache
Deno cache|$HOME/Library/Caches/deno/*|compiler_cache
CocoaPods cache (iOS dependencies)|$HOME/Library/Caches/CocoaPods/*|package_manager
npm package cache|$HOME/.npm/_cacache/*|package_manager
pip Python package cache|$HOME/.cache/pip/*|package_manager
uv Python package cache|$HOME/.cache/uv/*|package_manager
Homebrew downloaded packages|$HOME/Library/Caches/Homebrew/*|package_manager
Yarn package manager cache|$HOME/.cache/yarn/*|package_manager
pnpm package store|$HOME/.pnpm-store/*|package_manager
Composer PHP dependencies cache|$HOME/.composer/cache/*|package_manager
RubyGems cache|$HOME/.gem/cache/*|package_manager
Conda packages cache|$HOME/.conda/pkgs/*|package_manager
Anaconda packages cache|$HOME/anaconda3/pkgs/*|package_manager
PyTorch model cache|$HOME/.cache/torch/*|ai_ml_cache
TensorFlow model and dataset cache|$HOME/.cache/tensorflow/*|ai_ml_cache
HuggingFace models and datasets|$HOME/.cache/huggingface/*|ai_ml_cache
Playwright browser binaries|$HOME/Library/Caches/ms-playwright*|ai_ml_cache
Selenium WebDriver binaries|$HOME/.cache/selenium/*|ai_ml_cache
Ollama local AI models|$HOME/.ollama/models/*|ai_ml_cache
Weights & Biases ML experiments cache|$HOME/.cache/wandb/*|ai_ml_cache
Safari web browser cache|$HOME/Library/Caches/com.apple.Safari/*|browser_cache
Chrome browser cache|$HOME/Library/Caches/Google/Chrome/*|browser_cache
Firefox browser cache|$HOME/Library/Caches/Firefox/*|browser_cache
Brave browser cache|$HOME/Library/Caches/BraveSoftware/Brave-Browser/*|browser_cache
Surge proxy cache|$HOME/Library/Caches/com.nssurge.surge-mac/*|network_tools
Surge configuration and data|$HOME/Library/Application Support/com.nssurge.surge-mac/*|network_tools
Docker Desktop image cache|$HOME/Library/Containers/com.docker.docker/Data/*|container_cache
Podman container cache|$HOME/.local/share/containers/cache/*|container_cache
Font cache|$HOME/Library/Caches/com.apple.FontRegistry/*|system_cache
Spotlight metadata cache|$HOME/Library/Caches/com.apple.spotlight/*|system_cache
CloudKit cache|$HOME/Library/Caches/CloudKit/*|system_cache
EOF
}

patterns_equivalent() {
    local first="${1/#~/$HOME}"
    local second="${2/#~/$HOME}"

    # Only exact string match, no glob expansion
    [[ "$first" == "$second" ]] && return 0
    return 1
}

load_whitelist() {
    local -a patterns=()

    if [[ -f "$WHITELIST_CONFIG" ]]; then
        while IFS= read -r line; do
            line="${line#${line%%[![:space:]]*}}"
            line="${line%${line##*[![:space:]]}}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            patterns+=("$line")
        done < "$WHITELIST_CONFIG"
    else
        patterns=("${DEFAULT_WHITELIST_PATTERNS[@]}")
    fi

    if [[ ${#patterns[@]} -gt 0 ]]; then
        local -a unique_patterns=()
        for pattern in "${patterns[@]}"; do
            local duplicate="false"
            if [[ ${#unique_patterns[@]} -gt 0 ]]; then
                for existing in "${unique_patterns[@]}"; do
                    if patterns_equivalent "$pattern" "$existing"; then
                        duplicate="true"
                        break
                    fi
                done
            fi
            [[ "$duplicate" == "true" ]] && continue
            unique_patterns+=("$pattern")
        done
        CURRENT_WHITELIST_PATTERNS=("${unique_patterns[@]}")
    else
        CURRENT_WHITELIST_PATTERNS=()
    fi
}

is_whitelisted() {
    local pattern="$1"
    local check_pattern="${pattern/#\~/$HOME}"

    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -eq 0 ]]; then
        return 1
    fi

    for existing in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
        local existing_expanded="${existing/#\~/$HOME}"
        # Support both exact match and glob pattern match
        # shellcheck disable=SC2053
        if [[ "$check_pattern" == "$existing_expanded" ]] || [[ $check_pattern == $existing_expanded ]]; then
            return 0
        fi
    done
    return 1
}

manage_whitelist() {
    manage_whitelist_categories
}

manage_whitelist_categories() {
    clear
    echo ""
    echo -e "${PURPLE}Whitelist Manager${NC}"
    echo ""
    echo ""

    # Load currently enabled patterns from both sources
    load_whitelist

    # Build cache items list
    local -a cache_items=()
    local -a cache_patterns=()
    local -a menu_options=()
    local index=0

    while IFS='|' read -r display_name pattern _; do
        # Expand $HOME in pattern
        pattern="${pattern/\$HOME/$HOME}"

        cache_items+=("$display_name")
        cache_patterns+=("$pattern")
        menu_options+=("$display_name")

        ((index++))
    done < <(get_all_cache_items)

    # Prioritize already-selected items to appear first
    local -a selected_cache_items=()
    local -a selected_cache_patterns=()
    local -a selected_menu_options=()
    local -a remaining_cache_items=()
    local -a remaining_cache_patterns=()
    local -a remaining_menu_options=()

    for ((i = 0; i < ${#cache_patterns[@]}; i++)); do
        if is_whitelisted "${cache_patterns[i]}"; then
            selected_cache_items+=("${cache_items[i]}")
            selected_cache_patterns+=("${cache_patterns[i]}")
            selected_menu_options+=("${menu_options[i]}")
        else
            remaining_cache_items+=("${cache_items[i]}")
            remaining_cache_patterns+=("${cache_patterns[i]}")
            remaining_menu_options+=("${menu_options[i]}")
        fi
    done

    cache_items=()
    cache_patterns=()
    menu_options=()
    if [[ ${#selected_cache_items[@]} -gt 0 ]]; then
        cache_items=("${selected_cache_items[@]}")
        cache_patterns=("${selected_cache_patterns[@]}")
        menu_options=("${selected_menu_options[@]}")
    fi
    if [[ ${#remaining_cache_items[@]} -gt 0 ]]; then
        cache_items+=("${remaining_cache_items[@]}")
        cache_patterns+=("${remaining_cache_patterns[@]}")
        menu_options+=("${remaining_menu_options[@]}")
    fi

    if [[ ${#selected_cache_patterns[@]} -gt 0 ]]; then
        local -a preselected_indices=()
        for ((i = 0; i < ${#selected_cache_patterns[@]}; i++)); do
            preselected_indices+=("$i")
        done
        local IFS=','
        export MOLE_PRESELECTED_INDICES="${preselected_indices[*]}"
    else
        unset MOLE_PRESELECTED_INDICES
    fi

    MOLE_SELECTION_RESULT=""
    paginated_multi_select "Whitelist Manager – Select caches to protect" "${menu_options[@]}"
    unset MOLE_PRESELECTED_INDICES
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo -e "${YELLOW}Cancelled${NC}"
        return 1
    fi

    # Convert selected indices to patterns
    local -a selected_patterns=()
    if [[ -n "$MOLE_SELECTION_RESULT" ]]; then
        local -a selected_indices
        IFS=',' read -ra selected_indices <<< "$MOLE_SELECTION_RESULT"
        for idx in "${selected_indices[@]}"; do
            if [[ $idx -ge 0 && $idx -lt ${#cache_patterns[@]} ]]; then
                local pattern="${cache_patterns[$idx]}"
                # Convert back to portable format with ~
                pattern="${pattern/#$HOME/~}"
                selected_patterns+=("$pattern")
            fi
        done
    fi

    # Save to whitelist config (bash 3.2 + set -u safe)
    if [[ ${#selected_patterns[@]} -gt 0 ]]; then
        save_whitelist_patterns "${selected_patterns[@]}"
    else
        save_whitelist_patterns
    fi

    print_summary_block "success" \
        "Protected ${#selected_patterns[@]} cache(s)" \
        "Saved to ${WHITELIST_CONFIG}"
    printf '\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_whitelist
fi
