#!/bin/bash
# Mole - Export Common Functions Library
# 提供环境导出功能的公共函数
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_COMMON_LOADED=1

# =============================================================================
# 类别定义 (使用函数代替关联数组以兼容 bash 3.2)
# =============================================================================

# 获取类别组的展开列表
# 参数: $1 - 类别组名称
# 返回: 展开后的类别列表 (以逗号分隔), 如果不是类别组则返回空
export_get_category_group() {
    local group="$1"
    case "$group" in
        all)
            echo "homebrew,mas,npm,pip,vscode,jetbrains,cursor,docker,git,ssh,shell,system"
            ;;
        essential)
            echo "homebrew,git,shell,system"
            ;;
        dev)
            echo "homebrew,npm,pip,git,docker,vscode,jetbrains,cursor"
            ;;
        ide)
            echo "vscode,jetbrains,cursor"
            ;;
        cloud)
            echo "docker"
            ;;
        ai)
            echo "cursor"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 获取类别描述
# 参数: $1 - 类别名称
# 返回: 类别描述
export_get_category_description() {
    local category="$1"
    case "$category" in
        homebrew)
            echo "Homebrew packages and casks"
            ;;
        mas)
            echo "Mac App Store applications"
            ;;
        npm)
            echo "Global npm packages"
            ;;
        pip)
            echo "Python pip packages"
            ;;
        vscode)
            echo "VS Code extensions and settings"
            ;;
        jetbrains)
            echo "JetBrains IDE settings"
            ;;
        cursor)
            echo "Cursor editor extensions"
            ;;
        docker)
            echo "Docker images and config"
            ;;
        git)
            echo "Git global configuration"
            ;;
        ssh)
            echo "SSH configuration"
            ;;
        shell)
            echo "Shell configuration (zsh/bash)"
            ;;
        system)
            echo "macOS system preferences"
            ;;
        *)
            echo "$category"
            ;;
    esac
}

# 支持的所有类别列表
EXPORT_ALL_CATEGORIES="homebrew mas npm pip vscode jetbrains cursor docker git ssh shell system"

# =============================================================================
# 工具检测函数
# =============================================================================

# 检查命令是否存在
# 参数: $1 - 命令名称
# 返回: 0 存在, 1 不存在
export_command_exists() {
    command -v "$1" > /dev/null 2>&1
}

# 检查目录是否存在
# 参数: $1 - 目录路径
# 返回: 0 存在, 1 不存在
export_dir_exists() {
    [[ -d "$1" ]]
}

# 检查文件是否存在
# 参数: $1 - 文件路径
# 返回: 0 存在, 1 不存在
export_file_exists() {
    [[ -f "$1" ]]
}

# =============================================================================
# 日志和进度显示函数
# =============================================================================

# 导出操作日志 - 成功
# 参数: $1 - 消息
# 注意: 输出到 stderr 以避免干扰函数返回值
export_log_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1" >&2
}

# 导出操作日志 - 信息
# 参数: $1 - 消息
export_log_info() {
    echo -e "  ${BLUE}${ICON_LIST}${NC} $1" >&2
}

# 导出操作日志 - 警告
# 参数: $1 - 消息
export_log_warning() {
    echo -e "  ${YELLOW}${ICON_WARNING}${NC} $1" >&2
}

# 导出操作日志 - 错误
# 参数: $1 - 消息
export_log_error() {
    echo -e "  ${RED}${ICON_ERROR}${NC} $1" >&2
}

# 导出操作日志 - 跳过
# 参数: $1 - 消息
export_log_skipped() {
    echo -e "  ${GRAY}○${NC} $1" >&2
}

# 导出操作日志 - 调试 (仅在 --verbose 模式)
# 参数: $1 - 消息
export_log_verbose() {
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        echo -e "  ${GRAY}[DEBUG]${NC} $1" >&2
    fi
}

# 开始章节
# 参数: $1 - 章节名称
export_start_section() {
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
}

# 结束章节
export_end_section() {
    :
}

# =============================================================================
# 输出文件管理
# =============================================================================

# 生成默认输出文件名
# 返回: mole-export-YYYYMMDD-HHMMSS.sh
export_generate_filename() {
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    echo "mole-export-${timestamp}.sh"
}

# 解析输出文件路径
# 参数: $1 - 用户指定的路径 (可选)
# 返回: 完整的输出文件路径
export_resolve_output_path() {
    local user_path="${1:-}"
    
    if [[ -n "$user_path" ]]; then
        if [[ "$user_path" == /* ]]; then
            echo "$user_path"
        else
            echo "$(pwd)/$user_path"
        fi
    else
        echo "$(pwd)/$(export_generate_filename)"
    fi
}

# 验证输出目录可写
# 参数: $1 - 输出文件路径
# 返回: 0 可写, 1 不可写
export_validate_output_path() {
    local output_file="$1"
    local output_dir
    output_dir=$(dirname "$output_file")
    
    if [[ ! -d "$output_dir" ]]; then
        export_log_error "Output directory does not exist: $output_dir"
        return 1
    fi
    
    if [[ ! -w "$output_dir" ]]; then
        export_log_error "Output directory is not writable: $output_dir"
        return 1
    fi
    
    return 0
}

# =============================================================================
# 脚本生成辅助函数
# =============================================================================

# 获取 Mole 版本号
# 返回: 版本号字符串
export_get_mole_version() {
    local version=""
    if command -v mo > /dev/null 2>&1; then
        version=$(mo --version 2>/dev/null | head -1 | sed 's/.*version[[:space:]]*//' || echo "")
    fi
    echo "${version:-unknown}"
}

# 获取机器信息
# 返回: 机器型号描述
export_get_machine_info() {
    local model=""
    local chip=""
    
    model=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name" | sed 's/.*: //' || echo "Mac")
    chip=$(uname -m)
    
    if [[ "$chip" == "arm64" ]]; then
        local chip_name
        chip_name=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip" | head -1 | sed 's/.*: //' || echo "Apple Silicon")
        echo "${model} (${chip_name})"
    else
        echo "${model} (Intel)"
    fi
}

# 写入脚本注释头 (带美化边框)
# 参数: $1 - 输出文件路径
export_write_header() {
    local output_file="$1"
    local date_str machine_info mole_version filename
    date_str=$(date '+%Y-%m-%d %H:%M:%S')
    machine_info=$(export_get_machine_info)
    mole_version=$(export_get_mole_version)
    filename=$(basename "$output_file")

    cat > "$output_file" << EOF
#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Mole Export - 开发环境恢复脚本                                   ║
# ║  生成时间: $date_str                                   ║
# ║  生成工具: Mole v${mole_version}                                          ║
# ║  源机器: $machine_info                                    ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  使用方法:                                                        ║
# ║    chmod +x $filename                       ║
# ║    ./$filename [--dry-run] [--skip <cat>]   ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

EOF
}

# 写入全局配置和运行时框架
# 参数: $1 - 输出文件路径
export_write_runtime_framework() {
    local output_file="$1"
    
    cat >> "$output_file" << 'EOF'
# ============================================================
# 全局配置
# ============================================================
DRY_RUN=false
SKIP_CATEGORIES=()
LOG_FILE="./mole-restore-$(date +%Y%m%d-%H%M%S).log"

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --skip) SKIP_CATEGORIES+=("$2"); shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "OPTIONS:"
            echo "  --dry-run        Preview mode, don't execute commands"
            echo "  --skip <cat>     Skip specified category"
            echo "  -h, --help       Show this help"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ============================================================
# 运行时辅助函数
# ============================================================

# 日志函数
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# 执行命令 (支持 dry-run)
run() { 
    if $DRY_RUN; then
        log "DRY-RUN: $*"
    else
        eval "$*"
    fi
}

# 检查是否跳过指定类别
should_skip() { 
    local cat="$1"
    for skip in "${SKIP_CATEGORIES[@]:-}"; do
        [[ "$skip" == "$cat" ]] && return 0
    done
    return 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" > /dev/null 2>&1
}

EOF
}

# 写入章节开始标记 (带章节编号)
# 参数: $1 - 输出文件路径, $2 - 章节编号, $3 - 章节名称, $4 - 统计信息 (可选)
export_write_section_start() {
    local output_file="$1"
    local section_num="$2"
    local section_name="$3"
    local stats="${4:-}"

    if [[ -n "$stats" ]]; then
        cat >> "$output_file" << EOF

# ============================================================
# $section_num. $section_name ($stats)
# ============================================================
EOF
    else
        cat >> "$output_file" << EOF

# ============================================================
# $section_num. $section_name
# ============================================================
EOF
    fi
}

# 写入章节结束标记 (可选，用于添加空行)
# 参数: $1 - 输出文件路径
export_write_section_end() {
    local output_file="$1"
    echo "" >> "$output_file"
}

# 写入命令行 (带可选注释)
# 参数: $1 - 输出文件路径, $2 - 命令, $3 - 可选注释
export_write_command() {
    local output_file="$1"
    local cmd="$2"
    local comment="${3:-}"

    if [[ -n "$comment" && "${EXPORT_NO_COMMENTS:-false}" != "true" ]]; then
        echo "# $comment" >> "$output_file"
    fi
    echo "$cmd" >> "$output_file"
}

# 写入原始行
# 参数: $1 - 输出文件路径, $2 - 行内容
export_write_line() {
    local output_file="$1"
    local line="$2"
    echo "$line" >> "$output_file"
}

# 写入空行
# 参数: $1 - 输出文件路径
export_write_newline() {
    local output_file="$1"
    echo "" >> "$output_file"
}

# 写入函数开始
# 参数: $1 - 输出文件路径, $2 - 函数名, $3 - 类别 ID (用于 should_skip)
export_write_function_start() {
    local output_file="$1"
    local func_name="$2"
    local category_id="$3"
    
    cat >> "$output_file" << EOF
${func_name}() {
    should_skip "$category_id" && return 0
EOF
}

# 写入函数结束
# 参数: $1 - 输出文件路径
export_write_function_end() {
    local output_file="$1"
    echo "}" >> "$output_file"
}

# 写入主流程框架
# 参数: $1 - 输出文件路径, $2 - 函数调用列表 (以换行分隔)
export_write_main_function() {
    local output_file="$1"
    local function_calls="$2"
    
    cat >> "$output_file" << 'EOF'

# ============================================================
# 执行主流程
# ============================================================
main() {
    log "🚀 Mole Export - 开始恢复开发环境"
    log "   Dry run: $DRY_RUN"
    log "   Skip: ${SKIP_CATEGORIES[*]:-none}"
    echo
    
EOF
    
    while IFS= read -r func; do
        [[ -n "$func" ]] && echo "    $func" >> "$output_file"
    done <<< "$function_calls"
    
    cat >> "$output_file" << 'EOF'
    
    echo
    log "✅ 恢复完成! 日志: $LOG_FILE"
}

main
EOF
}

# 写入脚本页脚
# 参数: $1 - 输出文件路径
export_write_footer() {
    local output_file="$1"

    cat >> "$output_file" << 'EOF'

# ============================================================
# 手动安装应用
# ============================================================
# 以下应用需要手动下载安装（非 Homebrew/AppStore）:
#   （详见上方 Applications 章节注释）

EOF
}

# 写入注释块 (用于手动安装应用列表)
# 参数: $1 - 输出文件路径, $2 - 注释内容 (多行)
export_write_comment_block() {
    local output_file="$1"
    local content="$2"
    
    while IFS= read -r line; do
        echo "# $line" >> "$output_file"
    done <<< "$content"
}

# =============================================================================
# 统计信息管理
# =============================================================================

# 全局统计变量 (使用字符串存储，兼容 bash 3.2)
EXPORT_STATS=""

# 添加统计信息
# 参数: $1 - 类别名称, $2 - 数量, $3 - 描述 (可选)
export_add_stat() {
    local category="$1"
    local count="$2"
    local desc="${3:-items}"
    
    if [[ -n "$EXPORT_STATS" ]]; then
        EXPORT_STATS="${EXPORT_STATS}
${category}:${count}:${desc}"
    else
        EXPORT_STATS="${category}:${count}:${desc}"
    fi
}

# 重置统计信息
export_reset_stats() {
    EXPORT_STATS=""
}

# 显示统计摘要
export_show_summary() {
    local total_items=0
    
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} Export Summary${NC}"
    
    if [[ -z "$EXPORT_STATS" ]]; then
        echo -e "  ${GRAY}No items exported${NC}"
        return
    fi
    
    while IFS=: read -r category count desc; do
        [[ -z "$category" ]] && continue
        printf "  ${GREEN}%-15s${NC} %d %s\n" "$category" "$count" "$desc"
        total_items=$((total_items + count))
    done <<< "$EXPORT_STATS"
    
    echo ""
    echo -e "  ${BLUE}Total:${NC} ${total_items} items"
}

# 获取统计总数
# 返回: 所有类别的项目总数
export_get_total_count() {
    local total=0
    
    while IFS=: read -r category count desc; do
        [[ -z "$count" ]] && continue
        total=$((total + count))
    done <<< "$EXPORT_STATS"
    
    echo "$total"
}

# =============================================================================
# 类别处理函数
# =============================================================================

# 展开类别组为实际类别列表
# 参数: $1 - 类别或类别组名称
# 返回: 展开后的类别列表 (以逗号分隔)
export_expand_category() {
    local input="$1"
    local expanded
    expanded=$(export_get_category_group "$input")

    if [[ -n "$expanded" ]]; then
        echo "$expanded"
    else
        echo "$input"
    fi
}

# 验证类别是否有效
# 参数: $1 - 类别名称
# 返回: 0 有效, 1 无效
export_validate_category() {
    local category="$1"

    # 检查是否是类别组
    local group_expanded
    group_expanded=$(export_get_category_group "$category")
    if [[ -n "$group_expanded" ]]; then
        return 0
    fi

    # 检查是否是有效类别
    for cat in $EXPORT_ALL_CATEGORIES; do
        if [[ "$cat" == "$category" ]]; then
            return 0
        fi
    done

    return 1
}

# 解析类别参数为类别数组
# 参数: $1 - 逗号分隔的类别列表
# 输出: 去重后的类别列表 (每行一个)
export_parse_categories() {
    local input="$1"
    local result=""
    local seen=""

    # 使用 IFS 分割逗号分隔的列表
    local OLD_IFS="$IFS"
    IFS=','
    for part in $input; do
        IFS="$OLD_IFS"
        # 去除空白
        part="${part// /}"
        [[ -z "$part" ]] && continue

        # 展开类别组
        local expanded
        expanded=$(export_expand_category "$part")

        IFS=','
        for cat in $expanded; do
            IFS="$OLD_IFS"
            cat="${cat// /}"
            [[ -z "$cat" ]] && continue

            # 去重检查
            local is_seen=false
            for s in $seen; do
                if [[ "$s" == "$cat" ]]; then
                    is_seen=true
                    break
                fi
            done

            if [[ "$is_seen" == "false" ]]; then
                seen="$seen $cat"
                if [[ -n "$result" ]]; then
                    result="$result
$cat"
                else
                    result="$cat"
                fi
            fi
        done
        IFS=','
    done
    IFS="$OLD_IFS"

    echo "$result"
}

# 检查类别是否被排除
# 参数: $1 - 类别名称, $2 - 排除列表 (以换行分隔)
# 返回: 0 被排除, 1 未被排除
export_is_excluded() {
    local category="$1"
    local exclude_list="$2"

    while IFS= read -r excluded; do
        [[ "$excluded" == "$category" ]] && return 0
    done <<< "$exclude_list"

    return 1
}

# =============================================================================
# 帮助函数
# =============================================================================

# 显示可用类别列表
export_show_categories() {
    echo ""
    echo -e "${BLUE}Available Categories:${NC}"
    for cat in $EXPORT_ALL_CATEGORIES; do
        local desc
        desc=$(export_get_category_description "$cat")
        printf "  ${GREEN}%-12s${NC} %s\n" "$cat" "$desc"
    done

    echo ""
    echo -e "${BLUE}Category Groups:${NC}"
    printf "  ${GREEN}%-12s${NC} %s\n" "all" "All categories"
    printf "  ${GREEN}%-12s${NC} %s\n" "essential" "Essential tools (homebrew, git, shell, system)"
    printf "  ${GREEN}%-12s${NC} %s\n" "dev" "Development environment"
    printf "  ${GREEN}%-12s${NC} %s\n" "ide" "IDE configurations (vscode, jetbrains, cursor)"
    printf "  ${GREEN}%-12s${NC} %s\n" "cloud" "Cloud tools (docker)"
    printf "  ${GREEN}%-12s${NC} %s\n" "ai" "AI tools (cursor)"
}
