<div align="center">
  <h1>Mole</h1>
  <p><b>Macのディープクリーン、アプリアンインストール、システム最適化、ディスク分析、ステータス監視。無料のオープンソースCLIと、ネイティブMacアプリ。</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · 日本語 · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Mole クリーンアップ結果" width="1000" />
</p>

> 💡 このリポジトリは無料のオープンソースCLI（`mo`）です。ネイティブアプリがよければ、[Mole for Mac](https://mole.fit/) を別途ダウンロードできます。削除前の項目別確認、800以上のアプリで検証済みの残留ファイル削除、メンテナンス、ディスクの階層分析、リアルタイムのステータス表示、対応Macでのファン制御を備えています。`brew install mole` でインストールされるのはCLIのみです。

## 機能

- **オールインワンCLIツール**：CleanMyMac、AppCleaner、DaisyDisk、iStat Menus風のワークフローをひとつのターミナルコマンドに集約
- **ディープクリーン**：キャッシュ、ログ、一時ファイル、アンインストール残留物を削除して空き容量を確保
- **スマートアンインストーラ**：アプリ本体とLaunchAgents、設定ファイル、関連残留物をまとめて削除
- **ディスク分析**：インタラクティブTUIで容量内訳を可視化し、大容量ファイルを探索
- **システム最適化**：DNSキャッシュのフラッシュ、QuickLook・アイコンキャッシュの再構築、システムデータベースの最適化
- **リアルタイム監視**：CPU、メモリ、ディスクI/O、ネットワーク通信量、プロセス状態をターミナルで確認

## クイックスタート

MoleはmacOS 12以降に対応し、IntelおよびApple Silicon Macの双方をサポートします。お使いのmacOSでHomebrewが利用できない場合はスクリプトでインストールしてください。実験的なWindows版は [windowsブランチ](https://github.com/tw93/Mole/tree/windows) にあります。

**Homebrewでインストール**

```bash
brew install mole
```

**スクリプトでインストール**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**主要コマンド**

```bash
mo                           # インタラクティブメニューを開く
mo clean                     # ディープクリーン：システムキャッシュ、ログ、削除済みアプリの残留ファイル削除
mo uninstall                 # アプリ削除：インストール済みアプリと関連設定ファイルの完全アンインストール
mo optimize                  # システム最適化：システムサービスとキャッシュのリフレッシュ
mo analyze                   # ディスク分析：ディスク容量の内訳確認と大容量ファイルの探索
mo status                    # 状態監視：CPU、メモリ、ネットワーク、ハードウェアの健康度ダッシュボード
mo purge                     # プロジェクトクリーン：ビルド生成物（node_modules、targetなど）の整理
mo installer                 # インストーラ整理：インストーラファイルの探索と削除

mo touchid                   # ターミナルsudo用Touch ID認証の設定
mo completion                # シェル補完の設定
mo update                    # Moleの更新を確認・実行
mo update --nightly          # 未リリースの最新開発版に更新（スクリプトインストール環境のみ）
mo remove                    # システムからMoleを完全削除
mo --help                    # ヘルプを表示
mo --version                 # インストール済みバージョンを表示
```

**安全プレビュー（Dry Run）**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 安全プレビュー + 詳細ログ
mo optimize --whitelist      # 保護する最適化ルールの管理
mo clean --whitelist         # 保護するキャッシュホワイトリストの管理
mo purge --paths             # プロジェクト検索ディレクトリの設定
mo analyze /Volumes          # 外付けドライブのみ分析
mo analyze /private/tmp      # 一時ディレクトリの確認（自動削除なし）
```

<details>
<summary><strong>その他のインストールオプション</strong></summary>

特定バージョンをインストールする場合は、[Releasesページ](https://github.com/tw93/mole/releases) のタグを指定してください（先頭の `V` はあってもなくても構いません）。開発ブランチを利用する場合は `main` を指定します：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` はデフォルトブランチの未リリースのコードをインストールするため、不安定な部分があるかもしれません。`latest` は `main` の旧エイリアスとして残っており、名前に反して最新の安定版はインストールしません。

スクリプトは通常 `/usr/local/bin` にインストールされ、管理者パスワードが求められる場合があります。パスワード入力なしで `mo update` を実行したい場合は、ユーザーディレクトリにインストールしてください：

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

新しいターミナルでも使えるように、同じ `PATH` の設定を `~/.zshrc` などのシェル設定ファイルにも追加してください。Moleは実行したインストールを更新するので、以後もこのディレクトリが使われます。システム所有のファイルを変更するコマンドは、引き続き管理者権限を求めることがあります。

**Nix**

macOS環境のNixユーザーは、未リリースの変更を含む `main` ブランチからflakeを直接インストールできます：

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

宣言的に構成する場合は、`github:tw93/mole/main` をflake inputとして追加し、`packages.${system}.mole` パッケージを使用してください。更新と削除はNixで行います。`mo update` と `mo remove` はNixで管理されたインストールを変更しません。

</details>

## 安全性

Moleはファイルを削除できるため、パスを検証し、共有の場所やシステム所有の場所を保護し、必要な操作では確認を求めます。安全に変更できると確認できない項目は、スキップするか処理を拒否します。

- `clean`、`uninstall`、`purge`、`installer`、`remove` はファイル削除を伴うため、事前に `--dry-run` で確認し、必要に応じて `--debug` を併用してください
- 通常利用では **`sudo` 不要** で、システム領域のクリーン時のみ必要に応じて管理者権限を要求します
- `mo analyze` で選択した項目は、確認後にmacOSのゴミ箱へ移動されます
- クリーンアップ履歴は `~/Library/Logs/mole/operations.log` に記録され、`mo history` で確認するか、`MO_NO_OPLOG=1` で無効化できます
- `mo clean --whitelist` で保持したいキャッシュを保護し、`mo optimize --whitelist` で除外項目を設定できます

脆弱性の報告方法、安全上の境界、現在の制限は [SECURITY.md](SECURITY.md) および [SECURITY_AUDIT.md](SECURITY_AUDIT.md) をご覧ください。

## 機能詳細

以下の表示例は抜粋です。実際の表示項目、容量、スキップ理由はご利用のMac環境によって異なります。

### ディープクリーン（Clean）

`mo clean` は安全なキャッシュ、ログ、一時ファイル、開発ツールキャッシュ、アンインストール済みアプリの残留物を探索して削除します。既定でゴミ箱を空にするので、残したい場合は `mo clean --whitelist` で Trash を選択してください。同じメニューで保持したいキャッシュも保護でき、選択内容は `~/.config/mole/whitelist` に保存されます。独自のパスを追加する前に、メニューを開いてEnterで選択内容を保存し、そのあと1行に1パスずつ追記してください。ファイルが存在するとオプションの標準ルールは置き換えられますが、組み込みの安全保護は引き続き有効です。

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

### アプリアンインストール（Uninstall）

`mo uninstall` はインストール済みアプリと、Moleがそのアプリのものだと特定できる関連ファイルを削除します。同じアプリの別のインストールがまだ使っている共有ファイルは保持されます。アプリがすでに削除済みの場合は、`mo clean` で残留ファイルを探せます。

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

### システム最適化（Optimize）

`mo optimize` は対応するFinder、ネットワーク、データベース、macOSサービスに対して、範囲を限定したメンテナンスを実行します。不要な処理、その時点では安全に実行できない処理、利用できない処理は理由とともにスキップされます。`mo optimize --whitelist` でタスクやパスパターンを除外でき、たとえば `/Volumes/mail` のように長くマウントしたままにしておくディスクイメージを、取り外し候補に出さないようにできます。

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

### ディスク分析（Analyze）

`mo analyze` はターミナル内で動作するインタラクティブなディスク探索ツールです。矢印キーやVimキーバインドでの移動、絞り込み、複数選択、Finderプレビュー、ゴミ箱への移動に対応しています。外付けドライブは通常画面から除外されており、`mo analyze /Volumes` または特定のマウントパスで確認できます。`mo analyze /private/tmp` を使うと、ユーザー所有の一時ファイルを自動クリーンアップの対象にせずに確認できます。

サイズの末尾に `+` が付く場合は部分スキャンで計測できたバイト数、`unknown` はサイズを計測できなかったことを示します。タイムアウトなど一時的な失敗で中断した結果は、完全なキャッシュ済みの計測値を上書きせず、後の再スキャンで欠けたデータを補えます。macOSがターミナルからの読み取りを許可しないフォルダは、アクセス権が変わるまで部分スキャンのままです。ターミナルの一覧は大きい順に30件までなので、読み取れない項目が一覧から外れることがありますが、その場合も合計は部分スキャンとして表示されます。ディレクトリのJSON出力にはスキャンしたすべての項目が含まれます。

`mo analyze --json /path` の結果全体と各項目には `scan_status`（`complete`、`partial`、`unavailable`）が含まれます。数値のサイズは計測済みのバイト数で、`unavailable` での0は空のディレクトリを意味しません。部分スキャンでも終了コードは0なので、自動化では `scan_status` を確認してください。完全性はMoleの既存のスキャン除外の範囲内で判断され、ファイルシステムのアトミックなスナップショットは保証しません。

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

### 状態監視（Status）

`mo status` はハードウェア、システム負荷、ディスクI/O、ネットワーク通信量、電源、プロセスを一覧表示する読み取り専用ダッシュボードです。

デフォルトのIPv4ルートがVPNやトンネルを経由する場合、ネットワークグラフはそのインターフェースの速度を使い、物理アダプタ側で同じ通信量を二重に数えないようにします。JSON出力にはルーティング先のトンネルを含むインターフェースごとの速度が残り、デフォルトではないアイドル状態のトンネルは表示されません。

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

ヘルススコアはCPU、メモリ、ディスク容量、SMART状態、I/O、温度、バッテリー状態、稼働時間をまとめたもので、範囲ごとに色分けされます。`k` で猫の表示を切り替え、`c` で表示するCPUコア数を切り替え、`q` で終了します。表示設定は保存されます。

<details>
<summary><strong>JSON、NDJSON出力とプロセスアラート</strong></summary>

- `mo analyze --json ~/Documents`：指定パスのディスク分析結果をJSONで出力
- `mo status --json`：システムステータスをJSONで出力
- `mo status | jq '.health_score'`：パイプ接続時に自動でJSONモードへ切り替え
- `mo status --watch --interval 2s`：NDJSON形式でリアルタイムストリーミング
- `mo history --json`：クリーンアップ履歴をJSONで出力。各セッションには `run_id`（不透明な文字列で、識別情報が記録されていない場合は空）と `attribution` が含まれ、識別できた実行は `run`、旧来のコマンド単位のグループ化は `command`、旧形式のマーカーでは中断と実行の重なりを区別できない場合は `ambiguous` になります。記録されたアクションは引き続き参照できますが、`ambiguous` の件数を個々の実行に正しく割り当てることはできません。`ended_at` が空の場合は終了マーカーが記録されていません。

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

ゾンビプロセスの診断は読み取り専用で、プロセスを終了したりヘルススコアに影響したりしません。Moleがプロセスのサンプルを一度も取得できていない間は、`process_collected_at`、`process_stale`、`zombie_count`、`zombie_parents_complete` が省略され、`zombie_parents` は `null` になります。その後のfast/watchスナップショットは、最後に成功したサンプルを元の `process_collected_at` のまま再利用して `process_stale: true` を設定し、新しいサンプルを取得すると `false` に戻ります。`0` はMoleが計測した結果ゾンビがなかったことを意味します。親プロセスの要約は判明した上位3件までで、`zombie_parents_complete: false` は帰属情報が取得できない、不完全、または切り詰められたことを示します。

一部のコレクタが失敗しても、`mo status --json` は収集できた指標を出力し、失敗をstderrに報告して正常終了します。`--watch` がストリームを続けるのと同じ動作です。CPU、メモリ、ディスク、プロセスの指標がどれも取得できない場合、またはJSON出力に失敗した場合のみ終了コード1になります。

CPU使用率がしきい値を超え続けるプロセスについて、読み取り専用のアラートも表示します。`--proc-cpu-threshold`、`--proc-cpu-window`、`--proc-cpu-alerts=false` で調整または無効化できます。

</details>

### プロジェクトクリーン（Purge）

`mo purge` は再ビルド可能なプロジェクト生成ディレクトリ（`node_modules`、`target`、`.build`、`build`、`dist` など）を検出します。プロジェクトごとに整理して表示し、チェックして確認した項目のみを、ゴミ箱を経由せず完全に削除します。直近7日間にファイルの変更があった項目や、変更時期をMoleが確認できない項目は標準で選択解除されます。`fd` があれば使用し、なければ `find` を使います。デプロイ用のキーペアファイル、入れ子のGitリポジトリ、Gitで管理されたファイルを含むディレクトリは保護されます。非対話モードでは `mo purge --yes` が必要です。先に `mo purge --dry-run` で候補を確認してください。

Page Up/Downまたは `h`/`l` でページ移動、`[`/`]` でプロジェクト間を移動、`X` でそのプロジェクトをスキップして次へ進みます。`/` でプロジェクトのパスと生成物の名前を検索し、`n` で選択状態を変えずに次の一致へ移動し、Enterで最終的なパスの確認画面を開きます。表示される容量は推定値で、計測できなかった生成物や不完全なスキャンは明示されます。

<details>
<summary><strong>Purge 出力例</strong></summary>

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
<summary><strong>カスタムスキャンパス</strong></summary>

`mo purge --paths` でスキャン対象のディレクトリを設定するか、`~/.config/mole/purge_paths` を直接編集します：

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

カスタムパスを設定すると、Moleはそのディレクトリだけをスキャンします。未設定の場合は `~/Projects`、`~/GitHub`、`~/dev` や、対応するエージェントのworktreeディレクトリなどの標準パスを使います。探索の途中結果は保存されません。生成物のスキャンは設定した各ルートから6階層下までなので、より深いプロジェクトには近いルートを追加してください。Purgeはworktree内の再ビルド可能な生成物を削除しますが、worktree自体は削除しません。

</details>

### インストーラ整理（Installer）

`mo installer` はダウンロード、デスクトップ、Homebrewキャッシュ、iCloud、Mail、TelegramなどからDMG、PKG、MPKG、ISO、XIP、ZIPインストーラを探索し、削除前にサイズと保存場所を表示します。スキャン全体に制限時間があり、スキャンやメタデータの取得が失敗またはタイムアウトした場合は、部分的なデータで処理せず結果を破棄します。破損したZIPや読み取れないZIPはスキップされ、シンボリックリンクのスキャンルートには対応しますが、その配下のシンボリックリンクはたどりません。選択したファイルは、変更されていないことを削除の直前に再検証します。

<details>
<summary><strong>Installer 出力例</strong></summary>

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

## クイックランチャー

<details>
<summary><strong>Raycast & Alfred設定</strong></summary>

Clean、Uninstall、Optimize、Analyze、Status の5つのランチャーを一括設定：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

スクリプトはRaycastコマンドを追加し、Alfredの設定がある場合は `clean`、`uninstall`、`optimize`、`analyze`、`status` をキーワードにしたAlfredワークフローも追加します。

Raycastは一度だけ手動設定が必要です：

1. **Raycast Settings > Extensions > Script Commands** を開きます。
2. `~/Library/Application Support/Raycast/script-commands` をスクリプトディレクトリとして追加します。
3. Raycastで **Reload Script Directories** を実行します。

ランチャーはTerminal、iTerm2、Alacritty、kitty、WezTerm、Ghostty、Hyper、WindTerm、Warpを自動検出します。`MO_LAUNCHER_APP=<name>` で使うターミナルを指定でき、[Kaku](https://github.com/tw93/Kaku) でMoleを直接実行することもできます。

</details>

## コミュニティ

Moleの開発に貢献いただいたすべての方に感謝申し上げます。ぜひフォローしてみてください ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole コントリビューター" width="1000" />
</a>

<br/><br/>
X (Twitter) で寄せられた実際の声：

<img src="./docs/img/mole-love.png" alt="コミュニティフィードバック" width="1000" />

PAPAYA 電腦教室 による [Moleチュートリアル動画](https://www.youtube.com/watch?v=UEe9-w4CcQ0) をご覧いただけます。

## サポート

- [Mole for Mac](https://mole.fit) の購入が、Moleの継続開発を支援する最も直接的な方法です
- Moleが役に立った場合は、GitHubのStarや [Xでのシェア](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.)、Issue・PRでのフィードバックをお願いします
- 我が家には「湯圓（タンユエン）」と「コーラ」という2匹の猫がいて、Moleが役に立ったら彼女たちに <a href="https://cats.tw93.fun?name=Mole" target="_blank">缶詰 🥩</a> をごちそうしてもらえるとうれしいです

<details>
<summary>支援してくださった方々 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="スポンサー" width="1000" loading="lazy" /></a>
</details>

## ライセンス

MoleはGPL-3.0ライセンスのもとでオープンソース公開されています。詳細は [LICENSE](LICENSE) をご覧ください。変更したバージョンを共有する場合は、同じライセンスのままにする必要があります。Moleをフォークして別の製品にする場合は、別の名前を使い、Moleを元のプロジェクトとして明記してください。[Mole for Mac](https://mole.fit) は独立したプロプライエタリなアプリです。Moleはこれからも長く続けていきます。
