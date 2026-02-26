#!/bin/bash
# Mole - Export command.
# 导出开发环境配置为可执行脚本.
# 支持按类别选择导出内容.
# 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# =============================================================================
# 加载所有导出模块
# =============================================================================

EXPORT_LIB_DIR="$SCRIPT_DIR/../lib/export"

source "$EXPORT_LIB_DIR/common.sh"
source "$EXPORT_LIB_DIR/brew.sh"
source "$EXPORT_LIB_DIR/mas.sh"
source "$EXPORT_LIB_DIR/apps.sh"
source "$EXPORT_LIB_DIR/node_version.sh"
source "$EXPORT_LIB_DIR/python_version.sh"
source "$EXPORT_LIB_DIR/version_managers.sh"
source "$EXPORT_LIB_DIR/node_packages.sh"
source "$EXPORT_LIB_DIR/python_packages.sh"
source "$EXPORT_LIB_DIR/other_packages.sh"
source "$EXPORT_LIB_DIR/ide.sh"
source "$EXPORT_LIB_DIR/shell.sh"
source "$EXPORT_LIB_DIR/git.sh"
source "$EXPORT_LIB_DIR/cloud.sh"
source "$EXPORT_LIB_DIR/ai.sh"
source "$EXPORT_LIB_DIR/cli_tools.sh"

# =============================================================================
# 默认配置
# =============================================================================

OUTPUT_FILE=""
CATEGORIES="all"
EXCLUDE_CATEGORIES=""
DRY_RUN=false
EXPORT_VERBOSE=false
EXPORT_NO_COMMENTS=false
EXPORT_DEBUG=false

DEFAULT_OUTPUT_FILE="$HOME/mole-export-$(date '+%Y%m%d-%H%M%S').sh"

# =============================================================================
# 类别组定义 (根据 spec.md 要求)
# =============================================================================

# 获取新的类别组映射
# 参数: $1 - 类别组名称
# 返回: 展开后的类别列表 (以逗号分隔)
get_category_group() {
    local group="$1"
    case "$group" in
        all)
            echo "brew,mas,apps,nvm,fnm,pyenv,rbenv,goenv,jenv,rustup,mise,asdf,npm,pnpm,yarn,bun,pip,uv,cargo,go,gem,vscode,cursor,windsurf,zed,neovim,vim,shell,git,docker,kubectl,aws,terraform,helm,claude,copilot,codeium,continue,aider,ollama,cli_tools"
            ;;
        essential)
            echo "brew,mas,git,shell"
            ;;
        dev)
            echo "nvm,fnm,pyenv,rbenv,goenv,jenv,rustup,mise,asdf,npm,pnpm,yarn,bun,pip,uv,cargo,go,gem"
            ;;
        ide)
            echo "vscode,cursor,windsurf,zed,neovim,vim"
            ;;
        cloud)
            echo "docker,kubectl,aws,terraform,helm"
            ;;
        ai)
            echo "claude,copilot,codeium,continue,aider,ollama"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 所有支持的独立类别列表
ALL_INDIVIDUAL_CATEGORIES="brew mas apps nvm fnm pyenv rbenv goenv jenv rustup mise asdf npm pnpm yarn bun pip uv cargo go gem vscode cursor windsurf zed neovim vim shell git docker kubectl aws terraform helm claude copilot codeium continue aider ollama cli_tools"

# 所有支持的类别组列表
ALL_CATEGORY_GROUPS="all essential dev ide cloud ai"

# 验证类别是否有效
# 参数: $1 - 类别名称
# 返回: 0 有效, 1 无效
validate_category() {
    local category="$1"
    local item

    # 检查是否是类别组
    for item in $ALL_CATEGORY_GROUPS; do
        if [[ "$item" == "$category" ]]; then
            return 0
        fi
    done

    # 检查是否是有效的独立类别
    for item in $ALL_INDIVIDUAL_CATEGORIES; do
        if [[ "$item" == "$category" ]]; then
            return 0
        fi
    done

    return 1
}

# 解析类别参数为类别数组
# 参数: $1 - 逗号分隔的类别列表
# 输出: 去重后的类别列表 (每行一个)
parse_categories() {
    local input="$1"
    local result=""
    local seen=""

    local OLD_IFS="$IFS"
    IFS=','
    for part in $input; do
        IFS="$OLD_IFS"
        # 去除空白
        part="${part// /}"
        [[ -z "$part" ]] && continue

        # 展开类别组
        local expanded
        expanded=$(get_category_group "$part")
        if [[ -z "$expanded" ]]; then
            expanded="$part"
        fi

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
is_excluded() {
    local category="$1"
    local exclude_list="$2"

    while IFS= read -r excluded; do
        [[ "$excluded" == "$category" ]] && return 0
    done <<< "$exclude_list"

    return 1
}

# =============================================================================
# 帮助信息
# =============================================================================

show_export_help() {
    cat << 'EOF'
Mole Export - 导出开发环境配置

用法:
    mo export [OPTIONS]

选项:
    -o, --output FILE     指定输出文件路径 (默认: ~/mole-export-YYYYMMDD-HHMMSS.sh)
    -c, --category CAT    指定导出类别，逗号分隔或使用类别组名 (默认: all)
    -e, --exclude CAT     排除指定类别，逗号分隔
    --dry-run, -n         预览模式，显示将要导出的内容但不生成文件
    --verbose, -v         显示详细进度信息
    --no-comments         生成的脚本不包含注释
    --debug               启用调试输出
    --categories          显示所有可用类别
    -h, --help            显示此帮助信息

类别组:
    all         所有类别 (默认)
    essential   核心工具 (brew, mas, git, shell)
    dev         开发工具 (版本管理器 + 包管理器)
                包含: nvm, fnm, pyenv, rbenv, goenv, jenv, rustup, mise, asdf,
                      npm, pnpm, yarn, bun, pip, uv, cargo, go, gem
    ide         IDE 和编辑器 (vscode, cursor, windsurf, zed, neovim, vim)
    cloud       云和 DevOps 工具 (docker, kubectl, aws, terraform, helm)
    ai          AI 编程工具 (claude, copilot, codeium, continue, aider, ollama)

独立类别:
    系统级:     brew, mas, apps
    Node.js:    nvm, fnm, npm, pnpm, yarn, bun
    Python:     pyenv, pip, uv
    其他语言:   rbenv, goenv, jenv, rustup, mise, asdf, cargo, go, gem
    IDE:        vscode, cursor, windsurf, zed, neovim, vim
    配置:       shell, git
    云工具:     docker, kubectl, aws, terraform, helm
    AI 工具:    claude, copilot, codeium, continue, aider, ollama
    CLI 工具:   cli_tools

示例:
    mo export                              # 导出所有到默认文件
    mo export -o setup.sh                  # 导出到指定文件
    mo export --category dev               # 仅导出开发工具
    mo export --category brew,npm,pip      # 导出指定类别
    mo export --category all --exclude docker,aws  # 排除指定类别
    mo export --dry-run                    # 预览将要导出的内容
    mo export --dry-run --verbose          # 详细预览

安全说明:
    - 导出脚本不包含任何敏感信息（密钥、token、密码）
    - AWS/GCloud 凭证、SSH 私钥等不会被导出
    - Git 配置中的 credential 部分会被过滤

EOF
}

# 显示可用类别列表
show_categories() {
    echo ""
    echo -e "${BLUE}独立类别:${NC}"
    printf "  ${GREEN}%-12s${NC} %s\n" "brew" "Homebrew formulae 和 casks"
    printf "  ${GREEN}%-12s${NC} %s\n" "mas" "Mac App Store 应用"
    printf "  ${GREEN}%-12s${NC} %s\n" "apps" "手动安装的应用"
    printf "  ${GREEN}%-12s${NC} %s\n" "nvm" "Node.js 版本 (nvm)"
    printf "  ${GREEN}%-12s${NC} %s\n" "fnm" "Node.js 版本 (fnm)"
    printf "  ${GREEN}%-12s${NC} %s\n" "pyenv" "Python 版本管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "rbenv" "Ruby 版本管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "goenv" "Go 版本管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "jenv" "Java 版本管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "rustup" "Rust 工具链管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "mise" "mise (原 rtx) 多语言版本管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "asdf" "asdf 插件管理器"
    printf "  ${GREEN}%-12s${NC} %s\n" "npm" "npm 全局包"
    printf "  ${GREEN}%-12s${NC} %s\n" "pnpm" "pnpm 全局包"
    printf "  ${GREEN}%-12s${NC} %s\n" "yarn" "yarn 全局包"
    printf "  ${GREEN}%-12s${NC} %s\n" "bun" "bun 全局包"
    printf "  ${GREEN}%-12s${NC} %s\n" "pip" "pip 用户包"
    printf "  ${GREEN}%-12s${NC} %s\n" "uv" "uv 工具"
    printf "  ${GREEN}%-12s${NC} %s\n" "cargo" "Cargo (Rust) crates"
    printf "  ${GREEN}%-12s${NC} %s\n" "go" "Go 工具"
    printf "  ${GREEN}%-12s${NC} %s\n" "gem" "Ruby gems"
    printf "  ${GREEN}%-12s${NC} %s\n" "vscode" "VS Code 扩展"
    printf "  ${GREEN}%-12s${NC} %s\n" "cursor" "Cursor 扩展"
    printf "  ${GREEN}%-12s${NC} %s\n" "windsurf" "Windsurf 扩展"
    printf "  ${GREEN}%-12s${NC} %s\n" "zed" "Zed 扩展"
    printf "  ${GREEN}%-12s${NC} %s\n" "neovim" "Neovim 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "vim" "Vim 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "shell" "Shell 配置 (zsh/bash/fish)"
    printf "  ${GREEN}%-12s${NC} %s\n" "git" "Git 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "docker" "Docker 镜像"
    printf "  ${GREEN}%-12s${NC} %s\n" "kubectl" "Kubernetes contexts"
    printf "  ${GREEN}%-12s${NC} %s\n" "aws" "AWS CLI 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "terraform" "Terraform 版本"
    printf "  ${GREEN}%-12s${NC} %s\n" "helm" "Helm 仓库"
    printf "  ${GREEN}%-12s${NC} %s\n" "claude" "Claude Code 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "copilot" "GitHub Copilot 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "codeium" "Codeium 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "continue" "Continue.dev 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "aider" "Aider 配置"
    printf "  ${GREEN}%-12s${NC} %s\n" "ollama" "Ollama 模型"
    printf "  ${GREEN}%-12s${NC} %s\n" "cli_tools" "现代 CLI 工具"

    echo ""
    echo -e "${BLUE}类别组:${NC}"
    printf "  ${GREEN}%-12s${NC} %s\n" "all" "所有类别"
    printf "  ${GREEN}%-12s${NC} %s\n" "essential" "核心工具 (brew, mas, git, shell)"
    printf "  ${GREEN}%-12s${NC} %s\n" "dev" "开发工具 (版本管理器 + 包管理器)"
    printf "  ${GREEN}%-12s${NC} %s\n" "ide" "IDE 和编辑器"
    printf "  ${GREEN}%-12s${NC} %s\n" "cloud" "云和 DevOps 工具"
    printf "  ${GREEN}%-12s${NC} %s\n" "ai" "AI 编程工具"
}

# =============================================================================
# 参数解析
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o | --output)
                if [[ -z "${2:-}" ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -c | --category)
                if [[ -z "${2:-}" ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                CATEGORIES="$2"
                shift 2
                ;;
            -e | --exclude)
                if [[ -z "${2:-}" ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                EXCLUDE_CATEGORIES="$2"
                shift 2
                ;;
            --dry-run | -n)
                DRY_RUN=true
                shift
                ;;
            --verbose | -v)
                EXPORT_VERBOSE=true
                shift
                ;;
            --no-comments)
                EXPORT_NO_COMMENTS=true
                shift
                ;;
            --debug)
                EXPORT_DEBUG=true
                export MO_DEBUG=1
                shift
                ;;
            -h | --help)
                show_export_help
                exit 0
                ;;
            --categories)
                show_categories
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                echo "使用 'mo export --help' 获取帮助信息。"
                exit 1
                ;;
        esac
    done

    # 设置默认输出文件
    if [[ -z "$OUTPUT_FILE" ]]; then
        OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
    fi

    # 验证类别参数
    local category_to_validate
    IFS=',' read -ra cat_parts <<< "$CATEGORIES"
    for category_to_validate in "${cat_parts[@]}"; do
        category_to_validate="${category_to_validate// /}"
        [[ -z "$category_to_validate" ]] && continue
        if ! validate_category "$category_to_validate"; then
            log_error "无效的类别: $category_to_validate"
            echo "使用 'mo export --categories' 查看可用类别。"
            exit 1
        fi
    done

    # 验证排除类别参数
    if [[ -n "$EXCLUDE_CATEGORIES" ]]; then
        IFS=',' read -ra exclude_parts <<< "$EXCLUDE_CATEGORIES"
        for category_to_validate in "${exclude_parts[@]}"; do
            category_to_validate="${category_to_validate// /}"
            [[ -z "$category_to_validate" ]] && continue
            if ! validate_category "$category_to_validate"; then
                log_error "无效的排除类别: $category_to_validate"
                exit 1
            fi
        done
    fi
}

# =============================================================================
# 清理函数
# =============================================================================

CLEANUP_DONE=false

cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    stop_inline_spinner 2> /dev/null || true
    cleanup_temp_files
    show_cursor
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

# =============================================================================
# Dry-run 预览模式
# =============================================================================

perform_dry_run() {
    local -a final_categories=("$@")

    echo ""
    echo -e "${YELLOW}${ICON_WARNING} Dry Run 模式${NC} - 预览将要导出的内容"
    echo ""

    local total_items=0
    local detected_count=0

    for category in "${final_categories[@]}"; do
        case "$category" in
            brew)
                echo -e "${BLUE}${ICON_ARROW}${NC} Homebrew"
                export_brew_dry_run 2>/dev/null || echo "  无法检测"
                ((detected_count++))
                ;;
            mas)
                echo -e "${BLUE}${ICON_ARROW}${NC} Mac App Store"
                export_mas_dry_run 2>/dev/null || echo "  无法检测"
                ((detected_count++))
                ;;
            apps)
                echo -e "${BLUE}${ICON_ARROW}${NC} Applications"
                export_apps_dry_run 2>/dev/null || echo "  无法检测"
                ((detected_count++))
                ;;
            nvm)
                echo -e "${BLUE}${ICON_ARROW}${NC} nvm (Node.js)"
                if export_nvm_installed; then
                    local nvm_versions
                    nvm_versions=$(export_nvm_list_versions | wc -l | tr -d ' ')
                    echo "  已安装: $nvm_versions 个 Node.js 版本"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            fnm)
                echo -e "${BLUE}${ICON_ARROW}${NC} fnm (Node.js)"
                if export_fnm_installed; then
                    local fnm_versions
                    fnm_versions=$(export_fnm_list_versions | wc -l | tr -d ' ')
                    echo "  已安装: $fnm_versions 个 Node.js 版本"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            pyenv)
                echo -e "${BLUE}${ICON_ARROW}${NC} pyenv (Python)"
                if export_pyenv_installed; then
                    local pyenv_versions
                    pyenv_versions=$(export_pyenv_list_versions | wc -l | tr -d ' ')
                    echo "  已安装: $pyenv_versions 个 Python 版本"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            rbenv|goenv|jenv|rustup|mise|asdf)
                echo -e "${BLUE}${ICON_ARROW}${NC} $category"
                if command -v "$category" > /dev/null 2>&1; then
                    echo "  已检测到"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            npm|pnpm|yarn|bun)
                echo -e "${BLUE}${ICON_ARROW}${NC} $category 全局包"
                if command -v "$category" > /dev/null 2>&1; then
                    echo "  已检测到"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            pip|uv)
                echo -e "${BLUE}${ICON_ARROW}${NC} $category"
                if command -v "$category" > /dev/null 2>&1 || command -v pip3 > /dev/null 2>&1; then
                    echo "  已检测到"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            cargo|go|gem)
                echo -e "${BLUE}${ICON_ARROW}${NC} $category"
                if command -v "$category" > /dev/null 2>&1; then
                    echo "  已检测到"
                    ((detected_count++))
                else
                    echo "  未安装"
                fi
                ;;
            vscode|cursor|windsurf|zed|neovim|vim)
                echo -e "${BLUE}${ICON_ARROW}${NC} IDE: $category"
                export_ide_dry_run 2>/dev/null | grep -i "$category" || echo "  未配置"
                ((detected_count++))
                ;;
            shell)
                echo -e "${BLUE}${ICON_ARROW}${NC} Shell 配置"
                export_shell_dry_run 2>/dev/null || echo "  无法检测"
                ((detected_count++))
                ;;
            git)
                echo -e "${BLUE}${ICON_ARROW}${NC} Git 配置"
                export_git_dry_run 2>/dev/null || echo "  无法检测"
                ((detected_count++))
                ;;
            docker|kubectl|aws|terraform|helm)
                echo -e "${BLUE}${ICON_ARROW}${NC} Cloud: $category"
                export_cloud_dry_run 2>/dev/null | grep -i "$category" || echo "  未配置"
                ((detected_count++))
                ;;
            claude|copilot|codeium|continue|aider|ollama)
                echo -e "${BLUE}${ICON_ARROW}${NC} AI: $category"
                export_ai_dry_run 2>/dev/null | grep -i "$category" || echo "  未配置"
                ((detected_count++))
                ;;
            cli_tools)
                echo -e "${BLUE}${ICON_ARROW}${NC} CLI 工具"
                export_cli_tools_dry_run 2>/dev/null || echo "  无法检测"
                ((detected_count++))
                ;;
            *)
                echo -e "${GRAY}${ICON_LIST}${NC} $category: 未知类别"
                ;;
        esac
        echo ""
    done

    # 显示总结
    echo -e "${PURPLE_BOLD}${ICON_ARROW} 预览完成${NC}"
    echo -e "  扫描类别: ${#final_categories[@]}"
    echo -e "  检测到: $detected_count"
    echo ""
    echo -e "  ${GRAY}使用不带 --dry-run 参数重新运行以生成导出脚本${NC}"
}

# =============================================================================
# 完整导出流程
# =============================================================================

perform_export() {
    export MOLE_CURRENT_COMMAND="export"
    log_operation_session_start "export"

    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'
    echo -e "${PURPLE_BOLD}Export Development Environment${NC}"
    echo ""

    # 解析最终类别列表
    local -a final_categories=()
    local exclude_list=""

    if [[ -n "$EXCLUDE_CATEGORIES" ]]; then
        exclude_list=$(parse_categories "$EXCLUDE_CATEGORIES")
    fi

    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        if [[ -n "$exclude_list" ]] && is_excluded "$cat" "$exclude_list"; then
            export_log_verbose "排除类别: $cat"
            continue
        fi
        final_categories+=("$cat")
    done < <(parse_categories "$CATEGORIES")

    if [[ ${#final_categories[@]} -eq 0 ]]; then
        log_error "应用排除后没有要导出的类别"
        exit 1
    fi

    # 显示导出配置
    echo -e "${BLUE}${ICON_ADMIN}${NC} 输出文件: ${GRAY}$OUTPUT_FILE${NC}"
    echo -e "${BLUE}${ICON_LIST}${NC} 类别数量: ${GREEN}${#final_categories[@]}${NC}"

    if [[ "$DRY_RUN" == "true" ]]; then
        perform_dry_run "${final_categories[@]}"
        log_operation_session_end "export" "0" "0"
        return 0
    fi

    echo ""

    # 验证输出目录可写
    if ! export_validate_output_path "$OUTPUT_FILE"; then
        log_error "无法写入输出文件"
        exit 1
    fi

    # 初始化统计
    export_reset_stats

    # 生成脚本头部
    export_write_header "$OUTPUT_FILE"
    export_write_runtime_framework "$OUTPUT_FILE"

    # 统计计数器
    local total_categories=0
    local exported_categories=0
    local section_num=1
    local function_calls=""
    
    # 已处理的复合类别组（用于去重）
    local _exported_ide=false
    local _exported_cloud=false
    local _exported_ai=false

    # 遍历类别执行导出
    for category in "${final_categories[@]}"; do
        ((total_categories++))

        case "$category" in
            # 系统级包管理
            brew)
                export_start_section "Homebrew"
                export_brew "$OUTPUT_FILE" 2>/dev/null && ((exported_categories++)) || true
                function_calls="${function_calls}install_homebrew"$'\n'
                export_end_section
                ;;
            mas)
                export_start_section "Mac App Store"
                local mas_count
                mas_count=$(export_mas "$OUTPUT_FILE") || mas_count=0
                if [[ "$mas_count" -gt 0 ]]; then
                    export_log_success "mas: $mas_count 个应用"
                    function_calls="${function_calls}install_mas_apps"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "mas 未安装或无应用"
                fi
                export_end_section
                ;;
            apps)
                export_start_section "Applications"
                export_apps "$OUTPUT_FILE" 2>/dev/null && ((exported_categories++)) || true
                export_end_section
                ;;

            # Node.js 版本管理器
            nvm)
                export_start_section "nvm"
                if export_nvm_installed; then
                    export_nvm_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "nvm 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "nvm 未安装"
                fi
                export_end_section
                ;;
            fnm)
                export_start_section "fnm"
                if export_fnm_installed; then
                    export_fnm_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "fnm 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "fnm 未安装"
                fi
                export_end_section
                ;;

            # Python 版本管理器
            pyenv)
                export_start_section "pyenv"
                if export_pyenv_installed; then
                    export_pyenv_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "pyenv 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "pyenv 未安装"
                fi
                export_end_section
                ;;

            # 其他版本管理器
            rbenv)
                export_start_section "rbenv"
                if export_rbenv_installed; then
                    export_rbenv_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "rbenv 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "rbenv 未安装"
                fi
                export_end_section
                ;;
            goenv)
                export_start_section "goenv"
                if export_goenv_installed; then
                    export_goenv_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "goenv 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "goenv 未安装"
                fi
                export_end_section
                ;;
            jenv)
                export_start_section "jenv"
                if export_jenv_installed; then
                    export_jenv_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "jenv 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "jenv 未安装"
                fi
                export_end_section
                ;;
            rustup)
                export_start_section "rustup"
                if export_rustup_installed; then
                    export_rustup_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "rustup 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "rustup 未安装"
                fi
                export_end_section
                ;;
            mise)
                export_start_section "mise"
                if export_mise_installed; then
                    export_mise_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "mise 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "mise 未安装"
                fi
                export_end_section
                ;;
            asdf)
                export_start_section "asdf"
                if export_asdf_installed; then
                    export_asdf_generate_restore "$OUTPUT_FILE" > /dev/null 2>&1
                    export_log_success "asdf 配置已导出"
                    ((exported_categories++))
                else
                    export_log_skipped "asdf 未安装"
                fi
                export_end_section
                ;;

            # Node.js 包管理器
            npm)
                export_start_section "npm 全局包"
                local npm_count
                npm_count=$(export_npm_packages "$OUTPUT_FILE" 2>/dev/null) || npm_count=0
                if [[ "$npm_count" -gt 0 ]]; then
                    export_log_success "npm: $npm_count 个全局包"
                    function_calls="${function_calls}install_npm_packages"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "npm 未安装或无全局包"
                fi
                export_end_section
                ;;
            pnpm)
                export_start_section "pnpm 全局包"
                local pnpm_count
                pnpm_count=$(export_pnpm_packages "$OUTPUT_FILE" 2>/dev/null) || pnpm_count=0
                if [[ "$pnpm_count" -gt 0 ]]; then
                    export_log_success "pnpm: $pnpm_count 个全局包"
                    function_calls="${function_calls}install_pnpm_packages"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "pnpm 未安装或无全局包"
                fi
                export_end_section
                ;;
            yarn)
                export_start_section "yarn 全局包"
                local yarn_count
                yarn_count=$(export_yarn_packages "$OUTPUT_FILE" 2>/dev/null) || yarn_count=0
                if [[ "$yarn_count" -gt 0 ]]; then
                    export_log_success "yarn: $yarn_count 个全局包"
                    function_calls="${function_calls}install_yarn_packages"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "yarn 未安装或无全局包"
                fi
                export_end_section
                ;;
            bun)
                export_start_section "bun 全局包"
                local bun_count
                bun_count=$(export_bun_packages "$OUTPUT_FILE" 2>/dev/null) || bun_count=0
                if [[ "$bun_count" -gt 0 ]]; then
                    export_log_success "bun: $bun_count 个全局包"
                    function_calls="${function_calls}install_bun_packages"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "bun 未安装或无全局包"
                fi
                export_end_section
                ;;

            # Python 包管理器
            pip)
                export_start_section "pip 用户包"
                local pip_count
                pip_count=$(export_pip_packages "$OUTPUT_FILE" 2>/dev/null) || pip_count=0
                if [[ "$pip_count" -gt 0 ]]; then
                    export_log_success "pip: $pip_count 个用户包"
                    function_calls="${function_calls}install_pip_packages"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "pip 未安装或无用户包"
                fi
                export_end_section
                ;;
            uv)
                export_start_section "uv 工具"
                local uv_count
                uv_count=$(export_uv_tools "$OUTPUT_FILE" 2>/dev/null) || uv_count=0
                if [[ "$uv_count" -gt 0 ]]; then
                    export_log_success "uv: $uv_count 个工具"
                    function_calls="${function_calls}install_uv_tools"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "uv 未安装或无工具"
                fi
                export_end_section
                ;;

            # 其他包管理器
            cargo)
                export_start_section "Cargo crates"
                local cargo_count
                cargo_count=$(export_cargo_crates "$OUTPUT_FILE" 2>/dev/null) || cargo_count=0
                if [[ "$cargo_count" -gt 0 ]]; then
                    export_log_success "cargo: $cargo_count 个 crates"
                    function_calls="${function_calls}install_cargo_crates"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "cargo 未安装或无 crates"
                fi
                export_end_section
                ;;
            go)
                export_start_section "Go 工具"
                local go_count
                go_count=$(export_go_tools "$OUTPUT_FILE" 2>/dev/null) || go_count=0
                if [[ "$go_count" -gt 0 ]]; then
                    export_log_success "go: $go_count 个工具"
                    function_calls="${function_calls}install_go_tools"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "go 未安装或无工具"
                fi
                export_end_section
                ;;
            gem)
                export_start_section "Ruby gems"
                local gem_count
                gem_count=$(export_gem_packages "$OUTPUT_FILE" 2>/dev/null) || gem_count=0
                if [[ "$gem_count" -gt 0 ]]; then
                    export_log_success "gem: $gem_count 个 gems"
                    function_calls="${function_calls}install_gem_packages"$'\n'
                    ((exported_categories++))
                else
                    export_log_skipped "gem 未安装或无 gems"
                fi
                export_end_section
                ;;

            # IDE 和编辑器 (统一处理，避免重复)
            vscode|cursor|windsurf|zed|neovim|vim)
                if [[ "$_exported_ide" == "false" ]]; then
                    _exported_ide=true
                    export_start_section "IDE Extensions"
                    local ide_count
                    ide_count=$(export_ide "$OUTPUT_FILE") || ide_count=0
                    if [[ "$ide_count" -gt 0 ]]; then
                        export_log_success "ide: $ide_count 个扩展"
                        function_calls="${function_calls}install_ide_extensions"$'\n'
                        ((exported_categories++))
                    else
                        export_log_skipped "无 IDE 扩展"
                    fi
                    export_end_section
                fi
                ;;

            # Shell 配置
            shell)
                export_start_section "Shell 配置"
                export_shell "$OUTPUT_FILE" 2>/dev/null && ((exported_categories++)) || true
                function_calls="${function_calls}setup_shell_config"$'\n'
                export_end_section
                ;;

            # Git 配置
            git)
                export_start_section "Git 配置"
                export_git "$OUTPUT_FILE" 2>/dev/null && ((exported_categories++)) || true
                function_calls="${function_calls}setup_git_config"$'\n'
                export_end_section
                ;;

            # Cloud/DevOps 工具 (统一处理，避免重复)
            docker|kubectl|aws|terraform|helm)
                if [[ "$_exported_cloud" == "false" ]]; then
                    _exported_cloud=true
                    export_start_section "Cloud/DevOps"
                    local cloud_count
                    cloud_count=$(export_cloud "$OUTPUT_FILE") || cloud_count=0
                    if [[ "$cloud_count" -gt 0 ]]; then
                        export_log_success "cloud: $cloud_count 个项目"
                        function_calls="${function_calls}restore_docker_images"$'\n'
                        function_calls="${function_calls}restore_helm_repos"$'\n'
                        ((exported_categories++))
                    else
                        export_log_skipped "无 Cloud/DevOps 配置"
                    fi
                    export_end_section
                fi
                ;;

            # AI 工具 (统一处理，避免重复)
            claude|copilot|codeium|continue|aider|ollama)
                if [[ "$_exported_ai" == "false" ]]; then
                    _exported_ai=true
                    export_start_section "AI Tools"
                    local ai_count
                    ai_count=$(export_ai "$OUTPUT_FILE") || ai_count=0
                    if [[ "$ai_count" -gt 0 ]]; then
                        export_log_success "ai: $ai_count 个工具"
                        function_calls="${function_calls}restore_ollama_models"$'\n'
                        ((exported_categories++))
                    else
                        export_log_skipped "无 AI 工具"
                    fi
                    export_end_section
                fi
                ;;

            # CLI 工具
            cli_tools)
                export_start_section "CLI 工具"
                export_cli_tools "$OUTPUT_FILE" 2>/dev/null && ((exported_categories++)) || true
                function_calls="${function_calls}restore_cli_tools"$'\n'
                export_end_section
                ;;

            *)
                export_log_warning "未知类别: $category"
                ;;
        esac
    done

    # 生成主函数调用
    # 去重函数调用列表
    local unique_calls=""
    while IFS= read -r call; do
        [[ -z "$call" ]] && continue
        if ! echo "$unique_calls" | grep -qx "$call"; then
            unique_calls="${unique_calls}${call}"$'\n'
        fi
    done <<< "$function_calls"

    export_write_main_function "$OUTPUT_FILE" "$unique_calls"
    export_write_footer "$OUTPUT_FILE"

    # 设置可执行权限
    chmod +x "$OUTPUT_FILE"

    # 显示总结
    echo ""

    local summary_heading="导出完成"
    local total_items
    total_items=$(export_get_total_count)

    local -a summary_details=()
    summary_details+=("扫描类别: $total_categories")
    summary_details+=("成功导出: $exported_categories")
    summary_details+=("总项目数: $total_items")
    summary_details+=("输出文件: ${GRAY}$OUTPUT_FILE${NC}")
    summary_details+=("")
    summary_details+=("运行以下命令应用配置:")
    summary_details+=("  ${GRAY}chmod +x $OUTPUT_FILE && $OUTPUT_FILE${NC}")

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'

    # 显示详细统计
    export_show_summary

    log_operation_session_end "export" "$total_items" "0"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    parse_args "$@"
    hide_cursor
    perform_export
    show_cursor
    exit 0
}

main "$@"
