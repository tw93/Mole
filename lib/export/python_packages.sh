#!/bin/bash
# Mole - Python Package Managers Export Module
# 导出 pip/uv 全局包及检测 poetry/pdm/rye
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_PYTHON_PACKAGES_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_PYTHON_PACKAGES_LOADED=1

# =============================================================================
# 内部辅助函数
# =============================================================================

# 检查命令是否存在 (模块内部使用)
_python_cmd_exists() {
    command -v "$1" > /dev/null 2>&1
}

# 获取可用的 pip 命令
_get_pip_cmd() {
    if _python_cmd_exists "pip3"; then
        echo "pip3"
    elif _python_cmd_exists "pip"; then
        echo "pip"
    else
        return 1
    fi
}

# 获取可用的 python 命令
_get_python_cmd() {
    if _python_cmd_exists "python3"; then
        echo "python3"
    elif _python_cmd_exists "python"; then
        echo "python"
    else
        return 1
    fi
}

# =============================================================================
# pip 用户全局包导出
# =============================================================================

# 获取 pip 用户全局包列表
# 返回: 包名==版本 格式，每行一个
_export_pip_get_packages() {
    local pip_cmd
    pip_cmd=$(_get_pip_cmd) || return 1

    # 使用 --user 获取用户级别安装的包
    # --format=freeze 输出 package==version 格式
    $pip_cmd list --user --format=freeze 2>/dev/null | while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 跳过 pip、setuptools、wheel 等基础包
        local pkg_name="${line%%=*}"
        pkg_name="${pkg_name%%>*}"
        pkg_name="${pkg_name%%<*}"
        
        case "$pkg_name" in
            pip|setuptools|wheel|pkg-resources|distribute)
                continue
                ;;
        esac
        
        echo "$line"
    done
}

# 导出 pip 用户全局包
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_pip_packages() {
    local output_file="$1"
    local count=0
    
    local pip_cmd
    pip_cmd=$(_get_pip_cmd) || return 0

    local packages
    packages=$(_export_pip_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    # 写入章节
    cat >> "$output_file" << 'EOF'

# =============================================================================
# pip User Packages
# =============================================================================

install_pip_packages() {
    local pip_cmd=""
    if command -v pip3 > /dev/null 2>&1; then
        pip_cmd="pip3"
    elif command -v pip > /dev/null 2>&1; then
        pip_cmd="pip"
    else
        echo "pip not found, skipping pip packages..."
        return 0
    fi

    echo "Installing pip user packages..."

EOF

    # 写入每个包的安装命令（带幂等检查）
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        # 提取包名 (处理 == > < 等版本符号)
        local pkg_name="${pkg%%=*}"
        pkg_name="${pkg_name%%>*}"
        pkg_name="${pkg_name%%<*}"
        
        cat >> "$output_file" << EOF
    # 安装 $pkg_name
    if ! \$pip_cmd show "$pkg_name" > /dev/null 2>&1; then
        \$pip_cmd install --user "$pkg" || echo "Warning: Failed to install $pkg"
    fi
EOF
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "pip packages installation completed."
}

install_pip_packages

EOF

    echo "$count"
}

# =============================================================================
# uv 工具导出
# =============================================================================

# 获取 uv 工具列表
_export_uv_get_tools() {
    if ! _python_cmd_exists "uv"; then
        return 1
    fi

    # uv tool list 输出格式解析
    # 格式: tool-name v1.0.0
    uv tool list 2>/dev/null | while IFS= read -r line; do
        # 跳过空行和标题行
        [[ -z "$line" || "$line" =~ ^- ]] && continue
        
        # 提取工具名和版本
        local tool_name tool_version
        tool_name=$(echo "$line" | awk '{print $1}')
        tool_version=$(echo "$line" | awk '{print $2}')
        
        [[ -z "$tool_name" ]] && continue
        
        # 移除版本号前的 'v' 前缀
        tool_version="${tool_version#v}"
        
        if [[ -n "$tool_version" ]]; then
            echo "${tool_name}==${tool_version}"
        else
            echo "$tool_name"
        fi
    done
}

# 导出 uv 工具
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_uv_tools() {
    local output_file="$1"
    local count=0

    if ! _python_cmd_exists "uv"; then
        return 0
    fi

    local tools
    tools=$(_export_uv_get_tools 2>/dev/null) || return 0

    if [[ -z "$tools" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# uv Tools
# =============================================================================

install_uv_tools() {
    if ! command -v uv > /dev/null 2>&1; then
        echo "uv not found, skipping uv tools..."
        return 0
    fi

    echo "Installing uv tools..."

EOF

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        local tool_name="${tool%%=*}"
        
        cat >> "$output_file" << EOF
    # 安装 $tool_name
    if ! uv tool list 2>/dev/null | grep -q "^$tool_name "; then
        uv tool install "$tool_name" || echo "Warning: Failed to install $tool_name"
    fi
EOF
        ((count++))
    done <<< "$tools"

    cat >> "$output_file" << 'EOF'

    echo "uv tools installation completed."
}

install_uv_tools

EOF

    echo "$count"
}

# =============================================================================
# pipx 工具导出
# =============================================================================

# 获取 pipx 安装的工具列表
_export_pipx_get_tools() {
    if ! _python_cmd_exists "pipx"; then
        return 1
    fi

    # pipx list --short 输出格式: package version
    pipx list --short 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local pkg_name pkg_version
        pkg_name=$(echo "$line" | awk '{print $1}')
        pkg_version=$(echo "$line" | awk '{print $2}')
        
        if [[ -n "$pkg_version" ]]; then
            echo "${pkg_name}==${pkg_version}"
        else
            echo "$pkg_name"
        fi
    done
}

# 导出 pipx 工具
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_pipx_tools() {
    local output_file="$1"
    local count=0

    if ! _python_cmd_exists "pipx"; then
        return 0
    fi

    local tools
    tools=$(_export_pipx_get_tools 2>/dev/null) || return 0

    if [[ -z "$tools" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# pipx Tools
# =============================================================================

install_pipx_tools() {
    if ! command -v pipx > /dev/null 2>&1; then
        echo "pipx not found, skipping pipx tools..."
        return 0
    fi

    echo "Installing pipx tools..."

EOF

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        local tool_name="${tool%%=*}"
        
        cat >> "$output_file" << EOF
    # 安装 $tool_name
    if ! pipx list --short 2>/dev/null | grep -q "^$tool_name "; then
        pipx install "$tool_name" || echo "Warning: Failed to install $tool_name"
    fi
EOF
        ((count++))
    done <<< "$tools"

    cat >> "$output_file" << 'EOF'

    echo "pipx tools installation completed."
}

install_pipx_tools

EOF

    echo "$count"
}

# =============================================================================
# poetry/pdm/rye 检测 (项目级别工具，仅提示)
# =============================================================================

# 检测并提示项目级别的 Python 包管理器
# 参数: $1 - 输出文件路径
# 返回: 检测到的工具数量
export_python_project_tools_hint() {
    local output_file="$1"
    local detected=""
    local count=0

    # 检测 poetry
    if _python_cmd_exists "poetry"; then
        detected="$detected poetry"
        ((count++))
    fi

    # 检测 pdm
    if _python_cmd_exists "pdm"; then
        detected="$detected pdm"
        ((count++))
    fi

    # 检测 rye
    if _python_cmd_exists "rye"; then
        detected="$detected rye"
        ((count++))
    fi

    # 检测 hatch
    if _python_cmd_exists "hatch"; then
        detected="$detected hatch"
        ((count++))
    fi

    if [[ -z "$detected" ]]; then
        return 0
    fi

    cat >> "$output_file" << EOF

# =============================================================================
# Python Project Tools (Detected)
# =============================================================================
# 以下工具主要用于项目级别的包管理，通常不需要全局恢复:
#   检测到:$detected
#
# 这些工具通常通过以下方式安装:
#   - poetry:  pipx install poetry 或 curl -sSL https://install.python-poetry.org | python3 -
#   - pdm:     pipx install pdm 或 curl -sSL https://pdm-project.org/install-pdm.py | python3 -
#   - rye:     curl -sSf https://rye.astral.sh/get | bash
#   - hatch:   pipx install hatch
#
# 项目依赖通常记录在 pyproject.toml 中，可通过对应工具的 install 命令恢复
# =============================================================================

EOF

    echo "$count"
}

# =============================================================================
# 主导出函数
# =============================================================================

# 导出所有 Python 包管理器的全局包
# 参数: $1 - 输出文件路径
# 返回: 导出的总包数量 (通过 stdout)
export_python_packages() {
    local output_file="$1"
    local total_count=0

    # pip 用户包
    local pip_count
    pip_count=$(export_pip_packages "$output_file" 2>/dev/null) || pip_count=0
    [[ -n "$pip_count" ]] && ((total_count += pip_count)) || true

    # uv 工具
    local uv_count
    uv_count=$(export_uv_tools "$output_file" 2>/dev/null) || uv_count=0
    [[ -n "$uv_count" ]] && ((total_count += uv_count)) || true

    # pipx 工具
    local pipx_count
    pipx_count=$(export_pipx_tools "$output_file" 2>/dev/null) || pipx_count=0
    [[ -n "$pipx_count" ]] && ((total_count += pipx_count)) || true

    # 项目级别工具提示 (不计入总数)
    export_python_project_tools_hint "$output_file" 2>/dev/null || true

    echo "$total_count"
}

# =============================================================================
# 检测函数
# =============================================================================

# 检测可用的 Python 包管理器
# 返回: 检测到的包管理器列表 (以空格分隔)
detect_python_package_managers() {
    local managers=""
    
    _python_cmd_exists "pip3" && managers="$managers pip3"
    _python_cmd_exists "pip" && [[ -z "$managers" ]] && managers="$managers pip"
    _python_cmd_exists "uv" && managers="$managers uv"
    _python_cmd_exists "pipx" && managers="$managers pipx"
    _python_cmd_exists "poetry" && managers="$managers poetry"
    _python_cmd_exists "pdm" && managers="$managers pdm"
    _python_cmd_exists "rye" && managers="$managers rye"
    _python_cmd_exists "hatch" && managers="$managers hatch"
    
    echo "${managers# }"
}

# 获取各包管理器的包数量统计
# 返回: JSON 格式的统计信息
get_python_packages_stats() {
    local stats="{"
    local first=true
    
    local pip_cmd
    pip_cmd=$(_get_pip_cmd 2>/dev/null) || pip_cmd=""
    
    if [[ -n "$pip_cmd" ]]; then
        local pip_count
        pip_count=$($pip_cmd list --user --format=freeze 2>/dev/null | grep -cv '^\s*$' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"pip\":$pip_count"
        first=false
    fi
    
    if _python_cmd_exists "uv"; then
        local uv_count
        uv_count=$(uv tool list 2>/dev/null | grep -cv '^\s*$' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"uv\":$uv_count"
        first=false
    fi
    
    if _python_cmd_exists "pipx"; then
        local pipx_count
        pipx_count=$(pipx list --short 2>/dev/null | grep -cv '^\s*$' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"pipx\":$pipx_count"
        first=false
    fi
    
    stats="$stats}"
    echo "$stats"
}
