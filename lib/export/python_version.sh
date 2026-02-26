#!/bin/bash
# Mole - Python Version Manager Export
# 导出 Python 版本管理器配置 (pyenv)
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_PYTHON_VERSION_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_PYTHON_VERSION_LOADED=1

# 加载依赖
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# =============================================================================
# pyenv 检测和导出
# =============================================================================

# 检查 pyenv 是否安装
# 返回: 0 已安装, 1 未安装
export_pyenv_installed() {
    command -v pyenv > /dev/null 2>&1
}

# 获取 pyenv 安装的 Python 版本列表
# 输出: 每行一个版本号
export_pyenv_list_versions() {
    if ! export_pyenv_installed; then
        return 0
    fi

    # --bare 输出纯版本号，不带 * 标记
    pyenv versions --bare 2>/dev/null | while read -r version; do
        # 跳过 system
        if [[ "$version" != "system" && -n "$version" ]]; then
            echo "$version"
        fi
    done | sort -V
}

# 获取 pyenv 全局版本设置
# 输出: 全局版本号，如果未设置则为空
export_pyenv_get_global() {
    if ! export_pyenv_installed; then
        return 0
    fi

    local global_version
    global_version=$(pyenv global 2>/dev/null || true)
    # 处理可能的多版本设置 (pyenv 支持设置多个全局版本)
    # 取第一个非 system 版本
    echo "$global_version" | while read -r ver; do
        if [[ "$ver" != "system" && -n "$ver" ]]; then
            echo "$ver"
            break
        fi
    done
}

# 获取 pyenv 本地版本设置列表
# 输出: 目录:版本 格式的列表
export_pyenv_list_local_versions() {
    if ! export_pyenv_installed; then
        return 0
    fi

    local pyenv_root
    pyenv_root=$(pyenv root 2>/dev/null || echo "$HOME/.pyenv")

    # 搜索 .python-version 文件
    # 只在常见开发目录下搜索，避免全盘扫描
    local search_dirs=("$HOME/Projects" "$HOME/workspace" "$HOME/code" "$HOME/dev")

    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            find "$dir" -maxdepth 3 -name ".python-version" -type f 2>/dev/null | while read -r file; do
                local project_dir
                project_dir=$(dirname "$file")
                local version
                version=$(cat "$file" 2>/dev/null | head -1)
                if [[ -n "$version" ]]; then
                    echo "${project_dir}:${version}"
                fi
            done
        fi
    done
}

# =============================================================================
# 脚本生成函数
# =============================================================================

# 生成 pyenv 恢复脚本
# 参数: $1 - 输出文件路径
# 返回: 安装的版本数量
export_pyenv_generate_restore() {
    local output="$1"

    if ! export_pyenv_installed; then
        return 0
    fi

    local versions
    versions=$(export_pyenv_list_versions)
    local global_version
    global_version=$(export_pyenv_get_global)
    local version_count=0

    if [[ -z "$versions" ]]; then
        return 0
    fi

    # 写入章节头
    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# pyenv - Python Version Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 pyenv (如果未安装)"
        echo 'if ! command -v pyenv > /dev/null 2>&1; then'
        echo '    echo "Installing pyenv..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install pyenv'
        echo '    else'
        echo '        curl https://pyenv.run | bash'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 初始化 pyenv"
        echo 'export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"'
        echo '[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        echo 'eval "$(pyenv init -)"'
        echo ""
        echo "# 安装编译依赖 (macOS)"
        echo 'if [[ "$(uname)" == "Darwin" ]] && command -v brew > /dev/null 2>&1; then'
        echo '    brew install openssl readline sqlite3 xz zlib tcl-tk 2>/dev/null || true'
        echo 'fi'
        echo ""
        echo "# 安装 Python 版本"
    } >> "$output"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "pyenv install -s $version" >> "$output"
        ((version_count++))
    done <<< "$versions"

    # 设置全局版本
    if [[ -n "$global_version" ]]; then
        echo "" >> "$output"
        echo "# 设置全局版本" >> "$output"
        echo "pyenv global $global_version" >> "$output"
    fi

    echo "" >> "$output"
    echo "pyenv rehash" >> "$output"
    echo "echo \"pyenv: $version_count Python version(s) installed\"" >> "$output"

    echo "$version_count"
}

# =============================================================================
# 主导出函数
# =============================================================================

# 导出 Python 版本管理器配置
# 参数: $1 - 输出文件路径
# 返回: 检测到的工具数量 (通过 stdout 输出)
export_python_version_managers() {
    local output_file="$1"
    local detected_count=0

    # 检测并导出 pyenv
    if export_pyenv_installed; then
        local pyenv_root
        pyenv_root=$(pyenv root 2>/dev/null || echo "$HOME/.pyenv")
        export_log_info "pyenv detected at $pyenv_root"

        local pyenv_versions
        pyenv_versions=$(export_pyenv_list_versions | wc -l | tr -d ' ')
        if [[ "$pyenv_versions" -gt 0 ]]; then
            export_log_info "  Found $pyenv_versions Python version(s)"

            # 显示已安装版本
            local versions_list
            versions_list=$(export_pyenv_list_versions | head -5 | tr '\n' ', ' | sed 's/,$//')
            if [[ "$pyenv_versions" -gt 5 ]]; then
                versions_list="$versions_list, ..."
            fi
            export_log_verbose "  Versions: $versions_list"

            local global_ver
            global_ver=$(export_pyenv_get_global)
            if [[ -n "$global_ver" ]]; then
                export_log_info "  Global version: $global_ver"
            fi

            if [[ -n "$output_file" ]]; then
                export_pyenv_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        else
            export_log_info "  No Python versions installed via pyenv"
        fi
    else
        export_log_skipped "pyenv not detected"
    fi

    echo "$detected_count"
}
