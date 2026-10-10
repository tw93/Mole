<div align="center">
  <h1>Mole</h1>
  <p><b>Mac 深度清理、应用卸载、系统优化、磁盘分析与状态监控，免费开源命令行，另有原生 Mac App</b></p>
  <p><a href="README.md">English</a> · 中文 · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Mole 清理效果" width="1000" />
</p>

> 💡 这个仓库是免费开源的命令行工具（`mo`），喜欢图形界面的话可以单独下载 [Mole for Mac](https://mole.fit/)，支持删除前逐项确认、实测 800 多款软件的卸载残留、系统维护、逐层分析磁盘空间、实时状态监控，以及在支持的 Mac 上控制风扇，`brew install mole` 只会安装命令行工具。

## 功能

- **多合一命令行**：把 CleanMyMac、AppCleaner、DaisyDisk 与 iStat Menus 的日常用法放进一个终端命令
- **深度清理**：清除系统缓存、应用日志与卸载残留，释放磁盘空间
- **应用卸载**：移除应用程序，同步清理配置文件与自启动项
- **磁盘分析**：终端交互式浏览目录层级，定位占用空间的大文件
- **系统优化**：刷新系统服务与缓存，优化核心数据库
- **实时监控**：在终端看板中实时查看 CPU、内存、磁盘读写、网络流量与进程

## 快速开始

Mole 支持 macOS 12 及更高版本，兼容 Intel 与 Apple Silicon 芯片，Homebrew 不再支持你的 macOS 版本时改用脚本安装，实验性的 Windows 版本在 [windows 分支](https://github.com/tw93/Mole/tree/windows)。

**通过 Homebrew 安装**

```bash
brew install mole
```

**通过脚本安装**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**常用命令**

```bash
mo                           # 打开交互式菜单
mo clean                     # 深度清理与已卸载应用残留
mo uninstall                 # 卸载应用及其残留
mo optimize                  # 刷新系统缓存与服务
mo analyze                   # 磁盘空间浏览（也可写 mo analyse）
mo status                    # 实时系统健康看板
mo purge                     # 清理项目构建产物
mo installer                 # 查找并删除安装包

mo touchid                   # 配置终端 Touch ID 指纹提权
mo completion                # 配置命令行 Tab 键自动补全
mo update                    # 检查并更新 Mole
mo update --nightly          # 更新到最新未发布的开发版（仅限脚本安装）
mo remove                    # 从系统中完全卸载 Mole
mo --help                    # 查看帮助信息
mo --version                 # 查看已安装版本
```

**安全预览**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 安全预览 + 详细诊断日志
mo optimize --whitelist      # 管理受保护的优化规则
mo clean --whitelist         # 管理受保护的缓存白名单
mo purge --paths             # 配置代码项目扫描目录
mo analyze /Volumes          # 仅分析外接移动硬盘或磁盘卷
mo analyze /private/tmp      # 仅查看临时目录（不自动清理）
```

<details>
<summary><strong>其他安装选项</strong></summary>

如需安装特定版本，可传入 [Releases 页面](https://github.com/tw93/mole/releases) 中的任意 Tag（带或不带前导 `V` 均可）。如需跟踪开发分支，可传入 `main`：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` 会安装默认分支上还没发布的代码，可能不稳定，`latest` 只是 `main` 的旧别名，并不会安装最新稳定版。

安装脚本默认安装至 `/usr/local/bin`，可能需要输入管理员密码。如果你希望以后的 `mo update` 无需密码，可以安装至用户目录：

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

记得将 `export PATH` 加入 `~/.zshrc` 或相应的终端配置文件。Mole 更新的是你运行的那份安装，之后会一直用这个目录，需要改系统文件的命令仍可能要管理员权限。

**Nix**

在 macOS 上，Nix 用户可从 `main` 分支安装 flake，其中包含还没发布的改动：

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

声明式配置可将 `github:tw93/mole/main` 添加为 flake input，使用其 `packages.${system}.mole` 包。Nix 管理的安装要通过 Nix 升级和卸载，`mo update` 和 `mo remove` 不会改动它。

</details>

## 安全机制

Mole 会删除文件，所以会先校验路径、保护共享和系统目录，需要时才请你确认，无法确认安全的项目一律跳过或拒绝。

- `clean`、`uninstall`、`purge`、`installer` 与 `remove` 会删除文件，可先用 `--dry-run` 预览，需要时加上 `--debug`
- 日常运行 **无需 `sudo`**，仅在触及系统级清理时按需请求管理员权限
- `mo analyze` 中的删除操作在确认后默认放入 macOS 废纸篓
- 清理操作记录在 `~/Library/Logs/mole/operations.log` 中，可通过 `mo history` 查看，或设置 `MO_NO_OPLOG=1` 禁用
- 可通过 `mo clean --whitelist` 保护指定缓存，或使用 `mo optimize --whitelist` 排除维护项

漏洞报告方式、安全边界与当前限制见 [SECURITY.md](SECURITY.md) 与 [SECURITY_AUDIT.md](SECURITY_AUDIT.md)。

## 功能说明

以下展示为缩减示例，具体显示项、大小与跳过原因取决于你的 Mac 实际环境。

### 深度清理（Clean）

`mo clean` 扫描并清理已知可安全删除的缓存、日志、临时文件、开发工具缓存以及已卸载应用的残留，默认会清空废纸篓，想保留就在 `mo clean --whitelist` 里勾选 Trash，同一个菜单也用来保护想留下的缓存。选好的项会写进 `~/.config/mole/whitelist`，想加自定义路径时先打开菜单按回车保存一次，再往文件里每行追加一个路径，文件一旦存在就会替换可选默认规则，内置安全保护仍然生效。

```text
$ mo clean

Clean Your Mac

⚙ Apple Silicon | Free space: 219.0GB

➤ User essentials
  ✓ User app cache · 18 items, 2.4GB
  ✓ User app logs · 7 items, 12.8MB
  ✓ Trash · emptied, 9 items

➤ App caches
  ✓ App Store cache · 8 items, 248.5MB

➤ Browsers
  ✓ Safari cache · 24 items, 642.1MB
  ✓ Chrome cache · 31 items, 1.2GB

➤ Developer tools
  ✓ npm cache · cleaned
  ◎ pnpm cache · skipped (pnpm busy)

======================================================================
Cleanup complete
Tracked cleanup: 4.5GB | Items cleaned: 97 | Categories: 4
Free space: 223.5GB (+4.5GB)
======================================================================
```

### 应用卸载（Uninstall）

`mo uninstall` 移除已安装的应用，以及 Mole 能确认属于这个应用的相关文件；若同一应用的另一个已安装副本仍在使用这些文件，会自动保留，应用此前已被手动删除的话，运行 `mo clean` 扫描残留。

```text
$ mo uninstall

Select Apps to Remove  1/3 selected

➤ ● Photoshop 2024                4.20GB | 2mo ago
  ○ IntelliJ IDEA                 2.80GB | 3d ago
  ○ Premiere Pro                  3.40GB | 2w ago

Files to be removed:

✓ Photoshop 2024, 12.80GB
  ✓ /Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app
  ✓ ~/Library/Application Support/Adobe/Adobe Photoshop 2024
  ✓ ~/Library/Preferences/com.adobe.Photoshop.plist

======================================================================
Uninstall complete
Removed 1 app, freed 12.80GB: Photoshop 2024
======================================================================
```

### 系统优化（Optimize）

`mo optimize` 对支持的 Finder、网络、数据库与 macOS 服务执行范围明确的维护，非必要、当前执行不安全或不可用的任务会跳过并说明原因。可用 `mo optimize --whitelist` 排除任务或路径模式，例如常驻挂载的 `/Volumes/mail`，避免它被识别为卸载目标。

```text
$ mo optimize

Optimize

⚙ System  18/32 GB RAM | 616/926 GB Disk | Uptime 6d

PERFORMANCE DIAGNOSIS
  ✓ No sustained high-CPU bottleneck detected

➤ DNS & Spotlight Check
  → DNS cache flushed
  → Spotlight index verified

➤ Finder Cache Refresh
  → QuickLook thumbnails refreshed
  → Icon services cache rebuilt

➤ Database Optimization
  ◎ Close these apps before database optimization: Safari

➤ Disk Health
  → Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)

======================================================================
Optimization Complete
Applied 3 optimizations
14 unchanged | 3 skipped | 1 unavailable
======================================================================
```

### 磁盘分析（Analyze）

`mo analyze` 打开终端交互式磁盘分析器，支持方向键与 Vim 快捷键浏览、快速过滤、多选标记、Finder 预览与移入废纸篓。外置磁盘默认不在概览中显示，可运行 `mo analyze /Volumes` 或指定挂载路径单独查看，`mo analyze /private/tmp` 只检查临时目录，不会把它们变成自动清理目标。

以 `+` 结尾的大小是部分扫描里实际测到的字节数，`unknown` 表示没法测出大小。因临时超时中断的条目不会覆盖已有完整缓存，后续刷新可自动补全。macOS 不允许终端读取的文件夹会一直标为部分扫描，直到访问权限改变。终端界面只列出最大的 30 项，读不到的条目可能不在这 30 项里，但总量仍会标为部分扫描，JSON 格式输出则包含所有扫描条目。

`mo analyze --json /path` 的结果本身和其中每一项都带有 `scan_status`（`complete`、`partial` 或 `unavailable`）。数值大小是实际测到的字节数，`unavailable` 时的 0 也不代表目录为空。未完成的扫描仍返回退出码 0，脚本要看 `scan_status` 判断结果是否完整。完整性以 Mole 现有的扫描排除规则为界，不保证是文件系统的原子快照。

```text
$ mo analyze

Analyze Disk  (302.1GB free)
Select a location to explore:

 ▶  1. ████████████████████████  47.9%  |  Home                       75.4GB
    2. ███████████               22.0%  |  User Library               34.6GB
    3. ███████                   14.2%  |  Applications               22.4GB
    4. █████                     10.7%  |  System Library             16.9GB
    5. ███                        5.2%  |  Old Downloads (90d+)       8.2GB  >3mo
```

### 状态监控（Status）

`mo status` 提供只读系统硬件仪表盘，涵盖 CPU、系统负载、磁盘读写、网络流量、电源与进程。

当默认 IPv4 路由走 VPN 或隧道接口时，流量图表会统计这个接口，避免和物理网卡重复计算。JSON 输出保留每个接口的速率，包括路由经过的隧道，空闲的非默认隧道不显示。

```text
$ mo status

Mole Status  Health ● 92  MacBook Pro · M4 Pro · 32GB · macOS 26

⚙ CPU                                    ▦ Memory
Total   ████████████░░░░░░░  45.2%       Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (8 cores)     Total   18.7 / 32.0 GB
Core 1  ███████████████░░░░  78.3%       Free    ████████░░░░░░░░░░  41.6%
Core 2  ████████████░░░░░░░  62.1%       Avail   13.3 GB

▤ Disk                                   ⚡ Power
Used    █████████████░░░░░░  67.2%       Level   ██████████████████  100%
Free    156.3 GB                         Status  Charged
Read    ▮▯▯▯▯  2.1 MB/s                  Health  Normal · 423 cycles
Write   ▮▮▮▯▯  18.3 MB/s                 Temp    58°C · 1200 RPM

⇅ Network                                ▶ Processes
Down    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s      Zombies 3 · Chrome (4242) ×3
Up      ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s      Code       ▮▮▮▮▯  42.1%
Proxy   HTTP · 192.168.1.100             Chrome     ▮▮▮▯▯  28.3%
```

健康评分综合了 CPU、内存、磁盘余量、SMART 状态、I/O 读写、温度、电池状况与运行时间，按 `k` 切换看板小猫，按 `c` 调整显示的 CPU 核心数，按 `q` 退出，设置会自动保存。

<details>
<summary><strong>JSON、NDJSON 与进程告警</strong></summary>

- `mo analyze --json ~/Documents`：单次输出指定路径的磁盘分析 JSON
- `mo status --json`：单次输出系统状态快照 JSON
- `mo status | jq '.health_score'`：当输出被管道重定向时自动切换为 JSON 模式
- `mo status --watch --interval 2s`：持续流式输出 NDJSON（换行分隔的 JSON）
- `mo history --json`：以 JSON 格式输出历史清理日志。每个会话带有 `run_id`（不透明字符串，没有记录身份时为空）和 `attribution`，能识别的运行是 `run`，旧版按命令分组的是 `command`，旧标记分不清中断和重叠运行时是 `ambiguous`。记录下来的操作仍然都能看到，但 `ambiguous` 的计数没法可靠地分到单次运行上。`ended_at` 为空表示没有记录到结束标记。

```text
$ mo status --json
{
  "host": "MacBook-Pro",
  "health_score": 92,
  "cpu": { "usage": 45.2, "logical_cpu": 8 },
  "memory": { "total": 34359738368, "used": 20078972109, "used_percent": 58.4 },
  "disks": [],
  "process_collected_at": "2026-08-29T12:30:00Z",
  "process_stale": false,
  "zombie_count": 3,
  "zombie_parents": [
    { "pid": 4242, "name": "Google Chrome for Testing", "count": 3 }
  ],
  "zombie_parents_complete": true,
  "uptime": "3d 12h 45m"
}
```

僵尸进程诊断是只读的，不会结束进程，也不影响健康分。Mole 还没成功拿到一次进程样本时，`process_collected_at`、`process_stale`、`zombie_count` 和 `zombie_parents_complete` 都不会出现，`zombie_parents` 为 `null`。之后的 fast/watch 快照会沿用最近一次成功的样本，保留它原来的 `process_collected_at` 并设 `process_stale: true`，拿到新的进程样本后变回 `false`。`0` 表示 Mole 实际测过，没有僵尸进程。父进程摘要最多列出三个已知的父进程，`zombie_parents_complete: false` 表示归属信息拿不到、不完整或被截断。

如果某个指标采集出错，`mo status --json` 仍会输出其他可用指标，将错误记录在 stderr 中并退出 0，`--watch` 也是这样继续输出，只有 CPU、内存、磁盘和进程指标全都拿不到，或者 JSON 输出失败时才退出 1。

支持对持续高 CPU 占用的进程进行提示，可通过 `--proc-cpu-threshold`、`--proc-cpu-window` 或 `--proc-cpu-alerts=false` 进行调整或关闭。

</details>

### 项目清理（Purge）

`mo purge` 自动查找可随时重新构建的项目生成目录（如 `node_modules`、`target`、`.build`、`build` 与 `dist`）。按项目归类展示，只永久删除你勾选确认的产物，不经过废纸篓，最近 7 天内有改动或无法确认改动时间的产物默认不勾选。扫描优先用 `fd`，没有时回退到 `find`，包含部署密钥、嵌套 Git 仓库或 Git 追踪文件的目录会受保护，非交互式运行需加 `--yes`，可先用 `mo purge --dry-run` 预览候选目录。

使用 Page Up/Down 或 `h`/`l` 翻页，`[`/`]` 在项目间跳转，`X` 跳过当前项目并前进到下一个，`/` 搜索项目路径与产物名称，`n` 跳到下一个匹配且不改变已选项，回车打开最终路径确认界面。显示的空间是估算值，没测出大小的产物和不完整的扫描会单独标明。

<details>
<summary><strong>Purge 示例输出</strong></summary>

```text
$ mo purge

Purge Project Artifacts

Select Artifacts to Purge
6.00GB, 2 selected

➤ ● ┌ ~/Projects/website        3.80GB | node_modules | 28d
  ○ └ ~/Projects/website         186MB | dist         | <1d
  ● ┌ ~/Projects/rust-app       2.20GB | target       | 2mo
  ○ └ ~/Projects/rust-app         22MB | dist         | <7d

======================================================================
Purge complete
Estimated space freed: 6.00GB | Items: 2 | Free: 223.5GB
======================================================================
```

</details>

<details>
<summary><strong>自定义扫描路径</strong></summary>

运行 `mo purge --paths` 配置扫描目录，或直接编辑 `~/.config/mole/purge_paths`：

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

配置了自定义路径就只扫描这些目录，没配置时用默认目录（如 `~/Projects`、`~/GitHub`、`~/dev` 以及受支持的 agent worktree 目录），扫描中途得到的不完整结果不会保存。产物扫描深度为配置根目录下 6 层，更深的项目可以加一个更近的根目录，Purge 只删除 worktree 里可重建的产物，不会删除 worktree 目录本身。

</details>

### 安装包清理（Installer）

`mo installer` 自动查找下载目录、桌面、Homebrew 缓存、iCloud、Mail、Telegram 等受支持位置中的 DMG、PKG、MPKG、ISO、XIP 与安装器 ZIP 文件，清理前列出各文件大小与来源。扫描有总时长上限，出错或超时就直接放弃，不在不完整的数据上操作，损坏或无法读取的 ZIP 压缩包会跳过，扫描根目录可以是符号链接，但不会跟随它下面的符号链接，最终删除前还会再校验一次，确保文件未发生变动。

<details>
<summary><strong>Installer 示例输出</strong></summary>

```text
$ mo installer

Select Installers to Remove, 3.83GB, 5 selected

➤ ● Photoshop_2024.dmg          1.20GB | Downloads
  ● IntelliJ_IDEA.dmg          850.6MB | Downloads
  ● Illustrator_Setup.pkg      920.4MB | Downloads
  ● PyCharm_Pro.dmg            640.5MB | Homebrew
  ● Acrobat_Reader.dmg         220.4MB | Downloads
  ○ AppCode_Legacy.zip         410.6MB | Downloads

======================================================================
Installers cleaned
Removed 5 installers, freed 3.83GB
======================================================================
```

</details>

## 快捷启动器

<details>
<summary><strong>Raycast 与 Alfred 配置</strong></summary>

安装快捷启动器（Clean、Uninstall、Optimize、Analyze 与 Status）：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

该脚本会自动添加 Raycast 命令；若检测到 Alfred 配置，还会同步添加带有 `clean`、`uninstall`、`optimize`、`analyze` 与 `status` 关键词的 Alfred Workflow。

Raycast 安装后需一次性手动设置：

1. 打开 **Raycast 设置 > Extensions > Script Commands**。
2. 添加 `~/Library/Application Support/Raycast/script-commands` 目录。
3. 在 Raycast 中点击 **Reload Script Directories**。

启动器会自动适配常见终端（Terminal、iTerm2、Alacritty、kitty、WezTerm、Ghostty、Hyper、WindTerm、Warp）。可通过 `MO_LAUNCHER_APP=<名称>` 指定终端，也可以直接在 [Kaku](https://github.com/tw93/Kaku) 中运行。

</details>

## 社区反馈

感谢所有参与 Mole 开发与维护的贡献者，去关注一下他们吧 ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole 贡献者" width="1000" />
</a>

<br/><br/>
来自 X (Twitter) 用户的真实使用反馈：

<img src="./docs/img/mole-love.png" alt="社区反馈" width="1000" />

观看 PAPAYA 電腦教室 制作的 [Mole 教学视频](https://www.youtube.com/watch?v=UEe9-w4CcQ0)。

## 支持项目

- 购买 [Mole for Mac](https://mole.fit) 是支持 Mole 持续开发最直接的方式
- 如果 Mole 帮到了你，欢迎点个 Star、[分享给朋友](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.)，或在 GitHub 提交 Issue 和 PR
- 我养了两只猫，汤圆和可乐，如果 Mole 用着顺手，欢迎投喂她们一顿 <a href="https://cats.tw93.fun?name=Mole" target="_blank">罐头 🥩</a>

<details>
<summary>已经投喂的好心人 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="赞助者" width="1000" loading="lazy" /></a>
</details>

## 开源协议

Mole 基于 GPL-3.0 协议开源（详见 [LICENSE](LICENSE)），任何修改与分发的版本需要保持相同的开源协议，如果你将 Mole 分叉为其他独立产品，请使用不同名称并注明出处。[Mole for Mac](https://mole.fit) 是独立的闭源 App，Mole 会长期维护下去。
