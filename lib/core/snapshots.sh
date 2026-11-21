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

# 0 when a mount point sits at $1 or anywhere below it, 1 when none does, 2
# when that cannot be told (the table or the path's parent cannot be read).
# rm --one-file-system and a device comparison both read st_dev, and a bind
# mount of a folder on the same filesystem has the same st_dev as the folder
# it sits in, so rm walks into it and deletes the bound folder's real
# contents. Only the mount table names those. A symlink at $1 is no mount: rm
# removes the link, never what it points at.
# The table is read on every call, unless the caller took a snapshot of the
# folder $1 sits in with mole_mount_snapshot (clean's sizing pass, one per
# rule). The removal sinks drop any snapshot, so a mount made after the
# review is still seen right before rm. Under a snapshot the path's physical
# spelling is the folder's plus the rest of $1, which holds only because the
# caller (mole_cache_child_ok) has already refused a symlink below the home.
mole_mount_within() {
    local path="$1" parent phys esc mp
    [[ "$path" == /* && "$path" != / && "$path" != */ ]] || return 2
    [[ -L "$path" ]] && return 1
    if [[ -n "${_MOLE_MOUNT_SNAP_ROOT:-}" && "$path" == "$_MOLE_MOUNT_SNAP_ROOT/"* ]]; then
        # Usually nothing is mounted below a cache folder: no fork, no match.
        [[ -n "$_MOLE_MOUNT_SNAP_LIST" ]] || return 1
        _mole_escape_mount esc "$_MOLE_MOUNT_SNAP_PHYS/${path#"$_MOLE_MOUNT_SNAP_ROOT/"}"
        while IFS= read -r mp; do
            [[ "$mp" == "$esc" || "$mp" == "$esc"/* ]] && return 0
        done <<< "$_MOLE_MOUNT_SNAP_LIST"
        return 1
    fi
    parent="${path%/*}"
    [[ -n "$parent" ]] || parent=/
    parent=$(readlink -e -- "$parent" 2> /dev/null) || return 2
    phys="${parent%/}/${path##*/}"
    _mole_escape_mount esc "$phys"
    _mole_mounts_at_or_below "$esc" > /dev/null
}

# Prints the mount points, as the table spells them, at or below the escaped
# physical path $1. Exit 0 when there is one, 1 when there is none, 2 when
# the table cannot be read. Compared as strings, so a path holding regex or
# glob characters means only itself.
_mole_mounts_at_or_below() {
    [[ -r "$_MOLE_MOUNTINFO" ]] || return 2
    # ENVIRON, not -v: awk -v would turn the table's \040 back into a space.
    MOLE_MOUNT_PREFIX="$1" LC_ALL=C awk '
        BEGIN { p = ENVIRON["MOLE_MOUNT_PREFIX"] }
        $5 == p || index($5, p "/") == 1 { print $5; found = 1 }
        END { exit found ? 0 : 1 }' "$_MOLE_MOUNTINFO" 2> /dev/null
}

# Takes the snapshot mole_mount_within reads for paths below the folder $1:
# its physical path and the mount points at or below it. The caller declares
# _MOLE_MOUNT_SNAP_ROOT, _MOLE_MOUNT_SNAP_PHYS and _MOLE_MOUNT_SNAP_LIST local.
# On failure no snapshot is set, so every check reads the table itself and
# refuses when it cannot.
mole_mount_snapshot() {
    local root="$1" phys esc list rc=0
    _MOLE_MOUNT_SNAP_ROOT="" _MOLE_MOUNT_SNAP_PHYS="" _MOLE_MOUNT_SNAP_LIST=""
    [[ "$root" == /* && "$root" != / && "$root" != */ ]] || return 1
    phys=$(readlink -e -- "$root" 2> /dev/null) || return 1
    _mole_escape_mount esc "$phys"
    list=$(_mole_mounts_at_or_below "$esc") || rc=$?
    ((rc <= 1)) || return 1
    _MOLE_MOUNT_SNAP_ROOT="$root" _MOLE_MOUNT_SNAP_PHYS="$phys" _MOLE_MOUNT_SNAP_LIST="$list"
}

# Sets the variable named $1 to $2 escaped the way the kernel writes
# mountinfo, backslash first. No subshell: clean calls it per cache child.
_mole_escape_mount() {
    local LC_ALL=C s="$2"
    s=${s//\\/\\134}
    s=${s// /\\040}
    s=${s//$'\t'/\\011}
    s=${s//$'\n'/\\012}
    printf -v "$1" '%s' "$s"
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
