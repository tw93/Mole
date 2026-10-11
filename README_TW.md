<div align="center">
  <h1>Mole</h1>
  <p><b>Mac 深度清理、應用程式解除安裝、系統最佳化、磁碟分析與狀態監控，免費開源命令列工具，另有原生 Mac App</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · 繁體 · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Mole 清理成果" width="1000" />
</p>

> 💡 這個倉庫是免費開源的命令列工具（`mo`），喜歡圖形介面的話可以另外下載 [Mole for Mac](https://mole.fit/)，支援刪除前逐項確認、實測 800 多款軟體的解除安裝殘留、系統維護、逐層分析磁碟空間、即時狀態監控，以及在支援的 Mac 上控制風扇，`brew install mole` 只會安裝命令列工具。

## 功能

- **多合一命令列**：把 CleanMyMac、AppCleaner、DaisyDisk 與 iStat Menus 的日常用法放進一個終端機指令
- **深度清理**：清除系統快取、應用程式日誌與解除安裝殘留，釋放磁碟空間
- **應用程式解除安裝**：移除應用程式，同步清理偏好設定與自啟動項目
- **磁碟分析**：終端機互動式瀏覽目錄層級，定位佔用空間的大檔案
- **系統最佳化**：重新整理 DNS、QuickLook 與圖示快取，最佳化系統資料庫
- **即時監控**：在終端機儀表板中即時查看 CPU、記憶體、磁碟讀寫、網路流量與行程

## 快速開始

Mole 支援 macOS 12 及更高版本，相容 Intel 與 Apple Silicon 晶片，Homebrew 不再支援你的 macOS 版本時改用指令碼安裝，實驗性的 Windows 版本在 [windows 分支](https://github.com/tw93/Mole/tree/windows)。

**透過 Homebrew 安裝**

```bash
brew install mole
```

**透過指令碼安裝**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**常用指令**

```bash
mo                           # 開啟互動式選單
mo clean                     # 深度清理與已移除應用程式殘留
mo uninstall                 # 解除安裝應用程式及其殘留
mo optimize                  # 重新整理系統快取與服務
mo analyze                   # 磁碟空間瀏覽（也可寫 mo analyse）
mo status                    # 即時系統健康儀表板
mo purge                     # 清理專案建置產物
mo installer                 # 尋找並刪除安裝檔

mo touchid                   # 設定終端機 Touch ID 指紋認證
mo completion                # 設定命令列 Tab 鍵自動補全
mo update                    # 檢查並更新 Mole
mo update --nightly          # 更新到最新未釋出的開發版（僅限指令碼安裝）
mo remove                    # 從系統中完全移除 Mole
mo --help                    # 查看說明資訊
mo --version                 # 查看已安裝版本
```

**安全預覽**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 安全預覽 + 詳細診斷日誌
mo optimize --whitelist      # 管理受保護的最佳化規則
mo clean --whitelist         # 管理受保護的快取白名單
mo purge --paths             # 設定程式碼專案掃描目錄
mo analyze /Volumes          # 僅分析外接行動硬碟或磁碟卷宗
mo analyze /private/tmp      # 僅檢視暫存目錄（不自動清理）
```

<details>
<summary><strong>其他安裝選項</strong></summary>

想裝特定版本就傳入 [Releases 頁面](https://github.com/tw93/mole/releases) 裡的任意 Tag，帶不帶開頭的 `V` 都行，想跟開發分支就傳 `main`：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` 會安裝預設分支上還沒釋出的程式碼，可能不穩定，`latest` 只是 `main` 的舊別名，並不會安裝最新穩定版。

安裝指令碼預設裝到 `/usr/local/bin`，可能需要輸入管理員密碼。希望以後的 `mo update` 不用輸密碼，可以裝到使用者目錄：

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

記得把 `export PATH` 加到 `~/.zshrc` 或對應的 shell 設定檔中。Mole 更新的是你執行的那份安裝，之後會一直用這個目錄，需要改系統檔案的指令仍可能要管理員權限。

**Nix**

在 macOS 上，Nix 使用者可從 `main` 分支安裝 flake，其中包含還沒釋出的改動：

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

宣告式配置可以把 `github:tw93/mole/main` 加為 flake input，用它的 `packages.${system}.mole` 套件。Nix 管理的安裝要透過 Nix 升級和移除，`mo update` 和 `mo remove` 不會改動它。

</details>

## 安全機制

Mole 會刪除檔案，所以會先檢查路徑、保護共用和系統目錄，需要時才請你確認，無法確認安全的項目一律略過或拒絕。

- `clean`、`uninstall`、`purge`、`installer` 與 `remove` 會刪除檔案，可先用 `--dry-run` 預覽，需要時加上 `--debug`
- 日常執行 **無需 `sudo`**，僅在觸及系統級清理時按需請求管理員權限
- `mo analyze` 中的刪除操作在確認後預設放入 macOS 垃圾桶
- 清理操作記錄在 `~/Library/Logs/mole/operations.log` 中，可透過 `mo history` 查看，或設定 `MO_NO_OPLOG=1` 停用
- 可透過 `mo clean --whitelist` 保護指定快取，或使用 `mo optimize --whitelist` 排除維護項目

漏洞回報方式、安全邊界與目前限制見 [SECURITY.md](SECURITY.md) 與 [SECURITY_AUDIT.md](SECURITY_AUDIT.md)。

## 功能說明

以下展示為縮減範例，具體顯示項目、大小與略過原因取決於你的 Mac 實際環境。

### 深度清理（Clean）

`mo clean` 掃描並清理已知可安全刪除的快取、日誌、暫存檔案、開發者工具快取以及已移除應用程式的殘留檔案，預設會清空垃圾桶，想保留就在 `mo clean --whitelist` 裡勾選 Trash，同一個選單也用來保護想留下的快取。選好的項目會寫進 `~/.config/mole/whitelist`，想加自訂路徑時先打開選單按 Enter 儲存一次，再往檔案裡每行追加一個路徑，檔案一旦存在就會取代可選的預設規則，內建安全保護仍然生效。

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

### 應用程式解除安裝（Uninstall）

`mo uninstall` 移除已安裝的應用程式，以及 Mole 能確認屬於這個應用程式的相關檔案，若同一應用程式的另一個已安裝副本仍在使用這些檔案，會自動保留；應用程式此前已被手動刪除的話，執行 `mo clean` 掃描殘留。

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

### 系統最佳化（Optimize）

`mo optimize` 對支援的 Finder、網路、資料庫與 macOS 服務執行範圍明確的維護，非必要、目前執行不安全或無法使用的任務會略過並說明原因。可用 `mo optimize --whitelist` 排除任務或路徑模式，例如常駐掛載的 `/Volumes/mail`，避免它出現在退出列表裡。

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

### 磁碟分析（Analyze）

`mo analyze` 開啟終端機互動式磁碟分析器，支援方向鍵與 Vim 快捷鍵瀏覽、快速過濾、多選標記、Finder 預覽與放入垃圾桶。外接磁碟預設不在概覽中顯示，可執行 `mo analyze /Volumes` 或指定掛載路徑單獨檢視，`mo analyze /private/tmp` 只檢查暫存目錄，不會把它們變成自動清理目標。

以 `+` 結尾的大小是部分掃描裡實際測到的位元組數，`unknown` 表示無法測出大小。因臨時逾時中斷的項目不會覆蓋已有完整快取，後續重新整理可自動補全。macOS 不允許終端機讀取的資料夾會一直標為部分掃描，直到存取權限改變。終端機介面只列出最大的 30 個項目，讀不到的項目可能不在這 30 項裡，但總量仍會標為部分掃描，JSON 格式輸出則包含所有掃描項目。

`mo analyze --json /path` 的結果本身和其中每一項都帶有 `scan_status`（`complete`、`partial` 或 `unavailable`）。數值大小是實際測到的位元組數，`unavailable` 時的 0 也不代表目錄為空。未完成的掃描仍以結束碼 0 結束，指令碼要看 `scan_status` 判斷結果是否完整。完整性以 Mole 現有的掃描排除規則為界，不保證是檔案系統的原子快照。

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

### 狀態監控（Status）

`mo status` 提供唯讀系統硬體儀表板，涵蓋 CPU、系統負載、磁碟讀寫、網路流量、電源與行程。

當預設 IPv4 路由走 VPN 或通道介面時，流量圖表會統計這個介面，避免和實體網卡重複計算。JSON 輸出保留每個介面的速率，包括路由經過的通道，閒置的非預設通道不顯示。

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

健康評分綜合了 CPU、記憶體、磁碟餘量、SMART 狀態、I/O 讀寫、溫度、電池狀況與開機時間，按 `k` 切換儀表板小貓，按 `c` 調整顯示的 CPU 核心數，按 `q` 結束，偏好設定會自動儲存。

<details>
<summary><strong>JSON、NDJSON 與行程警示</strong></summary>

- `mo analyze --json ~/Documents`：單次輸出指定路徑的磁碟分析 JSON
- `mo status --json`：單次輸出系統狀態快照 JSON
- `mo status | jq '.health_score'`：當輸出被管線重定向時自動切換為 JSON 模式
- `mo status --watch --interval 2s`：持續串流輸出 NDJSON（換行分隔的 JSON）
- `mo history --json`：以 JSON 格式輸出歷史清理日誌。每個工作階段帶有 `run_id`（不透明字串，沒有記錄身分時為空）和 `attribution`，能識別的執行是 `run`，舊版按指令分組的是 `command`，舊標記分不清中斷和重疊執行時是 `ambiguous`。記錄下來的操作仍然都能看到，但 `ambiguous` 的計數沒辦法可靠地分到單次執行上。`ended_at` 為空表示沒有記錄到結束標記

```text
$ mo analyze --json ~/Documents
{
  "path": "/Users/you/Documents",
  "overview": false,
  "entries": [
    { "name": "Library", "path": "...", "size": 80939438080, "is_dir": true }
  ],
  "large_files": [
    { "name": "backup.zip", "path": "...", "size": 8796093022 }
  ],
  "total_size": 168393441280,
  "total_files": 42187
}

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

殭屍行程診斷是唯讀的，不會終止行程，也不影響健康分。Mole 還沒成功拿到一次行程樣本時，`process_collected_at`、`process_stale`、`zombie_count` 和 `zombie_parents_complete` 都不會出現，`zombie_parents` 為 `null`。之後的 fast/watch 快照會沿用最近一次成功的樣本，保留它原來的 `process_collected_at` 並設 `process_stale: true`，拿到新的行程樣本後變回 `false`。`0` 表示 Mole 實際測過，沒有殭屍行程。父行程摘要最多列出三個已知的父行程，`zombie_parents_complete: false` 表示歸屬資訊拿不到、不完整或被截斷。

如果某個指標收集出錯，`mo status --json` 仍會輸出其他可用指標，將錯誤記錄在 stderr 中並以結束碼 0 結束，`--watch` 也是這樣繼續輸出，只有 CPU、記憶體、磁碟和行程指標全都拿不到，或者 JSON 輸出失敗時才以結束碼 1 結束。

持續高 CPU 的行程會有提示，用 `--proc-cpu-threshold`、`--proc-cpu-window` 或 `--proc-cpu-alerts=false` 調整或關閉。

</details>

### 專案清理（Purge）

`mo purge` 自動尋找可隨時重新建置的專案生成目錄，例如 `node_modules`、`target`、`.build`、`build` 與 `dist`。按專案歸類呈現，只永久刪除你勾選確認的項目，不經過垃圾桶，最近 7 天內有改動或無法確認改動時間的產物預設不勾選。掃描優先用 `fd`，沒有時降級到 `find`，包含部署金鑰、巢狀 Git 倉庫或 Git 追蹤檔案的目錄會受到保護，非互動式執行需使用 `mo purge --yes`，可先用 `mo purge --dry-run` 預覽候選目錄。

使用 Page Up/Down 或 `h`/`l` 翻頁，`[`/`]` 在專案間跳轉，`X` 略過目前專案並前往下一個，`/` 搜尋專案路徑與產物名稱，`n` 跳到下一個符合項目且不改變已選項目，按 Enter 開啟最終路徑確認畫面。顯示的空間是估算值，沒測出大小的產物和不完整的掃描會另外標明。

<details>
<summary><strong>Purge 範例輸出</strong></summary>

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
<summary><strong>自訂掃描路徑</strong></summary>

執行 `mo purge --paths` 設定掃描目錄，或直接編輯 `~/.config/mole/purge_paths`：

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

設定了自訂路徑就只掃描這些目錄，沒設定時用預設目錄（如 `~/Projects`、`~/GitHub`、`~/dev` 以及支援的 agent worktree 目錄），掃描中途得到的不完整結果不會儲存。產物掃描深度為設定根目錄下 6 層，更深的專案可以加一個更近的根目錄，Purge 只刪除 worktree 裡可重新建置的產物，不會刪除 worktree 目錄本身。

</details>

### 安裝檔清理（Installer）

`mo installer` 自動尋找下載目錄、桌面、Homebrew 快取、iCloud、Mail、Telegram 及其他支援位置中的 DMG、PKG、MPKG、ISO、XIP 與安裝檔 ZIP，清理前會列出各檔案大小與來源。掃描有總時長上限，出錯或逾時就直接放棄，不在不完整的資料上操作，損壞或無法讀取的 ZIP 壓縮檔會略過，掃描根目錄可以是符號連結，但不會跟隨它底下的符號連結，最終刪除前還會再驗證一次，確保檔案未發生變動。

<details>
<summary><strong>Installer 範例輸出</strong></summary>

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

## 快捷啟動器

<details>
<summary><strong>Raycast 與 Alfred 設定</strong></summary>

安裝快捷啟動器（Clean、Uninstall、Optimize、Analyze 與 Status）：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

指令碼會新增 Raycast 指令，偵測到 Alfred 設定時還會新增帶有 `clean`、`uninstall`、`optimize`、`analyze` 與 `status` 關鍵字的 Alfred Workflow。

Raycast 裝好後要手動設定一次：

1. 開啟 **Raycast 設定 > Extensions > Script Commands**。
2. 新增 `~/Library/Application Support/Raycast/script-commands` 目錄。
3. 在 Raycast 中點選 **Reload Script Directories**。

啟動器會自動適配常見終端機（Terminal、iTerm2、Alacritty、kitty、WezTerm、Ghostty、Hyper、WindTerm、Warp）。可透過 `MO_LAUNCHER_APP=<名稱>` 指定終端機，也可以直接在 [Kaku](https://github.com/tw93/Kaku) 中執行。

</details>

## 社群回饋

感謝所有參與 Mole 開發與維護的貢獻者，去追蹤一下他們吧 ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole 貢獻者" width="1000" />
</a>

<br/><br/>
來自 X (Twitter) 使用者的真實回饋：

<img src="./docs/img/mole-love.png" alt="社群回饋" width="1000" />

觀看 PAPAYA 電腦教室 製作的 [Mole 教學影片](https://www.youtube.com/watch?v=UEe9-w4CcQ0)。

## 支持專案

- 購買 [Mole for Mac](https://mole.fit) 是支持 Mole 持續開發最直接的方式
- 如果 Mole 幫到了你，歡迎給予 Star、[分享給朋友](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.)，或在 GitHub 提交 Issue 和 PR
- 我養了兩隻貓，湯圓和可樂，如果 Mole 用著順手，歡迎請她們吃一頓 <a href="https://cats.tw93.fun?name=Mole" target="_blank">罐頭 🥩</a>

<details>
<summary>已經請客的好心人 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="贊助者" width="1000" loading="lazy" /></a>
</details>

## 開源授權條款

Mole 基於 GPL-3.0 條款開源（詳見 [LICENSE](LICENSE)），任何修改與發布的版本需要保持相同的開源授權條款，如果你將 Mole 分叉為其他獨立產品，請使用不同名稱並註明出處。[Mole for Mac](https://mole.fit) 是獨立的閉源 App，Mole 會長期維護下去。
