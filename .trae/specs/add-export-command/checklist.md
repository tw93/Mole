# Checklist

## 功能完整性

- [x] `mo export` 命令可正常执行并生成脚本文件
- [x] `mo export -o <path>` 可将脚本输出到指定路径
- [x] `mo export --category <list>` 可选择性导出指定类别
- [x] `mo export --exclude <list>` 可排除指定类别
- [x] `mo export --category dev` 可使用类别组（dev/ide/cloud/ai）
- [x] `mo export --dry-run` 显示预览但不生成文件
- [x] `mo export --dry-run --verbose` 显示详细预览
- [x] `mo export --help` 显示完整帮助信息
- [x] `mo --help` 中包含 export 命令说明

## 系统级包管理模块覆盖

- [x] Homebrew 模块：正确导出 formulae/casks/taps 并统计数量
- [x] Mac App Store 模块：正确导出已安装应用 ID 和名称
- [x] Applications 模块：列出非 Homebrew/AppStore 安装的应用，并尝试获取官网链接

## 语言版本管理器模块覆盖

- [x] nvm 检测：正确导出已安装 Node 版本
- [x] fnm 检测：正确导出已安装 Node 版本
- [x] pyenv 检测：正确导出已安装 Python 版本
- [x] rbenv 检测：正确导出已安装 Ruby 版本
- [x] goenv 检测：正确导出已安装 Go 版本
- [x] jenv 检测：正确导出已安装 Java 版本
- [x] rustup 检测：正确导出已安装 Rust 工具链
- [x] mise/asdf 检测：正确导出已安装工具和版本

## 包管理器全局包模块覆盖

- [x] npm 全局包：正确导出包名和版本
- [x] pnpm 全局包：正确导出包名和版本
- [x] yarn 全局包：正确导出包名
- [x] bun 全局包：正确导出包名和版本
- [x] pip 用户包：正确导出包名和版本
- [x] uv 工具：正确导出已安装工具
- [x] cargo crates：正确导出已安装 crates
- [x] Go 工具：正确扫描 GOPATH/bin 下的工具
- [x] gem 包：正确导出已安装 gems
- [x] composer 全局包（如存在）：正确导出

## IDE 和编辑器模块覆盖

- [x] VSCode 扩展：正确导出扩展列表
- [x] Cursor 扩展：正确导出扩展列表
- [x] Windsurf 扩展：正确导出扩展列表
- [x] Zed 扩展：检测并记录扩展目录
- [x] Neovim 插件：检测配置文件
- [x] Vim 插件：检测 .vimrc

## Shell 和配置文件模块覆盖

- [x] Zsh 配置：检测 .zshrc/.zprofile
- [x] Bash 配置：检测 .bashrc/.bash_profile
- [x] Fish 配置：检测 config.fish
- [x] Starship：检测 starship.toml
- [x] Oh My Zsh：检测主题和插件

## Git 配置模块覆盖

- [x] Git 配置：导出 .gitconfig（过滤敏感信息）
- [x] GitHub CLI：导出 gh 扩展列表
- [x] Lazygit：检测配置文件

## 云和 DevOps 工具模块覆盖

- [x] Docker：检测并可选导出镜像列表
- [x] Kubectl：导出 contexts 列表
- [x] AWS CLI：检测配置结构（不含密钥）
- [x] Terraform：检测版本
- [x] Helm：检测已安装 charts

## AI 编程工具模块覆盖（新增重要类别）

- [x] Claude Code：检测 ~/.claude 配置
- [x] GitHub Copilot：检测配置
- [x] Codeium：检测配置
- [x] Continue：检测配置
- [x] Aider：检测配置
- [x] Cursor：检测 ~/.cursor 配置
- [x] Windsurf：检测 ~/.windsurf 配置
- [x] Tabnine：检测配置
- [x] Ollama：导出已下载模型列表

## 现代 CLI 工具模块覆盖

- [x] 检测 bat, fd, ripgrep, fzf, delta, eza, zoxide, atuin, jq, yq 等工具
- [x] 验证这些工具是否已通过 brew 导出
- [x] 对未通过 brew 安装的工具生成安装命令

## 智能检测

- [x] 不存在的工具不会导致错误
- [x] 仅导出系统中实际存在的工具类别
- [x] 检测逻辑覆盖常见版本管理器路径（~/.nvm, ~/.pyenv 等）
- [x] 正确处理多版本管理器共存的情况

## 生成脚本质量

- [x] 生成的脚本语法正确（通过 `bash -n` 检查）
- [x] 脚本支持 `--dry-run` 参数
- [x] 脚本支持 `--skip <category>` 参数
- [x] 脚本包含清晰的分节注释和目录结构
- [x] 安装逻辑具有幂等性（已安装则跳过）
- [x] 依赖检查完善（如无 brew 则先安装）
- [x] 脚本头部包含生成时间、源机器信息、使用说明

## 安全性

- [x] 不导出 AWS/GCloud 密钥和凭证
- [x] 不导出 SSH 私钥
- [x] 不导出 Git 凭证
- [x] 不导出 API tokens
- [x] 不导出数据库密码
- [x] 过滤任何 `*_token`, `*_secret`, `*_key` 内容

## 代码质量

- [x] 遵循项目现有的代码风格和约定
- [x] 所有新函数有适当的注释
- [x] 无 ShellCheck 警告
- [x] 测试用例通过

## 用户体验

- [x] 导出过程有进度提示
- [x] 导出完成后显示摘要统计（各类别数量）
- [x] 错误信息清晰有指导性
- [x] 与现有 Mole 命令风格一致
- [x] 类别组（dev/ide/cloud/ai）便于快速选择

## 覆盖率目标

- [x] 覆盖 90%+ 的常见研发工具（基于本机扫描结果验证）
- [x] 支持 20+ 个导出类别
- [x] 支持 5 个类别组（all/essential/dev/ide/cloud/ai）
