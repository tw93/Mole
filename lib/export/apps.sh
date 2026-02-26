#!/bin/bash
# Mole - Applications Scan Export Module
# 扫描 /Applications 和 ~/Applications 目录中的手动安装应用
# 过滤已通过 brew cask 和 mas 管理的应用，尝试获取官网链接
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_APPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_APPS_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# Applications 扫描函数
# =============================================================================

# 获取所有 .app 应用列表
# 返回: 每行一个应用路径
export_apps_scan_directories() {
    local apps=""
    
    # 扫描 /Applications
    if [[ -d "/Applications" ]]; then
        for app in /Applications/*.app; do
            [[ -d "$app" ]] && apps="${apps}${app}"$'\n'
        done
    fi
    
    # 扫描 ~/Applications
    if [[ -d "$HOME/Applications" ]]; then
        for app in "$HOME/Applications"/*.app; do
            [[ -d "$app" ]] && apps="${apps}${app}"$'\n'
        done
    fi
    
    echo "$apps"
}

# 从应用路径获取应用名称
# 参数: $1 - 应用路径
# 返回: 应用名称 (不含 .app 后缀)
export_apps_get_name() {
    local app_path="$1"
    local name
    name=$(basename "$app_path" .app)
    echo "$name"
}

# 从 Info.plist 获取 Bundle ID
# 参数: $1 - 应用路径
# 返回: Bundle ID 或空
export_apps_get_bundle_id() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    
    if [[ -f "$plist" ]]; then
        /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# 尝试从 Info.plist 获取应用官网链接
# 参数: $1 - 应用路径
# 返回: URL 或空
export_apps_get_homepage() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    local url=""
    
    if [[ ! -f "$plist" ]]; then
        echo ""
        return
    fi
    
    # 尝试多种可能的键
    # 1. SUFeedURL (Sparkle 更新框架)
    url=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$plist" 2>/dev/null || echo "")
    if [[ -n "$url" ]]; then
        # 从更新 URL 提取域名
        url=$(echo "$url" | sed 's|^\(https\?://[^/]*\).*|\1|')
        echo "$url"
        return
    fi
    
    # 2. 尝试 NSHumanReadableCopyright 中可能包含的 URL
    local copyright
    copyright=$(/usr/libexec/PlistBuddy -c "Print :NSHumanReadableCopyright" "$plist" 2>/dev/null || echo "")
    if [[ -n "$copyright" ]]; then
        url=$(echo "$copyright" | grep -oE 'https?://[^[:space:]"<>]+' | head -1 || echo "")
        if [[ -n "$url" ]]; then
            echo "$url"
            return
        fi
    fi
    
    echo ""
}

# 检查应用是否通过 brew cask 安装
# 参数: $1 - 应用名称, $2 - brew cask 列表 (以换行分隔)
# 返回: 0 是, 1 否
export_apps_is_brew_managed() {
    local app_name="$1"
    local cask_list="$2"
    
    # 转换应用名称为小写并去除空格用于匹配
    local app_lower
    app_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    
    while IFS= read -r cask; do
        [[ -z "$cask" ]] && continue
        local cask_lower
        cask_lower=$(echo "$cask" | tr '[:upper:]' '[:lower:]' | tr -d ' -')
        
        # 模糊匹配 (去除空格和连字符)
        if [[ "$app_lower" == "$cask_lower" ]]; then
            return 0
        fi
    done <<< "$cask_list"
    
    return 1
}

# 检查应用是否通过 mas 安装
# 参数: $1 - 应用路径
# 返回: 0 是, 1 否
export_apps_is_mas_managed() {
    local app_path="$1"
    
    # 检查是否有 App Store 收据
    if [[ -d "$app_path/Contents/_MASReceipt" ]]; then
        return 0
    fi
    
    # 检查 provenance 标记
    local plist="$app_path/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
        local store_receipt
        store_receipt=$(/usr/libexec/PlistBuddy -c "Print :LSApplicationCategoryType" "$plist" 2>/dev/null || echo "")
        # 一些从 App Store 安装的应用会有这个属性
    fi
    
    return 1
}

# 检查应用是否为系统应用 (应跳过)
# 参数: $1 - 应用名称, $2 - Bundle ID
# 返回: 0 是系统应用, 1 否
export_apps_is_system_app() {
    local app_name="$1"
    local bundle_id="$2"
    
    # 系统应用 Bundle ID 前缀
    case "$bundle_id" in
        com.apple.*)
            return 0
            ;;
    esac
    
    # 常见系统应用名称
    case "$app_name" in
        "Safari"|"Mail"|"Calendar"|"Notes"|"Messages"|"FaceTime"|"Maps"|"Photos"|"Preview"|"TextEdit"|"Finder"|"System Preferences"|"App Store"|"iTunes"|"Music"|"Podcasts"|"TV"|"News"|"Stocks"|"Home"|"Voice Memos"|"Automator"|"Calculator"|"Chess"|"Clock"|"Contacts"|"Dictionary"|"Font Book"|"Grapher"|"Image Capture"|"Keychain Access"|"Migration Assistant"|"Photo Booth"|"QuickTime Player"|"Reminders"|"Screenshot"|"Siri"|"Stickies"|"Time Machine"|"Utilities"|"Weather"|"Books"|"Freeform")
            return 0
            ;;
    esac
    
    return 1
}

# 主导出函数: 扫描并生成手动安装应用列表
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_apps() {
    local output_file="$1"
    
    export_log_info "Scanning Applications directories..."
    
    # 获取 brew cask 列表用于过滤
    local cask_list=""
    if export_command_exists brew; then
        cask_list=$(brew list --cask 2>/dev/null || echo "")
    fi
    
    # 扫描应用目录
    local all_apps
    all_apps=$(export_apps_scan_directories)
    
    if [[ -z "$all_apps" ]]; then
        export_log_warning "No applications found"
        return 0
    fi
    
    # 过滤并分类应用
    local manual_apps=""
    local manual_count=0
    local skipped_brew=0
    local skipped_mas=0
    local skipped_system=0
    
    while IFS= read -r app_path; do
        [[ -z "$app_path" ]] && continue
        [[ ! -d "$app_path" ]] && continue
        
        local app_name bundle_id
        app_name=$(export_apps_get_name "$app_path")
        bundle_id=$(export_apps_get_bundle_id "$app_path")
        
        # 跳过系统应用
        if export_apps_is_system_app "$app_name" "$bundle_id"; then
            skipped_system=$((skipped_system + 1))
            export_log_verbose "Skipping system app: $app_name"
            continue
        fi
        
        # 跳过 brew cask 管理的应用
        if [[ -n "$cask_list" ]] && export_apps_is_brew_managed "$app_name" "$cask_list"; then
            skipped_brew=$((skipped_brew + 1))
            export_log_verbose "Skipping brew-managed: $app_name"
            continue
        fi
        
        # 跳过 mas 管理的应用
        if export_apps_is_mas_managed "$app_path"; then
            skipped_mas=$((skipped_mas + 1))
            export_log_verbose "Skipping mas-managed: $app_name"
            continue
        fi
        
        # 获取官网链接
        local homepage
        homepage=$(export_apps_get_homepage "$app_path")
        
        # 添加到手动安装列表
        if [[ -n "$homepage" ]]; then
            manual_apps="${manual_apps}${app_name}|${homepage}"$'\n'
        else
            manual_apps="${manual_apps}${app_name}|"$'\n'
        fi
        manual_count=$((manual_count + 1))
        
    done <<< "$all_apps"
    
    export_log_verbose "Filtered: $skipped_brew brew, $skipped_mas mas, $skipped_system system apps"
    
    if [[ $manual_count -eq 0 ]]; then
        export_log_success "Applications: all managed by Homebrew/MAS"
        return 0
    fi
    
    # 写入章节头
    export_write_section_start "$output_file" "3" "Manual Applications" "$manual_count apps"
    
    # 写入注释形式的手动安装应用列表
    cat >> "$output_file" << 'EOF'
# 以下应用需要手动下载安装（非 Homebrew/AppStore）:
# 建议访问官网下载最新版本
#
EOF
    
    while IFS='|' read -r app_name homepage; do
        [[ -z "$app_name" ]] && continue
        
        if [[ -n "$homepage" ]]; then
            echo "#   - $app_name ($homepage)" >> "$output_file"
        else
            echo "#   - $app_name" >> "$output_file"
        fi
    done <<< "$manual_apps"
    
    echo "#" >> "$output_file"
    echo "# 提示: 可使用以下命令搜索 Homebrew Cask:" >> "$output_file"
    echo "#   brew search --cask <app_name>" >> "$output_file"
    
    export_write_section_end "$output_file"
    
    # 更新统计
    export_add_stat "Manual Apps" "$manual_count" "apps (need manual install)"
    
    export_log_success "Applications: $manual_count manual apps (filtered $skipped_brew brew, $skipped_mas mas)"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_apps_dry_run() {
    # 获取 brew cask 列表用于过滤
    local cask_list=""
    if export_command_exists brew; then
        cask_list=$(brew list --cask 2>/dev/null || echo "")
    fi
    
    # 扫描应用目录
    local all_apps
    all_apps=$(export_apps_scan_directories)
    
    if [[ -z "$all_apps" ]]; then
        echo "Applications: no apps found"
        return 0
    fi
    
    # 统计应用
    local total_count=0
    local manual_count=0
    local manual_apps=""
    
    while IFS= read -r app_path; do
        [[ -z "$app_path" ]] && continue
        [[ ! -d "$app_path" ]] && continue
        
        total_count=$((total_count + 1))
        
        local app_name bundle_id
        app_name=$(export_apps_get_name "$app_path")
        bundle_id=$(export_apps_get_bundle_id "$app_path")
        
        # 跳过系统应用
        if export_apps_is_system_app "$app_name" "$bundle_id"; then
            continue
        fi
        
        # 跳过 brew cask 管理的应用
        if [[ -n "$cask_list" ]] && export_apps_is_brew_managed "$app_name" "$cask_list"; then
            continue
        fi
        
        # 跳过 mas 管理的应用
        if export_apps_is_mas_managed "$app_path"; then
            continue
        fi
        
        manual_apps="${manual_apps}${app_name}"$'\n'
        manual_count=$((manual_count + 1))
        
    done <<< "$all_apps"
    
    echo "Applications: $total_count total, $manual_count manual (need install)"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" && $manual_count -gt 0 ]]; then
        echo ""
        echo "  Manual Apps:"
        echo "$manual_apps" | head -20 | while IFS= read -r app; do
            [[ -n "$app" ]] && echo "    $app"
        done
        
        local remaining=$((manual_count - 20))
        [[ $remaining -gt 0 ]] && echo "    ... and $remaining more"
    fi
}

# 获取手动安装应用列表 (供其他模块使用)
# 返回: 每行一个应用名称
export_apps_get_manual_list() {
    local cask_list=""
    if export_command_exists brew; then
        cask_list=$(brew list --cask 2>/dev/null || echo "")
    fi
    
    local all_apps
    all_apps=$(export_apps_scan_directories)
    
    while IFS= read -r app_path; do
        [[ -z "$app_path" ]] && continue
        [[ ! -d "$app_path" ]] && continue
        
        local app_name bundle_id
        app_name=$(export_apps_get_name "$app_path")
        bundle_id=$(export_apps_get_bundle_id "$app_path")
        
        # 跳过系统应用
        export_apps_is_system_app "$app_name" "$bundle_id" && continue
        
        # 跳过 brew cask 管理的应用
        [[ -n "$cask_list" ]] && export_apps_is_brew_managed "$app_name" "$cask_list" && continue
        
        # 跳过 mas 管理的应用
        export_apps_is_mas_managed "$app_path" && continue
        
        echo "$app_name"
    done <<< "$all_apps"
}
