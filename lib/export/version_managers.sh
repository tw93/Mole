#!/bin/bash
# Mole - Other Version Managers Export
# 导出其他语言版本管理器配置 (rbenv, goenv, jenv, rustup, mise/asdf)
# 注意: 兼容 bash 3.2 (macOS 默认版本)

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_VERSION_MANAGERS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_VERSION_MANAGERS_LOADED=1

# 加载依赖
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# =============================================================================
# rbenv (Ruby) 检测和导出
# =============================================================================

export_rbenv_installed() {
    command -v rbenv > /dev/null 2>&1
}

export_rbenv_list_versions() {
    if ! export_rbenv_installed; then
        return 0
    fi

    rbenv versions --bare 2>/dev/null | while read -r version; do
        if [[ "$version" != "system" && -n "$version" ]]; then
            echo "$version"
        fi
    done | sort -V
}

export_rbenv_get_global() {
    if ! export_rbenv_installed; then
        return 0
    fi

    local global_version
    global_version=$(rbenv global 2>/dev/null || true)
    if [[ "$global_version" != "system" && -n "$global_version" ]]; then
        echo "$global_version"
    fi
}

export_rbenv_generate_restore() {
    local output="$1"

    if ! export_rbenv_installed; then
        return 0
    fi

    local versions
    versions=$(export_rbenv_list_versions)
    local global_version
    global_version=$(export_rbenv_get_global)
    local version_count=0

    if [[ -z "$versions" ]]; then
        return 0
    fi

    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# rbenv - Ruby Version Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 rbenv (如果未安装)"
        echo 'if ! command -v rbenv > /dev/null 2>&1; then'
        echo '    echo "Installing rbenv..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install rbenv ruby-build'
        echo '    else'
        echo '        git clone https://github.com/rbenv/rbenv.git ~/.rbenv'
        echo '        git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 初始化 rbenv"
        echo 'export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"'
        echo '[[ -d "$RBENV_ROOT/bin" ]] && export PATH="$RBENV_ROOT/bin:$PATH"'
        echo 'eval "$(rbenv init -)"'
        echo ""
        echo "# 安装 Ruby 版本"
    } >> "$output"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "rbenv install -s $version" >> "$output"
        ((version_count++))
    done <<< "$versions"

    if [[ -n "$global_version" ]]; then
        echo "" >> "$output"
        echo "# 设置全局版本" >> "$output"
        echo "rbenv global $global_version" >> "$output"
    fi

    echo "" >> "$output"
    echo "rbenv rehash" >> "$output"
    echo "echo \"rbenv: $version_count Ruby version(s) installed\"" >> "$output"

    echo "$version_count"
}

# =============================================================================
# goenv (Go) 检测和导出
# =============================================================================

export_goenv_installed() {
    command -v goenv > /dev/null 2>&1
}

export_goenv_list_versions() {
    if ! export_goenv_installed; then
        return 0
    fi

    goenv versions --bare 2>/dev/null | while read -r version; do
        if [[ "$version" != "system" && -n "$version" ]]; then
            echo "$version"
        fi
    done | sort -V
}

export_goenv_get_global() {
    if ! export_goenv_installed; then
        return 0
    fi

    local global_version
    global_version=$(goenv global 2>/dev/null || true)
    if [[ "$global_version" != "system" && -n "$global_version" ]]; then
        echo "$global_version"
    fi
}

export_goenv_generate_restore() {
    local output="$1"

    if ! export_goenv_installed; then
        return 0
    fi

    local versions
    versions=$(export_goenv_list_versions)
    local global_version
    global_version=$(export_goenv_get_global)
    local version_count=0

    if [[ -z "$versions" ]]; then
        return 0
    fi

    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# goenv - Go Version Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 goenv (如果未安装)"
        echo 'if ! command -v goenv > /dev/null 2>&1; then'
        echo '    echo "Installing goenv..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install goenv'
        echo '    else'
        echo '        git clone https://github.com/syndbg/goenv.git ~/.goenv'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 初始化 goenv"
        echo 'export GOENV_ROOT="${GOENV_ROOT:-$HOME/.goenv}"'
        echo '[[ -d "$GOENV_ROOT/bin" ]] && export PATH="$GOENV_ROOT/bin:$PATH"'
        echo 'eval "$(goenv init -)"'
        echo ""
        echo "# 安装 Go 版本"
    } >> "$output"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "goenv install -s $version" >> "$output"
        ((version_count++))
    done <<< "$versions"

    if [[ -n "$global_version" ]]; then
        echo "" >> "$output"
        echo "# 设置全局版本" >> "$output"
        echo "goenv global $global_version" >> "$output"
    fi

    echo "" >> "$output"
    echo "goenv rehash" >> "$output"
    echo "echo \"goenv: $version_count Go version(s) installed\"" >> "$output"

    echo "$version_count"
}

# =============================================================================
# jenv (Java) 检测和导出
# =============================================================================

export_jenv_installed() {
    command -v jenv > /dev/null 2>&1
}

export_jenv_list_versions() {
    if ! export_jenv_installed; then
        return 0
    fi

    jenv versions --bare 2>/dev/null | while read -r version; do
        if [[ "$version" != "system" && -n "$version" ]]; then
            echo "$version"
        fi
    done | sort -V
}

export_jenv_get_global() {
    if ! export_jenv_installed; then
        return 0
    fi

    local global_version
    global_version=$(jenv global 2>/dev/null || true)
    if [[ "$global_version" != "system" && -n "$global_version" ]]; then
        echo "$global_version"
    fi
}

export_jenv_generate_restore() {
    local output="$1"

    if ! export_jenv_installed; then
        return 0
    fi

    local versions
    versions=$(export_jenv_list_versions)
    local global_version
    global_version=$(export_jenv_get_global)
    local version_count=0

    if [[ -z "$versions" ]]; then
        return 0
    fi

    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# jenv - Java Version Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 jenv (如果未安装)"
        echo 'if ! command -v jenv > /dev/null 2>&1; then'
        echo '    echo "Installing jenv..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install jenv'
        echo '    else'
        echo '        git clone https://github.com/jenv/jenv.git ~/.jenv'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 初始化 jenv"
        echo 'export JENV_ROOT="${JENV_ROOT:-$HOME/.jenv}"'
        echo '[[ -d "$JENV_ROOT/bin" ]] && export PATH="$JENV_ROOT/bin:$PATH"'
        echo 'eval "$(jenv init -)"'
        echo ""
        echo "# 注意: jenv 不安装 JDK，只管理已安装的 JDK"
        echo "# 请先通过 Homebrew 或官方下载安装 JDK，然后使用 jenv add 添加"
        echo "# 已导出的版本仅供参考:"
    } >> "$output"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "# - $version" >> "$output"
        ((version_count++))
    done <<< "$versions"

    if [[ -n "$global_version" ]]; then
        echo "" >> "$output"
        echo "# 设置全局版本 (需要先添加对应 JDK)" >> "$output"
        echo "# jenv global $global_version" >> "$output"
    fi

    echo "" >> "$output"
    echo "echo \"jenv: Exported $version_count Java version reference(s)\"" >> "$output"

    echo "$version_count"
}

# =============================================================================
# rustup (Rust) 检测和导出
# =============================================================================

export_rustup_installed() {
    command -v rustup > /dev/null 2>&1
}

export_rustup_list_toolchains() {
    if ! export_rustup_installed; then
        return 0
    fi

    # rustup show 输出已安装的工具链
    rustup toolchain list 2>/dev/null | while read -r line; do
        # 移除 (default) 标记
        local toolchain
        toolchain=$(echo "$line" | awk '{print $1}')
        if [[ -n "$toolchain" ]]; then
            echo "$toolchain"
        fi
    done
}

export_rustup_get_default() {
    if ! export_rustup_installed; then
        return 0
    fi

    rustup default 2>/dev/null | awk '{print $1}'
}

export_rustup_list_components() {
    if ! export_rustup_installed; then
        return 0
    fi

    # 获取已安装的组件
    rustup component list --installed 2>/dev/null
}

export_rustup_list_targets() {
    if ! export_rustup_installed; then
        return 0
    fi

    # 获取已安装的目标平台
    rustup target list --installed 2>/dev/null
}

export_rustup_generate_restore() {
    local output="$1"

    if ! export_rustup_installed; then
        return 0
    fi

    local toolchains
    toolchains=$(export_rustup_list_toolchains)
    local default_toolchain
    default_toolchain=$(export_rustup_get_default)
    local components
    components=$(export_rustup_list_components)
    local targets
    targets=$(export_rustup_list_targets)
    local version_count=0

    if [[ -z "$toolchains" ]]; then
        return 0
    fi

    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# rustup - Rust Toolchain Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 rustup (如果未安装)"
        echo 'if ! command -v rustup > /dev/null 2>&1; then'
        echo '    echo "Installing rustup..."'
        echo '    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
        echo '    source "$HOME/.cargo/env"'
        echo 'fi'
        echo ""
        echo "# 安装工具链"
    } >> "$output"

    while IFS= read -r toolchain; do
        [[ -z "$toolchain" ]] && continue
        echo "rustup toolchain install $toolchain" >> "$output"
        ((version_count++))
    done <<< "$toolchains"

    # 设置默认工具链
    if [[ -n "$default_toolchain" ]]; then
        echo "" >> "$output"
        echo "# 设置默认工具链" >> "$output"
        echo "rustup default $default_toolchain" >> "$output"
    fi

    # 安装组件 (排除默认组件)
    if [[ -n "$components" ]]; then
        local extra_components
        extra_components=$(echo "$components" | grep -v -E '^(cargo|clippy|rust-docs|rust-std|rustc|rustfmt)$' || true)
        if [[ -n "$extra_components" ]]; then
            echo "" >> "$output"
            echo "# 安装额外组件" >> "$output"
            while IFS= read -r component; do
                [[ -z "$component" ]] && continue
                echo "rustup component add $component" >> "$output"
            done <<< "$extra_components"
        fi
    fi

    # 安装额外目标平台 (排除主机平台)
    if [[ -n "$targets" ]]; then
        local host_target
        host_target=$(rustc -vV 2>/dev/null | grep "host:" | awk '{print $2}' || true)
        local extra_targets
        extra_targets=$(echo "$targets" | grep -v "^${host_target}$" || true)
        if [[ -n "$extra_targets" ]]; then
            echo "" >> "$output"
            echo "# 安装交叉编译目标" >> "$output"
            while IFS= read -r target; do
                [[ -z "$target" ]] && continue
                echo "rustup target add $target" >> "$output"
            done <<< "$extra_targets"
        fi
    fi

    echo "" >> "$output"
    echo "echo \"rustup: $version_count toolchain(s) installed\"" >> "$output"

    echo "$version_count"
}

# =============================================================================
# mise (原 rtx) / asdf 检测和导出
# =============================================================================

export_mise_installed() {
    command -v mise > /dev/null 2>&1
}

export_asdf_installed() {
    command -v asdf > /dev/null 2>&1
}

export_mise_list_tools() {
    if ! export_mise_installed; then
        return 0
    fi

    # mise list 输出格式: tool  version  source
    mise list 2>/dev/null | while read -r line; do
        local tool version
        tool=$(echo "$line" | awk '{print $1}')
        version=$(echo "$line" | awk '{print $2}')
        if [[ -n "$tool" && -n "$version" && "$tool" != "Tool" ]]; then
            echo "$tool@$version"
        fi
    done
}

export_asdf_list_tools() {
    if ! export_asdf_installed; then
        return 0
    fi

    # asdf list 输出格式按插件分组
    asdf list 2>/dev/null | while read -r line; do
        if [[ "$line" =~ ^[a-z] ]]; then
            # 这是插件名
            current_plugin="$line"
        elif [[ "$line" =~ ^[[:space:]]+\*?[0-9] ]]; then
            # 这是版本号
            local version
            version=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/^\*//')
            if [[ -n "$current_plugin" && -n "$version" ]]; then
                echo "$current_plugin@$version"
            fi
        fi
    done
}

export_mise_generate_restore() {
    local output="$1"

    if ! export_mise_installed; then
        return 0
    fi

    local tools
    tools=$(export_mise_list_tools)
    local tool_count=0

    if [[ -z "$tools" ]]; then
        return 0
    fi

    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# mise - Polyglot Runtime Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 mise (如果未安装)"
        echo 'if ! command -v mise > /dev/null 2>&1; then'
        echo '    echo "Installing mise..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install mise'
        echo '    else'
        echo '        curl https://mise.run | sh'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 初始化 mise"
        echo 'eval "$(mise activate bash)"'
        echo ""
        echo "# 安装工具和版本"
    } >> "$output"

    while IFS= read -r tool_version; do
        [[ -z "$tool_version" ]] && continue
        echo "mise install $tool_version" >> "$output"
        ((tool_count++))
    done <<< "$tools"

    echo "" >> "$output"
    echo "echo \"mise: $tool_count tool(s) installed\"" >> "$output"

    echo "$tool_count"
}

export_asdf_generate_restore() {
    local output="$1"

    if ! export_asdf_installed; then
        return 0
    fi

    local tools
    tools=$(export_asdf_list_tools)
    local tool_count=0

    if [[ -z "$tools" ]]; then
        return 0
    fi

    # 获取已安装的插件列表
    local plugins
    plugins=$(asdf plugin list 2>/dev/null || true)

    {
        echo ""
        echo "# -----------------------------------------------------------------------------"
        echo "# asdf - Extendable Version Manager"
        echo "# -----------------------------------------------------------------------------"
        echo ""
        echo "# 安装 asdf (如果未安装)"
        echo 'if ! command -v asdf > /dev/null 2>&1; then'
        echo '    echo "Installing asdf..."'
        echo '    if command -v brew > /dev/null 2>&1; then'
        echo '        brew install asdf'
        echo '    else'
        echo '        git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0'
        echo '    fi'
        echo 'fi'
        echo ""
        echo "# 加载 asdf"
        echo '. "$HOME/.asdf/asdf.sh" 2>/dev/null || . "$(brew --prefix asdf)/libexec/asdf.sh" 2>/dev/null || true'
        echo ""
        echo "# 安装插件"
    } >> "$output"

    # 添加插件
    if [[ -n "$plugins" ]]; then
        while IFS= read -r plugin; do
            [[ -z "$plugin" ]] && continue
            echo "asdf plugin add $plugin 2>/dev/null || true" >> "$output"
        done <<< "$plugins"
    fi

    echo "" >> "$output"
    echo "# 安装工具版本" >> "$output"

    while IFS= read -r tool_version; do
        [[ -z "$tool_version" ]] && continue
        local tool="${tool_version%%@*}"
        local version="${tool_version#*@}"
        echo "asdf install $tool $version" >> "$output"
        ((tool_count++))
    done <<< "$tools"

    echo "" >> "$output"
    echo "echo \"asdf: $tool_count tool version(s) installed\"" >> "$output"

    echo "$tool_count"
}

# =============================================================================
# 主导出函数
# =============================================================================

# 导出所有版本管理器配置
# 参数: $1 - 输出文件路径
# 返回: 检测到的工具数量 (通过 stdout 输出)
export_other_version_managers() {
    local output_file="$1"
    local detected_count=0

    # rbenv (Ruby)
    if export_rbenv_installed; then
        export_log_info "rbenv detected"
        local rbenv_versions
        rbenv_versions=$(export_rbenv_list_versions | wc -l | tr -d ' ')
        if [[ "$rbenv_versions" -gt 0 ]]; then
            export_log_info "  Found $rbenv_versions Ruby version(s)"
            local global_ver
            global_ver=$(export_rbenv_get_global)
            if [[ -n "$global_ver" ]]; then
                export_log_info "  Global version: $global_ver"
            fi
            if [[ -n "$output_file" ]]; then
                export_rbenv_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        fi
    fi

    # goenv (Go)
    if export_goenv_installed; then
        export_log_info "goenv detected"
        local goenv_versions
        goenv_versions=$(export_goenv_list_versions | wc -l | tr -d ' ')
        if [[ "$goenv_versions" -gt 0 ]]; then
            export_log_info "  Found $goenv_versions Go version(s)"
            local global_ver
            global_ver=$(export_goenv_get_global)
            if [[ -n "$global_ver" ]]; then
                export_log_info "  Global version: $global_ver"
            fi
            if [[ -n "$output_file" ]]; then
                export_goenv_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        fi
    fi

    # jenv (Java)
    if export_jenv_installed; then
        export_log_info "jenv detected"
        local jenv_versions
        jenv_versions=$(export_jenv_list_versions | wc -l | tr -d ' ')
        if [[ "$jenv_versions" -gt 0 ]]; then
            export_log_info "  Found $jenv_versions Java version(s)"
            local global_ver
            global_ver=$(export_jenv_get_global)
            if [[ -n "$global_ver" ]]; then
                export_log_info "  Global version: $global_ver"
            fi
            if [[ -n "$output_file" ]]; then
                export_jenv_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        fi
    fi

    # rustup (Rust)
    if export_rustup_installed; then
        export_log_info "rustup detected"
        local rust_toolchains
        rust_toolchains=$(export_rustup_list_toolchains | wc -l | tr -d ' ')
        if [[ "$rust_toolchains" -gt 0 ]]; then
            export_log_info "  Found $rust_toolchains toolchain(s)"
            local default_tc
            default_tc=$(export_rustup_get_default)
            if [[ -n "$default_tc" ]]; then
                export_log_info "  Default: $default_tc"
            fi
            if [[ -n "$output_file" ]]; then
                export_rustup_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        fi
    fi

    # mise (原 rtx)
    if export_mise_installed; then
        export_log_info "mise detected"
        local mise_tools
        mise_tools=$(export_mise_list_tools | wc -l | tr -d ' ')
        if [[ "$mise_tools" -gt 0 ]]; then
            export_log_info "  Found $mise_tools tool(s)"
            if [[ -n "$output_file" ]]; then
                export_mise_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        fi
    # asdf (如果 mise 未安装则检测 asdf)
    elif export_asdf_installed; then
        export_log_info "asdf detected"
        local asdf_tools
        asdf_tools=$(export_asdf_list_tools | wc -l | tr -d ' ')
        if [[ "$asdf_tools" -gt 0 ]]; then
            export_log_info "  Found $asdf_tools tool version(s)"
            if [[ -n "$output_file" ]]; then
                export_asdf_generate_restore "$output_file" > /dev/null
            fi
            ((detected_count++))
        fi
    fi

    # 如果没有检测到任何版本管理器
    if [[ "$detected_count" -eq 0 ]]; then
        export_log_skipped "No other version managers detected (rbenv/goenv/jenv/rustup/mise/asdf)"
    fi

    echo "$detected_count"
}
