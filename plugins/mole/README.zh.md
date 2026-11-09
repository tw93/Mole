# Mole

这个插件给 DeepSeek Harness 装上开源 Mole CLI（`mo`）的官方 skill，macOS 和 Windows 都能用。装好后直接问「什么占了我的磁盘」，Agent 会按 Mole 自己的 JSON 输出回答，清理前先用 `--dry-run` 给你看清单，等你同意才动手，卸载应用和需要管理员权限的步骤留给你在自己的终端里跑。

插件只带 skill，本机要先装好 Mole CLI，macOS 用 `brew install mole`，Windows 用 `scoop install mole`。

用命令行安装插件：`dsh plugin --profile <name> add dsh-mole`。

源码、GPL-3.0 协议和其他安装方式见 https://github.com/tw93/Mole。
