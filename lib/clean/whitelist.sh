#!/bin/bash
# Mole CLI (Linux) - clean's whitelist: rules the user keeps.
#
# $XDG_CONFIG_HOME/mole/whitelist, one entry per line, # for comments:
#   a rule's label exactly as clean prints it ("Chromium profile caches",
#   "Trash"), which is what `mo clean --whitelist` writes, or
#   a path or glob starting with / or ~ that keeps every rule whose folder is
#   that path, sits below it, or matches the glob (Mole CLI (macOS)'s file
#   takes paths the same way).
# Whitelisted rules are skipped and shown as such, in dry runs too.

MOLE_WHITELIST_FILE="$MOLE_CONFIG_HOME/mole/whitelist"
MOLE_WHITELIST=()

# Load the file. Returns 1 when it exists but cannot be read, so a caller never
# cleans (or saves over) a whitelist it could not see.
mole_whitelist_load() {
    MOLE_WHITELIST=()
    [[ -e "$MOLE_WHITELIST_FILE" ]] || return 0
    [[ -f "$MOLE_WHITELIST_FILE" && -r "$MOLE_WHITELIST_FILE" ]] || return 1
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        MOLE_WHITELIST+=("$line")
    done < "$MOLE_WHITELIST_FILE"
    return 0
}

# 0 when the rule (label, folder) is whitelisted.
mole_whitelisted() {
    local label="$1" root="${2:-}" entry pattern
    [[ ${#MOLE_WHITELIST[@]} -gt 0 ]] || return 1
    for entry in "${MOLE_WHITELIST[@]}"; do
        case "$entry" in
            \~ | \~/* | /*)
                [[ -n "$root" ]] || continue
                pattern="$entry"
                [[ "$pattern" == "~"* ]] && pattern="$HOME${pattern#\~}"
                pattern="${pattern%/}"
                [[ -n "$pattern" ]] || continue
                # shellcheck disable=SC2053  # The pattern is a glob on purpose.
                if [[ "$root" == "$pattern" || "$root" == "$pattern/"* || "$root" == $pattern ]]; then
                    return 0
                fi
                ;;
            *) [[ "$entry" == "$label" ]] && return 0 ;;
        esac
    done
    return 1
}

# Labels the menu offers: every rule on this machine, once, then Trash.
mole_whitelist_labels() {
    local section label root owners selector seen=$'\n'
    while IFS='|' read -r section label root owners selector; do
        [[ -n "$label" ]] || continue
        [[ "$seen" == *$'\n'"$label"$'\n'* ]] && continue
        seen+="$label"$'\n'
        printf '%s\n' "$label"
    done < <(mole_clean_rules)
    printf '%s\n' "Trash"
}

mole_whitelist_save() {
    local dir tmp entry
    dir=$(dirname -- "$MOLE_WHITELIST_FILE")
    mkdir -p -- "$dir" || return 1
    tmp=$(mktemp "$dir/.whitelist.XXXXXX") || return 1
    {
        echo "# Mole whitelist: rules listed here are never cleaned."
        echo "# One rule label per line, or a path or glob starting with / or ~."
        for entry in "$@"; do printf '%s\n' "$entry"; done
    } > "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$MOLE_WHITELIST_FILE" || {
        rm -f -- "$tmp"
        return 1
    }
}

manage_whitelist() {
    local display
    display=$(mole_display_path "$MOLE_WHITELIST_FILE")
    if ! mole_whitelist_load; then
        echo "Cannot read $display; fix or remove it first." >&2
        return 1
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "mo clean --whitelist needs a terminal. Edit $display instead." >&2
        return 1
    fi

    local -a labels=() custom=() selected_first=() rest=()
    local label entry known
    while IFS= read -r label; do labels+=("$label"); done < <(mole_whitelist_labels)
    # Entries that are not a label offered here (paths, rules for apps not
    # installed now) stay in the file as they are.
    for entry in "${MOLE_WHITELIST[@]}"; do
        known=false
        for label in "${labels[@]}"; do
            [[ "$entry" == "$label" ]] && known=true && break
        done
        [[ "$known" == false ]] && custom+=("$entry")
    done
    for label in "${labels[@]}"; do
        if mole_whitelisted "$label"; then
            selected_first+=("$label")
        else
            rest+=("$label")
        fi
    done
    local -a items=()
    [[ ${#selected_first[@]} -gt 0 ]] && items+=("${selected_first[@]}")
    [[ ${#rest[@]} -gt 0 ]] && items+=("${rest[@]}")
    if [[ ${#selected_first[@]} -gt 0 ]]; then
        local -a pre=()
        local i
        for ((i = 0; i < ${#selected_first[@]}; i++)); do pre+=("$i"); done
        local IFS=','
        export MOLE_PRESELECTED_INDICES="${pre[*]}"
        unset IFS
    else
        unset MOLE_PRESELECTED_INDICES
    fi

    MOLE_SELECTION_RESULT=""
    local rc=0
    _MOLE_MENU_KEEP_EMPTY=true paginated_multi_select "Whitelist, select what clean keeps
${GRAY}Edit: ${display}, a path added there is kept too${NC}" "${items[@]}" || rc=$?
    unset MOLE_PRESELECTED_INDICES
    if [[ $rc -ne 0 ]]; then
        echo -e "${GRAY}Cancelled, no changes saved${NC}"
        return 0
    fi

    local -a chosen=() indices=()
    local idx
    if [[ -n "$MOLE_SELECTION_RESULT" ]]; then
        IFS=',' read -ra indices <<< "$MOLE_SELECTION_RESULT"
        for idx in "${indices[@]}"; do
            [[ "$idx" =~ ^[0-9]+$ && $idx -lt ${#items[@]} ]] && chosen+=("${items[idx]}")
        done
    fi
    local -a all=()
    [[ ${#chosen[@]} -gt 0 ]] && all+=("${chosen[@]}")
    [[ ${#custom[@]} -gt 0 ]] && all+=("${custom[@]}")
    if ! mole_whitelist_save ${all[@]+"${all[@]}"}; then
        echo "Could not write $display" >&2
        return 1
    fi
    local summary="Keeping $(mole_count_label "${#chosen[@]}" rule)"
    [[ ${#custom[@]} -gt 0 ]] && summary+=" + $(mole_count_label "${#custom[@]}" "custom entry" "custom entries")"
    print_summary_block "Whitelist updated" "$summary" "Config: ${GRAY}${display}${NC}"
}
