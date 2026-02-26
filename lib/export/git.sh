#!/bin/bash
# Mole - Git Configuration Export Module
# 导出 Git 配置（.gitconfig, gh CLI 扩展, lazygit 配置）
# 安全过滤敏感信息（credentials, tokens, passwords）
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_GIT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_GIT_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# 敏感信息过滤模式
# =============================================================================

# 需要过滤的敏感配置键（正则表达式）
# 这些键的值会被替换为 <REDACTED>
# 包含: password, token, secret, key, auth 等敏感关键词
# 支持多种命名风格: camelCase, snake_case, kebab-case
EXPORT_GIT_SENSITIVE_KEYS='(credential|password|pass|passwd|token|secret|apikey|api_key|api-key|oauth|auth|bearer|privatekey|private_key|private-key|accesskey|access_key|access-key|signingkey|signing_key|signing-key|[a-z_-]*secret[a-z_-]*|[a-z_-]*token[a-z_-]*|[a-z_-]*password[a-z_-]*|[a-z_-]*key[a-z_-]*)'

# =============================================================================
# Git 配置检测函数
# =============================================================================

# 检测 Git 是否可用
# 返回: 0 可用, 1 不可用
export_git_available() {
    export_command_exists git
}

# 检测 .gitconfig 是否存在
# 返回: 0 存在, 1 不存在
export_git_config_exists() {
    export_file_exists "$HOME/.gitconfig"
}

# 检测 gh CLI 是否可用
# 返回: 0 可用, 1 不可用
export_git_gh_available() {
    export_command_exists gh
}

# 检测 lazygit 配置是否存在
# 返回: 配置文件路径或空
export_git_lazygit_config() {
    local config_path="$HOME/Library/Application Support/lazygit/config.yml"
    if [[ -f "$config_path" ]]; then
        echo "$config_path"
        return
    fi
    
    # 备用位置
    config_path="$HOME/.config/lazygit/config.yml"
    if [[ -f "$config_path" ]]; then
        echo "$config_path"
        return
    fi
    
    echo ""
}

# =============================================================================
# .gitconfig 安全过滤函数
# =============================================================================

# 过滤 .gitconfig 中的敏感信息
# 参数: $1 - gitconfig 内容
# 返回: 过滤后的内容
export_git_filter_sensitive() {
    local content="$1"
    
    # 过滤敏感键的值
    echo "$content" | sed -E "s/^([[:space:]]*${EXPORT_GIT_SENSITIVE_KEYS}[[:space:]]*=).*/\1 <REDACTED>/i"
}

# 读取并过滤 .gitconfig
# 返回: 过滤后的 .gitconfig 内容
export_git_get_filtered_config() {
    local gitconfig="$HOME/.gitconfig"
    if [[ ! -f "$gitconfig" ]]; then
        echo ""
        return
    fi
    
    local content
    content=$(cat "$gitconfig" 2>/dev/null || echo "")
    
    if [[ -z "$content" ]]; then
        echo ""
        return
    fi
    
    # 过滤 [credential] 整个节
    # 过滤敏感键值对
    local filtered=""
    local in_credential_section=false
    
    while IFS= read -r line; do
        # 检测 [credential] 节开始
        if [[ "$line" =~ ^\[credential ]]; then
            in_credential_section=true
            filtered="${filtered}# [credential] section removed for security"$'\n'
            continue
        fi
        
        # 检测其他节开始，退出 credential 节
        if [[ "$line" =~ ^\[ ]] && [[ ! "$line" =~ ^\[credential ]]; then
            in_credential_section=false
        fi
        
        # 跳过 credential 节内的所有行
        if [[ "$in_credential_section" == "true" ]]; then
            continue
        fi
        
        # 过滤敏感键值
        if echo "$line" | grep -qiE "^[[:space:]]*(${EXPORT_GIT_SENSITIVE_KEYS})[[:space:]]*="; then
            local key
            key=$(echo "$line" | sed 's/[[:space:]]*=.*//')
            filtered="${filtered}${key} = <REDACTED>"$'\n'
        else
            filtered="${filtered}${line}"$'\n'
        fi
    done < "$gitconfig"
    
    echo "$filtered"
}

# =============================================================================
# gh CLI 扩展函数
# =============================================================================

# 获取 gh CLI 扩展列表
# 返回: 每行一个扩展名
export_git_get_gh_extensions() {
    if export_git_gh_available; then
        gh extension list 2>/dev/null | awk '{print $1}' || echo ""
    else
        echo ""
    fi
}

# =============================================================================
# 统计函数
# =============================================================================

# 统计 .gitconfig 配置项数量（不含注释和空行）
# 参数: $1 - gitconfig 内容
# 返回: 配置项数量
export_git_count_config_items() {
    local content="$1"
    if [[ -z "$content" ]]; then
        echo "0"
    else
        echo "$content" | grep -cE '^[[:space:]]*[^#[:space:]]' || echo "0"
    fi
}

# 统计列表行数
# 参数: $1 - 多行文本
# 返回: 行数
export_git_count_lines() {
    local content="$1"
    if [[ -z "$content" ]]; then
        echo "0"
    else
        echo "$content" | grep -c . || echo "0"
    fi
}

# =============================================================================
# 主导出函数
# =============================================================================

# 主导出函数: 生成 Git 配置恢复脚本
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_git() {
    local output_file="$1"
    
    export_log_info "Exporting Git configuration..."
    
    local has_content=false
    local total_items=0
    
    # 检测各种配置
    local gitconfig_content=""
    local gh_extensions=""
    local lazygit_config=""
    
    # .gitconfig
    if export_git_config_exists; then
        gitconfig_content=$(export_git_get_filtered_config)
        local config_items
        config_items=$(export_git_count_config_items "$gitconfig_content")
        if [[ "$config_items" -gt 0 ]]; then
            export_log_verbose ".gitconfig: $config_items items (sensitive data filtered)"
            total_items=$((total_items + config_items))
            has_content=true
        fi
    else
        export_log_verbose ".gitconfig: not found"
    fi
    
    # gh CLI 扩展
    if export_git_gh_available; then
        gh_extensions=$(export_git_get_gh_extensions)
        local gh_count
        gh_count=$(export_git_count_lines "$gh_extensions")
        if [[ "$gh_count" -gt 0 ]]; then
            export_log_verbose "gh extensions: $gh_count"
            total_items=$((total_items + gh_count))
            has_content=true
        else
            export_log_verbose "gh extensions: none"
        fi
    else
        export_log_verbose "gh CLI: not installed"
    fi
    
    # lazygit 配置
    lazygit_config=$(export_git_lazygit_config)
    if [[ -n "$lazygit_config" ]]; then
        export_log_verbose "lazygit: config found"
        has_content=true
    else
        export_log_verbose "lazygit: not configured"
    fi
    
    if [[ "$has_content" == "false" ]]; then
        export_log_skipped "No Git configurations found"
        return 0
    fi
    
    # 写入章节头
    export_write_section_start "$output_file" "8" "Git Configuration" "$total_items items"
    
    # 写入函数开始
    export_write_function_start "$output_file" "setup_git_config" "git"
    
    cat >> "$output_file" << 'EOF'
    log "🔧 Setting up Git configuration..."
    
EOF
    
    # 写入 .gitconfig 恢复
    if [[ -n "$gitconfig_content" ]]; then
        cat >> "$output_file" << 'EOF'
    # 写入 .gitconfig (敏感信息已过滤，需手动补充)
    log "   Writing ~/.gitconfig..."
    if [[ ! -f "$HOME/.gitconfig" ]] || $DRY_RUN; then
        run 'cat > "$HOME/.gitconfig" << '\''GITCONFIG'\''
EOF
        
        echo "$gitconfig_content" >> "$output_file"
        
        cat >> "$output_file" << 'EOF'
GITCONFIG'
    else
        log "   ⚠️ ~/.gitconfig already exists, skipping"
    fi
    
    # 提示需要手动配置的敏感信息
    log ""
    log "   ⚠️ 以下配置需要手动设置:"
    log "      git config --global user.email 'your@email.com'"
    log "      git config --global user.signingkey 'YOUR_GPG_KEY'"
    log "      # 如需配置 credential helper:"
    log "      git config --global credential.helper osxkeychain"
    
EOF
    fi
    
    # 写入 gh CLI 扩展安装
    if [[ -n "$gh_extensions" ]]; then
        cat >> "$output_file" << 'EOF'
    # 安装 gh CLI 扩展
    log ""
    log "   Installing gh CLI extensions..."
    if command_exists gh; then
EOF
        
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            echo "        run \"gh extension install $ext\"" >> "$output_file"
        done <<< "$gh_extensions"
        
        cat >> "$output_file" << 'EOF'
    else
        log "   ⚠️ gh CLI not found, skipping extensions"
    fi
    
EOF
    fi
    
    # 写入 lazygit 配置提示
    if [[ -n "$lazygit_config" ]]; then
        cat >> "$output_file" << EOF
    # lazygit 配置
    log ""
    log "   lazygit 配置文件位置:"
    log "     - $lazygit_config"
    log "   请手动迁移此配置文件到新机器"
    
EOF
    fi
    
    export_write_function_end "$output_file"
    export_write_section_end "$output_file"
    
    # 更新统计
    local stats_desc=""
    if export_git_config_exists; then
        stats_desc="gitconfig"
    fi
    if [[ -n "$gh_extensions" ]]; then
        local gh_count
        gh_count=$(export_git_count_lines "$gh_extensions")
        if [[ "$gh_count" -gt 0 ]]; then
            [[ -n "$stats_desc" ]] && stats_desc="$stats_desc, "
            stats_desc="${stats_desc}${gh_count} gh-ext"
        fi
    fi
    if [[ -n "$lazygit_config" ]]; then
        [[ -n "$stats_desc" ]] && stats_desc="$stats_desc, "
        stats_desc="${stats_desc}lazygit"
    fi
    
    export_add_stat "Git" "$total_items" "$stats_desc"
    export_log_success "Git: configuration exported (sensitive data filtered)"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_git_dry_run() {
    local output=""
    local total=0
    
    # .gitconfig
    if export_git_config_exists; then
        local gitconfig_content
        gitconfig_content=$(export_git_get_filtered_config)
        local config_items
        config_items=$(export_git_count_config_items "$gitconfig_content")
        output="${output}.gitconfig: $config_items items\n"
        total=$((total + config_items))
    else
        output="${output}.gitconfig: not found\n"
    fi
    
    # gh CLI 扩展
    if export_git_gh_available; then
        local gh_extensions
        gh_extensions=$(export_git_get_gh_extensions)
        local gh_count
        gh_count=$(export_git_count_lines "$gh_extensions")
        output="${output}gh extensions: $gh_count\n"
        total=$((total + gh_count))
    else
        output="${output}gh CLI: not installed\n"
    fi
    
    # lazygit
    local lazygit_config
    lazygit_config=$(export_git_lazygit_config)
    if [[ -n "$lazygit_config" ]]; then
        output="${output}lazygit: configured\n"
    else
        output="${output}lazygit: not configured\n"
    fi
    
    echo -e "Git Configuration: $total items\n$output"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        if export_git_gh_available; then
            local gh_extensions
            gh_extensions=$(export_git_get_gh_extensions)
            if [[ -n "$gh_extensions" ]]; then
                echo ""
                echo "  gh CLI Extensions:"
                echo "$gh_extensions" | while IFS= read -r ext; do
                    [[ -n "$ext" ]] && echo "    $ext"
                done
            fi
        fi
        
        if export_git_config_exists; then
            echo ""
            echo "  Git Config (user section):"
            git config --global --list 2>/dev/null | grep -E '^user\.' | while IFS= read -r line; do
                # 过滤 email 显示
                if [[ "$line" =~ ^user\.email ]]; then
                    echo "    user.email = <configured>"
                else
                    echo "    $line"
                fi
            done
        fi
    fi
}
