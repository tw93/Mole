#!/bin/bash
# Shared purge configuration and helpers (side-effect free).

set -euo pipefail

if [[ -n "${MOLE_PURGE_SHARED_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PURGE_SHARED_LOADED=1

MOLE_PURGE_PHYSICAL_HOME="$HOME"
if [[ -d "$HOME" ]]; then
    MOLE_PURGE_PHYSICAL_HOME=$(cd "$HOME" 2> /dev/null && pwd -P) || MOLE_PURGE_PHYSICAL_HOME="$HOME"
fi
readonly MOLE_PURGE_PHYSICAL_HOME

# Canonical purge targets (heavy project build artifacts).
readonly MOLE_PURGE_TARGETS=(
    "node_modules"
    "target"            # Rust, Maven
    "build"             # Gradle, various
    "dist"              # JS builds
    "venv"              # Python
    ".venv"             # Python
    ".pytest_cache"     # Python (pytest)
    ".mypy_cache"       # Python (mypy)
    ".tox"              # Python (tox virtualenvs)
    ".nox"              # Python (nox virtualenvs)
    ".ruff_cache"       # Python (ruff)
    ".gradle"           # Gradle local
    ".terragrunt-cache" # Terragrunt downloaded modules/providers
    "__pycache__"       # Python
    ".next"             # Next.js
    ".nuxt"             # Nuxt.js
    ".output"           # Nuxt.js
    "vendor"            # PHP Composer
    "bin"               # .NET build output (guarded; see is_protected_purge_artifact)
    "obj"               # C# / Unity
    ".turbo"            # Turborepo cache
    ".parcel-cache"     # Parcel bundler
    ".dart_tool"        # Flutter/Dart build cache
    ".zig-cache"        # Zig
    "zig-out"           # Zig
    ".angular"          # Angular
    ".svelte-kit"       # SvelteKit
    ".astro"            # Astro
    "coverage"          # Code coverage reports
    "DerivedData"       # Xcode
    "Pods"              # CocoaPods
    ".cxx"              # React Native Android NDK build cache
    ".expo"             # Expo
    ".build"            # Swift Package Manager
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
    "$HOME/Library/CloudStorage"
    # AI agent worktree containers. These sit under dot directories, which
    # discover_project_dirs cannot reach: it globs "$HOME"/*/ and
    # is_project_container rejects any basename starting with a dot. Listing
    # the exact containers keeps the checkouts inside them in scope for
    # rebuildable-artifact cleanup without widening discovery to dot
    # directories in general. The worktrees themselves are never removed.
    "$HOME/.codex/worktrees"
    "$HOME/.claude/worktrees"
)

readonly MOLE_PURGE_MONOREPO_INDICATORS=(
    "lerna.json"
    "pnpm-workspace.yaml"
    "nx.json"
    "rush.json"
    # A repository or worktree is the project-wide ownership boundary even
    # when nested packages have their own manifests. Keep .git in the project
    # indicators too because container discovery consumes that list directly.
    ".git"
)

readonly MOLE_PURGE_PROJECT_INDICATORS=(
    "package.json"
    "Cargo.toml"
    "go.mod"
    "pyproject.toml"
    "requirements.txt"
    "pom.xml"
    "build.gradle"
    "terragrunt.hcl"
    "Gemfile"
    "composer.json"
    "pubspec.yaml"
    "Package.swift" # Swift Package Manager
    "Makefile"
    "build.zig"
    "build.zig.zon"
    ".git"
)

readonly MOLE_CACHEDIR_TAG_NAME="CACHEDIR.TAG"
readonly MOLE_CACHEDIR_TAG_SIGNATURE="Signature: 8a477f597d28d172789f06886806bc55"

# Normalize an integer or fractional timeout into the whole-second budget used
# by SECONDS. Shared by clean's project-cache scan and purge's size pool so both
# keep fractional overrides without duplicating deadline arithmetic.
mole_purge_timeout_budget_seconds() {
    local fallback_seconds="${2:-30}"
    [[ "$fallback_seconds" =~ ^[1-9][0-9]*$ ]] || fallback_seconds=30
    local timeout_seconds="${1:-$fallback_seconds}"
    if [[ ! "$timeout_seconds" =~ ^[0-9]+(\.[0-9]+)?$ || "$timeout_seconds" =~ ^0+(\.0+)?$ ]]; then
        timeout_seconds="$fallback_seconds"
    fi

    local timeout_whole="${timeout_seconds%%.*}"
    local timeout_budget=$((10#$timeout_whole))
    if [[ "$timeout_seconds" == *.* && "${timeout_seconds#*.}" =~ [1-9] ]]; then
        timeout_budget=$((timeout_budget + 1))
    fi
    [[ $timeout_budget -ge 2 ]] || timeout_budget=2
    printf '%s\n' "$timeout_budget"
}

# High-noise targets intentionally excluded from quick hint scans in mo clean.
readonly MOLE_PURGE_QUICK_HINT_EXCLUDED_TARGETS=(
    "bin"
    "vendor"
)

mole_purge_is_cloud_synced_path() {
    local path="${1:-}"
    [[ -n "$path" ]] || return 1

    case "$path" in
        "$HOME/Library/CloudStorage" | "$HOME/Library/CloudStorage/"* | "$HOME/Library/Mobile Documents" | "$HOME/Library/Mobile Documents/"* | \
            "$MOLE_PURGE_PHYSICAL_HOME/Library/CloudStorage" | "$MOLE_PURGE_PHYSICAL_HOME/Library/CloudStorage/"* | "$MOLE_PURGE_PHYSICAL_HOME/Library/Mobile Documents" | "$MOLE_PURGE_PHYSICAL_HOME/Library/Mobile Documents/"*)
            return 0
            ;;
    esac

    return 1
}

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

# The repository that owns a physical path: the nearest ancestor holding .git
# (a directory, or a file for linked worktrees and submodules). Sets
# MOLE_GIT_REPO_ROOT without a subshell, for callers that ask per candidate.
mole_find_git_repo_root() {
    local ancestor="${1%/}"
    MOLE_GIT_REPO_ROOT=""
    while [[ "$ancestor" != "/" && -n "$ancestor" ]]; do
        if [[ -e "$ancestor/.git" || -L "$ancestor/.git" ]]; then
            MOLE_GIT_REPO_ROOT="$ancestor"
            return 0
        fi
        ancestor="${ancestor%/*}"
    done
    return 1
}

mole_git_repo_root() {
    mole_find_git_repo_root "$1" || return 1
    printf '%s\n' "$MOLE_GIT_REPO_ROOT"
}

# Run a bounded `git ls-files` in a repository from directory $3. Inherited Git
# routing is ignored so the repository's own index answers, fsmonitor hooks
# never run, and pathspecs stay literal. Returns git's or the timeout's status.
mole_git_ls_files() {
    local repo="$1"
    local deadline="$2"
    local dir="$3"
    shift 3
    local probe_timeout=""
    probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_HINT_SCAN_SEC" "$deadline") || return 124
    run_with_timeout "$probe_timeout" \
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        GIT_OPTIONAL_LOCKS=0 GIT_LITERAL_PATHSPECS=1 \
        git -c core.fsmonitor=false --git-dir="$repo/.git" --work-tree="$repo" -C "$dir" ls-files "$@" 2> /dev/null
}

# Whether Git tracks files below a directory, asked of the repository that owns
# it. Names do not prove a directory is disposable: build/ can hold tracked
# source and a cache-named folder a committed fixture. Returns 0 when Git tracks
# files there, 1 when no repository owns the path or it tracks nothing there,
# and 2 when the probe timed out or failed.
mole_path_has_git_tracked_files() {
    local path="${1%/}"
    local deadline="${2:-}"
    local evidence="" repo=""
    [[ -d "$path" ]] || return 1
    # A configured root can cross a symlink before reaching the candidate.
    # Git ancestry must follow the actual repository, not the alias spelling.
    path=$(cd "$path" 2> /dev/null && /bin/pwd -P) || return 2
    repo=$(mole_git_repo_root "$path") || return 1
    evidence=$(mole_git_ls_files "$repo" "$deadline" "$path" -- .) || return 2
    [[ -n "$evidence" ]] && return 0
    return 1
}

mole_dir_has_cachedir_tag() {
    local dir="$1"
    local tag="$dir/$MOLE_CACHEDIR_TAG_NAME"
    [[ -f "$tag" && ! -L "$tag" ]] || return 1

    local signature
    signature=$(LC_ALL=C dd bs=${#MOLE_CACHEDIR_TAG_SIGNATURE} count=1 < "$tag" 2> /dev/null || true)
    [[ "$signature" == "$MOLE_CACHEDIR_TAG_SIGNATURE" ]]
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
#
# Uses the external /bin/pwd rather than the bash builtin: bash's `pwd -P`
# resolves symlink chains in $PWD but reuses the casing of the `cd`
# argument instead of querying the filesystem, so on case-insensitive APFS
# it returns ~/Workspace even when the on-disk directory is ~/workspace.
# That breaks the string dedup in discover_project_dirs and a project
# appears twice (#1416). /bin/pwd calls getcwd(3), which returns the real
# on-disk name.
mole_purge_resolve_path_case() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" 2> /dev/null && /bin/pwd -P) || printf '%s\n' "$path"
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
