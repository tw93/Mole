#!/usr/bin/env bats
# Is a path held by btrfs snapshots? Fixtures only: a fake mountinfo and a fake
# snapper config tree, since the test machines are ext4/tmpfs without snapper.

load helpers

# mountinfo line: mountinfo_line <escaped mount point> <fstype>
mountinfo_line() {
    printf '36 1 0:%s / %s rw,relatime shared:1 - %s /dev/vda2 rw,subvol=/@\n' "$RANDOM" "$1" "$2"
}

# A btrfs root at $TEST_ROOT/sys with snapper's root config on it.
snapper_fixture() {
    mkdir -p "$TEST_ROOT/sys/var/cache/pacman/pkg" "$TEST_ROOT/sys/home" "$TEST_ROOT/snapper/configs"
    {
        mountinfo_line / ext4
        mountinfo_line "$TEST_ROOT/sys" btrfs
    } > "$TEST_ROOT/mountinfo"
    printf 'SUBVOLUME="%s"\nNUMBER_LIMIT="5"\nTIMELINE_CREATE="no"\n' "$TEST_ROOT/sys" > "$TEST_ROOT/snapper/configs/root"
}

detect() {
    mole_run core '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/mountinfo"
        _MOLE_SNAPPER_CONFIGS="'"$TEST_ROOT"'/snapper/configs"
        _MOLE_SNAPPER_SYSCONFIGS=("'"$TEST_ROOT"'/conf.d/snapper")
        s=0; mole_snapshot_state "'"$1"'" || s=$?; echo "state=$s"'
}

@test "snapshots: a path on the btrfs subvolume snapper snapshots is held" {
    snapper_fixture
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$status" -eq 0 ]
    [ "$output" = "state=0" ]
}

@test "snapshots: only the configs SNAPPER_CONFIGS lists count, when that file is readable" {
    snapper_fixture
    mkdir -p "$TEST_ROOT/conf.d"
    printf 'SNAPPER_CONFIGS="home"\n' > "$TEST_ROOT/conf.d/snapper"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=1" ]
    printf '# SNAPPER_CONFIGS="home"\nSNAPPER_CONFIGS="home root"\n' > "$TEST_ROOT/conf.d/snapper"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=0" ]
}

@test "snapshots: a separate subvolume mount is not in the root snapshots" {
    snapper_fixture
    mountinfo_line "$TEST_ROOT/sys/home" btrfs >> "$TEST_ROOT/mountinfo"
    mkdir -p "$TEST_ROOT/sys/home/me/.cache"
    detect "$TEST_ROOT/sys/home/me/.cache"
    [ "$output" = "state=1" ]
    printf 'SUBVOLUME="%s"\n' "$TEST_ROOT/sys/home" > "$TEST_ROOT/snapper/configs/home"
    detect "$TEST_ROOT/sys/home/me/.cache"
    [ "$output" = "state=0" ]
}

@test "snapshots: btrfs without snapper holds nothing" {
    snapper_fixture
    rm -rf "$TEST_ROOT/snapper"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=1" ]
}

@test "snapshots: ext4 holds nothing even beside a snapper config naming it" {
    snapper_fixture
    mountinfo_line / ext4 > "$TEST_ROOT/mountinfo"
    mountinfo_line "$TEST_ROOT/sys" ext4 >> "$TEST_ROOT/mountinfo"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=1" ]
}

@test "snapshots: a later mount stacked on the same point wins" {
    snapper_fixture
    {
        mountinfo_line / ext4
        mountinfo_line "$TEST_ROOT/sys" ext4
        mountinfo_line "$TEST_ROOT/sys" btrfs
    } > "$TEST_ROOT/mountinfo"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=0" ]
    mountinfo_line "$TEST_ROOT/sys" ext4 >> "$TEST_ROOT/mountinfo"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=1" ]
}

@test "snapshots: an unreadable config, configs folder or mount table is unknown, never held" {
    [ "$(id -u)" -ne 0 ] || skip "root reads mode 000 files"
    snapper_fixture
    printf 'SUBVOLUME="/elsewhere"\n' > "$TEST_ROOT/snapper/configs/other"
    chmod 000 "$TEST_ROOT/snapper/configs/root"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=2" ]
    chmod 644 "$TEST_ROOT/snapper/configs/root"
    chmod 000 "$TEST_ROOT/snapper/configs"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=2" ]
    chmod 755 "$TEST_ROOT/snapper/configs"
    chmod 000 "$TEST_ROOT/mountinfo"
    detect "$TEST_ROOT/sys/var/cache/pacman/pkg"
    [ "$output" = "state=2" ]
    chmod 644 "$TEST_ROOT/mountinfo"
    detect "$TEST_ROOT/sys/does/not/exist"
    [ "$output" = "state=2" ]
}

@test "snapshots: mountinfo mount points with spaces and backslashes are unescaped" {
    mkdir -p "$TEST_ROOT/my disk/a\\b/pkg" "$TEST_ROOT/my/pkg" "$TEST_ROOT/snapper/configs"
    {
        mountinfo_line / ext4
        mountinfo_line "$TEST_ROOT/my" ext4
        mountinfo_line "$TEST_ROOT/my\\040disk" btrfs
    } > "$TEST_ROOT/mountinfo"
    mole_run core '_MOLE_MOUNTINFO="'"$TEST_ROOT"'/mountinfo"; mole_mount_of "'"$TEST_ROOT"'/my disk/a\\b/pkg"; mole_mount_of "'"$TEST_ROOT"'/my/pkg"'
    [ "${lines[0]}" = "$TEST_ROOT/my disk"$'\t'"btrfs" ]
    [ "${lines[1]}" = "$TEST_ROOT/my"$'\t'"ext4" ]
    printf "SUBVOLUME='%s'\n" "$TEST_ROOT/my disk" > "$TEST_ROOT/snapper/configs/root"
    detect "$TEST_ROOT/my disk/a\\b/pkg"
    [ "$output" = "state=0" ]
    detect "$TEST_ROOT/my/pkg"
    [ "$output" = "state=1" ]
}
