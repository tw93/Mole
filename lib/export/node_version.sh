#!/bin/bash
# Mole - Node.js Version Manager Export
# 导出 Node.js 版本管理器配置 (nvm, fnm)
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_NODE_VERSION_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_NODE_VERSION_LOADED=1

# 加载依赖
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# =============================================================================
# nvm 检测和导出
# =============================================================================

# 检查 nvm 是否安装
# 返回: 0 已安装, 1 未安装
export_nvm_installed() {
    [[ -d "${NVM_DIR:-$HOME/.nvm}" ]] && [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]
}

# 获取 nvm 安装的 Node.js 版本列表
# 输出: 每行一个版本号 (不带 v 前缀)
export_nvm_list_versions() {
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    local versions_dir="$nvm_dir/versions/node"

    if [[ ! -d "$versions_dir" ]]; then
        return 0
    fi

    # 直接读取版本目录，避免 source nvm.sh (可能很慢)
    local version
    for version_path in "$versions_dir"/v*; do
        if [[ -d "$version_path" ]]; then
            version=$(basename "$version_path")
            # 去除 v 前缀
            echo "${version#v}"
        fi
    done | sort -V
}

# 获取 nvm 默认版本
# 输出: 默认版本号，如果未设置则为空
export_nvm_get_default() {
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    local alias_dir="$nvm_dir/alias"

    if [[ -f "$alias_dir/default" ]]; then
        local default_alias
        default_alias=$(cat "$alias_dir/default" 2>/dev/null || true)
        # 移除可能的 v 前缀和空白字符
        default_alias="${default_alias#v}"
        default_alias="${default_alias// /}"
        echo "$default_alias"
    fi
}

# =============================================================================
# fnm 检测和导出
# =============================================================================

# 检查 fnm 是否安装
# 返回: 0 已安装, 1 未安装
export_fnm_installed() {
    command -v fnm > /dev/null 2>&1
}

# 获取 fnm 安装的 Node.js 版本列表
# 输出: 每行一个版本号 (不带 v 前缀)
export_fnm_list_versions() {
    if ! export_fnm_installed; then
        return 0
    fi

    # fnm list 输出格式: * v20.11.0 default
    fnm list 2>/dev/null | while read -r line; do
        # 移除前导符号 (* 或空格)
        local version
        version=$(echo "$line" | sed 's/^[* ]*//' | awk '{print $1}')
        # 去除 v 前缀
        version="${version#v}"
        if [[ -n "$version" && "$version" != "system" ]]; then
            echo "$version"
        fi
    done | sort -V
}

# 获取 fnm 默认版本
# 输出: 默认版本号，如果未设置则为空
export_fnm_get_default() {
    if ! export_fnm_installed; then
        return 0
    fi

    # 从 fnm list 输出中查找 default 标记
    fnm list 2>/dev/null | grep -E 'default|^\*' | head -1 | sed 's/^[* ]*//' | awk '{print $1}' | sed 's/^v//'
}

# =============================================================================
# 脚本生成函数
# =============================================================================

# 生成 nvm 恢复脚本
# 参数: $1 - 输出文件描述符或文件路径
export_nvm_generate_restore() {
    local output="$1"

    if ! export_nvm_installed; then
        return 0
    fi

    local versions
    versions=$(export_nvm_list_versions)
    local default_version
    default_version=$(export_nvm_get_default)
    local version_count=0

    if [[ -z "$versions" ]]; then
        return 0
    fi

    # 写入章节头
    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# nvm - Node Version Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 nvm (如果未安装)"
        echo 'if [[ ! -d "${NVM_DIR:-$HOME/.nvm}" ]]; then'
        echo '    echo "Installing nvm..."'
        echo '    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
        echo 'fi'
        echo ""
        echo "# 加载 nvm"
        echo 'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"'
        echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
        echo ""
        echo "# 安装 Node.js 版本"
    } >> "$output"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "nvm install $version" >> "$output"
        ((version_count++))
    done <<< "$versions"

    # 设置默认版本
    if [[ -n "$default_version" ]]; then
        echo "" >> "$output"
        echo "# 设置默认版本" >> "$output"
        echo "nvm alias default $default_version" >> "$output"
        echo "nvm use default" >> "$output"
    fi

    echo "" >> "$output"
    echo "echo \"nvm: $version_count Node.js version(s) installed\"" >> "$output"

    echo "$version_count"
}

# 生成 fnm 恢复脚本
# 参数: $1 - 输出文件描述符或文件路径
export_fnm_generate_restore() {
    local output="$1"

    if ! export_fnm_installed; then
        return 0
    fi

    local versions
    versions=$(export_fnm_list_versions)
    local default_version
    default_version=$(export_fnm_get_default)
    local version_count=0

    if [[ -z "$versions" ]]; then
        return 0
    fi

    # 写入章节头
    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# fnm - Fast Node Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 fnm (如果未安装)"
        echo 'if ! command -v fnm > /dev/null 2>&1; then'
        echo '    echo "Installing fnm..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install fnm'
        echo '    else'
        echo '        curl -fsSL https://fnm.vercel.app/install | bash'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 初始化 fnm"
        echo 'eval "$(fnm env --use-on-cd)"'
        echo ""
        echo "# 安装 Node.js 版本"
    } >> "$output"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "fnm install $version" >> "$output"
        ((version_count++))
    done <<< "$versions"

    # 设置默认版本
    if [[ -n "$default_version" ]]; then
        echo "" >> "$output"
        echo "# 设置默认版本" >> "$output"
        echo "fnm default $default_version" >> "$output"
    fi

    echo "" >> "$output"
    echo "echo \"fnm: $version_count Node.js version(s) installed\"" >> "$output"

    echo "$version_count"
}

# =============================================================================
# 主导出函数
# =============================================================================

# 导出 Node.js 版本管理器配置
# 参数: $1 - 输出文件路径
# 返回: 检测到的工具数量 (通过 stdout 输出)
export_node_version_managers() {
    local output_file="$1"
    local detected_count=0

    # 检测并导出 nvm
    if export_nvm_installed; then
        export_log_info "nvm detected at ${NVM_DIR:-$HOME/.nvm}"
        local nvm_versions
        nvm_versions=$(export_nvm_list_versions | wc -l | tr -d ' ')
        if [[ "$nvm_versions" -gt 0 ]]; then
            export_log_info "  Found $nvm_versions Node.js version(s)"
            local default_ver
            default_ver=$(export_nvm_get_default)
            if [[ -n "$default_ver" ]]; then
                export_log_info "  Default version: $default_ver"
            fi
            if [[ -n "$output_file" ]]; then
                export_nvm_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        else
            export_log_info "  No Node.js versions installed via nvm"
        fi
    fi

    # 检测并导出 fnm
    if export_fnm_installed; then
        export_log_info "fnm detected"
        local fnm_versions
        fnm_versions=$(export_fnm_list_versions | wc -l | tr -d ' ')
        if [[ "$fnm_versions" -gt 0 ]]; then
            export_log_info "  Found $fnm_versions Node.js version(s)"
            local default_ver
            default_ver=$(export_fnm_get_default)
            if [[ -n "$default_ver" ]]; then
                export_log_info "  Default version: $default_ver"
            fi
            if [[ -n "$output_file" ]]; then
                export_fnm_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        else
            export_log_info "  No Node.js versions installed via fnm"
        fi
    fi

    # 如果没有检测到任何版本管理器
    if [[ "$detected_count" -eq 0 ]]; then
        export_log_skipped "No Node.js version manager detected (nvm/fnm)"
    fi

    echo "$detected_count"
}
