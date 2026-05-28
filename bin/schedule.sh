#!/bin/bash
# Roomy - user launchd scheduling for recurring maintenance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/common.sh
source "$PROJECT_ROOT/lib/core/common.sh"

ROOMY_CONFIG_DIR="${ROOMY_CONFIG_DIR:-$HOME/.config/roomy}"
ROOMY_SCHEDULE_LABEL="${ROOMY_SCHEDULE_LABEL:-com.roomy.maintenance}"
ROOMY_LAUNCH_AGENTS_DIR="${ROOMY_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
ROOMY_SCHEDULE_PLIST="${ROOMY_SCHEDULE_PLIST:-$ROOMY_LAUNCH_AGENTS_DIR/$ROOMY_SCHEDULE_LABEL.plist}"
ROOMY_SCHEDULE_CONFIG="${ROOMY_SCHEDULE_CONFIG:-$ROOMY_CONFIG_DIR/schedule.conf}"

show_schedule_help() {
    cat << EOF
Usage: roomy schedule <command> [OPTIONS]

Automate recurring Roomy maintenance with a user LaunchAgent.

Commands:
  status                 Show configured schedule
  enable                 Create or update the schedule
  disable                Remove the schedule
  run                    Run the configured maintenance command now

Enable options:
  --daily                Run every day
  --weekly               Run weekly (default)
  --monthly              Run monthly on day 1
  --time HH:MM           Run time, 24-hour clock (default: 03:00)
  --command NAME         clean, purge, or installer (default: clean)
  --execute              Run the command for real; default is dry-run preview
  --dry-run              Preview schedule changes without writing files
  -h, --help             Show this help message
EOF
}

schedule_escape_xml() {
    local value="${1:-}"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    printf '%s' "$value"
}

schedule_resolve_roomy() {
    if [[ -x "$PROJECT_ROOT/roomy" ]]; then
        printf '%s\n' "$PROJECT_ROOT/roomy"
    elif command -v roomy > /dev/null 2>&1; then
        command -v roomy
    else
        printf '%s\n' "$PROJECT_ROOT/roomy"
    fi
}

schedule_parse_time() {
    local raw="$1"
    if [[ ! "$raw" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        echo "Invalid time: $raw" >&2
        return 1
    fi
    local hour="${BASH_REMATCH[1]}"
    local minute="${BASH_REMATCH[2]}"
    local hour_num minute_num
    hour_num=$((10#$hour))
    minute_num=$((10#$minute))
    if ((hour_num > 23 || minute_num > 59)); then
        echo "Invalid time: $raw" >&2
        return 1
    fi
    printf '%d %d\n' "$hour_num" "$minute_num"
}

schedule_validate_command() {
    case "$1" in
        clean | purge | installer) return 0 ;;
        *)
            echo "Unsupported schedule command: $1" >&2
            echo "Use clean, purge, or installer." >&2
            return 1
            ;;
    esac
}

schedule_path_under_home() {
    local path="$1"
    local home_path="${HOME%/}"
    local physical_home physical_path

    [[ -n "$path" && "$path" == /* ]] || return 1
    [[ -n "$home_path" ]] || return 1
    case "$path" in
        "$home_path"/*) ;;
        *) return 1 ;;
    esac

    physical_home=$(cd -P "$home_path" 2> /dev/null && pwd) || return 1
    physical_path=$(roomy_physical_path_for_validation "$path" 2> /dev/null) || return 1
    case "$physical_path" in
        "$physical_home"/*) return 0 ;;
    esac
    return 1
}

schedule_validate_paths() {
    [[ -n "$ROOMY_SCHEDULE_LABEL" && "$ROOMY_SCHEDULE_LABEL" != */* && ! "$ROOMY_SCHEDULE_LABEL" =~ [[:cntrl:]] ]] || {
        echo "Invalid schedule label: $ROOMY_SCHEDULE_LABEL" >&2
        return 1
    }
    schedule_path_under_home "$ROOMY_LAUNCH_AGENTS_DIR" || {
        echo "Schedule LaunchAgents directory must be under HOME: $ROOMY_LAUNCH_AGENTS_DIR" >&2
        return 1
    }
    [[ ! -L "$ROOMY_LAUNCH_AGENTS_DIR" ]] || {
        echo "Schedule LaunchAgents directory must not be a symlink: $ROOMY_LAUNCH_AGENTS_DIR" >&2
        return 1
    }
    schedule_path_under_home "$ROOMY_CONFIG_DIR" || {
        echo "Schedule config directory must be under HOME: $ROOMY_CONFIG_DIR" >&2
        return 1
    }
    [[ ! -L "$ROOMY_CONFIG_DIR" ]] || {
        echo "Schedule config directory must not be a symlink: $ROOMY_CONFIG_DIR" >&2
        return 1
    }
    schedule_path_under_home "$ROOMY_SCHEDULE_PLIST" || {
        echo "Schedule plist path must be under HOME: $ROOMY_SCHEDULE_PLIST" >&2
        return 1
    }
    schedule_path_under_home "$ROOMY_SCHEDULE_CONFIG" || {
        echo "Schedule config path must be under HOME: $ROOMY_SCHEDULE_CONFIG" >&2
        return 1
    }
    [[ "$ROOMY_SCHEDULE_PLIST" == "$ROOMY_LAUNCH_AGENTS_DIR/$ROOMY_SCHEDULE_LABEL.plist" ]] || {
        echo "Schedule plist path does not match label and LaunchAgents directory" >&2
        return 1
    }
    [[ "$ROOMY_SCHEDULE_CONFIG" == "$ROOMY_CONFIG_DIR/schedule.conf" ]] || {
        echo "Schedule config path must be schedule.conf under the Roomy config directory" >&2
        return 1
    }
}

schedule_write_file_atomically() {
    local output="$1"
    local parent tmp_file

    parent=$(dirname "$output")
    ensure_user_dir "$parent"
    if [[ -e "$output" || -L "$output" ]]; then
        safe_remove "$output" true || return 1
    fi

    tmp_file=$(mktemp "$parent/.roomy-schedule.XXXXXX") || return 1
    if ! cat > "$tmp_file"; then
        safe_remove "$tmp_file" true || true
        return 1
    fi
    if ! mv -f "$tmp_file" "$output"; then
        safe_remove "$tmp_file" true || true
        return 1
    fi
}

schedule_write_config() {
    local cadence="$1"
    local time_value="$2"
    local command_name="$3"
    local execute="$4"

    {
        printf 'CADENCE=%s\n' "$cadence"
        printf 'TIME=%s\n' "$time_value"
        printf 'COMMAND=%s\n' "$command_name"
        printf 'EXECUTE=%s\n' "$execute"
        printf 'PLIST=%s\n' "$ROOMY_SCHEDULE_PLIST"
    } | schedule_write_file_atomically "$ROOMY_SCHEDULE_CONFIG"
}

schedule_load_config() {
    [[ -f "$ROOMY_SCHEDULE_CONFIG" ]] || return 1

    local loaded_cadence="" loaded_time="" loaded_command="" loaded_execute="" loaded_plist=""
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            CADENCE) loaded_cadence="$value" ;;
            TIME) loaded_time="$value" ;;
            COMMAND) loaded_command="$value" ;;
            EXECUTE) loaded_execute="$value" ;;
            PLIST) loaded_plist="$value" ;;
        esac
    done < "$ROOMY_SCHEDULE_CONFIG"

    case "$loaded_cadence" in
        daily | weekly | monthly) ;;
        *) return 1 ;;
    esac
    schedule_parse_time "$loaded_time" > /dev/null 2>&1 || return 1
    schedule_validate_command "$loaded_command" > /dev/null 2>&1 || return 1
    case "$loaded_execute" in
        true | false) ;;
        *) return 1 ;;
    esac

    CADENCE="$loaded_cadence"
    TIME="$loaded_time"
    COMMAND="$loaded_command"
    EXECUTE="$loaded_execute"
    PLIST="$loaded_plist"
}

schedule_write_plist() {
    local cadence="$1"
    local hour="$2"
    local minute="$3"
    local command_name="$4"
    local execute="$5"
    local roomy_path
    roomy_path=$(schedule_resolve_roomy)

    local stdout_path="$HOME/Library/Logs/roomy/schedule.log"
    local stderr_path="$HOME/Library/Logs/roomy/schedule.err.log"
    local dry_arg=""
    [[ "$execute" == "true" ]] || dry_arg="--dry-run"

    ensure_user_dir "$(dirname "$stdout_path")"

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">'
        printf '%s\n' '<dict>'
        printf '  <key>Label</key><string>%s</string>\n' "$(schedule_escape_xml "$ROOMY_SCHEDULE_LABEL")"
        printf '%s\n' '  <key>ProgramArguments</key>'
        printf '%s\n' '  <array>'
        printf '    <string>%s</string>\n' "$(schedule_escape_xml "$roomy_path")"
        printf '    <string>%s</string>\n' "$(schedule_escape_xml "$command_name")"
        if [[ -n "$dry_arg" ]]; then
            printf '    <string>%s</string>\n' "$dry_arg"
        elif [[ "$command_name" == "clean" ]]; then
            printf '%s\n' '    <string>--yes</string>'
            printf '%s\n' '    <string>--require-dry-run-age</string>'
            printf '%s\n' '    <string>168</string>'
        fi
        printf '%s\n' '  </array>'
        printf '%s\n' '  <key>StartCalendarInterval</key>'
        printf '%s\n' '  <dict>'
        if [[ "$cadence" == "weekly" ]]; then
            printf '%s\n' '    <key>Weekday</key><integer>1</integer>'
        elif [[ "$cadence" == "monthly" ]]; then
            printf '%s\n' '    <key>Day</key><integer>1</integer>'
        fi
        printf '    <key>Hour</key><integer>%s</integer>\n' "$hour"
        printf '    <key>Minute</key><integer>%s</integer>\n' "$minute"
        printf '%s\n' '  </dict>'
        printf '%s\n' '  <key>StandardOutPath</key>'
        printf '  <string>%s</string>\n' "$(schedule_escape_xml "$stdout_path")"
        printf '%s\n' '  <key>StandardErrorPath</key>'
        printf '  <string>%s</string>\n' "$(schedule_escape_xml "$stderr_path")"
        printf '%s\n' '</dict>'
        printf '%s\n' '</plist>'
    } | schedule_write_file_atomically "$ROOMY_SCHEDULE_PLIST"
}

schedule_launchctl_load() {
    command -v launchctl > /dev/null 2>&1 || return 0
    launchctl bootout "gui/$(id -u)" "$ROOMY_SCHEDULE_PLIST" > /dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$ROOMY_SCHEDULE_PLIST" > /dev/null 2>&1 ||
        launchctl load "$ROOMY_SCHEDULE_PLIST" > /dev/null 2>&1 || true
}

schedule_launchctl_unload() {
    command -v launchctl > /dev/null 2>&1 || return 0
    launchctl bootout "gui/$(id -u)" "$ROOMY_SCHEDULE_PLIST" > /dev/null 2>&1 ||
        launchctl unload "$ROOMY_SCHEDULE_PLIST" > /dev/null 2>&1 || true
}

schedule_status() {
    if [[ ! -f "$ROOMY_SCHEDULE_PLIST" ]]; then
        echo "Roomy schedule: disabled"
        return 0
    fi

    local cadence="${CADENCE:-unknown}"
    local time_value="${TIME:-unknown}"
    local command_name="${COMMAND:-unknown}"
    local execute="${EXECUTE:-false}"
    schedule_load_config || true
    cadence="${CADENCE:-$cadence}"
    time_value="${TIME:-$time_value}"
    command_name="${COMMAND:-$command_name}"
    execute="${EXECUTE:-$execute}"

    echo "Roomy schedule: enabled"
    echo "  Cadence: $cadence"
    echo "  Time: $time_value"
    echo "  Command: $command_name"
    if [[ "$execute" == "true" ]]; then
        echo "  Mode: execute"
    else
        echo "  Mode: dry-run preview"
    fi
    echo "  Plist: ${ROOMY_SCHEDULE_PLIST/#$HOME/~}"
}

schedule_enable() {
    local cadence="weekly"
    local time_value="03:00"
    local command_name="clean"
    local execute="false"
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --daily) cadence="daily" ;;
            --weekly) cadence="weekly" ;;
            --monthly) cadence="monthly" ;;
            --time)
                shift
                [[ $# -gt 0 ]] || {
                    echo "Missing value for --time" >&2
                    return 1
                }
                time_value="$1"
                ;;
            --command)
                shift
                [[ $# -gt 0 ]] || {
                    echo "Missing value for --command" >&2
                    return 1
                }
                command_name="$1"
                ;;
            --execute) execute="true" ;;
            --dry-run | -n) dry_run="true" ;;
            -h | --help)
                show_schedule_help
                return 0
                ;;
            *)
                echo "Unknown schedule enable option: $1" >&2
                return 1
                ;;
        esac
        shift
    done

    schedule_validate_command "$command_name" || return 1
    local parsed hour minute
    parsed=$(schedule_parse_time "$time_value") || return 1
    read -r hour minute <<< "$parsed"

    if [[ "$dry_run" == "true" ]]; then
        echo "Would enable Roomy schedule"
        echo "  Cadence: $cadence"
        echo "  Time: $time_value"
        echo "  Command: $command_name"
        [[ "$execute" == "true" ]] && echo "  Mode: execute" || echo "  Mode: dry-run preview"
        echo "  Plist: ${ROOMY_SCHEDULE_PLIST/#$HOME/~}"
        return 0
    fi

    schedule_write_plist "$cadence" "$hour" "$minute" "$command_name" "$execute"
    schedule_write_config "$cadence" "$time_value" "$command_name" "$execute"
    schedule_launchctl_load

    echo "Roomy schedule enabled"
    echo "  $cadence at $time_value: $command_name"
}

schedule_disable() {
    local dry_run="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run | -n) dry_run="true" ;;
            -h | --help)
                show_schedule_help
                return 0
                ;;
            *)
                echo "Unknown schedule disable option: $1" >&2
                return 1
                ;;
        esac
        shift
    done

    if [[ "$dry_run" == "true" ]]; then
        echo "Would disable Roomy schedule"
        echo "  Plist: ${ROOMY_SCHEDULE_PLIST/#$HOME/~}"
        return 0
    fi

    schedule_launchctl_unload
    if [[ -e "$ROOMY_SCHEDULE_PLIST" || -L "$ROOMY_SCHEDULE_PLIST" ]]; then
        safe_remove "$ROOMY_SCHEDULE_PLIST" true || true
    fi
    if [[ -e "$ROOMY_SCHEDULE_CONFIG" || -L "$ROOMY_SCHEDULE_CONFIG" ]]; then
        safe_remove "$ROOMY_SCHEDULE_CONFIG" true || true
    fi
    echo "Roomy schedule disabled"
}

schedule_run_now() {
    local command_name="clean"
    local execute="false"
    if schedule_load_config; then
        command_name="${COMMAND:-clean}"
        execute="${EXECUTE:-false}"
    fi

    local roomy_path
    roomy_path=$(schedule_resolve_roomy)
    if [[ "$execute" == "true" ]]; then
        exec "$roomy_path" "$command_name"
    fi
    exec "$roomy_path" "$command_name" --dry-run
}

main() {
    case "${1:-status}" in
        -h | --help | help)
            show_schedule_help
            return 0
            ;;
    esac

    schedule_validate_paths || exit 1

    case "${1:-status}" in
        status)
            shift || true
            [[ $# -eq 0 ]] || {
                echo "Usage: roomy schedule status" >&2
                exit 1
            }
            schedule_status
            ;;
        enable)
            shift
            schedule_enable "$@"
            ;;
        disable)
            shift
            schedule_disable "$@"
            ;;
        run)
            shift || true
            [[ $# -eq 0 ]] || {
                echo "Usage: roomy schedule run" >&2
                exit 1
            }
            schedule_run_now
            ;;
        *)
            echo "Unknown schedule command: $1" >&2
            show_schedule_help >&2
            exit 1
            ;;
    esac
}

main "$@"
