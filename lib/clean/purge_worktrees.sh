#!/bin/bash
# Git worktree awareness for `mo purge` (side-effect free).
#
# Purge's usual authority for removing a directory is its NAME: `node_modules`
# is a known-reproducible artifact, and because a name is only a guess,
# is_safe_project_artifact additionally demands the directory sit nested inside
# a detected project rather than as a direct child of a search root.
#
# A linked git worktree carries a stronger claim than any name can: the parent
# repo's own `git worktree list` registration. A worktree that is clean,
# remote-backed, fully pushed and untouched for a week is a checkout of objects
# that already exist locally, and `git worktree add` restores it offline in
# seconds. That registration - not the path - is what authorizes removal here,
# which is why these helpers never consult the search-root depth rule and why
# is_safe_purge_worktree exists as a parallel last gate for them.

set -euo pipefail

if [[ -n "${MOLE_PURGE_WORKTREES_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PURGE_WORKTREES_LOADED=1

# MOLE_PURGE_TARGETS is the whitelist the ignored-entry guard checks against.
if [[ -z "${MOLE_PURGE_SHARED_LOADED:-}" ]]; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/purge_shared.sh"
fi

# Days without git activity before a worktree is offered. Mirrors purge's
# MIN_AGE_DAYS; kept here so this file stays loadable on its own.
readonly MOLE_PURGE_WORKTREE_MIN_AGE_DAYS=7

# Never descended into while looking for repos. `.git` is deliberately absent:
# the repo scan looks for it, and prunes it once matched.
readonly MOLE_PURGE_WORKTREE_PRUNE_DIRS=("Library" ".Trash" "Applications" "node_modules")

# Read-only git invocation for cheap metadata reads (refs, config, registry).
#
# --no-optional-locks stops inspection from opportunistically rewriting the
# index: that write lands in the per-worktree git dir and would reset the
# staleness signal on every purge run, so a worktree could never age out.
# Supported since git 2.15, i.e. every git shipped with a macOS Mole runs on.
_mole_purge_git() {
    local repo="$1"
    shift
    run_with_timeout "${MOLE_TIMEOUT_QUICK_DETECT_SEC:-2}" \
        git --no-optional-locks -C "$repo" "$@" 2> /dev/null
}

# Read-only git invocation for the reads that walk an unbounded tree or history
# (`status`, `rev-list`). The quick-detect ceiling is wrong for these: a cold
# cache on a large checkout blows past it, and a timed-out `status` returns
# empty output, which reads exactly like "clean". Callers must still treat a
# nonzero exit as "keep this worktree" - the ceiling only makes that rare.
_mole_purge_git_walk() {
    local repo="$1"
    shift
    run_with_timeout "${MOLE_TIMEOUT_HINT_SCAN_SEC:-15}" \
        git --no-optional-locks -C "$repo" "$@" 2> /dev/null
}

# Emit the path of every linked worktree a repo has registered.
# The first porcelain record is always the repo's own main worktree; `bare`
# records have no working dir, and `prunable` records have already lost theirs.
# A `locked` record stays eligible: locking says "do not prune the
# registration", while reclaimability is decided by the four guards below.
mole_purge_worktree_registrations() {
    local repo="$1"

    [[ -n "$repo" && -d "$repo" ]] || return 0

    _mole_purge_git "$repo" worktree list --porcelain | awk '
        /^worktree / {
            if (keep) print path
            path = substr($0, 10)
            keep = (++seen > 1)
            next
        }
        /^bare$/ { keep = 0; next }
        /^prunable/ { keep = 0; next }
        END { if (keep) print path }
    '
}

# Absolute per-worktree git dir (<repo>/.git/worktrees/<name>).
mole_purge_worktree_gitdir() {
    local wt="$1"
    local gitdir=""

    [[ -n "$wt" && -d "$wt" ]] || return 1
    gitdir=$(_mole_purge_git "$wt" rev-parse --absolute-git-dir) || return 1
    [[ -n "$gitdir" && -d "$gitdir" ]] || return 1
    printf '%s\n' "$gitdir"
}

# Absolute path of the repo that owns a worktree. Derived from the git dir
# rather than by reading the worktree's `.git` pointer file, whose gitdir may
# be relative under worktree.useRelativePaths.
mole_purge_worktree_parent_repo() {
    local wt="$1"
    local gitdir=""
    local common_dir=""
    local parent=""

    gitdir=$(mole_purge_worktree_gitdir "$wt") || return 1
    case "$gitdir" in
        */worktrees/*) ;;
        *) return 1 ;; # main worktree, not a linked one
    esac

    common_dir="${gitdir%/worktrees/*}"
    [[ -n "$common_dir" && -d "$common_dir" ]] || return 1

    # <repo>/.git -> <repo>; a bare or separate git dir is its own repo root.
    parent="${common_dir%/.git}"
    [[ -n "$parent" && -d "$parent" ]] || parent="$common_dir"
    printf '%s\n' "$parent"
}

# Newest git activity timestamp for a worktree.
#
# purge's is_recently_modified reads the directory's own mtime, which does not
# move when a file deep inside the tree is edited, so a worktree in active use
# can look ancient. The per-worktree git dir records what actually happened in
# THIS worktree - checkouts and commits through HEAD and logs/HEAD, git command
# activity through index and the dir itself - so take the age from there, and
# keep the working dir mtime in the set so a fresh top-level file still counts.
mole_purge_worktree_activity_epoch() {
    local wt="$1"
    local gitdir="${2:-}"
    local newest=0
    local candidate=""
    local mtime=""

    [[ -n "$gitdir" ]] || gitdir=$(mole_purge_worktree_gitdir "$wt") || return 1

    for candidate in "$wt" "$gitdir" "$gitdir/HEAD" "$gitdir/index" "$gitdir/logs/HEAD"; do
        [[ -e "$candidate" ]] || continue
        mtime=$(get_file_mtime "$candidate")
        [[ "$mtime" =~ ^[0-9]+$ ]] || continue
        [[ "$mtime" -gt "$newest" ]] && newest="$mtime"
    done

    [[ "$newest" -gt 0 ]] || return 1
    printf '%s\n' "$newest"
}

# Every gitignored entry in the worktree must be a known purge target.
#
# This is the guard that makes the rest meaningful. `git status --porcelain` is
# silent about ignored files, so a gitignored `.env`, a local sqlite database or
# an untracked scratch note is invisible to the clean/unpushed guards, and
# "clean plus old" would delete the only copy. Nothing can separate that from a
# `node_modules` automatically except an explicit whitelist check, so run one:
# `--ignored` reports each ignored entry (a wholly ignored directory collapses
# to one line), and every single one has to match MOLE_PURGE_TARGETS by name.
# One unrecognized ignored entry keeps the whole worktree.
mole_purge_worktree_ignored_all_known() {
    local wt="$1"
    local ignored=""
    local git_rc=0
    local line=""
    local candidate=""
    local target=""
    local known=false

    ignored=$(_mole_purge_git_walk "$wt" status --porcelain --ignored) || git_rc=$?
    if [[ $git_rc -ne 0 ]]; then
        debug_log "Keeping worktree with unreadable ignored-entry list: $wt"
        return 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == '!! '* ]] || continue
        candidate="${line#!! }"
        candidate="${candidate%/}"
        candidate="${candidate##*/}"
        [[ -n "$candidate" ]] || continue

        known=false
        for target in "${MOLE_PURGE_TARGETS[@]}"; do
            if [[ "$candidate" == "$target" ]]; then
                known=true
                break
            fi
        done
        if [[ "$known" == "false" ]]; then
            debug_log "Keeping worktree with ignored entry outside the purge whitelist ($candidate): $wt"
            return 1
        fi
    done <<< "$ignored"

    return 0
}

# Returns 0 only when a worktree is provably reclaimable. Five independent
# guards, any one of which keeps it:
#
#   recent    - git activity inside the age bar; a clean, fully pushed,
#               remote-backed worktree can still be the one in use right now
#   no remote - nothing to restore the checkout from
#   dirty     - uncommitted or untracked changes
#   unpushed  - a commit reachable from HEAD that no remote-tracking ref has
#   opaque    - an ignored entry that is not a known rebuildable artifact
#
# Staleness is read first, before any git call that could touch the git dir.
mole_purge_worktree_is_reclaimable() {
    local wt="$1"
    local now="${2:-}"
    local min_age_days="${3:-$MOLE_PURGE_WORKTREE_MIN_AGE_DAYS}"
    local gitdir=""
    local activity=""
    local age_days=0
    local unpushed=""

    [[ -n "$wt" && -d "$wt" ]] || return 1
    # A linked worktree has `.git` as a pointer file; a main worktree has a dir.
    [[ -f "$wt/.git" ]] || return 1

    gitdir=$(mole_purge_worktree_gitdir "$wt") || return 1
    case "$gitdir" in
        */worktrees/*) ;;
        *) return 1 ;;
    esac

    activity=$(mole_purge_worktree_activity_epoch "$wt" "$gitdir") || return 1
    [[ -n "$now" && "$now" =~ ^[0-9]+$ ]] || now=$(get_epoch_seconds)
    [[ "$min_age_days" =~ ^[0-9]+$ ]] || min_age_days="$MOLE_PURGE_WORKTREE_MIN_AGE_DAYS"
    age_days=$(((now - activity) / 86400))
    if [[ $age_days -lt $min_age_days ]]; then
        debug_log "Keeping worktree with git activity ${age_days}d ago: $wt"
        return 1
    fi

    local remotes=""
    local git_rc=0
    remotes=$(_mole_purge_git "$wt" remote) || git_rc=$?
    if [[ $git_rc -ne 0 ]]; then
        debug_log "Keeping worktree with unreadable remote list: $wt"
        return 1
    fi
    if [[ -z "$remotes" ]]; then
        debug_log "Keeping worktree whose repo has no remote: $wt"
        return 1
    fi

    # Fail closed on a failed or timed-out status: it returns no output, which
    # is indistinguishable from a clean tree.
    local status_output=""
    git_rc=0
    status_output=$(_mole_purge_git_walk "$wt" status --porcelain) || git_rc=$?
    if [[ $git_rc -ne 0 ]]; then
        debug_log "Keeping worktree with unreadable status (git exit $git_rc): $wt"
        return 1
    fi
    if [[ -n "$status_output" ]]; then
        debug_log "Keeping worktree with uncommitted changes: $wt"
        return 1
    fi

    unpushed=$(_mole_purge_git_walk "$wt" rev-list --count HEAD --not --remotes) || unpushed=""
    if [[ ! "$unpushed" =~ ^[0-9]+$ ]]; then
        debug_log "Keeping worktree with unreadable commit state: $wt"
        return 1
    fi
    if [[ "$unpushed" -ne 0 ]]; then
        debug_log "Keeping worktree with $unpushed unpushed commit(s): $wt"
        return 1
    fi

    mole_purge_worktree_ignored_all_known "$wt" || return 1

    return 0
}

# A repo authorizes worktree removal only when the repo itself sits inside (or
# is) a configured purge search root. The worktree it points at may live
# anywhere - $TMPDIR agent checkouts are the common case, and finding those is
# the whole point of asking git instead of scanning locations.
mole_purge_repo_under_search_paths() {
    local repo="$1"
    local physical_repo=""
    local search_path=""
    local physical_root=""

    [[ -n "$repo" && "$repo" == /* ]] || return 1
    [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]] || return 1

    if [[ -d "$repo" ]]; then
        physical_repo=$(cd "$repo" 2> /dev/null && pwd -P) || physical_repo=""
    fi

    for search_path in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -n "$search_path" ]] || continue
        [[ "$search_path" == "/" ]] || search_path="${search_path%/}"
        [[ -n "$search_path" ]] || continue

        if [[ "$repo" == "$search_path" || "$repo" == "$search_path/"* ]]; then
            return 0
        fi

        # Configured roots may use symlink aliases while git reports physical
        # paths (/var vs /private/var), so compare canonical forms too.
        if [[ -n "$physical_repo" && -d "$search_path" ]]; then
            physical_root=$(cd "$search_path" 2> /dev/null && pwd -P) || physical_root=""
            if [[ -n "$physical_root" ]] &&
                { [[ "$physical_repo" == "$physical_root" ]] || [[ "$physical_repo" == "$physical_root/"* ]]; }; then
                return 0
            fi
        fi
    done

    return 1
}

# Last gate before removal, and the worktree counterpart of
# is_safe_configured_purge_artifact. That predicate rejects a direct child of a
# search root by design, which is where agent worktrees usually sit, and where
# it does admit one (a worktree nested a level deeper) it admits it for the
# wrong reason: depth, not reproducibility. So worktrees get their own gate,
# re-deriving the whole authority chain from git - a repo under a configured
# search root still registering this exact path, with every guard still
# holding. Never skip it: it is the last thing standing between a stale menu
# entry and an irreversible removal.
is_safe_purge_worktree() {
    local path="$1"
    local search_path=""
    local parent_repo=""

    [[ -n "$path" && "$path" == /* ]] || return 1
    [[ "$path" != "/" && "$path" != "$HOME" ]] || return 1
    [[ -d "$path" && -f "$path/.git" ]] || return 1
    [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]] || return 1

    # Never a search root itself, nor an ancestor of one.
    for search_path in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -n "$search_path" ]] || continue
        [[ "$search_path" == "/" ]] || search_path="${search_path%/}"
        [[ "$path" == "$search_path" ]] && return 1
        [[ "$search_path" == "$path/"* ]] && return 1
    done

    parent_repo=$(mole_purge_worktree_parent_repo "$path") || return 1
    mole_purge_repo_under_search_paths "$parent_repo" || return 1
    mole_purge_worktree_registrations "$parent_repo" | grep -qxF "$path" || return 1
    mole_purge_worktree_is_reclaimable "$path" || return 1

    return 0
}

# Discover reclaimable worktrees registered by repos under one search root.
# Emits "<worktree_path>\t<parent_repo>\t<activity_epoch>" lines.
#
# Bounded twice, per the long-scan rule: run_with_timeout caps the repo find,
# and a wall-clock deadline stops the per-repo git loop so a machine with
# hundreds of repos degrades to partial results instead of looking hung.
scan_purge_worktrees() {
    local search_root="$1"
    local output_file="$2"
    local max_depth="${3:-6}"
    local now="${4:-}"
    local budget="${MO_PURGE_SCAN_TIMEOUT_SEC:-60}"
    local -a prune_expr=()
    local repos_raw=""
    local deadline=0
    local index=0
    local git_dir=""
    local repo=""
    local wt=""
    local parent=""
    local activity=""

    : > "$output_file" 2> /dev/null || return 0
    [[ -n "$search_root" && -d "$search_root" ]] || return 0
    command -v git > /dev/null 2>&1 || return 0
    [[ "$max_depth" =~ ^[0-9]+$ ]] || max_depth=6
    [[ -n "$now" && "$now" =~ ^[0-9]+$ ]] || now=$(get_epoch_seconds)
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=60
    deadline=$((now + budget))

    for index in "${!MOLE_PURGE_WORKTREE_PRUNE_DIRS[@]}"; do
        [[ $index -gt 0 ]] && prune_expr+=(-o)
        prune_expr+=(-name "${MOLE_PURGE_WORKTREE_PRUNE_DIRS[$index]}")
    done

    repos_raw=$(mktemp) || return 0
    run_with_timeout "$budget" find "$search_root" -maxdepth "$((max_depth + 1))" \
        \( "${prune_expr[@]}" \) -prune -o \
        -type d -name ".git" -print -prune \
        2> /dev/null > "$repos_raw" || true

    local out_of_budget=false
    while IFS= read -r git_dir; do
        [[ -n "$git_dir" ]] || continue
        [[ "$out_of_budget" == "false" ]] || break
        if [[ $(get_epoch_seconds) -ge $deadline ]]; then
            debug_log "Worktree scan budget exhausted under $search_root"
            break
        fi
        repo="${git_dir%/.git}"
        [[ -n "$repo" && -d "$repo" ]] || continue
        # git creates <gitdir>/worktrees on the first `worktree add`, so its
        # absence means the repo has never had a linked worktree and
        # `worktree list` could only echo the main one. Skipping the call here
        # is what keeps a tree of hundreds of ordinary repos cheap to scan.
        [[ -d "$git_dir/worktrees" ]] || continue

        while IFS= read -r wt; do
            [[ -n "$wt" ]] || continue
            # Checkpoint inside the loop too, not only between repos: a single
            # repo can register several worktrees on a slow volume (a network
            # or iCloud-backed checkout), and each `status` may burn its full
            # ceiling, so the per-root budget has to be able to cut in here.
            if [[ $(get_epoch_seconds) -ge $deadline ]]; then
                debug_log "Worktree scan budget exhausted while inspecting $repo"
                out_of_budget=true
                break
            fi
            mole_purge_worktree_is_reclaimable "$wt" "$now" || continue
            parent=$(mole_purge_worktree_parent_repo "$wt") || continue
            activity=$(mole_purge_worktree_activity_epoch "$wt") || continue
            printf '%s\t%s\t%s\n' "$wt" "$parent" "$activity"
        done < <(mole_purge_worktree_registrations "$repo")
    done < "$repos_raw" >> "$output_file"

    rm -f "$repos_raw" 2> /dev/null || true
    return 0
}

# Drop the parent repo's registration once a worktree's working dir is gone.
# Without this the repo keeps a dangling entry that `git worktree list` reports
# as prunable, which is the second half of the mess this feature cleans up.
# Agent tools lock their worktrees and a plain prune skips a locked entry even
# when its directory has vanished, so unlock first (same reason as #985).
# prune --expire=now also drops registrations that were already dead before
# this run - metadata only, and only in a repo the user just purged from.
mole_purge_worktree_prune() {
    local wt="$1"
    local parent_repo="$2"

    [[ -n "$wt" && -n "$parent_repo" ]] || return 0
    [[ -d "$parent_repo" ]] || return 0
    # Dry-run and failed removals leave the working dir in place; a live
    # registration must never be pruned.
    [[ ! -d "$wt" ]] || return 0

    _mole_purge_git "$parent_repo" worktree unlock "$wt" > /dev/null 2>&1 || true
    _mole_purge_git "$parent_repo" worktree prune --expire=now > /dev/null 2>&1 || true
    return 0
}

# Remove one worktree, then reap its registration.
#
# Delete mode is Trash, not purge's usual permanent safe_remove: `git status
# --porcelain` reports nothing for ignored files, so a gitignored .env or a
# local sqlite database inside an otherwise clean worktree is invisible to the
# guards and would be unrecoverable. Everything else purge removes is matched
# by name and rebuildable; a worktree is the one category where the guards
# cannot see all of what is being deleted, so it gets the recoverable path.
mole_purge_remove_worktree() {
    local wt="$1"
    local parent_repo="${2:-}"
    local previous_mode="${MOLE_DELETE_MODE:-}"
    local had_mode=false
    local rc=0

    [[ -n "$wt" ]] || return 1

    # Explicit if/fi, not `[[ ... ]] && had_mode=true`: the short-circuit form
    # yields exit 1 whenever MOLE_DELETE_MODE is unset, which is the normal case
    # here and would make this line the function's failure under a caller that
    # reads the status.
    if [[ -n "${MOLE_DELETE_MODE+x}" ]]; then
        had_mode=true
    fi
    export MOLE_DELETE_MODE="trash"
    mole_delete "$wt" || rc=$?
    if [[ "$had_mode" == "true" ]]; then
        export MOLE_DELETE_MODE="$previous_mode"
    else
        unset MOLE_DELETE_MODE
    fi

    [[ $rc -eq 0 ]] || return "$rc"
    mole_purge_worktree_prune "$wt" "$parent_repo"
    return 0
}
