#!/bin/bash
# Mole - Modern CLI Tools Export Module
# 检测并导出现代 CLI 工具安装状态
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_CLI_TOOLS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_CLI_TOOLS_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# 现代 CLI 工具列表定义
# =============================================================================

# 工具列表格式: "命令名:brew包名:描述"
# brew包名为空表示命令名与包名相同
MODERN_CLI_TOOLS="
bat::A cat clone with syntax highlighting
fd::Simple, fast alternative to find
rg:ripgrep:Fast grep replacement
fzf::Fuzzy finder
delta:git-delta:Syntax highlighting pager for git
eza::Modern replacement for ls
zoxide::Smarter cd command
atuin::Magical shell history
jq::JSON processor
yq::YAML processor
sd::sed replacement
hyperfine::Command-line benchmarking tool
starship::Cross-shell prompt
lazygit::Terminal UI for git
btop::Resource monitor
tldr:tealdeer:Simplified man pages
http:httpie:Modern HTTP client
curlie::curl frontend with httpie-like syntax
"

# =============================================================================
# 工具检测函数
# =============================================================================

# 解析工具定义
# 参数: $1 - 工具定义行 "命令:brew包:描述"
# 返回: 通过变量设置 TOOL_CMD, TOOL_BREW, TOOL_DESC
export_cli_parse_tool() {
    local line="$1"
    TOOL_CMD=$(echo "$line" | cut -d':' -f1)
    TOOL_BREW=$(echo "$line" | cut -d':' -f2)
    TOOL_DESC=$(echo "$line" | cut -d':' -f3-)
    
    # 如果 brew 包名为空，使用命令名
    [[ -z "$TOOL_BREW" ]] && TOOL_BREW="$TOOL_CMD"
}

# 检测单个工具是否已安装
# 参数: $1 - 命令名
# 返回: 0 已安装, 1 未安装
export_cli_tool_installed() {
    local cmd="$1"
    export_command_exists "$cmd"
}

# 检测工具是否通过 brew 安装
# 参数: $1 - brew 包名, $2 - brew 列表 (以换行分隔)
# 返回: 0 是, 1 否
export_cli_is_brew_managed() {
    local pkg="$1"
    local brew_list="$2"
    
    echo "$brew_list" | grep -qx "$pkg" 2>/dev/null
}

# 获取工具版本
# 参数: $1 - 命令名
# 返回: 版本号或 "unknown"
export_cli_get_version() {
    local cmd="$1"
    local version=""
    
    case "$cmd" in
        bat|fd|rg|eza|sd|hyperfine|starship|btop)
            version=$("$cmd" --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "")
            ;;
        fzf)
            version=$(fzf --version 2>/dev/null | awk '{print $1}' || echo "")
            ;;
        delta)
            version=$(delta --version 2>/dev/null | head -1 | awk '{print $2}' || echo "")
            ;;
        zoxide)
            version=$(zoxide --version 2>/dev/null | awk '{print $2}' || echo "")
            ;;
        atuin)
            version=$(atuin --version 2>/dev/null | awk '{print $2}' || echo "")
            ;;
        jq)
            version=$(jq --version 2>/dev/null | sed 's/jq-//' || echo "")
            ;;
        yq)
            version=$(yq --version 2>/dev/null | awk '{print $NF}' || echo "")
            ;;
        lazygit)
            version=$(lazygit --version 2>/dev/null | grep -oE 'version=[0-9.]+' | cut -d= -f2 || echo "")
            ;;
        tldr)
            version=$(tldr --version 2>/dev/null | head -1 || echo "")
            ;;
        http)
            version=$(http --version 2>/dev/null | head -1 | awk '{print $1}' || echo "")
            ;;
        curlie)
            version=$(curlie --version 2>/dev/null | head -1 | awk '{print $2}' || echo "")
            ;;
        *)
            version=$("$cmd" --version 2>/dev/null | head -1 || echo "")
            ;;
    esac
    
    echo "${version:-unknown}"
}

# =============================================================================
# 扫描函数
# =============================================================================

# 扫描所有现代 CLI 工具
# 参数: $1 - brew 列表 (可选)
# 返回: 工具状态列表 "命令|brew包|描述|已安装|brew管理|版本"
export_cli_scan_tools() {
    local brew_list="${1:-}"
    local results=""
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        export_cli_parse_tool "$line"
        [[ -z "$TOOL_CMD" ]] && continue
        
        local installed="no"
        local brew_managed="no"
        local version=""
        
        if export_cli_tool_installed "$TOOL_CMD"; then
            installed="yes"
            version=$(export_cli_get_version "$TOOL_CMD")
            
            if [[ -n "$brew_list" ]] && export_cli_is_brew_managed "$TOOL_BREW" "$brew_list"; then
                brew_managed="yes"
            fi
        fi
        
        results="${results}${TOOL_CMD}|${TOOL_BREW}|${TOOL_DESC}|${installed}|${brew_managed}|${version}"$'\n'
        
    done <<< "$MODERN_CLI_TOOLS"
    
    echo "$results"
}

# 统计已安装工具数量
# 参数: $1 - 扫描结果
# 返回: 数量
export_cli_count_installed() {
    local results="$1"
    echo "$results" | grep '|yes|' | wc -l | tr -d ' '
}

# 统计 brew 管理的工具数量
# 参数: $1 - 扫描结果
# 返回: 数量
export_cli_count_brew_managed() {
    local results="$1"
    echo "$results" | grep '|yes|yes|' | wc -l | tr -d ' '
}

# 获取未通过 brew 安装的工具列表
# 参数: $1 - 扫描结果
# 返回: 工具列表
export_cli_get_non_brew_tools() {
    local results="$1"
    echo "$results" | grep '|yes|no|' | cut -d'|' -f1-3
}

# 获取未安装的工具列表
# 参数: $1 - 扫描结果
# 返回: 工具列表
export_cli_get_not_installed() {
    local results="$1"
    echo "$results" | grep '|no|' | cut -d'|' -f1-3
}

# =============================================================================
# 主导出函数
# =============================================================================

# 主导出函数: 导出现代 CLI 工具状态
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_cli_tools() {
    local output_file="$1"
    
    export_log_info "Scanning modern CLI tools..."
    
    # 获取 brew 列表用于检测
    local brew_list=""
    if export_command_exists brew; then
        brew_list=$(brew list --formula 2>/dev/null || echo "")
    fi
    
    # 扫描所有工具
    local scan_results
    scan_results=$(export_cli_scan_tools "$brew_list")
    
    local installed_count brew_count
    installed_count=$(export_cli_count_installed "$scan_results")
    brew_count=$(export_cli_count_brew_managed "$scan_results")
    
    if [[ $installed_count -eq 0 ]]; then
        export_log_skipped "No modern CLI tools detected"
        return 0
    fi
    
    local non_brew_count=$((installed_count - brew_count))
    
    export_log_verbose "Found: $installed_count installed, $brew_count via brew"
    
    # 写入章节头
    export_write_section_start "$output_file" "CLI" "Modern CLI Tools" "${installed_count} installed"
    
    # 写入说明
    cat >> "$output_file" << EOF
# 现代 CLI 工具检测结果
# 已安装: $installed_count 个
# 通过 Homebrew 管理: $brew_count 个
# 需要单独安装: $non_brew_count 个
#

EOF
    
    # 写入已安装工具列表
    cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# 已安装的工具
# ------------------------------------------------------------
EOF
    
    while IFS='|' read -r cmd brew_pkg desc installed brew_managed version; do
        [[ -z "$cmd" ]] && continue
        [[ "$installed" != "yes" ]] && continue
        
        local status=""
        if [[ "$brew_managed" == "yes" ]]; then
            status="[brew] "
        else
            status="[other] "
        fi
        
        if [[ -n "$version" && "$version" != "unknown" ]]; then
            echo "#   ${status}${cmd} v${version} - $desc" >> "$output_file"
        else
            echo "#   ${status}${cmd} - $desc" >> "$output_file"
        fi
        
    done <<< "$scan_results"
    
    echo "#" >> "$output_file"
    
    # 如果有未通过 brew 安装的工具，生成安装命令
    if [[ $non_brew_count -gt 0 ]]; then
        cat >> "$output_file" << 'EOF'

# ------------------------------------------------------------
# 未通过 Homebrew 安装的工具 (建议使用 brew 统一管理)
# ------------------------------------------------------------
EOF
        echo "# 以下工具已安装但未通过 brew 管理，建议重新安装:" >> "$output_file"
        echo "#" >> "$output_file"
        
        local install_cmds=""
        while IFS='|' read -r cmd brew_pkg desc installed brew_managed version; do
            [[ -z "$cmd" ]] && continue
            [[ "$installed" != "yes" ]] && continue
            [[ "$brew_managed" == "yes" ]] && continue
            
            echo "#   brew install $brew_pkg  # $cmd - $desc" >> "$output_file"
            install_cmds="${install_cmds}$brew_pkg "
            
        done <<< "$scan_results"
        
        echo "#" >> "$output_file"
        
        # 生成一键安装命令
        if [[ -n "$install_cmds" ]]; then
            cat >> "$output_file" << EOF

# 一键安装命令:
#   brew install $install_cmds

EOF
        fi
    fi
    
    # 推荐安装但尚未安装的工具
    local not_installed
    not_installed=$(export_cli_get_not_installed "$scan_results")
    local not_installed_count=0
    [[ -n "$not_installed" ]] && not_installed_count=$(echo "$not_installed" | wc -l | tr -d ' ')
    
    if [[ $not_installed_count -gt 0 ]]; then
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# 推荐安装 (当前未安装)
# ------------------------------------------------------------
# 以下是现代开发环境常用的 CLI 工具:
#
EOF
        
        local recommend_cmds=""
        while IFS='|' read -r cmd brew_pkg desc; do
            [[ -z "$cmd" ]] && continue
            echo "#   brew install $brew_pkg  # $cmd - $desc" >> "$output_file"
            recommend_cmds="${recommend_cmds}$brew_pkg "
        done <<< "$not_installed"
        
        echo "#" >> "$output_file"
        
        if [[ -n "$recommend_cmds" ]]; then
            cat >> "$output_file" << EOF
# 一键安装推荐工具:
#   brew install $recommend_cmds

EOF
        fi
    fi
    
    # 生成可执行的恢复函数
    cat >> "$output_file" << 'EOF'
restore_cli_tools() {
    should_skip "cli_tools" && return 0
    if ! command_exists brew; then
        log "⚠️  Homebrew not installed, skipping CLI tools restore"
        return 0
    fi
    log "🔧 Installing modern CLI tools..."
    
EOF
    
    # 添加需要安装的工具
    local tools_to_install=""
    while IFS='|' read -r cmd brew_pkg desc installed brew_managed version; do
        [[ -z "$cmd" ]] && continue
        [[ "$installed" != "yes" ]] && continue
        [[ "$brew_managed" == "yes" ]] && continue
        tools_to_install="${tools_to_install} $brew_pkg"
    done <<< "$scan_results"
    
    if [[ -n "$tools_to_install" ]]; then
        echo "    run 'brew install$tools_to_install'" >> "$output_file"
    else
        echo "    log \"  All CLI tools already managed by Homebrew\"" >> "$output_file"
    fi
    
    echo "}" >> "$output_file"
    
    export_write_section_end "$output_file"
    
    # 更新统计
    export_add_stat "CLI Tools" "$installed_count" "installed ($brew_count via brew)"
    
    export_log_success "CLI Tools: $installed_count installed, $brew_count via brew"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_cli_tools_dry_run() {
    # 获取 brew 列表
    local brew_list=""
    if export_command_exists brew; then
        brew_list=$(brew list --formula 2>/dev/null || echo "")
    fi
    
    # 扫描所有工具
    local scan_results
    scan_results=$(export_cli_scan_tools "$brew_list")
    
    local installed_count brew_count total_count
    installed_count=$(export_cli_count_installed "$scan_results")
    brew_count=$(export_cli_count_brew_managed "$scan_results")
    total_count=$(echo "$MODERN_CLI_TOOLS" | grep -c '[a-z]' || echo "0")
    
    echo "Modern CLI Tools: $installed_count/$total_count installed, $brew_count via brew"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        echo ""
        echo "  Installed:"
        while IFS='|' read -r cmd brew_pkg desc installed brew_managed version; do
            [[ -z "$cmd" ]] && continue
            [[ "$installed" != "yes" ]] && continue
            
            local status=""
            [[ "$brew_managed" == "yes" ]] && status="[brew]" || status="[other]"
            
            if [[ -n "$version" && "$version" != "unknown" ]]; then
                printf "    %-8s %-12s v%s\n" "$status" "$cmd" "$version"
            else
                printf "    %-8s %-12s\n" "$status" "$cmd"
            fi
        done <<< "$scan_results"
        
        # 显示未安装的工具
        local not_installed
        not_installed=$(export_cli_get_not_installed "$scan_results")
        if [[ -n "$not_installed" ]]; then
            echo ""
            echo "  Not Installed (recommended):"
            while IFS='|' read -r cmd brew_pkg desc; do
                [[ -z "$cmd" ]] && continue
                printf "    %-12s %s\n" "$cmd" "$desc"
            done <<< "$not_installed"
        fi
    fi
}

# 获取所有检测到的 CLI 工具列表 (供其他模块使用)
# 返回: 每行一个工具名
export_cli_tools_get_list() {
    local brew_list=""
    if export_command_exists brew; then
        brew_list=$(brew list --formula 2>/dev/null || echo "")
    fi
    
    local scan_results
    scan_results=$(export_cli_scan_tools "$brew_list")
    
    while IFS='|' read -r cmd brew_pkg desc installed brew_managed version; do
        [[ -z "$cmd" ]] && continue
        [[ "$installed" == "yes" ]] && echo "$cmd"
    done <<< "$scan_results"
}
