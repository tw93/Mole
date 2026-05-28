#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOMY_UNSAFE_RM_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"

files=()
for file in roomy install.sh; do
    [[ -f "$file" ]] && files+=("$file")
done
for dir in bin lib scripts; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$dir" -type f -name '*.sh' ! -name 'check-unsafe-rm.sh' | sort)
done

if [[ ${#files[@]} -eq 0 ]]; then
    printf 'No unsafe deletion usage found.\n'
    exit 0
fi

unsafe_delete_patterns=(
    '(^|[^[:alnum:]_-])([^[:space:]]*/)?rm[[:space:]]+(-[^[:space:]]*[rR][^[:space:]]*[fF]|-[^[:space:]]*[fF][^[:space:]]*[rR]|-[rR][[:space:]]+-[fF]|-[fF][[:space:]]+-[rR])([^[:alnum:]_-]|$)'
    '(^|[^[:alnum:]_-])find[[:space:]].*[[:space:]]-delete([^[:alnum:]_-]|$)'
    '(^|[^[:alnum:]_-])find[[:space:]].*[[:space:]]-exec[[:space:]]+([^[:space:]]*/)?rm([[:space:]]|$)'
    '(^|[^[:alnum:]_-])xargs([[:space:]][^;&|]*)?[[:space:]]+([^[:space:]]*/)?rm([[:space:]]|$)'
)
matches=""
for pattern in "${unsafe_delete_patterns[@]}"; do
    pattern_matches=$(grep -En -- "$pattern" "${files[@]}" 2> /dev/null || true)
    [[ -n "$pattern_matches" ]] || continue
    matches+="${pattern_matches}"$'\n'
done
failures=()

while IFS= read -r match; do
    [[ -n "$match" ]] || continue

    location="${match%%:*}"
    rest="${match#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"
    trimmed="${text#"${text%%[![:space:]]*}"}"

    case "$trimmed" in
        \#*)
            continue
            ;;
    esac
    if [[ "$trimmed" == echo\ * || "$trimmed" == printf\ * ]] && [[ "$text" != *"| xargs"* && "$text" != *"|xargs"* ]]; then
        continue
    fi

    if [[ "$text" == *"# SAFE:"* || "$text" == *"safe_remove"* || "$text" == *"validate_path"* ]]; then
        continue
    fi

    failures+=("${location}:${line}:${text}")
done <<< "$matches"

if [[ ${#failures[@]} -gt 0 ]]; then
    printf 'Unsafe deletion usage found. Route through safe_remove or annotate narrowly with # SAFE: <reason>.\n' >&2
    printf '%s\n' "${failures[@]}" >&2
    exit 1
fi

printf 'No unsafe deletion usage found.\n'
