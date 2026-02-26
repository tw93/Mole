#!/bin/bash
# Mole - AI Programming Tools Export Module
# 导出 AI 编程工具配置（不包含敏感信息）
# 注意: 兼容 bash 3.2 (macOS 默认版本)
# 安全: 不导出 API keys, tokens, secrets 等敏感信息

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_AI_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_AI_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# Claude Code 检测函数
# =============================================================================

# 检测 Claude Code 配置是否存在
# 返回: 0 存在, 1 不存在
export_ai_claude_config_exists() {
    [[ -d "$HOME/.claude" ]]
}

# 获取 Claude Code 配置文件列表 (不包含敏感信息)
# 返回: 配置文件列表
export_ai_claude_get_config_files() {
    local files=""
    local claude_dir="$HOME/.claude"
    
    if [[ -d "$claude_dir" ]]; then
        # 只列出非敏感配置文件
        for f in "$claude_dir"/*.json "$claude_dir"/*.yaml "$claude_dir"/*.yml; do
            if [[ -f "$f" ]]; then
                local basename
                basename=$(basename "$f")
                # 跳过可能包含密钥的文件
                case "$basename" in
                    *credentials*|*token*|*secret*|*key*|*auth*)
                        continue
                        ;;
                    *)
                        files="${files}${basename}"$'\n'
                        ;;
                esac
            fi
        done
    fi
    
    echo "$files" | grep -v '^$' || echo ""
}

# 检测 Claude Code 是否安装
# 返回: 0 已安装, 1 未安装
export_ai_claude_cli_available() {
    export_command_exists claude
}

# =============================================================================
# GitHub Copilot 检测函数
# =============================================================================

# 检测 GitHub Copilot 配置是否存在
# 支持 VS Code, JetBrains, Vim/Neovim 等
# 返回: 0 存在, 1 不存在
export_ai_copilot_config_exists() {
    # VS Code Copilot
    [[ -d "$HOME/.config/github-copilot" ]] && return 0
    
    # GitHub CLI Copilot 扩展
    [[ -d "$HOME/.config/gh/copilot" ]] && return 0
    
    # Vim/Neovim Copilot
    [[ -d "$HOME/.config/nvim/pack/github/start/copilot.vim" ]] && return 0
    [[ -d "$HOME/.vim/pack/github/start/copilot.vim" ]] && return 0
    
    return 1
}

# 获取 GitHub Copilot 配置位置
# 返回: 配置位置描述
export_ai_copilot_get_locations() {
    local locations=""
    
    [[ -d "$HOME/.config/github-copilot" ]] && locations="${locations}~/.config/github-copilot"$'\n'
    [[ -d "$HOME/.config/gh/copilot" ]] && locations="${locations}~/.config/gh/copilot (gh extension)"$'\n'
    [[ -d "$HOME/.config/nvim/pack/github/start/copilot.vim" ]] && locations="${locations}Neovim plugin"$'\n'
    [[ -d "$HOME/.vim/pack/github/start/copilot.vim" ]] && locations="${locations}Vim plugin"$'\n'
    
    echo "$locations" | grep -v '^$' || echo ""
}

# 检测 gh copilot 扩展是否安装
# 返回: 0 已安装, 1 未安装
export_ai_gh_copilot_available() {
    if export_command_exists gh; then
        gh extension list 2>/dev/null | grep -q 'copilot'
        return $?
    fi
    return 1
}

# =============================================================================
# Codeium 检测函数
# =============================================================================

# 检测 Codeium 配置是否存在
# 返回: 0 存在, 1 不存在
export_ai_codeium_config_exists() {
    [[ -d "$HOME/.codeium" ]] || [[ -d "$HOME/.config/codeium" ]]
}

# 获取 Codeium 配置位置
# 返回: 配置位置
export_ai_codeium_get_location() {
    [[ -d "$HOME/.codeium" ]] && echo "~/.codeium" && return
    [[ -d "$HOME/.config/codeium" ]] && echo "~/.config/codeium" && return
    echo ""
}

# =============================================================================
# Tabnine 检测函数
# =============================================================================

# 检测 Tabnine 配置是否存在
# 返回: 0 存在, 1 不存在
export_ai_tabnine_config_exists() {
    [[ -d "$HOME/.tabnine" ]] || [[ -d "$HOME/.config/TabNine" ]]
}

# 获取 Tabnine 配置位置
# 返回: 配置位置
export_ai_tabnine_get_location() {
    [[ -d "$HOME/.tabnine" ]] && echo "~/.tabnine" && return
    [[ -d "$HOME/.config/TabNine" ]] && echo "~/.config/TabNine" && return
    echo ""
}

# =============================================================================
# Continue.dev 检测函数
# =============================================================================

# 检测 Continue 配置是否存在
# 返回: 0 存在, 1 不存在
export_ai_continue_config_exists() {
    [[ -d "$HOME/.continue" ]]
}

# 获取 Continue 配置文件
# 返回: 配置文件路径
export_ai_continue_get_config() {
    local config_file="$HOME/.continue/config.json"
    [[ -f "$config_file" ]] && echo "~/.continue/config.json" && return
    echo ""
}

# =============================================================================
# Aider 检测函数
# =============================================================================

# 检测 Aider 是否安装
# 返回: 0 已安装, 1 未安装
export_ai_aider_available() {
    export_command_exists aider
}

# 检测 Aider 配置文件是否存在
# 返回: 0 存在, 1 不存在
export_ai_aider_config_exists() {
    [[ -f "$HOME/.aider.conf.yml" ]] || \
    [[ -f "$HOME/.aider.model.settings.yml" ]] || \
    [[ -d "$HOME/.aider" ]]
}

# 获取 Aider 配置文件列表
# 返回: 配置文件列表
export_ai_aider_get_config_files() {
    local files=""
    
    [[ -f "$HOME/.aider.conf.yml" ]] && files="${files}~/.aider.conf.yml"$'\n'
    [[ -f "$HOME/.aider.model.settings.yml" ]] && files="${files}~/.aider.model.settings.yml"$'\n'
    [[ -d "$HOME/.aider" ]] && files="${files}~/.aider/"$'\n'
    
    echo "$files" | grep -v '^$' || echo ""
}

# =============================================================================
# Ollama 检测函数
# =============================================================================

# 检测 Ollama 是否安装
# 返回: 0 已安装, 1 未安装
export_ai_ollama_available() {
    export_command_exists ollama
}

# 获取 Ollama 已下载模型列表
# 返回: 模型名称列表
export_ai_ollama_get_models() {
    if export_ai_ollama_available; then
        # ollama list 输出格式: NAME ID SIZE MODIFIED
        ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || echo ""
    else
        echo ""
    fi
}

# 统计 Ollama 模型数量
# 参数: $1 - 模型列表
# 返回: 数量
export_ai_ollama_count() {
    local models="$1"
    if [[ -z "$models" ]]; then
        echo "0"
        return
    fi
    echo "$models" | wc -l | tr -d ' '
}

# =============================================================================
# Cursor 检测函数 (补充)
# =============================================================================

# 检测 Cursor 配置是否存在
# 返回: 0 存在, 1 不存在
export_ai_cursor_config_exists() {
    # macOS 路径
    [[ -d "$HOME/Library/Application Support/Cursor" ]] || \
    [[ -d "$HOME/.cursor" ]]
}

# 获取 Cursor 扩展数量 (如果有 cursor CLI)
# 返回: 扩展数量
export_ai_cursor_extensions_count() {
    if export_command_exists cursor; then
        cursor --list-extensions 2>/dev/null | wc -l | tr -d ' ' || echo "0"
    else
        echo "0"
    fi
}

# =============================================================================
# 主导出函数
# =============================================================================

# 主导出函数: 导出 AI 编程工具配置
# 参数: $1 - 输出文件路径
# 返回: 成功时输出项目数量到 stdout
# 副作用: 更新 EXPORT_STATS
export_ai() {
    local output_file="$1"
    local total_items=0
    local has_content=false
    
    export_log_info "Scanning AI programming tools..."
    
    # 检测各工具
    local claude_found=false copilot_found=false codeium_found=false
    local tabnine_found=false continue_found=false aider_found=false
    local ollama_models="" ollama_count=0 cursor_found=false
    
    # Claude Code
    if export_ai_claude_config_exists || export_ai_claude_cli_available; then
        claude_found=true
        total_items=$((total_items + 1))
        export_log_verbose "Claude Code: detected"
    fi
    
    # GitHub Copilot
    if export_ai_copilot_config_exists || export_ai_gh_copilot_available; then
        copilot_found=true
        total_items=$((total_items + 1))
        export_log_verbose "GitHub Copilot: detected"
    fi
    
    # Codeium
    if export_ai_codeium_config_exists; then
        codeium_found=true
        total_items=$((total_items + 1))
        export_log_verbose "Codeium: detected"
    fi
    
    # Tabnine
    if export_ai_tabnine_config_exists; then
        tabnine_found=true
        total_items=$((total_items + 1))
        export_log_verbose "Tabnine: detected"
    fi
    
    # Continue
    if export_ai_continue_config_exists; then
        continue_found=true
        total_items=$((total_items + 1))
        export_log_verbose "Continue: detected"
    fi
    
    # Aider
    if export_ai_aider_available || export_ai_aider_config_exists; then
        aider_found=true
        total_items=$((total_items + 1))
        export_log_verbose "Aider: detected"
    fi
    
    # Ollama
    if export_ai_ollama_available; then
        ollama_models=$(export_ai_ollama_get_models)
        ollama_count=$(export_ai_ollama_count "$ollama_models")
        total_items=$((total_items + ollama_count))
        export_log_verbose "Ollama: $ollama_count models"
    fi
    
    # Cursor
    if export_ai_cursor_config_exists; then
        cursor_found=true
        total_items=$((total_items + 1))
        export_log_verbose "Cursor: detected"
    fi
    
    if [[ $total_items -eq 0 ]]; then
        export_log_skipped "No AI programming tools detected"
        echo "0"
        return 0
    fi
    
    # 写入章节头
    export_write_section_start "$output_file" "AI" "AI Programming Tools" "${total_items} items"
    
    # 写入恢复提示
    cat >> "$output_file" << 'EOF'
# ⚠️  AI 编程工具恢复提示:
#     大部分 AI 工具需要重新登录或配置 API Key
#     以下仅记录工具配置位置，不包含敏感信息
#     请在新环境中重新进行身份验证
#

EOF
    
    # Claude Code
    if [[ "$claude_found" == "true" ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Claude Code
# ------------------------------------------------------------
EOF
        if export_ai_claude_cli_available; then
            echo "# CLI: claude (已安装)" >> "$output_file"
        fi
        if export_ai_claude_config_exists; then
            echo "# 配置目录: ~/.claude" >> "$output_file"
            local claude_files
            claude_files=$(export_ai_claude_get_config_files)
            if [[ -n "$claude_files" ]]; then
                echo "# 配置文件:" >> "$output_file"
                while IFS= read -r f; do
                    [[ -n "$f" ]] && echo "#   - $f" >> "$output_file"
                done <<< "$claude_files"
            fi
        fi
        echo "# 恢复: 运行 'claude' 并使用 Anthropic 账号登录" >> "$output_file"
        echo "#" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # GitHub Copilot
    if [[ "$copilot_found" == "true" ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# GitHub Copilot
# ------------------------------------------------------------
EOF
        local copilot_locations
        copilot_locations=$(export_ai_copilot_get_locations)
        if [[ -n "$copilot_locations" ]]; then
            echo "# 配置位置:" >> "$output_file"
            while IFS= read -r loc; do
                [[ -n "$loc" ]] && echo "#   - $loc" >> "$output_file"
            done <<< "$copilot_locations"
        fi
        if export_ai_gh_copilot_available; then
            echo "# gh copilot 扩展: 已安装" >> "$output_file"
        fi
        echo "# 恢复:" >> "$output_file"
        echo "#   - VS Code/IDE: 在扩展中重新登录 GitHub" >> "$output_file"
        echo "#   - gh copilot: gh auth login && gh extension install github/gh-copilot" >> "$output_file"
        echo "#" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Codeium
    if [[ "$codeium_found" == "true" ]]; then
        has_content=true
        local codeium_loc
        codeium_loc=$(export_ai_codeium_get_location)
        cat >> "$output_file" << EOF
# ------------------------------------------------------------
# Codeium
# ------------------------------------------------------------
# 配置目录: $codeium_loc
# 恢复: 在 IDE 中安装 Codeium 扩展并使用账号登录
#

EOF
    fi
    
    # Tabnine
    if [[ "$tabnine_found" == "true" ]]; then
        has_content=true
        local tabnine_loc
        tabnine_loc=$(export_ai_tabnine_get_location)
        cat >> "$output_file" << EOF
# ------------------------------------------------------------
# Tabnine
# ------------------------------------------------------------
# 配置目录: $tabnine_loc
# 恢复: 在 IDE 中安装 Tabnine 扩展并使用账号登录
#

EOF
    fi
    
    # Continue
    if [[ "$continue_found" == "true" ]]; then
        has_content=true
        local continue_config
        continue_config=$(export_ai_continue_get_config)
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Continue.dev
# ------------------------------------------------------------
# 配置目录: ~/.continue
EOF
        [[ -n "$continue_config" ]] && echo "# 配置文件: $continue_config" >> "$output_file"
        echo "# 恢复: 在 VS Code/JetBrains 中安装 Continue 扩展" >> "$output_file"
        echo "#       配置文件可从备份恢复 (注意移除 API keys)" >> "$output_file"
        echo "#" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Aider
    if [[ "$aider_found" == "true" ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Aider (AI Pair Programming)
# ------------------------------------------------------------
EOF
        if export_ai_aider_available; then
            echo "# CLI: aider (已安装)" >> "$output_file"
        fi
        local aider_files
        aider_files=$(export_ai_aider_get_config_files)
        if [[ -n "$aider_files" ]]; then
            echo "# 配置文件:" >> "$output_file"
            while IFS= read -r f; do
                [[ -n "$f" ]] && echo "#   - $f" >> "$output_file"
            done <<< "$aider_files"
        fi
        echo "# 恢复: pip install aider-chat && 配置 OPENAI_API_KEY 等环境变量" >> "$output_file"
        echo "#" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Ollama
    if [[ $ollama_count -gt 0 ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Ollama (本地 LLM)
# ------------------------------------------------------------
EOF
        echo "# 已下载模型 ($ollama_count 个):" >> "$output_file"
        while IFS= read -r model; do
            [[ -n "$model" ]] && echo "#   - $model" >> "$output_file"
        done <<< "$ollama_models"
        echo "#" >> "$output_file"
        
        # 生成可执行的恢复命令
        cat >> "$output_file" << 'EOF'
restore_ollama_models() {
    should_skip "ollama" && return 0
    if ! command_exists ollama; then
        log "⚠️  Ollama not installed, skipping model restore"
        log "    Install: brew install ollama"
        return 0
    fi
    log "🦙 Pulling Ollama models..."
EOF
        while IFS= read -r model; do
            [[ -n "$model" ]] && echo "    run 'ollama pull $model'" >> "$output_file"
        done <<< "$ollama_models"
        echo "}" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Cursor
    if [[ "$cursor_found" == "true" ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Cursor (AI-first Code Editor)
# ------------------------------------------------------------
# 配置目录: ~/Library/Application Support/Cursor 或 ~/.cursor
# 恢复: 下载 Cursor (https://cursor.sh) 并使用账号登录
#       扩展和设置会通过账号同步
#

EOF
    fi
    
    export_write_section_end "$output_file"
    
    # 更新统计
    export_add_stat "AI Tools" "$total_items" "items"
    
    export_log_success "AI Tools: $total_items items exported"
    
    # 输出数量供调用者使用
    echo "$total_items"
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_ai_dry_run() {
    local results=""
    local tool_count=0
    
    # Claude Code
    if export_ai_claude_config_exists || export_ai_claude_cli_available; then
        results="${results}Claude Code: detected"
        export_ai_claude_cli_available && results="${results} (CLI available)"
        results="${results}\n"
        tool_count=$((tool_count + 1))
    fi
    
    # GitHub Copilot
    if export_ai_copilot_config_exists || export_ai_gh_copilot_available; then
        results="${results}GitHub Copilot: detected"
        export_ai_gh_copilot_available && results="${results} (gh extension)"
        results="${results}\n"
        tool_count=$((tool_count + 1))
    fi
    
    # Codeium
    if export_ai_codeium_config_exists; then
        results="${results}Codeium: detected\n"
        tool_count=$((tool_count + 1))
    fi
    
    # Tabnine
    if export_ai_tabnine_config_exists; then
        results="${results}Tabnine: detected\n"
        tool_count=$((tool_count + 1))
    fi
    
    # Continue
    if export_ai_continue_config_exists; then
        results="${results}Continue: detected\n"
        tool_count=$((tool_count + 1))
    fi
    
    # Aider
    if export_ai_aider_available || export_ai_aider_config_exists; then
        results="${results}Aider: detected"
        export_ai_aider_available && results="${results} (CLI available)"
        results="${results}\n"
        tool_count=$((tool_count + 1))
    fi
    
    # Ollama
    if export_ai_ollama_available; then
        local ollama_models ollama_count
        ollama_models=$(export_ai_ollama_get_models)
        ollama_count=$(export_ai_ollama_count "$ollama_models")
        results="${results}Ollama: ${ollama_count} models\n"
        tool_count=$((tool_count + ollama_count))
    fi
    
    # Cursor
    if export_ai_cursor_config_exists; then
        results="${results}Cursor: detected\n"
        tool_count=$((tool_count + 1))
    fi
    
    if [[ $tool_count -eq 0 ]]; then
        echo "AI Tools: none detected"
        return 0
    fi
    
    echo "AI Tools Summary ($tool_count items):"
    echo -e "$results"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        if export_ai_ollama_available; then
            echo "  Ollama Models:"
            export_ai_ollama_get_models | while IFS= read -r model; do
                [[ -n "$model" ]] && echo "    $model"
            done
        fi
    fi
}
