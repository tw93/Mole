#!/bin/bash

# Shared command list for help text and completions.
MOLE_COMMANDS=(
    "clean:Free up disk space"
    "uninstall:Remove apps completely"
    "optimize:Refresh caches and services"
    "analyze:Explore disk usage"
    "status:Monitor system health"
    "history:Review cleanup activity"
    "purge:Remove old project artifacts"
    "installer:Find and remove installer files"
    "touchid:Configure Touch ID for sudo"
    "completion:Setup shell tab completion"
    "update:Update to latest version"
    "remove:Remove Mole from system"
    "help:Show help"
    "version:Show version"
)

# Levenshtein distance between two strings. Bash 3.2 ships with no associative
# arrays, so the matrix is kept as two indexed rows and rebuilt per character.
# Callers must bound the inputs: this is O(len(a) * len(b)) shell arithmetic.
_mole_edit_distance() {
    local a="$1" b="$2"
    local alen=${#a} blen=${#b}

    if [[ $alen -eq 0 ]]; then
        printf '%s' "$blen"
        return 0
    fi
    if [[ $blen -eq 0 ]]; then
        printf '%s' "$alen"
        return 0
    fi

    local -a prev=() cur=()
    local i j
    for ((j = 0; j <= blen; j++)); do
        prev[j]=$j
    done

    for ((i = 1; i <= alen; i++)); do
        cur=("$i")
        local ac="${a:i-1:1}"
        for ((j = 1; j <= blen; j++)); do
            local bc="${b:j-1:1}"
            local cost=1
            [[ "$ac" == "$bc" ]] && cost=0

            local del=$((prev[j] + 1))
            local ins=$((cur[j - 1] + 1))
            local sub=$((prev[j - 1] + cost))

            local best=$del
            [[ $ins -lt $best ]] && best=$ins
            [[ $sub -lt $best ]] && best=$sub
            cur[j]=$best
        done
        prev=("${cur[@]}")
    done

    printf '%s' "${prev[blen]}"
}

# Closest public command to a mistyped one, or nothing when no candidate is
# near enough. Prints the name only, so the caller decides the wording.
mole_suggest_command() {
    local input="$1"
    [[ -n "$input" ]] || return 0

    # Commands are lowercase ASCII; fold the input so `mo CLEAN` still matches.
    input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

    # A short typo tolerates fewer edits: at distance 2, "mo rm" is as close to
    # "remove" as it is to nothing in particular, and a wrong guess is worse
    # than none on a tool that deletes files.
    local max_distance=2
    [[ ${#input} -le 3 ]] && max_distance=1

    local best="" best_distance=$((max_distance + 1))
    local entry name distance
    for entry in "${MOLE_COMMANDS[@]}"; do
        name="${entry%%:*}"

        # An abbreviation the user clearly meant, such as `mo unins`, sits far
        # away by edit distance but is unambiguous as a prefix.
        if [[ ${#input} -ge 3 && "$name" == "$input"* ]]; then
            printf '%s' "$name"
            return 0
        fi

        distance="$(_mole_edit_distance "$input" "$name")"
        if [[ $distance -lt $best_distance ]]; then
            best_distance=$distance
            best="$name"
        fi
    done

    [[ $best_distance -le $max_distance ]] && printf '%s' "$best"
    return 0
}
