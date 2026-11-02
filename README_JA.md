<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <img src="./docs/img/mole-logo.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Windows</h1>
  <p><b>WindowsパソコンのディープクリーンとアプリのアンインストールからOS最適化、ディスク分析、ステータス監視まで。無料のオープンソースCLI。</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · 日本語 · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Mole CLI for Windows メニュー" width="736" />
</p>

> 💡 このブランチは無料のオープンソースWindows CLI（`mo`）です。ネイティブアプリがよければ、[Mole for Windows](https://mole.fit/ja/windows) を別途ダウンロードできます。削除前の確認、アプリの更新、スタートアップ管理、ディスクの階層分析、リアルタイムのステータス表示を備えています。macOS版CLIは [mainブランチ](https://github.com/tw93/Mole#readme) にあります。

## 機能

- **オールインワンCLIツール**：CCleaner、IObit Uninstaller、WinDirStat、タスクマネージャー風のワークフローをひとつのターミナルコマンドに集約
- **ディープクリーン**：一時ファイル、キャッシュ、ログ、ブラウザの残留物を削除して空き容量を確保
- **スマートアンインストーラ**：アプリ本体と残ったインストールフォルダをまとめて削除
- **ディスク分析**：インタラクティブTUIで容量内訳を可視化し、大容量ファイルを探索
- **システム最適化**：DNSのフラッシュ、システムドライブの最適化、ディスクの健康状態チェック
- **リアルタイム監視**：CPU、メモリ、ディスク、ネットワーク、プロセスの状態をリアルタイムで確認

## クイックスタート

MoleはWindows 10および11で、標準搭載のWindows PowerShell 5.1を使って動作します。スクリプトでのインストールにはGitが必要で、ソースが最新リリースと異なる場合はネイティブツールをビルドするためにGoも必要です。インストール先は `%LOCALAPPDATA%\Programs\mole-cli` で、`mo` と `mole` がPATHに追加されます。

**Scoopでインストール**

```powershell
scoop install mole
```

**スクリプトでインストール**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Moleの配布元はこのGitHubリポジトリ、Scoop、Windowsアプリ用の [mole.fit](https://mole.fit/ja/windows) だけです。「Moleベース」をうたう別のアプリや、エンコードされたコマンドをターミナルに貼り付けるよう求めるサイトはMoleとは無関係です。

**AI エージェントでインストール**

エージェントにこう伝えるだけです：

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

スキルを自分で入れることもできます。入れると Claude Code、Codex、Cursor などのエージェントは削除の前に必ず `--dry-run` で一覧を見せ、アプリのアンインストールと管理者権限が必要な手順はあなたに任せます。更新は `npx skills update -g -y` です。

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

ホストのプラグインとして入れる場合は、Claude Code で `/plugin marketplace add tw93/Mole` のあと `/plugin install mole@mole`、Codex で `codex plugin marketplace add tw93/Mole` のあと `codex plugin add mole@mole` を実行します。

**主要コマンド**

```powershell
mo                           # インタラクティブメニューを開く
mo clean                     # ディープクリーン
mo uninstall                 # インストール済みアプリと残留ファイルを削除
mo optimize                  # キャッシュとサービスのリフレッシュ
mo analyze                   # ディスク分析：容量の内訳を可視化
mo status                    # システムの健康度をリアルタイム表示
mo purge                     # プロジェクトのビルド生成物を整理

mo update                    # Moleを更新
mo remove                    # このPCからMoleを削除
mo --help                    # ヘルプを表示
mo --version                 # インストール済みバージョンを表示
```

**安全プレビュー（Dry Run）**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 安全プレビュー + 詳細ログ
mo clean --whitelist         # 保護するパスの管理
mo clean --system            # システム領域のクリーンも実行（管理者として実行）
mo purge --paths             # プロジェクト検索ディレクトリの設定
mo analyze D:\               # 別のドライブを分析
mo uninstall --list          # インストール済みアプリを一覧表示（パイプ時はJSON）
mo analyze --json D:\        # ディスク分析をJSONで出力
```

<details>
<summary><strong>その他のインストールオプション</strong></summary>

インストール前にコードを確認したい場合は、`windows` ブランチをcloneし、その場でインストーラを実行してください。`.git` が残るので、あとから `mo update` を使えます：

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

スタートメニューに項目を追加するには `-CreateShortcut` を付けてください。アンインストールは `mo remove` で行います。

</details>

## 安全性

Moleはファイルを削除できるため、パスを検証し、システム領域とユーザープロファイルの場所を保護します。`uninstall`、`purge`、`remove` は、削除の前に必ず確認を求めます。安全に変更できると確認できない項目は、スキップします。

- `clean`、`uninstall`、`purge` はファイル削除を伴うため、事前に `--dry-run` で確認し、必要に応じて `--debug` を併用してください
- `clean` と `purge` は完全に削除します。確認済みの `uninstall` の残存ファイルはごみ箱へ移動し、アプリ自身のアンインストーラーは元の動作を保ちます。`mo analyze` で削除したファイルもごみ箱へ移動されます。ごみ箱に入らない大きな項目は、完全に削除するかを Windows が先に確認します
- Moleは通常のユーザーとして実行してください。システム領域の処理は、PowerShellを管理者として実行しない限りスキップされます
- `mo clean --whitelist` で保護するパスを設定できます
- クリーンアップ履歴は `%USERPROFILE%\.config\mole\operations.log` に記録され、`mo history` で確認するか、`MO_NO_OPLOG=1` で無効化できます
- `C:\Windows`、`C:\Program Files`、Windows Defenderのフォルダ、ユーザープロファイルのルートには一切手を加えません

脆弱性の報告方法と安全上の境界は [SECURITY.md](SECURITY.md) をご覧ください。

## 機能詳細

以下の画面はテスト用PCで撮影したものです。実際の表示項目や容量は、ご利用のPCによって異なります。

### ディープクリーン（Clean）

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="mo clean --dry-run のプレビュー" width="736" />

詳細リストには、プレビューで見つかったすべてのパスが記録されます。残したいパスは、リストからコピーしてホワイトリストに追加してください。

### アプリアンインストール（Uninstall）

```powershell
mo uninstall
```

レジストリとWindowsアプリからインストール済みのプログラムを容量の大きい順に一覧表示し、選択したものを各アプリ自身のアンインストーラで削除して、残ったインストールフォルダも整理します。`mo uninstall --dry-run` なら、何も実行せずに、各アプリでどのアンインストーラが使われ、何が削除されるかを確認できます。

<img src="./docs/img/uninstall-windows.png" alt="mo uninstall のアプリ一覧" width="736" />

### システム最適化（Optimize）

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="mo optimize --dry-run のプレビュー" width="736" />

ディスクの最適化やARPキャッシュのフラッシュなどの処理は管理者権限が必要で、権限がない場合はスキップされます。これらを含めるには、PowerShellを管理者として実行してください。

### ディスク分析（Analyze）

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="mo analyze 概要" width="807" />

macOS版と同じレイアウトのインタラクティブなディスク探索ツールです。矢印キーでフォルダを移動し、`Backspace` で戻り、`T` で大容量ファイルを一覧表示し、`Del` で選択した項目を確認後にごみ箱へ移動します。

### 状態監視（Status）

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="mo status ダッシュボード" width="1000" />

ヘルススコア、CPU、メモリ、ディスク、電源、ネットワーク、負荷の高いプロセスを表示するリアルタイムのダッシュボードです。

### プロジェクトクリーン（Purge）

```powershell
mo purge --dry-run
```

プロジェクトフォルダ内のビルド生成物（`node_modules`、`target`、`build`、`dist`、`venv` など）を検出し、整理するプロジェクトを選べます。選択するまでは何も選ばれません。スキャン対象のフォルダは `mo purge --paths` で設定します。

## コミュニティ

Moleの開発に貢献いただいたすべての方に感謝申し上げます。ぜひフォローしてみてください ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole コントリビューター" width="1000" />
</a>

## サポート

- [Mole for Windows](https://mole.fit/ja/windows) の購入が、Moleの継続開発を支援する最も直接的な方法です
- Moleが役に立った場合は、GitHubのStarや [Xでのシェア](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.)、Issue・PRでのフィードバックをお願いします
- コントリビューションを歓迎します。まず [CONTRIBUTING.md](CONTRIBUTING.md) をお読みください
- 我が家には「湯圓（タンユエン）」と「コーラ」という2匹の猫がいて、Moleが役に立ったら彼女たちに <a href="https://cats.tw93.fun?name=Mole" target="_blank">缶詰 🥩</a> をごちそうしてもらえるとうれしいです

## ライセンス

MoleはGPL-3.0ライセンスのもとでオープンソース公開されています。詳細は [LICENSE](LICENSE) をご覧ください。変更したバージョンを共有する場合は、同じライセンスのままにする必要があります。Moleをフォークする場合は、別の名前を使い、Moleを元のプロジェクトとして明記してください。詳細は [TRADEMARK.md](TRADEMARK.md) をご覧ください。
