<div align="center">
  <h1>Mole</h1>
  <p><em>Dig deep like a mole to clean your Mac.</em></p>
</div>

<p align="center">
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+GclQS9ZnxyI2ODQ1"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</p>

<p align="center">
  <img src="https://cdn.tw93.fun/img/mole.jpeg" alt="Mole - 95.50GB freed" width="800" />
  <p align="center">由于 Mole 还在中级版本，如果这台 Mac 对你非常重要，建议再等等。</p>
</p>

## Features

- **Deep System Cleanup** - Cleans way more junk than CleanMyMac/Lemon - caches, logs, temp files
- **Thorough Uninstall** - Scans 22+ locations to remove app leftovers, not just the .app file
- **Interactive Disk Analyzer** - Navigate folders with arrow keys, find and delete large files quickly
- **Fast & Lightweight** - Terminal-based with arrow-key navigation, pagination, and Touch ID support

## Quick Start

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

Or via Homebrew:

```bash
brew install tw93/tap/mole
```

**Run:**

```bash
mo                      # Interactive menu
mo clean                # System cleanup
mo clean --dry-run      # Preview mode
mo clean --whitelist    # Manage protected caches
mo uninstall            # Uninstall apps
mo analyze              # Disk analyzer

mo touchid              # Configure Touch ID for sudo
mo update               # Update Mole
mo remove               # Remove Mole from system
mo --help               # Show help
mo --version            # Show installed version
```

## Tips

- Safety first, if your Mac is mission-critical, wait for Mole to mature before full cleanups.
- Preview the cleanup by running `mo clean --dry-run` and reviewing the generated list.
- Protect caches with `mo clean --whitelist`; defaults cover Playwright, HuggingFace, Maven, and Surge Mac paths.
- Use `mo touchid` to approve sudo with Touch ID instead of typing your password.

## Quick Launchers

One command sets up Raycast + Alfred shortcuts for `mo clean` and `mo uninstall`:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/integrations/setup-quick-launchers.sh | bash
```

Done! Raycast gets `clean` / `uninstall`, Alfred gets the same keywords.  
Details and manual options live in [integrations/README.md](integrations/README.md).

## Features in Detail

### Deep System Cleanup

```bash
$ mo clean

▶ System essentials
  ✓ User app cache (45.2GB)
  ✓ User app logs (2.1GB)
  ✓ Trash (12.3GB)

▶ Browser cleanup
  ✓ Chrome cache (8.4GB)
  ✓ Safari cache (2.1GB)

▶ Developer tools
  ✓ Xcode derived data (9.1GB)
  ✓ Node.js cache (14.2GB)

▶ Others
  ✓ Dropbox cache (5.2GB)
  ✓ Spotify cache (3.1GB)

====================================================================
CLEANUP COMPLETE!
Space freed: 95.50GB | Free space now: 223.5GB
====================================================================
```

### Smart App Uninstaller

```bash
$ mo uninstall

Select Apps to Remove
═══════════════════════════
▶ ☑ Adobe Creative Cloud      (12.4G) | Old
  ☐ WeChat                    (2.1G) | Recent
  ☐ Final Cut Pro             (3.8G) | Recent

Uninstalling: Adobe Creative Cloud
  ✓ Removed application              # /Applications/
  ✓ Cleaned 52 related files         # ~/Library/ across 12 locations
    - Support files & caches         # Application Support, Caches
    - Preferences & logs             # Preferences, Logs
    - WebKit storage & cookies       # WebKit, HTTPStorages
    - Extensions & plugins           # Internet Plug-Ins, Services
    - System files with sudo         # /Library/, Launch daemons

====================================================================
UNINSTALLATION COMPLETE!
Space freed: 12.8GB
====================================================================
```

### Disk Space Analyzer

```bash
$ mo analyze

Analyzing: /Users/You
═══════════════════════════════════════════════════════
Total: 156.8GB

├─ 📁 Library                                        45.2GB
│  ├─ 📁 Caches                                      28.4GB
│  └─ 📁 Application Support                         16.8GB
├─ 📁 Downloads                                      32.6GB
│  ├─ 📄 Xcode-14.3.1.dmg                            12.3GB
│  ├─ 📄 backup_2023.zip                             8.6GB
│  └─ 📄 old_projects.tar.gz                         5.2GB
├─ 📁 Movies                                         28.9GB
│  ├─ 📄 vacation_2023.mov                           15.4GB
│  └─ 📄 screencast_raw.mp4                          8.8GB
├─ 📁 Documents                                      18.4GB
└─ 📁 Desktop                                        12.7GB
```

## Support

- If Mole reclaimed storage for you, consider starring the repo or sharing it with friends needing a cleaner Mac.
- Have ideas or fixes? Open an issue or PR and help shape Mole's roadmap together with the community.
- Love cats? Treat Tangyuan and Cola to canned food via <a href="https://miaoyan.app/cats.html?name=Mole" target="_blank">this link</a> and keep the mascots purring.

## License

MIT License - feel free to enjoy and participate in open source.
