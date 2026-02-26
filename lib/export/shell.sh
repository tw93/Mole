#!/bin/bash
# Mole - Shell Configuration Export Module
# 导出 Shell 配置文件信息（zsh, bash, fish, starship, oh-my-zsh 等）
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_SHELL_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_SHELL_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# Shell 配置检测函数
# =============================================================================

# 检测 Zsh 配置文件是否存在
# 返回: 存在的配置文件路径列表 (以换行分隔)
export_shell_detect_zsh_configs() {
    local configs=""
    
    [[ -f "$HOME/.zshrc" ]] && configs="${configs}$HOME/.zshrc"$'\n'
    [[ -f "$HOME/.zprofile" ]] && configs="${configs}$HOME/.zprofile"$'\n'
    [[ -f "$HOME/.zshenv" ]] && configs="${configs}$HOME/.zshenv"$'\n'
    [[ -f "$HOME/.zlogin" ]] && configs="${configs}$HOME/.zlogin"$'\n'
    
    echo "$configs"
}

# 检测 Bash 配置文件是否存在
# 返回: 存在的配置文件路径列表 (以换行分隔)
export_shell_detect_bash_configs() {
    local configs=""
    
    [[ -f "$HOME/.bashrc" ]] && configs="${configs}$HOME/.bashrc"$'\n'
    [[ -f "$HOME/.bash_profile" ]] && configs="${configs}$HOME/.bash_profile"$'\n'
    [[ -f "$HOME/.bash_login" ]] && configs="${configs}$HOME/.bash_login"$'\n'
    [[ -f "$HOME/.profile" ]] && configs="${configs}$HOME/.profile"$'\n'
    
    echo "$configs"
}

# 检测 Fish 配置是否存在
# 返回: 存在的配置文件路径
export_shell_detect_fish_config() {
    local fish_config="$HOME/.config/fish/config.fish"
    if [[ -f "$fish_config" ]]; then
        echo "$fish_config"
    else
        echo ""
    fi
}

# 检测 Starship 配置是否存在
# 返回: 存在的配置文件路径
export_shell_detect_starship_config() {
    local starship_config="$HOME/.config/starship.toml"
    if [[ -f "$starship_config" ]]; then
        echo "$starship_config"
    else
        echo ""
    fi
}

# 检测 Oh-My-Zsh 是否安装
# 返回: 0 已安装, 1 未安装
export_shell_omz_available() {
    export_dir_exists "$HOME/.oh-my-zsh"
}

# =============================================================================
# Oh-My-Zsh 配置解析函数
# =============================================================================

# 从 .zshrc 解析 Oh-My-Zsh 主题
# 返回: 主题名称
export_shell_parse_omz_theme() {
    local zshrc="$HOME/.zshrc"
    if [[ -f "$zshrc" ]]; then
        grep -E '^ZSH_THEME=' "$zshrc" 2>/dev/null | head -1 | sed 's/ZSH_THEME=["'\'']\?\([^"'\'']*\)["'\'']\?/\1/' || echo ""
    else
        echo ""
    fi
}

# 从 .zshrc 解析 Oh-My-Zsh 插件列表
# 返回: 插件列表 (空格分隔)
export_shell_parse_omz_plugins() {
    local zshrc="$HOME/.zshrc"
    if [[ ! -f "$zshrc" ]]; then
        echo ""
        return
    fi
    
    # 解析 plugins=(...) 格式，支持单行和多行
    local plugins=""
    local in_plugins=false
    
    while IFS= read -r line; do
        # 跳过注释行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # 检测 plugins=( 开始
        if [[ "$line" =~ ^[[:space:]]*plugins=\( ]]; then
            in_plugins=true
            # 提取同一行的插件
            local inline
            inline=$(echo "$line" | sed 's/.*plugins=(\([^)]*\)).*/\1/' | tr '\n' ' ')
            # 检查是否在同一行闭合
            if [[ "$line" =~ \) ]]; then
                echo "$inline" | tr -s ' ' | sed 's/^ *//;s/ *$//'
                return
            fi
            plugins="$inline"
            continue
        fi
        
        # 在 plugins 块内
        if [[ "$in_plugins" == "true" ]]; then
            # 检测 ) 结束
            if [[ "$line" =~ \) ]]; then
                local end_part
                end_part=$(echo "$line" | sed 's/\(.*\)).*/\1/')
                plugins="$plugins $end_part"
                in_plugins=false
                break
            else
                plugins="$plugins $line"
            fi
        fi
    done < "$zshrc"
    
    # 清理输出
    echo "$plugins" | tr -s ' \t\n' ' ' | sed 's/^ *//;s/ *$//'
}

# 获取 Oh-My-Zsh 自定义插件列表
# 返回: 自定义插件目录列表 (以换行分隔)
export_shell_get_omz_custom_plugins() {
    local custom_dir="$HOME/.oh-my-zsh/custom/plugins"
    if [[ -d "$custom_dir" ]]; then
        ls -1 "$custom_dir" 2>/dev/null | grep -v '^example$' || echo ""
    else
        echo ""
    fi
}

# 获取 Oh-My-Zsh 自定义主题列表
# 返回: 自定义主题文件列表 (以换行分隔)
export_shell_get_omz_custom_themes() {
    local custom_dir="$HOME/.oh-my-zsh/custom/themes"
    if [[ -d "$custom_dir" ]]; then
        ls -1 "$custom_dir" 2>/dev/null | sed 's/\.zsh-theme$//' || echo ""
    else
        echo ""
    fi
}

# =============================================================================
# 统计函数
# =============================================================================

# 统计配置文件数量
# 参数: $1 - 多行文本
# 返回: 非空行数
export_shell_count_configs() {
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

# 主导出函数: 生成 Shell 配置备份提示
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_shell() {
    local output_file="$1"
    
    export_log_info "Detecting Shell configurations..."
    
    local has_content=false
    local config_count=0
    
    # 检测各种 Shell 配置
    local zsh_configs=""
    local bash_configs=""
    local fish_config=""
    local starship_config=""
    local omz_theme=""
    local omz_plugins=""
    local omz_custom_plugins=""
    local omz_custom_themes=""
    
    # Zsh 配置
    zsh_configs=$(export_shell_detect_zsh_configs)
    local zsh_count
    zsh_count=$(export_shell_count_configs "$zsh_configs")
    if [[ "$zsh_count" -gt 0 ]]; then
        export_log_verbose "Zsh: $zsh_count config files"
        config_count=$((config_count + zsh_count))
        has_content=true
    fi
    
    # Bash 配置
    bash_configs=$(export_shell_detect_bash_configs)
    local bash_count
    bash_count=$(export_shell_count_configs "$bash_configs")
    if [[ "$bash_count" -gt 0 ]]; then
        export_log_verbose "Bash: $bash_count config files"
        config_count=$((config_count + bash_count))
        has_content=true
    fi
    
    # Fish 配置
    fish_config=$(export_shell_detect_fish_config)
    if [[ -n "$fish_config" ]]; then
        export_log_verbose "Fish: config found"
        config_count=$((config_count + 1))
        has_content=true
    fi
    
    # Starship 配置
    starship_config=$(export_shell_detect_starship_config)
    if [[ -n "$starship_config" ]]; then
        export_log_verbose "Starship: config found"
        config_count=$((config_count + 1))
        has_content=true
    fi
    
    # Oh-My-Zsh 配置
    if export_shell_omz_available; then
        omz_theme=$(export_shell_parse_omz_theme)
        omz_plugins=$(export_shell_parse_omz_plugins)
        omz_custom_plugins=$(export_shell_get_omz_custom_plugins)
        omz_custom_themes=$(export_shell_get_omz_custom_themes)
        
        export_log_verbose "Oh-My-Zsh: installed (theme: ${omz_theme:-default})"
        has_content=true
    fi
    
    if [[ "$has_content" == "false" ]]; then
        export_log_skipped "No Shell configurations found"
        return 0
    fi
    
    # 写入章节头
    export_write_section_start "$output_file" "7" "Shell Configuration" "$config_count configs"
    
    # 写入函数开始
    export_write_function_start "$output_file" "setup_shell_config" "shell"
    
    cat >> "$output_file" << 'EOF'
    log "🐚 Shell Configuration (Manual Migration Required)"
    log "   以下配置文件需要手动迁移到新机器："
    echo
EOF
    
    # 写入 Zsh 配置列表
    if [[ -n "$zsh_configs" ]]; then
        cat >> "$output_file" << 'EOF'
    log "   Zsh 配置文件:"
EOF
        while IFS= read -r config; do
            [[ -z "$config" ]] && continue
            echo "    log \"     - $config\"" >> "$output_file"
        done <<< "$zsh_configs"
        echo "" >> "$output_file"
    fi
    
    # 写入 Bash 配置列表
    if [[ -n "$bash_configs" ]]; then
        cat >> "$output_file" << 'EOF'
    log "   Bash 配置文件:"
EOF
        while IFS= read -r config; do
            [[ -z "$config" ]] && continue
            echo "    log \"     - $config\"" >> "$output_file"
        done <<< "$bash_configs"
        echo "" >> "$output_file"
    fi
    
    # 写入 Fish 配置
    if [[ -n "$fish_config" ]]; then
        cat >> "$output_file" << EOF
    log "   Fish 配置文件:"
    log "     - $fish_config"

EOF
    fi
    
    # 写入 Starship 配置
    if [[ -n "$starship_config" ]]; then
        cat >> "$output_file" << EOF
    log "   Starship 配置文件:"
    log "     - $starship_config"

EOF
    fi
    
    # 写入 Oh-My-Zsh 配置
    if export_shell_omz_available; then
        cat >> "$output_file" << 'EOF'
    log "   Oh-My-Zsh 配置:"
EOF
        
        if [[ -n "$omz_theme" ]]; then
            echo "    log \"     Theme: $omz_theme\"" >> "$output_file"
        fi
        
        if [[ -n "$omz_plugins" ]]; then
            echo "    log \"     Plugins: $omz_plugins\"" >> "$output_file"
        fi
        
        local custom_plugin_count
        custom_plugin_count=$(export_shell_count_configs "$omz_custom_plugins")
        if [[ "$custom_plugin_count" -gt 0 ]]; then
            echo "    log \"\"" >> "$output_file"
            echo "    log \"     Custom Plugins (需手动安装):\"" >> "$output_file"
            while IFS= read -r plugin; do
                [[ -z "$plugin" ]] && continue
                echo "    log \"       - $plugin\"" >> "$output_file"
            done <<< "$omz_custom_plugins"
        fi
        
        local custom_theme_count
        custom_theme_count=$(export_shell_count_configs "$omz_custom_themes")
        if [[ "$custom_theme_count" -gt 0 ]]; then
            echo "    log \"\"" >> "$output_file"
            echo "    log \"     Custom Themes (需手动迁移):\"" >> "$output_file"
            while IFS= read -r theme; do
                [[ -z "$theme" ]] && continue
                echo "    log \"       - $theme\"" >> "$output_file"
            done <<< "$omz_custom_themes"
        fi
        
        echo "" >> "$output_file"
        
        # 写入 Oh-My-Zsh 安装命令提示
        cat >> "$output_file" << 'EOF'
    log ""
    log "   💡 Oh-My-Zsh 安装命令:"
    log '      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

EOF
        
        # 常用自定义插件安装提示
        if [[ "$omz_custom_plugins" == *"zsh-autosuggestions"* ]] || [[ "$omz_custom_plugins" == *"zsh-syntax-highlighting"* ]]; then
            cat >> "$output_file" << 'EOF'
    log "   💡 常用自定义插件安装:"
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
EOF
            if [[ "$omz_custom_plugins" == *"zsh-autosuggestions"* ]]; then
                cat >> "$output_file" << 'EOF'
        log "      git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
EOF
            fi
            if [[ "$omz_custom_plugins" == *"zsh-syntax-highlighting"* ]]; then
                cat >> "$output_file" << 'EOF'
        log "      git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
EOF
            fi
            cat >> "$output_file" << 'EOF'
    fi
EOF
        fi
    fi
    
    # 写入备份建议
    cat >> "$output_file" << 'EOF'
    log ""
    log "   ⚠️ 建议使用以下命令备份配置文件:"
    log "      tar -czf shell-configs-backup.tar.gz ~/.zshrc ~/.zprofile ~/.bashrc ~/.bash_profile ~/.config/fish ~/.config/starship.toml 2>/dev/null || true"
EOF
    
    export_write_function_end "$output_file"
    export_write_section_end "$output_file"
    
    # 更新统计
    local stats_parts=""
    if [[ "$zsh_count" -gt 0 ]]; then
        stats_parts="zsh"
    fi
    if [[ "$bash_count" -gt 0 ]]; then
        [[ -n "$stats_parts" ]] && stats_parts="$stats_parts, "
        stats_parts="${stats_parts}bash"
    fi
    if [[ -n "$fish_config" ]]; then
        [[ -n "$stats_parts" ]] && stats_parts="$stats_parts, "
        stats_parts="${stats_parts}fish"
    fi
    if [[ -n "$starship_config" ]]; then
        [[ -n "$stats_parts" ]] && stats_parts="$stats_parts, "
        stats_parts="${stats_parts}starship"
    fi
    if export_shell_omz_available; then
        [[ -n "$stats_parts" ]] && stats_parts="$stats_parts, "
        stats_parts="${stats_parts}oh-my-zsh"
    fi
    
    export_add_stat "Shell" "$config_count" "configs ($stats_parts)"
    export_log_success "Shell: $config_count config files detected"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_shell_dry_run() {
    local output=""
    local total=0
    
    # Zsh
    local zsh_configs
    zsh_configs=$(export_shell_detect_zsh_configs)
    local zsh_count
    zsh_count=$(export_shell_count_configs "$zsh_configs")
    if [[ "$zsh_count" -gt 0 ]]; then
        output="${output}Zsh: $zsh_count config files\n"
        total=$((total + zsh_count))
    else
        output="${output}Zsh: not configured\n"
    fi
    
    # Bash
    local bash_configs
    bash_configs=$(export_shell_detect_bash_configs)
    local bash_count
    bash_count=$(export_shell_count_configs "$bash_configs")
    if [[ "$bash_count" -gt 0 ]]; then
        output="${output}Bash: $bash_count config files\n"
        total=$((total + bash_count))
    else
        output="${output}Bash: not configured\n"
    fi
    
    # Fish
    local fish_config
    fish_config=$(export_shell_detect_fish_config)
    if [[ -n "$fish_config" ]]; then
        output="${output}Fish: configured\n"
        total=$((total + 1))
    else
        output="${output}Fish: not configured\n"
    fi
    
    # Starship
    local starship_config
    starship_config=$(export_shell_detect_starship_config)
    if [[ -n "$starship_config" ]]; then
        output="${output}Starship: configured\n"
        total=$((total + 1))
    else
        output="${output}Starship: not configured\n"
    fi
    
    # Oh-My-Zsh
    if export_shell_omz_available; then
        local omz_theme
        omz_theme=$(export_shell_parse_omz_theme)
        local omz_plugins
        omz_plugins=$(export_shell_parse_omz_plugins)
        local plugin_count=0
        if [[ -n "$omz_plugins" ]]; then
            plugin_count=$(echo "$omz_plugins" | wc -w | tr -d ' ')
        fi
        output="${output}Oh-My-Zsh: theme=${omz_theme:-default}, $plugin_count plugins\n"
    else
        output="${output}Oh-My-Zsh: not installed\n"
    fi
    
    echo -e "Shell Configuration: $total configs\n$output"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        if [[ -n "$zsh_configs" ]]; then
            echo ""
            echo "  Zsh Config Files:"
            echo "$zsh_configs" | while IFS= read -r config; do
                [[ -n "$config" ]] && echo "    $config"
            done
        fi
        
        if export_shell_omz_available; then
            local omz_plugins
            omz_plugins=$(export_shell_parse_omz_plugins)
            if [[ -n "$omz_plugins" ]]; then
                echo ""
                echo "  Oh-My-Zsh Plugins:"
                echo "    $omz_plugins"
            fi
            
            local omz_custom_plugins
            omz_custom_plugins=$(export_shell_get_omz_custom_plugins)
            if [[ -n "$omz_custom_plugins" ]]; then
                echo ""
                echo "  Oh-My-Zsh Custom Plugins:"
                echo "$omz_custom_plugins" | while IFS= read -r plugin; do
                    [[ -n "$plugin" ]] && echo "    $plugin"
                done
            fi
        fi
    fi
}
