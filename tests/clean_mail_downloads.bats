#!/usr/bin/env bats

load helpers/common

# Regression for #1344: a Mail Downloads directory that cannot be sized within
# the disk-verify timeout (exit 124) must be skipped as a single target, not
# end the whole `mo clean` run at User essentials. Signal-class statuses
# (>=128) keep their cancellation semantics.

setup_file() {
    mole_test_setup_home mail-downloads
}

teardown_file() {
    mole_test_teardown_home
}

# Mail writes one folder per opened attachment and the copy inside it. Setting
# an earlier time also lowers the APFS creation time, so stamping the file and
# then its folder reproduces an untouched opening from that date.
mail_copy() {
    local folder="$1" name="$2" stamp="$3"
    mkdir -p "$folder"
    echo x > "$folder/$name"
    touch -t "$stamp" "$folder/$name"
    touch -t "$stamp" "$folder"
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-mail-downloads."* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "$HOME/Library"
}

@test "mail dir sizing timeout (124) skips the target and keeps the run going" {
    mkdir -p "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_path_size_kb() { return 124; }
_clean_mail_downloads
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Mail Downloads · skipped (sizing unavailable)"* ]] || return 1
    [[ "$output" == *"RC=0"* ]] || return 1
}

@test "mail dir sizing timeout (124) skips one dir and still cleans the other" {
    mail_copy "$HOME/Library/Mail Downloads/A1" old.bin 202401010000
    mkdir -p "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { echo "REMOVE:$1"; return 0; }
get_path_size_kb() {
    if [[ "$1" == "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads" ]]; then
        return 124
    fi
    if [[ "$1" == "$HOME/Library/Mail Downloads" ]]; then
        echo "6000"
        return 0
    fi
    echo "6000"
}
_clean_mail_downloads
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"REMOVE:$HOME/Library/Mail Downloads/A1/old.bin"* ]] || return 1
    [[ "$output" == *"Mail Downloads · skipped (sizing unavailable)"* ]] || return 1
    [[ "$output" == *"RC=0"* ]] || return 1
}

@test "mail attachment cleanup adds the removed bytes to the run totals (#2045)" {
    mail_copy "$HOME/Library/Mail Downloads/A1" old.bin 202401010000

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { return 0; }
get_path_size_kb() {
    if [[ "$1" == "$HOME/Library/Mail Downloads" ]]; then
        echo "6000"
        return 0
    fi
    echo "300"
}
files_cleaned=0
total_size_cleaned=0
total_items=0
_clean_mail_downloads
printf 'TOTALS=%s:%s:%s\n' "$files_cleaned" "$total_size_cleaned" "$total_items"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Cleaned 1 mail attachments"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"TOTALS=1:300:1"* ]] || { echo "$output"; return 1; }
}

@test "mail attachment sizing timeout (124) skips the file without aborting" {
    mail_copy "$HOME/Library/Mail Downloads/B2" stuck.bin 202401010000

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { echo "DEBUG:$*"; }
safe_remove() { echo "REMOVE:$1"; return 0; }
get_path_size_kb() {
    if [[ "$1" == "$HOME/Library/Mail Downloads" ]]; then
        echo "6000"
        return 0
    fi
    return 124
}
_clean_mail_downloads
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Mail attachment sizing failed"* ]] || return 1
    [[ "$output" != *"REMOVE:"* ]] || return 1
    [[ "$output" == *"RC=0"* ]] || return 1
}

@test "mail dir sizing signal (130) still cancels the run" {
    mkdir -p "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_path_size_kb() { return 130; }
_clean_mail_downloads
echo "RC=$?"
EOF

    [ "$status" -eq 130 ] || return 1
    [[ "$output" != *"skipped (sizing unavailable)"* ]] || return 1
}

@test "mo clean completes when the Mail Downloads du stalls (#1344)" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/integration.XXXXXX")
    mkdir -p "$fixture_home/Library/Caches"
    mkdir -p "$fixture_home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    echo x > "$fixture_home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/old.docx"

    SHIM_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/mail-shim.XXXXXX")"
    cat > "$SHIM_DIR/du" << 'SHIM'
#!/bin/bash
for a in "$@"; do
    if [[ "$a" == *"Mail Downloads"* ]]; then
        printf 'MAIL_DU\n' >> "$HOME/mail-du.trace"
        /bin/sleep 60
        exit 124
    fi
done
exec /usr/bin/du "$@"
SHIM
    chmod +x "$SHIM_DIR/du"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$SHIM_DIR:$PATH" MOLE_TIMEOUT_DISK_VERIFY_SEC=2 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
# The scenario requires Mail to be idle, regardless of the host's apps.
pgrep() { return 1; }
# Stub every other section so the run reaches the summary quickly; only
# clean_user_essentials (which contains _clean_mail_downloads) stays real.
for fn in clean_finder_metadata clean_app_caches clean_browsers \
    run_cloud_and_office_cleanup clean_developer_tools \
    clean_user_gui_applications clean_virtualization_tools \
    clean_application_support_logs clean_orphaned_app_data \
    clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice \
    clean_apple_silicon_caches clean_cached_device_firmware \
    clean_time_machine_failed_backups check_large_file_candidates \
    show_project_artifact_hint_notice; do
    eval "$fn() { return 0; }"
done
perform_cleanup
EOF

    rm -rf "$SHIM_DIR"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Cleanup complete"* ]] || return 1
    [[ "$output" == *"Mail Downloads · skipped (sizing unavailable)"* ]] || return 1
    [[ -s "$fixture_home/mail-du.trace" ]] || return 1
    [[ -f "$fixture_home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/old.docx" ]] || return 1
}

@test "mail dir sizing hard failure (1) skips the target and keeps the run going (#1366)" {
    # On Intel with macOS 26 the protected Mail container refuses du
    # outright: rc=1 immediately, no timeout. That must skip exactly like
    # the 124 case instead of cancelling the whole run.
    mkdir -p "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_path_size_kb() { return 1; }
_clean_mail_downloads
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Mail Downloads · skipped (sizing unavailable)"* ]] || return 1
    [[ "$output" == *"RC=0"* ]] || return 1
}

@test "mail attachment cleanup takes only copies nobody touched since Mail made them" {
    local root="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    # Untouched month-old opening: the positive control.
    mail_copy "$root/UNTOUCHED" invoice.pdf 202401010000
    # Saved over after Mail wrote it: the modification time moved past creation.
    mail_copy "$root/EDITED" contract.docx 202401010000
    touch -t 202401200000 "$root/EDITED/contract.docx"
    # A Save As beside the copy: born later, and it moved the folder's time.
    mail_copy "$root/BESIDE" sheet.xlsx 202401010000
    echo y > "$root/BESIDE/sheet-final.xlsx"
    touch -t 202401050000 "$root/BESIDE/sheet-final.xlsx"
    touch -t 202401050000 "$root/BESIDE"
    # Opened yesterday: inside the age window.
    mkdir -p "$root/RECENT"
    echo x > "$root/RECENT/photo.jpg"
    # A file loose in the root is not one opening's copy.
    echo x > "$root/loose.pdf"
    touch -t 202401010000 "$root/loose.pdf"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_path_size_kb() { echo 6000; }
safe_remove() {
    echo "REMOVE:${1#"$HOME"/}"
    # The sink asks the same question again before anything is removed.
    "$_MOLE_SAFE_REMOVE_FINAL_GUARD" "$1" && echo "SINK_OK:${1##*/}"
    return 0
}
_clean_mail_downloads
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"REMOVE:Library/Containers/com.apple.mail/Data/Library/Mail Downloads/UNTOUCHED/invoice.pdf"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SINK_OK:invoice.pdf"* ]] || return 1
    [[ "$(grep -c 'REMOVE:' <<< "$output")" -eq 1 ]] || { echo "$output"; return 1; }
}

@test "mail attachment sink guard refuses a copy edited after the scan" {
    local root="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    mail_copy "$root/LATE" notes.pages 202401010000

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
root="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
_mail_attachment_is_untouched_copy "$root/LATE/notes.pages" "$root" 30 && echo "BEFORE_OK"
touch -t 202402010000 "$root/LATE/notes.pages"
if _mail_attachment_is_untouched_copy "$root/LATE/notes.pages" "$root" 30; then
    echo "AFTER_OK"
fi
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"BEFORE_OK"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"AFTER_OK"* ]]
}

@test "mail attachment cleanup keeps a copy edited between the scan and the real sink" {
    # The legacy root: the container copy is a com.apple.* container, which
    # should_protect_path keeps whole, so only this root reaches the sink.
    local root="$HOME/Library/Mail Downloads"
    mail_copy "$root/EDIT" notes.pages 202401010000
    mail_copy "$root/IDLE" old.pdf 202401010000

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
export MOLE_CURRENT_COMMAND=clean
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
_mail_process_state() { return 1; }
# The folder clears the 5 MB gate; sizing the file is the moment someone
# saves an edit, after the scan accepted it and before the real sink.
get_path_size_kb() {
    case "$1" in
        */EDIT/notes.pages) touch "$1"; echo 1 ;;
        */Mail\ Downloads) echo 99999 ;;
        *) echo 1 ;;
    esac
}
_clean_mail_downloads
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$root/EDIT/notes.pages" ]] || { echo "$output"; return 1; }
    [[ ! -e "$root/IDLE/old.pdf" ]] || { echo "$output"; return 1; }
    local oplog="$HOME/Library/Logs/mole/operations.log"
    grep -Fq "SKIPPED $root/EDIT/notes.pages (sink guard denied)" "$oplog" || { cat "$oplog"; return 1; }
}
