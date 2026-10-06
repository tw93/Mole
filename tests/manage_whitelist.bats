#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home whitelist-home
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "$HOME/.config"
    mkdir -p "$HOME"
    WHITELIST_PATH="$HOME/.config/mole/whitelist"
}

@test "patterns_equivalent treats paths with tilde expansion as equal" {
    local status
    if HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; patterns_equivalent '~/.cache/test' \"\$HOME/.cache/test\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]
}

@test "patterns_equivalent distinguishes different paths" {
    local status
    if HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; patterns_equivalent '~/.cache/test' \"\$HOME/.cache/other\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -ne 0 ]
}

@test "save_whitelist_patterns keeps unique entries and preserves header" {
    HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; save_whitelist_patterns \"\$HOME/.cache/foo\" \"\$HOME/.cache/foo\" \"\$HOME/.cache/bar\""

    [[ -f "$WHITELIST_PATH" ]] || return 1

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
    HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; rm -f \"\$HOME/.config/mole/whitelist\"; load_whitelist; printf '%s\n' \"\${CURRENT_WHITELIST_PATTERNS[@]}\"" > "$HOME/current_whitelist.txt"
    HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; printf '%s\n' \"\${DEFAULT_WHITELIST_PATTERNS[@]}\"" > "$HOME/default_whitelist.txt"

    current=()
    while IFS= read -r line; do
        current+=("$line")
    done < "$HOME/current_whitelist.txt"

    defaults=()
    while IFS= read -r line; do
        defaults+=("$line")
    done < "$HOME/default_whitelist.txt"

    # Every convenience default must survive, and the hard-safety entries are
    # merged on top. Asserting a count would re-pin a number that changes
    # whenever either list grows; assert the containment instead.
    [ "${#defaults[@]}" -gt 0 ]
    local expected
    for expected in "${defaults[@]}"; do
        expected="${expected/\$HOME/$HOME}"
        printf '%s\n' "${current[@]}" | grep -qxF "$expected" || {
            echo "missing default: $expected"
            return 1
        }
    done
    [ "${current[0]}" = "${defaults[0]/\$HOME/$HOME}" ]

    safety=()
    while IFS= read -r line; do
        safety+=("$line")
    done < <(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; printf '%s\n' \"\${SAFETY_WHITELIST_PATTERNS[@]}\"")
    for expected in "${safety[@]}"; do
        printf '%s\n' "${current[@]}" | grep -qxF "$expected" || {
            echo "missing safety entry: $expected"
            return 1
        }
    done
}

@test "is_whitelisted matches saved patterns exactly" {
    local status
    if HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; save_whitelist_patterns \"\$HOME/.cache/unique-pattern\"; load_whitelist; is_whitelisted \"\$HOME/.cache/unique-pattern\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ]

    if HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/manage/whitelist.sh'; save_whitelist_patterns \"\$HOME/.cache/unique-pattern\"; load_whitelist; is_whitelisted \"\$HOME/.cache/other-pattern\""; then
        status=0
    else
        status=$?
    fi
    [ "$status" -ne 0 ]
}

@test "optimize whitelist ignores and does not resave removed task ids" {
    local optimize_path="$HOME/.config/mole/whitelist_optimize"
    mkdir -p "$(dirname "$optimize_path")"
    printf 'dock_refresh\nmemory_pressure_relief\nlaunch_services_rebuild\ncache_refresh\n' > "$optimize_path"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
load_whitelist optimize
printf 'loaded:%s\n' "${CURRENT_WHITELIST_PATTERNS[@]}"
save_whitelist_patterns optimize dock_refresh memory_pressure_relief launch_services_rebuild cache_refresh
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"loaded:cache_refresh"* ]] || return 1
    [[ "$output" != *"loaded:dock_refresh"* ]] || return 1
    [[ "$output" != *"loaded:memory_pressure_relief"* ]] || return 1
    [[ "$output" != *"loaded:launch_services_rebuild"* ]] || return 1
    grep -qFx 'cache_refresh' "$optimize_path"
    run grep -qFx 'dock_refresh' "$optimize_path"
    [ "$status" -eq 1 ]
    run grep -qFx 'memory_pressure_relief' "$optimize_path"
    [ "$status" -eq 1 ]
    run grep -qFx 'launch_services_rebuild' "$optimize_path"
    [ "$status" -eq 1 ]
}

@test "load_whitelist merges FINDER_METADATA into an existing custom file (#1396)" {
    mkdir -p "$(dirname "$WHITELIST_PATH")"
    printf '%s\n' "$HOME/.cache/custom-keep/*" > "$WHITELIST_PATH"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
load_whitelist
has_sentinel=false
has_custom=false
for p in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
    [[ "$p" == "$FINDER_METADATA_SENTINEL" ]] && has_sentinel=true
    [[ "$p" == "$HOME/.cache/custom-keep/*" ]] && has_custom=true
done
printf 'sentinel=%s custom=%s count=%s\n' "$has_sentinel" "$has_custom" "${#CURRENT_WHITELIST_PATTERNS[@]}"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"sentinel=true"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"custom=true"* ]] || { echo "$output"; return 1; }
}

@test "ensure_safety_whitelist_patterns is idempotent and preserves custom entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
declare -a WHITELIST_PATTERNS=("$HOME/.cache/custom-keep/*" "$FINDER_METADATA_SENTINEL")
declare -a CURRENT_WHITELIST_PATTERNS=("${WHITELIST_PATTERNS[@]}")
ensure_safety_whitelist_patterns
ensure_safety_whitelist_patterns
sentinel_count=0
custom_count=0
for p in "${WHITELIST_PATTERNS[@]}"; do
    [[ "$p" == "$FINDER_METADATA_SENTINEL" ]] && sentinel_count=$((sentinel_count + 1))
    [[ "$p" == "$HOME/.cache/custom-keep/*" ]] && custom_count=$((custom_count + 1))
done
# Every safety entry must appear exactly once after two calls, and the total
# is derived from the array rather than pinned, so growing hard safety does
# not turn an idempotency test into a counting test.
duplicated=0
for safety in "${SAFETY_WHITELIST_PATTERNS[@]}"; do
    seen=0
    for p in "${WHITELIST_PATTERNS[@]}"; do
        [[ "$p" == "$safety" ]] && seen=$((seen + 1))
    done
    [[ $seen -eq 1 ]] || duplicated=$((duplicated + 1))
done
expected_total=$((1 + ${#SAFETY_WHITELIST_PATTERNS[@]}))
printf 'sentinel=%s custom=%s duplicated=%s total_matches_expected=%s\n' \
    "$sentinel_count" "$custom_count" "$duplicated" \
    "$([[ ${#WHITELIST_PATTERNS[@]} -eq $expected_total ]] && echo yes || echo no)"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"sentinel=1"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"custom=1"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"duplicated=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"total_matches_expected=yes"* ]] || { echo "$output"; return 1; }
}

@test "legacy optimize whitelist with only removed task ids migrates safely on Bash 3.2" {
    local legacy_path="$HOME/.config/mole/whitelist_checks"
    local optimize_path="$HOME/.config/mole/whitelist_optimize"
    mkdir -p "$(dirname "$legacy_path")"
    printf 'dock_refresh\nmemory_pressure_relief\n' > "$legacy_path"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
load_whitelist optimize
[[ ${#CURRENT_WHITELIST_PATTERNS[@]} -eq 0 ]] || exit 1
printf 'survived\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"survived"* ]] || return 1
    [[ -f "$optimize_path" ]] || return 1
    run grep -qFx 'dock_refresh' "$optimize_path"
    [ "$status" -eq 1 ]
}

@test "whitelist inventory exposes LM Studio app cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"LM Studio app cache|\$HOME/Library/Caches/com.lmstudio.lmstudio/*|ai_ml_cache"* ]] || return 1
    [[ "$output" != *".cache/lm-studio"* ]]
}

@test "whitelist inventory exposes Codex staging and Tart caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex Desktop update staging|\$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation|ai_ml_cache"* ]] || return 1
    [[ "$output" == *"Tart OCI/IPSW cache|\$HOME/.tart/cache|container_cache"* ]] || return 1
}

@test "whitelist inventory offers no protection for paths Mole never deletes" {
    # Every inventory row is a protection the user can switch on. Offering one
    # for a path no cleanup path touches invites the reader to conclude Mole
    # would otherwise delete it. registry/src is kept by clean_dev_rust, so it
    # must not reappear here.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust Cargo registry cache|\$HOME/.cargo/registry/cache/*|compiler_cache"* ]] || return 1
    [[ "$output" != *"registry/src"* ]] || return 1
    [[ "$output" != *"Cargo git"* ]] || return 1
    [[ "$output" != *"Deno cache"* ]] || return 1
    [[ "$output" != *"SBT Scala"* ]] || return 1
    [[ "$output" != *"Ivy dependency"* ]] || return 1
    [[ "$output" != *"PyTorch model"* ]] || return 1
    [[ "$output" != *"TensorFlow model"* ]] || return 1
    [[ "$output" != *"HuggingFace models"* ]] || return 1
    [[ "$output" != *"Weights & Biases"* ]]
}

@test "whitelist inventory follows relocated Go cache roots" {
    local build_root="$HOME/custom-go-build"
    local module_root="$HOME/custom-go-mod"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        BUILD_ROOT="$build_root" MODULE_ROOT="$module_root" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
mole_go_cache_root() {
    if [[ "$1" == "GOCACHE" ]]; then
        printf '%s\n' "$BUILD_ROOT"
    else
        printf '%s\n' "$MODULE_ROOT"
    fi
}
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go build cache|$build_root/*|compiler_cache"* ]] || return 1
    [[ "$output" == *"Go module cache|$module_root/*|compiler_cache"* ]] || return 1
    [[ "$output" != *"\$HOME/go/pkg/mod"* ]]
}

@test "whitelist inventory exposes guarded PyInstaller and Clang caches" {
    local darwin_cache="$HOME/darwin-cache"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DARWIN_CACHE="$darwin_cache" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
mole_darwin_user_cache_root() { printf '%s\n' "$DARWIN_CACHE"; }
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PyInstaller binary cache|\$HOME/Library/Application Support/pyinstaller/bincache*|compiler_cache"* ]] || return 1
    [[ "$output" == *"Clang module cache|$darwin_cache/clang/*|compiler_cache"* ]]
}

@test "whitelist inventory resolves the GitHub CLI cache location" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"GitHub CLI cache|$HOME/.cache/gh|network_tools"* ]] || return 1

    local xdg_cache="$HOME/custom-cache"
    run env HOME="$HOME" XDG_CACHE_HOME="$xdg_cache" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"GitHub CLI cache|$xdg_cache/gh|network_tools"* ]] || return 1
    [[ "$output" != *"GitHub CLI cache|$HOME/.cache/gh|network_tools"* ]] || return 1
}

@test "saved custom XDG GitHub CLI cache whitelist blocks the owner command" {
    local xdg_cache="$HOME/custom-cache"
    local trace="$HOME/gh-xdg-manager.trace"
    mkdir -p "$xdg_cache/gh" "$HOME/bin"
    cat > "$HOME/bin/gh" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_TRACE"
exit 0
SCRIPT
    chmod +x "$HOME/bin/gh"

    run env HOME="$HOME" XDG_CACHE_HOME="$xdg_cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
github_cache_pattern=""
while IFS='|' read -r name pattern _; do
    if [[ "$name" == "GitHub CLI cache" ]]; then
        github_cache_pattern="$pattern"
        break
    fi
done < <(get_all_cache_items)
[[ "$github_cache_pattern" == "$XDG_CACHE_HOME/gh" ]] || exit 1
save_whitelist_patterns "$github_cache_pattern"
load_mole_whitelist "$HOME"

source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · skipped (whitelist)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "whitelist inventory exposes Chrome AI model stores" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Chrome on-device AI models|\$HOME/Library/Application Support/Google/Chrome/OptGuideOnDevice*/*|ai_ml_cache"* ]] || return 1
    [[ "$output" == *"Chrome optimization guide models|\$HOME/Library/Application Support/Google/Chrome/optimization_guide_model_store/*|ai_ml_cache"* ]] || return 1
    [[ "$output" == *"Chrome browser cache|\$HOME/Library/Caches/Google/Chrome/*|browser_cache"* ]] || return 1
}

@test "whitelist inventory exposes Final Cut Pro proxy media (#1499)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_all_cache_items
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Final Cut Pro proxy media (render files still cleaned)|\$HOME/Movies/*.fcpbundle/*/Transcoded Media/Proxy Media|app_cache"* ]] || return 1
}

@test "mo clean --whitelist persists selections" {
    whitelist_file="$HOME/.config/mole/whitelist"
    mkdir -p "$(dirname "$whitelist_file")"

    run /bin/bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    first_pattern=$(grep -v '^[[:space:]]*#' "$whitelist_file" | grep -v '^[[:space:]]*$' | head -n 1)
    [ -n "$first_pattern" ]

    run /bin/bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$' \\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    run grep -Fxq "$first_pattern" "$whitelist_file"
    [ "$status" -eq 1 ]

    run /bin/bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    run grep -Fxq "$first_pattern" "$whitelist_file"
    [ "$status" -eq 1 ]
}

@test "a saved renv line stays protected after the whitelist menu saves" {
    # The renv cache is hard safety now and has no menu row. Files saved
    # before that still carry its old default line, spelled with ~ or $HOME.
    # Saving through the menu must keep unrelated custom rules, and the renv
    # cache must stay protected whether or not the old line survives.
    local variant test_home whitelist_file
    for variant in tilde absolute; do
        test_home="$HOME/renv-menu-$variant"
        whitelist_file="$test_home/.config/mole/whitelist"
        mkdir -p "$(dirname "$whitelist_file")"
        if [[ "$variant" == "tilde" ]]; then
            # shellcheck disable=SC2088 # Exercise a saved literal tilde pattern.
            printf '%s\n' '~/Library/Caches/org.R-project.R/R/renv/*' > "$whitelist_file"
        else
            printf '%s\n' "$test_home/Library/Caches/org.R-project.R/R/renv/*" > "$whitelist_file"
        fi
        printf '%s\n' "$test_home/.cache/custom-keep/*" >> "$whitelist_file"

        run /bin/bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$test_home' ./mo clean --whitelist"
        [ "$status" -eq 0 ] || { echo "$variant: $output"; return 1; }
        grep -Fxq "$test_home/.cache/custom-keep/*" "$whitelist_file" || {
            echo "$variant: custom rule lost"
            cat "$whitelist_file"
            return 1
        }

        run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
# Capture first: under pipefail an early `grep -q` exit fails the pipe.
menu_items=$(get_all_cache_items)
if grep -q "R renv" <<< "$menu_items"; then
    echo "MENU_ROW_PRESENT"
fi
load_mole_whitelist "$HOME"
for probe in \
    "$HOME/Library/Caches/org.R-project.R" \
    "$HOME/Library/Caches/org.R-project.R/R/renv/cache/v5/pkg" \
    "$HOME/.cache/custom-keep/x"; do
    if is_path_whitelisted "$probe"; then
        printf 'PROTECTED=%s\n' "${probe#"$HOME"/}"
    else
        printf 'EXPOSED=%s\n' "${probe#"$HOME"/}"
    fi
done
EOF
        [ "$status" -eq 0 ] || { echo "$variant: $output"; return 1; }
        [[ "$output" != *"MENU_ROW_PRESENT"* ]] || { echo "$variant: $output"; return 1; }
        [[ "$output" != *"EXPOSED="* ]] || { echo "$variant: $output"; return 1; }
    done
}

@test "mo clean --whitelist cancel preserves existing file (#807)" {
    whitelist_file="$HOME/.config/mole/whitelist"
    mkdir -p "$(dirname "$whitelist_file")"

    run /bin/bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf \$'\\n' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    [[ -f "$whitelist_file" ]] || return 1
    before_hash=$(shasum "$whitelist_file" | awk '{print $1}')

    run /bin/bash --noprofile --norc -c "cd '$PROJECT_ROOT'; printf 'q' | HOME='$HOME' ./mo clean --whitelist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]] || return 1
    after_hash=$(shasum "$whitelist_file" | awk '{print $1}')
    [ "$before_hash" = "$after_hash" ]
}

@test "whitelist validation accepts special and non-ASCII characters (#749)" {
    # Verify the [[:cntrl:]] guard accepts valid macOS path chars and rejects control chars.
    run /bin/bash --noprofile --norc -c "
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
    [[ "$output" == *"ACCEPT"* ]] || return 1
    [[ "$output" != *"REJECT /Users"* ]] || return 1
    [[ "$output" == *"REJECT_NEWLINE"* ]] || return 1
    [[ "$output" == *"REJECT_TAB"* ]]
}

@test "is_path_whitelisted protects parent directories of whitelisted nested paths" {
    local status
    if HOME="$HOME" /bin/bash --noprofile --norc -c "
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
    if HOME="$HOME" /bin/bash --noprofile --norc -c "
        source '$PROJECT_ROOT/lib/manage/whitelist.sh'
        rm -f \"\$HOME/.config/mole/whitelist\"
        load_whitelist
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
    if HOME="$HOME" /bin/bash --noprofile --norc -c "
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

    HOME="$HOME" /bin/bash --noprofile --norc -c "
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

    HOME="$HOME" /bin/bash --noprofile --norc -c "
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
    if HOME="$HOME" /bin/bash --noprofile --norc -c "
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

# Drive the real clean whitelist menu with a stubbed selector. The stub returns
# the preselected rows, minus the Gradle build cache row when GRADLE_ACTION is
# "uncheck". Prints the preselected state, then the real cleanup-side verdict.
run_gradle_menu() {
    local action="$1"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" GRADLE_ACTION="$action" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
paginated_multi_select() {
    shift
    local -a opts=("$@")
    local -a keep=()
    local idx
    local -a pre=()
    IFS=',' read -ra pre <<< "${MOLE_PRESELECTED_INDICES:-}"
    for idx in "${pre[@]}"; do
        if [[ "${opts[$idx]}" == "Gradle build cache"* ]]; then
            echo "GRADLE_PRESELECTED" >&2
            [[ "$GRADLE_ACTION" == "uncheck" ]] && continue
        fi
        keep+=("$idx")
    done
    local IFS=','
    MOLE_SELECTION_RESULT="${keep[*]:-}"
    return 0
}
manage_whitelist clean > /dev/null
echo "MENU_DONE"
load_mole_whitelist "$HOME"
probe="$HOME/.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"
if is_path_whitelisted "$probe"; then
    printf 'PROTECTED=%s\n' "${probe#"$HOME"/}"
else
    printf 'EXPOSED=%s\n' "${probe#"$HOME"/}"
fi
EOF
}

@test "Gradle menu row spelling matches the default protection (#458)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
row=$(get_all_cache_items | grep '^Gradle build cache')
pattern="${row#*|}"
pattern="${pattern%%|*}"
pattern="${pattern/\$HOME/$HOME}"
echo "ROW=$pattern"
for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
    [[ "$default" == "$pattern" ]] && echo "MATCHES_DEFAULT"
done
exit 0
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ROW=$HOME/.gradle/caches/*"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"MATCHES_DEFAULT"* ]] || { echo "$output"; return 1; }
}

@test "Gradle row starts checked and unchecking it exposes the build cache (#458)" {
    rm -f "$WHITELIST_PATH"
    run_gradle_menu uncheck
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"MENU_DONE"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"GRADLE_PRESELECTED"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"EXPOSED=.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"* ]] || { echo "$output"; return 1; }
    [[ -f "$WHITELIST_PATH" ]] || return 1
    ! grep -q '\.gradle/caches' "$WHITELIST_PATH" || { cat "$WHITELIST_PATH"; return 1; }

    rm -f "$WHITELIST_PATH"
    run_gradle_menu keep
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GRADLE_PRESELECTED"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"PROTECTED=.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"* ]] || { echo "$output"; return 1; }
}

@test "a caches/* line kept as custom by an older menu shows checked and unchecking removes it" {
    # Before the row matched the default, saving the menu wrote the unmatched
    # default back as an absolute custom line that no row could clear.
    mkdir -p "$(dirname "$WHITELIST_PATH")"
    printf '%s\n' "$HOME/.gradle/caches/*" > "$WHITELIST_PATH"
    run_gradle_menu uncheck
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"MENU_DONE"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"GRADLE_PRESELECTED"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"EXPOSED=.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"* ]] || { echo "$output"; return 1; }
    ! grep -q '\.gradle/caches' "$WHITELIST_PATH" || { cat "$WHITELIST_PATH"; return 1; }
}

@test "legacy build-cache-*/* line shows checked, and unchecking removes both spellings" {
    mkdir -p "$(dirname "$WHITELIST_PATH")"
    # shellcheck disable=SC2088 # Exercise a saved literal tilde pattern.
    printf '%s\n' '~/.gradle/caches/build-cache-*/*' > "$WHITELIST_PATH"
    run_gradle_menu uncheck
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"MENU_DONE"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"GRADLE_PRESELECTED"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"EXPOSED=.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"* ]] || { echo "$output"; return 1; }
    ! grep -q 'build-cache-\*' "$WHITELIST_PATH" || { cat "$WHITELIST_PATH"; return 1; }
    ! grep -q '\.gradle/caches' "$WHITELIST_PATH" || { cat "$WHITELIST_PATH"; return 1; }

    # A file saved with the row checked after #845 holds both lines: the row
    # and the default the menu kept as custom. Unchecking must clear both.
    # shellcheck disable=SC2088 # Exercise a saved literal tilde pattern.
    printf '%s\n' '~/.gradle/caches/build-cache-*/*' "$HOME/.gradle/caches/*" > "$WHITELIST_PATH"
    run_gradle_menu uncheck
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GRADLE_PRESELECTED"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"EXPOSED=.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"* ]] || { echo "$output"; return 1; }
    ! grep -q '\.gradle/caches' "$WHITELIST_PATH" || { cat "$WHITELIST_PATH"; return 1; }

    # shellcheck disable=SC2088 # Exercise a saved literal tilde pattern.
    printf '%s\n' '~/.gradle/caches/build-cache-*/*' > "$WHITELIST_PATH"
    run_gradle_menu keep
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GRADLE_PRESELECTED"* ]] || { echo "$output"; return 1; }
    # shellcheck disable=SC2088 # Exercise a saved literal tilde pattern.
    grep -Fxq '~/.gradle/caches/*' "$WHITELIST_PATH" || { cat "$WHITELIST_PATH"; return 1; }
    [[ "$output" == *"PROTECTED=.gradle/caches/build-cache-1/0123456789abcdef0123456789abcdef"* ]] || { echo "$output"; return 1; }
}
