#!/bin/bash
# Fixture for tests/clean_apps.bats: one launchd plist whose program is gone,
# with the installed-app scan failing with SCAN_RC.
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }
should_protect_path() { return 1; }
scan_installed_apps() { return "${SCAN_RC:-1}"; }

tmp_dir="$(mktemp -d)"
stray="$tmp_dir/com.example.goneapp.status.agent.plist"
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-agent" "$stray" 2> /dev/null || true

sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then
        return 0
    fi
    [[ "${1:-}" == "-n" ]] && shift
    if [[ "$1" == "find" ]]; then
        case "$2" in
            /Library/LaunchDaemons) printf '%s\0' "$stray" ;;
            *) : ;;
        esac
        return 0
    fi
    command "$@"
}

clean_orphaned_system_services
