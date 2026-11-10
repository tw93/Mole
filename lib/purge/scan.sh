#!/bin/bash
# Mole CLI (Linux) - purge: project build output that its tool rebuilds.
#
# A folder is a candidate only when its name is a known build output AND the
# folder beside it proves which tool made it (node_modules next to
# package.json, target next to Cargo.toml or pom.xml). Names alone prove
# nothing: a hand-written build/ or vendor/ looks the same. Every candidate is
# then probed for authored content (a .git inside, Anchor keypairs, files git
# tracks), for a process working in its project, and for activity in the last
# seven days. A probe that cannot finish never counts as "safe".
#
# Rules follow Mole CLI (macOS) lib/clean/purge_shared.sh and project.sh, and
# kondo's and npkill's target lists (docs/oss-research.md), re-implemented for
# GNU find and /proc.

set -euo pipefail

if [[ -n "${MOLE_PURGE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PURGE_LOADED=1

MOLE_PURGE_CONFIG_FILE="$MOLE_CONFIG_HOME/mole/purge_paths"
readonly MOLE_PURGE_MIN_AGE_DAYS=7
readonly MOLE_PURGE_MAX_DEPTH=6
# Seconds: one root's walk, one candidate's content probe, one size. Plain
# globals, not read from the environment: a tuning variable is a setting.
MOLE_PURGE_WALK_TIMEOUT=120
MOLE_PURGE_PROBE_TIMEOUT=20

# name|evidence beside it (any one; *.ext is a glob in the project folder;
# "tag" means the folder carries its own CACHEDIR.TAG instead).
mole_purge_target_table() {
    cat << 'TABLE'
node_modules|package.json
target|Cargo.toml pom.xml
build|build.gradle build.gradle.kts settings.gradle settings.gradle.kts package.json pubspec.yaml CMakeLists.txt pyproject.toml setup.py
dist|package.json pyproject.toml setup.py
.venv|pyproject.toml requirements.txt setup.py Pipfile
venv|pyproject.toml requirements.txt setup.py Pipfile
.tox|tox.ini pyproject.toml setup.cfg
.nox|noxfile.py
.pytest_cache|tag
.mypy_cache|tag
.ruff_cache|tag
.gradle|build.gradle build.gradle.kts settings.gradle settings.gradle.kts
.cxx|build.gradle build.gradle.kts
.next|package.json
.nuxt|package.json
.output|package.json
.turbo|package.json
.parcel-cache|package.json
.angular|package.json
.svelte-kit|package.json
.astro|package.json
.expo|package.json
coverage|package.json pyproject.toml
vendor|composer.json
bin|*.csproj *.fsproj *.vbproj
obj|*.csproj *.fsproj *.vbproj
.dart_tool|pubspec.yaml
.zig-cache|build.zig
zig-out|build.zig
.build|Package.swift
.terragrunt-cache|terragrunt.hcl
_build|mix.exs dune-project rebar.config
.stack-work|stack.yaml
cmake-build-*|CMakeLists.txt
TABLE
}

# Folders discovery never treats as a project container: media folders, and
# homes of tools whose caches hold whole projects (GOPATH's module cache has a
# go.mod in every module and read-only files).
readonly MOLE_PURGE_NOT_CONTAINERS=" Desktop Documents Downloads Music Pictures Videos Public Templates go snap "

mole_purge_default_roots() {
    local d
    for d in www dev Dev Projects projects GitHub github Code code Workspace workspace Repos repos src Development; do
        printf '%s\n' "$HOME/$d"
    done
    # Agent worktree containers sit under dot folders, which the walk prunes;
    # naming them keeps the checkouts inside in scope. The worktrees
    # themselves are never removed, only build output inside them.
    printf '%s\n' "$HOME/.codex/worktrees" "$HOME/.claude/worktrees"
}

# 0 when $1's name is a purge target; MOLE_PURGE_EVIDENCE gets its evidence.
MOLE_PURGE_EVIDENCE=""
mole_purge_target_of() {
    local base="${1##*/}" name evidence
    while IFS='|' read -r name evidence; do
        # shellcheck disable=SC2053  # cmake-build-* is a glob on purpose.
        if [[ "$base" == $name ]]; then
            MOLE_PURGE_EVIDENCE="$evidence"
            return 0
        fi
    done < <(mole_purge_target_table)
    return 1
}

mole_dir_has_cachedir_tag() {
    local tag="$1/CACHEDIR.TAG" head
    [[ -f "$tag" && ! -L "$tag" ]] || return 1
    head=$(LC_ALL=C head -c 43 -- "$tag" 2> /dev/null) || return 1
    [[ "$head" == "Signature: 8a477f597d28d172789f06886806bc55" ]]
}

# 0 when the folder beside $1 proves which tool made $1.
mole_purge_has_evidence() {
    local path="$1" project="${1%/*}" item
    mole_purge_target_of "$path" || return 1
    local -a evidence=()
    read -ra evidence <<< "$MOLE_PURGE_EVIDENCE"
    for item in "${evidence[@]}"; do
        if [[ "$item" == tag ]]; then
            mole_dir_has_cachedir_tag "$path" && return 0
        elif [[ "$item" == *'*'* ]]; then
            # The project part stays literal; only the evidence is a glob.
            local -a hits=()
            # shellcheck disable=SC2206  # $item is the table's own glob.
            hits=("$project"/$item)
            [[ -e "${hits[0]}" ]] && return 0
        elif [[ -f "$project/$item" && ! -L "$project/$item" ]]; then
            return 0
        fi
    done
    return 1
}

# The folder holding the nearest .git (a folder, or a worktree's file) at or
# above $1 and below the home; 1 when there is none. A repository at the home
# itself (dotfiles kept as ~/.git with everything ignored) says nothing about
# the folders in it.
mole_purge_git_top() {
    local d="$1" home_real
    home_real=$(readlink -e -- "$HOME" 2> /dev/null) || home_real="$HOME"
    while [[ -n "$d" && "$d" != / && "$d" != "$home_real" && "$d" != "$HOME" ]]; do
        if [[ -e "$d/.git" ]]; then
            printf '%s' "$d"
            return 0
        fi
        d="${d%/*}"
    done
    return 1
}

# Names a person also gives to folders they write by hand (an unpacked
# release ships its program in dist/, a project keeps scripts in bin/). These
# are offered only inside a git repository, where the tracked-files probe can
# tell build output from source.
mole_purge_weak_name() {
    case "${1##*/}" in
        build | dist | coverage | vendor | bin | obj | _build) return 0 ;;
    esac
    return 1
}

# Extra checks a few names need beyond the evidence beside them.
mole_purge_shape_ok() {
    local path="$1"
    case "${path##*/}" in
        .venv | venv) [[ -f "$path/pyvenv.cfg" && ! -L "$path/pyvenv.cfg" ]] ;;
        # .NET writes bin/Debug or bin/Release; any other bin/ is a project's
        # scripts.
        bin) [[ -d "$path/Debug" || -d "$path/Release" ]] ;;
        *) return 0 ;;
    esac
}

# Project roots to scan, physical, into MOLE_PURGE_ROOTS: the config file
# when it lists any path, else the defaults that exist plus home folders that
# hold a project within two levels. A root inside another root is dropped (the
# outer walk covers it). Returns 2 when the config file cannot be read.
MOLE_PURGE_ROOTS=()
MOLE_PURGE_ROOTS_FROM_CONFIG=false
mole_purge_load_roots() {
    local line path real home_real
    local -a roots=() kept=()
    MOLE_PURGE_ROOTS=()
    MOLE_PURGE_ROOTS_FROM_CONFIG=false
    if [[ -f "$MOLE_PURGE_CONFIG_FILE" ]]; then
        [[ -r "$MOLE_PURGE_CONFIG_FILE" ]] || return 2
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" == "~" ]] && line="$HOME"
            # shellcheck disable=SC2088  # A literal ~/ from the file, expanded here.
            [[ "$line" == "~/"* ]] && line="$HOME/${line#"~/"}"
            [[ "$line" == /* ]] || continue
            roots+=("$line")
        done < "$MOLE_PURGE_CONFIG_FILE"
        [[ ${#roots[@]} -gt 0 ]] && MOLE_PURGE_ROOTS_FROM_CONFIG=true
    fi
    if [[ "$MOLE_PURGE_ROOTS_FROM_CONFIG" == false ]]; then
        while IFS= read -r path; do roots+=("$path"); done < <(mole_purge_default_roots)
        local dir name
        for dir in "$HOME"/*/; do
            dir="${dir%/}"
            [[ -d "$dir" && ! -L "$dir" ]] || continue
            name="${dir##*/}"
            [[ "$MOLE_PURGE_NOT_CONTAINERS" == *" $name "* ]] && continue
            mole_purge_target_of "$dir" && continue
            if mole_c timeout 10 find "$dir" -mindepth 1 -maxdepth 2 -name '.*' -prune -o -type f \
                \( -name package.json -o -name Cargo.toml -o -name go.mod -o -name pyproject.toml \
                -o -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name composer.json \
                -o -name pubspec.yaml -o -name CMakeLists.txt -o -name build.zig -o -name mix.exs \) \
                -print -quit 2> /dev/null | grep -q .; then
                roots+=("$dir")
            fi
        done
    fi
    home_real=$(readlink -e -- "$HOME" 2> /dev/null) || home_real="$HOME"
    local -A seen=()
    for path in "${roots[@]+"${roots[@]}"}"; do
        real=$(readlink -e -- "$path" 2> /dev/null) || continue
        [[ -d "$real" ]] || continue
        # The whole filesystem or the whole home is not a project folder: the
        # walk would reach editor extensions and tool caches that ship
        # package.json beside node_modules.
        [[ "$real" == / || "$real" == "$home_real" || "$home_real" == "$real/"* ]] && continue
        mole_purge_protected "$real" && continue
        [[ -n "${seen[$real]:-}" ]] && continue
        seen[$real]=1
        kept+=("$real")
    done
    local r o inner
    for r in "${kept[@]+"${kept[@]}"}"; do
        inner=false
        for o in "${kept[@]}"; do
            [[ "$r" != "$o" && "$r" == "$o/"* ]] && inner=true && break
        done
        [[ "$inner" == false ]] && MOLE_PURGE_ROOTS+=("$r")
    done
    return 0
}

# Candidate folders under one physical root, one per line. Matched names are
# not descended into, dot folders that are not targets are pruned (editor and
# tool homes), and the walk stays on the root's filesystem. Returns 124 when
# the walk ran out of time (what it found so far is still printed).
mole_purge_walk() {
    local root="$1" name
    local -a names=()
    while IFS='|' read -r name _; do
        [[ ${#names[@]} -gt 0 ]] && names+=(-o)
        names+=(-name "$name")
    done < <(mole_purge_target_table)
    local rc=0
    mole_c timeout "$MOLE_PURGE_WALK_TIMEOUT" find "$root" -xdev -mindepth 1 -maxdepth "$MOLE_PURGE_MAX_DEPTH" \
        \( -type d \( "${names[@]}" \) -print -prune \) -o \
        \( -name '.*' -prune \) 2> /dev/null || rc=$?
    [[ $rc -eq 124 ]] && return 124
    return 0
}

# 0 when files inside $1 hold authored work: a git repository, Solana/Anchor
# keypairs, or any file git tracks. 1 when the probes finished and found none;
# 2 when one could not finish (callers treat 2 as "keep"). A .git above the
# folder that git cannot read (a moved main repository behind a worktree, no
# git installed, "dubious ownership") is 2, never "nothing tracked".
mole_purge_has_authored() {
    local path="$1" out rc=0 repo rel n
    out=$(mole_c timeout "$MOLE_PURGE_PROBE_TIMEOUT" find "$path" \( -name .git -o -name '*-keypair.json' \) -print -quit 2> /dev/null) || rc=$?
    [[ $rc -eq 0 ]] || return 2
    [[ -z "$out" ]] || return 0
    mole_purge_git_top "${path%/*}" > /dev/null || return 1
    command -v git > /dev/null 2>&1 || return 2
    # The user's GIT_DIR or GIT_WORK_TREE (a dotfiles repo) must not answer
    # for the project's own repository.
    repo=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR LC_ALL=C LANG=C \
        git -C "${path%/*}" rev-parse --show-toplevel 2> /dev/null) || return 2
    repo=$(readlink -e -- "$repo" 2> /dev/null) || return 2
    rel="${path#"$repo"/}"
    [[ "$rel" != "$path" && -n "$rel" ]] || return 2
    rc=0
    n=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR LC_ALL=C LANG=C \
        timeout "$MOLE_PURGE_PROBE_TIMEOUT" git -C "$repo" ls-files -z -- ":(literal)$rel" 2> /dev/null | wc -c) || rc=$?
    [[ $rc -eq 0 && "$n" =~ ^[0-9]+$ ]] || return 2
    ((n == 0)) && return 1
    return 0
}

# node_modules a package manager can put back: a lockfile beside it and the
# manager's own install record inside, with no file changed after that record
# (a patched package, a local edit). Anything else is kept. 0 = keep.
mole_purge_node_modules_kept() {
    local path="$1" project="${1%/*}" pair lock record marker="" out rc=0
    for pair in package-lock.json:.package-lock.json npm-shrinkwrap.json:.package-lock.json \
        pnpm-lock.yaml:.modules.yaml yarn.lock:.yarn-integrity yarn.lock:.yarn-state.yml \
        bun.lock:.bun-tag bun.lockb:.bun-tag; do
        lock="${pair%%:*}"
        record="${pair#*:}"
        if [[ -f "$project/$lock" && ! -L "$project/$lock" && -f "$path/$record" && ! -L "$path/$record" ]]; then
            marker="$path/$record"
            break
        fi
    done
    [[ -n "$marker" ]] || return 0
    local pattern
    pattern=$(printf '%s' "$path/.cache" | sed 's/[][*?\\]/\\&/g')
    out=$(mole_c timeout "$MOLE_PURGE_PROBE_TIMEOUT" find "$path" -path "$pattern" -prune -o \
        -type f -newer "$marker" -print -quit 2> /dev/null) || rc=$?
    [[ $rc -eq 0 ]] || return 0
    [[ -n "$out" ]]
}

# Why $1 is never offered, one short reason, or "ok" when it may be. A caller
# that gets anything but "ok" (no output at all included) keeps the folder.
mole_purge_refusal() {
    local path="$1" rc=0
    [[ -d "$path" && ! -L "$path" ]] || { echo "not a folder"; return; }
    [[ -O "$path" ]] || { echo "not yours"; return; }
    mole_purge_has_evidence "$path" || { echo "no project file beside it"; return; }
    mole_purge_shape_ok "$path" || { echo "not build output"; return; }
    if mole_purge_weak_name "$path" && ! mole_purge_git_top "${path%/*}" > /dev/null; then
        echo "not in a git repository"
        return
    fi
    mole_purge_has_authored "$path" || rc=$?
    case $rc in
        0) echo "holds tracked or authored files"; return ;;
        1) ;;
        *) echo "could not be checked in time"; return ;;
    esac
    if [[ "${path##*/}" == node_modules ]] && mole_purge_node_modules_kept "$path"; then
        echo "no lockfile record, or changed after install"
        return
    fi
    echo ok
}

# The user's process ids, minus Mole itself, the shells that started it and
# Mole's own helpers: a shell sitting in a project folder is not working in
# it. The walk up stops at the first process that is not a shell, so an editor
# whose terminal started Mole still counts.
# mo and mole are Mole's own router, named by its script for comm.
readonly MOLE_PURGE_SHELLS=" bash zsh fish sh dash ksh mksh nu xonsh tcsh csh elvish mo mole "
mole_purge_ppid() {
    local key value
    { while read -r key value _; do
        [[ "$key" == PPid: ]] && printf '%s' "$value" && return 0
    done < "$1/status"; } 2> /dev/null || true
    return 0
}
# 0 when process folder $1 is the user's, 1 when it is someone else's or the
# process has exited, 2 when its status cannot be read although it still runs.
# mole_pid_mine answers 1 for both of the last two, which suits its callers;
# purge needs to know it missed a process.
mole_purge_pid_mine() {
    local key uid found=""
    [[ -n "$_MOLE_UID" ]] || _MOLE_UID=$(id -u)
    { while read -r key uid _; do
        if [[ "$key" == Uid: ]]; then
            found="$uid"
            break
        fi
    done < "$1/status"; } 2> /dev/null || true
    if [[ -n "$found" ]]; then
        [[ "$found" == "$_MOLE_UID" ]]
        return
    fi
    [[ -e "$1" ]] && return 2
    return 1
}

# The user's other processes, one pid a line, then MOLE_PURGE_PIDS_DONE. A
# process it could not place prints MOLE_PURGE_PIDS_UNKNOWN instead of a pid.
readonly MOLE_PURGE_PIDS_DONE="done"
readonly MOLE_PURGE_PIDS_UNKNOWN="unknown"
mole_purge_other_pids() {
    local -A skip=()
    local pid="$$" comm dir ppid rc
    skip[$$]=1
    pid=$(mole_purge_ppid "$_MOLE_PROC_ROOT/$$")
    while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; do
        comm=$(cat "$_MOLE_PROC_ROOT/$pid/comm" 2> /dev/null) || break
        [[ "$MOLE_PURGE_SHELLS" == *" $comm "* ]] || break
        skip[$pid]=1
        pid=$(mole_purge_ppid "$_MOLE_PROC_ROOT/$pid")
    done
    [[ -n "${BASHPID:-}" ]] && skip[$BASHPID]=1
    for dir in "$_MOLE_PROC_ROOT"/[0-9]*; do
        pid="${dir##*/}"
        [[ -n "${skip[$pid]:-}" ]] && continue
        rc=0
        mole_purge_pid_mine "$dir" || rc=$?
        if ((rc == 2)); then
            printf '%s\n' "$MOLE_PURGE_PIDS_UNKNOWN"
            continue
        fi
        ((rc == 0)) || continue
        # Mole's own helpers (its spinner) start in Mole's folder too.
        [[ "$(mole_purge_ppid "$dir")" == "$$" ]] && continue
        printf '%s\n' "$pid"
    done
    printf '%s\n' "$MOLE_PURGE_PIDS_DONE"
    return 0
}

# 0 when listing status $1 finished. xargs reports 123 for any child that failed,
# so it counts only when error file $2 shows nothing but processes that exited or
# that the kernel will not let this user read (ssh-agent), which hold nothing
# this can learn. A find that could not start or ran out of descriptors is also
# 123, and a timeout (a stuck process can block reading its maps) is 124.
mole_purge_listing_finished() {
    [[ "$1" -eq 0 ]] && return 0
    [[ "$1" -eq 123 && -s "$2" ]] || return 1
    local line
    while IFS= read -r line; do
        case "$line" in
            *": Permission denied" | *": Operation not permitted" | *": No such file or directory" | *": No such process") ;;
            *) return 1 ;;
        esac
    done < "$2"
    return 0
}

# 0 when the open and mapped files of the process folders in $2... were all
# printed, NUL separated, with their errors collected in $1.
mole_purge_proc_listings() {
    local errors="$1"
    shift
    local -a statuses
    printf '%s/fd\0' "$@" |
        timeout "$MOLE_PURGE_PROBE_TIMEOUT" xargs -0 sh -c 'exec find "$@" -mindepth 1 -maxdepth 1 -type l -printf "%l\\0"' sh 2>> "$errors"
    statuses=("${PIPESTATUS[@]}")
    mole_purge_listing_finished "${statuses[1]}" "$errors" || return 1
    # Each listing answers for itself: an error above must not excuse a silent one here.
    : > "$errors"
    printf '%s/maps\0' "$@" |
        timeout "$MOLE_PURGE_PROBE_TIMEOUT" xargs -0 cat 2>> "$errors" |
        sed -n 's|^[^/]*\(/.*\)$|\1|p' | sort -u | tr '\n' '\0'
    statuses=("${PIPESTATUS[@]}")
    mole_purge_listing_finished "${statuses[1]}" "$errors" || return 1
    [[ "${statuses[2]}" -eq 0 && "${statuses[3]}" -eq 0 && "${statuses[4]}" -eq 0 ]]
}

# Prints the listings, then MOLE_PURGE_HOLDERS_DONE once all of it was read; any
# other ending leaves the mark out. One process each would cost seconds on a desktop.
readonly MOLE_PURGE_HOLDERS_DONE="mole-purge-holders-done"
mole_purge_proc_holders() {
    set +e
    export LC_ALL=C
    (($# > 0)) || {
        printf '%s\0' "$MOLE_PURGE_HOLDERS_DONE"
        return 0
    }
    local errors finished=0
    errors=$(mktemp) || return 0
    mole_purge_proc_listings "$errors" "$@" || finished=1
    rm -f "$errors" # SAFE: this function's own mktemp file.
    ((finished == 0)) && printf '%s\0' "$MOLE_PURGE_HOLDERS_DONE"
    return 0
}

# Every folder the user's other processes work in: working folders, programs,
# path arguments, an activated VIRTUAL_ENV, open files and mapped libraries,
# into MOLE_PURGE_PROC_PATHS. A process elsewhere holding one file of a build
# folder shows only in the last two.
# MOLE_PURGE_PROC_OK is false when /proc cannot be read, a process could not be
# placed, or the open and mapped files could not all be listed, and then every project counts as busy.
MOLE_PURGE_PROC_PATHS=()
MOLE_PURGE_PROC_OK=false
mole_purge_proc_snapshot() {
    local pid dir path arg
    local -a pid_dirs=()
    local -A seen=()
    MOLE_PURGE_PROC_PATHS=()
    MOLE_PURGE_PROC_OK=false
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 2
    local pids_done=false pids_missed=false
    while IFS= read -r pid; do
        case "$pid" in
            "$MOLE_PURGE_PIDS_DONE")
                pids_done=true
                continue
                ;;
            "$MOLE_PURGE_PIDS_UNKNOWN")
                pids_missed=true
                continue
                ;;
        esac
        dir="$_MOLE_PROC_ROOT/$pid"
        pid_dirs+=("$dir")
        for path in "$(readlink -- "$dir/cwd" 2> /dev/null)" "$(readlink -- "$dir/exe" 2> /dev/null)"; do
            [[ "$path" == /* && -z "${seen[$path]:-}" ]] || continue
            seen[$path]=1
            MOLE_PURGE_PROC_PATHS+=("$path")
        done
        { while IFS= read -r -d '' arg; do
            arg="${arg#--*=}"
            [[ "$arg" == /* && -z "${seen[$arg]:-}" ]] || continue
            seen[$arg]=1
            MOLE_PURGE_PROC_PATHS+=("$arg")
        done < "$dir/cmdline"; } 2> /dev/null || true
        { while IFS= read -r -d '' arg; do
            [[ "$arg" == VIRTUAL_ENV=/* ]] || continue
            arg="${arg#VIRTUAL_ENV=}"
            [[ -z "${seen[$arg]:-}" ]] || continue
            seen[$arg]=1
            MOLE_PURGE_PROC_PATHS+=("$arg")
        done < "$dir/environ"; } 2> /dev/null || true
    done < <(mole_purge_other_pids)
    # A process it could not place, or a list cut short, could be the holder.
    [[ "$pids_done" == true && "$pids_missed" == false ]] || return 2
    local finished=false
    while IFS= read -r -d '' path; do
        case "$path" in
            "$MOLE_PURGE_HOLDERS_DONE") finished=true ;;
            # A shared library or device is in every process and in no project.
            /usr/lib/* | /usr/share/* | /lib/* | /lib64/* | /dev/* | /proc/* | /sys/*) ;;
            /*)
                if [[ -z "${seen[$path]:-}" ]]; then
                    seen[$path]=1
                    MOLE_PURGE_PROC_PATHS+=("$path")
                fi
                ;;
        esac
    done < <(mole_purge_proc_holders "${pid_dirs[@]+"${pid_dirs[@]}"}")
    # An unfinished answer could hide a holder, and that is a failed snapshot.
    [[ "$finished" == true ]] || return 2
    MOLE_PURGE_PROC_OK=true
    return 0
}

# 0 when folder $1 is a project of its own (a repository or a project file),
# as opposed to a folder that only holds projects.
mole_purge_is_project_dir() {
    local d="$1" f
    for f in .git package.json pnpm-workspace.yaml Cargo.toml go.mod pyproject.toml pom.xml \
        build.gradle build.gradle.kts settings.gradle settings.gradle.kts composer.json pubspec.yaml \
        CMakeLists.txt build.zig mix.exs; do
        [[ -e "$d/$f" ]] && return 0
    done
    return 1
}

# 0 when a process from the last snapshot works inside project folder $1, or
# sits in a folder above it, up to the scan root $2, that is a project itself
# (a dev server started at a monorepo's top), or when the snapshot could not
# be taken. A folder that only holds projects (~/www) never makes them busy.
mole_purge_project_busy() {
    local project="$1" root="$2" path d
    [[ "$MOLE_PURGE_PROC_OK" == true ]] || return 0
    local -a above=() workspaces=()
    d="${project%/*}"
    while [[ "$d" == "$root" || "$d" == "$root/"* ]]; do
        mole_purge_is_project_dir "$d" && above+=("$d")
        # A JS workspace links its packages into each other's node_modules,
        # so a process anywhere in it may use any package's dependencies.
        if [[ -f "$d/pnpm-workspace.yaml" || -f "$d/lerna.json" || -f "$d/nx.json" || -f "$d/turbo.json" ]] ||
            { [[ -f "$d/package.json" ]] && grep -q '"workspaces"' "$d/package.json" 2> /dev/null; }; then
            workspaces+=("$d")
        fi
        [[ "$d" == "$root" ]] && break
        d="${d%/*}"
    done
    for path in "${MOLE_PURGE_PROC_PATHS[@]+"${MOLE_PURGE_PROC_PATHS[@]}"}"; do
        [[ "$path" == "$project" || "$path" == "$project/"* ]] && return 0
        for d in "${above[@]+"${above[@]}"}"; do
            [[ "$path" == "$d" ]] && return 0
        done
        for d in "${workspaces[@]+"${workspaces[@]}"}"; do
            [[ "$path" == "$d/"* ]] && return 0
        done
    done
    return 1
}

# Activity: prints recent, old or unknown. Recent when the folder or any file
# in it changed within the last seven days.
mole_purge_activity() {
    local path="$1" mtime now out rc=0
    mtime=$(stat -c %Y -- "$path" 2> /dev/null) || { echo unknown; return; }
    now=$(date +%s)
    if (((now - mtime) < MOLE_PURGE_MIN_AGE_DAYS * 86400)); then
        echo recent
        return
    fi
    out=$(mole_c timeout "$MOLE_PURGE_PROBE_TIMEOUT" find "$path" -mtime "-$MOLE_PURGE_MIN_AGE_DAYS" -print -quit 2> /dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo unknown
    elif [[ -n "$out" ]]; then
        echo recent
    else
        echo old
    fi
}

# Size in KB, or empty when du could not finish.
mole_purge_size_kb() {
    local kb
    kb=$(mole_c timeout "$MOLE_PURGE_PROBE_TIMEOUT" du -skx -- "$1" 2> /dev/null | awk 'NR==1 {print $1}') || kb=""
    [[ "$kb" =~ ^[0-9]+$ ]] && printf '%s' "$kb"
    return 0
}

# Device and inode, the identity a removal checks against what was reviewed.
mole_purge_identity() { stat -c '%d:%i' -- "$1" 2> /dev/null; }

# 0 when $1 is a protected location. Below the home it is judged on the
# home's logical spelling, so a home under /var (Fedora Atomic's /var/home)
# keeps its own protected folders without protecting every project in it.
mole_purge_protected() {
    local path="$1" home_real
    home_real=$(readlink -e -- "$HOME" 2> /dev/null) || home_real="$HOME"
    if [[ "$path" == "$home_real/"* ]]; then
        mole_is_protected_path "$HOME/${path#"$home_real"/}"
    else
        mole_is_protected_path "$path"
    fi
}
