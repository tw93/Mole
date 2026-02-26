# Tasks

## 阶段一：核心框架

- [x] Task 1: 创建 export 命令入口和框架
  - [x] SubTask 1.1: 创建 `bin/export.sh` 主入口脚本，解析命令行参数 (-o, -c, -e, --dry-run, --verbose, --help)
  - [x] SubTask 1.2: 在 `mole` 主文件中添加 `export` 命令路由
  - [x] SubTask 1.3: 在 `lib/core/commands.sh` 中注册 export 命令描述
  - [x] SubTask 1.4: 创建 `lib/export/` 目录结构和 `common.sh` 公共函数（检测、日志、脚本生成）

- [x] Task 2: 实现脚本生成框架
  - [x] SubTask 2.1: 实现脚本头部生成（时间戳、机器信息、使用说明）
  - [x] SubTask 2.2: 实现分节模板和注释格式
  - [x] SubTask 2.3: 实现类别分组逻辑（all/essential/dev/ide/cloud/ai）
  - [x] SubTask 2.4: 实现输出文件写入逻辑（支持 -o 参数和默认命名）

## 阶段二：系统级包管理模块

- [x] Task 3: 实现 Homebrew 导出模块 (`lib/export/brew.sh`)
  - [x] SubTask 3.1: 检测 brew 是否存在
  - [x] SubTask 3.2: 调用 `brew bundle dump --file=-` 获取 Brewfile 内容
  - [x] SubTask 3.3: 生成带幂等检查的安装函数
  - [x] SubTask 3.4: 统计 formulae/casks/taps 数量

- [x] Task 4: 实现 Mac App Store 导出模块 (`lib/export/mas.sh`)
  - [x] SubTask 4.1: 检测 mas-cli 是否存在
  - [x] SubTask 4.2: 调用 `mas list` 获取已安装应用 ID 和名称
  - [x] SubTask 4.3: 生成 mas install 命令序列

- [x] Task 5: 实现 Applications 扫描模块 (`lib/export/apps.sh`)
  - [x] SubTask 5.1: 扫描 /Applications 和 ~/Applications 目录
  - [x] SubTask 5.2: 过滤已通过 brew cask 管理的应用
  - [x] SubTask 5.3: 过滤已通过 mas 管理的应用
  - [x] SubTask 5.4: 尝试从 Info.plist 获取应用官网链接
  - [x] SubTask 5.5: 生成手动安装应用列表（注释形式）

## 阶段三：语言版本管理器模块

- [x] Task 6: 实现 Node.js 版本管理导出 (`lib/export/node_version.sh`)
  - [x] SubTask 6.1: 检测 nvm (`~/.nvm` 目录)
  - [x] SubTask 6.2: 检测 fnm (`command -v fnm`)
  - [x] SubTask 6.3: 导出已安装 Node 版本列表
  - [x] SubTask 6.4: 导出默认版本设置

- [x] Task 7: 实现 Python 版本管理导出 (`lib/export/python_version.sh`)
  - [x] SubTask 7.1: 检测 pyenv (`command -v pyenv`)
  - [x] SubTask 7.2: 导出 `pyenv versions --bare` 已安装版本
  - [x] SubTask 7.3: 导出全局版本设置

- [x] Task 8: 实现其他版本管理器导出 (`lib/export/version_managers.sh`)
  - [x] SubTask 8.1: 检测并导出 rbenv (Ruby)
  - [x] SubTask 8.2: 检测并导出 goenv (Go)
  - [x] SubTask 8.3: 检测并导出 jenv (Java)
  - [x] SubTask 8.4: 检测并导出 rustup 工具链
  - [x] SubTask 8.5: 检测并导出 mise/asdf 管理的工具

## 阶段四：包管理器全局包模块

- [x] Task 9: 实现 Node.js 包管理器导出 (`lib/export/node_packages.sh`)
  - [x] SubTask 9.1: 导出 npm 全局包 (`npm list -g --depth=0 --json`)
  - [x] SubTask 9.2: 导出 pnpm 全局包 (`pnpm list -g --depth=0`)
  - [x] SubTask 9.3: 导出 yarn 全局包 (`yarn global list`)
  - [x] SubTask 9.4: 导出 bun 全局包 (`bun pm ls -g`)

- [x] Task 10: 实现 Python 包管理器导出 (`lib/export/python_packages.sh`)
  - [x] SubTask 10.1: 导出 pip 用户全局包 (`pip3 list --user --format=freeze`)
  - [x] SubTask 10.2: 导出 uv 工具 (`uv tool list`)
  - [x] SubTask 10.3: 检测 poetry/pdm/rye 并提示

- [x] Task 11: 实现 Rust/Go/Ruby 包导出 (`lib/export/other_packages.sh`)
  - [x] SubTask 11.1: 导出 cargo crates (`cargo install --list`)
  - [x] SubTask 11.2: 导出 Go 工具 (扫描 `$(go env GOPATH)/bin`)
  - [x] SubTask 11.3: 导出 gem 全局包 (`gem list --local`)
  - [x] SubTask 11.4: 检测 composer (PHP) 并导出全局包

## 阶段五：IDE 和编辑器模块

- [x] Task 12: 实现 IDE 扩展导出 (`lib/export/ide.sh`)
  - [x] SubTask 12.1: 导出 VSCode 扩展 (`code --list-extensions`)
  - [x] SubTask 12.2: 导出 Cursor 扩展 (`cursor --list-extensions`)
  - [x] SubTask 12.3: 导出 Windsurf 扩展 (`windsurf --list-extensions`)
  - [x] SubTask 12.4: 检测 Zed 扩展目录
  - [x] SubTask 12.5: 检测 Neovim/Vim 插件配置

## 阶段六：Shell 和配置文件模块

- [x] Task 13: 实现 Shell 配置导出 (`lib/export/shell.sh`)
  - [x] SubTask 13.1: 检测并记录 .zshrc/.zprofile
  - [x] SubTask 13.2: 检测并记录 .bashrc/.bash_profile
  - [x] SubTask 13.3: 检测并记录 fish 配置
  - [x] SubTask 13.4: 检测 starship.toml 配置
  - [x] SubTask 13.5: 检测 oh-my-zsh 主题和插件

- [x] Task 14: 实现 Git 配置导出 (`lib/export/git.sh`)
  - [x] SubTask 14.1: 导出 .gitconfig（过滤敏感信息）
  - [x] SubTask 14.2: 导出 gh CLI 扩展列表
  - [x] SubTask 14.3: 导出 lazygit 配置

## 阶段七：云和 DevOps 工具模块

- [x] Task 15: 实现云工具导出 (`lib/export/cloud.sh`)
  - [x] SubTask 15.1: 检测 docker 并可选导出镜像列表
  - [x] SubTask 15.2: 检测 kubectl 并导出 contexts 列表
  - [x] SubTask 15.3: 检测 AWS CLI 配置结构（不含密钥）
  - [x] SubTask 15.4: 检测 terraform 版本
  - [x] SubTask 15.5: 检测 helm 已安装 charts

## 阶段八：AI 编程工具模块（新增）

- [x] Task 16: 实现 AI 工具导出 (`lib/export/ai.sh`)
  - [x] SubTask 16.1: 检测 Claude Code 配置 (`~/.claude`)
  - [x] SubTask 16.2: 检测 GitHub Copilot 配置
  - [x] SubTask 16.3: 检测 Codeium/Tabnine/Continue 配置
  - [x] SubTask 16.4: 检测 Aider 配置文件
  - [x] SubTask 16.5: 检测 Ollama 已下载模型 (`ollama list`)
  - [x] SubTask 16.6: 生成 AI 工具配置恢复提示

## 阶段九：现代 CLI 工具模块

- [x] Task 17: 实现 CLI 工具检测 (`lib/export/cli_tools.sh`)
  - [x] SubTask 17.1: 检测并列出已安装的现代 CLI 工具（bat, fd, ripgrep, fzf, delta, eza, zoxide, atuin, jq, yq, sd, hyperfine 等）
  - [x] SubTask 17.2: 验证这些工具是否已通过 brew 导出
  - [x] SubTask 17.3: 对未通过 brew 安装的工具生成安装命令

## 阶段十：整合、UI 和测试

- [x] Task 18: 整合所有模块和 UI
  - [x] SubTask 18.1: 实现 `--category` 和 `--exclude` 过滤逻辑
  - [x] SubTask 18.2: 实现 `--dry-run` 预览模式（摘要和详细）
  - [x] SubTask 18.3: 实现导出摘要统计和进度 UI
  - [x] SubTask 18.4: 实现 `--help` 完整帮助信息
  - [x] SubTask 18.5: 实现敏感信息过滤机制

- [x] Task 19: 编写测试用例
  - [x] SubTask 19.1: 创建 `tests/export.bats` 测试文件
  - [x] SubTask 19.2: 测试命令行参数解析
  - [x] SubTask 19.3: 测试各导出模块检测逻辑（使用 mock）
  - [x] SubTask 19.4: 测试生成脚本的语法正确性 (`bash -n`)
  - [x] SubTask 19.5: 测试敏感信息过滤

# Task Dependencies

```
Task 1 (框架) ✅
    ↓
Task 2 (脚本生成) ✅
    ↓
┌───┴───┬───────┬───────┬───────┬───────┬───────┬───────┐
│       │       │       │       │       │       │       │
▼       ▼       ▼       ▼       ▼       ▼       ▼       ▼
T3 ✅   T4 ✅   T5 ✅   T6-8 ✅ T9-11✅  T12 ✅  T13-14✅ T15-17✅
brew    mas     apps    版本    包管理   IDE     Shell   Cloud/AI
│       │       │       │       │       │       │       │
└───────┴───────┴───────┴───────┴───────┴───────┴───────┘
                            ↓
                        Task 18 (整合) ✅
                            ↓
                        Task 19 (测试) ✅
```

- Task 2 依赖 Task 1（框架先行）
- Task 3-17 依赖 Task 2（模块依赖框架）
- Task 3-17 可并行开发（各模块独立）
- Task 18 依赖 Task 3-17（整合依赖所有模块）
- Task 19 依赖 Task 18（测试依赖完整功能）

# 并行开发建议

以下任务可以同时进行：
- Task 3, 4, 5（系统级包管理）
- Task 6, 7, 8（版本管理器）
- Task 9, 10, 11（包管理器）
- Task 12, 13, 14（IDE 和配置）
- Task 15, 16, 17（云/AI/CLI）
