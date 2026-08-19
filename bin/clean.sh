#!/bin/bash
# Mole - Clean command.
# Runs cleanup modules with optional sudo.
# Supports dry-run and whitelist.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

source "$SCRIPT_DIR/../lib/core/sudo.sh"
source "$SCRIPT_DIR/../lib/clean/brew.sh"
source "$SCRIPT_DIR/../lib/clean/caches.sh"
source "$SCRIPT_DIR/../lib/clean/apps.sh"
source "$SCRIPT_DIR/../lib/clean/dev.sh"
source "$SCRIPT_DIR/../lib/clean/app_caches.sh"
source "$SCRIPT_DIR/../lib/clean/hints.sh"
source "$SCRIPT_DIR/../lib/clean/system.sh"
source "$SCRIPT_DIR/../lib/clean/user.sh"

SYSTEM_CLEAN=false
DRY_RUN=false
if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
    DRY_RUN=true
fi
PROTECT_FINDER_METADATA=false
EXTERNAL_VOLUME_TARGET=""
IS_M_SERIES=$([[ "$(uname -m)" == "arm64" ]] && echo "true" || echo "false")

# Whitelist and preview belong to the invoking user even when the whole
# command runs as root. Root dry-runs stage preview content in a root-owned
# file and publish it through an invoking-user process so user-controlled
# symlinks are never opened for writing with root privileges. See #1210.
MOLE_USER_HOME="$(get_invoking_home)"
[[ -n "$MOLE_USER_HOME" ]] || MOLE_USER_HOME="$HOME"

load_mole_whitelist "$MOLE_USER_HOME"

CLEAN_PREVIEW_FINAL_FILE="$MOLE_USER_HOME/.config/mole/clean-list.txt"
CLEAN_PREVIEW_STAGING_FILE=""
CLEAN_PREVIEW_LEDGER_FILE=""
EXPORT_LIST_FILE="$CLEAN_PREVIEW_FINAL_FILE"
CURRENT_SECTION=""
readonly PROTECTED_SW_DOMAINS=(
    # Web editors
    "capcut.com"
    "photopea.com"
    "pixlr.com"
    # Google Workspace (offline mode)
    "docs.google.com"
    "sheets.google.com"
    "slides.google.com"
    "drive.google.com"
    "mail.google.com"
    # Code platforms (offline/PWA)
    "github.com"
    "gitlab.com"
    "codepen.io"
    "codesandbox.io"
    "replit.com"
    "stackblitz.com"
    # Collaboration tools (offline/PWA)
    "notion.so"
    "figma.com"
    "linear.app"
    "excalidraw.com"
)

prepare_clean_preview_file() {
    EXPORT_LIST_FILE="$CLEAN_PREVIEW_FINAL_FILE"
    CLEAN_PREVIEW_STAGING_FILE=""
    CLEAN_PREVIEW_LEDGER_FILE=""

    if is_root_user && [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        ensure_mole_temp_root || return 1
        local root_temp_dir="$MOLE_RESOLVED_TMPDIR"

        CLEAN_PREVIEW_STAGING_FILE=$(umask 077 && mktemp "$root_temp_dir/mole.clean-preview.XXXXXX") || return 1
        [[ -f "$CLEAN_PREVIEW_STAGING_FILE" && ! -L "$CLEAN_PREVIEW_STAGING_FILE" && -O "$CLEAN_PREVIEW_STAGING_FILE" ]] || return 1
        MOLE_TEMP_FILES+=("$CLEAN_PREVIEW_STAGING_FILE")
        EXPORT_LIST_FILE="$CLEAN_PREVIEW_STAGING_FILE"
    else
        ensure_user_file "$EXPORT_LIST_FILE"
    fi

    CLEAN_PREVIEW_LEDGER_FILE=$(create_temp_file) || return 1
    [[ -f "$CLEAN_PREVIEW_LEDGER_FILE" && ! -L "$CLEAN_PREVIEW_LEDGER_FILE" ]] || return 1
    : > "$CLEAN_PREVIEW_LEDGER_FILE"
}

run_clean_preview_as_invoking_user() {
    /usr/bin/sudo -u "$SUDO_USER" -- "$@"
}

publish_clean_preview_file() {
    [[ -n "$CLEAN_PREVIEW_STAGING_FILE" ]] || return 0
    [[ -f "$CLEAN_PREVIEW_STAGING_FILE" && ! -L "$CLEAN_PREVIEW_STAGING_FILE" && -O "$CLEAN_PREVIEW_STAGING_FILE" ]] || return 1
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]] || return 1

    local final_dir
    final_dir=$(dirname "$CLEAN_PREVIEW_FINAL_FILE")
    run_clean_preview_as_invoking_user /bin/mkdir -p "$final_dir" 2> /dev/null || return 1
    if ! /bin/cat "$CLEAN_PREVIEW_STAGING_FILE" |
        run_clean_preview_as_invoking_user /usr/bin/tee "$CLEAN_PREVIEW_FINAL_FILE" > /dev/null; then
        return 1
    fi

    EXPORT_LIST_FILE="$CLEAN_PREVIEW_FINAL_FILE"
    return 0
}

if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            PROTECT_FINDER_METADATA=true
            break
        fi
    done
fi

# Section tracking and summary counters.
total_items=0
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0
PROJECT_ARTIFACT_HINT_DETECTED=false
PROJECT_ARTIFACT_HINT_COUNT=0
PROJECT_ARTIFACT_HINT_TRUNCATED=false
PROJECT_ARTIFACT_HINT_EXAMPLES=()
PROJECT_ARTIFACT_HINT_ESTIMATED_KB=0
PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=0
PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false
declare -a DRY_RUN_SEEN_IDENTITIES=()
DRY_RUN_TOTAL_PARTIAL=false
declare -a DEFERRED_CLEANUP_FAMILIES=()
DEFERRED_CLEANUP_FAMILIES_FILE=""

# shellcheck disable=SC2329
note_activity() {
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Record expected process-state skips without turning every protected target
# into a separate warning row. Unknown process state is not recorded here and
# remains visible at the call site.
# shellcheck disable=SC2329
defer_cleanup_family() {
    local family="${1:-}"
    local existing
    [[ -n "$family" ]] || return 0

    if [[ ${#DEFERRED_CLEANUP_FAMILIES[@]} -gt 0 ]]; then
        for existing in "${DEFERRED_CLEANUP_FAMILIES[@]}"; do
            [[ "$existing" == "$family" ]] && return 0
        done
    fi

    DEFERRED_CLEANUP_FAMILIES+=("$family")
    if [[ -n "${DEFERRED_CLEANUP_FAMILIES_FILE:-}" &&
        -f "$DEFERRED_CLEANUP_FAMILIES_FILE" &&
        ! -L "$DEFERRED_CLEANUP_FAMILIES_FILE" ]]; then
        printf '%s\0' "$family" >> "$DEFERRED_CLEANUP_FAMILIES_FILE"
    fi
    debug_log "Deferred cleanup while active: $family"
}

# The Cloud & Office section runs in a timeout worker, so its array writes stay
# in that child shell. Replay its file-backed records before rendering the
# parent summary.
sync_deferred_cleanup_families() {
    local record_file="${DEFERRED_CLEANUP_FAMILIES_FILE:-}"
    local family
    [[ -n "$record_file" && -f "$record_file" && ! -L "$record_file" ]] || return 0

    DEFERRED_CLEANUP_FAMILIES_FILE=""
    while IFS= read -r -d '' family; do
        defer_cleanup_family "$family"
    done < "$record_file"
    DEFERRED_CLEANUP_FAMILIES_FILE="$record_file"
}

format_deferred_cleanup_families() {
    local family
    local output=""
    for family in "${DEFERRED_CLEANUP_FAMILIES[@]}"; do
        [[ -n "$output" ]] && output+=", "
        output+="$family"
    done
    printf '%s\n' "$output"
}

# shellcheck disable=SC2329
register_dry_run_cleanup_target() {
    # Full clean runs deduplicate the file-backed ledger in one linear pass.
    # Avoid an O(n²) Bash array scan while candidates are still being found.
    if [[ -n "${CLEAN_PREVIEW_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
        return 0
    fi

    local path="$1"
    local identity
    identity=$(mole_path_identity "$path")

    if [[ ${#DRY_RUN_SEEN_IDENTITIES[@]} -gt 0 ]] && mole_identity_in_list "$identity" "${DRY_RUN_SEEN_IDENTITIES[@]}"; then
        return 1
    fi

    DRY_RUN_SEEN_IDENTITIES+=("$identity")
    return 0
}

# Append one candidate to the dry-run ledger. Final rendering deduplicates the
# shared file, so timeout subprocess paths survive without an O(n²) hot loop.
# Fields are NUL-delimited to preserve whitespace in paths.
# Args: path, size_kb, item_count, size_known
append_dry_run_cleanup_target() {
    local path="$1"
    local size_kb="${2:-0}"
    local item_count="${3:-1}"
    local size_known="${4:-true}"
    local identity
    identity=$(mole_path_identity "$path")

    [[ "$size_kb" =~ ^[0-9]+$ ]] || {
        size_kb=0
        size_known=false
    }
    [[ "$item_count" =~ ^[0-9]+$ && "$item_count" -gt 0 ]] || item_count=1
    [[ "$size_known" == "true" || "$size_known" == "false" ]] || size_known=false

    if [[ -n "${CLEAN_PREVIEW_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_LEDGER_FILE" && ! -L "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$identity" "$size_kb" "$item_count" "$size_known" "${CURRENT_SECTION:-Uncategorized}" "$path" \
            >> "$CLEAN_PREVIEW_LEDGER_FILE"
        return 0
    fi

    # Keep focused function tests and sourced-module callers useful even when
    # start_cleanup has not prepared the full ledger.
    if [[ -n "${EXPORT_LIST_FILE:-}" ]]; then
        ensure_user_file "$EXPORT_LIST_FILE"
        if [[ "$size_known" == "true" ]]; then
            echo "$path  # $(bytes_to_human "$((size_kb * 1024))")" >> "$EXPORT_LIST_FILE"
        else
            echo "$path  # size unknown" >> "$EXPORT_LIST_FILE"
        fi
    fi
}

# Validate and append a candidate in one call. Focused callers without a
# prepared ledger retain the legacy in-memory duplicate check.
record_dry_run_cleanup_target() {
    local path="$1"
    if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$path" 2> /dev/null; then
        return 1
    fi
    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path" 2> /dev/null; then
        return 1
    fi
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        return 1
    fi
    # Keep preview eligibility identical to real cleanup (#1390 / PR #1391).
    if declare -f _mole_should_refuse_live_user_cache_path > /dev/null 2>&1 &&
        _mole_should_refuse_live_user_cache_path "$path"; then
        return 1
    fi
    if declare -f _mole_is_sqlite_database_path > /dev/null 2>&1 &&
        _mole_is_sqlite_database_path "$path" &&
        declare -f _mole_sqlite_database_in_use > /dev/null 2>&1; then
        local sqlite_state=0
        _mole_sqlite_database_in_use "$path" || sqlite_state=$?
        if [[ $sqlite_state -eq 0 || $sqlite_state -eq 2 ]]; then
            return 1
        fi
    fi

    if [[ -z "${CLEAN_PREVIEW_LEDGER_FILE:-}" || ! -f "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
        register_dry_run_cleanup_target "$path" || return 1
    fi
    append_dry_run_cleanup_target "$@"
}

# Emit the first complete ledger record for each path identity. Perl keeps the
# normal path linear for large clean previews; the Bash fallback preserves the
# same NUL-safe format on systems without Perl.
emit_deduplicated_dry_run_ledger() {
    if [[ -z "${CLEAN_PREVIEW_LEDGER_FILE:-}" || ! -f "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
        return 0
    fi

    local perl_bin=""
    perl_bin=$(command -v perl 2> /dev/null || true)
    if [[ -n "$perl_bin" && -x "$perl_bin" ]]; then
        # shellcheck disable=SC2016  # Embedded Perl uses Perl variables inside single quotes.
        "$perl_bin" -e '
            use strict;
            use warnings;
            binmode STDIN;
            binmode STDOUT;
            local $/ = "\0";
            my %seen;
            while (defined(my $identity = <STDIN>)) {
                chomp $identity;
                my @record = ($identity);
                for (1 .. 5) {
                    my $field = <STDIN>;
                    exit 0 unless defined $field;
                    chomp $field;
                    push @record, $field;
                }
                next if $seen{$identity}++;
                print join("\0", @record), "\0";
            }
        ' < "$CLEAN_PREVIEW_LEDGER_FILE"
        return 0
    fi

    local identity size_kb count size_known section path
    local -a seen_identities=()
    while IFS= read -r -d '' identity &&
        IFS= read -r -d '' size_kb &&
        IFS= read -r -d '' count &&
        IFS= read -r -d '' size_known &&
        IFS= read -r -d '' section &&
        IFS= read -r -d '' path; do
        if [[ ${#seen_identities[@]} -gt 0 ]] && mole_identity_in_list "$identity" "${seen_identities[@]}"; then
            continue
        fi
        seen_identities+=("$identity")
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$identity" "$size_kb" "$count" "$size_known" "$section" "$path"
    done < "$CLEAN_PREVIEW_LEDGER_FILE"
}

write_clean_preview_header() {
    cat > "$EXPORT_LIST_FILE" << EOF
# Mole Cleanup Preview - $(date '+%Y-%m-%d %H:%M:%S')
#
# How to protect files:
# 1. Copy any path below to ~/.config/mole/whitelist
# 2. Run: mo clean --whitelist
#
# Example:
#   /Users/*/Library/Caches/com.example.app
#

EOF
}

render_clean_preview_from_ledger() {
    write_clean_preview_header

    local identity size_kb count size_known section path
    local current_rendered_section=""
    local known_size_kb=0
    local rendered_items=0
    local rendered_categories=0
    local unknown_size_count=0
    local -a seen_sections=()

    if [[ -n "${CLEAN_PREVIEW_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
        while IFS= read -r -d '' identity &&
            IFS= read -r -d '' size_kb &&
            IFS= read -r -d '' count &&
            IFS= read -r -d '' size_known &&
            IFS= read -r -d '' section &&
            IFS= read -r -d '' path; do
            if [[ "$section" != "$current_rendered_section" ]]; then
                echo "" >> "$EXPORT_LIST_FILE"
                echo "=== $section ===" >> "$EXPORT_LIST_FILE"
                current_rendered_section="$section"
                if [[ ${#seen_sections[@]} -eq 0 ]] || ! mole_identity_in_list "$section" "${seen_sections[@]}"; then
                    seen_sections+=("$section")
                    rendered_categories=$((rendered_categories + 1))
                fi
            fi

            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
            local item_note=""
            [[ "$count" -gt 1 ]] && item_note=", $count items"
            if [[ "$size_known" == "true" ]]; then
                echo "$path  # $(bytes_to_human "$((size_kb * 1024))")$item_note" >> "$EXPORT_LIST_FILE"
            else
                echo "$path  # size unknown$item_note" >> "$EXPORT_LIST_FILE"
                unknown_size_count=$((unknown_size_count + 1))
            fi

            known_size_kb=$((known_size_kb + size_kb))
            rendered_items=$((rendered_items + count))
        done < <(emit_deduplicated_dry_run_ledger)
    fi

    total_size_cleaned=$known_size_kb
    files_cleaned=$rendered_items
    total_items=$rendered_categories
    if [[ "$unknown_size_count" -gt 0 ]]; then
        DRY_RUN_TOTAL_PARTIAL=true
    else
        DRY_RUN_TOTAL_PARTIAL=false
    fi
}

read_clean_sudo_choice() {
    local had_force_char=false
    local previous_force_char="${MOLE_READ_KEY_FORCE_CHAR:-}"
    if [[ ${MOLE_READ_KEY_FORCE_CHAR+x} ]]; then
        had_force_char=true
    fi

    export MOLE_READ_KEY_FORCE_CHAR=1
    local choice
    choice=$(read_key)

    if [[ "$had_force_char" == "true" ]]; then
        export MOLE_READ_KEY_FORCE_CHAR="$previous_force_char"
    else
        unset MOLE_READ_KEY_FORCE_CHAR
    fi

    printf '%s\n' "$choice"
}

read_clean_sudo_password_remainder() {
    local __remainder_var="$1"
    local remainder=""

    if [[ -r /dev/tty ]]; then
        IFS= read -r -s remainder < /dev/tty || true
    else
        IFS= read -r -s remainder || true
    fi

    printf -v "$__remainder_var" '%s' "$remainder"
}

# Seam for the interactive check so the authorization policy can be covered
# without allocating a pty.
clean_stdin_is_tty() {
    [[ -t 0 ]]
}

prompt_for_system_clean() {
    local sudo_cached="${1:-false}"
    local prompt_attempt=0
    local prompt_line="System caches need sudo."
    if [[ "$sudo_cached" == "true" ]]; then
        # A cached timestamp settles who the user is, not whether this run was
        # meant to sweep system caches. Keep asking; only the password step is
        # already done.
        prompt_line="System caches, admin access already active."
    fi
    while true; do
        echo -ne "${PURPLE}${ICON_ARROW}${NC} ${prompt_line} ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "

        local choice
        choice=$(read_clean_sudo_choice)

        # ESC aborts, Space skips, Enter (or any typed key, e.g. someone who
        # starts typing their password) proceeds to authentication.
        if [[ "$choice" == "QUIT" ]]; then
            echo -e " ${GRAY}Canceled${NC}"
            exit 0
        fi

        if [[ "$choice" == "SPACE" ]]; then
            echo -e " ${GRAY}Skipped${NC}"
            echo ""
            SYSTEM_CLEAN=false
            break
        elif [[ "$choice" == "ENTER" ]]; then
            printf "\r\033[K" # Clear the prompt line
            if ensure_sudo_session "System cleanup requires admin access"; then
                SYSTEM_CLEAN=true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                echo ""
            else
                SYSTEM_CLEAN=false
                echo ""
                echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
            fi
            break
        elif [[ "$choice" == CHAR:* ]]; then
            local typed_password="${choice#CHAR:}"
            local password_remainder=""
            read_clean_sudo_password_remainder password_remainder
            typed_password="${typed_password}${password_remainder}"

            printf "\r\033[K" # Clear the prompt line
            if ensure_sudo_session_with_password "$typed_password" "System cleanup requires admin access"; then
                SYSTEM_CLEAN=true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                echo ""
            else
                SYSTEM_CLEAN=false
                echo ""
                echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
            fi
            unset typed_password password_remainder
            break
        else
            prompt_attempt=$((prompt_attempt + 1))
            drain_pending_input 0.05
            if [[ $prompt_attempt -ge 2 ]]; then
                SYSTEM_CLEAN=false
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
                break
            fi
            printf "\r\033[K"
            echo -e "${YELLOW}${ICON_WARNING}${NC} Press Enter to continue, or Space to skip"
        fi
    done
}

CLEANUP_DONE=false
# shellcheck disable=SC2329
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    stop_inline_spinner 2> /dev/null || true

    cleanup_temp_files

    stop_sudo_session

    show_cursor
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

# IMPORTANT: This file overrides start_section / end_section from
# lib/core/base.sh by virtue of being sourced after it. The clean variant adds
# CURRENT_SECTION tracking, dry-run EXPORT_LIST_FILE writes, a section
# spinner stop, and idle-header recycling. See the cross-reference block in
# lib/core/base.sh and the differing purge variant in bin/purge.sh before
# changing any of these three.
#
# Idle-header recycling: an idle section used to erase its own header after
# the fact, which made all content below jump up two lines per idle section.
# Instead the header stays put and the NEXT start_section overwrites it in
# place, so the screen never moves vertically. Any output that is not a
# section header must clear a leftover idle header first via
# flush_idle_section_slot.
IDLE_SECTION_PENDING=0

flush_idle_section_slot() {
    if [[ "${IDLE_SECTION_PENDING:-0}" == "1" ]]; then
        IDLE_SECTION_PENDING=0
        safe_clear_lines 2 || true
    fi
}

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    if [[ "${IDLE_SECTION_PENDING:-0}" == "1" ]]; then
        # Overwrite the previous idle section's header line in place (the
        # pending flag is only ever set on an interactive ANSI terminal).
        IDLE_SECTION_PENDING=0
        printf '\033[1A\r\033[2K%b\n' "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
    else
        echo ""
        echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
    fi

    if [[ "$DRY_RUN" == "true" && -z "${CLEAN_PREVIEW_LEDGER_FILE:-}" ]]; then
        ensure_user_file "$EXPORT_LIST_FILE"
        echo "" >> "$EXPORT_LIST_FILE"
        echo "=== $1 ===" >> "$EXPORT_LIST_FILE"
    fi
}

end_section() {
    stop_section_spinner

    if [[ "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        # On an interactive ANSI terminal, leave the header on screen and let
        # the next start_section recycle its line, so idle sections disappear
        # without the erase-and-jump. Piped output keeps the explicit fallback
        # so logs stay self-describing. MO_DEBUG interleaves stderr lines that
        # line recycling would corrupt, so keep the fallback there too.
        if [[ -t 1 && "${MO_DEBUG:-}" != "1" ]] && is_ansi_supported 2> /dev/null; then
            IDLE_SECTION_PENDING=1
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to clean"
        fi
    else
        IDLE_SECTION_PENDING=0
    fi
    TRACK_SECTION=0
}

# shellcheck disable=SC2329
normalize_paths_for_cleanup() {
    local -a input_paths=("$@")

    local _normalized_cleanup_path=""
    _normalize_single_cleanup_path() {
        local raw_path="$1"
        local normalized="${raw_path%/}"
        [[ -z "$normalized" ]] && normalized="$raw_path"

        local gradle_caches_root="$HOME/.gradle/caches"
        case "$normalized" in
            "$gradle_caches_root"/*/groovy-dsl/*/* | "$gradle_caches_root"/*/kotlin-dsl/*/*)
                local rel version dsl_dir rest hash
                rel="${normalized#"$gradle_caches_root"/}"
                version="${rel%%/*}"
                rest="${rel#*/}"
                dsl_dir="${rest%%/*}"
                rest="${rest#*/}"
                hash="${rest%%/*}"
                if [[ -n "$version" && -n "$hash" &&
                    ("$dsl_dir" == "groovy-dsl" || "$dsl_dir" == "kotlin-dsl") ]]; then
                    _normalized_cleanup_path="$gradle_caches_root/$version/$dsl_dir/$hash"
                    return
                fi
                ;;
        esac

        _normalized_cleanup_path="$normalized"
    }

    # Fast path for large batches: O(n log n) via sort|awk instead of O(n²) bash loops.
    # Lex sort guarantees every parent path precedes its children, so a single-pass
    # awk can filter child paths by tracking only the last kept path.
    # Paths with embedded newlines cannot go through the newline-delimited pipeline;
    # they are output directly with null-byte delimiters and skipped by the sort pass.
    if [[ ${#input_paths[@]} -gt 50 ]]; then
        # The gradle-DSL collapse below is intentionally inlined (not a call to
        # _normalize_single_cleanup_path): this path runs for thousands of items
        # and per-item function-call overhead trips the large-batch time budget
        # in tests/regression.bats. Keep it in sync with that helper.
        local -a _fast_pipeline=()
        local _fast_path _fast_raw
        for _fast_path in "${input_paths[@]}"; do
            if [[ "$_fast_path" == *$'\n'* ]]; then
                printf '%s\0' "$_fast_path"
            else
                _fast_raw="$_fast_path"
                _fast_path="${_fast_path%/}"
                [[ -z "$_fast_path" ]] && _fast_path="$_fast_raw"
                local _gradle_caches_root="$HOME/.gradle/caches"
                case "$_fast_path" in
                    "$_gradle_caches_root"/*/groovy-dsl/*/* | "$_gradle_caches_root"/*/kotlin-dsl/*/*)
                        local _rel _version _dsl_dir _rest _hash
                        _rel="${_fast_path#"$_gradle_caches_root"/}"
                        _version="${_rel%%/*}"
                        _rest="${_rel#*/}"
                        _dsl_dir="${_rest%%/*}"
                        _rest="${_rest#*/}"
                        _hash="${_rest%%/*}"
                        if [[ -n "$_version" && -n "$_hash" &&
                            ("$_dsl_dir" == "groovy-dsl" || "$_dsl_dir" == "kotlin-dsl") ]]; then
                            _fast_path="$_gradle_caches_root/$_version/$_dsl_dir/$_hash"
                        fi
                        ;;
                esac
                _fast_pipeline+=("$_fast_path")
            fi
        done
        if [[ ${#_fast_pipeline[@]} -gt 0 ]]; then
            printf '%s\n' "${_fast_pipeline[@]}" |
                awk '{sub(/\/$/, ""); if ($0 != "") print}' |
                LC_ALL=C sort -u |
                awk 'BEGIN { last = "" } {
                    if (last != "" && substr($0, 1, length(last) + 1) == last "/") next
                    last = $0; print
                }' |
                while IFS= read -r _fast_path; do printf '%s\0' "$_fast_path"; done
        fi
        return
    fi

    local -a unique_paths=()

    for path in "${input_paths[@]}"; do
        local normalized
        _normalize_single_cleanup_path "$path"
        normalized="$_normalized_cleanup_path"
        local found=false
        if [[ ${#unique_paths[@]} -gt 0 ]]; then
            for existing in "${unique_paths[@]}"; do
                if [[ "$existing" == "$normalized" ]]; then
                    found=true
                    break
                fi
            done
        fi
        [[ "$found" == "true" ]] || unique_paths+=("$normalized")
    done

    # Paths with embedded newlines cannot safely go through the newline-delimited
    # sort pipeline. Collect them separately and append to result as-is.
    local -a pipeline_paths=()
    local -a passthrough_paths=()
    for path in "${unique_paths[@]}"; do
        if [[ "$path" == *$'\n'* ]]; then
            passthrough_paths+=("$path")
        else
            pipeline_paths+=("$path")
        fi
    done

    local sorted_paths
    if [[ ${#pipeline_paths[@]} -gt 0 ]]; then
        sorted_paths=$(printf '%s\n' "${pipeline_paths[@]}" | awk '{print length "|" $0}' | LC_ALL=C sort -n | cut -d'|' -f2-)
    else
        sorted_paths=""
    fi

    local -a result_paths=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local is_child=false
        if [[ ${#result_paths[@]} -gt 0 ]]; then
            for kept in "${result_paths[@]}"; do
                if [[ "$path" == "$kept" || "$path" == "$kept"/* ]]; then
                    is_child=true
                    break
                fi
            done
        fi
        [[ "$is_child" == "true" ]] || result_paths+=("$path")
    done <<< "$sorted_paths"

    # Append passthrough paths (newline-containing; not deduplicated against others).
    if [[ ${#passthrough_paths[@]} -gt 0 ]]; then
        result_paths+=("${passthrough_paths[@]}")
    fi

    if [[ ${#result_paths[@]} -gt 0 ]]; then
        printf '%s\0' "${result_paths[@]}"
    fi
}

# shellcheck disable=SC2329
get_cleanup_path_size_kb() {
    local path="$1"

    # A plain file or a symlink is a single stat. Directories and the
    # stat-unavailable case fall back to get_path_size_kb. For a regular file
    # with a zero/invalid stat we also fall back; a symlink reports 0 directly.
    if [[ -L "$path" || -f "$path" ]] && command -v stat > /dev/null 2>&1; then
        local bytes
        bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
        if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
            echo $(((bytes + 1023) / 1024))
            return 0
        fi
        if [[ -L "$path" ]]; then
            echo 0
            return 0
        fi
    fi

    get_path_size_kb "$path"
}

# Classification helper for cleanup risk levels
# shellcheck disable=SC2329
classify_cleanup_risk() {
    local description="$1"
    local path="${2:-}"

    # HIGH RISK: System files, preference files, require sudo
    if [[ "$description" =~ [Ss]ystem || "$description" =~ [Ss]udo || "$path" =~ ^/System || "$path" =~ ^/Library ]]; then
        echo "HIGH|System files or requires admin access"
        return
    fi

    # HIGH RISK: Preference files that might affect app functionality
    if [[ "$description" =~ [Pp]reference || "$path" =~ /Preferences/ ]]; then
        echo "HIGH|Preference files may affect app settings"
        return
    fi

    # MEDIUM RISK: Installers, large files, app bundles
    if [[ "$description" =~ [Ii]nstaller || "$description" =~ [Aa]pp.*[Bb]undle || "$description" =~ [Ll]arge ]]; then
        echo "MEDIUM|Installer packages or app data"
        return
    fi

    # MEDIUM RISK: Old backups, downloads
    if [[ "$description" =~ [Bb]ackup || "$description" =~ [Dd]ownload || "$description" =~ [Oo]rphan ]]; then
        echo "MEDIUM|Backup or downloaded files"
        return
    fi

    # LOW RISK: Caches, logs, temporary files (automatically regenerated)
    if [[ "$description" =~ [Cc]ache || "$description" =~ [Ll]og || "$description" =~ [Tt]emp || "$description" =~ [Tt]humbnail ]]; then
        echo "LOW|Cache/log files, automatically regenerated"
        return
    fi

    # DEFAULT: MEDIUM
    echo "MEDIUM|User data files"
}

# Internal implementation shared by the normal and process-guarded cleanup
# entry points. The first argument is an optional callback that must return 0
# immediately before each deletion sink; callers use it to bind a process-state
# check to the path that was just sized.
# shellcheck disable=SC2329
_safe_clean_impl() {
    local delete_guard="$1"
    shift

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" &&
        ("$pending_clean_cancel" -eq 124 || "$pending_clean_cancel" -ge 128) ]]; then
        return "$pending_clean_cancel"
    fi

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        description="${*: -1}"
        targets=("${@:1:$#-1}")
    fi

    local -a valid_targets=()
    for target in "${targets[@]}"; do
        # Optimization: If target is a glob literal and parent dir missing, skip it.
        if [[ "$target" == *"*"* && ! -e "$target" ]]; then
            local base_path="${target%%\**}"
            local parent_dir
            if [[ "$base_path" == */ ]]; then
                parent_dir="${base_path%/}"
            else
                parent_dir="${base_path%/*}"
            fi

            if [[ ! -d "$parent_dir" ]]; then
                # debug_log "Skipping nonexistent parent: $parent_dir for $target"
                continue
            fi
        fi
        valid_targets+=("$target")
    done

    if [[ ${#valid_targets[@]} -gt 0 ]]; then
        targets=("${valid_targets[@]}")
    else
        targets=()
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        return 0
    fi

    local removed_any=0
    local total_size_kb=0
    local total_count=0
    local skipped_count=0
    local removal_failed_count=0
    local delete_guard_stopped=0
    local cleanup_interrupt_rc=0
    # A guarded cleanup may bind the exact object it approved to safe_remove's
    # final identity check. These names deliberately use dynamic scope so the
    # callback can populate them without stdout/command-substitution races.
    local _MOLE_SAFE_CLEAN_BOUND_PATH=""
    local _MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
    local _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
    local _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
    local permission_start=${MOLE_PERMISSION_DENIED_COUNT:-0}

    local show_scan_feedback=false
    if [[ ${#targets[@]} -gt 20 && -t 1 ]]; then
        show_scan_feedback=true
        # Updates a running section spinner in place instead of restarting it.
        start_section_spinner "Scanning ${#targets[@]} items..."
    fi

    local _perf_scan_start
    debug_timer_start _perf_scan_start

    local -a existing_paths=()
    for path in "${targets[@]}"; do
        local skip=false

        if should_protect_path "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "protected"
        fi

        [[ "$skip" == "true" ]] && continue

        if is_path_whitelisted "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "whitelist"
        fi
        [[ "$skip" == "true" ]] && continue

        if holds_compiled_model_cache "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "compiled model cache"
        fi
        [[ "$skip" == "true" ]] && continue

        if [[ -e "$path" ]]; then
            existing_paths+=("$path")
        fi
    done

    if [[ ${#existing_paths[@]} -gt 1 ]]; then
        local -a normalized_paths=()
        while IFS= read -r -d '' path; do
            [[ -n "$path" ]] && normalized_paths+=("$path")
        done < <(normalize_paths_for_cleanup "${existing_paths[@]}")

        if [[ ${#normalized_paths[@]} -gt 0 ]]; then
            existing_paths=("${normalized_paths[@]}")
        else
            existing_paths=()
        fi
    fi

    debug_timer_end "$description: path scan" _perf_scan_start

    # Keep the spinner alive between phases; the next phase swaps its text in
    # place. Under MO_DEBUG stop it so debug lines print on a clean line.
    if [[ "$show_scan_feedback" == "true" && "${MO_DEBUG:-}" == "1" ]]; then
        stop_section_spinner
    fi

    debug_log "Cleaning: $description, ${#existing_paths[@]} items"

    # Enhanced debug output with risk level and details
    if [[ "${MO_DEBUG:-}" == "1" && ${#existing_paths[@]} -gt 0 ]]; then
        # Determine risk level for this cleanup operation
        local risk_info
        risk_info=$(classify_cleanup_risk "$description" "${existing_paths[0]}")
        local risk_level="${risk_info%%|*}"
        local risk_reason="${risk_info#*|}"

        debug_operation_start "$description"
        debug_risk_level "$risk_level" "$risk_reason"
        debug_operation_detail "Item count" "${#existing_paths[@]}"

        # Log sample of files (first 10) with details
        if [[ ${#existing_paths[@]} -le 10 ]]; then
            debug_operation_detail "Files to be removed" "All files listed below"
        else
            debug_operation_detail "Files to be removed" "Showing first 10 of ${#existing_paths[@]} files"
        fi
    fi

    if [[ $skipped_count -gt 0 ]]; then
        whitelist_skipped_count=$((whitelist_skipped_count + skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        # The scan spinner we started (or took over) must not outlive this
        # call; callers print rows without stopping spinners themselves.
        if [[ "$show_scan_feedback" == "true" ]]; then
            stop_section_spinner
        fi
        [[ $delete_guard_stopped -eq 1 ]] && return 75
        return 0
    fi

    local show_spinner=false
    if [[ ${#existing_paths[@]} -gt 10 ]]; then
        show_spinner=true
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then start_section_spinner "Scanning items..."; fi
    fi

    local cleaning_spinner_started=false

    local _perf_size_start
    debug_timer_start _perf_size_start

    # For larger batches, precompute sizes in parallel for better UX/stat accuracy.
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local temp_dir
        temp_dir=$(create_temp_dir)

        local dir_count=0
        local sample_size=$((${#existing_paths[@]} > 20 ? 20 : ${#existing_paths[@]}))
        local max_sample=$((${#existing_paths[@]} * 20 / 100))
        [[ $max_sample -gt $sample_size ]] && sample_size=$max_sample

        for ((i = 0; i < sample_size && i < ${#existing_paths[@]}; i++)); do
            [[ -d "${existing_paths[i]}" ]] && ((dir_count++))
        done

        # Heuristic: mostly files -> bulk stat is faster than per-file subshells.
        if [[ $dir_count -lt 5 && ${#existing_paths[@]} -gt 20 ]]; then
            if [[ -t 1 && "$show_spinner" == "false" ]]; then
                start_section_spinner "Scanning items..."
                show_spinner=true
            fi

            local idx=0
            local _bytes
            local bulk_stat_file="$temp_dir/bulk_stat"
            local bulk_stat_rc=0
            run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                stat -f%z "${existing_paths[@]}" < /dev/null \
                > "$bulk_stat_file" 2> /dev/null || bulk_stat_rc=$?
            if [[ $bulk_stat_rc -ge 128 ]]; then
                cleanup_interrupt_rc=$bulk_stat_rc
            elif [[ $bulk_stat_rc -eq 124 ]]; then
                # The size is only used for the freed total; a stalled stat
                # must not cancel the delete set. Sizes are already 0 here.
                MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
            fi
            while IFS= read -r _bytes; do
                [[ "$_bytes" =~ ^[0-9]+$ ]] || _bytes=0
                local _kb=$(((_bytes + 1023) / 1024))
                if [[ "$_kb" -gt 0 ]]; then
                    echo "$_kb 1" > "$temp_dir/result_${idx}"
                else
                    echo "0 0" > "$temp_dir/result_${idx}"
                fi
                idx=$((idx + 1))
            done < "$bulk_stat_file"
            while [[ $idx -lt ${#existing_paths[@]} ]]; do
                echo "0 0" > "$temp_dir/result_${idx}"
                idx=$((idx + 1))
            done
            for ((idx = 0; idx < ${#existing_paths[@]}; idx++)); do
                if [[ -d "${existing_paths[$idx]}" && ! -L "${existing_paths[$idx]}" ]]; then
                    local _dsize=0
                    local _dsize_rc=0
                    _dsize=$(get_cleanup_path_size_kb \
                        "${existing_paths[$idx]}") || _dsize_rc=$?
                    if [[ $_dsize_rc -ge 128 ]]; then
                        cleanup_interrupt_rc=$_dsize_rc
                        break
                    elif [[ $_dsize_rc -eq 124 ]]; then
                        MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
                    fi
                    [[ "$_dsize" =~ ^[0-9]+$ ]] || _dsize=0
                    if [[ "$_dsize" -gt 0 ]]; then
                        echo "$_dsize 1" > "$temp_dir/result_${idx}"
                    else
                        echo "0 0" > "$temp_dir/result_${idx}"
                    fi
                fi
            done
        else
            local -a pids=()
            local idx=0
            local completed=0
            local last_progress_update
            last_progress_update=$(get_epoch_seconds)
            local total_paths=${#existing_paths[@]}

            if [[ ${#existing_paths[@]} -gt 0 ]]; then
                for path in "${existing_paths[@]}"; do
                    (
                        local size=0 size_rc=0
                        local size_unknown=0
                        size=$(get_cleanup_path_size_kb "$path") || size_rc=$?
                        if [[ $size_rc -ge 128 ]]; then
                            exit "$size_rc"
                        fi
                        if [[ $size_rc -eq 124 ]]; then
                            # Sizing budget exhausted: keep the item in the
                            # delete set and report its size as 0.
                            size_unknown=1
                        fi
                        [[ ! "$size" =~ ^[0-9]+$ ]] && size=0
                        local tmp_file="$temp_dir/result_${idx}.$$"
                        if [[ "$size" -gt 0 ]]; then
                            echo "$size 1 $size_unknown" > "$tmp_file"
                        else
                            echo "0 0 $size_unknown" > "$tmp_file"
                        fi
                        mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
                    ) < /dev/null &
                    pids+=($!)
                    idx=$((idx + 1))

                    if ((${#pids[@]} >= MOLE_MAX_PARALLEL_JOBS)); then
                        local wait_rc=0
                        wait "${pids[0]}" 2> /dev/null || wait_rc=$?
                        if [[ $wait_rc -ge 128 ]]; then
                            cleanup_interrupt_rc=$wait_rc
                            break
                        fi
                        pids=("${pids[@]:1}")
                        completed=$((completed + 1))

                        if [[ "$show_spinner" == "true" && -t 1 ]]; then
                            update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                        fi
                    fi
                done
            fi

            if [[ ${#pids[@]} -gt 0 ]]; then
                for pid in "${pids[@]}"; do
                    local wait_rc=0
                    wait "$pid" 2> /dev/null || wait_rc=$?
                    if [[ $wait_rc -ge 128 ]]; then
                        [[ $cleanup_interrupt_rc -ne 0 ]] || cleanup_interrupt_rc=$wait_rc
                    fi
                    completed=$((completed + 1))

                    if [[ "$show_spinner" == "true" && -t 1 ]]; then
                        update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                    fi
                done
            fi
        fi

        # Count the items whose size check hit the budget; they were still
        # cleaned, only the freed total is under-reported.
        local _t_size=0
        local _t_count=0
        local _t_flag=0
        local _t_file
        for _t_file in "$temp_dir"/result_*; do
            [[ -f "$_t_file" ]] || continue
            _t_flag=0
            read -r _t_size _t_count _t_flag < "$_t_file" 2> /dev/null || true
            [[ "$_t_flag" == "1" ]] && MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
        done

        if [[ $cleanup_interrupt_rc -ne 0 ]]; then
            if [[ "$show_spinner" == "true" || "$show_scan_feedback" == "true" ]]; then
                stop_inline_spinner
            fi
            MOLE_CLEAN_CANCEL_STATUS=$cleanup_interrupt_rc
            export MOLE_CLEAN_CANCEL_STATUS
            return "$cleanup_interrupt_rc"
        fi

        debug_timer_end "$description: size calc" _perf_size_start

        local _perf_del_start
        debug_timer_start _perf_del_start

        # Read results back in original order.
        # Start spinner for cleaning phase
        if [[ "$DRY_RUN" != "true" && ${#existing_paths[@]} -gt 0 && -t 1 ]]; then
            start_section_spinner "Cleaning..."
            cleaning_spinner_started=true
        fi
        idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local result_file="$temp_dir/result_${idx}"
                if [[ -f "$result_file" ]]; then
                    read -r size count size_unknown < "$result_file" 2> /dev/null || true
                    local removed=0
                    local action_rc=0
                    if [[ "$DRY_RUN" != "true" ]]; then
                        if [[ -n "$delete_guard" ]]; then
                            _MOLE_SAFE_CLEAN_BOUND_PATH=""
                            _MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
                            _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
                            _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
                            "$delete_guard" "$path" || action_rc=$?
                            if [[ $action_rc -eq 124 || $action_rc -ge 128 ]]; then
                                cleanup_interrupt_rc=$action_rc
                                break
                            elif [[ $action_rc -ne 0 ]]; then
                                delete_guard_stopped=1
                                break
                            fi
                        fi
                        action_rc=0
                        local bound_parent=""
                        local bound_parent_id=""
                        local bound_target_id=""
                        if [[ "$_MOLE_SAFE_CLEAN_BOUND_PATH" == "$path" ]]; then
                            bound_parent="$_MOLE_SAFE_CLEAN_EXPECTED_PARENT"
                            bound_parent_id="$_MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID"
                            bound_target_id="$_MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID"
                        fi
                        safe_remove "$path" true "$size" "" \
                            "$bound_parent" "$bound_parent_id" \
                            "$bound_target_id" || action_rc=$?
                        # A removal timeout (124) is a failed removal, not a
                        # user interrupt: count it below and keep cleaning so
                        # one slow disk item never cancels the rest of the run.
                        if [[ $action_rc -ge 128 ]]; then
                            cleanup_interrupt_rc=$action_rc
                            break
                        elif [[ $action_rc -eq 0 ]]; then
                            removed=1
                        fi
                    else
                        if [[ -n "$delete_guard" ]]; then
                            _MOLE_SAFE_CLEAN_BOUND_PATH=""
                            _MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
                            _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
                            _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
                            "$delete_guard" "$path" || action_rc=$?
                            if [[ $action_rc -eq 124 || $action_rc -ge 128 ]]; then
                                cleanup_interrupt_rc=$action_rc
                                break
                            elif [[ $action_rc -ne 0 ]]; then
                                delete_guard_stopped=1
                                break
                            fi
                        fi
                        action_rc=0
                        record_dry_run_cleanup_target \
                            "$path" "$size" 1 true || action_rc=$?
                        if [[ $action_rc -eq 124 || $action_rc -ge 128 ]]; then
                            cleanup_interrupt_rc=$action_rc
                            break
                        elif [[ $action_rc -eq 0 ]]; then
                            removed=1
                        fi
                    fi

                    if [[ $removed -eq 1 ]]; then
                        if [[ "$size" -gt 0 ]]; then
                            total_size_kb=$((total_size_kb + size))
                        fi
                        total_count=$((total_count + 1))
                        removed_any=1
                    else
                        if [[ -e "$path" && "$DRY_RUN" != "true" ]]; then
                            removal_failed_count=$((removal_failed_count + 1))
                        fi
                    fi
                fi
                idx=$((idx + 1))
            done
        fi

        debug_timer_end "$description: deletion" _perf_del_start

    else
        debug_timer_end "$description: size calc" _perf_size_start

        local _perf_del_start
        debug_timer_start _perf_del_start

        # Start spinner for cleaning phase (small batch)
        if [[ "$DRY_RUN" != "true" && ${#existing_paths[@]} -gt 0 && -t 1 ]]; then
            start_section_spinner "Cleaning..."
            cleaning_spinner_started=true
        fi
        local idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local size_kb=0
                local size_rc=0
                size_kb=$(get_cleanup_path_size_kb "$path") || size_rc=$?
                if [[ $size_rc -ge 128 ]]; then
                    cleanup_interrupt_rc=$size_rc
                    break
                elif [[ $size_rc -eq 124 ]]; then
                    # Sizing budget exhausted: keep cleaning with size 0.
                    MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
                fi
                [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0

                local removed=0
                local action_rc=0
                if [[ "$DRY_RUN" != "true" ]]; then
                    if [[ -n "$delete_guard" ]]; then
                        _MOLE_SAFE_CLEAN_BOUND_PATH=""
                        _MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
                        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
                        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
                        "$delete_guard" "$path" || action_rc=$?
                        if [[ $action_rc -eq 124 || $action_rc -ge 128 ]]; then
                            cleanup_interrupt_rc=$action_rc
                            break
                        elif [[ $action_rc -ne 0 ]]; then
                            delete_guard_stopped=1
                            break
                        fi
                    fi
                    action_rc=0
                    local bound_parent=""
                    local bound_parent_id=""
                    local bound_target_id=""
                    if [[ "$_MOLE_SAFE_CLEAN_BOUND_PATH" == "$path" ]]; then
                        bound_parent="$_MOLE_SAFE_CLEAN_EXPECTED_PARENT"
                        bound_parent_id="$_MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID"
                        bound_target_id="$_MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID"
                    fi
                    safe_remove "$path" true "$size_kb" "" \
                        "$bound_parent" "$bound_parent_id" \
                        "$bound_target_id" || action_rc=$?
                    # Same non-fatal removal-timeout policy as the
                    # parallel-result loop above.
                    if [[ $action_rc -ge 128 ]]; then
                        cleanup_interrupt_rc=$action_rc
                        break
                    elif [[ $action_rc -eq 0 ]]; then
                        removed=1
                    fi
                else
                    if [[ -n "$delete_guard" ]]; then
                        _MOLE_SAFE_CLEAN_BOUND_PATH=""
                        _MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
                        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
                        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
                        "$delete_guard" "$path" || action_rc=$?
                        if [[ $action_rc -eq 124 || $action_rc -ge 128 ]]; then
                            cleanup_interrupt_rc=$action_rc
                            break
                        elif [[ $action_rc -ne 0 ]]; then
                            delete_guard_stopped=1
                            break
                        fi
                    fi
                    action_rc=0
                    record_dry_run_cleanup_target \
                        "$path" "$size_kb" 1 true || action_rc=$?
                    if [[ $action_rc -eq 124 || $action_rc -ge 128 ]]; then
                        cleanup_interrupt_rc=$action_rc
                        break
                    elif [[ $action_rc -eq 0 ]]; then
                        removed=1
                    fi
                fi

                if [[ $removed -eq 1 ]]; then
                    if [[ "$size_kb" -gt 0 ]]; then
                        total_size_kb=$((total_size_kb + size_kb))
                    fi
                    total_count=$((total_count + 1))
                    removed_any=1
                else
                    if [[ -e "$path" && "$DRY_RUN" != "true" ]]; then
                        removal_failed_count=$((removal_failed_count + 1))
                    fi
                fi
                idx=$((idx + 1))
            done
        fi

        debug_timer_end "$description: deletion" _perf_del_start
    fi

    if [[ "$show_spinner" == "true" || "$cleaning_spinner_started" == "true" || "$show_scan_feedback" == "true" ]]; then
        stop_inline_spinner
    fi

    if [[ $cleanup_interrupt_rc -ne 0 ]]; then
        MOLE_CLEAN_CANCEL_STATUS=$cleanup_interrupt_rc
        export MOLE_CLEAN_CANCEL_STATUS
        return "$cleanup_interrupt_rc"
    fi

    local permission_end=${MOLE_PERMISSION_DENIED_COUNT:-0}
    # Track permission failures in debug output (avoid noisy user warnings).
    if [[ $permission_end -gt $permission_start && $removed_any -eq 0 ]]; then
        debug_log "Permission denied while cleaning: $description"
    fi
    if [[ $removal_failed_count -gt 0 && "$DRY_RUN" != "true" ]]; then
        debug_log "Skipped $removal_failed_count items, permission denied, in use, or timed out, for: $description"
    fi

    if [[ $removed_any -eq 1 ]]; then
        # Stop spinner before output
        stop_section_spinner

        local size_human
        size_human=$(bytes_to_human "$((total_size_kb * 1024))")

        # Multi-target cleanups report the item count as part of the detail
        # column, keeping the label clean: "npm logs · 2 items, 2KB". Use the
        # actually-cleaned count (total_count), not the raw target count, so it
        # stays consistent with the reported size after protected, whitelisted,
        # missing, and deduplicated targets have been dropped.
        local count_note=""
        if [[ $total_count -gt 1 ]]; then
            count_note="$total_count items, "
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            local size_display
            size_display=$(colorize_human_size "$size_human")
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $description${NC} · ${count_note}${size_display} ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} $description${NC} · ${count_note}${line_color}$size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + total_count))
        total_size_cleaned=$((total_size_cleaned + total_size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi

    # 75 is internal to safe_clean_guarded. Normal safe_clean calls never set a
    # guard and retain the existing always-zero cleanup contract.
    [[ $delete_guard_stopped -eq 1 ]] && return 75
    return 0
}

# shellcheck disable=SC2329
safe_clean() {
    _safe_clean_impl "" "$@"
}

# Run safe_clean with a callback rechecked after sizing and immediately before
# every safe_remove call. Returns 75 when the callback stops the batch after
# preserving any removals already completed.
# shellcheck disable=SC2329
safe_clean_guarded() {
    local delete_guard="$1"
    shift
    declare -f "$delete_guard" > /dev/null 2>&1 || return 2
    _safe_clean_impl "$delete_guard" "$@"
}

start_cleanup() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="clean"
    MOLE_CLEAN_CANCEL_STATUS=0
    export MOLE_CLEAN_CANCEL_STATUS
    MOLE_CLEAN_SIZING_TIMEOUTS=0
    export MOLE_CLEAN_SIZING_TIMEOUTS
    MOLE_CLEAN_REMOVAL_TIMEOUTS=0
    export MOLE_CLEAN_REMOVAL_TIMEOUTS
    MOLE_CLEAN_TRASH_FAILURES=0
    export MOLE_CLEAN_TRASH_FAILURES
    log_operation_session_start "clean"
    DRY_RUN_SEEN_IDENTITIES=()
    DRY_RUN_TOTAL_PARTIAL=false

    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        echo -e "${PURPLE_BOLD}Clean External Volume${NC}"
        echo -e "${GRAY}${EXTERNAL_VOLUME_TARGET}${NC}"
        echo ""

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
            echo ""
        fi
        SYSTEM_CLEAN=false
        return 0
    fi

    echo -e "${PURPLE_BOLD}Clean Your Mac${NC}"
    echo ""

    if [[ "${MOLE_CLEAN_TRASH:-0}" == "1" && "$DRY_RUN" != "true" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Trash mode, removals stay restorable, space frees up when you empty the Trash"
        echo ""
    fi

    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo -e "${GRAY}${ICON_WARNING} Use --dry-run to preview, --whitelist to manage protected paths${NC}"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
        echo ""

        prepare_clean_preview_file || {
            echo -e "${YELLOW}${ICON_WARNING}${NC} Unable to create a safe cleanup preview file" >&2
            return 1
        }
        write_clean_preview_header

        # Preview system section when sudo is already cached (no password prompt).
        if adopt_sudo_session; then
            SYSTEM_CLEAN=true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access available, system preview included"
            echo ""
        else
            SYSTEM_CLEAN=false
            echo -e "${GRAY}${ICON_WARNING} System caches need sudo, run ${NC}sudo -v && mo clean --dry-run${GRAY} for full preview${NC}"
            echo ""
        fi
        return
    fi

    local sudo_cached=false
    adopt_sudo_session && sudo_cached=true

    if clean_stdin_is_tty; then
        # Confirm the privileged sweep on every interactive run. A sudo
        # timestamp the user established for something else authenticates them;
        # it does not say this run was meant to delete outside $HOME. The
        # adopted session above still spares them the password and still keeps
        # later privileged calls from prompting mid-spinner (#1084).
        prompt_for_system_clean "$sudo_cached"
    else
        # No terminal to ask, so the #1084 contract stands unchanged:
        # credentials the caller already established are reused for the run.
        echo ""
        echo "Running in non-interactive mode"
        if [[ "$sudo_cached" == "true" ]]; then
            SYSTEM_CLEAN=true
            echo "  ${ICON_LIST} System-level cleanup enabled, sudo session active"
        else
            SYSTEM_CLEAN=false
            echo "  ${ICON_LIST} System-level cleanup skipped, requires sudo"
        fi
        echo "  ${ICON_LIST} User-level cleanup will proceed automatically"
        echo ""
    fi
}

perform_cleanup() {
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        total_items=0
        files_cleaned=0
        total_size_cleaned=0
    fi

    local initial_free_space_kb=""
    local initial_free_space_display="Unknown"

    # Test mode skips expensive scans and returns minimal output.
    local test_mode_enabled=false
    if [[ -z "$EXTERNAL_VOLUME_TARGET" && "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        test_mode_enabled=true
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
            echo ""
        fi
        echo -e "${GREEN}${ICON_LIST}${NC} User app cache"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            local -a expanded_defaults
            expanded_defaults=()
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                expanded_defaults+=("${default/#\~/$HOME}")
            done
            local has_custom=false
            for pattern in "${WHITELIST_PATTERNS[@]}"; do
                local is_default=false
                local normalized_pattern="${pattern%/}"
                for default in "${expanded_defaults[@]}"; do
                    local normalized_default="${default%/}"
                    [[ "$normalized_pattern" == "$normalized_default" ]] && is_default=true && break
                done
                [[ "$is_default" == "false" ]] && has_custom=true && break
            done
            [[ "$has_custom" == "true" ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} Protected items found"
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            echo ""
            echo -e "Potential space: $(colorize_human_size "0.00GB")"
        fi
        total_items=1
        files_cleaned=0
        total_size_cleaned=0
    fi

    if [[ "$test_mode_enabled" == "false" && -z "$EXTERNAL_VOLUME_TARGET" ]]; then
        if ! initial_free_space_kb=$(get_free_space_kb 2> /dev/null); then
            initial_free_space_kb=""
        fi
        initial_free_space_display=$(format_free_space_kb "$initial_free_space_kb")
        echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $initial_free_space_display"
    fi

    if [[ "$test_mode_enabled" == "true" ]]; then
        local summary_heading="Test mode complete"
        local -a summary_details
        summary_details=()
        summary_details+=("Test mode - no actual cleanup performed")
        print_summary_block "$summary_heading" "${summary_details[@]}"
        printf '\n'
        return 0
    fi

    # Pre-check TCC permissions to avoid mid-run prompts.
    if [[ -z "$EXTERNAL_VOLUME_TARGET" ]]; then
        check_tcc_permissions
    fi

    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local predefined_count=0
        local custom_count=0

        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            # Hard safety entries are the most core protection Mole ships, so
            # count them with the defaults. Attributing them to the user reads
            # as "you added these" for rules nobody opted into.
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}" "${SAFETY_WHITELIST_PATTERNS[@]}"; do
                local expanded_default="${default/#\~/$HOME}"
                if [[ "$pattern" == "$expanded_default" ]]; then
                    is_predefined=true
                    break
                fi
            done

            if [[ "$is_predefined" == "true" ]]; then
                predefined_count=$((predefined_count + 1))
            else
                custom_count=$((custom_count + 1))
            fi
        done

        if [[ $custom_count -gt 0 || $predefined_count -gt 0 ]]; then
            local summary=""
            [[ $predefined_count -gt 0 ]] && summary+="$predefined_count core"
            [[ $custom_count -gt 0 && $predefined_count -gt 0 ]] && summary+=" + "
            [[ $custom_count -gt 0 ]] && summary+="$custom_count custom"
            summary+=" patterns active"

            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $summary"

            if [[ "$DRY_RUN" == "true" ]]; then
                for pattern in "${WHITELIST_PATTERNS[@]}"; do
                    [[ "$pattern" == "$FINDER_METADATA_SENTINEL" ]] && continue
                    echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ${GRAY}${pattern}${NC}"
                done
            fi
        fi
    fi

    if [[ -t 1 && "$DRY_RUN" != "true" ]]; then
        local fda_status=0
        has_full_disk_access
        fda_status=$?
        if [[ $fda_status -eq 1 ]]; then
            echo ""
            echo -e "${GRAY}${ICON_REVIEW}${NC} ${GRAY}Grant Full Disk Access to your terminal in System Settings for best results${NC}"
        fi
    fi

    total_items=0
    files_cleaned=0
    total_size_cleaned=0
    DEFERRED_CLEANUP_FAMILIES=()
    DEFERRED_CLEANUP_FAMILIES_FILE=$(create_temp_file 2> /dev/null || true)

    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1

    # Allow per-section failures without aborting the full run.
    set +e

    _run_cleanup_step() {
        local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
        if [[ $pending_clean_cancel -eq 124 || $pending_clean_cancel -ge 128 ]]; then
            return "$pending_clean_cancel"
        fi
        local step_rc=0
        "$@" || step_rc=$?
        pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
        if [[ $step_rc -eq 124 || $step_rc -ge 128 ]]; then
            MOLE_CLEAN_CANCEL_STATUS=$step_rc
            export MOLE_CLEAN_CANCEL_STATUS
            return "$step_rc"
        fi
        if [[ $pending_clean_cancel -eq 124 || $pending_clean_cancel -ge 128 ]]; then
            return "$pending_clean_cancel"
        fi
        return 0
    }

    local cleanup_cancel_rc=0
    # Sections run inside a function so a cancelled step (timeout/signal,
    # exit 124+) stops the remaining sections but still falls through to the
    # final summary instead of returning from perform_cleanup with no output.
    run_clean_sections() {
        if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
            start_section "External volume"
            _run_cleanup_step clean_external_volume_target "$EXTERNAL_VOLUME_TARGET" || return $?
            end_section
        else
            # ===== 1. System =====
            if [[ "$SYSTEM_CLEAN" == "true" ]]; then
                start_section "System"
                _run_cleanup_step clean_deep_system || return $?
                _run_cleanup_step clean_local_snapshots || return $?
                end_section
            fi

            if [[ ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
                flush_idle_section_slot
                echo ""
                for warning in "${WHITELIST_WARNINGS[@]}"; do
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Whitelist: $warning"
                done
            fi

            # ===== 2. User essentials =====
            start_section "User essentials"
            _run_cleanup_step clean_user_essentials || return $?
            _run_cleanup_step clean_finder_metadata || return $?
            end_section

            # ===== 3. App caches (merged sandboxed and standard app caches) =====
            start_section "App caches"
            _run_cleanup_step clean_app_caches || return $?
            end_section

            # ===== 4. Browsers =====
            start_section "Browsers"
            _run_cleanup_step clean_browsers || return $?
            end_section

            # ===== 5. Cloud & Office =====
            start_section "Cloud & Office"
            # Force shell fallback so timeout runs in this shell context.
            # The Cloud/Office cleaners rely on helpers (safe_clean, whitelist checks)
            # defined in this script and sourced modules.
            if run_with_shell_timeout 300 run_cloud_and_office_cleanup; then
                : # completed successfully
            else
                local ret=$?
                if [[ $ret -eq 124 ]]; then
                    log_warning "Cloud & Office cleanup timed out after 5 minutes, skipping remaining items"
                elif [[ $ret -ge 128 ]]; then
                    return "$ret"
                else
                    log_warning "Cloud & Office cleanup failed with exit code $ret"
                fi
            fi
            end_section

            # ===== 6. Developer tools (merged CLI and GUI tooling) =====
            start_section "Developer tools"
            _run_cleanup_step clean_developer_tools || return $?
            end_section

            # ===== 7. Apps & utilities =====
            start_section "Apps & utilities"
            _run_cleanup_step clean_user_gui_applications || return $?
            end_section

            # ===== 8. Virtualization =====
            start_section "Virtualization"
            _run_cleanup_step clean_virtualization_tools || return $?
            end_section

            # ===== 9. Application Support =====
            start_section "Application Support"
            _run_cleanup_step clean_application_support_logs || return $?
            end_section

            # ===== 10. App leftovers =====
            start_section "App leftovers"
            _run_cleanup_step clean_orphaned_app_data || return $?
            _run_cleanup_step clean_orphaned_system_services || return $?
            # No stale-LaunchServices step here on purpose. `lsregister -u`
            # cannot remove a record whose app is already gone: on macOS 15 and
            # later it fails with -10814 for every such path, which is exactly
            # the set this would have targeted, so the step could only ever
            # report failures. `mo optimize` already offers the supported
            # repair (`lsregister -gc` plus a domain rescan) as an explicit,
            # user-triggered task.
            _run_cleanup_step clean_orphaned_container_stubs || return $?
            _run_cleanup_step show_user_launch_agent_hint_notice || return $?
            end_section

            # ===== 11. Apple Silicon =====
            _run_cleanup_step clean_apple_silicon_caches || return $?

            # ===== 12. Device backups & firmware =====
            # iOS backups are reported once, in the Large files section; a second
            # row here used a different size formatter and confused users.
            start_section "Device backups & firmware"
            _run_cleanup_step clean_cached_device_firmware || return $?
            end_section

            # ===== 13. Time Machine =====
            start_section "Time Machine"
            _run_cleanup_step clean_time_machine_failed_backups || return $?
            end_section

            # ===== 14. Large files =====
            start_section "Large files"
            _run_cleanup_step check_large_file_candidates || return $?
            end_section

            # ===== 15. Project artifacts =====
            start_section "Project artifacts"
            _run_cleanup_step show_project_artifact_hint_notice || return $?
            end_section
        fi
    }
    run_clean_sections || cleanup_cancel_rc=$?

    # ===== Final summary =====
    flush_idle_section_slot
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        render_clean_preview_from_ledger
    fi

    sync_deferred_cleanup_families

    local summary_heading=""
    local summary_status="success"
    if [[ $cleanup_cancel_rc -eq 124 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_heading="Dry run cancelled"
        else
            summary_heading="Cleanup cancelled"
        fi
        summary_status="warning"
    elif [[ $cleanup_cancel_rc -ge 128 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_heading="Dry run interrupted"
        else
            summary_heading="Cleanup interrupted"
        fi
        summary_status="warning"
    elif [[ "$DRY_RUN" == "true" ]]; then
        summary_heading="Dry run complete - no changes made"
    else
        summary_heading="Cleanup complete"
    fi

    local -a summary_details=()
    if [[ $cleanup_cancel_rc -ne 0 ]]; then
        if [[ $cleanup_cancel_rc -eq 124 ]]; then
            summary_details+=("${GRAY}${ICON_WARNING}${NC} Cancelled: a scan or size check timed out (exit 124). Remaining cleanup was skipped.")
        elif [[ $cleanup_cancel_rc -ge 128 ]]; then
            summary_details+=("${GRAY}${ICON_WARNING}${NC} Cancelled: a cleanup step was interrupted (exit $cleanup_cancel_rc). Remaining cleanup was skipped.")
        fi
    fi

    # Emit one "Free space" line, with the measured delta in parentheses when
    # available. $1 is the free space in KB captured before cleanup started.
    # Caller appends each printed line to summary_details.
    emit_free_space_summary() {
        local initial_kb="$1"
        if [[ "$DRY_RUN" == "true" ]]; then
            printf 'Free space: %s\n' "$(get_free_space)"
            return 0
        fi

        local final_kb
        if ! final_kb=$(get_free_space_kb 2> /dev/null); then
            final_kb=""
        fi
        local delta_note=""
        if [[ "$initial_kb" =~ ^[0-9]+$ && "$final_kb" =~ ^[0-9]+$ && "$initial_kb" -ne "$final_kb" ]]; then
            delta_note=" ($(format_free_space_delta_kb "$((final_kb - initial_kb))"))"
        fi
        printf 'Free space: %s%s\n' "$(format_free_space_kb "$final_kb")" "$delta_note"
    }

    if [[ $total_size_cleaned -gt 0 ||
        ("$DRY_RUN" == "true" && ("$DRY_RUN_TOTAL_PARTIAL" == "true" || $files_cleaned -gt 0)) ]]; then
        local freed_size_human
        freed_size_human=$(bytes_to_human_kb "$total_size_cleaned")

        if [[ "$DRY_RUN" == "true" ]]; then
            local potential_label
            if [[ "$DRY_RUN_TOTAL_PARTIAL" == "true" ]]; then
                potential_label="At least $freed_size_human"
            else
                potential_label="$freed_size_human"
            fi
            local stats="Potential space: $(colorize_human_size "$potential_label")"
            [[ $files_cleaned -gt 0 ]] && stats+=" | Items: $files_cleaned"
            [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
            summary_details+=("$stats")

            {
                echo ""
                echo "# ============================================"
                echo "# Summary"
                echo "# ============================================"
                echo "# Potential cleanup: ${potential_label}"
                echo "# Items: $files_cleaned"
                echo "# Categories: $total_items"
            } >> "$EXPORT_LIST_FILE"

        else
            local summary_line="Tracked cleanup: ${GREEN}${freed_size_human}${NC}"

            if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                summary_line+=" | Items cleaned: $files_cleaned | Categories: $total_items"
            elif [[ $files_cleaned -gt 0 ]]; then
                summary_line+=" | Items cleaned: $files_cleaned"
            elif [[ $total_items -gt 0 ]]; then
                summary_line+=" | Categories: $total_items"
            fi

            summary_details+=("$summary_line")

            # Movie comparison only if >= 1GB
            if ((total_size_cleaned >= MOLE_ONE_GIB_KB)); then
                local freed_gb=$((total_size_cleaned / MOLE_ONE_GIB_KB))
                local movies=$((freed_gb * 10 / 45))

                if [[ $movies -gt 0 ]]; then
                    if [[ $movies -eq 1 ]]; then
                        summary_details+=("Equivalent to ~$movies 4K movie of storage.")
                    else
                        summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                    fi
                fi
            fi

            local free_space_line
            while IFS= read -r free_space_line; do
                summary_details+=("$free_space_line")
            done < <(emit_free_space_summary "$initial_free_space_kb")
        fi
    else
        summary_status="info"
        if [[ ${#DEFERRED_CLEANUP_FAMILIES[@]} -gt 0 ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                summary_details+=("No additional reclaimable space detected.")
            else
                summary_details+=("No additional space freed.")
            fi
        elif [[ "$DRY_RUN" == "true" ]]; then
            summary_details+=("No significant reclaimable space detected, system already clean.")
        else
            summary_details+=("System was already clean; no additional space freed.")
        fi
        local free_space_line
        while IFS= read -r free_space_line; do
            summary_details+=("$free_space_line")
        done < <(emit_free_space_summary "$initial_free_space_kb")
    fi

    # Caches of running apps are deferred silently: skipping them is Mole's
    # ordinary behavior, not news, and for always-on tools (Codex, browsers)
    # a summary line here appeared on every single run. Preview still lists
    # what would be cleaned, and the ledger stays visible under --debug.
    if [[ ${#DEFERRED_CLEANUP_FAMILIES[@]} -gt 0 ]]; then
        debug_log "Deferred while active: $(format_deferred_cleanup_families)"
    fi

    if [[ "$DRY_RUN" == "true" &&
        ($total_size_cleaned -gt 0 || "$DRY_RUN_TOTAL_PARTIAL" == "true" || $files_cleaned -gt 0) ]]; then
        if publish_clean_preview_file; then
            summary_details+=("Detailed file list: ${GRAY}$CLEAN_PREVIEW_FINAL_FILE${NC}")
            summary_details+=("Use ${GRAY}mo clean --whitelist${NC} to add protection rules")
        else
            summary_details+=("Cleanup preview file could not be written safely")
        fi
    elif [[ "$DRY_RUN" == "true" ]]; then
        publish_clean_preview_file || true
    fi

    if [[ ${MOLE_CLEAN_SIZING_TIMEOUTS:-0} -gt 0 ]]; then
        summary_details+=("${GRAY}${ICON_WARNING}${NC} Some items exceeded the ${MOLE_TIMEOUT_DISK_VERIFY_SEC}s size-check budget and were counted as 0, so the total is under-reported. Raise ${GRAY}MOLE_TIMEOUT_DISK_VERIFY_SEC${NC} to measure them.")
    fi

    if [[ ${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0} -gt 0 ]]; then
        summary_details+=("${GRAY}${ICON_WARNING}${NC} ${MOLE_CLEAN_REMOVAL_TIMEOUTS} item(s) exceeded the ${MOLE_TIMEOUT_DISK_VERIFY_SEC}s removal budget and may be only partly removed. Run clean again, or raise ${GRAY}MOLE_TIMEOUT_DISK_VERIFY_SEC${NC} for slower disks.")
    fi

    # Trash mode never downgrades to a permanent delete, so a failed move
    # leaves the item in place. Say so: silence here would read as "cleaned".
    if [[ ${MOLE_CLEAN_TRASH_FAILURES:-0} -gt 0 ]]; then
        summary_details+=("${GRAY}${ICON_WARNING}${NC} ${MOLE_CLEAN_TRASH_FAILURES} item(s) could not be moved to the Trash and were left in place. Run ${GRAY}mo clean${NC} without ${GRAY}--trash${NC} to remove them permanently.")
    fi

    if [[ $had_errexit -eq 1 ]]; then
        set -e
    fi

    # Log session end with summary
    log_operation_session_end "clean" "$files_cleaned" "$total_size_cleaned"

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'

    return "$cleanup_cancel_rc"
}

run_with_shell_timeout() {
    local duration="$1"
    shift || true
    # Functions (for example safe_clean) are available only in the current shell.
    # Force the shell fallback path so timeout can execute shell functions directly.
    MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN="" run_with_timeout "$duration" "$@"
}

# shellcheck disable=SC2329  # Invoked indirectly via run_with_timeout fallback.
run_cloud_and_office_cleanup() {
    clean_cloud_storage
    clean_office_applications
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--help" | "-h")
                show_clean_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                DRY_RUN=true
                export MOLE_DRY_RUN=1
                ;;
            "--trash")
                export MOLE_CLEAN_TRASH=1
                ;;
            "--external")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing path for --external" >&2
                    exit 1
                fi
                EXTERNAL_VOLUME_TARGET=$(validate_external_volume_target "$1") || exit 1
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/manage/whitelist.sh"
                manage_whitelist "clean"
                exit 0
                ;;
            "--select" | "--categories" | "--exclude")
                echo "mo clean $1 was removed in this release." >&2
                echo "Use 'mo clean --dry-run' to preview cleanup and 'mo clean --whitelist' to protect paths." >&2
                exit 1
                ;;
            -*)
                echo "Unknown option for mo clean: $1" >&2
                echo "Run 'mo clean --help' for usage." >&2
                exit 1
                ;;
            *)
                echo "Unexpected argument for mo clean: $1" >&2
                echo "Run 'mo clean --help' for usage." >&2
                exit 1
                ;;
        esac
        shift
    done

    start_cleanup
    hide_cursor
    local cleanup_rc=0
    perform_cleanup || cleanup_rc=$?
    show_cursor
    exit "$cleanup_rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
