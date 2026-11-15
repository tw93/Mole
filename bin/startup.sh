#!/bin/bash
# Mole CLI (Linux) - startup: the apps that start at login. XDG autostart
# entries (the user's and the system's, as GNOME's Startup Applications lists
# them) and the systemd user services the user installed in their own config.
# Turning one off never deletes anything: a system entry gets a user copy with
# Hidden=true, the override the autostart spec defines, and a service is
# disabled with systemctl --user, so turning it back on restores it exactly.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
mole_refuse_root

startup_help() {
    echo "Usage: mo startup [OPTIONS] [enable|disable <id>]"
    echo ""
    echo "List apps and user services that start at login, and turn them on or off."
    echo ""
    echo "  mo startup                     List startup items"
    echo "  mo startup disable <id>        Stop an item from starting at login"
    echo "  mo startup enable <id>         Start it at login again"
    echo ""
    echo "Options:"
    echo "  --json            Output the list as JSON"
    echo "  --dry-run, -n     Show what enable or disable would change"
    echo "  -h, --help        Show this help message"
}

STARTUP_JSON=false
ACTION=""
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) STARTUP_JSON=true ;;
        --dry-run | -n) DRY_RUN=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            startup_help
            exit 0
            ;;
        enable | disable)
            ACTION="$1"
            TARGET="${2:-}"
            [[ -n "$TARGET" ]] || {
                echo "mo startup $1 needs an id; mo startup lists them." >&2
                exit 1
            }
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use 'mo startup --help' for supported options." >&2
            exit 1
            ;;
    esac
    shift
done
export DRY_RUN

STARTUP_USER_DIR="$MOLE_CONFIG_HOME/autostart"
STARTUP_UNIT_DIR="$MOLE_CONFIG_HOME/systemd/user"
# The system autostart folders, most important first, from XDG_CONFIG_DIRS.
STARTUP_SYSTEM_DIRS=()
IFS=':' read -ra _dirs <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
for _d in "${_dirs[@]}"; do
    [[ "$_d" == /* ]] && STARTUP_SYSTEM_DIRS+=("${_d%/}/autostart")
done
unset _dirs _d

# Print KEY<tab>value for the keys startup reads from the [Desktop Entry]
# group; localized keys (Name[de]) and other groups are ignored.
desktop_keys() {
    awk -F= '
        /^\[/ { group = $0; next }
        group != "[Desktop Entry]" { next }
        /^(Name|Exec|Hidden|NoDisplay|X-GNOME-Autostart-enabled|OnlyShowIn|NotShowIn)=/ {
            key = $1; sub(/^[^=]*=/, ""); if (!(key in seen)) { seen[key] = 1; print key "\t" $0 }
        }' "$1" 2> /dev/null
}

# 0 when the entry runs in this desktop session (OnlyShowIn / NotShowIn).
desktop_shown_here() {
    local only="$1" not="$2" d
    local -a current=()
    IFS=':' read -ra current <<< "${XDG_CURRENT_DESKTOP:-}"
    if [[ -n "$only" ]]; then
        for d in "${current[@]}"; do [[ ";$only;" == *";$d;"* ]] && return 0; done
        return 1
    fi
    for d in "${current[@]}"; do [[ ";$not;" == *";$d;"* ]] && return 1; done
    return 0
}

# Fill ITEM_* with one row per startup item.
ITEM_ID=()
ITEM_KIND=()
ITEM_NAME=()
ITEM_ENABLED=()
ITEM_SOURCE=()
ITEM_EXEC=()
load_items() {
    local -A seen=()
    local dir file id key value name exec hidden nodisplay gnome only not source
    for dir in "$STARTUP_USER_DIR" "${STARTUP_SYSTEM_DIRS[@]}"; do
        for file in "$dir"/*.desktop; do
            [[ -f "$file" ]] || continue
            id="${file##*/}"
            [[ -z "${seen[$id]:-}" ]] || continue
            seen[$id]=1
            name="" exec="" hidden="" nodisplay="" gnome="" only="" not=""
            while IFS=$'\t' read -r key value; do
                case "$key" in
                    Name) name="$value" ;;
                    Exec) exec="$value" ;;
                    Hidden) hidden="$value" ;;
                    NoDisplay) nodisplay="$value" ;;
                    X-GNOME-Autostart-enabled) gnome="$value" ;;
                    OnlyShowIn) only="$value" ;;
                    NotShowIn) not="$value" ;;
                esac
            done < <(desktop_keys "$file")
            # Startup Applications hides these too: session plumbing.
            [[ "$nodisplay" == true ]] && continue
            desktop_shown_here "$only" "$not" || continue
            source=system
            [[ "$dir" == "$STARTUP_USER_DIR" ]] && source=user
            [[ "$source" == user ]] && system_entry "$id" > /dev/null && source=override
            ITEM_ID+=("$id")
            ITEM_KIND+=(autostart)
            ITEM_NAME+=("${name:-${id%.desktop}}")
            if [[ "$hidden" == true || "$gnome" == false ]]; then
                ITEM_ENABLED+=(false)
            else
                ITEM_ENABLED+=(true)
            fi
            ITEM_SOURCE+=("$source")
            ITEM_EXEC+=("$exec")
        done
    done
    local unit state
    [[ -d "$STARTUP_UNIT_DIR" ]] || return 0
    command -v systemctl > /dev/null 2>&1 || return 0
    for file in "$STARTUP_UNIT_DIR"/*.service; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        unit="${file##*/}"
        [[ "$unit" == *@.service ]] && continue
        state=$(mole_c systemctl --user is-enabled -- "$unit" 2> /dev/null) || true
        # No user bus or no systemd: the state is unknown, so no switch is shown.
        [[ "$state" == enabled || "$state" == disabled ]] || continue
        exec=$(awk -F= '/^ExecStart=/ { sub(/^ExecStart=/, ""); print; exit }' "$file" 2> /dev/null) || exec=""
        ITEM_ID+=("$unit")
        ITEM_KIND+=(service)
        ITEM_NAME+=("${unit%.service}")
        if [[ "$state" == enabled ]]; then ITEM_ENABLED+=(true); else ITEM_ENABLED+=(false); fi
        ITEM_SOURCE+=(user)
        ITEM_EXEC+=("$exec")
    done
}

# The system entry the user file of the same name overrides, if any.
system_entry() {
    local dir
    for dir in "${STARTUP_SYSTEM_DIRS[@]}"; do
        [[ -f "$dir/$1" ]] && {
            printf '%s' "$dir/$1"
            return 0
        }
    done
    return 1
}

print_list() {
    local i
    if [[ "$STARTUP_JSON" == true ]]; then
        local sep=""
        printf '['
        for i in "${!ITEM_ID[@]}"; do
            printf '%s\n  {"id": %s, "kind": %s, "name": %s, "enabled": %s, "source": %s, "exec": %s}' "$sep" \
                "$(json_string "${ITEM_ID[i]}")" "$(json_string "${ITEM_KIND[i]}")" "$(json_string "${ITEM_NAME[i]}")" \
                "${ITEM_ENABLED[i]}" "$(json_string "${ITEM_SOURCE[i]}")" "$(json_string "${ITEM_EXEC[i]}")"
            sep=","
        done
        printf '\n]\n'
        return
    fi
    echo -e "${PURPLE_BOLD}Startup Apps${NC}"
    if [[ ${#ITEM_ID[@]} -eq 0 ]]; then
        echo -e "  ${GRAY}${ICON_EMPTY} Nothing starts at login${NC}"
        return
    fi
    local mark
    for i in "${!ITEM_ID[@]}"; do
        if [[ "${ITEM_ENABLED[i]}" == true ]]; then
            mark="${GREEN}${ICON_SOLID}${NC}"
        else
            mark="${GRAY}${ICON_EMPTY}${NC}"
        fi
        printf '  %b %-32s %s\n' "$mark" "$(truncate_by_display_width "${ITEM_NAME[i]}" 32)" "${GRAY}${ITEM_ID[i]}${NC}"
    done
    echo ""
    echo -e "${GRAY}${ICON_SOLID} starts at login · mo startup disable <id> · mo startup enable <id>${NC}"
}

# Write KEY=value pairs into the [Desktop Entry] group of a copy of src and
# move it over dst in one rename, so the file is never half written.
desktop_set() {
    local src="$1" dst="$2"
    shift 2
    local tmp
    tmp=$(mktemp "${dst%/*}/.mole-startup.XXXXXX") || return 1
    if ! awk -v pairs="$*" '
        BEGIN { n = split(pairs, kv, " "); for (i = 1; i <= n; i++) { split(kv[i], p, "="); want[p[1]] = p[2]; order[i] = p[1] } }
        function flush() { for (i = 1; i <= n; i++) if (!(order[i] in done)) print order[i] "=" want[order[i]]; flushed = 1 }
        /^\[/ { if (group == "[Desktop Entry]" && !flushed) flush(); group = $0; print; next }
        group == "[Desktop Entry]" {
            key = $0; sub(/=.*/, "", key)
            if (key in want) { if (!(key in done)) { print key "=" want[key]; done[key] = 1 } next }
        }
        { print }
        END { if (group == "[Desktop Entry]" && !flushed) flush() }' "$src" > "$tmp"; then
        rm -f -- "$tmp" # SAFE: Mole's own mktemp file in the autostart folder.
        return 1
    fi
    chmod 644 -- "$tmp" 2> /dev/null || true
    mv -f -- "$tmp" "$dst"
}

set_item() {
    local want="$1" id="$2" i kind=""
    for i in "${!ITEM_ID[@]}"; do
        [[ "${ITEM_ID[i]}" == "$id" ]] && kind="${ITEM_KIND[i]}" && break
    done
    if [[ -z "$kind" ]]; then
        log_error "No startup item named \"$id\". Run mo startup to see the ids."
        return 1
    fi
    local verb=enabled
    [[ "$want" == false ]] && verb=disabled
    if [[ "${ITEM_ENABLED[i]}" == "$want" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${ITEM_NAME[i]} is already ${verb/abled/abled at login}"
        return 0
    fi
    if [[ "$kind" == service ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Would run systemctl --user ${ACTION} $id"
            return 0
        fi
        # Only at login: a service running now keeps running until it stops.
        if ! mole_c systemctl --user "$ACTION" -- "$id" > /dev/null 2>&1; then
            log_error "systemctl --user $ACTION $id failed"
            log_operation startup FAILED "$STARTUP_UNIT_DIR/$id" "systemctl $ACTION"
            return 1
        fi
        log_operation startup REBUILT "$STARTUP_UNIT_DIR/$id" "$verb at login"
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${ITEM_NAME[i]} ${verb/abled/abled at login}"
        return 0
    fi
    local dst="$STARTUP_USER_DIR/$id" src
    if [[ -L "$dst" ]]; then
        log_error "$(mole_display_path "$dst") is a link; edit its target instead."
        return 1
    fi
    if [[ -f "$dst" ]]; then
        src="$dst"
    else
        src=$(system_entry "$id") || {
            log_error "Cannot find the entry for $id"
            return 1
        }
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Would write Hidden=$([[ $want == true ]] && echo false || echo true) to $(mole_display_path "$dst")"
        return 0
    fi
    mkdir -p -- "$STARTUP_USER_DIR"
    local hidden=true gnome=false
    [[ "$want" == true ]] && hidden=false gnome=true
    if ! desktop_set "$src" "$dst" "Hidden=$hidden" "X-GNOME-Autostart-enabled=$gnome"; then
        log_error "Could not write $(mole_display_path "$dst")"
        log_operation startup FAILED "$dst" "autostart $verb"
        return 1
    fi
    log_operation startup REBUILT "$dst" "$verb at login"
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${ITEM_NAME[i]} ${verb/abled/abled at login}"
}

main() {
    load_items
    case "$ACTION" in
        enable) set_item true "$TARGET" ;;
        disable) set_item false "$TARGET" ;;
        *) print_list ;;
    esac
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
