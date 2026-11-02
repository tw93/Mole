#!/bin/bash
# Mole CLI (Linux) - is a path held by btrfs snapshots?
#
# On a btrfs subvolume that snapper snapshots (Omarchy snapshots / before every
# update), a file deleted there keeps its blocks until every snapshot holding
# it rotates out, so clean and uninstall must not report that space as freed.
# Everything here runs without root: the mount comes from mountinfo, the
# snapshot policy from snapper's readable configs. Exclusive bytes per
# snapshot need root (qgroups) and are never measured. Timeshift's btrfs mode
# is not detected: its snapshots live under a root-only mount of the top-level
# subvolume, and its config alone does not say whether any snapshot exists.

# Overridden by the tests.
_MOLE_MOUNTINFO=/proc/self/mountinfo
_MOLE_SNAPPER_CONFIGS=/etc/snapper/configs
_MOLE_SNAPPER_SYSCONFIGS=(/etc/conf.d/snapper /etc/default/snapper)

# KEY="value", KEY='value' or KEY=value at the start of a shell-style line.
_MOLE_SNAPPER_CONFIGS_RE='^[[:space:]]*SNAPPER_CONFIGS=["'"'"']?([^"'"'"']*)'
_MOLE_SNAPPER_SUBVOLUME_RE='^[[:space:]]*SUBVOLUME=["'"'"']?([^"'"'"']*)'

# mountinfo escapes space, tab, newline and backslash as octal.
_mole_unescape_mount() {
    local s="$1"
    s=${s//\\040/ }
    s=${s//\\011/$'\t'}
    s=${s//\\012/$'\n'}
    s=${s//\\134/\\}
    printf '%s' "$s"
}

# Prints "<mount point><TAB><fstype>" of the mount holding $1, an absolute
# resolved path: the longest matching mount point, the later one when two are
# stacked. Returns 1 when the table cannot be read or has no match.
mole_mount_of() {
    local path="$1" line mp fstype best="" best_type="" found=false i
    local -a f
    [[ -r "$_MOLE_MOUNTINFO" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        read -ra f <<< "$line"
        # id parent major:minor root mountpoint options [optional...] - fstype source superopts
        for ((i = 6; i < ${#f[@]}; i++)); do
            [[ "${f[i]}" == - ]] && break
        done
        ((i + 1 < ${#f[@]})) || continue
        mp=$(_mole_unescape_mount "${f[4]}")
        fstype="${f[i + 1]}"
        [[ "$mp" == /* ]] || continue
        if [[ "$mp" == / || "$path" == "$mp" || "$path" == "$mp"/* ]]; then
            if [[ "$found" == false || ${#mp} -ge ${#best} ]]; then
                best="$mp" best_type="$fstype" found=true
            fi
        fi
    done < "$_MOLE_MOUNTINFO"
    [[ "$found" == true ]] || return 1
    printf '%s\t%s\n' "$best" "$best_type"
}

# A btrfs subvolume root has inode 256; asked of the real filesystem, so a
# directory on ext4 or tmpfs never counts.
_mole_btrfs_subvol_root() {
    [[ "$(mole_c stat -f -c %T -- "$1" 2> /dev/null)" == btrfs ]] &&
        [[ "$(mole_c stat -c %i -- "$1" 2> /dev/null)" == 256 ]]
}

# 0 when a snapper config snapshots the subvolume mounted or rooted at $1,
# 1 when none does (or snapper is not set up), 2 when a config cannot be read.
mole_snapper_covers() {
    local subvol="$1" dir="$_MOLE_SNAPPER_CONFIGS" sys line names="" listed=false
    local cfg value unknown=false
    local -a cfgs=() list=()
    if [[ ! -e "$dir" ]]; then
        # A parent that cannot be searched hides the folder; that is not "absent".
        [[ -d "${dir%/*}" && ! -x "${dir%/*}" ]] && return 2
        return 1
    fi
    [[ -d "$dir" && -r "$dir" && -x "$dir" ]] || return 2
    for sys in "${_MOLE_SNAPPER_SYSCONFIGS[@]}"; do
        [[ -f "$sys" && -r "$sys" ]] || continue
        listed=true
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ $_MOLE_SNAPPER_CONFIGS_RE ]]; then
                names="${BASH_REMATCH[1]}"
            fi
        done < "$sys"
        break
    done
    if [[ "$listed" == true ]]; then
        read -ra list <<< "$names"
        for cfg in "${list[@]}"; do
            [[ "$cfg" == */* || -z "$cfg" ]] && continue
            [[ -e "$dir/$cfg" ]] && cfgs+=("$dir/$cfg")
        done
    else
        for cfg in "$dir"/*; do
            [[ -f "$cfg" ]] && cfgs+=("$cfg")
        done
    fi
    for cfg in "${cfgs[@]}"; do
        if [[ ! -f "$cfg" || ! -r "$cfg" ]]; then
            unknown=true
            continue
        fi
        value=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ $_MOLE_SNAPPER_SUBVOLUME_RE ]]; then
                value="${BASH_REMATCH[1]}"
            fi
        done < "$cfg"
        [[ "$value" == /* ]] || continue
        value=$(readlink -e -- "$value" 2> /dev/null) || continue
        [[ "$value" == "$subvol" ]] && return 0
    done
    [[ "$unknown" == true ]] && return 2
    return 1
}

# 0 when $1 sits on a btrfs subvolume that snapper snapshots, so space freed
# there returns only as those snapshots rotate; 1 when it does not; 2 when a
# probe cannot tell. Callers treat 2 like 1 for wording (no claim either way)
# and never as "snapshotted".
mole_snapshot_state() {
    local real mount fstype subvol dir
    real=$(readlink -e -- "$1" 2> /dev/null) || return 2
    mount=$(mole_mount_of "$real") || return 2
    fstype="${mount#*$'\t'}"
    mount="${mount%%$'\t'*}"
    [[ "$fstype" == btrfs ]] || return 1
    # The nearest subvolume root at or above the path, else the mount itself:
    # a nested subvolume is not part of its parent's snapshots.
    subvol="$mount"
    dir="$real"
    while [[ "$dir" != "$mount" && "$dir" != / ]]; do
        if _mole_btrfs_subvol_root "$dir"; then
            subvol="$dir"
            break
        fi
        dir=$(dirname -- "$dir")
    done
    mole_snapper_covers "$subvol"
}
