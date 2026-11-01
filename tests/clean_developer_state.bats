#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_home developer-state
}

teardown() {
    mole_test_teardown_home
}

probe_developer_state() {
    local family="$1"
    local boundary="$2"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 MO_NO_OPLOG=1 FAMILY="$family" BOUNDARY="$boundary" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
case "$FAMILY" in
    wal)
        targets=("$HOME/.prometheus/data/wal/00000000")
        positive="$HOME/.grafana/cache/rebuildable"
        cleanup=clean_dev_cicd
        ;;
    backup)
        targets=("$HOME/.gitconfig.bak" "$HOME/.config/fish/fish_history.bak" "$HOME/.bash_history.bak" "$HOME/.zsh_history.bak")
        positive="$HOME/.oh-my-zsh/cache/rebuildable"
        cleanup=clean_dev_shell
        ;;
    lock)
        targets=("$HOME/.gitconfig.lock")
        positive="$HOME/.oh-my-zsh/cache/rebuildable"
        cleanup=clean_dev_shell
        ;;
    jupyter)
        targets=("$HOME/.jupyter/runtime/kernel-fixture.json")
        positive="$HOME/.pyenv/cache/rebuildable"
        cleanup=clean_dev_python
        pip3() { return 1; }
        uv() { return 1; }
        conda() { return 1; }
        run_with_timeout() { shift; "$@"; }
        ;;
esac
for target in "${targets[@]}" "$positive"; do
    mkdir -p "$(dirname "$target")"
    printf 'synthetic user state\n' > "$target"
done
# A freshly created file can still be an active WAL or config transaction.
exec 7>>"${targets[0]}"
trace="$HOME/sink-trace"
export trace
: > "$trace"
rm() { printf '%s\n' "${@: -1}" >> "$trace"; }
if [[ "$BOUNDARY" == candidate ]]; then
    # Inspect the producer independently from its protection backstop. The
    # neighboring cache is a positive control that the real producer ran.
    safe_clean() {
        local path
        for path in "${@:1:$#-1}"; do
            [[ ! -e "$path" ]] || printf '%s\n' "$path" >> "$trace"
        done
        return 0
    }
    "$cleanup"
else
    for target in "${targets[@]}" "$positive"; do
        safe_remove "$target" true || true
    done
fi
grep -Fx -- "$positive" "$trace" >/dev/null || exit 1
for target in "${targets[@]}"; do
    if grep -Fx -- "$target" "$trace" >/dev/null; then
        printf 'UNSAFE:%s\n' "${target#"$HOME"/}"
        exit 1
    fi
    [[ -f "$target" ]] || exit 1
done
if [[ "$BOUNDARY" == sink ]]; then
    # Protection belongs to automated cleanup, not explicit uninstall choices.
    for target in "${targets[@]}"; do
        if MOLE_UNINSTALL_MODE=1 should_protect_path "$target"; then
            printf 'UNINSTALL_BLOCKED:%s\n' "$target"
            exit 1
        fi
    done
    if [[ "$FAMILY" == wal ]]; then
        should_protect_path "$HOME/.prometheus/data" || exit 1
    fi
    if [[ "$FAMILY" == jupyter ]]; then
        should_protect_path "$HOME/.jupyter/runtime" || exit 1
    fi
fi
printf 'SAFE:%s:%s\n' "$FAMILY" "$BOUNDARY"
EOF
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE:$family:$boundary"* ]] || return 1
}

# Keep the real producer, policy and removal sink. Only unrelated package
# commands and the final rm are substituted; the Classic control must reach rm.
probe_yarn_berry_boundary() {
    local variant="$1"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" VARIANT="$variant" \
        MOLE_TEST_NO_AUTH=1 MO_NO_OPLOG=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
berry="$HOME/.yarn/berry/cache"
classic="$HOME/Library/Caches/Yarn/v6/package.tgz"
neighbor="$HOME/.yarn/berry/cache-backup/package.zip"
mkdir -p "$berry/nested" "$(dirname "$classic")" "$(dirname "$neighbor")" "$HOME/.config/mole"
printf 'installed PnP dependency\n' > "$berry/package.zip"
printf 'installed PnP dependency\n' > "$berry/nested/package.zip"
printf 'download cache\n' > "$classic"
printf 'neighbor control\n' > "$neighbor"
if [[ "$VARIANT" == custom ]]; then
    printf '%s\n' "$HOME/keep-unrelated/*" > "$HOME/.config/mole/whitelist"
fi
load_mole_whitelist "$HOME"
npm() { return 1; }
run_with_timeout() { shift; "$@"; }
clean_pnpm_stores() { :; }
clean_corepack_cache() { :; }
clean_bun_cache() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
trace="$HOME/yarn-removal-trace"
export trace
: > "$trace"
rm() { printf '%s\n' "${@: -1}" >> "$trace"; }
clean_dev_npm
# Direct callers cannot bypass the clean backstop, including the root itself.
for target in "$berry" "$berry/package.zip" "$berry/nested/package.zip" "$neighbor"; do
    safe_remove "$target" true || true
done
cat "$trace"
grep -Fx -- "$(dirname "$classic")" "$trace" >/dev/null || exit 1
grep -Fx -- "$neighbor" "$trace" >/dev/null || exit 1
for target in "$berry" "$berry/package.zip" "$berry/nested/package.zip"; do
    if grep -Fx -- "$target" "$trace" >/dev/null; then
        echo "BERRY_REMOVED:$target"
        exit 1
    fi
    should_protect_path "$target" || exit 1
    if MOLE_UNINSTALL_MODE=1 should_protect_path "$target"; then
        echo "UNINSTALL_BLOCKED:$target"
        exit 1
    fi
done
printf 'BERRY_SAFE:%s\n' "$VARIANT"
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"BERRY_SAFE:$variant"* ]] || return 1
}

@test "developer cleanup never nominates Prometheus recovery WAL" {
    probe_developer_state wal candidate
}

@test "developer cleanup never nominates sole config or shell-history backups" {
    probe_developer_state backup candidate
}

@test "developer cleanup never nominates an active Git config lock" {
    probe_developer_state lock candidate
}

@test "cleanup sink protects Prometheus data while keeping ordinary caches cleanable" {
    probe_developer_state wal sink
}

@test "cleanup sink protects config and shell-history backups without blocking uninstall" {
    probe_developer_state backup sink
}

@test "cleanup sink protects an open Git config lock without blocking uninstall" {
    probe_developer_state lock sink
}

@test "developer cleanup never nominates Jupyter runtime connection files" {
    probe_developer_state jupyter candidate
}

@test "cleanup sink protects Jupyter runtime without blocking uninstall" {
    probe_developer_state jupyter sink
}

@test "Yarn Berry producer and sink preserve dependencies with the default whitelist" {
    probe_yarn_berry_boundary default
}

@test "Yarn Berry producer and sink preserve dependencies with a custom whitelist" {
    probe_yarn_berry_boundary custom
}
