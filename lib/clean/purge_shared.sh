#!/bin/bash
# Shared purge configuration and helpers (side-effect free).

set -euo pipefail

if [[ -n "${MOLE_PURGE_SHARED_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PURGE_SHARED_LOADED=1

# Canonical purge targets (heavy project build artifacts).
readonly MOLE_PURGE_TARGETS=(
    "node_modules"
    "target"        # Rust, Maven
    "build"         # Gradle, various
    "dist"          # JS builds
    "venv"          # Python
    ".venv"         # Python
    ".pytest_cache" # Python (pytest)
    ".mypy_cache"   # Python (mypy)
    ".tox"          # Python (tox virtualenvs)
    ".nox"          # Python (nox virtualenvs)
    ".ruff_cache"   # Python (ruff)
    ".gradle"       # Gradle local
    "__pycache__"   # Python
    ".next"         # Next.js
    ".nuxt"         # Nuxt.js
    ".output"       # Nuxt.js
    "vendor"        # PHP Composer
    "bin"           # .NET build output (guarded; see is_protected_purge_artifact)
    "obj"           # C# / Unity
    ".turbo"        # Turborepo cache
    ".parcel-cache" # Parcel bundler
    ".dart_tool"    # Flutter/Dart build cache
    ".zig-cache"    # Zig
    "zig-out"       # Zig
    ".angular"      # Angular
    ".svelte-kit"   # SvelteKit
    ".astro"        # Astro
    "coverage"      # Code coverage reports
    "DerivedData"   # Xcode
    "Pods"          # CocoaPods
    ".cxx"          # React Native Android NDK build cache
    ".expo"         # Expo
    ".build"        # Swift Package Manager
)

readonly MOLE_PURGE_DEFAULT_SEARCH_PATHS=(
    "$HOME/www"
    "$HOME/dev"
    "$HOME/Projects"
    "$HOME/GitHub"
    "$HOME/Code"
    "$HOME/Workspace"
    "$HOME/Repos"
    "$HOME/Development"
)

readonly MOLE_PURGE_MONOREPO_INDICATORS=(
    "lerna.json"
    "pnpm-workspace.yaml"
    "nx.json"
    "rush.json"
)

readonly MOLE_PURGE_PROJECT_INDICATORS=(
    "package.json"
    "Cargo.toml"
    "go.mod"
    "pyproject.toml"
    "requirements.txt"
    "pom.xml"
    "build.gradle"
    "Gemfile"
    "composer.json"
    "pubspec.yaml"
    "Package.swift" # Swift Package Manager
    "Makefile"
    "build.zig"
    "build.zig.zon"
    ".git"
)

# High-noise targets intentionally excluded from quick hint scans in mo clean.
readonly MOLE_PURGE_QUICK_HINT_EXCLUDED_TARGETS=(
    "bin"
    "vendor"
)

mole_purge_is_project_root() {
    local dir="$1"
    local indicator

    for indicator in "${MOLE_PURGE_MONOREPO_INDICATORS[@]}"; do
        if [[ -e "$dir/$indicator" ]]; then
            return 0
        fi
    done

    for indicator in "${MOLE_PURGE_PROJECT_INDICATORS[@]}"; do
        if [[ -e "$dir/$indicator" ]]; then
            return 0
        fi
    done

    return 1
}

mole_purge_quick_hint_target_names() {
    local target
    local excluded
    local is_excluded

    for target in "${MOLE_PURGE_TARGETS[@]}"; do
        is_excluded=false
        for excluded in "${MOLE_PURGE_QUICK_HINT_EXCLUDED_TARGETS[@]}"; do
            if [[ "$target" == "$excluded" ]]; then
                is_excluded=true
                break
            fi
        done
        [[ "$is_excluded" == "true" ]] && continue
        printf '%s\n' "$target"
    done
}

# Resolve a directory path to its canonical filesystem casing.
# On case-insensitive macOS (APFS), ~/Code and ~/code point to the same
# directory but with different display names.  This function returns the
# real (on-disk) path so that string comparisons work correctly for dedup.
mole_purge_resolve_path_case() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    else
        printf '%s\n' "$path"
    fi
}

mole_purge_read_paths_config() {
    local config_file="${1:-$HOME/.config/mole/purge_paths}"
    [[ -f "$config_file" ]] || return 0

    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        line="${line/#\~/$HOME}"
        line=$(mole_purge_resolve_path_case "$line")
        printf '%s\n' "$line"
    done < "$config_file"
}
