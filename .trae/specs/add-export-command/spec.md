# Mole Export 功能规格说明

## Why

Mac 开发者在更换电脑或重装系统时，需要手动记录和恢复大量开发工具、包管理器、全局包、IDE 扩展及版本。现有工具各自为战，无法一站式导出完整的开发环境。Mole 作为 Mac 系统维护工具，提供统一的 `mo export` 命令填补这一空白，目标覆盖 **90%+ 的研发工具链**。

## 调研结论

经过对本机 `~/.xxx` 目录的深度扫描，识别出以下开发工具生态：

### 已检测到的工具分布

| 类别 | 工具数量 | 示例 |
|------|---------|------|
| Homebrew | 336 formulae + 32 casks | git, node, go, cargo... |
| Node.js 全局包 | 19+ | npm, vercel, openclaw... |
| Python 包 | 28+ | black, httpx, langchain... |
| Go 工具 | 30+ | dlv, cobra, errcheck... |
| Rust crates | 2+ | sqlx-cli, skim... |
| VSCode 扩展 | 72 | - |
| AI 编程工具 | 15+ | claude, copilot, codeium... |
| 云/DevOps | docker, kubectl, aws | - |

### 现有工具无法覆盖的场景

1. **版本管理器组合**：pyenv + nvm + fnm + bun 需要分别导出
2. **AI 工具配置**：各种 AI 助手的配置文件散落各处
3. **IDE 扩展**：VSCode/Zed/Cursor 扩展需要分别处理
4. **企业内部工具**：bytectl 等字节跳动工具无现成方案
5. **CLI 增强工具**：starship, zoxide, bat 等现代 CLI 工具

## What Changes

- **新增 `mo export` 命令**：一站式扫描和导出开发环境
- 支持 **20+ 个导出类别**，覆盖 90%+ 研发工具
- 生成可执行的 shell 恢复脚本
- 支持选择性导出和预览模式

## Impact

- 影响范围：新增功能，不影响现有代码
- 新增文件：
  - `bin/export.sh` - 主入口脚本
  - `lib/export/` - 各导出模块（20+ 个）
- 修改文件：
  - `mole` - 添加 export 命令路由
  - `lib/core/commands.sh` - 添加命令定义

---

## 支持的导出类别（完整列表）

### 1. 系统级包管理

| ID | 类别 | 检测方式 | 导出命令 |
|----|------|----------|----------|
| `brew` | Homebrew | `command -v brew` | `brew bundle dump` |
| `mas` | Mac App Store | `command -v mas` | `mas list` |
| `apps` | /Applications 应用 | 目录扫描 | 过滤非 brew/mas 应用 |

### 2. 语言版本管理器

| ID | 类别 | 检测方式 | 导出命令 |
|----|------|----------|----------|
| `nvm` | Node 版本 (nvm) | `~/.nvm` 目录 | `nvm list` |
| `fnm` | Node 版本 (fnm) | `command -v fnm` | `fnm list` |
| `pyenv` | Python 版本 | `command -v pyenv` | `pyenv versions --bare` |
| `rbenv` | Ruby 版本 | `command -v rbenv` | `rbenv versions --bare` |
| `goenv` | Go 版本 | `command -v goenv` | `goenv versions` |
| `jenv` | Java 版本 | `command -v jenv` | `jenv versions` |
| `rustup` | Rust 工具链 | `command -v rustup` | `rustup show` |
| `mise` | mise 工具 | `command -v mise` | `mise list` |
| `asdf` | asdf 插件 | `command -v asdf` | `asdf list` |

### 3. 包管理器全局包

| ID | 类别 | 检测方式 | 导出命令 |
|----|------|----------|----------|
| `npm` | npm 全局包 | `command -v npm` | `npm list -g --depth=0 --json` |
| `pnpm` | pnpm 全局包 | `command -v pnpm` | `pnpm list -g --depth=0` |
| `yarn` | yarn 全局包 | `command -v yarn` | `yarn global list` |
| `bun` | bun 全局包 | `~/.bun` 目录 | `bun pm ls -g` |
| `pip` | pip 全局包 | `command -v pip3` | `pip3 list --user --format=freeze` |
| `uv` | uv 工具 | `command -v uv` | `uv tool list` |
| `poetry` | poetry 项目 | `command -v poetry` | `poetry show` |
| `cargo` | cargo crates | `command -v cargo` | `cargo install --list` |
| `go` | go 工具 | `command -v go` | `ls $(go env GOPATH)/bin` |
| `gem` | Ruby gems | `command -v gem` | `gem list --local` |
| `composer` | PHP 全局包 | `command -v composer` | `composer global show` |

### 4. IDE 和编辑器扩展

| ID | 类别 | 检测方式 | 导出命令 |
|----|------|----------|----------|
| `vscode` | VSCode 扩展 | `command -v code` | `code --list-extensions` |
| `cursor` | Cursor 扩展 | `command -v cursor` | `cursor --list-extensions` |
| `zed` | Zed 扩展 | `~/.config/zed` | 目录扫描 |
| `windsurf` | Windsurf 扩展 | `command -v windsurf` | `windsurf --list-extensions` |
| `neovim` | Neovim 插件 | `~/.config/nvim` | 解析配置文件 |
| `vim` | Vim 插件 | `~/.vim` | 解析 .vimrc |

### 5. Shell 和终端配置

| ID | 类别 | 检测方式 | 导出文件 |
|----|------|----------|----------|
| `zsh` | Zsh 配置 | `~/.zshrc` | .zshrc, .zprofile |
| `bash` | Bash 配置 | `~/.bashrc` | .bashrc, .bash_profile |
| `fish` | Fish 配置 | `~/.config/fish` | config.fish |
| `starship` | Starship 配置 | `~/.config/starship.toml` | starship.toml |
| `oh-my-zsh` | Oh My Zsh | `~/.oh-my-zsh` | 主题和插件 |
| `p10k` | Powerlevel10k | `~/.p10k.zsh` | p10k.zsh |

### 6. 云和 DevOps 工具

| ID | 类别 | 检测方式 | 导出内容 |
|----|------|----------|----------|
| `docker` | Docker | `command -v docker` | 镜像列表（可选） |
| `kubectl` | Kubernetes | `command -v kubectl` | contexts 列表 |
| `aws` | AWS CLI | `~/.aws` | 配置文件结构（不含密钥） |
| `gcloud` | Google Cloud | `~/.config/gcloud` | 配置文件结构 |
| `terraform` | Terraform | `command -v terraform` | 版本信息 |
| `helm` | Helm | `command -v helm` | 已安装 charts |

### 7. 数据库客户端

| ID | 类别 | 检测方式 | 导出内容 |
|----|------|----------|----------|
| `redis-cli` | Redis CLI | `.rediscli_history` | 历史配置 |
| `mysql-cli` | MySQL CLI | `.my.cnf` | 配置结构 |
| `pg-cli` | PostgreSQL | `.pgpass` | 配置结构（不含密码） |
| `sqlite` | SQLite | `.sqlite_history` | 历史 |

### 8. Git 和版本控制

| ID | 类别 | 检测方式 | 导出内容 |
|----|------|----------|----------|
| `git` | Git 配置 | `~/.gitconfig` | 全局配置（不含密钥） |
| `gh` | GitHub CLI | `command -v gh` | 扩展列表 |
| `lazygit` | Lazygit | `command -v lazygit` | 配置文件 |

### 9. AI 编程工具（新增重要类别）

| ID | 类别 | 检测方式 | 导出内容 |
|----|------|----------|----------|
| `claude` | Claude Code | `~/.claude` | 配置结构 |
| `copilot` | GitHub Copilot | `~/.copilot` | 配置结构 |
| `codeium` | Codeium | `~/.codeium` | 配置结构 |
| `continue` | Continue | `~/.continue` | 配置文件 |
| `aider` | Aider | `~/.aider*` | 配置文件 |
| `cursor` | Cursor AI | `~/.cursor` | 配置结构 |
| `windsurf` | Windsurf | `~/.windsurf` | 配置结构 |
| `tabnine` | Tabnine | `~/.tabnine` | 配置结构 |
| `ollama` | Ollama 模型 | `~/.ollama` | 已下载模型列表 |

### 10. 现代 CLI 工具

| ID | 类别 | 检测方式 | 导出内容 |
|----|------|----------|----------|
| `cli-tools` | CLI 增强工具 | 命令检测 | bat, fd, ripgrep, fzf, delta, eza, zoxide, atuin, jq, yq 等 |

---

## ADDED Requirements

### Requirement: 开发环境导出功能

系统 **SHALL** 提供 `mo export` 命令，自动检测并导出当前 Mac 上 **90%+ 的开发工具、包和配置**到可执行 shell 脚本。

#### Scenario: 基本导出

- **WHEN** 用户执行 `mo export`
- **THEN** 系统扫描所有已支持的工具类别
- **AND** 在当前目录生成 `mole-export-YYYYMMDD-HHMMSS.sh` 脚本
- **AND** 显示导出摘要（各类别数量统计）

#### Scenario: 指定输出文件

- **WHEN** 用户执行 `mo export -o ~/backup/my-setup.sh`
- **THEN** 脚本导出到指定路径

#### Scenario: 选择性导出

- **WHEN** 用户执行 `mo export --category brew,python,node`
- **THEN** 仅导出指定类别

#### Scenario: 排除类别

- **WHEN** 用户执行 `mo export --exclude apps,docker`
- **THEN** 导出除指定类别外的所有内容

#### Scenario: 干运行预览

- **WHEN** 用户执行 `mo export --dry-run`
- **THEN** 显示将要导出的内容摘要，但不生成文件

#### Scenario: 完整详情预览

- **WHEN** 用户执行 `mo export --dry-run --verbose`
- **THEN** 显示每个类别的详细导出列表

### Requirement: 智能检测

系统 **SHALL** 自动检测以下条件：

1. **工具存在性**：仅导出系统中实际存在的工具
2. **版本管理器优先**：检测到 pyenv 时优先导出 pyenv 版本而非系统 Python
3. **配置文件安全**：不导出敏感信息（密钥、token、密码）
4. **幂等性**：生成的脚本支持重复执行

### Requirement: 导出脚本格式

导出的 shell 脚本 **SHALL** 满足：

- 可直接执行 (`chmod +x` 后运行)
- 包含清晰的分节注释和目录结构
- 支持 `--dry-run` 和 `--skip <category>` 参数
- 智能跳过已安装的软件
- 依赖检查（如需要 brew 先安装）
- 错误处理和日志输出

---

## 命令行接口

```bash
mo export [OPTIONS]

OPTIONS:
  -o, --output <FILE>     指定输出文件路径 (默认: ./mole-export-<timestamp>.sh)
  -c, --category <LIST>   指定导出类别，逗号分隔 (默认: all)
  -e, --exclude <LIST>    排除指定类别
  --dry-run               预览模式，不生成文件
  --verbose               显示详细信息
  --no-comments           生成的脚本不包含注释
  --include-secrets       包含敏感配置（谨慎使用）
  --debug                 显示调试信息
  -h, --help              显示帮助信息

CATEGORY GROUPS:
  all         所有类别 (默认)
  essential   核心工具 (brew, mas, git, shell)
  dev         开发工具 (语言版本管理器 + 包管理器)
  ide         IDE 和编辑器
  cloud       云和 DevOps 工具
  ai          AI 编程工具

INDIVIDUAL CATEGORIES:
  brew, mas, apps, nvm, fnm, pyenv, rbenv, goenv, jenv, rustup, mise, asdf,
  npm, pnpm, yarn, bun, pip, uv, cargo, go, gem, composer,
  vscode, cursor, zed, neovim, vim,
  zsh, bash, fish, starship,
  docker, kubectl, aws, terraform,
  git, gh, lazygit,
  claude, copilot, codeium, continue, aider, ollama,
  cli-tools

EXAMPLES:
  mo export                              # 导出所有到默认文件
  mo export -o setup.sh                  # 导出到指定文件
  mo export --category brew,npm,pip      # 仅导出指定类别
  mo export --category dev               # 导出所有开发工具
  mo export --exclude apps,docker        # 排除指定类别
  mo export --dry-run --verbose          # 详细预览
```

---

## 导出脚本示例

```bash
#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Mole Export - 开发环境恢复脚本                                   ║
# ║  生成时间: 2026-02-26 10:30:00                                   ║
# ║  生成工具: Mole v1.24.0                                          ║
# ║  源机器: MacBook Pro (M4 Pro)                                    ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  使用方法:                                                        ║
# ║    chmod +x mole-export-20260226-103000.sh                       ║
# ║    ./mole-export-20260226-103000.sh [--dry-run] [--skip <cat>]   ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

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
        *) shift ;;
    esac
done

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
run() { $DRY_RUN && log "DRY-RUN: $*" || eval "$*"; }
should_skip() { [[ " ${SKIP_CATEGORIES[*]} " =~ " $1 " ]]; }

# ============================================================
# 1. Homebrew (336 formulae, 32 casks)
# ============================================================
install_homebrew() {
    should_skip "brew" && return 0
    log "📦 Installing Homebrew packages..."
    
    if ! command -v brew &> /dev/null; then
        log "  Installing Homebrew..."
        run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    fi
    
    run 'brew bundle --file=- <<BREWFILE
tap "homebrew/bundle"
tap "homebrew/cask"
# ... 336 formulae ...
brew "git"
brew "node"
brew "go"
# ... 32 casks ...
cask "visual-studio-code"
BREWFILE'
}

# ============================================================
# 2. Node.js 版本 (nvm)
# ============================================================
install_nvm() {
    should_skip "nvm" && return 0
    log "📗 Setting up Node.js versions (nvm)..."
    
    if [[ ! -d "$HOME/.nvm" ]]; then
        run 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash'
    fi
    
    source "$HOME/.nvm/nvm.sh"
    for ver in "20.19.6"; do
        nvm list | grep -q "$ver" || run "nvm install $ver"
    done
    run 'nvm alias default 20'
}

# ============================================================
# 3. npm 全局包 (19 packages)
# ============================================================
install_npm_global() {
    should_skip "npm" && return 0
    log "📗 Installing npm global packages..."
    
    local packages=(
        "npm@11.9.0"
        "vercel@48.2.9"
        "openclaw@2026.2.24"
        # ... 更多包 ...
    )
    
    for pkg in "${packages[@]}"; do
        npm list -g "$pkg" &>/dev/null || run "npm install -g $pkg"
    done
}

# ============================================================
# 4. Python (pyenv + pip)
# ============================================================
install_python() {
    should_skip "python" && return 0
    log "🐍 Setting up Python environment..."
    
    # pyenv (如果存在)
    if command -v pyenv &>/dev/null; then
        log "  Using pyenv for version management"
    fi
    
    # pip 全局包
    local pip_packages=(
        "black==25.9.0"
        "httpx==0.28.1"
        "langchain-core==0.3.51"
        # ...
    )
    run "pip3 install --user ${pip_packages[*]}"
}

# ============================================================
# 5. uv 工具
# ============================================================
install_uv_tools() {
    should_skip "uv" && return 0
    log "🐍 Installing uv tools..."
    
    command -v uv &>/dev/null || run 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    
    local tools=(
        "duckduckgo-mcp-server"
        "huggingface-hub"
        "kimi-cli"
        "y-cli"
    )
    for tool in "${tools[@]}"; do
        uv tool list | grep -q "$tool" || run "uv tool install $tool"
    done
}

# ============================================================
# 6. Go 工具 (30+ tools)
# ============================================================
install_go_tools() {
    should_skip "go" && return 0
    log "🐹 Installing Go tools..."
    
    local tools=(
        "github.com/go-delve/delve/cmd/dlv@latest"
        "github.com/spf13/cobra-cli@latest"
        # ...
    )
    for tool in "${tools[@]}"; do
        run "go install $tool"
    done
}

# ============================================================
# 7. Rust (cargo crates)
# ============================================================
install_rust() {
    should_skip "rust" && return 0
    log "🦀 Installing Rust tools..."
    
    command -v rustup &>/dev/null || run 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
    
    local crates=(
        "sqlx-cli"
        "skim"
    )
    for crate in "${crates[@]}"; do
        cargo install --list | grep -q "$crate" || run "cargo install $crate"
    done
}

# ============================================================
# 8. VSCode 扩展 (72 extensions)
# ============================================================
install_vscode_extensions() {
    should_skip "vscode" && return 0
    log "📝 Installing VSCode extensions..."
    
    command -v code &>/dev/null || return 0
    
    local extensions=(
        "ms-python.python"
        "golang.go"
        # ... 72 扩展 ...
    )
    for ext in "${extensions[@]}"; do
        code --list-extensions | grep -q "$ext" || run "code --install-extension $ext"
    done
}

# ============================================================
# 9. CLI 增强工具
# ============================================================
install_cli_tools() {
    should_skip "cli-tools" && return 0
    log "🔧 Verifying CLI tools..."
    
    # 这些通常通过 brew 安装，此处仅验证
    local tools=(bat fd ripgrep fzf delta eza zoxide jq yq starship lazygit)
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null && log "  ✓ $tool"
    done
}

# ============================================================
# 10. AI 编程工具配置
# ============================================================
setup_ai_tools() {
    should_skip "ai" && return 0
    log "🤖 AI tools detected (manual setup may be required):"
    
    local ai_dirs=(
        ".claude:Claude Code"
        ".copilot:GitHub Copilot"
        ".codeium:Codeium"
        ".continue:Continue"
        ".aider:Aider"
        ".ollama:Ollama"
    )
    for item in "${ai_dirs[@]}"; do
        local dir="${item%%:*}"
        local name="${item#*:}"
        [[ -d "$HOME/$dir" ]] && log "  • $name (配置目录已存在)"
    done
}

# ============================================================
# 手动安装应用
# ============================================================
# 以下应用需要手动下载安装（非 Homebrew/AppStore）:
#   - OrbStack (https://orbstack.dev/)
#   - CleanMyMac X (https://macpaw.com/cleanmymac)

# ============================================================
# 执行主流程
# ============================================================
main() {
    log "🚀 Mole Export - 开始恢复开发环境"
    log "   Dry run: $DRY_RUN"
    log "   Skip: ${SKIP_CATEGORIES[*]:-none}"
    echo
    
    install_homebrew
    install_nvm
    install_npm_global
    install_python
    install_uv_tools
    install_go_tools
    install_rust
    install_vscode_extensions
    install_cli_tools
    setup_ai_tools
    
    echo
    log "✅ 恢复完成! 日志: $LOG_FILE"
}

main
```

---

## 安全考虑

### 不导出的内容

- AWS/GCloud 密钥和凭证
- SSH 私钥
- Git 凭证
- API tokens
- 数据库密码
- 任何 `*_token`, `*_secret`, `*_key` 文件

### 可选导出（需显式启用）

- `--include-secrets`：导出配置文件结构（仍过滤明确的密钥）
