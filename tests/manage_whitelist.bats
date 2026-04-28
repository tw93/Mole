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

@test "mo clean --whitelist cancel preserves existing file (#807)" {
    whitelist_file="$HOME/.config/mole/whitelist"
    mkdir -p "$(dirname "$whitelist_file")"

    run bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    [[ -f "$whitelist_file" ]]
    before_hash=$(shasum "$whitelist_file" | awk '{print $1}')

    run bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf 'q' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]]
    after_hash=$(shasum "$whitelist_file" | awk '{print $1}')
    [ "$before_hash" = "$after_hash" ]
}

@test "whitelist validation accepts special and non-ASCII characters (#749)" {
    # Verify the [[:cntrl:]] guard accepts valid macOS path chars and rejects control chars.
    run bash --noprofile --norc -c "
        accept() { [[ ! \"\$1\" =~ [[:cntrl:]] ]] && echo ACCEPT || echo REJECT; }
        accept '/Users/me/Library/Application Support/Foo & Bar'
        accept '/Users/me/Library/Caches/com.example+beta'
        accept '/Users/me/Library/Caches/com.example(Preview)'
        accept '/Users/me/Library/Caches/บริษัท'
        accept '/Users/me/Library/Caches/app,[test]'
        [[ \$'line\nbreak' =~ [[:cntrl:]] ]] && echo REJECT_NEWLINE || echo FAIL
        [[ \$'tab\there' =~ [[:cntrl:]] ]] && echo REJECT_TAB || echo FAIL
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACCEPT"* ]]
    [[ "$output" != *"REJECT /Users"* ]]
    [[ "$output" == *"REJECT_NEWLINE"* ]]
    [[ "$output" == *"REJECT_TAB"* ]]
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

# Regression for #724: when a caller concats a glob expansion that ends
# in `/` with a sub-path that starts with `/`, the result contains `//`.
# Without slash collapsing, the comparison with a single-slash whitelist
# entry always fails and Chrome MV3 service workers get wiped.
@test "is_path_whitelisted matches entries against paths containing double slashes (#724)" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        source '$PROJECT_ROOT/lib/core/app_protection.sh'
        WHITELIST_PATTERNS=(\"\$HOME/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage\")
        is_path_whitelisted \"\$HOME/Library/Application Support/Google/Chrome/Default//Service Worker/CacheStorage\"
    "; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]
}

# safe_find_delete must consult the user whitelist on every match. Per-caller
# gates were missed in past releases (#710, #724, #738, #744); enforcing it
# inside the iterator makes whitelist protection structural rather than
# case-by-case. Regression for #757.
@test "safe_find_delete respects user whitelist for matched paths (#757)" {
    local target_dir="$HOME/safe_find_delete_target"
    local protected_file="$target_dir/protected.mat"
    local removable_file="$target_dir/removable.mat"
    mkdir -p "$target_dir"
    : > "$protected_file"
    : > "$removable_file"
    touch -t 202001010000 "$protected_file" "$removable_file"

    HOME="$HOME" bash --noprofile --norc -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/base.sh'
        source '$PROJECT_ROOT/lib/core/app_protection.sh'
        source '$PROJECT_ROOT/lib/core/file_ops.sh'
        WHITELIST_PATTERNS=(\"$target_dir/protected.mat\")
        safe_find_delete \"$target_dir\" '*' 1 f
    " > /dev/null

    [[ -f "$protected_file" ]] || {
        printf 'protected file was unexpectedly removed\n' >&2
        return 1
    }
    [[ ! -f "$removable_file" ]] || {
        printf 'removable file was unexpectedly kept\n' >&2
        return 1
    }
}

@test "safe_find_delete respects user whitelist glob patterns (#757)" {
    local target_dir="$HOME/idleassetsd_target"
    local protected_file="$target_dir/Customer/cbbim-w-prod.mat"
    local removable_file="$target_dir/other/extra.dat"
    mkdir -p "$target_dir/Customer" "$target_dir/other"
    : > "$protected_file"
    : > "$removable_file"
    touch -t 202001010000 "$protected_file" "$removable_file"

    HOME="$HOME" bash --noprofile --norc -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/base.sh'
        source '$PROJECT_ROOT/lib/core/app_protection.sh'
        source '$PROJECT_ROOT/lib/core/file_ops.sh'
        WHITELIST_PATTERNS=(\"$target_dir/Customer/*\")
        safe_find_delete \"$target_dir\" '*' 1 f
    " > /dev/null

    [[ -f "$protected_file" ]] || {
        printf 'glob-whitelisted file was unexpectedly removed\n' >&2
        return 1
    }
    [[ ! -f "$removable_file" ]] || {
        printf 'non-whitelisted file was unexpectedly kept\n' >&2
        return 1
    }
}

@test "is_path_whitelisted collapses slashes in whitelist entries too (#724)" {
    local status
    if HOME="$HOME" bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        source '$PROJECT_ROOT/lib/core/app_protection.sh'
        WHITELIST_PATTERNS=(\"\$HOME//Library//Caches//chrome-sw\")
        is_path_whitelisted \"\$HOME/Library/Caches/chrome-sw\"
    "; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]
}
