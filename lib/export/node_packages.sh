#!/bin/bash
# Mole - Node.js Package Managers Export Module
# 导出 npm/pnpm/yarn/bun 全局包
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_NODE_PACKAGES_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_NODE_PACKAGES_LOADED=1

# =============================================================================
# 内部辅助函数
# =============================================================================

# 检查命令是否存在 (模块内部使用)
_node_cmd_exists() {
    command -v "$1" > /dev/null 2>&1
}

# =============================================================================
# npm 全局包导出
# =============================================================================

# 获取 npm 全局包列表
# 返回: 包名@版本 格式，每行一个
# 输出到 stdout: 包列表
_export_npm_get_packages() {
    if ! _node_cmd_exists "npm"; then
        return 1
    fi

    local npm_json
    npm_json=$(npm list -g --depth=0 --json 2>/dev/null) || return 1

    # 检查是否有依赖
    if ! echo "$npm_json" | grep -q '"dependencies"'; then
        return 0
    fi

    # 解析 JSON 提取包名和版本
    # 格式: "package-name": { "version": "1.0.0", ... }
    echo "$npm_json" | grep -E '^\s+"[^"]+": \{' | while IFS= read -r line; do
        local pkg_name
        pkg_name=$(echo "$line" | sed -E 's/.*"([^"]+)".*/\1/')
        
        # 跳过 npm 自身
        [[ "$pkg_name" == "npm" ]] && continue
        
        # 获取版本号
        local version
        version=$(echo "$npm_json" | grep -A1 "\"$pkg_name\":" | grep '"version"' | sed -E 's/.*"version":\s*"([^"]+)".*/\1/' | head -1)
        
        if [[ -n "$version" ]]; then
            echo "${pkg_name}@${version}"
        else
            echo "$pkg_name"
        fi
    done
}

# 导出 npm 全局包
# 参数: $1 - 输出文件描述符
# 返回: 导出的包数量
export_npm_packages() {
    local output_file="$1"
    local count=0

    if ! _node_cmd_exists "npm"; then
        return 0
    fi

    local packages
    packages=$(_export_npm_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    # 写入章节
    cat >> "$output_file" << 'EOF'

# =============================================================================
# npm Global Packages
# =============================================================================

install_npm_packages() {
    if ! command -v npm > /dev/null 2>&1; then
        echo "npm not found, skipping npm packages..."
        return 0
    fi

    echo "Installing npm global packages..."

EOF

    # 写入每个包的安装命令（带幂等检查）
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        local pkg_name="${pkg%%@*}"
        
        cat >> "$output_file" << EOF
    # 安装 $pkg_name
    if ! npm list -g "$pkg_name" > /dev/null 2>&1; then
        npm install -g "$pkg" || echo "Warning: Failed to install $pkg"
    fi
EOF
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "npm packages installation completed."
}

install_npm_packages

EOF

    echo "$count"
}

# =============================================================================
# pnpm 全局包导出
# =============================================================================

# 获取 pnpm 全局包列表
_export_pnpm_get_packages() {
    if ! _node_cmd_exists "pnpm"; then
        return 1
    fi

    # pnpm list -g --depth=0 输出格式解析
    pnpm list -g --depth=0 2>/dev/null | grep -E '^\s*[a-zA-Z@]' | while IFS= read -r line; do
        # 提取包名（格式可能是 "package-name 1.0.0" 或带 @ 前缀的作用域包）
        local pkg
        pkg=$(echo "$line" | awk '{print $1}')
        
        # 跳过 pnpm 自身和空行
        [[ -z "$pkg" || "$pkg" == "pnpm" ]] && continue
        
        # 提取版本
        local version
        version=$(echo "$line" | awk '{print $2}')
        
        if [[ -n "$version" && "$version" =~ ^[0-9] ]]; then
            echo "${pkg}@${version}"
        else
            echo "$pkg"
        fi
    done
}

# 导出 pnpm 全局包
# 参数: $1 - 输出文件描述符
# 返回: 导出的包数量
export_pnpm_packages() {
    local output_file="$1"
    local count=0

    if ! _node_cmd_exists "pnpm"; then
        return 0
    fi

    local packages
    packages=$(_export_pnpm_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# pnpm Global Packages
# =============================================================================

install_pnpm_packages() {
    if ! command -v pnpm > /dev/null 2>&1; then
        echo "pnpm not found, skipping pnpm packages..."
        return 0
    fi

    echo "Installing pnpm global packages..."

EOF

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        local pkg_name="${pkg%%@*}"
        
        cat >> "$output_file" << EOF
    # 安装 $pkg_name
    if ! pnpm list -g "$pkg_name" > /dev/null 2>&1; then
        pnpm add -g "$pkg" || echo "Warning: Failed to install $pkg"
    fi
EOF
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "pnpm packages installation completed."
}

install_pnpm_packages

EOF

    echo "$count"
}

# =============================================================================
# yarn 全局包导出
# =============================================================================

# 获取 yarn 全局包列表
_export_yarn_get_packages() {
    if ! _node_cmd_exists "yarn"; then
        return 1
    fi

    # yarn global list 输出格式：info "package@version" has binaries
    yarn global list 2>/dev/null | grep -E '^info "' | while IFS= read -r line; do
        # 提取引号中的 package@version
        local pkg_version
        pkg_version=$(echo "$line" | sed -E 's/^info "([^"]+)".*/\1/')
        
        [[ -n "$pkg_version" ]] && echo "$pkg_version"
    done
}

# 导出 yarn 全局包
# 参数: $1 - 输出文件描述符
# 返回: 导出的包数量
export_yarn_packages() {
    local output_file="$1"
    local count=0

    if ! _node_cmd_exists "yarn"; then
        return 0
    fi

    local packages
    packages=$(_export_yarn_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# Yarn Global Packages
# =============================================================================

install_yarn_packages() {
    if ! command -v yarn > /dev/null 2>&1; then
        echo "yarn not found, skipping yarn packages..."
        return 0
    fi

    echo "Installing yarn global packages..."

EOF

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        local pkg_name="${pkg%%@*}"
        
        cat >> "$output_file" << EOF
    # 安装 $pkg_name
    if ! yarn global list 2>/dev/null | grep -q "\"$pkg_name@"; then
        yarn global add "$pkg" || echo "Warning: Failed to install $pkg"
    fi
EOF
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "yarn packages installation completed."
}

install_yarn_packages

EOF

    echo "$count"
}

# =============================================================================
# bun 全局包导出
# =============================================================================

# 获取 bun 全局包列表
_export_bun_get_packages() {
    if ! _node_cmd_exists "bun"; then
        return 1
    fi

    # 检查 ~/.bun 目录是否存在
    if [[ ! -d "$HOME/.bun" ]]; then
        return 1
    fi

    # bun pm ls -g 输出解析
    bun pm ls -g 2>/dev/null | grep -E '^\s*[├└]' | while IFS= read -r line; do
        # 提取包名和版本，格式类似 "├── package@version"
        local pkg_version
        pkg_version=$(echo "$line" | sed -E 's/.*[├└]── ([^ ]+).*/\1/')
        
        [[ -n "$pkg_version" ]] && echo "$pkg_version"
    done
}

# 导出 bun 全局包
# 参数: $1 - 输出文件描述符
# 返回: 导出的包数量
export_bun_packages() {
    local output_file="$1"
    local count=0

    if ! _node_cmd_exists "bun"; then
        return 0
    fi

    # 检查 ~/.bun 目录
    if [[ ! -d "$HOME/.bun" ]]; then
        return 0
    fi

    local packages
    packages=$(_export_bun_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# Bun Global Packages
# =============================================================================

install_bun_packages() {
    if ! command -v bun > /dev/null 2>&1; then
        echo "bun not found, skipping bun packages..."
        return 0
    fi

    echo "Installing bun global packages..."

EOF

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        local pkg_name="${pkg%%@*}"
        
        cat >> "$output_file" << EOF
    # 安装 $pkg_name
    if ! bun pm ls -g 2>/dev/null | grep -q "$pkg_name@"; then
        bun add -g "$pkg" || echo "Warning: Failed to install $pkg"
    fi
EOF
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "bun packages installation completed."
}

install_bun_packages

EOF

    echo "$count"
}

# =============================================================================
# 主导出函数
# =============================================================================

# 导出所有 Node.js 包管理器的全局包
# 参数: $1 - 输出文件路径
# 返回: 导出的总包数量 (通过 stdout)
export_node_packages() {
    local output_file="$1"
    local total_count=0

    # npm
    local npm_count
    npm_count=$(export_npm_packages "$output_file" 2>/dev/null) || npm_count=0
    [[ -n "$npm_count" ]] && ((total_count += npm_count)) || true

    # pnpm
    local pnpm_count
    pnpm_count=$(export_pnpm_packages "$output_file" 2>/dev/null) || pnpm_count=0
    [[ -n "$pnpm_count" ]] && ((total_count += pnpm_count)) || true

    # yarn
    local yarn_count
    yarn_count=$(export_yarn_packages "$output_file" 2>/dev/null) || yarn_count=0
    [[ -n "$yarn_count" ]] && ((total_count += yarn_count)) || true

    # bun
    local bun_count
    bun_count=$(export_bun_packages "$output_file" 2>/dev/null) || bun_count=0
    [[ -n "$bun_count" ]] && ((total_count += bun_count)) || true

    echo "$total_count"
}

# =============================================================================
# 检测函数
# =============================================================================

# 检测可用的 Node.js 包管理器
# 返回: 检测到的包管理器列表 (以空格分隔)
detect_node_package_managers() {
    local managers=""
    
    _node_cmd_exists "npm" && managers="$managers npm"
    _node_cmd_exists "pnpm" && managers="$managers pnpm"
    _node_cmd_exists "yarn" && managers="$managers yarn"
    _node_cmd_exists "bun" && [[ -d "$HOME/.bun" ]] && managers="$managers bun"
    
    echo "${managers# }"
}

# 获取各包管理器的全局包数量统计
# 返回: JSON 格式的统计信息
get_node_packages_stats() {
    local stats="{"
    local first=true
    
    if _node_cmd_exists "npm"; then
        local npm_count
        npm_count=$(npm list -g --depth=0 --json 2>/dev/null | grep -c '"version"' || echo "0")
        # 减去 npm 自身
        ((npm_count > 0)) && ((npm_count--)) || true
        $first || stats="$stats,"
        stats="$stats\"npm\":$npm_count"
        first=false
    fi
    
    if _node_cmd_exists "pnpm"; then
        local pnpm_count
        pnpm_count=$(pnpm list -g --depth=0 2>/dev/null | grep -cE '^\s*[a-zA-Z@]' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"pnpm\":$pnpm_count"
        first=false
    fi
    
    if _node_cmd_exists "yarn"; then
        local yarn_count
        yarn_count=$(yarn global list 2>/dev/null | grep -c '^info "' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"yarn\":$yarn_count"
        first=false
    fi
    
    if _node_cmd_exists "bun" && [[ -d "$HOME/.bun" ]]; then
        local bun_count
        bun_count=$(bun pm ls -g 2>/dev/null | grep -cE '^\s*[├└]' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"bun\":$bun_count"
        first=false
    fi
    
    stats="$stats}"
    echo "$stats"
}
