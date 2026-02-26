#!/bin/bash
# Mole - Other Package Managers Export Module
# 导出 Rust(cargo)/Go/Ruby(gem)/PHP(composer) 全局包
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_OTHER_PACKAGES_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_OTHER_PACKAGES_LOADED=1

# =============================================================================
# 内部辅助函数
# =============================================================================

# 检查命令是否存在 (模块内部使用)
_other_cmd_exists() {
    command -v "$1" > /dev/null 2>&1
}

# =============================================================================
# Cargo (Rust) crates 导出
# =============================================================================

# 获取 cargo 安装的 crates 列表
# 返回: crate@version 格式，每行一个
_export_cargo_get_crates() {
    if ! _other_cmd_exists "cargo"; then
        return 1
    fi

    # cargo install --list 输出格式:
    # crate-name v1.0.0:
    #     binary-name
    cargo install --list 2>/dev/null | grep -E '^[a-zA-Z].*:$' | while IFS= read -r line; do
        # 移除末尾的冒号
        line="${line%:}"
        
        # 提取 crate 名和版本
        local crate_name crate_version
        crate_name=$(echo "$line" | awk '{print $1}')
        crate_version=$(echo "$line" | awk '{print $2}')
        
        [[ -z "$crate_name" ]] && continue
        
        # 移除版本号前的 'v' 前缀
        crate_version="${crate_version#v}"
        
        if [[ -n "$crate_version" ]]; then
            echo "${crate_name}@${crate_version}"
        else
            echo "$crate_name"
        fi
    done
}

# 导出 cargo crates
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_cargo_crates() {
    local output_file="$1"
    local count=0

    if ! _other_cmd_exists "cargo"; then
        return 0
    fi

    local crates
    crates=$(_export_cargo_get_crates 2>/dev/null) || return 0

    if [[ -z "$crates" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# Cargo (Rust) Crates
# =============================================================================

install_cargo_crates() {
    if ! command -v cargo > /dev/null 2>&1; then
        echo "cargo not found, skipping Rust crates..."
        return 0
    fi

    echo "Installing Rust crates via cargo..."

EOF

    while IFS= read -r crate; do
        [[ -z "$crate" ]] && continue
        local crate_name="${crate%%@*}"
        
        cat >> "$output_file" << EOF
    # 安装 $crate_name
    if ! cargo install --list 2>/dev/null | grep -q "^$crate_name "; then
        cargo install "$crate_name" || echo "Warning: Failed to install $crate_name"
    fi
EOF
        ((count++))
    done <<< "$crates"

    cat >> "$output_file" << 'EOF'

    echo "Cargo crates installation completed."
}

install_cargo_crates

EOF

    echo "$count"
}

# =============================================================================
# Go 工具导出
# =============================================================================

# 获取 Go 工具列表
# 通过扫描 GOPATH/bin 并使用 go version -m 获取模块路径
_export_go_get_tools() {
    if ! _other_cmd_exists "go"; then
        return 1
    fi

    local gopath
    gopath=$(go env GOPATH 2>/dev/null) || return 1
    
    local gobin="$gopath/bin"
    if [[ ! -d "$gobin" ]]; then
        return 1
    fi

    # 遍历 GOPATH/bin 中的可执行文件
    find "$gobin" -maxdepth 1 -type f -perm +111 2>/dev/null | while IFS= read -r binary; do
        local binary_name
        binary_name=$(basename "$binary")
        
        # 跳过 go 自身的工具
        case "$binary_name" in
            go|gofmt)
                continue
                ;;
        esac
        
        # 使用 go version -m 获取模块信息
        local mod_info
        mod_info=$(go version -m "$binary" 2>/dev/null) || continue
        
        # 提取模块路径和版本
        # 格式: path	module/path	v1.0.0
        local mod_path mod_version
        mod_path=$(echo "$mod_info" | grep -E '^\s*path\s' | awk '{print $2}')
        mod_version=$(echo "$mod_info" | grep -E '^\s*mod\s' | awk '{print $3}')
        
        if [[ -z "$mod_path" ]]; then
            # 尝试从 mod 行获取
            mod_path=$(echo "$mod_info" | grep -E '^\s*mod\s' | awk '{print $2}')
        fi
        
        [[ -z "$mod_path" ]] && continue
        
        # 处理 (devel) 版本标识 - 使用 @latest 代替
        if [[ "$mod_version" == "(devel)" || -z "$mod_version" ]]; then
            echo "${mod_path}@latest"
        else
            echo "${mod_path}@${mod_version}"
        fi
    done | sort -u
}

# 导出 Go 工具
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_go_tools() {
    local output_file="$1"
    local count=0

    if ! _other_cmd_exists "go"; then
        return 0
    fi

    local tools
    tools=$(_export_go_get_tools 2>/dev/null) || return 0

    if [[ -z "$tools" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# Go Tools
# =============================================================================

install_go_tools() {
    if ! command -v go > /dev/null 2>&1; then
        echo "go not found, skipping Go tools..."
        return 0
    fi

    echo "Installing Go tools..."

EOF

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        local tool_path="${tool%%@*}"
        local tool_name
        tool_name=$(basename "$tool_path")
        
        cat >> "$output_file" << EOF
    # 安装 $tool_name ($tool_path)
    if ! command -v "$tool_name" > /dev/null 2>&1; then
        go install "$tool" || echo "Warning: Failed to install $tool"
    fi
EOF
        ((count++))
    done <<< "$tools"

    cat >> "$output_file" << 'EOF'

    echo "Go tools installation completed."
}

install_go_tools

EOF

    echo "$count"
}

# =============================================================================
# Ruby Gem 导出
# =============================================================================

# 获取 gem 全局包列表
_export_gem_get_packages() {
    if ! _other_cmd_exists "gem"; then
        return 1
    fi

    # gem list --local 输出格式: gem-name (version1, version2, ...) 或 gem-name (default: version)
    gem list --local 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        # 跳过系统默认 gems (包括带 default: 前缀的版本)
        case "$line" in
            bigdecimal*|bundler*|did_you_mean*|io-console*|json*|minitest*|net-telnet*|openssl*|power_assert*|psych*|rake*|rdoc*|test-unit*|xmlrpc*)
                continue
                ;;
            *"(default:"*)
                # 跳过默认 gems
                continue
                ;;
        esac
        
        # 提取 gem 名和版本
        # 格式: gem-name (version) 或 gem-name (v1, v2, ...)
        local gem_name gem_version
        # 移除括号及其内容，并去除尾随空格
        gem_name=$(echo "$line" | sed -E 's/[[:space:]]*\(.*\)$//' | tr -d ' ')
        # 提取第一个版本号（可能有多个版本，取第一个）
        gem_version=$(echo "$line" | sed -E 's/.*\(([^,)]+).*/\1/' | sed 's/default: //')
        
        [[ -z "$gem_name" ]] && continue
        
        if [[ -n "$gem_version" && "$gem_version" != "$line" ]]; then
            echo "${gem_name}:${gem_version}"
        else
            echo "$gem_name"
        fi
    done
}

# 导出 gem 包
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_gem_packages() {
    local output_file="$1"
    local count=0

    if ! _other_cmd_exists "gem"; then
        return 0
    fi

    local packages
    packages=$(_export_gem_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# Ruby Gems
# =============================================================================

install_gem_packages() {
    if ! command -v gem > /dev/null 2>&1; then
        echo "gem not found, skipping Ruby gems..."
        return 0
    fi

    echo "Installing Ruby gems..."

EOF

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        local gem_name="${pkg%%:*}"
        local gem_version="${pkg#*:}"
        
        if [[ "$gem_version" == "$pkg" ]]; then
            gem_version=""
        fi
        
        if [[ -n "$gem_version" ]]; then
            cat >> "$output_file" << EOF
    # 安装 $gem_name (version $gem_version)
    if ! gem list --local "$gem_name" 2>/dev/null | grep -q "^$gem_name "; then
        gem install "$gem_name" -v "$gem_version" || echo "Warning: Failed to install $gem_name"
    fi
EOF
        else
            cat >> "$output_file" << EOF
    # 安装 $gem_name
    if ! gem list --local "$gem_name" 2>/dev/null | grep -q "^$gem_name "; then
        gem install "$gem_name" || echo "Warning: Failed to install $gem_name"
    fi
EOF
        fi
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "Ruby gems installation completed."
}

install_gem_packages

EOF

    echo "$count"
}

# =============================================================================
# PHP Composer 全局包导出
# =============================================================================

# 获取 composer 全局包列表
_export_composer_get_packages() {
    if ! _other_cmd_exists "composer"; then
        return 1
    fi

    # composer global show 输出格式: vendor/package version description
    composer global show 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local pkg_name pkg_version
        pkg_name=$(echo "$line" | awk '{print $1}')
        pkg_version=$(echo "$line" | awk '{print $2}')
        
        [[ -z "$pkg_name" ]] && continue
        
        if [[ -n "$pkg_version" ]]; then
            echo "${pkg_name}:${pkg_version}"
        else
            echo "$pkg_name"
        fi
    done
}

# 导出 composer 全局包
# 参数: $1 - 输出文件路径
# 返回: 导出的包数量
export_composer_packages() {
    local output_file="$1"
    local count=0

    if ! _other_cmd_exists "composer"; then
        return 0
    fi

    local packages
    packages=$(_export_composer_get_packages 2>/dev/null) || return 0

    if [[ -z "$packages" ]]; then
        return 0
    fi

    cat >> "$output_file" << 'EOF'

# =============================================================================
# PHP Composer Global Packages
# =============================================================================

install_composer_packages() {
    if ! command -v composer > /dev/null 2>&1; then
        echo "composer not found, skipping PHP packages..."
        return 0
    fi

    echo "Installing PHP Composer global packages..."

EOF

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        local pkg_name="${pkg%%:*}"
        local pkg_version="${pkg#*:}"
        
        if [[ "$pkg_version" == "$pkg" ]]; then
            pkg_version=""
        fi
        
        if [[ -n "$pkg_version" ]]; then
            cat >> "$output_file" << EOF
    # 安装 $pkg_name (version $pkg_version)
    if ! composer global show "$pkg_name" > /dev/null 2>&1; then
        composer global require "$pkg_name:$pkg_version" || echo "Warning: Failed to install $pkg_name"
    fi
EOF
        else
            cat >> "$output_file" << EOF
    # 安装 $pkg_name
    if ! composer global show "$pkg_name" > /dev/null 2>&1; then
        composer global require "$pkg_name" || echo "Warning: Failed to install $pkg_name"
    fi
EOF
        fi
        ((count++))
    done <<< "$packages"

    cat >> "$output_file" << 'EOF'

    echo "Composer packages installation completed."
}

install_composer_packages

EOF

    echo "$count"
}

# =============================================================================
# 主导出函数
# =============================================================================

# 导出所有其他包管理器的全局包
# 参数: $1 - 输出文件路径
# 返回: 导出的总包数量 (通过 stdout)
export_other_packages() {
    local output_file="$1"
    local total_count=0

    # Cargo (Rust)
    local cargo_count
    cargo_count=$(export_cargo_crates "$output_file" 2>/dev/null) || cargo_count=0
    [[ -n "$cargo_count" ]] && ((total_count += cargo_count)) || true

    # Go
    local go_count
    go_count=$(export_go_tools "$output_file" 2>/dev/null) || go_count=0
    [[ -n "$go_count" ]] && ((total_count += go_count)) || true

    # Gem (Ruby)
    local gem_count
    gem_count=$(export_gem_packages "$output_file" 2>/dev/null) || gem_count=0
    [[ -n "$gem_count" ]] && ((total_count += gem_count)) || true

    # Composer (PHP)
    local composer_count
    composer_count=$(export_composer_packages "$output_file" 2>/dev/null) || composer_count=0
    [[ -n "$composer_count" ]] && ((total_count += composer_count)) || true

    echo "$total_count"
}

# =============================================================================
# 检测函数
# =============================================================================

# 检测可用的其他包管理器
# 返回: 检测到的包管理器列表 (以空格分隔)
detect_other_package_managers() {
    local managers=""
    
    _other_cmd_exists "cargo" && managers="$managers cargo"
    _other_cmd_exists "go" && managers="$managers go"
    _other_cmd_exists "gem" && managers="$managers gem"
    _other_cmd_exists "composer" && managers="$managers composer"
    
    echo "${managers# }"
}

# 获取各包管理器的包数量统计
# 返回: JSON 格式的统计信息
get_other_packages_stats() {
    local stats="{"
    local first=true
    
    if _other_cmd_exists "cargo"; then
        local cargo_count
        cargo_count=$(cargo install --list 2>/dev/null | grep -cE '^[a-zA-Z].*:$' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"cargo\":$cargo_count"
        first=false
    fi
    
    if _other_cmd_exists "go"; then
        local gopath
        gopath=$(go env GOPATH 2>/dev/null) || gopath=""
        local go_count=0
        if [[ -n "$gopath" && -d "$gopath/bin" ]]; then
            go_count=$(find "$gopath/bin" -maxdepth 1 -type f -perm +111 2>/dev/null | wc -l | tr -d ' ')
        fi
        $first || stats="$stats,"
        stats="$stats\"go\":$go_count"
        first=false
    fi
    
    if _other_cmd_exists "gem"; then
        local gem_count
        gem_count=$(gem list --local 2>/dev/null | grep -cv '^\s*$' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"gem\":$gem_count"
        first=false
    fi
    
    if _other_cmd_exists "composer"; then
        local composer_count
        composer_count=$(composer global show 2>/dev/null | grep -cv '^\s*$' || echo "0")
        $first || stats="$stats,"
        stats="$stats\"composer\":$composer_count"
        first=false
    fi
    
    stats="$stats}"
    echo "$stats"
}
