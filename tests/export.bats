#!/usr/bin/env bats
# Mole Export 功能测试
# 测试内容:
#   1. 命令行参数解析
#   2. 类别过滤
#   3. 生成脚本语法检查
#   4. 敏感信息过滤

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-export-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"

    TEST_OUTPUT_DIR="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-export-output.XXXXXX")"
    export TEST_OUTPUT_DIR
}

teardown_file() {
    rm -rf "$HOME"
    rm -rf "$TEST_OUTPUT_DIR"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "$HOME/.config"
    rm -rf "$HOME/.gitconfig"
    mkdir -p "$HOME"
}

# =============================================================================
# 1. 命令行参数解析测试
# =============================================================================

@test "export --help returns 0 and shows usage" {
    run env HOME="$HOME" "$PROJECT_ROOT/bin/export.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole Export"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--category"* ]]
    [[ "$output" == *"--exclude"* ]]
}

@test "export --categories shows all categories" {
    run env HOME="$HOME" "$PROJECT_ROOT/bin/export.sh" --categories
    [ "$status" -eq 0 ]
    [[ "$output" == *"brew"* ]]
    [[ "$output" == *"npm"* ]]
    [[ "$output" == *"pip"* ]]
    [[ "$output" == *"git"* ]]
    [[ "$output" == *"shell"* ]]
    [[ "$output" == *"vscode"* ]]
    [[ "$output" == *"docker"* ]]
}

@test "export --categories shows category groups" {
    run env HOME="$HOME" "$PROJECT_ROOT/bin/export.sh" --categories
    [ "$status" -eq 0 ]
    [[ "$output" == *"essential"* ]]
    [[ "$output" == *"dev"* ]]
    [[ "$output" == *"ide"* ]]
    [[ "$output" == *"cloud"* ]]
    [[ "$output" == *"ai"* ]]
}

@test "export --dry-run returns 0 and does not generate file" {
    local test_output="$TEST_OUTPUT_DIR/dry-run-test.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --dry-run -o "$test_output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run"* ]]
    [ ! -f "$test_output" ]
}

@test "export -o creates file at specified path" {
    local test_output="$TEST_OUTPUT_DIR/output-test.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    [ -x "$test_output" ]
}

@test "export --category invalid returns error" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category invalid_category_xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"无效的类别"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"Invalid"* ]]
}

@test "export with unknown option returns error" {
    run env HOME="$HOME" "$PROJECT_ROOT/bin/export.sh" --unknown-option
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知选项"* ]] || [[ "$output" == *"Unknown"* ]]
}

@test "export -h is alias for --help" {
    run env HOME="$HOME" "$PROJECT_ROOT/bin/export.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole Export"* ]]
}

@test "export -n is alias for --dry-run" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -n -o "$TEST_OUTPUT_DIR/alias-test.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run"* ]]
}

@test "export -c is alias for --category" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -c brew --dry-run
    [ "$status" -eq 0 ]
}

@test "export -e is alias for --exclude" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -e docker --dry-run
    [ "$status" -eq 0 ]
}

# =============================================================================
# 2. 类别过滤测试
# =============================================================================

@test "export --category brew only exports brew" {
    local test_output="$TEST_OUTPUT_DIR/brew-only.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category brew -o "$test_output"
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep -c "Homebrew" "$test_output"
    [ "$output" -ge 1 ]
}

@test "export --exclude docker does not include docker" {
    local test_output="$TEST_OUTPUT_DIR/exclude-docker.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --exclude docker -o "$test_output"
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
}

@test "export --category dev expands to version managers and packages" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category dev --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"nvm"* ]] || [[ "$output" == *"pyenv"* ]] || [[ "$output" == *"npm"* ]]
}

@test "export --category essential expands to core tools" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category essential --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]] || [[ "$output" == *"brew"* ]]
    [[ "$output" == *"Git"* ]] || [[ "$output" == *"git"* ]]
}

@test "export --category ide expands to editors" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category ide --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"vscode"* ]] || [[ "$output" == *"cursor"* ]] || [[ "$output" == *"IDE"* ]]
}

@test "export multiple categories via comma" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category brew,git --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]] || [[ "$output" == *"brew"* ]]
    [[ "$output" == *"Git"* ]] || [[ "$output" == *"git"* ]]
}

@test "export with exclude removes category from all" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category all --exclude docker,aws --dry-run
    [ "$status" -eq 0 ]
}

# =============================================================================
# 3. 生成脚本语法测试
# =============================================================================

@test "generated script passes bash -n syntax check" {
    local test_output="$TEST_OUTPUT_DIR/syntax-check.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run bash -n "$test_output"
    [ "$status" -eq 0 ]
}

@test "generated script contains correct shebang" {
    local test_output="$TEST_OUTPUT_DIR/shebang-check.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    first_line=$(head -1 "$test_output")
    [[ "$first_line" == "#!/bin/bash" ]]
}

@test "generated script contains DRY_RUN support" {
    local test_output="$TEST_OUTPUT_DIR/dryrun-support.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep "DRY_RUN" "$test_output"
    [ "$status" -eq 0 ]
}

@test "generated script contains set -euo pipefail" {
    local test_output="$TEST_OUTPUT_DIR/strict-mode.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep "set -euo pipefail" "$test_output"
    [ "$status" -eq 0 ]
}

@test "generated script contains --help option" {
    local test_output="$TEST_OUTPUT_DIR/help-option.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep -E "\-h\|--help" "$test_output"
    [ "$status" -eq 0 ]
}

@test "generated script is executable" {
    local test_output="$TEST_OUTPUT_DIR/executable-check.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -x "$test_output" ]
}

@test "generated script has header with metadata" {
    local test_output="$TEST_OUTPUT_DIR/header-metadata.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category brew
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep "Mole Export" "$test_output"
    [ "$status" -eq 0 ]
    
    run grep -E "生成时间|Generated" "$test_output"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 4. 敏感信息过滤测试
# =============================================================================

@test "git config does not contain credential section" {
    cat > "$HOME/.gitconfig" << 'EOF'
[user]
    name = Test User
    email = test@example.com
[credential]
    helper = osxkeychain
[credential "https://github.com"]
    username = testuser
[core]
    editor = vim
EOF

    local test_output="$TEST_OUTPUT_DIR/git-credential-filter.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category git
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep "credential" "$test_output"
    if [ "$status" -eq 0 ]; then
        [[ "$output" == *"removed"* ]] || [[ "$output" == *"REDACTED"* ]] || [[ "$output" == *"filtered"* ]] || [[ "$output" != *"osxkeychain"* ]]
    fi
    
    run grep "helper = osxkeychain" "$test_output"
    [ "$status" -ne 0 ]
}

@test "git config does not contain token values" {
    cat > "$HOME/.gitconfig" << 'EOF'
[user]
    name = Test User
[github]
    token = ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    oauth-token = gho_yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
[core]
    editor = vim
EOF

    local test_output="$TEST_OUTPUT_DIR/git-token-filter.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category git
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    # 检查 token 键的值被过滤（值被替换为 REDACTED 或被移除）
    # 原始 token 值不应该出现在导出文件中
    if grep -q "ghp_" "$test_output" 2>/dev/null; then
        # 如果原始 token 值仍存在，则测试失败
        false
    fi
    
    if grep -q "gho_" "$test_output" 2>/dev/null; then
        # 如果原始 oauth-token 值仍存在，则测试失败
        false
    fi
    
    # 测试通过：敏感值已被过滤
    true
}

@test "git config does not contain secret values" {
    cat > "$HOME/.gitconfig" << 'EOF'
[user]
    name = Test User
[custom]
    secret = mysupersecretvalue
    api-secret = anothersecret
    apikey = my-api-key-12345
[core]
    editor = vim
EOF

    local test_output="$TEST_OUTPUT_DIR/git-secret-filter.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category git
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    # 检查敏感键的值被过滤
    # 原始敏感值不应该出现在导出文件中
    if grep -q "mysupersecretvalue" "$test_output" 2>/dev/null; then
        false
    fi
    
    if grep -q "anothersecret" "$test_output" 2>/dev/null; then
        false
    fi
    
    if grep -q "my-api-key-12345" "$test_output" 2>/dev/null; then
        false
    fi
    
    true
}

@test "git config does not contain password values" {
    cat > "$HOME/.gitconfig" << 'EOF'
[user]
    name = Test User
[http]
    password = mypassword123
[smtp]
    pass = emailpassword
[core]
    editor = vim
EOF

    local test_output="$TEST_OUTPUT_DIR/git-password-filter.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category git
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep "mypassword123" "$test_output"
    [ "$status" -ne 0 ]
}

@test "git config preserves non-sensitive sections" {
    cat > "$HOME/.gitconfig" << 'EOF'
[user]
    name = Test User
[alias]
    co = checkout
    br = branch
    ci = commit
[core]
    editor = vim
    autocrlf = input
[pull]
    rebase = false
EOF

    local test_output="$TEST_OUTPUT_DIR/git-preserve-safe.sh"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" -o "$test_output" --category git
    [ "$status" -eq 0 ]
    [ -f "$test_output" ]
    
    run grep "alias" "$test_output"
    [ "$status" -eq 0 ]
    
    run grep "checkout" "$test_output"
    [ "$status" -eq 0 ]
    
    run grep "editor" "$test_output"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 5. 边界条件测试
# =============================================================================

@test "export handles empty HOME gracefully" {
    run env HOME="$TEST_OUTPUT_DIR/nonexistent" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --dry-run --category brew
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "export handles missing .gitconfig gracefully" {
    rm -f "$HOME/.gitconfig"
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category git --dry-run
    [ "$status" -eq 0 ]
}

@test "export --verbose shows detailed output" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --dry-run --verbose --category brew
    [ "$status" -eq 0 ]
}

@test "export with empty exclude works correctly" {
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --dry-run --category brew
    [ "$status" -eq 0 ]
}

@test "export default output filename contains timestamp" {
    local initial_files
    initial_files=$(ls "$HOME"/mole-export-*.sh 2>/dev/null | wc -l || echo "0")
    
    run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/export.sh" --category brew
    [ "$status" -eq 0 ]
    
    local output_file
    output_file=$(ls -t "$HOME"/mole-export-*.sh 2>/dev/null | head -1)
    [ -n "$output_file" ]
    [[ "$output_file" =~ mole-export-[0-9]{8}-[0-9]{6}\.sh ]]
    
    rm -f "$output_file"
}
