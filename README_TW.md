<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <img src="./docs/img/mole-logo.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Windows</h1>
  <p><b>Windows 電腦深度清理、應用程式解除安裝、系統最佳化、磁碟分析與狀態監控，免費開源命令列</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · 繁體 · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Mole CLI for Windows 選單介面" width="1000" />
</p>

> 💡 這個分支是免費開源的 Windows 命令列工具（`mo`），喜歡圖形介面的話可以單獨下載 [Mole for Windows](https://mole.fit/tw/windows)，支援刪除前逐項確認、應用程式更新、啟動項目管理、逐層分析磁碟空間與即時狀態監控，macOS 命令列在 [main 分支](https://github.com/tw93/Mole#readme)。

## 功能

- **多合一命令列**：把 CCleaner、IObit Uninstaller、WinDirStat 與工作管理員的日常用法放進一個終端機指令
- **深度清理**：清除暫存檔案、快取、日誌與瀏覽器殘留，釋放磁碟空間
- **應用程式解除安裝**：移除應用程式，同時清理它留下的安裝資料夾
- **磁碟分析**：在終端機裡互動式瀏覽磁碟佔用，找出大檔案
- **系統維護**：重新整理 DNS、最佳化系統盤並檢查磁碟健康
- **即時監控**：即時檢視 CPU、記憶體、磁碟、網路與行程狀態

## 快速開始

Mole 支援 Windows 10 和 11，使用系統自帶的 Windows PowerShell 5.1 即可執行，指令碼安裝需要 Git，原始碼和最新發布版不一致時還需要 Go 來建置原生工具，會安裝到 `%LOCALAPPDATA%\Programs\mole-cli`，並把 `mo` 和 `mole` 加入 PATH。

**透過 Scoop 安裝**

```powershell
scoop install mole
```

**或透過指令碼安裝**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole 只透過這個 GitHub 倉庫、Scoop 和 Windows 版官網 [mole.fit](https://mole.fit/tw/windows) 發布，自稱基於 Mole 的其他 App，或者讓你往終端機裡貼上一段編碼指令的網站，都和 Mole 無關。

**用 AI Agent 安裝**

直接告訴你的 Agent：

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

也可以自己裝 skill，裝上後 Claude Code、Codex、Cursor 等 Agent 刪除前會先用 `--dry-run` 把清單給你看，解除安裝 App 與需要管理員權限的步驟留給你自己執行，更新用 `npx skills update -g -y`。

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

習慣用宿主內建的外掛管理，Claude Code 裡先 `/plugin marketplace add tw93/Mole` 再 `/plugin install mole@mole`，Codex 裡先 `codex plugin marketplace add tw93/Mole` 再 `codex plugin add mole@mole`，DeepSeek Harness 裡用 `dsh plugin --profile <name> add dsh-mole`。

**常用指令**

```powershell
mo                           # 開啟互動式選單
mo clean                     # 深度清理
mo uninstall                 # 解除安裝應用及其殘留
mo optimize                  # 重新整理快取與服務
mo analyze                   # 磁碟空間瀏覽
mo status                    # 即時系統健康儀表板
mo purge                     # 清理專案建置產物
mo installer                 # 尋找並刪除安裝檔

mo update                    # 檢查並更新 Mole
mo remove                    # 從這台電腦上完全解除安裝 Mole
mo --help                    # 檢視幫助資訊
mo --version                 # 檢視已安裝版本
```

**安全預覽**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo remove --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 安全預覽 + 詳細診斷日誌
mo clean --whitelist         # 管理受保護的路徑
mo clean --system            # 包含系統級清理（需以管理員身份執行）
mo purge --paths             # 設定專案掃描資料夾
mo analyze D:\               # 分析另一塊磁碟
mo uninstall --list          # 列出已安裝的應用程式，透過管線輸出時為 JSON
mo analyze --json D:\        # 以 JSON 輸出磁碟分析
```

<details>
<summary><strong>其他安裝選項</strong></summary>

想先看程式碼再安裝的話，複製 `windows` 分支並在原地執行安裝指令碼，它會保留 `.git`，之後 `mo update` 照常可用：

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

加上 `-CreateShortcut` 會建立開始選單入口，解除安裝時執行 `mo remove`。

</details>

## 安全機制

Mole 會刪除檔案，所以會先校驗路徑、保護系統和使用者設定資料夾，`uninstall`、`purge`、`installer` 與 `remove` 刪除前都會請你確認，無法確認安全的項目一律跳過。

- `clean`、`uninstall` 與 `purge` 會刪除檔案，可先用 `--dry-run` 預覽，需要時加上 `--debug`
- `clean` 與 `purge` 是永久刪除，已核實的 `uninstall` 殘留會放進資源回收筒，應用程式自身的解除安裝程式保留其原有行為，`mo analyze` 中刪除的檔案也會放進資源回收筒，放不進資源回收筒的大項目 Windows 會先詢問是否永久刪除
- 用普通使用者身份執行 Mole 即可，系統級步驟只有以管理員身份執行 PowerShell 時才會執行，否則跳過
- 可透過 `mo clean --whitelist` 保護指定路徑
- 清理操作記錄在 `%USERPROFILE%\.config\mole\operations.log` 中，可透過 `mo history` 查看，或設定 `MO_NO_OPLOG=1` 停用
- `C:\Windows`、`C:\Program Files`、Windows Defender 資料夾和使用者設定根資料夾永遠不會被觸碰

漏洞回報方式與安全邊界見 [SECURITY.md](SECURITY.md)。

## 功能說明

以下截圖來自一台測試電腦，具體顯示項與大小取決於你的電腦實際環境。

### 深度清理（Clean）

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="mo clean --dry-run 預覽" width="736" />

詳細清單裡是預覽找到的每一個路徑，想保留哪個，就把它複製進白名單。

### 應用程式解除安裝（Uninstall）

```powershell
mo uninstall
```

從登錄檔和 Windows 應用程式中列出已安裝的程式，按佔用從大到小排序，選取的軟體會用它自己的解除安裝程式移除，再清理遺留的安裝資料夾，`mo uninstall --dry-run` 會顯示每個軟體將使用哪個解除安裝程式、會移除什麼，但不會執行任何東西。

<img src="./docs/img/uninstall-windows.png" alt="mo uninstall 應用程式清單" width="1000" />

### 系統最佳化（Optimize）

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="mo optimize --dry-run 預覽" width="736" />

磁碟最佳化、重新整理 ARP 快取這類步驟需要管理員權限，否則會跳過，想包含它們就以管理員身份執行 PowerShell。

### 磁碟分析（Analyze）

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="mo analyze 概覽" width="1000" />

互動式磁碟瀏覽器，版面配置和 macOS 版一致，方向鍵在資料夾間移動，`Backspace` 返回，`T` 列出最大的檔案，`Del` 在確認後把選取的項目放進資源回收筒。

### 狀態監控（Status）

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="mo status 儀表板" width="1000" />

即時儀表板，包含健康評分、CPU、記憶體、磁碟、電源、網路和最忙碌的行程。

### 專案清理（Purge）

```powershell
mo purge --dry-run
```

在你的專案資料夾裡找出建置產物（`node_modules`、`target`、`build`、`dist`、`venv` 等），由你挑選要清理的專案，選擇之前什麼都不會勾選，掃描的資料夾可以用 `mo purge --paths` 設定。

### 安裝檔清理（Installer）

```powershell
mo installer --dry-run
```

在下載資料夾裡找出放了 14 天以上的 Windows 安裝檔（`.msi`），由你挑選要移到資源回收筒的檔案，選擇之前什麼都不會勾選，只列出內容確實是安裝檔的檔案，仍在開啟中的檔案會略過。

## 社群回饋

感謝所有參與 Mole 開發與維護的貢獻者，去關注一下他們吧 ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole 貢獻者" width="1000" />
</a>

## 支持專案

- 購買 [Mole for Windows](https://mole.fit/tw/windows) 是支持 Mole 持續開發最直接的方式
- 如果 Mole 幫到了你，歡迎點個 Star、[分享給朋友](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.)，或在 GitHub 提交 Issue 和 PR
- 歡迎參與貢獻，先看一下 [CONTRIBUTING.md](CONTRIBUTING.md)
- 我養了兩隻貓，湯圓和可樂，如果 Mole 用著順手，歡迎請她們吃一頓 <a href="https://cats.tw93.fun?name=Mole" target="_blank">罐頭 🥩</a>

## 開源授權條款

Mole 基於 GPL-3.0 條款開源（詳見 [LICENSE](LICENSE)），任何修改與發布的版本需要保持相同的開源授權條款，如果你將 Mole 分叉為其他獨立產品，請使用不同名稱並註明出處，詳見 [TRADEMARK.md](TRADEMARK.md)。
