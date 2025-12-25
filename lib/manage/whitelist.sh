#!/bin/bash
# Whitelist management functionality
# Shows actual files that would be deleted by dry-run

set -euo pipefail

# Get script directory and source dependencies
_MOLE_MANAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MOLE_MANAGE_DIR/../core/common.sh"
source "$_MOLE_MANAGE_DIR/../ui/menu_simple.sh"

# Config file paths
readonly WHITELIST_CONFIG_CLEAN="$HOME/.config/mole/whitelist"
readonly WHITELIST_CONFIG_OPTIMIZE="$HOME/.config/mole/whitelist_optimize"
readonly WHITELIST_CONFIG_OPTIMIZE_LEGACY="$HOME/.config/mole/whitelist_checks"

# Default whitelist patterns defined in lib/core/common.sh:
# - DEFAULT_WHITELIST_PATTERNS
# - FINDER_METADATA_SENTINEL

# Save whitelist patterns to config (defaults to "clean" for legacy callers)
save_whitelist_patterns() {
    local mode="clean"
    if [[ $# -gt 0 ]]; then
        case "$1" in
            clean | optimize)
                mode="$1"
                shift
                ;;
        esac
    fi

    local -a patterns
    patterns=("$@")

    local config_file
    local header_text

    if [[ "$mode" == "optimize" ]]; then
        config_file="$WHITELIST_CONFIG_OPTIMIZE"
        header_text="# Mole Optimization Whitelist - These checks will be skipped during optimization"
    else
        config_file="$WHITELIST_CONFIG_CLEAN"
        header_text="# Mole Whitelist - Protected paths won't be deleted\n# Default protections: Playwright browsers, HuggingFace models, Maven repo, Ollama models, Surge Mac, R renv, Finder metadata\n# Add one pattern per line to keep items safe."
    fi

    ensure_user_file "$config_file"

    echo -e "$header_text" > "$config_file"

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
            printf '\n' >> "$config_file"
            for pattern in "${unique_patterns[@]}"; do
                echo "$pattern" >> "$config_file"
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
Rust documentation cache|$HOME/.rustup/toolchains/*/share/doc/*|compiler_cache
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
R renv global cache (virtual environments)|$HOME/Library/Caches/org.R-project.R/R/renv/*|package_manager
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
    # Add FINDER_METADATA with constant reference
    echo "Finder metadata (.DS_Store)|$FINDER_METADATA_SENTINEL|system_cache"
}

# Get all optimize items with their patterns
get_optimize_whitelist_items() {
    # Format: "display_name|pattern|category"
    cat << 'EOF'
macOS Firewall check|firewall|security_check
Gatekeeper check|gatekeeper|security_check
Homebrew updates check|check_brew_updates|update_check
macOS system updates check|check_macos_updates|update_check
Homebrew health check (doctor)|check_brew_health|health_check
SIP status check|check_sip|security_check
FileVault status check|check_filevault|security_check
TouchID sudo check|check_touchid|config_check
Rosetta 2 check|check_rosetta|config_check
Git configuration check|check_git_config|config_check
Login items check|check_login_items|config_check
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
    local mode="${1:-clean}"
    local -a patterns=()
    local config_file
    local legacy_file=""

    if [[ "$mode" == "optimize" ]]; then
        config_file="$WHITELIST_CONFIG_OPTIMIZE"
        legacy_file="$WHITELIST_CONFIG_OPTIMIZE_LEGACY"
    else
        config_file="$WHITELIST_CONFIG_CLEAN"
    fi

    local using_legacy="false"
    if [[ ! -f "$config_file" && -n "$legacy_file" && -f "$legacy_file" ]]; then
        config_file="$legacy_file"
        using_legacy="true"
    fi

    if [[ -f "$config_file" ]]; then
        while IFS= read -r line; do
            # shellcheck disable=SC2295
            line="${line#"${line%%[![:space:]]*}"}"
            # shellcheck disable=SC2295
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            patterns+=("$line")
        done < "$config_file"
    else
        if [[ "$mode" == "clean" ]]; then
            patterns=("${DEFAULT_WHITELIST_PATTERNS[@]}")
        elif [[ "$mode" == "optimize" ]]; then
            patterns=("${DEFAULT_OPTIMIZE_WHITELIST_PATTERNS[@]}")
        fi
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

        # Migrate legacy optimize config to the new path automatically
        if [[ "$mode" == "optimize" && "$using_legacy" == "true" && "$config_file" != "$WHITELIST_CONFIG_OPTIMIZE" ]]; then
            save_whitelist_patterns "$mode" "${CURRENT_WHITELIST_PATTERNS[@]}"
        fi
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
        # Only use exact string match to prevent glob expansion security issues
        if [[ "$check_pattern" == "$existing_expanded" ]]; then
            return 0
        fi
    done
    return 1
}

manage_whitelist() {
    local mode="${1:-clean}"
    manage_whitelist_categories "$mode"
}

manage_whitelist_categories() {
    local mode="$1"

    # Load currently enabled patterns from both sources
    load_whitelist "$mode"

    # Build cache items list
    local -a cache_items=()
    local -a cache_patterns=()
    local -a menu_options=()
    local index=0

    # Choose source based on mode
    local items_source
    local menu_title
    local active_config_file

    if [[ "$mode" == "optimize" ]]; then
        items_source=$(get_optimize_whitelist_items)
        active_config_file="$WHITELIST_CONFIG_OPTIMIZE"
        local display_config="${active_config_file/#$HOME/~}"
        menu_title="Whitelist Manager – Select system checks to ignore
${GRAY}Edit: ${display_config}${NC}"
    else
        items_source=$(get_all_cache_items)
        active_config_file="$WHITELIST_CONFIG_CLEAN"
        local display_config="${active_config_file/#$HOME/~}"
        menu_title="Whitelist Manager – Select caches to protect
${GRAY}Edit: ${display_config}${NC}"
    fi

    while IFS='|' read -r display_name pattern _; do
        # Expand $HOME in pattern
        pattern="${pattern/\$HOME/$HOME}"

        cache_items+=("$display_name")
        cache_patterns+=("$pattern")
        menu_options+=("$display_name")

        ((index++)) || true
    done <<< "$items_source"

    # Identify custom patterns (not in predefined list)
    local -a custom_patterns=()
    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        for current_pattern in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            for predefined_pattern in "${cache_patterns[@]}"; do
                if patterns_equivalent "$current_pattern" "$predefined_pattern"; then
                    is_predefined=true
                    break
                fi
            done
            if [[ "$is_predefined" == "false" ]]; then
                custom_patterns+=("$current_pattern")
            fi
        done
    fi

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
    paginated_multi_select "$menu_title" "${menu_options[@]}"
    unset MOLE_PRESELECTED_INDICES
    local exit_code=$?

    # Normal exit or cancel
    if [[ $exit_code -ne 0 ]]; then
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

    # Merge custom patterns with selected patterns
    local -a all_patterns=()
    if [[ ${#selected_patterns[@]} -gt 0 ]]; then
        all_patterns=("${selected_patterns[@]}")
    fi
    if [[ ${#custom_patterns[@]} -gt 0 ]]; then
        for custom_pattern in "${custom_patterns[@]}"; do
            all_patterns+=("$custom_pattern")
        done
    fi

    # Save to whitelist config (bash 3.2 + set -u safe)
    if [[ ${#all_patterns[@]} -gt 0 ]]; then
        save_whitelist_patterns "$mode" "${all_patterns[@]}"
    else
        save_whitelist_patterns "$mode"
    fi

    local total_protected=$((${#selected_patterns[@]} + ${#custom_patterns[@]}))
    local -a summary_lines=()
    summary_lines+=("Whitelist Updated")
    if [[ ${#custom_patterns[@]} -gt 0 ]]; then
        summary_lines+=("Protected ${#selected_patterns[@]} predefined + ${#custom_patterns[@]} custom patterns")
    else
        summary_lines+=("Protected ${total_protected} cache(s)")
    fi
    local display_config="${active_config_file/#$HOME/~}"
    summary_lines+=("Config: ${GRAY}${display_config}${NC}")

    print_summary_block "${summary_lines[@]}"
    printf '\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_whitelist
fi
