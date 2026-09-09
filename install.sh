#!/bin/bash
# Mole - Installer for manual installs.
# Fetches source/binaries and installs to prefix.
# Supports update and edge installs.

set -euo pipefail

# Honor https://no-color.org: any non-empty NO_COLOR disables ANSI escapes.
if [[ -n "${NO_COLOR:-}" ]]; then
    GREEN=''
    BLUE=''
    YELLOW=''
    RED=''
    NC=''
else
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
fi

_SPINNER_PID=""
start_line_spinner() {
    local msg="$1"
    # A progress line only means something while it is being watched. When the
    # output is captured, as `mo update` does, every one of these lands in the
    # final block as a stale "Downloading..." / "Verifying..." line that the
    # very next line contradicts. Say nothing there and let the result lines
    # speak; a tty still gets the animation.
    [[ -t 1 ]] || return 0
    local chars="|/-\\"
    # shellcheck disable=SC1003
    [[ -z "$chars" ]] && chars='|/-\\'
    local i=0
    (while true; do
        c="${chars:$((i % ${#chars})):1}"
        printf "\r${BLUE}%s${NC} %s" "$c" "$msg"
        ((i++))
        sleep 0.12
    done) &
    _SPINNER_PID=$!
}
stop_line_spinner() { if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2> /dev/null || true
    wait "$_SPINNER_PID" 2> /dev/null || true
    _SPINNER_PID=""
    printf "\r\033[K"
fi; }

VERBOSE=1

# Icons duplicated from lib/core/common.sh (install.sh runs standalone).
# Avoid readonly to prevent conflicts when sourcing common.sh later.
ICON_SUCCESS="✓"
ICON_ADMIN="●"
ICON_CONFIRM="◎"
ICON_ERROR="☻"

log_info() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}$1${NC}"; }
log_success() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} $1"; }
log_warning() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${YELLOW}${ICON_ERROR}${NC} $1"; }
log_admin() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}${ICON_ADMIN}${NC} $1"; }
log_confirm() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}${ICON_CONFIRM}${NC} $1"; }

curl_download_with_retry() {
    local url="$1"
    local output_file="$2"
    local attempt=1
    local max_attempts=3
    local curl_exit=0
    # Capture curl's stderr per attempt and surface it only when the download
    # ultimately fails: a transient TLS reset that the retry recovers from is
    # not news, and printing it made successful installs look broken.
    local curl_err=""
    curl_err="$(mktemp "${TMPDIR:-/tmp}/mole-curl-err.XXXXXX")" || curl_err=""

    while true; do
        if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output_file" \
            2> "${curl_err:-/dev/null}"; then
            [[ -n "$curl_err" ]] && rm -f "$curl_err" # SAFE: exact mktemp stderr file created above
            return 0
        else
            curl_exit=$?
        fi

        rm -f "$output_file" 2> /dev/null || true
        case "$curl_exit" in
            6 | 7 | 18 | 28 | 35 | 52 | 55 | 56) ;;
            *)
                [[ -s "$curl_err" ]] && cat "$curl_err" >&2
                [[ -n "$curl_err" ]] && rm -f "$curl_err" # SAFE: exact mktemp stderr file created above
                return "$curl_exit"
                ;;
        esac

        if [[ "$attempt" -ge "$max_attempts" ]]; then
            [[ -s "$curl_err" ]] && cat "$curl_err" >&2
            [[ -n "$curl_err" ]] && rm -f "$curl_err" # SAFE: exact mktemp stderr file created above
            return "$curl_exit"
        fi
        sleep 1 || {
            [[ -n "$curl_err" ]] && rm -f "$curl_err" # SAFE: exact mktemp stderr file created above
            return "$curl_exit"
        }
        attempt=$((attempt + 1))
    done
}

safe_rm() {
    local target="${1:-}"
    local tmp_root

    if [[ -z "$target" ]]; then
        log_error "safe_rm: empty path"
        return 1
    fi
    if [[ ! -e "$target" ]]; then
        return 0
    fi

    tmp_root="${TMPDIR:-/tmp}"
    while [[ "$tmp_root" != "/" && "$tmp_root" == */ ]]; do
        tmp_root="${tmp_root%/}"
    done
    case "$target" in
        "$tmp_root" | /tmp)
            log_error "safe_rm: refusing to remove temp root: $target"
            return 1
            ;;
        "$tmp_root"/* | /tmp/*) ;;
        *)
            log_error "safe_rm: refusing to remove non-temp path: $target"
            return 1
            ;;
    esac

    if [[ -d "$target" ]]; then
        find "$target" -depth \( -type f -o -type l \) -exec rm -f {} + 2> /dev/null || true
        find "$target" -depth -type d -exec rmdir {} + 2> /dev/null || true
    else
        rm -f "$target" 2> /dev/null || true
    fi
}

# Install defaults
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/mole"
SOURCE_DIR=""
SOURCE_COMMIT_HASH=""
INSTALL_LOCK_PATH=""
INSTALL_LOCK_CONTROL=""
INSTALL_LOCK_HOLDER_PID=""
INSTALL_LOCK_USE_SUDO=false
# Why the last acquire_install_lock attempt failed. A bare "the lock is busy"
# message sent one reporter reverse-engineering the ancestor check by hand
# (#1335), so callers report the actual cause instead.
INSTALL_LOCK_FAILURE=""
INSTALL_LOCK_UNSAFE_ANCESTOR=""
# Which of the ancestor check's five independent rejections fired. They need
# different commands: chown does not clear an ACL and chmod does not turn a
# symlink into a directory, so one shared "it is writable" sentence sends the
# user to run something that changes nothing and retry into the same refusal.
INSTALL_LOCK_UNSAFE_ANCESTOR_REASON=""
INSTALL_SOURCE_TMP=""

ACTION="install"

# Resolve source dir (local checkout, env override, or download).
needs_sudo() {
    if [[ -e "$INSTALL_DIR" ]]; then
        [[ ! -w "$INSTALL_DIR" ]]
        return
    fi

    local parent_dir
    parent_dir="$(dirname "$INSTALL_DIR")"
    [[ ! -w "$parent_dir" ]]
}

ensure_sudo_ready() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        log_error "Admin access required, blocked in test mode"
        return 1
    fi

    if [[ "${MOLE_ASSUME_SUDO_AUTH:-0}" == "1" ]]; then
        sudo -n -v
        return
    fi

    sudo -v
}

maybe_sudo() {
    if needs_sudo; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            log_error "Admin access required, blocked in test mode"
            return 1
        fi
        if [[ "${MOLE_ASSUME_SUDO_AUTH:-0}" == "1" ]]; then
            sudo -n "$@"
        else
            sudo "$@"
        fi
    else
        "$@"
    fi
}

# Keep verification of a newly installed executable bounded. The installer
# cannot source lib/core/timeout.sh until after it has installed the source
# tree, so use a small standalone wrapper for --version/--help probes.
run_install_probe_with_timeout() {
    local duration="${1:-5}"
    shift || true
    [[ $# -gt 0 ]] || return 125
    [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || duration=5

    local candidate timeout_bin=""
    for candidate in gtimeout timeout; do
        if command -v "$candidate" > /dev/null 2>&1; then
            timeout_bin=$(command -v "$candidate")
            break
        fi
    done
    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" -k 1 "$duration" "$@"
        return $?
    fi

    # Stock macOS has no timeout utility, but it does ship Perl. Supervise the
    # probe from outside its process group so a shell wrapper and every child
    # holding inherited output descriptors are terminated at the deadline.
    local perl_bin=""
    perl_bin=$(command -v perl 2> /dev/null || true)
    [[ -n "$perl_bin" ]] || return 125
    # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
    "$perl_bin" -MPOSIX=:sys_wait_h,setpgid -MTime::HiRes=time,sleep -e '
        my ($duration, @command) = @ARGV;
        exit 125 unless @command;
        my $pid = fork();
        exit 125 unless defined $pid;
        if ($pid == 0) {
            my $setpgid_status = POSIX::setpgid(0, 0);
            exit 126 unless defined $setpgid_status && $setpgid_status == 0;
            exec { $command[0] } @command;
            exit 127;
        }
        POSIX::setpgid($pid, $pid);
        my $deadline = time() + $duration;
        while (time() < $deadline) {
            my $result = waitpid($pid, WNOHANG);
            if ($result == $pid) {
                exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
            }
            sleep(0.02);
        }
        kill "TERM", -$pid;
        my $grace = time() + 1;
        while (time() < $grace) {
            my $result = waitpid($pid, WNOHANG);
            exit 124 if $result == $pid;
            sleep(0.02);
        }
        kill "KILL", -$pid;
        waitpid($pid, 0);
        exit 124;
    ' "$duration" "$@"
}

install_lock_has_unsafe_ancestor() {
    local use_sudo="$1"
    local probe="$INSTALL_DIR"
    local current_uid owner_uid mode acl_listing
    current_uid=$(id -u 2> /dev/null || true)
    INSTALL_LOCK_UNSAFE_ANCESTOR="$probe"
    INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="unreadable"
    [[ "$current_uid" =~ ^[0-9]+$ ]] || return 0

    while true; do
        # Record the directory under inspection so a rejection can name it.
        INSTALL_LOCK_UNSAFE_ANCESTOR="$probe"
        INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="symlink"
        [[ ! -L "$probe" ]] || return 0
        owner_uid=$(/usr/bin/stat -f%u "$probe" 2> /dev/null || true)
        mode=$(/usr/bin/stat -f%Lp "$probe" 2> /dev/null || true)
        INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="unreadable"
        [[ "$owner_uid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || return 0
        if [[ "$use_sudo" == "true" || ${EUID:-0} -eq 0 ]]; then
            INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="not_root_owned"
            [[ "$owner_uid" -eq 0 ]] || return 0
            INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="writable"
            (((8#$mode & 0022) == 0)) || return 0
        elif [[ "$owner_uid" -ne 0 && "$owner_uid" -ne "$current_uid" ]]; then
            INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="foreign_owner"
            return 0
        else
            # A regular installer already writes through this tree. Accept
            # group-writable prefixes, but keep world-writable paths closed.
            INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="writable"
            (((8#$mode & 0002) == 0)) || return 0
        fi
        INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="unreadable"
        acl_listing=$(/bin/ls -lde "$probe" 2> /dev/null) || return 0
        INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="acl"
        if printf '%s\n' "$acl_listing" |
            /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:.*[[:space:]]allow[[:space:]]'; then
            return 0
        fi
        [[ "$probe" == "/" ]] && break
        local parent_probe="${probe%/*}"
        INSTALL_LOCK_UNSAFE_ANCESTOR_REASON="unreadable"
        [[ "$parent_probe" != "$probe" ]] || return 0
        probe="$parent_probe"
        [[ -n "$probe" ]] || probe="/"
    done
    INSTALL_LOCK_UNSAFE_ANCESTOR=""
    INSTALL_LOCK_UNSAFE_ANCESTOR_REASON=""
    return 1
}

install_lock_process_start() {
    local pid="$1"
    LC_ALL=C /bin/ps -p "$pid" -o lstart= 2> /dev/null |
        /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | /usr/bin/head -1
}

install_lock_command() {
    local use_sudo="$1"
    shift
    if [[ "$use_sudo" != "true" ]]; then
        "$@"
        return
    fi
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi
    if [[ "${MOLE_ASSUME_SUDO_AUTH:-0}" == "1" ]]; then
        sudo -n "$@"
    else
        sudo "$@"
    fi
}

# One interactive recovery for a lapsed sudo session, through the controlling
# terminal so it works even when the installer's stdio is captured by a caller.
# Returns non-zero without prompting when there is no terminal to ask on.
install_lock_reauthenticate() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi
    [[ -r /dev/tty && -w /dev/tty ]] || return 1
    # shellcheck disable=SC2024 # sudo's own prompt belongs on the same terminal.
    sudo -v < /dev/tty > /dev/tty 2> /dev/tty
}

install_lock_current_shell_pid() {
    local variable_name="$1"
    local pid_file current_pid=""
    pid_file=$(/usr/bin/mktemp /tmp/mole-install-pid.XXXXXX) || return 1
    if ! /bin/sh -c 'printf "%s\n" "$PPID" > "$1"' sh "$pid_file"; then
        safe_rm "$pid_file"
        return 1
    fi
    IFS= read -r current_pid < "$pid_file" || true
    safe_rm "$pid_file"
    [[ "$current_pid" =~ ^[0-9]+$ ]] || return 1
    printf -v "$variable_name" '%s' "$current_pid"
}

install_lock_prepare_dir() {
    local use_sudo="$1"
    local lock_dir="$INSTALL_DIR/.mole-update.lock"
    local expected_uid owner_uid mode acl_listing
    expected_uid=$(id -u 2> /dev/null || true)
    [[ "$expected_uid" =~ ^[0-9]+$ ]] || return 1

    if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
        install_lock_command "$use_sudo" mkdir -m 0700 "$lock_dir" 2> /dev/null || return 1
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
    # macOS applies inherited ACLs even when mkdir requests mode 0700. Remove
    # them before touching the lock file, then verify that no ACL entry remains.
    # Once this succeeds, only the expected owner can mutate directory entries.
    install_lock_command "$use_sudo" /bin/chmod -N "$lock_dir" 2> /dev/null || return 1
    acl_listing=$(install_lock_command "$use_sudo" /bin/ls -lde "$lock_dir" 2> /dev/null) || return 1
    if printf '%s\n' "$acl_listing" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+:'; then
        return 1
    fi
    owner_uid=$(install_lock_command "$use_sudo" /usr/bin/stat -f%u "$lock_dir" 2> /dev/null || true)
    mode=$(install_lock_command "$use_sudo" /usr/bin/stat -f%Lp "$lock_dir" 2> /dev/null || true)
    if [[ "$use_sudo" == "true" ]]; then
        expected_uid=0
    fi
    [[ "$owner_uid" == "$expected_uid" && "$mode" =~ ^[0-7]+$ ]] || return 1
    (((8#$mode & 0077) == 0)) || return 1
}

install_lock_read_owner() {
    local lock_path="$1"
    local use_sudo="$2"
    install_lock_command "$use_sudo" /bin/test -f "$lock_path" 2> /dev/null || return 1
    ! install_lock_command "$use_sudo" /bin/test -L "$lock_path" 2> /dev/null || return 1
    install_lock_command "$use_sudo" cat "$lock_path" 2> /dev/null
}

install_lock_remove_control() {
    local control_path="$1"
    local use_sudo="$2"
    local control_prefix="$INSTALL_DIR/.mole-update.lock/control."
    local control_suffix
    [[ -n "$control_path" ]] || return 0
    [[ "$control_path" == "$control_prefix"* ]] || return 1
    control_suffix="${control_path#"$control_prefix"}"
    [[ -n "$control_suffix" && "$control_suffix" != */* ]] || return 1
    install_lock_command "$use_sudo" /bin/test -f "$control_path" 2> /dev/null || return 1
    ! install_lock_command "$use_sudo" /bin/test -L "$control_path" 2> /dev/null || return 1
    install_lock_command "$use_sudo" /bin/rm -f "$control_path" 2> /dev/null # SAFE: exact mktemp-created install lock control file.
}

acquire_install_lock() {
    local lock_path="$INSTALL_DIR/.mole-update.lock/kernel.lock"
    local control_path holder_pid owner_pid owner_start token owner_value="" attempt=0
    local use_sudo=false
    if [[ ${EUID:-0} -ne 0 && ! -w "$INSTALL_DIR" ]]; then
        use_sudo=true
    fi
    INSTALL_LOCK_FAILURE="busy"
    if install_lock_has_unsafe_ancestor "$use_sudo"; then
        INSTALL_LOCK_FAILURE="unsafe_ancestor"
        return 1
    fi
    # Probe admin access before the first privileged lock step. Without this the
    # denial surfaces as a swallowed `sudo -n` inside install_lock_prepare_dir
    # and gets reported as a busy lock.
    if [[ "$use_sudo" == "true" ]] &&
        ! install_lock_command "$use_sudo" /usr/bin/true 2> /dev/null; then
        # A caller that set MOLE_ASSUME_SUDO_AUTH did authenticate, but the
        # session can lapse before this point on a slow download or when the
        # keepalive dies. Recover once through the controlling terminal instead
        # of failing an install that only needs the password again. Without a
        # terminal this is a no-op and the refusal stands.
        if ! install_lock_reauthenticate ||
            ! install_lock_command "$use_sudo" /usr/bin/true 2> /dev/null; then
            INSTALL_LOCK_FAILURE="no_admin"
            return 1
        fi
    fi
    if ! install_lock_prepare_dir "$use_sudo"; then
        INSTALL_LOCK_FAILURE="lock_dir"
        return 1
    fi
    if install_lock_command "$use_sudo" /bin/test -e "$lock_path" 2> /dev/null ||
        install_lock_command "$use_sudo" /bin/test -L "$lock_path" 2> /dev/null; then
        INSTALL_LOCK_FAILURE="lock_path"
        install_lock_command "$use_sudo" /bin/test -f "$lock_path" 2> /dev/null || return 1
        ! install_lock_command "$use_sudo" /bin/test -L "$lock_path" 2> /dev/null || return 1
        INSTALL_LOCK_FAILURE="busy"
    fi
    # /usr/bin/lockf gives a kernel lock the OS drops even if the holder is
    # killed -9, so prefer it. It only ships with newer macOS, and requiring it
    # made both install and update exit before writing a single file on every
    # older release (#1348). Where it is absent, an atomic mkdir inside the lock
    # directory provides the same mutual exclusion; what it does not provide is
    # release-on-death, so that path reclaims a mutex whose recorded owner is
    # provably gone. Only a system with neither is refused.
    local mutex_dir=""
    if [[ ! -x /usr/bin/lockf ]]; then
        if [[ ! -x /bin/mkdir ]]; then
            INSTALL_LOCK_FAILURE="no_mutex"
            return 1
        fi
        mutex_dir="$INSTALL_DIR/.mole-update.lock/holder"
    fi
    install_lock_current_shell_pid owner_pid || return 1
    owner_start=$(install_lock_process_start "$owner_pid")
    [[ -n "$owner_start" ]] || return 1
    control_path=$(install_lock_command "$use_sudo" /usr/bin/mktemp "$INSTALL_DIR/.mole-update.lock/control.XXXXXX") || return 1
    token="$owner_pid|$owner_start|${control_path##*.}"

    # shellcheck disable=SC2016 # The lock-holder shell expands these values.
    local holder_script='
        token="$1"
        owner_pid="$2"
        owner_start="$3"
        lock_path="$4"
        control_path="$5"
        mutex_dir="$6"
        current_start=""
        if [ ! -f "$control_path" ]; then
            exit 1
        fi
        if [ -n "$mutex_dir" ] && ! /bin/mkdir "$mutex_dir" 2>/dev/null; then
            # Occupied. Reclaim only against proof the recorded owner is gone:
            # a live pid whose start time still matches is a real concurrent
            # writer, and a reused pid is why the start time is compared too.
            previous=$(/bin/cat "$lock_path" 2>/dev/null || true)
            previous_pid=${previous%%|*}
            previous_rest=${previous#*|}
            previous_start=${previous_rest%%|*}
            owner_gone=1
            if [ -n "$previous_pid" ] && kill -0 "$previous_pid" 2>/dev/null; then
                current_start=$(LC_ALL=C /bin/ps -p "$previous_pid" -o lstart= 2>/dev/null |
                    /usr/bin/sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | /usr/bin/head -1)
                if [ "$current_start" = "$previous_start" ]; then
                    owner_gone=0
                fi
            fi
            [ "$owner_gone" = 1 ] || exit 1
            /bin/rmdir "$mutex_dir" 2>/dev/null || exit 1
            /bin/mkdir "$mutex_dir" 2>/dev/null || exit 1
        fi
        if ! printf "%s\n" "$token" > "$lock_path"; then
            [ -n "$mutex_dir" ] && /bin/rmdir "$mutex_dir" 2>/dev/null
            exit 1
        fi
        while [ -f "$control_path" ]; do
            kill -0 "$owner_pid" 2>/dev/null || break
            current_start=$(LC_ALL=C /bin/ps -p "$owner_pid" -o lstart= 2>/dev/null |
                /usr/bin/sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | /usr/bin/head -1)
            [ "$current_start" = "$owner_start" ] || break
            /bin/sleep 0.1
        done
        /bin/rm -f "$control_path" # SAFE: exact mktemp-created install lock control file.
        [ -n "$mutex_dir" ] && /bin/rmdir "$mutex_dir" 2>/dev/null
        exit 0
    '
    if [[ -n "$mutex_dir" ]]; then
        install_lock_command "$use_sudo" /bin/sh -c "$holder_script" \
            sh "$token" "$owner_pid" "$owner_start" "$lock_path" "$control_path" "$mutex_dir" &
    else
        install_lock_command "$use_sudo" /usr/bin/lockf -k -s -t 0 -w "$lock_path" /bin/sh -c "$holder_script" \
            sh "$token" "$owner_pid" "$owner_start" "$lock_path" "$control_path" "" &
    fi
    holder_pid=$!

    while [[ "$attempt" -lt 100 ]]; do
        if ! kill -0 "$holder_pid" 2> /dev/null; then
            wait "$holder_pid" 2> /dev/null || true
            install_lock_remove_control "$control_path" "$use_sudo" || true
            return 1
        fi
        owner_value=$(install_lock_read_owner "$lock_path" "$use_sudo" || true)
        if [[ "$owner_value" == "$token" ]]; then
            INSTALL_LOCK_PATH="$lock_path"
            INSTALL_LOCK_CONTROL="$control_path"
            INSTALL_LOCK_HOLDER_PID="$holder_pid"
            INSTALL_LOCK_USE_SUDO="$use_sudo"
            INSTALL_LOCK_FAILURE=""
            return 0
        fi
        /bin/sleep 0.05
        attempt=$((attempt + 1))
    done

    install_lock_remove_control "$control_path" "$use_sudo" || true
    wait "$holder_pid" 2> /dev/null || true
    return 1
}

# One rejection reason, one remedy. Callers must not print a bare lock message.
report_install_lock_failure() {
    local install_lock_dir
    case "$INSTALL_LOCK_FAILURE" in
        no_admin)
            log_error "Admin access to $INSTALL_DIR is required but not available"
            log_error "Cache credentials first, then retry: sudo -v && mo update"
            ;;
        unsafe_ancestor)
            install_lock_dir="${INSTALL_LOCK_UNSAFE_ANCESTOR:-<dir>}"
            case "$INSTALL_LOCK_UNSAFE_ANCESTOR_REASON" in
                symlink)
                    log_error "$install_lock_dir is a symlink, so a privileged write through it cannot be trusted"
                    log_error "See where it points, install under a real directory, then retry: ls -ld $install_lock_dir"
                    ;;
                not_root_owned)
                    log_error "$install_lock_dir is not owned by root, so a privileged write there cannot be trusted"
                    log_error "Restore ownership, then retry: sudo chown root:wheel $install_lock_dir"
                    ;;
                foreign_owner)
                    log_error "$install_lock_dir is owned by neither root nor you"
                    log_error "Take ownership, then retry: sudo chown $(id -un) $install_lock_dir"
                    ;;
                acl)
                    log_error "$install_lock_dir carries an ACL that grants access beyond its mode"
                    log_error "Clear it, then retry: sudo chmod -N $install_lock_dir"
                    ;;
                unreadable)
                    log_error "$install_lock_dir could not be inspected, so it cannot be cleared for a privileged write"
                    log_error "Look at it, then retry: sudo ls -lde $install_lock_dir"
                    ;;
                writable)
                    log_error "$install_lock_dir is writable by someone other than root"
                    log_error "Close it, then retry: sudo chmod go-w $install_lock_dir"
                    ;;
                *)
                    log_error "$install_lock_dir cannot be trusted for a privileged write"
                    log_error "Inspect it, then retry: sudo ls -lde $install_lock_dir"
                    ;;
            esac
            ;;
        lock_dir)
            log_error "$INSTALL_DIR/.mole-update.lock is not a usable lock directory"
            log_error "Inspect it, then retry: sudo ls -lde $INSTALL_DIR/.mole-update.lock"
            ;;
        lock_path)
            log_error "$INSTALL_DIR/.mole-update.lock/kernel.lock is not a regular file"
            log_error "Remove it, then retry: sudo rm -f $INSTALL_DIR/.mole-update.lock/kernel.lock"
            ;;
        no_mutex)
            log_error "Neither /usr/bin/lockf nor /bin/mkdir is usable, so concurrent installs cannot be kept apart"
            log_error "Check that /bin and /usr/bin are intact, then retry: ls -l /bin/mkdir /usr/bin/lockf"
            ;;
        *)
            log_error "Another install or update is running, wait for it to finish and retry"
            ;;
    esac
}

release_install_lock() {
    [[ -n "$INSTALL_LOCK_CONTROL" ]] &&
        install_lock_remove_control "$INSTALL_LOCK_CONTROL" "$INSTALL_LOCK_USE_SUDO" || true
    [[ -n "$INSTALL_LOCK_HOLDER_PID" ]] && wait "$INSTALL_LOCK_HOLDER_PID" 2> /dev/null || true
    INSTALL_LOCK_PATH=""
    INSTALL_LOCK_CONTROL=""
    INSTALL_LOCK_HOLDER_PID=""
    INSTALL_LOCK_USE_SUDO=false
}

cleanup_installer() {
    stop_line_spinner 2> /dev/null || true
    release_install_lock
    if [[ -n "$INSTALL_SOURCE_TMP" ]]; then
        # Teardown never decides the exit status. This runs from the EXIT trap
        # under `set -e`, so a refusal here used to turn a finished, verified
        # install into exit 1 and every caller that checks the status, package
        # managers included, read it as a failed install (#1343). safe_rm still
        # prints why it refused; it just no longer overrides the verdict the
        # install itself already reached.
        safe_rm "$INSTALL_SOURCE_TMP" || true
        INSTALL_SOURCE_TMP=""
    fi
}

get_remote_main_commit_hash() {
    command -v curl > /dev/null 2>&1 || return 1

    local response=""
    local commit_hash=""
    response=$(curl -fsSL --connect-timeout 3 --max-time 5 \
        "https://api.github.com/repos/tw93/mole/commits/main" 2> /dev/null || true)
    commit_hash=$(printf '%s\n' "$response" |
        sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{40\}\)".*/\1/p' | head -1)
    [[ "$commit_hash" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "$commit_hash"
}

source_archive_url() {
    local branch="$1"
    local source_commit="${2:-}"

    if [[ "$branch" == "main" && "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'https://github.com/tw93/mole/archive/%s.tar.gz\n' "$source_commit"
    elif [[ "$branch" == "main" || "$branch" == "dev" ]]; then
        printf 'https://github.com/tw93/mole/archive/refs/heads/%s.tar.gz\n' "$branch"
    else
        printf 'https://github.com/tw93/mole/archive/refs/tags/%s.tar.gz\n' "$branch"
    fi
}

resolve_source_dir() {
    if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" && -f "$SOURCE_DIR/mole" ]]; then
        return 0
    fi

    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$script_dir/mole" ]]; then
            SOURCE_DIR="$script_dir"
            return 0
        fi
    fi

    if [[ -n "${CLEAN_SOURCE_DIR:-}" && -d "$CLEAN_SOURCE_DIR" && -f "$CLEAN_SOURCE_DIR/mole" ]]; then
        SOURCE_DIR="$CLEAN_SOURCE_DIR"
        return 0
    fi

    local tmp
    # Derive the directory from the same TMPDIR safe_rm gates on. A bare
    # `mktemp -d` ignores TMPDIR on macOS and always lands in the Darwin
    # per-user temp dir, so with TMPDIR unset the two disagreed and cleanup
    # refused to remove what the installer had just created (#1343). Homebrew
    # strips TMPDIR from the environment, which made that deterministic there.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/mole.XXXXXX")"
    INSTALL_SOURCE_TMP="$tmp"

    local branch="${MOLE_VERSION:-}"
    if [[ -z "$branch" ]]; then
        branch="$(get_latest_release_tag || true)"
    fi
    if [[ -z "$branch" ]]; then
        branch="$(get_latest_release_tag_from_git || true)"
    fi
    if [[ -z "$branch" ]]; then
        # Both release-tag lookups failed (typically GitHub API rate limits
        # while codeload still works). Keep the install usable, but say
        # loudly that this is now a nightly source install, not a release.
        log_warning "Could not resolve the latest release tag; installing from main (nightly source)"
        branch="main"
    fi
    if [[ "$branch" != "main" && "$branch" != "dev" ]]; then
        branch="$(normalize_release_tag "$branch")"
    fi
    local source_commit=""
    if [[ "$branch" == "main" ]]; then
        source_commit="${MOLE_INSTALL_COMMIT:-}"
        if [[ -n "$source_commit" && ! "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
            log_error "Invalid pinned source commit"
            exit 1
        fi
        if [[ -z "$source_commit" ]]; then
            source_commit=$(get_remote_main_commit_hash || true)
        fi
        if [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
            SOURCE_COMMIT_HASH="$source_commit"
        fi
    fi
    local url
    url=$(source_archive_url "$branch" "$source_commit")

    start_line_spinner "Fetching Mole source, ${branch}..."
    if command -v curl > /dev/null 2>&1; then
        if curl_download_with_retry "$url" "$tmp/mole.tar.gz" 2> /dev/null; then
            if tar -xzf "$tmp/mole.tar.gz" -C "$tmp" 2> /dev/null; then
                stop_line_spinner

                local extracted_dir
                extracted_dir=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)

                if [[ -n "$extracted_dir" && -f "$extracted_dir/mole" ]]; then
                    SOURCE_DIR="$extracted_dir"
                    return 0
                fi
            fi
        else
            stop_line_spinner
            # Only exit early for version tags (not for main/dev branches)
            if [[ "$branch" != "main" && "$branch" != "dev" ]]; then
                log_error "Failed to fetch version ${branch}. Check if tag exists."
                exit 1
            fi
        fi
    fi
    stop_line_spinner

    start_line_spinner "Cloning Mole source..."
    if command -v git > /dev/null 2>&1; then
        local clone_succeeded=false
        if [[ -n "$source_commit" ]]; then
            if git init -q "$tmp/mole" > /dev/null 2>&1 &&
                git -C "$tmp/mole" remote add origin https://github.com/tw93/mole.git > /dev/null 2>&1 &&
                git -C "$tmp/mole" fetch -q --depth=1 origin "$source_commit" > /dev/null 2>&1 &&
                git -C "$tmp/mole" checkout -q --detach FETCH_HEAD > /dev/null 2>&1; then
                clone_succeeded=true
            fi
        else
            local git_args=("--depth=1")
            if [[ "$branch" != "main" ]]; then
                git_args+=("--branch" "$branch")
            fi
            if git clone "${git_args[@]}" https://github.com/tw93/mole.git "$tmp/mole" > /dev/null 2>&1; then
                clone_succeeded=true
            fi
        fi

        if [[ "$clone_succeeded" == "true" ]]; then
            stop_line_spinner
            SOURCE_DIR="$tmp/mole"
            SOURCE_COMMIT_HASH=$(git -C "$SOURCE_DIR" rev-parse HEAD 2> /dev/null || true)
            return 0
        fi
    fi
    stop_line_spinner

    log_error "Failed to fetch source files. Ensure curl or git is available."
    exit 1
}

# Version helpers
get_source_version() {
    local source_mole="$SOURCE_DIR/mole"
    if [[ -f "$source_mole" ]]; then
        sed -n 's/^VERSION="\(.*\)"$/\1/p' "$source_mole" | head -n1
    fi
}

get_source_commit_hash() {
    if [[ "$SOURCE_COMMIT_HASH" =~ ^[0-9a-f]{7,40}$ ]]; then
        printf '%s\n' "$SOURCE_COMMIT_HASH"
        return 0
    fi
    # Try to get from local git repo first
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        git -C "$SOURCE_DIR" rev-parse --short HEAD 2> /dev/null && return
    fi
    return 1
}

get_latest_release_tag() {
    local tag
    if ! command -v curl > /dev/null 2>&1; then
        return 1
    fi
    tag=$(curl -fsSL --connect-timeout 2 --max-time 3 \
        "https://api.github.com/repos/tw93/mole/releases/latest" 2> /dev/null |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    if [[ -z "$tag" ]]; then
        return 1
    fi
    printf '%s\n' "$tag"
}

get_latest_release_tag_from_git() {
    if ! command -v git > /dev/null 2>&1; then
        return 1
    fi
    git ls-remote --tags --refs https://github.com/tw93/mole.git 2> /dev/null |
        awk -F/ '{print $NF}' |
        grep -E '^V[0-9]' |
        sort -V |
        tail -n 1
}

normalize_release_tag() {
    local tag="$1"
    while [[ "$tag" =~ ^[vV] ]]; do
        tag="${tag#v}"
        tag="${tag#V}"
    done
    if [[ -n "$tag" ]]; then
        printf 'V%s\n' "$tag"
    fi
}

release_checksums_url() {
    local tag="$1"
    printf 'https://github.com/tw93/mole/releases/download/%s/SHA256SUMS\n' "$tag"
}

download_release_checksums() {
    local tag="$1"
    local output_file="$2"
    local url
    url="$(release_checksums_url "$tag")"

    curl_download_with_retry "$url" "$output_file"
}

# Verify the Sigstore/GitHub Actions build-provenance attestation for a release
# asset. Returns:
#   0 - attestation verified
#   1 - verification failed (asset has no matching attestation, or signature invalid)
#   2 - cannot verify (gh CLI missing or unauthenticated); caller decides policy
#
# The release workflow generates attestations via actions/attest-build-provenance
# covering SHA256SUMS, the per-arch binaries, and the homebrew tarballs.
# Verifying the SHA256SUMS file is sufficient: the binary's sha256 is then
# anchored to that attested file by verify_release_asset_checksum().
verify_release_attestation() {
    local file="$1"

    if ! command -v gh > /dev/null 2>&1; then
        return 2
    fi
    if ! gh auth status > /dev/null 2>&1; then
        return 2
    fi

    # Bind provenance to this exact repository rather than accepting an
    # attestation from any repository owned by tw93. --deny-self-hosted-runners
    # also blocks attestations produced by self-hosted runners, which a repo
    # compromise could otherwise introduce as a sidechannel.
    if gh attestation verify "$file" \
        --repo tw93/Mole \
        --deny-self-hosted-runners \
        > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

extract_release_checksum() {
    local checksums_file="$1"
    local asset_name="$2"

    awk -v asset="$asset_name" '$2 == asset { print $1; found = 1; exit } END { exit found ? 0 : 1 }' "$checksums_file"
}

calculate_file_sha256() {
    local file="$1"

    if command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1; exit}'
        return
    fi
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1; exit}'
        return
    fi

    return 1
}

verify_release_asset_checksum() {
    local tag="$1"
    local asset_name="$2"
    local file="$3"
    local checksums_file
    checksums_file="$(mktemp "${TMPDIR:-/tmp}/mole-checksums.XXXXXX")" || return 1

    local expected=""
    local actual=""
    local result=1
    local attestation_status=2

    # The checksums fetch and the attestation check are separate network round
    # trips that can take several seconds each. With nothing on screen this is
    # the longest silent stretch of an install and reads as a hang, so keep a
    # spinner up until the first real line prints.
    start_line_spinner "Verifying ${asset_name}..."

    if download_release_checksums "$tag" "$checksums_file" > /dev/null 2>&1; then
        # Anchor the SHA256SUMS file to its GitHub Actions build-provenance
        # attestation before reading checksums from it. If gh is available,
        # an attestation mismatch is fatal; without gh, fall through to
        # checksum-only verification (matches prior behavior).
        verify_release_attestation "$checksums_file"
        attestation_status=$?

        if [[ "$attestation_status" -eq 1 ]]; then
            stop_line_spinner
            log_error "Release attestation verification failed for ${asset_name}"
            rm -f "$checksums_file"
            return 1
        fi

        if [[ "$attestation_status" -eq 2 && "${MOLE_REQUIRE_ATTESTATION:-0}" == "1" ]]; then
            stop_line_spinner
            log_error "MOLE_REQUIRE_ATTESTATION=1 set but gh CLI unavailable or unauthenticated"
            rm -f "$checksums_file"
            return 1
        fi

        expected=$(extract_release_checksum "$checksums_file" "$asset_name" 2> /dev/null || true)
        actual=$(calculate_file_sha256 "$file" 2> /dev/null || true)
        if [[ -n "$expected" && -n "$actual" && "$expected" == "$actual" ]]; then
            result=0
            if [[ "$attestation_status" -eq 0 ]]; then
                stop_line_spinner
                log_success "Verified ${asset_name} · sha256 + attestation"
            fi
        fi
    fi

    stop_line_spinner
    rm -f "$checksums_file"
    return "$result"
}

get_installed_version() {
    local binary="$INSTALL_DIR/mole"
    if [[ -x "$binary" ]]; then
        local version
        version=$(run_install_probe_with_timeout 5 "$binary" --version 2> /dev/null |
            awk '/Mole version/ {print $NF; exit}' || true)
        if [[ -n "$version" ]]; then
            echo "$version"
        else
            sed -n 's/^VERSION="\(.*\)"$/\1/p' "$binary" | head -n1
        fi
    fi
}

resolve_install_channel() {
    case "${MOLE_VERSION:-}" in
        main | latest)
            printf 'nightly\n'
            return 0
            ;;
        dev)
            printf 'dev\n'
            return 0
            ;;
    esac

    if [[ "${MOLE_EDGE_INSTALL:-}" == "true" ]]; then
        printf 'nightly\n'
        return 0
    fi

    printf 'stable\n'
}

write_install_channel_metadata() {
    local channel="$1"
    local commit_hash="${2:-}"
    local install_receipt="${3:-}"
    local metadata_file="$CONFIG_DIR/install_channel"

    if [[ -n "$install_receipt" && ! "$install_receipt" =~ ^(heal|update)-[0-9]+-[0-9]+-[0-9]+$ ]]; then
        return 1
    fi

    mkdir -p "$CONFIG_DIR" 2> /dev/null || return 1
    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/install_channel.XXXXXX") || return 1
    # Use a plain if/fi so the block's exit code reflects only I/O failure.
    # The previous form `[[ -n "$h" ]] && printf ...` returned 1 whenever the
    # commit hash was empty (the stable channel always omits it), which made
    # the redirect look like it had failed and tripped the warning.
    {
        printf 'CHANNEL=%s\n' "$channel"
        if [[ -n "$commit_hash" ]]; then
            printf 'COMMIT_HASH=%s\n' "$commit_hash"
        fi
        if [[ -n "$install_receipt" ]]; then
            printf 'INSTALL_RECEIPT=%s\n' "$install_receipt"
        fi
    } > "$tmp_file" || {
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    }

    mv -f "$tmp_file" "$metadata_file" || {
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    }
}

# CLI parsing (supports main, the legacy latest alias, and version tokens).
parse_args() {
    local -a args=("$@")
    local version_token=""
    local i skip_next=false
    for i in "${!args[@]}"; do
        local token="${args[$i]}"
        [[ -z "$token" ]] && continue
        # Skip values for options that take arguments
        if [[ "$skip_next" == "true" ]]; then
            skip_next=false
            continue
        fi
        if [[ "$token" == "--prefix" || "$token" == "--config" ]]; then
            skip_next=true
            continue
        fi
        if [[ "$token" == -* ]]; then
            continue
        fi
        if [[ -n "$version_token" ]]; then
            log_error "Unexpected argument: $token"
            exit 1
        fi
        case "$token" in
            latest | main)
                export MOLE_VERSION="main"
                export MOLE_EDGE_INSTALL="true"
                version_token="$token"
                unset 'args[$i]'
                ;;
            dev)
                export MOLE_VERSION="dev"
                export MOLE_EDGE_INSTALL="true"
                version_token="$token"
                unset 'args[$i]'
                ;;
            [0-9]* | V[0-9]* | v[0-9]*)
                export MOLE_VERSION="$token"
                version_token="$token"
                unset 'args[$i]'
                ;;
            *)
                log_error "Unknown option: $token"
                exit 1
                ;;
        esac
    done
    if [[ ${#args[@]} -gt 0 ]]; then
        set -- ${args[@]+"${args[@]}"}
    else
        set --
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --prefix)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --prefix"
                    exit 1
                fi
                INSTALL_DIR="$2"
                shift 2
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --config"
                    exit 1
                fi
                CONFIG_DIR="$2"
                shift 2
                ;;
            --update)
                ACTION="update"
                shift 1
                ;;
            --verbose | -v)
                VERBOSE=1
                shift 1
                ;;
            --help | -h)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

normalize_install_dir() {
    case "$INSTALL_DIR" in
        /*) return 0 ;;
    esac

    local physical_cwd
    physical_cwd=$(pwd -P 2> /dev/null) || return 1
    INSTALL_DIR="$physical_cwd/$INSTALL_DIR"
}

# Environment checks and directory setup
check_requirements() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_error "This tool is designed for macOS only"
        exit 1
    fi

    local minimum_macos_major=12
    local macos_version=""
    local macos_version_rc=0
    macos_version=$(run_install_probe_with_timeout 2 \
        /usr/bin/sw_vers -productVersion 2> /dev/null) || macos_version_rc=$?
    if [[ $macos_version_rc -ne 0 ||
        ! "$macos_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        log_error "Could not determine a supported macOS version (probe exit $macos_version_rc)"
        log_error "Verify sw_vers works, then retry the installation"
        exit 1
    fi
    local macos_major="${macos_version%%.*}"
    macos_major=$((10#$macos_major))
    if [[ $macos_major -lt $minimum_macos_major ]]; then
        log_error "Mole requires macOS $minimum_macos_major or newer; found $macos_version"
        log_error "Upgrade macOS before installing this release"
        exit 1
    fi

    if homebrew_owns_mole; then
        local mole_path
        mole_path=$(command -v mole 2> /dev/null || true)
        local is_homebrew_binary=false

        if [[ -n "$mole_path" && -L "$mole_path" ]]; then
            if readlink "$mole_path" | grep -q "Cellar/mole"; then
                is_homebrew_binary=true
            fi
        fi

        if [[ "$is_homebrew_binary" == "true" ]]; then
            if [[ "$ACTION" == "update" ]]; then
                return 0
            fi

            echo -e "${YELLOW}Mole is installed via Homebrew${NC}"
            echo ""
            echo "Choose one:"
            echo -e "  1. Update via Homebrew: ${GREEN}brew upgrade mole${NC}"
            echo -e "  2. Switch to manual: ${GREEN}brew uninstall --force mole${NC} then re-run this"
            echo ""
            exit 1
        else
            log_warning "Cleaning up stale Homebrew installation..."
            brew uninstall --force mole > /dev/null 2>&1 || true
        fi
    fi

    if [[ ! -d "$(dirname "$INSTALL_DIR")" ]]; then
        log_error "Parent directory $(dirname "$INSTALL_DIR") does not exist"
        exit 1
    fi
}

create_directories() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        maybe_sudo mkdir -p "$INSTALL_DIR"
    fi

    if ! mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/bin" "$CONFIG_DIR/lib"; then
        log_error "Failed to create config directory: $CONFIG_DIR"
        exit 1
    fi

}

# Binary install helpers
build_binary_from_source() {
    local binary_name="$1"
    local target_path="$2"
    local cmd_dir=""

    case "$binary_name" in
        analyze)
            cmd_dir="cmd/analyze"
            ;;
        status)
            cmd_dir="cmd/status"
            ;;
        *)
            return 1
            ;;
    esac

    if ! command -v go > /dev/null 2>&1; then
        return 1
    fi

    if [[ ! -d "$SOURCE_DIR/$cmd_dir" ]]; then
        return 1
    fi

    start_line_spinner "Building ${binary_name} from source..."

    if (cd "$SOURCE_DIR" && go build -ldflags="-s -w" -o "$target_path" "./$cmd_dir" > /dev/null 2>&1); then
        if [[ -t 1 ]]; then stop_line_spinner; fi
        chmod +x "$target_path"
        log_success "Built ${binary_name} from source"
        return 0
    fi

    if [[ -t 1 ]]; then stop_line_spinner; fi
    log_warning "Failed to build ${binary_name} from source"
    return 1
}

install_staged_binary() {
    local staged_path="$1"
    local target_path="$2"

    chmod +x "$staged_path" || return 1
    xattr -c "$staged_path" 2> /dev/null || true
    mv -f "$staged_path" "$target_path"
}

download_binary() {
    local binary_name="$1"
    local target_path="$CONFIG_DIR/bin/${binary_name}-go"
    local staged_path
    staged_path=$(mktemp "$CONFIG_DIR/bin/.${binary_name}-go.XXXXXX") || return 1
    local arch
    arch=$(uname -m)
    local arch_suffix="amd64"
    if [[ "$arch" == "arm64" ]]; then
        arch_suffix="arm64"
    fi

    if [[ -f "$SOURCE_DIR/bin/${binary_name}-go" ]]; then
        if ! cp "$SOURCE_DIR/bin/${binary_name}-go" "$staged_path" ||
            ! install_staged_binary "$staged_path" "$target_path"; then
            rm -f "$staged_path"
            return 1
        fi
        log_success "Installed local ${binary_name} binary"
        return 0
    elif [[ -f "$SOURCE_DIR/bin/${binary_name}-darwin-${arch_suffix}" ]]; then
        if ! cp "$SOURCE_DIR/bin/${binary_name}-darwin-${arch_suffix}" "$staged_path" ||
            ! install_staged_binary "$staged_path" "$target_path"; then
            rm -f "$staged_path"
            return 1
        fi
        log_success "Installed local ${binary_name} binary"
        return 0
    fi

    if [[ "${MOLE_EDGE_INSTALL:-}" == "true" ]]; then
        if build_binary_from_source "$binary_name" "$staged_path" &&
            install_staged_binary "$staged_path" "$target_path"; then
            return 0
        fi
        rm -f "$staged_path"
    fi

    local version
    version=$(get_source_version)
    if [[ -z "$version" ]]; then
        log_warning "Could not determine version for ${binary_name}, trying local build"
        if build_binary_from_source "$binary_name" "$staged_path" &&
            install_staged_binary "$staged_path" "$target_path"; then
            return 0
        fi
        rm -f "$staged_path"
        return 1
    fi
    local release_tag
    release_tag="$(normalize_release_tag "$version")"
    local asset_name="${binary_name}-darwin-${arch_suffix}"
    local url="https://github.com/tw93/mole/releases/download/${release_tag}/${asset_name}"

    # Skip preflight network checks to avoid false negatives.

    start_line_spinner "Downloading ${binary_name}..."

    # Both download attempts are followed by another route, so a failure here
    # is a step in the flow rather than the end of it. Surfacing curl's raw
    # stderr made the ordinary "tag not published yet" case print a 404 the
    # user cannot act on, immediately above the line explaining the fallback.
    if curl_download_with_retry "$url" "$staged_path" 2> /dev/null; then
        if [[ -t 1 ]]; then stop_line_spinner; fi
        if verify_release_asset_checksum "$release_tag" "$asset_name" "$staged_path" &&
            install_staged_binary "$staged_path" "$target_path"; then
            log_success "Installed ${binary_name}"
            return 0
        fi
        rm -f "$staged_path"
        # Integrity failure is fatal, never a downgrade. The asset arrived
        # but its SHA256SUMS/attestation check did not pass; a blocked or
        # tampered checksums file must not be able to reroute the install
        # onto an unverified source build (classic verification-stripping
        # downgrade). Explicit source builds remain available via
        # MOLE_VERSION=main / MOLE_EDGE_INSTALL=true.
        log_error "Verification failed for ${binary_name}; aborting instead of falling back to an unverified build"
        log_error "Retry later, or opt into a source build explicitly: MOLE_VERSION=main ./install.sh (piping from curl: | bash -s -- main)"
        return 1
    fi
    rm -f "$staged_path"
    if [[ -t 1 ]]; then stop_line_spinner; fi

    local fallback_tag
    fallback_tag=$(get_latest_release_tag 2> /dev/null || true)
    if [[ -n "$fallback_tag" && "$fallback_tag" != "$release_tag" ]]; then
        local fallback_url="https://github.com/tw93/mole/releases/download/${fallback_tag}/${asset_name}"
        start_line_spinner "Retrying ${binary_name} from ${fallback_tag}..."
        if curl_download_with_retry "$fallback_url" "$staged_path" 2> /dev/null; then
            if [[ -t 1 ]]; then stop_line_spinner; fi
            if verify_release_asset_checksum "$fallback_tag" "$asset_name" "$staged_path" &&
                install_staged_binary "$staged_path" "$target_path"; then
                log_success "Installed ${binary_name} from ${fallback_tag} · v${version} not yet published"
                return 0
            fi
            rm -f "$staged_path"
            if [[ -t 1 ]]; then stop_line_spinner; fi
            # Same integrity contract as the primary tag above: the fallback
            # asset arrived but did not verify, which is evidence of tampering
            # or a corrupted checksums file, not of unavailability. Only a
            # plain download failure may continue into the source build.
            log_error "Verification failed for ${binary_name} from ${fallback_tag}; aborting instead of falling back to an unverified build"
            log_error "Retry later, or opt into a source build explicitly: MOLE_VERSION=main ./install.sh (piping from curl: | bash -s -- main)"
            return 1
        fi
        rm -f "$staged_path"
        if [[ -t 1 ]]; then stop_line_spinner; fi
    fi

    log_warning "Could not download ${binary_name} binary, v${version}, trying local build"
    if build_binary_from_source "$binary_name" "$staged_path" &&
        install_staged_binary "$staged_path" "$target_path"; then
        return 0
    fi
    rm -f "$staged_path"
    log_error "Failed to install ${binary_name} binary"
    return 1
}

# File installation (bin/lib/scripts + go helpers).
install_files() {

    resolve_source_dir

    local source_dir_abs
    local install_dir_abs
    local config_dir_abs
    source_dir_abs="$(cd "$SOURCE_DIR" && pwd)"
    install_dir_abs="$(cd "$INSTALL_DIR" && pwd)"
    config_dir_abs="$(cd "$CONFIG_DIR" && pwd)"

    if [[ -f "$SOURCE_DIR/mole" ]]; then
        if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
            if needs_sudo; then
                log_admin "Admin access required for /usr/local/bin"
                if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
                    log_error "Admin access required, blocked in test mode"
                    return 1
                fi
                # Explicit failure checks throughout this function: callers run
                # `install_files || {...}`, and bash disables errexit inside a
                # function invoked that way, so a failed sudo would otherwise be
                # swallowed and the install would report success while leaving
                # the old entry script in place (the 1.45.0 -> 1.47.0 fake
                # "Updated to latest version" incident).
                if ! ensure_sudo_ready; then
                    log_error "Admin access to $INSTALL_DIR is required but not available"
                    log_error "Cache credentials first, then retry: sudo -v && mo update"
                    return 1
                fi
            fi

            # Atomic update: copy to temporary name first, then move
            if ! maybe_sudo cp "$SOURCE_DIR/mole" "$INSTALL_DIR/mole.new" ||
                ! maybe_sudo chmod +x "$INSTALL_DIR/mole.new" ||
                ! maybe_sudo mv -f "$INSTALL_DIR/mole.new" "$INSTALL_DIR/mole"; then
                log_error "Failed to install mole to $INSTALL_DIR (admin access missing or denied)"
                log_error "Cache credentials first, then retry: sudo -v && mo update"
                return 1
            fi

        fi
    else
        log_error "mole executable not found in ${SOURCE_DIR:-unknown}"
        exit 1
    fi

    if [[ -f "$SOURCE_DIR/mo" && "$source_dir_abs" != "$install_dir_abs" ]]; then
        if ! maybe_sudo cp "$SOURCE_DIR/mo" "$INSTALL_DIR/mo.new" ||
            ! maybe_sudo chmod +x "$INSTALL_DIR/mo.new" ||
            ! maybe_sudo mv -f "$INSTALL_DIR/mo.new" "$INSTALL_DIR/mo"; then
            log_error "Failed to install mo alias to $INSTALL_DIR (admin access missing or denied)"
            return 1
        fi
    fi

    if [[ -d "$SOURCE_DIR/bin" ]]; then
        local source_bin_abs="$(cd "$SOURCE_DIR/bin" && pwd)"
        local config_bin_abs="$(cd "$CONFIG_DIR/bin" && pwd)"
        if [[ "$source_bin_abs" != "$config_bin_abs" ]]; then
            local -a bin_files=("$SOURCE_DIR/bin"/*)
            if [[ ${#bin_files[@]} -gt 0 ]]; then
                cp -r "${bin_files[@]}" "$CONFIG_DIR/bin/"
                for file in "$CONFIG_DIR/bin/"*; do
                    [[ -e "$file" ]] && chmod +x "$file"
                done
            fi
        fi
    fi

    if [[ -d "$SOURCE_DIR/lib" ]]; then
        local source_lib_abs="$(cd "$SOURCE_DIR/lib" && pwd)"
        local config_lib_abs="$(cd "$CONFIG_DIR/lib" && pwd)"
        if [[ "$source_lib_abs" != "$config_lib_abs" ]]; then
            local -a lib_files=("$SOURCE_DIR/lib"/*)
            if [[ ${#lib_files[@]} -gt 0 ]]; then
                cp -r "${lib_files[@]}" "$CONFIG_DIR/lib/"
            fi
        fi
    fi

    if [[ "$config_dir_abs" != "$source_dir_abs" ]]; then
        for file in README.md LICENSE install.sh; do
            if [[ -f "$SOURCE_DIR/$file" ]]; then
                cp -f "$SOURCE_DIR/$file" "$CONFIG_DIR/"
            fi
        done
    fi

    if [[ -f "$CONFIG_DIR/install.sh" ]]; then
        chmod +x "$CONFIG_DIR/install.sh"
    fi

    if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
        # Use absolute /usr/bin/sed (always BSD on macOS) so PATH-shadowed
        # GNU sed from Homebrew gnu-sed does not break the -i '' syntax.
        if ! maybe_sudo /usr/bin/sed -i '' "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$CONFIG_DIR\"|" "$INSTALL_DIR/mole"; then
            log_error "Failed to point $INSTALL_DIR/mole at $CONFIG_DIR"
            return 1
        fi
    fi

    # One line for the whole file install. Reporting the entry script, the mo
    # alias, the modules and the libraries separately described the layout
    # rather than the outcome, and every one of them is a hard failure that
    # returns above if it goes wrong.
    log_success "Installed to $INSTALL_DIR"

    local helper_install_marker="$CONFIG_DIR/.helper_install_incomplete"
    : > "$helper_install_marker"
    if ! download_binary "analyze"; then
        exit 1
    fi
    if ! download_binary "status"; then
        exit 1
    fi
    rm -f "$helper_install_marker"
}

# Verification and PATH hint
verify_installation() {

    if [[ -x "$INSTALL_DIR/mole" ]] && [[ -f "$CONFIG_DIR/lib/core/common.sh" ]]; then
        # A runnable old entry script also passes --help, so cross-check the
        # installed version against the source that was just installed. A
        # mismatch means the entry script was not actually replaced (for
        # example a swallowed sudo failure) and the install is a mixed-version
        # state that must not be reported as success.
        local expected_version installed_version
        expected_version="$(get_source_version 2> /dev/null || true)"
        installed_version="$(get_installed_version 2> /dev/null || true)"
        if [[ -n "$expected_version" && -n "$installed_version" && "$expected_version" != "$installed_version" ]]; then
            log_error "Installed mole reports $installed_version but $expected_version was expected"
            log_error "The entry script at $INSTALL_DIR/mole was not replaced; retry with: sudo -v && mo update"
            exit 1
        fi

        if run_install_probe_with_timeout 5 "$INSTALL_DIR/mole" --help > /dev/null 2>&1; then
            return 0
        else
            log_error "Installed Mole did not answer the bounded help probe"
            return 1
        fi
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

setup_path() {
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        return
    fi

    if [[ "$INSTALL_DIR" != "/usr/local/bin" ]]; then
        log_warning "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "To use mole from anywhere, add this line to your shell profile:"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        echo "For example, add it to ~/.zshrc or ~/.bash_profile"
    fi
}

print_usage_summary() {
    local action="$1"
    local new_version="$2"
    local previous_version="${3:-}"

    if [[ ${VERBOSE} -ne 1 ]]; then
        return
    fi

    # A usage cheat sheet is for someone watching a fresh install scroll by.
    # `mo update` runs this same installer with its output captured, so on a
    # tty-less run the block arrives after the fact and tells an existing user
    # the nine commands they already use, followed by a second success line
    # contradicting nothing. The caller prints its own result there.
    [[ -t 1 ]] || return 0

    echo ""

    local message="Mole ${action} successfully"

    if [[ "$action" == "updated" && -n "$previous_version" && -n "$new_version" && "$previous_version" != "$new_version" ]]; then
        message+=", ${previous_version} -> ${new_version}"
    elif [[ -n "$new_version" ]]; then
        message+=", version ${new_version}"
    fi

    log_confirm "$message"

    echo ""
    echo "Usage:"
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        echo "  mo                           # Interactive menu"
        echo "  mo clean                     # Deep cleanup"
        echo "  mo uninstall                 # Remove apps + leftovers"
        echo "  mo optimize                  # Check and maintain system"
        echo "  mo analyze                   # Explore disk usage"
        echo "  mo status                    # Monitor system health"
        echo "  mo touchid                   # Configure Touch ID for sudo"
        echo "  mo update                    # Update to latest version"
        echo "  mo --help                    # Show all commands"
    else
        echo "  $INSTALL_DIR/mo                           # Interactive menu"
        echo "  $INSTALL_DIR/mo clean                     # Deep cleanup"
        echo "  $INSTALL_DIR/mo uninstall                 # Remove apps + leftovers"
        echo "  $INSTALL_DIR/mo optimize                  # Check and maintain system"
        echo "  $INSTALL_DIR/mo analyze                   # Explore disk usage"
        echo "  $INSTALL_DIR/mo status                    # Monitor system health"
        echo "  $INSTALL_DIR/mo touchid                   # Configure Touch ID for sudo"
        echo "  $INSTALL_DIR/mo update                    # Update to latest version"
        echo "  $INSTALL_DIR/mo --help                    # Show all commands"
    fi
    echo ""
}

# Whether Homebrew owns a mole install, decided from the Cellar on disk and
# never by running `brew`: the brew entry point resets the user's sudo
# timestamp as a security measure, and invoking it after the update flow's
# pre-authentication is exactly what killed the handed-over ticket within
# five seconds and forced a second password prompt on every update, with
# the ticket dying between installer start and the first privileged step.
homebrew_owns_mole() {
    local -a brew_prefixes=("${HOMEBREW_PREFIX:-}" /opt/homebrew /usr/local)
    # A custom prefix need not export HOMEBREW_PREFIX, and `brew list mole`
    # used to find those installs. Derive the prefix from brew's own location
    # instead: reading the path is not running the binary.
    local brew_bin=""
    brew_bin=$(command -v brew 2> /dev/null || true)
    if [[ -n "$brew_bin" ]]; then
        brew_prefixes+=("$(dirname "$(dirname "$brew_bin")")")
    fi
    local brew_prefix
    for brew_prefix in "${brew_prefixes[@]}"; do
        [[ -n "$brew_prefix" && -d "$brew_prefix/Cellar/mole" ]] && return 0
    done
    return 1
}

# Main install/update flows
perform_install() {
    check_requirements
    resolve_source_dir
    local source_version
    source_version="$(get_source_version || true)"

    create_directories
    acquire_install_lock || {
        report_install_lock_failure
        exit 1
    }
    install_files
    verify_installation
    setup_path

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        installed_version="$source_version"
    fi

    local install_channel commit_hash=""
    install_channel="$(resolve_install_channel)"
    if [[ "$install_channel" == "nightly" ]]; then
        commit_hash=$(get_source_commit_hash || true)
    fi
    if ! write_install_channel_metadata "$install_channel" "$commit_hash" "${MOLE_INSTALL_RECEIPT:-}"; then
        log_warning "Could not write install channel metadata"
    fi

    # Edge installs get a suffix to make the version explicit.
    if [[ "${MOLE_EDGE_INSTALL:-}" == "true" ]]; then
        installed_version="${installed_version}-edge"
        echo ""
        local branch_name="${MOLE_VERSION:-main}"
        log_warning "Edge version installed on ${branch_name} branch"
        log_info "This is a testing version; use 'mo update' to switch to stable"
    fi

    print_usage_summary "installed" "$installed_version"
}

perform_update() {
    check_requirements

    if homebrew_owns_mole; then
        resolve_source_dir 2> /dev/null || true
        local current_version
        current_version=$(get_installed_version || echo "unknown")
        if [[ -f "$SOURCE_DIR/lib/core/common.sh" ]]; then
            # shellcheck disable=SC1090,SC1091
            source "$SOURCE_DIR/lib/core/common.sh"
            update_via_homebrew "$current_version"
        else
            log_error "Cannot update Homebrew-managed Mole without full installation"
            echo ""
            echo "Please update via Homebrew:"
            echo -e "  ${GREEN}brew upgrade mole${NC}"
            exit 1
        fi
        exit 0
    fi

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        log_warning "Mole is not currently installed in $INSTALL_DIR. Running fresh installation."
        perform_install
        return
    fi

    resolve_source_dir
    local target_version
    target_version="$(get_source_version || true)"

    if [[ -z "$target_version" ]]; then
        log_error "Unable to determine the latest Mole version."
        exit 1
    fi

    if [[ "$installed_version" == "$target_version" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version, $installed_version"
        exit 0
    fi

    local old_verbose=$VERBOSE
    VERBOSE=0
    create_directories || {
        VERBOSE=$old_verbose
        log_error "Failed to create directories"
        exit 1
    }
    acquire_install_lock || {
        VERBOSE=$old_verbose
        report_install_lock_failure
        exit 1
    }
    install_files || {
        VERBOSE=$old_verbose
        log_error "Failed to install files"
        exit 1
    }
    verify_installation || {
        VERBOSE=$old_verbose
        log_error "Failed to verify installation"
        exit 1
    }
    setup_path
    VERBOSE=$old_verbose

    local updated_version
    updated_version="$(get_installed_version || true)"

    if [[ -z "$updated_version" ]]; then
        updated_version="$target_version"
    fi

    local install_channel commit_hash=""
    install_channel="$(resolve_install_channel)"
    if [[ "$install_channel" == "nightly" ]]; then
        commit_hash=$(get_source_commit_hash || true)
    fi
    if ! write_install_channel_metadata "$install_channel" "$commit_hash" "${MOLE_INSTALL_RECEIPT:-}"; then
        log_warning "Could not write install channel metadata"
    fi

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Updated to latest version, $updated_version"
}

parse_args "$@"
normalize_install_dir || {
    log_error "Could not resolve the installation directory: $INSTALL_DIR"
    exit 1
}

trap 'cleanup_installer' EXIT
trap 'cleanup_installer; exit 130' INT TERM

case "$ACTION" in
    update)
        perform_update
        ;;
    *)
        perform_install
        ;;
esac
