#!/bin/bash
# Mole - Homebrew Export Module
# 导出 Homebrew formulae, casks, taps 到可执行安装脚本
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_BREW_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_BREW_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# Homebrew 导出函数
# =============================================================================

# 检测 Homebrew 是否可用
# 返回: 0 可用, 1 不可用
export_brew_available() {
    export_command_exists brew
}

# 获取 Homebrew Brewfile 内容
# 返回: Brewfile 格式的内容
export_brew_get_brewfile() {
    brew bundle dump --file=- 2>/dev/null || echo ""
}

# 统计 Brewfile 中各类型数量
# 参数: $1 - Brewfile 内容
# 返回: "formulae_count cask_count tap_count" (空格分隔)
export_brew_count_items() {
    local brewfile="$1"
    local formulae_count=0
    local cask_count=0
    local tap_count=0
    
    while IFS= read -r line; do
        case "$line" in
            brew\ *)
                formulae_count=$((formulae_count + 1))
                ;;
            cask\ *)
                cask_count=$((cask_count + 1))
                ;;
            tap\ *)
                tap_count=$((tap_count + 1))
                ;;
        esac
    done <<< "$brewfile"
    
    echo "$formulae_count $cask_count $tap_count"
}

# 获取所有已安装的 cask 名称列表
# 返回: 每行一个 cask 名称
export_brew_get_cask_list() {
    brew list --cask 2>/dev/null || echo ""
}

# 检查包是否已通过 brew cask 安装
# 参数: $1 - cask 名称, $2 - cask 列表 (以换行分隔)
# 返回: 0 已安装, 1 未安装
export_brew_is_cask_installed() {
    local cask_name="$1"
    local cask_list="$2"
    
    while IFS= read -r installed; do
        [[ "$installed" == "$cask_name" ]] && return 0
    done <<< "$cask_list"
    
    return 1
}

# 主导出函数: 生成 Homebrew 安装脚本
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_brew() {
    local output_file="$1"
    
    # 检测 brew 是否存在
    if ! export_brew_available; then
        export_log_skipped "Homebrew not installed"
        return 0
    fi
    
    export_log_info "Exporting Homebrew packages..."
    
    # 获取 Brewfile 内容
    local brewfile
    brewfile=$(export_brew_get_brewfile)
    
    if [[ -z "$brewfile" ]]; then
        export_log_warning "No Homebrew packages found"
        return 0
    fi
    
    # 统计各类型数量
    local counts
    counts=$(export_brew_count_items "$brewfile")
    local formulae_count cask_count tap_count
    read -r formulae_count cask_count tap_count <<< "$counts"
    
    local total_count=$((formulae_count + cask_count))
    local stats="${formulae_count} formulae, ${cask_count} casks"
    
    export_log_verbose "Found: $stats, $tap_count taps"
    
    # 写入章节头
    export_write_section_start "$output_file" "1" "Homebrew" "$stats"
    
    # 写入安装函数
    export_write_function_start "$output_file" "install_homebrew" "brew"
    
    # 写入 Homebrew 安装检测
    cat >> "$output_file" << 'EOF'
    log "📦 Installing Homebrew packages..."
    
    # 检测并安装 Homebrew
    if ! command_exists brew; then
        log "  Installing Homebrew..."
        run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        
        # 设置 PATH (Apple Silicon)
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
    fi
    
    # 使用 brew bundle 安装
    run 'brew bundle --file=- <<BREWFILE
EOF
    
    # 写入 Brewfile 内容
    echo "$brewfile" >> "$output_file"
    
    # 结束 heredoc 和函数
    cat >> "$output_file" << 'EOF'
BREWFILE'
EOF
    
    export_write_function_end "$output_file"
    export_write_section_end "$output_file"
    
    # 更新统计
    export_add_stat "Homebrew" "$total_count" "packages ($stats)"
    
    export_log_success "Homebrew: $stats"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_brew_dry_run() {
    if ! export_brew_available; then
        echo "Homebrew: not installed"
        return 0
    fi
    
    local brewfile
    brewfile=$(export_brew_get_brewfile)
    
    if [[ -z "$brewfile" ]]; then
        echo "Homebrew: no packages"
        return 0
    fi
    
    local counts
    counts=$(export_brew_count_items "$brewfile")
    local formulae_count cask_count tap_count
    read -r formulae_count cask_count tap_count <<< "$counts"
    
    echo "Homebrew: ${formulae_count} formulae, ${cask_count} casks, ${tap_count} taps"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        echo ""
        echo "  Taps:"
        echo "$brewfile" | grep "^tap " | sed 's/^tap "\([^"]*\)".*/    \1/'
        echo ""
        echo "  Formulae:"
        echo "$brewfile" | grep "^brew " | sed 's/^brew "\([^"]*\)".*/    \1/' | head -20
        local remaining=$((formulae_count - 20))
        [[ $remaining -gt 0 ]] && echo "    ... and $remaining more"
        echo ""
        echo "  Casks:"
        echo "$brewfile" | grep "^cask " | sed 's/^cask "\([^"]*\)".*/    \1/' | head -20
        remaining=$((cask_count - 20))
        [[ $remaining -gt 0 ]] && echo "    ... and $remaining more"
    fi
}
