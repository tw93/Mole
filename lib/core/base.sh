#!/bin/bash
# Mole CLI (Linux) - base definitions: colors, icons, sizes, paths.
# The look (colors, icons, size format) matches Mole CLI (macOS) on purpose;
# the code is this branch's own.

set -euo pipefail

if [[ -n "${MOLE_BASE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_BASE_LOADED=1

: "${DRY_RUN:=false}"

# Colors: off for NO_COLOR, TERM=dumb or a non-terminal stdout; forced on in tests.
mole_color=0
if [[ -n "${NO_COLOR:-}" ]]; then
    mole_color=0
elif [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    mole_color=1
elif [[ "${TERM:-}" != "dumb" ]] && [[ -t 1 ]]; then
    mole_color=1
fi
if [[ "$mole_color" == "0" ]]; then
    readonly ESC="" GREEN="" BLUE="" CYAN="" YELLOW="" PURPLE="" PURPLE_BOLD="" RED="" GRAY="" NC=""
else
    readonly ESC=$'\033'
    readonly GREEN="${ESC}[0;32m"
    readonly BLUE="${ESC}[1;34m"
    readonly CYAN="${ESC}[0;36m"
    readonly YELLOW="${ESC}[0;33m"
    readonly PURPLE="${ESC}[0;35m"
    readonly PURPLE_BOLD="${ESC}[1;35m"
    readonly RED="${ESC}[0;31m"
    readonly GRAY="${ESC}[0;38;5;244m"
    readonly NC="${ESC}[0m"
fi
unset mole_color

readonly ICON_CONFIRM="◎"
readonly ICON_ADMIN="⚙"
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="◎"
readonly ICON_EMPTY="○"
readonly ICON_SOLID="●"
readonly ICON_LIST="•"
readonly ICON_SUBLIST="↳"
readonly ICON_ARROW="➤"
readonly ICON_DRY_RUN="○"
readonly ICON_REVIEW="⊙"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"

# UTF-8 locale for width math. C.UTF-8 ships with glibc; en_US.UTF-8 often
# is not generated on Arch, and a missing locale silently counts bytes.
readonly MOLE_UTF8_LOCALE="C.UTF-8"

# XDG locations. A relative XDG value is invalid per the spec and ignored.
mole_xdg_dir() {
    local value="$1" fallback="$2"
    if [[ "$value" == /* ]]; then
        # A trailing slash would put "//" into every path built from it.
        while [[ "$value" == */ && "$value" != / ]]; do value="${value%/}"; done
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}
MOLE_CACHE_HOME="$(mole_xdg_dir "${XDG_CACHE_HOME:-}" "$HOME/.cache")"
MOLE_CONFIG_HOME="$(mole_xdg_dir "${XDG_CONFIG_HOME:-}" "$HOME/.config")"
MOLE_DATA_HOME="$(mole_xdg_dir "${XDG_DATA_HOME:-}" "$HOME/.local/share")"
MOLE_STATE_HOME="$(mole_xdg_dir "${XDG_STATE_HOME:-}" "$HOME/.local/state")"
readonly MOLE_CACHE_HOME MOLE_CONFIG_HOME MOLE_DATA_HOME MOLE_STATE_HOME
readonly MOLE_STATE_DIR="$MOLE_STATE_HOME/mole"
readonly MOLE_TRASH_DIR="$MOLE_DATA_HOME/Trash"

# Run an external tool with a fixed C locale before parsing what it prints.
# The Omarchy test VM runs in Chinese; localized text is never matched.
mole_c() { LC_ALL=C LANG=C "$@"; }

bytes_to_human() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || {
        echo "0B"
        return 1
    }
    if ((bytes >= 1000000000)); then
        local scaled=$(((bytes * 100 + 500000000) / 1000000000))
        printf "%d.%02dGB\n" $((scaled / 100)) $((scaled % 100))
    elif ((bytes >= 1000000)); then
        local scaled=$(((bytes * 10 + 500000) / 1000000))
        printf "%d.%01dMB\n" $((scaled / 10)) $((scaled % 10))
    elif ((bytes >= 1000)); then
        printf "%dKB\n" $(((bytes + 500) / 1000))
    else
        printf "%dB\n" "$bytes"
    fi
}

bytes_to_human_kb() {
    bytes_to_human "$((${1:-0} * 1024))"
}

mole_count_label() {
    local count="${1:-0}" noun="$2" plural="${3:-${2}s}"
    if [[ "$count" == "1" ]]; then
        printf '%s %s' "$count" "$noun"
    else
        printf '%s %s' "$count" "$plural"
    fi
}

colorize_human_size() {
    local size_human="$1"
    local size_unit="${size_human%+}"
    local size_color=""
    case "$size_unit" in
        *GB) size_color="$RED" ;;
        *MB) size_color="$YELLOW" ;;
        *KB) size_color="$GREEN" ;;
        *B) size_color="$GRAY" ;;
        *)
            printf '%s' "$size_human"
            return 0
            ;;
    esac
    printf '%s%s%s' "$size_color" "$size_human" "$NC"
}

# Size of one path in KB, staying on its filesystem. Unreadable parts count as
# zero; the exit status of du is not trusted for partial reads.
mole_path_kb() {
    local path="$1" kb
    [[ -e "$path" || -L "$path" ]] || {
        echo 0
        return 0
    }
    kb=$(mole_c du -skx -- "$path" 2> /dev/null) || true
    kb="${kb%%[[:space:]]*}"
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo "$kb"
}

# Free KB on the filesystem holding a path (default $HOME).
get_free_space_kb() {
    local target="${1:-$HOME}" kb
    kb=$(mole_c df -Pk -- "$target" 2> /dev/null | awk 'NR==2 {print $4}') || true
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo "$kb"
}

# Display a home path with ~.
mole_display_path() {
    local path="$1" home="${HOME%/}"
    if [[ -z "$home" ]]; then
        printf '%s' "$path"
    elif [[ "$path" == "$home" ]]; then
        printf '~'
    elif [[ "$path" == "$home/"* ]]; then
        # shellcheck disable=SC2088  # Display HOME as a literal tilde.
        printf '~/%s' "${path#"$home/"}"
    else
        printf '%s' "$path"
    fi
}

# 0 when this Mole runs from the tree install.sh installs (~/.local/share/mole),
# not a source checkout or another copy. mo update refuses to run otherwise and
# the update notice stays quiet, so both ask this one question.
mole_runs_installed_tree() {
    [[ -n "${SCRIPT_DIR:-}" && ! -d "$SCRIPT_DIR/.git" ]] || return 1
    local here there
    here=$(readlink -e -- "$SCRIPT_DIR" 2> /dev/null) || return 1
    there=$(readlink -e -- "$MOLE_DATA_HOME/mole" 2> /dev/null) || return 1
    [[ -n "$here" && "$here" == "$there" ]]
}

# What mo update should do with the latest release $1 (X.Y.Z) over the
# installed version $2, by the numeric X.Y.Z core only (sort -V puts
# 0.1.0-rc1 above 0.1.0 and "unknown" above 1.0.0). Prints one word:
# install (latest is newer, or the installed version is a prerelease of the
# same core, or not a version at all), current (same version), or newer (the
# installed core is above the latest: never downgrade).
mole_update_verdict() {
    local latest="$1" current="$2" i
    local -a l c
    [[ "$latest" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    l=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
        echo install
        return 0
    fi
    c=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    local suffix="${BASH_REMATCH[4]}"
    for i in 0 1 2; do
        if ((10#${l[i]} > 10#${c[i]})); then
            echo install
            return 0
        elif ((10#${l[i]} < 10#${c[i]})); then
            echo newer
            return 0
        fi
    done
    if [[ -n "$suffix" ]]; then echo install; else echo current; fi
}

# Where processes are read from (tests point it at a fake tree).
_MOLE_PROC_ROOT=/proc
_MOLE_UID=""

# Sets the variable named $3 to the first value on the "$2:" line of process
# folder $1's status (Uid: gives the real uid first). 1 when the file cannot
# be read or has no such line.
# One mapfile, never a while-read loop over the file: bash's read takes a
# block, keeps one line and seeks back to the line's end, and /proc builds the
# file again on every read, so a field above changing length (State: R and S)
# moves that offset and the loop skips or repeats lines. Measured 2026-11-20
# on Ubuntu 26.04 while processes came and went: a loop missed Uid: 9 times in
# 51,364 reads of live processes, mapfile never (the file is one block).
mole_proc_status_field() {
    local _line _rest
    local -a _lines=()
    mapfile -t _lines 2> /dev/null < "$1/status" || return 1
    for _line in "${_lines[@]}"; do
        [[ "$_line" == "$2:"* ]] || continue
        _rest="${_line#*:}"
        _rest="${_rest#"${_rest%%[![:space:]]*}"}"
        printf -v "$3" '%s' "${_rest%%[[:space:]]*}"
        return 0
    done
    return 1
}

# 0 when the process's real uid, from the Uid: line of its status, is the
# user's. Not -O on /proc/<pid>: a non-dumpable process (KeePassXC) has its
# /proc folder owned by root although the user runs it.
mole_pid_mine() {
    local uid=""
    [[ -n "$_MOLE_UID" ]] || _MOLE_UID=$(id -u)
    mole_proc_status_field "$1" Uid uid || return 1
    [[ "$uid" == "$_MOLE_UID" ]]
}

# Process running check by exact process name. Returns 0 when running, 1 when
# not, 2 when the probe itself failed (callers treat 2 as running).
# The kernel keeps only 15 bytes of a name in comm, and pgrep -x with a longer
# name warns and answers "not running" (procps-ng 4.0.7: telegram-desktop), so a
# longer name is matched on its first 15 bytes in /proc/<pid>/comm and then
# confirmed by the basename of /proc/<pid>/exe or of argv[0].
mole_process_running() {
    local name rc=1 probe
    for name in "$@"; do
        [[ -n "$name" ]] || continue
        probe=0
        if ((${#name} > 15)); then
            _mole_long_process_running "$name" || probe=$?
        elif command -v pgrep > /dev/null 2>&1; then
            pgrep -x -u "$(id -u)" -- "$name" > /dev/null 2>&1 || probe=$?
        else
            probe=2
        fi
        [[ $probe -eq 0 ]] && return 0
        [[ $probe -eq 1 ]] || rc=2
    done
    return "$rc"
}

# One name longer than comm holds, among the user's own processes.
_mole_long_process_running() {
    local name="$1" short="${1:0:15}" pid comm exe argv0 rc=1
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 2
    for pid in "$_MOLE_PROC_ROOT"/[0-9]*; do
        mole_pid_mine "$pid" || continue
        comm=""
        IFS= read -r comm 2> /dev/null < "$pid/comm" || continue
        [[ "$comm" == "$short" ]] || continue
        exe=$(readlink -- "$pid/exe" 2> /dev/null) || exe=""
        exe="${exe% (deleted)}"
        argv0=""
        IFS= read -r -d '' argv0 2> /dev/null < "$pid/cmdline" || true
        if [[ "${exe##*/}" == "$name" || "${argv0##*/}" == "$name" ]]; then
            return 0
        fi
        # Same 15 bytes and the executable cannot be read (a non-dumpable
        # process): argv[0] may be anything, so the answer is "cannot tell".
        [[ -z "$exe" ]] && rc=2
    done
    return "$rc"
}

# 0 when one of the user's processes runs a file from this list of absolute
# paths (one per line), either as its executable or as one of its arguments
# (a wrapper or interpreter: /usr/bin/code runs electron with
# /usr/lib/code/out/main.js, /usr/bin/discord runs /opt/discord/Discord).
# Directories in the list count only as /usr/lib/<x> or /opt/<x>, the
# folders a single package owns; /usr/lib itself belongs to every package.
# A token --opt=/path counts by its path. A process whose executable cannot be
# read (non-dumpable) and whose argv names no listed file is matched by its
# comm against the first 15 bytes of the list's executables: 2, cannot tell.
# 1 when none does, 2 when /proc cannot be read.
mole_files_running() {
    local list="$1" line pid exe word comm rc=1
    local -A own=() short=()
    while IFS= read -r line; do
        [[ "$line" == /* ]] || continue
        if [[ "$line" == */ ]]; then
            line="${line%/}"
            [[ "$line" =~ ^/usr/lib/[^/]+$ || "$line" =~ ^/opt/[^/]+$ ]] || continue
            case "${line##*/}" in
                systemd | modules | firmware | python* | perl* | ruby | node_modules | girepository-1.0 | \
                    gtk-* | qt* | gstreamer-* | gio | dri | pkgconfig | cmake | udev | sysusers.d | tmpfiles.d) continue ;;
            esac
        fi
        own[$line]=1
        # Every executable file of the package, wherever it lives
        # (/opt/<app>/<App>, /usr/lib/<app>/<app>), and anything in a bin/.
        [[ "$line" == */bin/* || (-f "$line" && -x "$line") ]] && short[${line##*/}]=1
    done <<< "$list"
    [[ ${#own[@]} -gt 0 ]] || return 1
    local name
    local -A short15=()
    for name in "${!short[@]}"; do short15[${name:0:15}]=1; done
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 2
    for pid in "$_MOLE_PROC_ROOT"/[0-9]*; do
        mole_pid_mine "$pid" || continue
        exe=$(readlink -- "$pid/exe" 2> /dev/null) || exe=""
        exe="${exe% (deleted)}"
        [[ -n "$exe" && -n "${own[$exe]:-}" ]] && return 0
        while IFS= read -r -d '' word; do
            [[ "$word" == -*=/* ]] && word="${word#*=}"
            [[ "$word" == /* ]] || continue
            word="${word%/}"
            # "/" itself (bwrap --bind / /) leaves an empty key; under set -u
            # bash 5.2 and 5.3 treat it as a bad subscript and end the shell,
            # whatever || follows.
            [[ -n "$word" && -n "${own[$word]:-}" ]] && return 0
        done 2> /dev/null < "$pid/cmdline" || true
        if [[ -z "$exe" && ${#short15[@]} -gt 0 ]]; then
            comm=""
            IFS= read -r comm 2> /dev/null < "$pid/comm" || true
            [[ -n "$comm" && -n "${short15[$comm]:-}" ]] && rc=2
        fi
    done
    return "$rc"
}

# 0 when one of the user's processes belongs to the snap: snapd runs its apps
# in snap.<name>.<app>-<uuid>.scope (or .service) cgroups, and an executable
# under /snap/<name>/ counts too. 1 when none does; 2 when /proc cannot be
# read or a live process's cgroup cannot be read.
mole_snap_running() {
    local name="$1" pid line exe readable rc=1
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 2
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 2
    for pid in "$_MOLE_PROC_ROOT"/[0-9]*; do
        mole_pid_mine "$pid" || continue
        readable=false
        while IFS= read -r line; do
            readable=true
            [[ "$line" == *"/snap.$name."* ]] && return 0
        done 2> /dev/null < "$pid/cgroup" || true
        if exe=$(readlink -- "$pid/exe" 2> /dev/null); then
            [[ "$exe" == "/snap/$name/"* ]] && return 0
        fi
        [[ "$readable" == false && -d "$pid" ]] && rc=2
    done
    return "$rc"
}

# 0 when apt, dpkg or a frontend runs (as root, so any user), 1 when none
# does, 2 when it cannot tell. apt's lock files exist whether or not apt runs,
# so the processes are asked instead. unattended-upgrade is a python script
# whose process the kernel names "unattended-upgr", which is also the name of
# its -shutdown helper that Ubuntu keeps running for the whole session; only
# a process whose argv names .../unattended-upgrade itself counts. With /proc
# mounted hidepid, root's processes are hidden or unreadable, so idle cannot
# be told.
mole_apt_busy() {
    local name probe rc=1 pid word pids seen
    command -v pgrep > /dev/null 2>&1 || return 2
    # hidepid=1 leaves /proc/1 visible but unreadable.
    [[ -d "$_MOLE_PROC_ROOT/1" && -r "$_MOLE_PROC_ROOT/1/stat" ]] || return 2
    for name in apt apt-get aptitude dpkg synaptic; do
        probe=0
        pgrep -x -- "$name" > /dev/null 2>&1 || probe=$?
        [[ $probe -eq 0 ]] && return 0
        [[ $probe -eq 1 ]] || rc=2
    done
    probe=0
    pids=$(pgrep -x -- unattended-upgr 2> /dev/null) || probe=$?
    if [[ $probe -eq 0 ]]; then
        for pid in $pids; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            seen=false
            while IFS= read -r -d '' word; do
                seen=true
                [[ "$word" == */unattended-upgrade ]] && return 0
            done 2> /dev/null < "$_MOLE_PROC_ROOT/$pid/cmdline" || true
            # Gone meanwhile is fine; there but unreadable is not.
            [[ "$seen" == false && -d "$_MOLE_PROC_ROOT/$pid" ]] && rc=2
        done
    elif [[ $probe -ne 1 ]]; then
        rc=2
    fi
    return "$rc"
}

# Seconds flatpak ps may take before its answer counts as unknown.
MOLE_FLATPAK_PS_TIMEOUT=10

# The application ids flatpak ps lists, one per line; fails when flatpak is
# missing, fails or does not answer in time.
mole_flatpak_ps() {
    command -v flatpak > /dev/null 2>&1 || return 2
    mole_c timeout "$MOLE_FLATPAK_PS_TIMEOUT" flatpak ps --columns=application 2> /dev/null || return 2
}

# 0 when id is a line of a mole_flatpak_ps list.
mole_flatpak_listed() {
    [[ $'\n'"$2"$'\n' == *$'\n'"$1"$'\n'* ]]
}

# 0 when the Flatpak app runs, 1 when it does not, 2 when flatpak cannot say.
# Asks flatpak every time: it is the check right before removal.
mole_flatpak_running() {
    local id="$1" out
    out=$(mole_flatpak_ps) || return 2
    mole_flatpak_listed "$id" "$out" && return 0
    return 1
}

# 0 when one of the user's processes runs this exact executable file (an
# AppImage's runtime keeps running as its FUSE server), 1 when none does, 2
# when /proc cannot be read or a hidden process carries the file's name.
mole_exe_running() {
    local want="$1" exe pid comm short rc=1
    short="${want##*/}"
    short="${short:0:15}"
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 2
    for pid in "$_MOLE_PROC_ROOT"/[0-9]*; do
        mole_pid_mine "$pid" || continue
        if exe=$(readlink -- "$pid/exe" 2> /dev/null); then
            [[ "${exe% (deleted)}" == "$want" ]] && return 0
            continue
        fi
        # A non-dumpable process hides its executable; its comm carries the
        # first 15 bytes of the file name, so the answer is "cannot tell".
        comm=""
        IFS= read -r comm 2> /dev/null < "$pid/comm" || true
        [[ -n "$comm" && "$comm" == "$short" ]] && rc=2
    done
    return "$rc"
}

# Lowercase A-Z only, without a fork: under LC_ALL=C bash's ${v,,} leaves
# every byte above 127 alone, as tr did. Trailing newlines are dropped, as the
# command substitution around tr dropped them.
mole_ascii_lowercase() {
    local LC_ALL=C _value="${2:-}"
    _value="${_value,,}"
    while [[ "$_value" == *$'\n' ]]; do _value="${_value%$'\n'}"; done
    printf -v "$1" '%s' "$_value"
}

# Terminal columns a string takes, the width charmbracelet/x/ansi StringWidth
# gives in the Go TUIs, so shell and Go menus line up: the zero and wide
# ranges below are generated from StringWidth one code point at a time, then
# a ZWJ sequence, skin tone, flag pair or VS16 emoji counts as one 2-column
# cluster. Scripts whose clusters join several letters (Devanagari conjuncts)
# can still differ. UTF-8 is decoded by hand in the C locale, as on the
# main branch where Bash 3.2's printf "'c" yields only the first byte; no forks. Locked by
# "get_display_width matches the Go width table" in tests/uninstall.bats.
get_display_width() {
    local str="$1"
    local had_lc=${LC_ALL+x} old_lc="${LC_ALL:-}"

    export LC_ALL=$MOLE_UTF8_LOCALE
    local char_count=${#str}
    export LC_ALL=C
    local byte_count=${#str}

    local width=$char_count
    if ((byte_count != char_count)); then
        width=0
        local i=0 b c n k cp w prev_w=0 after_zwj=0 flag_open=0
        while ((i < byte_count)); do
            printf -v b '%d' "'${str:i:1}"
            if ((b < 0)); then b=$((b + 256)); fi
            i=$((i + 1))
            if ((b < 128)); then
                width=$((width + 1))
                prev_w=1 after_zwj=0 flag_open=0
                continue
            fi
            if ((b >= 240)); then
                n=3 cp=$((b & 7))
            elif ((b >= 224)); then
                n=2 cp=$((b & 15))
            elif ((b >= 192)); then
                n=1 cp=$((b & 31))
            else
                n=0 cp=-1
            fi
            for ((k = 0; k < n; k++)); do
                printf -v c '%d' "'${str:i:1}"
                if ((c < 0)); then c=$((c + 256)); fi
                if ((c < 128 || c >= 192)); then
                    cp=-1
                    break
                fi
                cp=$(((cp << 6) | (c & 63)))
                i=$((i + 1))
            done

            if ((cp == 0x200D)); then
                after_zwj=1
                continue
            fi
            if ((cp == 0xFE0F)); then
                # VS16 asks for emoji presentation: a narrow base becomes wide.
                if ((prev_w == 1)); then
                    width=$((width + 1))
                    prev_w=2
                fi
                continue
            fi
            if ((cp < 0)); then
                w=1
            elif ((cp < 0x300)); then
                w=1
                if ((cp == 0xAD)); then w=0; fi
            elif (((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xAC00 && cp <= 0xD7A3))); then
                w=2
            elif ((cp >= 0x1F3FB && cp <= 0x1F3FF)); then
                # A skin tone joins whatever comes before it; alone it is wide.
                w=2
                if ((prev_w > 0)); then w=0; fi
            elif ((cp >= 0x1F1E6 && cp <= 0x1F1FF)); then
                # Regional indicators pair into one flag.
                if ((flag_open)); then
                    w=0 flag_open=0
                else
                    w=2 flag_open=1
                fi
            elif ((cp < 0x2000)) && (((cp >= 0x300 && cp <= 0x36F) || (cp >= 0x483 && cp <= 0x489) || (\
            cp >= 0x591 && cp <= 0x5BD) || cp == 0x5BF || (cp >= 0x5C1 && cp <= 0x5C2) || (\
            cp >= 0x5C4 && cp <= 0x5C5) || cp == 0x5C7 || (cp >= 0x600 && cp <= 0x605) || (\
            cp >= 0x610 && cp <= 0x61A) || cp == 0x61C || (cp >= 0x64B && cp <= 0x65F) || cp == 0x670 || (\
            cp >= 0x6D6 && cp <= 0x6DD) || (cp >= 0x6DF && cp <= 0x6E4) || (\
            cp >= 0x6E7 && cp <= 0x6E8) || (cp >= 0x6EA && cp <= 0x6ED) || cp == 0x70F || cp == 0x711 || (\
            cp >= 0x730 && cp <= 0x74A) || (cp >= 0x7A6 && cp <= 0x7B0) || (\
            cp >= 0x7EB && cp <= 0x7F3) || cp == 0x7FD || (cp >= 0x816 && cp <= 0x819) || (\
            cp >= 0x81B && cp <= 0x823) || (cp >= 0x825 && cp <= 0x827) || (\
            cp >= 0x829 && cp <= 0x82D) || (cp >= 0x859 && cp <= 0x85B) || (\
            cp >= 0x890 && cp <= 0x891) || (cp >= 0x898 && cp <= 0x89F) || (\
            cp >= 0x8CA && cp <= 0x902) || cp == 0x93A || cp == 0x93C || (cp >= 0x941 && cp <= 0x948) || \
            cp == 0x94D || (cp >= 0x951 && cp <= 0x957) || (cp >= 0x962 && cp <= 0x963) || cp == 0x981 || \
            cp == 0x9BC || (cp >= 0x9C1 && cp <= 0x9C4) || cp == 0x9CD || (cp >= 0x9E2 && cp <= 0x9E3) || \
            cp == 0x9FE || (cp >= 0xA01 && cp <= 0xA02) || cp == 0xA3C || (cp >= 0xA41 && cp <= 0xA42) || (\
            cp >= 0xA47 && cp <= 0xA48) || (cp >= 0xA4B && cp <= 0xA4D) || cp == 0xA51 || (\
            cp >= 0xA70 && cp <= 0xA71) || cp == 0xA75 || (cp >= 0xA81 && cp <= 0xA82) || cp == 0xABC || (\
            cp >= 0xAC1 && cp <= 0xAC5) || (cp >= 0xAC7 && cp <= 0xAC8) || cp == 0xACD || (\
            cp >= 0xAE2 && cp <= 0xAE3) || (cp >= 0xAFA && cp <= 0xAFF) || cp == 0xB01 || cp == 0xB3C || \
            cp == 0xB3F || (cp >= 0xB41 && cp <= 0xB44) || cp == 0xB4D || (cp >= 0xB55 && cp <= 0xB56) || (\
            cp >= 0xB62 && cp <= 0xB63) || cp == 0xB82 || cp == 0xBC0 || cp == 0xBCD || cp == 0xC00 || \
            cp == 0xC04 || cp == 0xC3C || (cp >= 0xC3E && cp <= 0xC40) || (cp >= 0xC46 && cp <= 0xC48) || (\
            cp >= 0xC4A && cp <= 0xC4D) || (cp >= 0xC55 && cp <= 0xC56) || (\
            cp >= 0xC62 && cp <= 0xC63) || cp == 0xC81 || cp == 0xCBC || cp == 0xCBF || cp == 0xCC6 || (\
            cp >= 0xCCC && cp <= 0xCCD) || (cp >= 0xCE2 && cp <= 0xCE3) || (\
            cp >= 0xD00 && cp <= 0xD01) || (cp >= 0xD3B && cp <= 0xD3C) || (\
            cp >= 0xD41 && cp <= 0xD44) || cp == 0xD4D || (cp >= 0xD62 && cp <= 0xD63) || cp == 0xD81 || \
            cp == 0xDCA || (cp >= 0xDD2 && cp <= 0xDD4) || cp == 0xDD6 || cp == 0xE31 || (\
            cp >= 0xE34 && cp <= 0xE3A) || (cp >= 0xE47 && cp <= 0xE4E) || cp == 0xEB1 || (\
            cp >= 0xEB4 && cp <= 0xEBC) || (cp >= 0xEC8 && cp <= 0xECE) || (\
            cp >= 0xF18 && cp <= 0xF19) || cp == 0xF35 || cp == 0xF37 || cp == 0xF39 || (\
            cp >= 0xF71 && cp <= 0xF7E) || (cp >= 0xF80 && cp <= 0xF84) || (\
            cp >= 0xF86 && cp <= 0xF87) || (cp >= 0xF8D && cp <= 0xF97) || (\
            cp >= 0xF99 && cp <= 0xFBC) || cp == 0xFC6 || (cp >= 0x102D && cp <= 0x1030) || (\
            cp >= 0x1032 && cp <= 0x1037) || (cp >= 0x1039 && cp <= 0x103A) || (\
            cp >= 0x103D && cp <= 0x103E) || (cp >= 0x1058 && cp <= 0x1059) || (\
            cp >= 0x105E && cp <= 0x1060) || (cp >= 0x1071 && cp <= 0x1074) || cp == 0x1082 || (\
            cp >= 0x1085 && cp <= 0x1086) || cp == 0x108D || cp == 0x109D || (\
            cp >= 0x1160 && cp <= 0x11FF) || (cp >= 0x135D && cp <= 0x135F) || (\
            cp >= 0x1712 && cp <= 0x1714) || (cp >= 0x1732 && cp <= 0x1733) || (\
            cp >= 0x1752 && cp <= 0x1753) || (cp >= 0x1772 && cp <= 0x1773) || (\
            cp >= 0x17B4 && cp <= 0x17B5) || (cp >= 0x17B7 && cp <= 0x17BD) || cp == 0x17C6 || (\
            cp >= 0x17C9 && cp <= 0x17D3) || cp == 0x17DD || (cp >= 0x180B && cp <= 0x180F) || (\
            cp >= 0x1885 && cp <= 0x1886) || cp == 0x18A9 || (cp >= 0x1920 && cp <= 0x1922) || (\
            cp >= 0x1927 && cp <= 0x1928) || cp == 0x1932 || (cp >= 0x1939 && cp <= 0x193B) || (\
            cp >= 0x1A17 && cp <= 0x1A18) || cp == 0x1A1B || cp == 0x1A56 || (\
            cp >= 0x1A58 && cp <= 0x1A5E) || cp == 0x1A60 || cp == 0x1A62 || (\
            cp >= 0x1A65 && cp <= 0x1A6C) || (cp >= 0x1A73 && cp <= 0x1A7C) || cp == 0x1A7F || (\
            cp >= 0x1AB0 && cp <= 0x1ACE) || (cp >= 0x1B00 && cp <= 0x1B03) || cp == 0x1B34 || (\
            cp >= 0x1B36 && cp <= 0x1B3A) || cp == 0x1B3C || cp == 0x1B42 || (\
            cp >= 0x1B6B && cp <= 0x1B73) || (cp >= 0x1B80 && cp <= 0x1B81) || (\
            cp >= 0x1BA2 && cp <= 0x1BA5) || (cp >= 0x1BA8 && cp <= 0x1BA9) || (\
            cp >= 0x1BAB && cp <= 0x1BAD) || cp == 0x1BE6 || (cp >= 0x1BE8 && cp <= 0x1BE9) || \
            cp == 0x1BED || (cp >= 0x1BEF && cp <= 0x1BF1) || (cp >= 0x1C2C && cp <= 0x1C33) || (\
            cp >= 0x1C36 && cp <= 0x1C37) || (cp >= 0x1CD0 && cp <= 0x1CD2) || (\
            cp >= 0x1CD4 && cp <= 0x1CE0) || (cp >= 0x1CE2 && cp <= 0x1CE8) || cp == 0x1CED || \
            cp == 0x1CF4 || (cp >= 0x1CF8 && cp <= 0x1CF9) || (cp >= 0x1DC0 && cp <= 0x1DFF))); then
                w=0
            elif ((cp >= 0x2000)) && (((cp >= 0x200B && cp <= 0x200C) || (cp >= 0x200E && cp <= 0x200F) || (\
            cp >= 0x2028 && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x2064) || (\
            cp >= 0x2066 && cp <= 0x206F) || (cp >= 0x20D0 && cp <= 0x20F0) || (\
            cp >= 0x2CEF && cp <= 0x2CF1) || cp == 0x2D7F || (cp >= 0x2DE0 && cp <= 0x2DFF) || (\
            cp >= 0x302A && cp <= 0x302D) || (cp >= 0x3099 && cp <= 0x309A) || (\
            cp >= 0xA66F && cp <= 0xA672) || (cp >= 0xA674 && cp <= 0xA67D) || (\
            cp >= 0xA69E && cp <= 0xA69F) || (cp >= 0xA6F0 && cp <= 0xA6F1) || cp == 0xA802 || \
            cp == 0xA806 || cp == 0xA80B || (cp >= 0xA825 && cp <= 0xA826) || cp == 0xA82C || (\
            cp >= 0xA8C4 && cp <= 0xA8C5) || (cp >= 0xA8E0 && cp <= 0xA8F1) || cp == 0xA8FF || (\
            cp >= 0xA926 && cp <= 0xA92D) || (cp >= 0xA947 && cp <= 0xA951) || (\
            cp >= 0xA980 && cp <= 0xA982) || cp == 0xA9B3 || (cp >= 0xA9B6 && cp <= 0xA9B9) || (\
            cp >= 0xA9BC && cp <= 0xA9BD) || cp == 0xA9E5 || (cp >= 0xAA29 && cp <= 0xAA2E) || (\
            cp >= 0xAA31 && cp <= 0xAA32) || (cp >= 0xAA35 && cp <= 0xAA36) || cp == 0xAA43 || \
            cp == 0xAA4C || cp == 0xAA7C || cp == 0xAAB0 || (cp >= 0xAAB2 && cp <= 0xAAB4) || (\
            cp >= 0xAAB7 && cp <= 0xAAB8) || (cp >= 0xAABE && cp <= 0xAABF) || cp == 0xAAC1 || (\
            cp >= 0xAAEC && cp <= 0xAAED) || cp == 0xAAF6 || cp == 0xABE5 || cp == 0xABE8 || \
            cp == 0xABED || cp == 0xFB1E || (cp >= 0xFE00 && cp <= 0xFE0E) || (\
            cp >= 0xFE20 && cp <= 0xFE2F) || cp == 0xFEFF || (cp >= 0xFF9E && cp <= 0xFF9F) || (\
            cp >= 0xFFF9 && cp <= 0xFFFB) || cp == 0xE0001 || (cp >= 0xE0020 && cp <= 0xE007F) || (\
            cp >= 0xE0100 && cp <= 0xE01EF))); then
                w=0
            elif (((cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x231A && cp <= 0x231B) || (\
                cp >= 0x2329 && cp <= 0x232A) || (cp >= 0x23E9 && cp <= 0x23EC) || cp == 0x23F0 || \
                cp == 0x23F3 || (cp >= 0x25FD && cp <= 0x25FE) || (cp >= 0x2614 && cp <= 0x2615) || (\
                cp >= 0x2630 && cp <= 0x2637) || (cp >= 0x2648 && cp <= 0x2653) || cp == 0x267F || (\
                cp >= 0x268A && cp <= 0x268F) || cp == 0x2693 || cp == 0x26A1 || (\
                cp >= 0x26AA && cp <= 0x26AB) || (cp >= 0x26BD && cp <= 0x26BE) || (\
                cp >= 0x26C4 && cp <= 0x26C5) || cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA || (\
                cp >= 0x26F2 && cp <= 0x26F3) || cp == 0x26F5 || cp == 0x26FA || cp == 0x26FD || \
                cp == 0x2705 || (cp >= 0x270A && cp <= 0x270B) || cp == 0x2728 || cp == 0x274C || \
                cp == 0x274E || (cp >= 0x2753 && cp <= 0x2755) || cp == 0x2757 || (\
                cp >= 0x2795 && cp <= 0x2797) || cp == 0x27B0 || cp == 0x27BF || (\
                cp >= 0x2B1B && cp <= 0x2B1C) || cp == 0x2B50 || cp == 0x2B55 || (\
                cp >= 0x2E80 && cp <= 0x2E99) || (cp >= 0x2E9B && cp <= 0x2EF3) || (\
                cp >= 0x2F00 && cp <= 0x2FD5) || (cp >= 0x2FF0 && cp <= 0x3029) || (\
                cp >= 0x302E && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x3096) || (\
                cp >= 0x309B && cp <= 0x30FF) || (cp >= 0x3105 && cp <= 0x312F) || (\
                cp >= 0x3131 && cp <= 0x318E) || (cp >= 0x3190 && cp <= 0x31E5) || (\
                cp >= 0x31EF && cp <= 0x321E) || (cp >= 0x3220 && cp <= 0x3247) || (\
                cp >= 0x3250 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0xA4CF) || (\
                cp >= 0xA960 && cp <= 0xA97C) || (cp >= 0xAC00 && cp <= 0xD7A3) || (\
                cp >= 0xFE10 && cp <= 0xFE19) || (cp >= 0xFE30 && cp <= 0xFE52) || (\
                cp >= 0xFE54 && cp <= 0xFE66) || (cp >= 0xFE68 && cp <= 0xFE6B) || (\
                cp >= 0xFF01 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) || (\
                cp >= 0x16FE0 && cp <= 0x16FE4) || (cp >= 0x17000 && cp <= 0x18AFF) || (\
                cp >= 0x1B000 && cp <= 0x1B2FF) || cp == 0x1F004 || cp == 0x1F0CF || cp == 0x1F18E || (\
                cp >= 0x1F191 && cp <= 0x1F19A) || (cp >= 0x1F200 && cp <= 0x1F202) || (\
                cp >= 0x1F210 && cp <= 0x1F23B) || (cp >= 0x1F240 && cp <= 0x1F248) || (\
                cp >= 0x1F250 && cp <= 0x1F251) || (cp >= 0x1F260 && cp <= 0x1F265) || (\
                cp >= 0x1F300 && cp <= 0x1F320) || (cp >= 0x1F32D && cp <= 0x1F335) || (\
                cp >= 0x1F337 && cp <= 0x1F37C) || (cp >= 0x1F37E && cp <= 0x1F393) || (\
                cp >= 0x1F3A0 && cp <= 0x1F3CA) || (cp >= 0x1F3CF && cp <= 0x1F3D3) || (\
                cp >= 0x1F3E0 && cp <= 0x1F3F0) || cp == 0x1F3F4 || (cp >= 0x1F3F8 && cp <= 0x1F3FA) || (\
                cp >= 0x1F400 && cp <= 0x1F43E) || cp == 0x1F440 || (cp >= 0x1F442 && cp <= 0x1F4FC) || (\
                cp >= 0x1F4FF && cp <= 0x1F53D) || (cp >= 0x1F54B && cp <= 0x1F54E) || (\
                cp >= 0x1F550 && cp <= 0x1F567) || cp == 0x1F57A || (cp >= 0x1F595 && cp <= 0x1F596) || \
                cp == 0x1F5A4 || (cp >= 0x1F5FB && cp <= 0x1F64F) || (cp >= 0x1F680 && cp <= 0x1F6C5) || \
                cp == 0x1F6CC || (cp >= 0x1F6D0 && cp <= 0x1F6D2) || (cp >= 0x1F6D5 && cp <= 0x1F6D7) || (\
                cp >= 0x1F6DC && cp <= 0x1F6DF) || (cp >= 0x1F6EB && cp <= 0x1F6EC) || (\
                cp >= 0x1F6F4 && cp <= 0x1F6FC) || (cp >= 0x1F7E0 && cp <= 0x1F7EB) || cp == 0x1F7F0 || (\
                cp >= 0x1F90C && cp <= 0x1F93A) || (cp >= 0x1F93C && cp <= 0x1F945) || (\
                cp >= 0x1F947 && cp <= 0x1F9FF) || (cp >= 0x1FA70 && cp <= 0x1FA7C) || (\
                cp >= 0x1FA80 && cp <= 0x1FA89) || (cp >= 0x1FA8F && cp <= 0x1FAC6) || (\
                cp >= 0x1FACE && cp <= 0x1FADC) || (cp >= 0x1FADF && cp <= 0x1FAE9) || (\
                cp >= 0x1FAF0 && cp <= 0x1FAF8) || (cp >= 0x20000 && cp <= 0x3FFFD))); then
                w=2
            else
                w=1
            fi
            if ((cp < 0x1F1E6 || cp > 0x1F1FF)); then flag_open=0; fi
            # An emoji after a ZWJ joins the cluster before it.
            if ((after_zwj && prev_w == 2 && w > 0 && (cp >= 0x1F000 || (cp >= 0x2190 && cp <= 0x2BFF)))); then
                w=0
            fi
            after_zwj=0
            width=$((width + w))
            if ((w > 0)); then prev_w=$w; fi
        done
    fi

    if [[ -n "$had_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi
    echo "$width"
}

# Truncate string by display width (handles CJK)

truncate_by_display_width() {
    local str="$1"
    local max_width="$2"
    local current_width
    current_width=$(get_display_width "$str")

    if [[ $current_width -le $max_width ]]; then
        # printf, not echo: a string such as "-n" or "-e" is an echo option.
        printf '%s\n' "$str"
        return
    fi

    # Fallback: Use pure bash character iteration
    # Since we need to know the width of *each* character to truncate at the right spot,
    # we cannot just use the total width formula on the whole string.
    # However, iterating char-by-char and calling the optimized get_display_width function
    # is now much faster because it doesn't fork 'wc'.

    # CRITICAL: Switch to UTF-8 for correct character iteration
    local old_lc="${LC_ALL:-}"
    export LC_ALL=$MOLE_UTF8_LOCALE

    local truncated=""
    local width=0
    local i=0
    local char char_width
    local strlen=${#str} # Re-calculate in UTF-8

    # Optimization: If total width <= max_width, return original string (checked above)

    while [[ $i -lt $strlen ]]; do
        char="${str:$i:1}"

        # Inlined width calculation for minimal overhead to avoid recursion overhead
        # We are already in UTF-8, so ${#char} is char length (1).
        # We need byte length for the heuristic.
        # But switching locale inside loop is disastrous for perf.
        # Logic: If char is ASCII (1 byte), width 1.
        # If char is wide (3 bytes), width 2.
        # How to detect byte size without switching locale?
        # printf %s "$char" | wc -c ? Slow.
        # Check against ASCII range?
        # Bash's own pattern matcher knows [:ascii:]; a regex hands it to
        # glibc regcomp, which rejects it once per character (#1918).
        if [[ "$char" == [[:ascii:]] ]]; then
            char_width=1
        else
            # Assume wide for non-ascii in this context (simplified)
            # Or use LC_ALL=C inside? No.
            # Most non-ASCII in filenames are either CJK (width 2) or heavy symbols.
            # Let's assume 2 for simplicity in this fast loop as we know we are usually dealing with CJK.
            char_width=2
        fi

        if ((width + char_width + 3 > max_width)); then
            break
        fi

        truncated+="$char"
        width=$((width + char_width))
        i=$((i + 1))
    done

    # Restore locale
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    printf '%s...\n' "$truncated"
}

