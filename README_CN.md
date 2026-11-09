<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <img src="./docs/img/mole-logo.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Windows</h1>
  <p><b>Windows 电脑深度清理、应用卸载、系统优化、磁盘分析与状态监控，免费开源命令行</b></p>
  <p><a href="README.md">English</a> · 中文 · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Mole CLI for Windows 菜单界面" width="1000" />
</p>

> 💡 这个分支是免费开源的 Windows 命令行工具（`mo`），喜欢图形界面的话可以单独下载 [Mole for Windows](https://mole.fit/zh/windows)，支持删除前逐项确认、应用更新、启动项管理、逐层分析磁盘空间与实时状态监控，macOS 命令行在 [main 分支](https://github.com/tw93/Mole#readme)。

## 功能

- **多合一命令行**：把 CCleaner、IObit Uninstaller、WinDirStat 与任务管理器的日常用法放进一个终端命令
- **深度清理**：清除临时文件、缓存、日志与浏览器残留，释放磁盘空间
- **应用卸载**：移除应用程序，同时清理它留下的安装目录
- **磁盘分析**：在终端里交互式浏览磁盘占用，找出大文件
- **系统维护**：刷新 DNS、优化系统盘并检查磁盘健康
- **实时监控**：实时查看 CPU、内存、磁盘、网络与进程状态

## 快速开始

Mole 支持 Windows 10 和 11，使用系统自带的 Windows PowerShell 5.1 即可运行，脚本安装需要 Git，源码和最新发布版不一致时还需要 Go 来构建原生工具，会安装到 `%LOCALAPPDATA%\Programs\mole-cli`，并把 `mo` 和 `mole` 加入 PATH。

**通过 Scoop 安装**

```powershell
scoop install mole
```

**或通过脚本安装**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole 只通过这个 GitHub 仓库、Scoop 和 Windows 版官网 [mole.fit](https://mole.fit/zh/windows) 发布，自称基于 Mole 的其他 App，或者让你往终端里粘贴一段编码命令的网站，都和 Mole 无关。

**用 AI Agent 安装**

直接告诉你的 Agent：

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

也可以自己装 skill，装上后 Claude Code、Codex、Cursor 等 Agent 删东西前会先用 `--dry-run` 把清单给你看，卸载 App 和要管理员权限的步骤留给你自己跑，更新用 `npx skills update -g -y`。

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

喜欢用宿主自带的插件管理，Claude Code 里先 `/plugin marketplace add tw93/Mole` 再 `/plugin install mole@mole`，Codex 里先 `codex plugin marketplace add tw93/Mole` 再 `codex plugin add mole@mole`，DeepSeek Harness 里用 `dsh plugin --profile <name> add dsh-mole`。

**常用命令**

```powershell
mo                           # 打开交互式菜单
mo clean                     # 深度清理
mo uninstall                 # 卸载应用及其残留
mo optimize                  # 刷新缓存与服务
mo analyze                   # 磁盘空间浏览
mo status                    # 实时系统健康看板
mo purge                     # 清理项目构建产物

mo update                    # 检查并更新 Mole
mo remove                    # 从这台电脑上完全卸载 Mole
mo --help                    # 查看帮助信息
mo --version                 # 查看已安装版本
```

**安全预览**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 安全预览 + 详细诊断日志
mo clean --whitelist         # 管理受保护的路径
mo clean --system            # 包含系统级清理（需以管理员身份运行）
mo purge --paths             # 配置项目扫描目录
mo analyze D:\               # 分析另一块磁盘
mo uninstall --list          # 列出已安装应用，管道输出时为 JSON
mo analyze --json D:\        # 以 JSON 输出磁盘分析
```

<details>
<summary><strong>其他安装选项</strong></summary>

想先看代码再安装的话，克隆 `windows` 分支并在原地运行安装脚本，它会保留 `.git`，之后 `mo update` 照常可用：

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

加上 `-CreateShortcut` 会创建开始菜单入口，卸载时运行 `mo remove`。

</details>

## 安全机制

Mole 会删除文件，所以会先校验路径、保护系统和用户配置目录，`uninstall`、`purge` 与 `remove` 删除前都会请你确认，无法确认安全的项目一律跳过。

- `clean`、`uninstall` 与 `purge` 会删除文件，可先用 `--dry-run` 预览，需要时加上 `--debug`
- `clean` 与 `purge` 是永久删除，已核实的 `uninstall` 残留会放进回收站，应用自身的卸载器保留其原有行为，`mo analyze` 中删除的文件也会放进回收站，放不进回收站的大项目 Windows 会先询问是否永久删除
- 用普通用户身份运行 Mole 即可，系统级步骤只有以管理员身份运行 PowerShell 时才会执行，否则跳过
- 可通过 `mo clean --whitelist` 保护指定路径
- 清理操作记录在 `%USERPROFILE%\.config\mole\operations.log` 中，可通过 `mo history` 查看，或设置 `MO_NO_OPLOG=1` 禁用
- `C:\Windows`、`C:\Program Files`、Windows Defender 目录和用户配置根目录永远不会被触碰

漏洞报告方式与安全边界见 [SECURITY.md](SECURITY.md)。

## 功能说明

以下截图来自一台测试电脑，具体显示项与大小取决于你的电脑实际环境。

### 深度清理（Clean）

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="mo clean --dry-run 预览" width="736" />

详细清单里是预览找到的每一个路径，想保留哪个，就把它复制进白名单。

### 应用卸载（Uninstall）

```powershell
mo uninstall
```

从注册表和 Windows 应用中列出已安装的程序，按占用从大到小排序，选中的软件会用它自己的卸载程序移除，再清理遗留的安装目录，`mo uninstall --dry-run` 会显示每个软件将使用哪个卸载程序、会移除什么，但不会运行任何东西。

<img src="./docs/img/uninstall-windows.png" alt="mo uninstall 应用列表" width="1000" />

### 系统优化（Optimize）

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="mo optimize --dry-run 预览" width="736" />

磁盘优化、刷新 ARP 缓存这类步骤需要管理员权限，否则会跳过，想包含它们就以管理员身份运行 PowerShell。

### 磁盘分析（Analyze）

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="mo analyze 概览" width="1000" />

交互式磁盘浏览器，布局和 macOS 版一致，方向键在目录间移动，`Backspace` 返回，`T` 列出最大的文件，`Del` 在确认后把选中的项目放进回收站。

### 状态监控（Status）

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="mo status 看板" width="1000" />

实时看板，包含健康评分、CPU、内存、磁盘、电源、网络和最繁忙的进程。

### 项目清理（Purge）

```powershell
mo purge --dry-run
```

在你的项目目录里找出构建产物（`node_modules`、`target`、`build`、`dist`、`venv` 等），由你挑选要清理的项目，选择之前什么都不会勾选，扫描的目录可以用 `mo purge --paths` 配置。

## 社区反馈

感谢所有参与 Mole 开发与维护的贡献者，去关注一下他们吧 ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole 贡献者" width="1000" />
</a>

## 支持项目

- 购买 [Mole for Windows](https://mole.fit/zh/windows) 是支持 Mole 持续开发最直接的方式
- 如果 Mole 帮到了你，欢迎点个 Star、[分享给朋友](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.)，或在 GitHub 提交 Issue 和 PR
- 欢迎参与贡献，先看一下 [CONTRIBUTING.md](CONTRIBUTING.md)
- 我养了两只猫，汤圆和可乐，如果 Mole 用着顺手，欢迎投喂她们一顿 <a href="https://cats.tw93.fun?name=Mole" target="_blank">罐头 🥩</a>

## 开源协议

Mole 基于 GPL-3.0 协议开源（详见 [LICENSE](LICENSE)），任何修改与分发的版本需要保持相同的开源协议，如果你将 Mole 分叉为其他独立产品，请使用不同名称并注明出处，详见 [TRADEMARK.md](TRADEMARK.md)。
