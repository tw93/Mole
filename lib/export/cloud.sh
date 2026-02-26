#!/bin/bash
# Mole - Cloud and DevOps Tools Export Module
# 导出云服务和 DevOps 工具配置（不包含敏感信息）
# 注意: 兼容 bash 3.2 (macOS 默认版本)
# 安全: 不导出 API keys, tokens, secrets 等敏感信息

set -euo pipefail

# 防止重复加载
if [[ -n "${MOLE_EXPORT_CLOUD_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_EXPORT_CLOUD_LOADED=1

# 加载依赖
_MOLE_EXPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_EXPORT_COMMON_LOADED:-}" ]]; then
    source "$_MOLE_EXPORT_DIR/common.sh"
fi

# =============================================================================
# Docker 检测函数
# =============================================================================

# 检测 Docker 是否可用
# 返回: 0 可用, 1 不可用
export_cloud_docker_available() {
    export_command_exists docker && docker info >/dev/null 2>&1
}

# 获取 Docker 镜像列表
# 返回: 格式化的镜像列表 (repository:tag)
export_cloud_docker_get_images() {
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | sort -u || echo ""
}

# 统计 Docker 镜像数量
# 参数: $1 - 镜像列表
# 返回: 数量
export_cloud_docker_count() {
    local images="$1"
    if [[ -z "$images" ]]; then
        echo "0"
        return
    fi
    echo "$images" | wc -l | tr -d ' '
}

# =============================================================================
# Kubernetes (kubectl) 检测函数
# =============================================================================

# 检测 kubectl 是否可用
# 返回: 0 可用, 1 不可用
export_cloud_kubectl_available() {
    export_command_exists kubectl
}

# 获取 kubectl contexts 列表
# 返回: context 名称列表
export_cloud_kubectl_get_contexts() {
    kubectl config get-contexts -o name 2>/dev/null || echo ""
}

# 获取当前 kubectl context
# 返回: 当前 context 名称
export_cloud_kubectl_current_context() {
    kubectl config current-context 2>/dev/null || echo ""
}

# =============================================================================
# AWS CLI 检测函数
# =============================================================================

# 检测 AWS CLI 配置是否存在
# 返回: 0 存在, 1 不存在
export_cloud_aws_config_exists() {
    [[ -d "$HOME/.aws" ]]
}

# 获取 AWS 配置的 profiles 列表 (安全方式)
# 注意: 只读取 profile 名称，不读取密钥
# 返回: profile 名称列表
export_cloud_aws_get_profiles() {
    local profiles=""
    
    # 从 credentials 文件提取 profile 名称
    if [[ -f "$HOME/.aws/credentials" ]]; then
        profiles=$(grep '^\[' "$HOME/.aws/credentials" 2>/dev/null | tr -d '[]' || echo "")
    fi
    
    # 从 config 文件提取 profile 名称
    if [[ -f "$HOME/.aws/config" ]]; then
        local config_profiles
        config_profiles=$(grep '^\[profile ' "$HOME/.aws/config" 2>/dev/null | sed 's/\[profile //' | tr -d ']' || echo "")
        if [[ -n "$config_profiles" ]]; then
            if [[ -n "$profiles" ]]; then
                profiles="${profiles}"$'\n'"${config_profiles}"
            else
                profiles="$config_profiles"
            fi
        fi
        # 检查 [default] 部分
        if grep -q '^\[default\]' "$HOME/.aws/config" 2>/dev/null; then
            profiles="${profiles}"$'\n'"default"
        fi
    fi
    
    # 去重并排序
    echo "$profiles" | sort -u | grep -v '^$' || echo ""
}

# 检查 AWS 配置文件是否存在
# 返回: 存在的配置文件列表
export_cloud_aws_config_files() {
    local files=""
    [[ -f "$HOME/.aws/config" ]] && files="~/.aws/config"
    [[ -f "$HOME/.aws/credentials" ]] && files="${files:+$files, }~/.aws/credentials"
    echo "$files"
}

# =============================================================================
# Terraform 检测函数
# =============================================================================

# 检测 Terraform 是否可用
# 返回: 0 可用, 1 不可用
export_cloud_terraform_available() {
    export_command_exists terraform
}

# 获取 Terraform 版本
# 返回: 版本号
export_cloud_terraform_version() {
    terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || \
    terraform version 2>/dev/null | head -1 | sed 's/Terraform v//' || echo "unknown"
}

# =============================================================================
# Helm 检测函数
# =============================================================================

# 检测 Helm 是否可用
# 返回: 0 可用, 1 不可用
export_cloud_helm_available() {
    export_command_exists helm
}

# 获取已安装的 Helm releases
# 返回: namespace/release-name 格式的列表
export_cloud_helm_get_releases() {
    helm list -A --output json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || echo ""
}

# 获取 Helm 仓库列表
# 返回: 仓库名称和 URL
export_cloud_helm_get_repos() {
    helm repo list 2>/dev/null | tail -n +2 || echo ""
}

# =============================================================================
# 主导出函数
# =============================================================================

# 主导出函数: 导出云和 DevOps 工具配置
# 参数: $1 - 输出文件路径
# 返回: 0 成功, 1 失败
# 副作用: 更新 EXPORT_STATS
export_cloud() {
    local output_file="$1"
    local total_items=0
    local has_content=false
    
    export_log_info "Scanning Cloud & DevOps tools..."
    
    # 检测各工具
    local docker_images="" kubectl_contexts="" aws_profiles="" helm_repos=""
    local docker_count=0 kubectl_count=0 aws_count=0 helm_count=0
    local terraform_ver=""
    
    # Docker
    if export_cloud_docker_available; then
        docker_images=$(export_cloud_docker_get_images)
        docker_count=$(export_cloud_docker_count "$docker_images")
        export_log_verbose "Docker: $docker_count images"
    fi
    
    # Kubectl
    if export_cloud_kubectl_available; then
        kubectl_contexts=$(export_cloud_kubectl_get_contexts)
        if [[ -n "$kubectl_contexts" ]]; then
            kubectl_count=$(echo "$kubectl_contexts" | wc -l | tr -d ' ')
        fi
        export_log_verbose "Kubectl: $kubectl_count contexts"
    fi
    
    # AWS
    if export_cloud_aws_config_exists; then
        aws_profiles=$(export_cloud_aws_get_profiles)
        if [[ -n "$aws_profiles" ]]; then
            aws_count=$(echo "$aws_profiles" | wc -l | tr -d ' ')
        fi
        export_log_verbose "AWS: $aws_count profiles"
    fi
    
    # Terraform
    if export_cloud_terraform_available; then
        terraform_ver=$(export_cloud_terraform_version)
        export_log_verbose "Terraform: v$terraform_ver"
    fi
    
    # Helm
    if export_cloud_helm_available; then
        helm_repos=$(export_cloud_helm_get_repos)
        if [[ -n "$helm_repos" ]]; then
            helm_count=$(echo "$helm_repos" | wc -l | tr -d ' ')
        fi
        export_log_verbose "Helm: $helm_count repos"
    fi
    
    # 计算总数
    total_items=$((docker_count + kubectl_count + aws_count + helm_count))
    [[ -n "$terraform_ver" ]] && total_items=$((total_items + 1))
    
    if [[ $total_items -eq 0 && -z "$terraform_ver" ]]; then
        export_log_skipped "No Cloud/DevOps tools detected"
        return 0
    fi
    
    # 写入章节头
    export_write_section_start "$output_file" "C" "Cloud & DevOps Tools" "${total_items} items"
    
    # 写入恢复提示
    cat >> "$output_file" << 'EOF'
# ⚠️  Cloud & DevOps 工具恢复提示:
#     大部分云服务需要重新认证（登录）才能使用
#     以下仅记录工具配置结构，不包含敏感信息
#

EOF
    
    # Docker
    if [[ $docker_count -gt 0 ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Docker 镜像列表 (需要重新 pull)
# ------------------------------------------------------------
EOF
        echo "# 已安装镜像 ($docker_count 个):" >> "$output_file"
        while IFS= read -r image; do
            [[ -n "$image" ]] && echo "#   docker pull $image" >> "$output_file"
        done <<< "$docker_images"
        echo "#" >> "$output_file"
        
        # 生成可执行的恢复命令
        cat >> "$output_file" << 'EOF'
restore_docker_images() {
    should_skip "docker" && return 0
    if ! command_exists docker; then
        log "⚠️  Docker not installed, skipping image restore"
        return 0
    fi
    log "🐳 Pulling Docker images..."
EOF
        while IFS= read -r image; do
            [[ -n "$image" ]] && echo "    run 'docker pull $image'" >> "$output_file"
        done <<< "$docker_images"
        echo "}" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Kubectl
    if [[ $kubectl_count -gt 0 ]]; then
        has_content=true
        local current_ctx
        current_ctx=$(export_cloud_kubectl_current_context)
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Kubectl Contexts (需要重新配置 kubeconfig)
# ------------------------------------------------------------
EOF
        echo "# 已配置 contexts ($kubectl_count 个):" >> "$output_file"
        while IFS= read -r ctx; do
            if [[ -n "$ctx" ]]; then
                if [[ "$ctx" == "$current_ctx" ]]; then
                    echo "#   - $ctx (当前)" >> "$output_file"
                else
                    echo "#   - $ctx" >> "$output_file"
                fi
            fi
        done <<< "$kubectl_contexts"
        echo "#" >> "$output_file"
        echo "# 提示: 使用云服务商 CLI 重新配置:" >> "$output_file"
        echo "#   AWS EKS: aws eks update-kubeconfig --name <cluster>" >> "$output_file"
        echo "#   GKE: gcloud container clusters get-credentials <cluster>" >> "$output_file"
        echo "#   AKS: az aks get-credentials --name <cluster> --resource-group <rg>" >> "$output_file"
        echo "#" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # AWS
    if [[ $aws_count -gt 0 ]]; then
        has_content=true
        local aws_files
        aws_files=$(export_cloud_aws_config_files)
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# AWS CLI 配置 (需要重新 aws configure)
# ------------------------------------------------------------
EOF
        echo "# 配置文件: $aws_files" >> "$output_file"
        echo "# 已配置 profiles ($aws_count 个):" >> "$output_file"
        while IFS= read -r profile; do
            [[ -n "$profile" ]] && echo "#   - $profile" >> "$output_file"
        done <<< "$aws_profiles"
        echo "#" >> "$output_file"
        echo "# 提示: 使用以下命令重新配置:" >> "$output_file"
        echo "#   aws configure                    # 配置默认 profile" >> "$output_file"
        echo "#   aws configure --profile <name>  # 配置指定 profile" >> "$output_file"
        echo "#   aws configure sso               # 配置 SSO" >> "$output_file"
        echo "#" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    # Terraform
    if [[ -n "$terraform_ver" ]]; then
        has_content=true
        cat >> "$output_file" << EOF
# ------------------------------------------------------------
# Terraform (版本 $terraform_ver)
# ------------------------------------------------------------
# 提示: 使用 tfenv 或 brew 安装指定版本:
#   brew install terraform
#   tfenv install $terraform_ver && tfenv use $terraform_ver
#

EOF
    fi
    
    # Helm
    if [[ $helm_count -gt 0 ]]; then
        has_content=true
        cat >> "$output_file" << 'EOF'
# ------------------------------------------------------------
# Helm 仓库
# ------------------------------------------------------------
EOF
        echo "# 已配置仓库 ($helm_count 个):" >> "$output_file"
        echo "$helm_repos" | while IFS=$'\t' read -r name url _; do
            [[ -n "$name" ]] && echo "#   - $name: $url" >> "$output_file"
        done
        echo "#" >> "$output_file"
        
        # 生成可执行的恢复命令
        cat >> "$output_file" << 'EOF'
restore_helm_repos() {
    should_skip "helm" && return 0
    if ! command_exists helm; then
        log "⚠️  Helm not installed, skipping repo restore"
        return 0
    fi
    log "⎈ Adding Helm repositories..."
EOF
        echo "$helm_repos" | while IFS=$'\t' read -r name url _; do
            [[ -n "$name" && -n "$url" ]] && echo "    run 'helm repo add $name $url'" >> "$output_file"
        done
        echo "    run 'helm repo update'" >> "$output_file"
        echo "}" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    export_write_section_end "$output_file"
    
    # 更新统计
    export_add_stat "Cloud/DevOps" "$total_items" "items"
    
    export_log_success "Cloud/DevOps: $total_items items exported"
    
    return 0
}

# Dry-run 模式: 仅显示统计信息
# 返回: 统计信息字符串
export_cloud_dry_run() {
    local results=""
    
    # Docker
    if export_cloud_docker_available; then
        local docker_images docker_count
        docker_images=$(export_cloud_docker_get_images)
        docker_count=$(export_cloud_docker_count "$docker_images")
        results="${results}Docker: ${docker_count} images\n"
    else
        results="${results}Docker: not available\n"
    fi
    
    # Kubectl
    if export_cloud_kubectl_available; then
        local kubectl_contexts kubectl_count=0
        kubectl_contexts=$(export_cloud_kubectl_get_contexts)
        [[ -n "$kubectl_contexts" ]] && kubectl_count=$(echo "$kubectl_contexts" | wc -l | tr -d ' ')
        results="${results}Kubectl: ${kubectl_count} contexts\n"
    else
        results="${results}Kubectl: not installed\n"
    fi
    
    # AWS
    if export_cloud_aws_config_exists; then
        local aws_profiles aws_count=0
        aws_profiles=$(export_cloud_aws_get_profiles)
        [[ -n "$aws_profiles" ]] && aws_count=$(echo "$aws_profiles" | wc -l | tr -d ' ')
        results="${results}AWS CLI: ${aws_count} profiles (config exists)\n"
    else
        results="${results}AWS CLI: no config found\n"
    fi
    
    # Terraform
    if export_cloud_terraform_available; then
        local terraform_ver
        terraform_ver=$(export_cloud_terraform_version)
        results="${results}Terraform: v${terraform_ver}\n"
    else
        results="${results}Terraform: not installed\n"
    fi
    
    # Helm
    if export_cloud_helm_available; then
        local helm_repos helm_count=0
        helm_repos=$(export_cloud_helm_get_repos)
        [[ -n "$helm_repos" ]] && helm_count=$(echo "$helm_repos" | wc -l | tr -d ' ')
        results="${results}Helm: ${helm_count} repos\n"
    else
        results="${results}Helm: not installed\n"
    fi
    
    echo -e "$results"
    
    # Verbose 模式显示详细列表
    if [[ "${EXPORT_VERBOSE:-false}" == "true" ]]; then
        echo ""
        if export_cloud_docker_available; then
            echo "  Docker Images:"
            export_cloud_docker_get_images | head -10 | while IFS= read -r img; do
                [[ -n "$img" ]] && echo "    $img"
            done
        fi
        
        if export_cloud_kubectl_available; then
            echo "  Kubectl Contexts:"
            export_cloud_kubectl_get_contexts | while IFS= read -r ctx; do
                [[ -n "$ctx" ]] && echo "    $ctx"
            done
        fi
        
        if export_cloud_aws_config_exists; then
            echo "  AWS Profiles:"
            export_cloud_aws_get_profiles | while IFS= read -r profile; do
                [[ -n "$profile" ]] && echo "    $profile"
            done
        fi
    fi
}
