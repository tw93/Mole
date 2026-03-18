#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-whitelist-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "$HOME/.config"
    mkdir -p "$HOME"
    WHITELIST_PATH="$HOME/.config/mole/whitelist"
}

@test "patterns_equivalent treats paths with tilde expansion as equal" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; patterns_equivalent '~/.cache/test' \"\$HOME/.cache/test\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]
}

@test "patterns_equivalent distinguishes different paths" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; patterns_equivalent '~/.cache/test' \"\$HOME/.cache/other\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -ne 0 ]
}

@test "save_whitelist_patterns keeps unique entries and preserves header" {
    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; save_whitelist_patterns \"\$HOME/.cache/foo\" \"\$HOME/.cache/foo\" \"\$HOME/.cache/bar\""

    [[ -f "$WHITELIST_PATH" ]]

    lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < "$WHITELIST_PATH"
    [ "${#lines[@]}" -ge 4 ]
    occurrences=$(grep -c "$HOME/.cache/foo" "$WHITELIST_PATH")
    [ "$occurrences" -eq 1 ]
}

@test "load_whitelist falls back to defaults when config missing" {
    rm -f "$WHITELIST_PATH"
    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; rm -f \"\$HOME/.config/mole/whitelist\"; load_whitelist; printf '%s\n' \"\${CURRENT_WHITELIST_PATTERNS[@]}\"" > "$HOME/current_whitelist.txt"
    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; printf '%s\n' \"\${DEFAULT_WHITELIST_PATTERNS[@]}\"" > "$HOME/default_whitelist.txt"

    current=()
    while IFS= read -r line; do
        current+=("$line")
    done < "$HOME/current_whitelist.txt"

    defaults=()
    while IFS= read -r line; do
        defaults+=("$line")
    done < "$HOME/default_whitelist.txt"

    [ "${#current[@]}" -eq "${#defaults[@]}" ]
    [ "${current[0]}" = "${defaults[0]/\$HOME/$HOME}" ]
}

@test "is_whitelisted matches saved patterns exactly" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; save_whitelist_patterns \"\$HOME/.cache/unique-pattern\"; load_whitelist; is_whitelisted \"\$HOME/.cache/unique-pattern\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]

    if HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; save_whitelist_patterns \"\$HOME/.cache/unique-pattern\"; load_whitelist; is_whitelisted \"\$HOME/.cache/other-pattern\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -ne 0 ]
}

@test "mo clean --whitelist persists selections" {
    whitelist_file="$HOME/.config/mole/whitelist"
    mkdir -p "$(dirname "$whitelist_file")"

    run bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    first_pattern=$(grep -v '^[[:space:]]*#' "$whitelist_file" | grep -v '^[[:space:]]*$' | head -n 1)
    [ -n "$first_pattern" ]

    run bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$' \\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    run grep -Fxq "$first_pattern" "$whitelist_file"
    [ "$status" -eq 1 ]

    run bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    run grep -Fxq "$first_pattern" "$whitelist_file"
    [ "$status" -eq 1 ]
}

@test "is_path_whitelisted protects parent directories of whitelisted nested paths" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        source '$PROJECT_ROOT/lib/core/app_protection.sh'
        WHITELIST_PATTERNS=(\"\$HOME/Library/Caches/org.R-project.R/R/renv\")
        is_path_whitelisted \"\$HOME/Library/Caches/org.R-project.R\"
    "; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]
}

@test "default whitelist protects tealdeer cache parent for tldr pages" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/manage/whitelist.sh'
        rm -f \"\$HOME/.config/mole/whitelist\"
        load_whitelist
        WHITELIST_PATTERNS=(\"\${CURRENT_WHITELIST_PATTERNS[@]}\")
        is_path_whitelisted \"\$HOME/Library/Caches/tealdeer\"
    "; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]
}
