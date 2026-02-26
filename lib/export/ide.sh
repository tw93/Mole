#!/bin/bash
# Mole - IDE Extensions Export Module
# 导出各种 IDE 扩展和编辑器插件配置
# 支持: VSCode, Cursor, Windsurf, Zed, Neovim, Vim
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_IDE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_IDE_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# IDE 检测函数
# =============================================================================

# 检测 VSCode 是否可用
# 返回: 0 可用, 1 不可用
export_ide_vscode_available() {
    export_command_exists code
}

# 检测 Cursor 是否可用
# 返回: 0 可用, 1 不可用
export_ide_cursor_available() {
    export_command_exists cursor
}

# 检测 Windsurf 是否可用
# 返回: 0 可用, 1 不可用
export_ide_windsurf_available() {
    export_command_exists windsurf
}

# 检测 Zed 扩展目录是否存在
# 返回: 0 存在, 1 不存在
export_ide_zed_available() {
    export_dir_exists "$HOME/.config/zed/extensions/installed"
}

# 检测 Neovim 配置是否存在
# 返回: 0 存在, 1 不存在
export_ide_neovim_available() {
    export_dir_exists "$HOME/.config/nvim"
}

# 检测 Vim 配置是否存在
# 返回: 0 存在, 1 不存在
export_ide_vim_available() {
    export_dir_exists "$HOME/.vim" || export_file_exists "$HOME/.vimrc"
}

# =============================================================================
# 扩展列表获取函数
# =============================================================================

# 获取 VSCode 扩展列表
# 返回: 每行一个扩展 ID
export_ide_get_vscode_extensions() {
    if export_ide_vscode_available; then
        code --list-extensions 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 获取 Cursor 扩展列表
# 返回: 每行一个扩展 ID
export_ide_get_cursor_extensions() {
    if export_ide_cursor_available; then
        cursor --list-extensions 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 获取 Windsurf 扩展列表
# 返回: 每行一个扩展 ID
export_ide_get_windsurf_extensions() {
    if export_ide_windsurf_available; then
        windsurf --list-extensions 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 获取 Zed 扩展列表
# 返回: 每行一个扩展目录名
export_ide_get_zed_extensions() {
    local zed_ext_dir="$HOME/.config/zed/extensions/installed"
    if [[ -d "$zed_ext_dir" ]]; then
        ls -1 "$zed_ext_dir" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 获取 Neovim 插件管理器类型和配置路径
# 返回: "manager_type|config_path" 或空
export_ide_detect_neovim_plugin_manager() {
    local nvim_dir="$HOME/.config/nvim"
    
    # 检测 lazy.nvim
    if [[ -d "$nvim_dir/lazy" ]] || [[ -f "$nvim_dir/lua/plugins.lua" ]] || [[ -d "$nvim_dir/lua/plugins" ]]; then
        echo "lazy.nvim|$nvim_dir"
        return
    fi
    
    # 检测 packer.nvim
    if [[ -d "$HOME/.local/share/nvim/site/pack/packer" ]]; then
        echo "packer.nvim|$nvim_dir"
        return
    fi
    
    # 检测 vim-plug
    if [[ -f "$HOME/.local/share/nvim/site/autoload/plug.vim" ]]; then
        echo "vim-plug|$nvim_dir"
        return
    fi
    
    # 检测 dein.vim
    if [[ -d "$HOME/.cache/dein" ]]; then
        echo "dein.vim|$nvim_dir"
        return
    fi
    
    echo ""
}

# 获取 Vim 插件管理器类型和配置路径
# 返回: "manager_type|config_path" 或空
export_ide_detect_vim_plugin_manager() {
    # 检测 vim-plug
    if [[ -f "$HOME/.vim/autoload/plug.vim" ]]; then
        echo "vim-plug|$HOME/.vimrc"
        return
    fi
    
    # 检测 Vundle
    if [[ -d "$HOME/.vim/bundle/Vundle.vim" ]]; then
        echo "Vundle|$HOME/.vimrc"
        return
    fi
    
    # 检测 pathogen
    if [[ -f "$HOME/.vim/autoload/pathogen.vim" ]]; then
        echo "pathogen|$HOME/.vim/bundle"
        return
    fi
    
    echo ""
}

# =============================================================================
# 统计函数
# =============================================================================

# 统计列表行数
# 参数: $1 - 多行文本
# 返回: 行数
export_ide_count_lines() {
    local content="$1"
    if [[ -z "$content" ]]; then
        echo "0"
    else
        echo "$content" | grep -c . || echo "0"
    fi
}

# =============================================================================
# 恢复脚本生成函数
# =============================================================================

# 生成 VSCode 扩展安装循环脚本
# 参数: $1 - 输出文件路径, $2 - 扩展列表
export_ide_write_vscode_install() {
    local output_file="$1"
    local extensions="$2"
    
    cat >> "$output_file" << 'EOF'
    log "📝 Installing VSCode extensions..."
    if command_exists code; then
        local vscode_extensions=(
EOF
    
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        echo "            \"$ext\"" >> "$output_file"
    done <<< "$extensions"
    
    cat >> "$output_file" << 'EOF'
        )
        for ext in "${vscode_extensions[@]}"; do
            run "code --install-extension \"$ext\" --force"
        done
    else
        log "  ⚠️ VSCode not found, skipping extensions"
    fi
EOF
}

# 生成 Cursor 扩展安装循环脚本
# 参数: $1 - 输出文件路径, $2 - 扩展列表
export_ide_write_cursor_install() {
    local output_file="$1"
    local extensions="$2"
    
    cat >> "$output_file" << 'EOF'
    log "🖱️ Installing Cursor extensions..."
    if command_exists cursor; then
        local cursor_extensions=(
EOF
    
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        echo "            \"$ext\"" >> "$output_file"
    done <<< "$extensions"
    
    cat >> "$output_file" << 'EOF'
        )
        for ext in "${cursor_extensions[@]}"; do
            run "cursor --install-extension \"$ext\" --force"
        done
    else
        log "  ⚠️ Cursor not found, skipping extensions"
    fi
EOF
}

# 生成 Windsurf 扩展安装循环脚本
# 参数: $1 - 输出文件路径, $2 - 扩展列表
export_ide_write_windsurf_install() {
    local output_file="$1"
    local extensions="$2"
    
    cat >> "$output_file" << 'EOF'
    log "🏄 Installing Windsurf extensions..."
    if command_exists windsurf; then
        local windsurf_extensions=(
EOF
    
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        echo "            \"$ext\"" >> "$output_file"
    done <<< "$extensions"
    
    cat >> "$output_file" << 'EOF'
        )
        for ext in "${windsurf_extensions[@]}"; do
            run "windsurf --install-extension \"$ext\" --force"
        done
    else
        log "  ⚠️ Windsurf not found, skipping extensions"
    fi
EOF
}

# =============================================================================
# 主导出函数
# =============================================================================

# 主导出函数: 生成 IDE 扩展安装脚本
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_ide() {
    local output_file="$1"
    
    export_log_info "Exporting IDE extensions..."
    
    local total_count=0
    local has_content=false
    
    # 收集各 IDE 扩展
    local vscode_ext=""
    local cursor_ext=""
    local windsurf_ext=""
    local zed_ext=""
    local nvim_info=""
    local vim_info=""
    
    # VSCode
    if export_ide_vscode_available; then
        vscode_ext=$(export_ide_get_vscode_extensions)
        local vscode_count
        vscode_count=$(export_ide_count_lines "$vscode_ext")
        if [[ "$vscode_count" -gt 0 ]]; then
            export_log_verbose "VSCode: $vscode_count extensions"
            total_count=$((total_count + vscode_count))
            has_content=true
        fi
    else
        export_log_verbose "VSCode: not installed"
    fi
    
    # Cursor
    if export_ide_cursor_available; then
        cursor_ext=$(export_ide_get_cursor_extensions)
        local cursor_count
        cursor_count=$(export_ide_count_lines "$cursor_ext")
        if [[ "$cursor_count" -gt 0 ]]; then
            export_log_verbose "Cursor: $cursor_count extensions"
            total_count=$((total_count + cursor_count))
            has_content=true
        fi
    else
        export_log_verbose "Cursor: not installed"
    fi
    
    # Windsurf
    if export_ide_windsurf_available; then
        windsurf_ext=$(export_ide_get_windsurf_extensions)
        local windsurf_count
        windsurf_count=$(export_ide_count_lines "$windsurf_ext")
        if [[ "$windsurf_count" -gt 0 ]]; then
            export_log_verbose "Windsurf: $windsurf_count extensions"
            total_count=$((total_count + windsurf_count))
            has_content=true
        fi
    else
        export_log_verbose "Windsurf: not installed"
    fi
    
    # Zed
    if export_ide_zed_available; then
        zed_ext=$(export_ide_get_zed_extensions)
        local zed_count
        zed_count=$(export_ide_count_lines "$zed_ext")
        if [[ "$zed_count" -gt 0 ]]; then
            export_log_verbose "Zed: $zed_count extensions"
            total_count=$((total_count + zed_count))
            has_content=true
        fi
    else
        export_log_verbose "Zed: not installed or no extensions"
    fi
    
    # Neovim
    if export_ide_neovim_available; then
        nvim_info=$(export_ide_detect_neovim_plugin_manager)
        if [[ -n "$nvim_info" ]]; then
            export_log_verbose "Neovim: detected (${nvim_info%%|*})"
            has_content=true
        else
            export_log_verbose "Neovim: config found, no plugin manager detected"
            nvim_info="manual|$HOME/.config/nvim"
            has_content=true
        fi
    else
        export_log_verbose "Neovim: not configured"
    fi
    
    # Vim
    if export_ide_vim_available; then
        vim_info=$(export_ide_detect_vim_plugin_manager)
        if [[ -n "$vim_info" ]]; then
            export_log_verbose "Vim: detected (${vim_info%%|*})"
            has_content=true
        else
            export_log_verbose "Vim: config found, no plugin manager detected"
            vim_info="manual|$HOME/.vim"
            has_content=true
        fi
    else
        export_log_verbose "Vim: not configured"
    fi
    
    if [[ "$has_content" == "false" ]]; then
        export_log_skipped "No IDE configurations found"
        return 0
    fi
    
    # 写入章节头
    export_write_section_start "$output_file" "6" "IDE Extensions" "$total_count extensions"
    
    # 写入函数开始
    export_write_function_start "$output_file" "install_ide_extensions" "ide"
    
    # 写入 VSCode 扩展安装
    local vscode_count=0
    if [[ -n "$vscode_ext" ]]; then
        vscode_count=$(export_ide_count_lines "$vscode_ext")
        if [[ "$vscode_count" -gt 0 ]]; then
            export_ide_write_vscode_install "$output_file" "$vscode_ext"
            echo "" >> "$output_file"
        fi
    fi
    
    # 写入 Cursor 扩展安装
    local cursor_count=0
    if [[ -n "$cursor_ext" ]]; then
        cursor_count=$(export_ide_count_lines "$cursor_ext")
        if [[ "$cursor_count" -gt 0 ]]; then
            export_ide_write_cursor_install "$output_file" "$cursor_ext"
            echo "" >> "$output_file"
        fi
    fi
    
    # 写入 Windsurf 扩展安装
    local windsurf_count=0
    if [[ -n "$windsurf_ext" ]]; then
        windsurf_count=$(export_ide_count_lines "$windsurf_ext")
        if [[ "$windsurf_count" -gt 0 ]]; then
            export_ide_write_windsurf_install "$output_file" "$windsurf_ext"
            echo "" >> "$output_file"
        fi
    fi
    
    # 写入 Zed 扩展注释 (Zed 扩展需要手动安装)
    local zed_count=0
    if [[ -n "$zed_ext" ]]; then
        zed_count=$(export_ide_count_lines "$zed_ext")
        if [[ "$zed_count" -gt 0 ]]; then
            cat >> "$output_file" << 'EOF'
    # Zed 扩展需要通过 Zed 内置的扩展管理器安装
    # 已安装的扩展列表:
EOF
            while IFS= read -r ext; do
                [[ -z "$ext" ]] && continue
                echo "    #   - $ext" >> "$output_file"
            done <<< "$zed_ext"
            echo "" >> "$output_file"
        fi
    fi
    
    # 写入 Neovim 配置注释
    if [[ -n "$nvim_info" ]]; then
        local nvim_manager="${nvim_info%%|*}"
        local nvim_path="${nvim_info##*|}"
        cat >> "$output_file" << EOF
    # Neovim 配置 (插件管理器: $nvim_manager)
    # 配置目录: $nvim_path
    # 需要手动迁移配置文件后运行插件安装命令
EOF
        echo "" >> "$output_file"
    fi
    
    # 写入 Vim 配置注释
    if [[ -n "$vim_info" ]]; then
        local vim_manager="${vim_info%%|*}"
        local vim_path="${vim_info##*|}"
        cat >> "$output_file" << EOF
    # Vim 配置 (插件管理器: $vim_manager)
    # 配置路径: $vim_path
    # 需要手动迁移配置文件后运行插件安装命令
EOF
        echo "" >> "$output_file"
    fi
    
    export_write_function_end "$output_file"
    export_write_section_end "$output_file"
    
    # 更新统计
    local stats_desc="extensions"
    if [[ "$vscode_count" -gt 0 ]]; then
        stats_desc="${vscode_count} VSCode"
    fi
    if [[ "$cursor_count" -gt 0 ]]; then
        [[ "$stats_desc" != "extensions" ]] && stats_desc="$stats_desc, "
        [[ "$stats_desc" == "extensions" ]] && stats_desc=""
        stats_desc="${stats_desc}${cursor_count} Cursor"
    fi
    if [[ "$windsurf_count" -gt 0 ]]; then
        [[ -n "$stats_desc" ]] && stats_desc="$stats_desc, "
        stats_desc="${stats_desc}${windsurf_count} Windsurf"
    fi
    if [[ "$zed_count" -gt 0 ]]; then
        [[ -n "$stats_desc" ]] && stats_desc="$stats_desc, "
        stats_desc="${stats_desc}${zed_count} Zed"
    fi
    
    export_add_stat "IDE" "$total_count" "$stats_desc"
    export_log_success "IDE: $total_count extensions exported"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_ide_dry_run() {
    local output=""
    local total=0
    
    # VSCode
    if export_ide_vscode_available; then
        local vscode_ext
        vscode_ext=$(export_ide_get_vscode_extensions)
        local vscode_count
        vscode_count=$(export_ide_count_lines "$vscode_ext")
        output="${output}VSCode: $vscode_count extensions\n"
        total=$((total + vscode_count))
    else
        output="${output}VSCode: not installed\n"
    fi
    
    # Cursor
    if export_ide_cursor_available; then
        local cursor_ext
        cursor_ext=$(export_ide_get_cursor_extensions)
        local cursor_count
        cursor_count=$(export_ide_count_lines "$cursor_ext")
        output="${output}Cursor: $cursor_count extensions\n"
        total=$((total + cursor_count))
    else
        output="${output}Cursor: not installed\n"
    fi
    
    # Windsurf
    if export_ide_windsurf_available; then
        local windsurf_ext
        windsurf_ext=$(export_ide_get_windsurf_extensions)
        local windsurf_count
        windsurf_count=$(export_ide_count_lines "$windsurf_ext")
        output="${output}Windsurf: $windsurf_count extensions\n"
        total=$((total + windsurf_count))
    else
        output="${output}Windsurf: not installed\n"
    fi
    
    # Zed
    if export_ide_zed_available; then
        local zed_ext
        zed_ext=$(export_ide_get_zed_extensions)
        local zed_count
        zed_count=$(export_ide_count_lines "$zed_ext")
        output="${output}Zed: $zed_count extensions\n"
        total=$((total + zed_count))
    else
        output="${output}Zed: not installed\n"
    fi
    
    # Neovim
    if export_ide_neovim_available; then
        local nvim_info
        nvim_info=$(export_ide_detect_neovim_plugin_manager)
        if [[ -n "$nvim_info" ]]; then
            output="${output}Neovim: ${nvim_info%%|*}\n"
        else
            output="${output}Neovim: config found (manual)\n"
        fi
    else
        output="${output}Neovim: not configured\n"
    fi
    
    # Vim
    if export_ide_vim_available; then
        local vim_info
        vim_info=$(export_ide_detect_vim_plugin_manager)
        if [[ -n "$vim_info" ]]; then
            output="${output}Vim: ${vim_info%%|*}\n"
        else
            output="${output}Vim: config found (manual)\n"
        fi
    else
        output="${output}Vim: not configured\n"
    fi
    
    echo -e "IDE Extensions: $total total\n$output"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        if export_ide_vscode_available; then
            local vscode_ext
            vscode_ext=$(export_ide_get_vscode_extensions)
            if [[ -n "$vscode_ext" ]]; then
                echo ""
                echo "  VSCode Extensions:"
                echo "$vscode_ext" | head -10 | while IFS= read -r ext; do
                    [[ -n "$ext" ]] && echo "    $ext"
                done
                local vscode_count
                vscode_count=$(export_ide_count_lines "$vscode_ext")
                local remaining=$((vscode_count - 10))
                [[ $remaining -gt 0 ]] && echo "    ... and $remaining more"
            fi
        fi
    fi
}
