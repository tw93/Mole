#!/usr/bin/env bats


setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-userfile.XXXXXX")"
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
    rm -rf "$HOME/.config" "$HOME/.cache"
    mkdir -p "$HOME"
}

@test "get_darwin_major returns numeric version on macOS" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_darwin_major")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_darwin_major returns 999 on failure (mock uname failure)" {
    result=$(bash -c "
        uname() { return 1; }
        export -f uname
        source '$PROJECT_ROOT/lib/core/base.sh'
        get_darwin_major
    ")
    [ "$result" = "999" ]
}

@test "is_darwin_ge correctly compares versions" {
    run bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_darwin_ge 1"
    [ "$status" -eq 0 ]

    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_darwin_ge 100 && echo 'yes' || echo 'no'")
    [[ -n "$result" ]]
}

@test "is_root_user detects non-root correctly" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_root_user && echo 'root' || echo 'not-root'")
    [ "$result" = "not-root" ]
}

@test "get_invoking_user returns current user when not sudo" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_user")
    [ -n "$result" ]
    [ "$result" = "${USER:-$(whoami)}" ]
}

@test "get_invoking_uid returns numeric UID" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_uid")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_invoking_gid returns numeric GID" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_gid")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_invoking_home returns home directory" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_home")
    [ -n "$result" ]
    [ -d "$result" ]
}

@test "get_roomy_temp_root uses writable TMPDIR when available" {
    local writable_tmp="$HOME/custom-tmp"
    mkdir -p "$writable_tmp"

    result=$(env HOME="$HOME" TMPDIR="$writable_tmp" bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_roomy_temp_root")
    [ "$result" = "$writable_tmp" ]
}

@test "get_roomy_temp_root falls back to user cache when TMPDIR is not writable" {
    local blocked_tmp="$HOME/blocked-tmp"
    mkdir -p "$blocked_tmp"
    chmod 500 "$blocked_tmp"

    result=$(env HOME="$HOME" TMPDIR="$blocked_tmp" bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_roomy_temp_root")
    [ "$result" = "$HOME/.cache/roomy/tmp" ]
    [ -d "$HOME/.cache/roomy/tmp" ]
}

@test "get_roomy_temp_root caches the first resolved directory" {
    local first_tmp="$HOME/first-tmp"
    local second_tmp="$HOME/second-tmp"
    mkdir -p "$first_tmp" "$second_tmp"

    result=$(env HOME="$HOME" TMPDIR="$first_tmp" bash -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_roomy_temp_root
        first=\$ROOMY_RESOLVED_TMPDIR
        export TMPDIR='$second_tmp'
        ensure_roomy_temp_root
        second=\$ROOMY_RESOLVED_TMPDIR
        printf '%s|%s\n' \"\$first\" \"\$second\"
    ")

    [ "$result" = "$first_tmp|$first_tmp" ]
}

@test "get_roomy_temp_root falls back to /tmp when TMPDIR and invoking home are unavailable" {
    result=$(env HOME="$HOME" TMPDIR="/var/empty" bash -c "
        source '$PROJECT_ROOT/lib/core/base.sh'
        get_invoking_home() { echo '/var/empty'; }
        get_roomy_temp_root
    ")

    [ "$result" = "/tmp" ]
}

@test "common.sh exports resolved TMPDIR for runtime callers" {
    local blocked_tmp="$HOME/common-blocked-tmp"
    mkdir -p "$blocked_tmp"
    chmod 500 "$blocked_tmp"

    result=$(env HOME="$HOME" TMPDIR="$blocked_tmp" bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; printf '%s\n' \"\$TMPDIR\"")
    [ "$result" = "$HOME/.cache/roomy/tmp" ]
}

@test "get_user_home returns home for valid user" {
    current_user="${USER:-$(whoami)}"
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_user_home '$current_user'")
    [ -n "$result" ]
    [ -d "$result" ]
}

@test "get_user_home returns empty for invalid user" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_user_home 'nonexistent_user_12345'")
    [ -z "$result" ] || [ "$result" = "~nonexistent_user_12345" ]
}

@test "ensure_user_dir creates simple directory" {
    test_dir="$HOME/.cache/test"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir creates nested directory" {
    test_dir="$HOME/.config/roomy/deep/nested/path"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir handles tilde expansion" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '~/.cache/tilde-test'"
    [ -d "$HOME/.cache/tilde-test" ]
}

@test "ensure_user_dir is idempotent" {
    test_dir="$HOME/.cache/idempotent"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir replaces leaf symlinks without following them" {
    real_dir="$HOME/real-cache-target"
    link_dir="$HOME/.cache/roomy"
    mkdir -p "$real_dir" "$(dirname "$link_dir")"
    echo "keep" > "$real_dir/marker"
    ln -s "$real_dir" "$link_dir"

    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$link_dir'"

    [ -d "$link_dir" ]
    [ ! -L "$link_dir" ]
    [ "$(cat "$real_dir/marker")" = "keep" ]
}

@test "ensure_user_dir handles empty path gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir ''"
    [ "$status" -eq 0 ]
}

@test "ensure_user_dir preserves ownership for non-root users" {
    test_dir="$HOME/.cache/ownership-test"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"

    current_uid=$(id -u)
    dir_uid=$(/usr/bin/stat -f%u "$test_dir")
    [ "$dir_uid" = "$current_uid" ]
}


@test "ensure_user_file creates file and parent directories" {
    test_file="$HOME/.config/roomy/test.log"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
    [ -d "$(dirname "$test_file")" ]
}

@test "ensure_user_file handles tilde expansion" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '~/.cache/tilde-file.txt'"
    [ -f "$HOME/.cache/tilde-file.txt" ]
}

@test "ensure_user_file is idempotent" {
    test_file="$HOME/.cache/idempotent.txt"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    echo "content" > "$test_file"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
    [ "$(cat "$test_file")" = "content" ]
}

@test "ensure_user_file replaces leaf symlinks without following them" {
    protected_file="$HOME/protected-target.txt"
    link_file="$HOME/.cache/roomy/log.txt"
    mkdir -p "$(dirname "$link_file")"
    echo "protected" > "$protected_file"
    ln -s "$protected_file" "$link_file"

    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$link_file'; printf 'generated\n' > '$link_file'"

    [ -f "$link_file" ]
    [ ! -L "$link_file" ]
    [ "$(cat "$link_file")" = "generated" ]
    [ "$(cat "$protected_file")" = "protected" ]
}

@test "commit_staged_user_file replaces symlinked target without following it" {
    protected_dir="$HOME/protected-commit-dir"
    target_file="$HOME/.cache/roomy/state.txt"
    staged_file="$HOME/.cache/roomy/.state.tmp"
    mkdir -p "$(dirname "$target_file")" "$protected_dir"
    printf 'staged\n' > "$staged_file"
    ln -s "$protected_dir" "$target_file"

    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; commit_staged_user_file '$staged_file' '$target_file'"

    [ -f "$target_file" ]
    [ ! -L "$target_file" ]
    [ "$(cat "$target_file")" = "staged" ]
    [ -z "$(find "$protected_dir" -mindepth 1 -print -quit)" ]
}

@test "ensure_user_file handles empty path gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file ''"
    [ "$status" -eq 0 ]
}

@test "ensure_user_file creates deeply nested files" {
    test_file="$HOME/.config/deep/very/nested/structure/file.log"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
}

@test "ensure_user_file preserves ownership for non-root users" {
    test_file="$HOME/.cache/file-ownership-test.txt"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"

    current_uid=$(id -u)
    file_uid=$(/usr/bin/stat -f%u "$test_file")
    [ "$file_uid" = "$current_uid" ]
}

@test "ensure_user_dir early stop optimization works" {
    test_dir="$HOME/.cache/perf/test/nested"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"

    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]

    current_uid=$(id -u)
    dir_uid=$(/usr/bin/stat -f%u "$test_dir")
    [ "$dir_uid" = "$current_uid" ]
}

@test "ensure_user_dir and ensure_user_file work together" {
    cache_dir="$HOME/.cache/roomy"
    cache_file="$cache_dir/integration_test.log"

    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$cache_dir'"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$cache_file'"

    [ -d "$cache_dir" ]
    [ -f "$cache_file" ]
}

@test "multiple ensure_user_file calls in same directory" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_user_file '$HOME/.config/roomy/file1.txt'
        ensure_user_file '$HOME/.config/roomy/file2.txt'
        ensure_user_file '$HOME/.config/roomy/file3.txt'
    "

    [ -f "$HOME/.config/roomy/file1.txt" ]
    [ -f "$HOME/.config/roomy/file2.txt" ]
    [ -f "$HOME/.config/roomy/file3.txt" ]
}

@test "ensure functions handle concurrent calls safely" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_user_dir '$HOME/.cache/concurrent' &
        ensure_user_dir '$HOME/.cache/concurrent' &
        wait
    "

    [ -d "$HOME/.cache/concurrent" ]
}
