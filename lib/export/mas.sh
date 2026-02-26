#!/bin/bash
# Mole - Mac App Store Export Module
# 导出 Mac App Store 已安装应用到可执行安装脚本
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_MAS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_MAS_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# Mac App Store 导出函数
# =============================================================================

# 检测 mas-cli 是否可用
# 返回: 0 可用, 1 不可用
export_mas_available() {
    export_command_exists mas
}

# 获取已安装的 MAS 应用列表
# 返回: 每行格式 "app_id app_name"
export_mas_get_apps() {
    mas list 2>/dev/null || echo ""
}

# 解析 mas list 输出为应用列表
# 参数: $1 - mas list 原始输出
# 返回: 应用数量
export_mas_count_apps() {
    local mas_output="$1"
    local count=0
    
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done <<< "$mas_output"
    
    echo "$count"
}

# 从 mas list 输出解析应用 ID
# 参数: $1 - mas list 单行输出
# 返回: 应用 ID
export_mas_parse_id() {
    local line="$1"
    echo "$line" | awk '{print $1}'
}

# 从 mas list 输出解析应用名称
# 参数: $1 - mas list 单行输出
# 返回: 应用名称
export_mas_parse_name() {
    local line="$1"
    # mas list 格式: "1234567890  App Name (1.2.3)"
    # 提取 ID 后的名称部分，去掉版本号
    echo "$line" | sed 's/^[0-9]*[[:space:]]*//' | sed 's/[[:space:]]*([^)]*)[[:space:]]*$//'
}

# 主导出函数: 生成 MAS 安装脚本
# 参数: $1 - 输出文件路径
# 返回: 成功时输出应用数量到 stdout，失败返回 0
# 副作用: 更新 EXPORT_STATS
export_mas() {
    local output_file="$1"
    
    # 检测 mas-cli 是否存在
    if ! export_mas_available; then
        export_log_skipped "mas-cli not installed (brew install mas)"
        echo "0"
        return 0
    fi
    
    export_log_info "Exporting Mac App Store apps..."
    
    # 获取已安装应用列表
    local mas_output
    mas_output=$(export_mas_get_apps)
    
    if [[ -z "$mas_output" ]]; then
        export_log_warning "No Mac App Store apps found"
        echo "0"
        return 0
    fi
    
    # 统计应用数量
    local app_count
    app_count=$(export_mas_count_apps "$mas_output")
    
    export_log_verbose "Found: $app_count apps"
    
    # 写入章节头
    export_write_section_start "$output_file" "2" "Mac App Store" "$app_count apps"
    
    # 写入安装函数
    export_write_function_start "$output_file" "install_mas_apps" "mas"
    
    # 写入 mas-cli 安装检测
    cat >> "$output_file" << 'EOF'
    log "🍎 Installing Mac App Store apps..."
    
    # 检测并安装 mas-cli
    if ! command_exists mas; then
        if command_exists brew; then
            log "  Installing mas-cli..."
            run 'brew install mas'
        else
            log "  ⚠ mas-cli not available, skipping App Store apps"
            return 0
        fi
    fi
    
    # 检查 App Store 登录状态
    if ! mas account > /dev/null 2>&1; then
        log "  ⚠ Not signed in to App Store. Please sign in manually."
        log "  After signing in, run this section again."
        return 0
    fi
    
EOF
    
    # 生成 mas install 命令
    echo "    # 安装应用" >> "$output_file"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local app_id app_name
        app_id=$(export_mas_parse_id "$line")
        app_name=$(export_mas_parse_name "$line")
        
        # 生成幂等安装命令
        cat >> "$output_file" << EOF
    mas list | grep -q "^${app_id}" || run "mas install ${app_id}"  # ${app_name}
EOF
    done <<< "$mas_output"
    
    export_write_function_end "$output_file"
    export_write_section_end "$output_file"
    
    # 更新统计
    export_add_stat "Mac App Store" "$app_count" "apps"
    
    export_log_success "Mac App Store: $app_count apps"
    
    # 输出数量供调用者使用
    echo "$app_count"
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_mas_dry_run() {
    if ! export_mas_available; then
        echo "Mac App Store: mas-cli not installed"
        return 0
    fi
    
    local mas_output
    mas_output=$(export_mas_get_apps)
    
    if [[ -z "$mas_output" ]]; then
        echo "Mac App Store: no apps"
        return 0
    fi
    
    local app_count
    app_count=$(export_mas_count_apps "$mas_output")
    
    echo "Mac App Store: $app_count apps"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        echo ""
        echo "  Apps:"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local app_id app_name
            app_id=$(export_mas_parse_id "$line")
            app_name=$(export_mas_parse_name "$line")
            echo "    $app_name ($app_id)"
        done <<< "$mas_output" | head -20
        
        local remaining=$((app_count - 20))
        [[ $remaining -gt 0 ]] && echo "    ... and $remaining more"
    fi
}

# 获取已安装 MAS 应用的 ID 列表 (供其他模块使用)
# 返回: 每行一个应用 ID
export_mas_get_app_ids() {
    if ! export_mas_available; then
        return 0
    fi
    
    local mas_output
    mas_output=$(export_mas_get_apps)
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        export_mas_parse_id "$line"
    done <<< "$mas_output"
}
