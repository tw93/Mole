#!/bin/bash
# Hint notices used by `mo clean` (non-destructive guidance only).

set -euo pipefail

mole_hints_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$mole_hints_dir/purge_shared.sh"

# Quick reminder probe for project build artifacts handled by `mo purge`.
# Designed to be very fast: shallow directory checks only, no deep find scans.
# shellcheck disable=SC2329
load_quick_purge_hint_paths() {
    local config_file="$HOME/.config/mole/purge_paths"
    local -a paths=()

    while IFS= read -r line; do
        [[ -n "$line" ]] && paths+=("$line")
    done < <(mole_purge_read_paths_config "$config_file")

    if [[ ${#paths[@]} -eq 0 ]]; then
        paths=("${MOLE_PURGE_DEFAULT_SEARCH_PATHS[@]}")
    fi

    if [[ ${#paths[@]} -gt 0 ]]; then
        printf '%s\n' "${paths[@]}"
    fi
}

# shellcheck disable=SC2329
hint_get_path_size_kb_with_timeout() {
    local path="$1"
    local timeout_seconds="${2:-0.8}"
    local du_tmp
    du_tmp=$(mktemp)

    local du_status=0
    if run_with_timeout "$timeout_seconds" du -skP "$path" > "$du_tmp" 2> /dev/null; then
        du_status=0
    else
        du_status=$?
    fi

    if [[ $du_status -ne 0 ]]; then
        rm -f "$du_tmp"
        return 1
    fi

    local size_kb
    size_kb=$(awk 'NR==1 {print $1; exit}' "$du_tmp")
    rm -f "$du_tmp"

    [[ "$size_kb" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$size_kb"
}

# shellcheck disable=SC2329
hint_extract_launch_agent_program_path() {
    local plist="$1"
    local program=""

    if ! program=$(plutil -extract ProgramArguments.0 raw "$plist" 2> /dev/null); then
        program=""
    fi
    if [[ -z "$program" ]]; then
        if ! program=$(plutil -extract Program raw "$plist" 2> /dev/null); then
            program=""
        fi
    fi

    printf '%s\n' "$program"
}

# shellcheck disable=SC2329
hint_launch_agent_has_mach_services() {
    local plist="$1"
    plutil -extract MachServices raw "$plist" > /dev/null 2>&1
}

# shellcheck disable=SC2329
hint_extract_launch_agent_associated_bundle() {
    local plist="$1"
    local associated=""

    if ! associated=$(plutil -extract AssociatedBundleIdentifiers.0 raw "$plist" 2> /dev/null); then
        associated=""
    fi
    if [[ -z "$associated" ]] || [[ "$associated" == "1" ]]; then
        if ! associated=$(plutil -extract AssociatedBundleIdentifiers raw "$plist" 2> /dev/null); then
            associated=""
        fi
        if [[ "$associated" == "{"* ]] || [[ "$associated" == "["* ]]; then
            associated=""
        fi
    fi

    printf '%s\n' "$associated"
}

# shellcheck disable=SC2329
hint_is_app_scoped_launch_target() {
    local program="$1"

    case "$program" in
        /Applications/Setapp/*.app/* | \
            /Applications/*.app/* | \
            "$HOME"/Applications/*.app/* | \
            /Library/Input\ Methods/*.app/* | \
            /Library/PrivilegedHelperTools/*)
            return 0
            ;;
    esac

    return 1
}

# shellcheck disable=SC2329
hint_is_system_binary() {
    local program="$1"

    case "$program" in
        /bin/* | /sbin/* | /usr/bin/* | /usr/sbin/* | /usr/libexec/*)
            return 0
            ;;
    esac

    return 1
}

# shellcheck disable=SC2329
hint_launch_agent_bundle_exists() {
    local bundle_id="$1"

    [[ -z "$bundle_id" ]] && return 1

    # Delegate to the shared resolver so Spotlight misses (e.g. KeePassXC
    # installed via Homebrew) fall back to a direct /Applications scan. See #732.
    bundle_has_installed_app "$bundle_id"
}

# shellcheck disable=SC2329
hint_normalize_app_match_text() {
    printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd '[:alnum:]'
}

# shellcheck disable=SC2329
hint_dotdir_candidate_matches_text() {
    local text="$1"
    shift || true
    [[ $# -gt 0 ]] || return 1

    local normalized_text
    normalized_text=$(hint_normalize_app_match_text "$text")
    [[ -n "$normalized_text" ]] || return 1

    local candidate normalized_candidate
    for candidate in "$@"; do
        normalized_candidate=$(hint_normalize_app_match_text "$candidate")
        [[ ${#normalized_candidate} -ge 4 ]] || continue
        if [[ "$normalized_text" == "$normalized_candidate" || "$normalized_text" == *"$normalized_candidate"* ]]; then
            return 0
        fi
    done

    return 1
}

# shellcheck disable=SC2329
hint_collect_installed_gui_app_match_texts() {
    local -a app_roots=(
        "/Applications"
        "/Applications/Setapp"
        "/Applications/Utilities"
        "$HOME/Applications"
        "/Library/Input Methods"
        "$HOME/Library/Input Methods"
        "$HOME/Library/Application Support/Setapp/Applications"
    )

    local app_root app_path app_name info value
    for app_root in "${app_roots[@]}"; do
        [[ -d "$app_root" ]] || continue
        while IFS= read -r -d '' app_path; do
            [[ -n "$app_path" ]] || continue

            app_name="${app_path##*/}"
            app_name="${app_name%.app}"
            printf '%s\n' "$app_name"

            info="$app_path/Contents/Info.plist"
            [[ -f "$info" ]] || continue
            for value in \
                "$(plutil -extract CFBundleIdentifier raw "$info" 2> /dev/null || echo "")" \
                "$(plutil -extract CFBundleName raw "$info" 2> /dev/null || echo "")" \
                "$(plutil -extract CFBundleDisplayName raw "$info" 2> /dev/null || echo "")"; do
                [[ -n "$value" && "$value" != "(null)" ]] && printf '%s\n' "$value"
            done
        done < <(run_with_timeout 2 find "$app_root" -maxdepth 2 -name "*.app" -print0 2> /dev/null || true)
    done

    local -a cask_roots=(
        "/opt/homebrew/Caskroom"
        "/usr/local/Caskroom"
    )

    local cask_root cask_dir cask_name
    for cask_root in "${cask_roots[@]}"; do
        [[ -d "$cask_root" ]] || continue
        while IFS= read -r -d '' cask_dir; do
            [[ -n "$cask_dir" ]] || continue
            cask_name="${cask_dir##*/}"
            printf '%s\n' "$cask_name"
        done < <(run_with_timeout 1 find "$cask_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null || true)
    done
}

# shellcheck disable=SC2329
hint_dotdir_owned_by_installed_gui_app() {
    local installed_app_texts="$1"
    shift || true
    [[ -n "$installed_app_texts" && $# -gt 0 ]] || return 1

    local value
    while IFS= read -r value; do
        [[ -n "$value" ]] || continue
        if hint_dotdir_candidate_matches_text "$value" "$@"; then
            return 0
        fi
    done <<< "$installed_app_texts"

    return 1
}

# shellcheck disable=SC2329
record_project_artifact_hint() {
    local path="$1"

    PROJECT_ARTIFACT_HINT_COUNT=$((PROJECT_ARTIFACT_HINT_COUNT + 1))

    if [[ ${#PROJECT_ARTIFACT_HINT_EXAMPLES[@]} -lt 2 ]]; then
        PROJECT_ARTIFACT_HINT_EXAMPLES+=("${path/#$HOME/~}")
    fi

    local sample_max=3
    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -ge $sample_max ]]; then
        PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=true
        return 0
    fi

    local timeout_seconds="0.8"
    local size_kb=""
    if size_kb=$(hint_get_path_size_kb_with_timeout "$path" "$timeout_seconds"); then
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
            PROJECT_ARTIFACT_HINT_ESTIMATED_KB=$((PROJECT_ARTIFACT_HINT_ESTIMATED_KB + size_kb))
            PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=$((PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES + 1))
        else
            PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=true
        fi
    else
        PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=true
    fi

    return 0
}

# shellcheck disable=SC2329
is_quick_purge_project_root() {
    mole_purge_is_project_root "$1"
}

# shellcheck disable=SC2329
probe_project_artifact_hints() {
    PROJECT_ARTIFACT_HINT_DETECTED=false
    PROJECT_ARTIFACT_HINT_COUNT=0
    PROJECT_ARTIFACT_HINT_TRUNCATED=false
    PROJECT_ARTIFACT_HINT_EXAMPLES=()
    PROJECT_ARTIFACT_HINT_ESTIMATED_KB=0
    PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=0
    PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false

    local max_projects=200
    local max_projects_per_root=0
    local max_nested_per_project=120
    local max_matches=12

    local -a target_names=()
    while IFS= read -r target_name; do
        [[ -n "$target_name" ]] && target_names+=("$target_name")
    done < <(mole_purge_quick_hint_target_names)

    local -a scan_roots=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && scan_roots+=("$path")
    done < <(load_quick_purge_hint_paths)

    [[ ${#scan_roots[@]} -eq 0 ]] && return 0

    # Fairness: avoid one very large root exhausting the entire scan budget.
    if [[ $max_projects_per_root -le 0 ]]; then
        max_projects_per_root=$(((max_projects + ${#scan_roots[@]} - 1) / ${#scan_roots[@]}))
        [[ $max_projects_per_root -lt 25 ]] && max_projects_per_root=25
    fi
    [[ $max_projects_per_root -gt $max_projects ]] && max_projects_per_root=$max_projects

    local nullglob_was_set=0
    if shopt -q nullglob; then
        nullglob_was_set=1
    fi
    shopt -s nullglob

    local scanned_projects=0
    local stop_scan=false
    local root project_dir nested_dir target_name candidate

    for root in "${scan_roots[@]}"; do
        [[ -d "$root" ]] || continue
        local root_projects_scanned=0

        if is_quick_purge_project_root "$root"; then
            scanned_projects=$((scanned_projects + 1))
            root_projects_scanned=$((root_projects_scanned + 1))
            if [[ $scanned_projects -gt $max_projects ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                stop_scan=true
                break
            fi

            for target_name in "${target_names[@]}"; do
                candidate="$root/$target_name"
                if [[ -d "$candidate" ]]; then
                    record_project_artifact_hint "$candidate"
                fi
            done
        fi
        [[ "$stop_scan" == "true" ]] && break

        if [[ $root_projects_scanned -ge $max_projects_per_root ]]; then
            PROJECT_ARTIFACT_HINT_TRUNCATED=true
            continue
        fi

        for project_dir in "$root"/*/; do
            [[ -d "$project_dir" ]] || continue
            project_dir="${project_dir%/}"

            local project_name
            project_name=$(basename "$project_dir")
            [[ "$project_name" == .* ]] && continue

            if [[ $root_projects_scanned -ge $max_projects_per_root ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                break
            fi

            scanned_projects=$((scanned_projects + 1))
            root_projects_scanned=$((root_projects_scanned + 1))
            if [[ $scanned_projects -gt $max_projects ]]; then
                PROJECT_ARTIFACT_HINT_TRUNCATED=true
                stop_scan=true
                break
            fi

            for target_name in "${target_names[@]}"; do
                candidate="$project_dir/$target_name"
                if [[ -d "$candidate" ]]; then
                    record_project_artifact_hint "$candidate"
                fi
            done
            [[ "$stop_scan" == "true" ]] && break

            local nested_count=0
            for nested_dir in "$project_dir"/*/; do
                [[ -d "$nested_dir" ]] || continue
                nested_dir="${nested_dir%/}"

                local nested_name
                nested_name=$(basename "$nested_dir")
                [[ "$nested_name" == .* ]] && continue

                case "$nested_name" in
                    node_modules | target | build | dist | DerivedData | Pods)
                        continue
                        ;;
                esac

                nested_count=$((nested_count + 1))
                if [[ $nested_count -gt $max_nested_per_project ]]; then
                    break
                fi

                for target_name in "${target_names[@]}"; do
                    candidate="$nested_dir/$target_name"
                    if [[ -d "$candidate" ]]; then
                        record_project_artifact_hint "$candidate"
                    fi
                done

                [[ "$stop_scan" == "true" ]] && break
            done

            [[ "$stop_scan" == "true" ]] && break
        done

        [[ "$stop_scan" == "true" ]] && break
    done

    if [[ $nullglob_was_set -eq 0 ]]; then
        shopt -u nullglob
    fi

    if [[ $PROJECT_ARTIFACT_HINT_COUNT -gt 0 ]]; then
        PROJECT_ARTIFACT_HINT_DETECTED=true
    fi

    # Preserve a compact display hint if candidate count is large, but do not
    # stop scanning early solely because we exceeded this threshold.
    if [[ $PROJECT_ARTIFACT_HINT_COUNT -gt $max_matches ]]; then
        PROJECT_ARTIFACT_HINT_TRUNCATED=true
    fi

    return 0
}

# shellcheck disable=SC2329
show_system_data_hint_notice() {
    local min_gb=2
    local timeout_seconds="0.8"
    local max_hits=3

    local threshold_kb=$((min_gb * 1024 * 1024))
    local -a clue_labels=()
    local -a clue_sizes=()
    local -a clue_paths=()

    local -a labels=(
        "Xcode DerivedData"
        "Xcode Archives"
        "iPhone backups"
        "Simulator data"
        "Docker Desktop data"
        "Mail data"
    )
    local -a paths=(
        "$HOME/Library/Developer/Xcode/DerivedData"
        "$HOME/Library/Developer/Xcode/Archives"
        "$HOME/Library/Application Support/MobileSync/Backup"
        "$HOME/Library/Developer/CoreSimulator/Devices"
        "$HOME/Library/Containers/com.docker.docker/Data"
        "$HOME/Library/Mail"
    )

    local i
    for i in "${!paths[@]}"; do
        local path="${paths[$i]}"
        [[ -d "$path" ]] || continue

        local size_kb=""
        if size_kb=$(hint_get_path_size_kb_with_timeout "$path" "$timeout_seconds"); then
            if [[ "$size_kb" -ge "$threshold_kb" ]]; then
                clue_labels+=("${labels[$i]}")
                clue_sizes+=("$size_kb")
                clue_paths+=("${path/#$HOME/~}")
                if [[ ${#clue_labels[@]} -ge $max_hits ]]; then
                    break
                fi
            fi
        fi
    done

    if [[ ${#clue_labels[@]} -eq 0 ]]; then
        note_activity
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No common System Data clues detected"
        return 0
    fi

    note_activity

    for i in "${!clue_labels[@]}"; do
        local human_size
        human_size=$(bytes_to_human "$((clue_sizes[i] * 1024))")
        echo -e "  ${GREEN}${ICON_LIST}${NC} ${clue_labels[$i]}: ${human_size}"
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} Path: ${GRAY}${clue_paths[$i]}${NC}"
    done
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Review: mo analyze, Device backups, docker system df"
}

# shellcheck disable=SC2329
show_project_artifact_hint_notice() {
    probe_project_artifact_hints

    if [[ "$PROJECT_ARTIFACT_HINT_DETECTED" != "true" ]]; then
        return 0
    fi

    note_activity

    local hint_count_label="$PROJECT_ARTIFACT_HINT_COUNT"
    [[ "$PROJECT_ARTIFACT_HINT_TRUNCATED" == "true" ]] && hint_count_label="${hint_count_label}+"

    local example_text=""
    if [[ ${#PROJECT_ARTIFACT_HINT_EXAMPLES[@]} -gt 0 ]]; then
        example_text="${PROJECT_ARTIFACT_HINT_EXAMPLES[0]}"
        if [[ ${#PROJECT_ARTIFACT_HINT_EXAMPLES[@]} -gt 1 ]]; then
            example_text+=", ${PROJECT_ARTIFACT_HINT_EXAMPLES[1]}"
        fi
    fi

    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -gt 0 ]]; then
        local estimate_human
        estimate_human=$(bytes_to_human "$((PROJECT_ARTIFACT_HINT_ESTIMATED_KB * 1024))")

        local estimate_is_partial="$PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL"
        if [[ "$PROJECT_ARTIFACT_HINT_TRUNCATED" == "true" ]] || [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -lt $PROJECT_ARTIFACT_HINT_COUNT ]]; then
            estimate_is_partial=true
        fi

        if [[ "$estimate_is_partial" == "true" ]]; then
            echo -e "  ${GREEN}${ICON_LIST}${NC} ${GREEN}${hint_count_label}${NC} candidates, at least ${estimate_human} sampled from ${PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES} items"
        else
            echo -e "  ${GREEN}${ICON_LIST}${NC} ${GREEN}${hint_count_label}${NC} candidates, sampled ${estimate_human}"
        fi
    else
        echo -e "  ${GREEN}${ICON_LIST}${NC} ${GREEN}${hint_count_label}${NC} candidates"
    fi

    if [[ -n "$example_text" ]]; then
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} Examples: ${GRAY}${example_text}${NC}"
    fi
    local review_command="mo purge"
    if [[ $PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES -gt 0 && $PROJECT_ARTIFACT_HINT_ESTIMATED_KB -eq 0 ]]; then
        review_command="mo purge --include-empty"
    fi
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Review: ${review_command}"
}

# shellcheck disable=SC2329
show_user_launch_agent_hint_notice() {
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    [[ -d "$launch_agents_dir" ]] || return 0

    local max_hits=3
    local -a labels=()
    local -a reasons=()
    local -a targets=()
    local plist

    while IFS= read -r -d '' plist; do
        local filename
        filename=$(basename "$plist")
        [[ "$filename" == com.apple.* ]] && continue

        local reason=""
        local target=""
        local program=""
        local associated=""

        program=$(hint_extract_launch_agent_program_path "$plist")
        if [[ -z "$program" ]] && hint_launch_agent_has_mach_services "$plist"; then
            continue
        fi
        if [[ -n "$program" ]] && hint_is_system_binary "$program"; then
            continue
        fi
        if [[ -n "$program" ]] && hint_is_app_scoped_launch_target "$program" && [[ ! -e "$program" ]]; then
            reason="Missing app/helper target"
            target="${program/#$HOME/~}"
        else
            associated=$(hint_extract_launch_agent_associated_bundle "$plist")
            if [[ -n "$associated" ]] && ! hint_launch_agent_bundle_exists "$associated"; then
                reason="Associated app not found"
                target="$associated"
            fi
        fi

        if [[ -n "$reason" ]]; then
            labels+=("$filename")
            reasons+=("$reason")
            targets+=("$target")
            if [[ ${#labels[@]} -ge $max_hits ]]; then
                break
            fi
        fi
    done < <(find "$launch_agents_dir" -maxdepth 1 -name "*.plist" -print0 2> /dev/null)

    [[ ${#labels[@]} -eq 0 ]] && return 0

    note_activity

    local i
    for i in "${!labels[@]}"; do
        echo -e "  ${GREEN}${ICON_LIST}${NC} Potential stale login item: ${labels[$i]}"
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ${reasons[$i]}: ${GRAY}${targets[$i]}${NC}"
    done
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Review: open ~/Library/LaunchAgents and remove only items you recognize"
}

readonly ORPHAN_DOTDIR_KNOWN_SAFE=(
    # Shell
    ".bash_history" ".bash_profile" ".bash_sessions" ".bashrc"
    ".zshrc" ".zsh_history" ".zsh_sessions" ".zprofile" ".zshenv" ".zlogout" ".zcompdump"
    ".profile" ".inputrc" ".hushlogin"
    ".oh-my-zsh" ".zinit" ".zplug" ".antigen" ".p10k.zsh"
    ".config" ".local" ".cache"
    # Security
    ".ssh" ".gnupg" ".gpg" ".pass""word-store"
    # Git
    ".gitconfig" ".gitignore_global" ".git-credentials" ".gitattributes_global"
    # Language tools (Mole handles their caches separately)
    ".pyenv" ".rbenv" ".nvm" ".nodenv" ".goenv" ".jenv"
    ".rustup" ".cargo" ".ghcup" ".stack" ".cabal"
    ".sdkman" ".jabba" ".asdf" ".mise" ".rtx" ".volta" ".fnm"
    ".deno" ".bun"
    # Package managers
    ".npm" ".yarn" ".pnpm" ".bundle" ".gem"
    ".composer" ".nuget" ".pub-cache"
    ".m2" ".gradle" ".sbt" ".ivy2" ".lein"
    ".hex" ".mix" ".opam" ".cpan" ".cpanm"
    ".conda" ".virtualenvs" ".pipx"
    # Cloud / devops
    ".docker" ".kube" ".minikube" ".helm"
    ".aws" ".azure" ".terraform" ".vagrant"
    # Editors / IDEs
    ".vim" ".vimrc" ".viminfo" ".emacs" ".emacs.d" ".doom.d" ".nano" ".nanorc"
    ".vscode" ".cursor" ".atom"
    # AI tools
    ".claude" ".copilot" ".ollama"
    # macOS system
    ".Trash" ".Trashes" ".CFUserTextEncoding" ".DS_Store" ".cups" ".dropbox"
    # Mobile / native dev
    ".android" ".cocoapods" ".fastlane" ".expo" ".react-native" ".swiftpm"
    # Terminal / misc
    ".tmux" ".screen" ".wget-hsts" ".curlrc" ".netrc" ".wgetrc"
    ".putty"
    ".lesshst" ".python_history" ".node_repl_history"
    ".irb_history" ".pry_history"
    ".jupyter" ".ipython" ".matplotlib" ".keras" ".torch"
    ".psql_history" ".mysql_history" ".sqlite_history" ".rediscli_history" ".mongo" ".dbshell"
    # Homebrew / VCS
    ".homebrew" ".hg" ".hgrc" ".svn" ".bazaar"
    # Fly.io / Gemini (Tang uses these)
    ".fly" ".gemini"
)

# Standard locations for installed GUI apps. Overridable from tests.
_MOLE_DOTDIR_OWNER_APP_ROOTS=(
    "/Applications"
    "/Applications/Setapp"
    "$HOME/Applications"
)

# Emit every alnum token found in installed .app filenames + brew casks,
# lowercased, one per line. Caller filters/dedups.
# shellcheck disable=SC2329
_dotdir_owner_collect_tokens() {
    local root entry name
    for root in "${_MOLE_DOTDIR_OWNER_APP_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        for entry in "$root"/*.app; do
            [[ -e "$entry" ]] || continue
            name=$(basename "$entry")
            name="${name%.app}"
            printf '%s\n' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '\n'
        done
    done

    if command -v brew > /dev/null 2>&1; then
        local cask_list=""
        cask_list=$(HOMEBREW_NO_ENV_HINTS=1 run_with_timeout 5 brew list --cask 2> /dev/null) || true
        if [[ -n "$cask_list" ]]; then
            printf '%s\n' "$cask_list" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '\n'
        fi
    fi
}

# Return 0 if any ≥4-char token from `name` matches a token harvested from
# installed `.app` bundles or Homebrew casks. Cached for 5 minutes. Short
# tokens (<4 chars) on either side are ignored to avoid false matches like
# `.ai-old` vs `AI.app`. See issue #872.
# shellcheck disable=SC2329
dotdir_has_owning_gui_app() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    [[ ${#name} -lt 4 ]] && return 1

    local cache_dir="$HOME/.cache/mole"
    local cache_file="$cache_dir/installed_app_tokens_cache"
    local cache_ttl=300
    local now
    now=$(date +%s)

    local rebuild=1
    if [[ -f "$cache_file" ]]; then
        local mtime
        mtime=$(get_file_mtime "$cache_file" 2> /dev/null || echo 0)
        if [[ -n "$mtime" ]] && [[ $((now - mtime)) -lt $cache_ttl ]]; then
            rebuild=0
        fi
    fi
    if [[ $rebuild -eq 1 ]]; then
        ensure_user_dir "$cache_dir" 2> /dev/null || true
        _dotdir_owner_collect_tokens 2> /dev/null |
            LC_ALL=C awk 'length($0) >= 4' |
            LC_ALL=C sort -u > "$cache_file" 2> /dev/null || return 1
    fi
    [[ -s "$cache_file" ]] || return 1

    local name_lower
    name_lower=$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    local tok
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        [[ ${#tok} -ge 4 ]] || continue
        if LC_ALL=C grep -Fxq "$tok" "$cache_file" 2> /dev/null; then
            return 0
        fi
    done < <(printf '%s\n' "$name_lower" | LC_ALL=C tr -cs 'a-z0-9' '\n')

    return 1
}

# Detect ~/.<dir> directories that may belong to uninstalled CLI tools.
# shellcheck disable=SC2329
show_orphan_dotdir_hint_notice() {
    local max_hits=5
    local age_days="${MOLE_DOTDIR_ORPHAN_AGE_DAYS:-60}"
    local now
    now=$(date +%s)

    local -a labels=()
    local -a details=()
    local installed_gui_app_texts=""
    local installed_gui_app_texts_loaded=false

    while IFS= read -r dotdir; do
        [[ -d "$dotdir" ]] || continue
        local basename
        basename=$(basename "$dotdir")

        local is_safe=false
        local safe_name
        for safe_name in "${ORPHAN_DOTDIR_KNOWN_SAFE[@]}"; do
            if [[ "$basename" == "$safe_name" ]]; then
                is_safe=true
                break
            fi
        done
        [[ "$is_safe" == "true" ]] && continue

        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$dotdir"; then
            continue
        fi

        local mtime
        mtime=$(get_file_mtime "$dotdir" 2> /dev/null) || continue
        local age_d=$(((now - mtime) / 86400))
        [[ $age_d -lt $age_days ]] && continue

        local name="${basename#.}"
        local -a candidates=("$name")
        local dehyphen="${name//-/_}"
        [[ "$dehyphen" != "$name" ]] && candidates+=("$dehyphen")
        local stripped="${name//-/}"
        [[ "$stripped" != "$name" && "$stripped" != "$dehyphen" ]] && candidates+=("$stripped")
        local no_suffix="${name%-cli}"
        [[ "$no_suffix" != "$name" ]] && candidates+=("$no_suffix")
        no_suffix="${name%-temp}"
        [[ "$no_suffix" != "$name" ]] && candidates+=("$no_suffix")
        no_suffix="${name%-data}"
        [[ "$no_suffix" != "$name" ]] && candidates+=("$no_suffix")

        local has_binary=false
        local c
        for c in "${candidates[@]}"; do
            if command -v "$c" > /dev/null 2>&1; then
                has_binary=true
                break
            fi
        done
        [[ "$has_binary" == "true" ]] && continue

        if [[ "$installed_gui_app_texts_loaded" != "true" ]]; then
            installed_gui_app_texts=$(hint_collect_installed_gui_app_match_texts)
            installed_gui_app_texts_loaded=true
        fi
        if hint_dotdir_owned_by_installed_gui_app "$installed_gui_app_texts" "${candidates[@]}"; then
            continue
        fi

        if [[ -d "$HOME/Library/LaunchAgents" ]]; then
            if run_with_timeout 2 grep -rlq "$basename" "$HOME/Library/LaunchAgents/" 2> /dev/null; then
                continue
            fi
        fi

        if dotdir_has_owning_gui_app "$name"; then
            continue
        fi

        local size_human=""
        local size_kb
        if size_kb=$(hint_get_path_size_kb_with_timeout "$dotdir" 0.8); then
            size_human=" ($(bytes_to_human $((size_kb * 1024))))"
        fi

        # shellcheck disable=SC2088
        labels+=("~/${basename}${size_human}")
        details+=("No matching binary in PATH, last modified ${age_d} days ago")

        if [[ ${#labels[@]} -ge $max_hits ]]; then
            break
        fi
    done < <(run_with_timeout 3 find "$HOME" -maxdepth 1 -mindepth 1 -type d -name '.*' 2> /dev/null | LC_ALL=C sort)

    [[ ${#labels[@]} -eq 0 ]] && return 0

    note_activity

    local i
    for i in "${!labels[@]}"; do
        echo -e "  ${GREEN}${ICON_LIST}${NC} Potential orphan dotfile: ${labels[$i]}"
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ${details[$i]}"
    done
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Review manually before removing any ~/.<dir> directory"
}
