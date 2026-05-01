# Mole — Plan de portage Linux/Debian

> Document de référence pour le portage de Mole (macOS) vers Linux/Debian.
> Branche de travail principale : `claude/port-linux-debian-L3h6G`
> Chaque phase dispose de sa propre branche `linux/phase-N-*`.

---

## Contexte technique

| Métrique | Valeur |
|---|---|
| Lignes Bash total | ~25 000 |
| Lignes Go total | ~12 700 |
| Fichiers shell à modifier | 23 |
| Fichiers Go à modifier | 16 |
| Fichiers Go `//go:build darwin` | 15 (à lever) |
| Références macOS-spécifiques (shell) | ~780 occurrences réparties |
| Commandes | clean, uninstall, optimize, analyze, status, purge, installer, touchid, check, completion, update |

---

## Tableau général — Effort par commande

| Commande | Fichiers principaux | Réf. macOS | Faisabilité Linux | Effort estimé | Priorité |
|---|---|---|---|---|---|
| `status` (Go) | `cmd/status/*.go` (11 fichiers) | ~40 | Haute — gopsutil cross-platform, fallbacks Linux partiels déjà codés | **M** 3-4j | P1 |
| `analyze` (Go) | `cmd/analyze/*.go` (15 fichiers) | ~25 | Haute — syscall.Statfs identique, remplacer osascript+mdfind | **M** 3j | P1 |
| `purge` | `bin/purge.sh`, `lib/clean/purge_shared.sh`, `lib/manage/purge_paths.sh` | 32 | Très haute — node_modules/venv/target sont cross-platform | **F** 1j | P1 |
| `clean` (infra) | `lib/core/base.sh`, `lib/core/common.sh` | 23 | Haute — remplacer `~/Library/` → XDG dirs | **F** 1j | P1 |
| `clean` (caches) | `lib/clean/caches.sh`, `lib/clean/system.sh` | 23 | Haute — chemins bien connus côté Linux | **F** 1-2j | P1 |
| `clean` (user) | `lib/clean/user.sh` | 154 | Moyenne — nombreux chemins `~/Library/` hardcodés | **M** 3j | P2 |
| `clean` (dev) | `lib/clean/dev.sh` | 107 | Moyenne — Xcode N/A, Homebrew → apt/snap, reste cross-platform | **M** 2j | P2 |
| `optimize` | `lib/optimize/tasks.sh`, `lib/optimize/diagnostics.sh`, `lib/optimize/maintenance.sh` | 69+ | Moyenne — launchctl→systemctl, APIs 1:1 disponibles | **M** 3j | P2 |
| `installer` | `bin/installer.sh` | 13 | Moyenne — remplacer .dmg/.pkg → .deb/.AppImage/snap | **F** 1j | P2 |
| `check` | `lib/check/all.sh`, `lib/check/health_json.sh` | ~30 | Moyenne — system_profiler → lshw/dmidecode | **F** 1-2j | P2 |
| `uninstall` | `bin/uninstall.sh`, `lib/uninstall/batch.sh`, `lib/uninstall/brew.sh` | 15+ | Basse — réécriture profonde, modèle .app inexistant | **E** 5-7j | P3 |
| `touchid` | `bin/touchid.sh` | 18 | Basse — fprintd disponible mais hardware variable | **M** 2j | P3 |
| `completion` | `bin/completion.sh` | 0 | Très haute — Bash/Zsh/Fish cross-platform | **T** 0.5j | P1 |
| `update` | `lib/manage/update.sh` | ~5 | Haute — remplacer Homebrew update → apt/curl | **F** 1j | P2 |
| `mole` (entry) | `mole` (main script) | 75 | Haute — détection OS, tagline, update flow | **M** 2j | P1 |

**Légende effort :** T = Trivial (<1j) · F = Faible (1-2j) · M = Moyen (3-4j) · E = Élevé (5-7j)

---

## Tableau détaillé — Par module Go

### `cmd/status/` — Monitoring système

| Fichier | Lignes | API macOS utilisée | Équivalent Linux | Effort | Notes |
|---|---|---|---|---|---|
| `metrics_hardware.go` | ~130 | `system_profiler SPHardwareDataType`, `sw_vers` | `/proc/cpuinfo`, `lscpu`, `dmidecode -t system`, `/etc/os-release` | F | Retourne struct vide sur non-darwin actuellement |
| `metrics_battery.go` | ~200 | `pmset -g batt`, `system_profiler SPPowerDataType` | `/sys/class/power_supply/BAT*/` — fallback **déjà implémenté** | T | Linux path présent, à activer |
| `metrics_gpu.go` | ~150 | `system_profiler SPDisplaysDataType`, `powermetrics` | `nvidia-smi`, `intel_gpu_top`, `lspci -v` | M | Multi-backend nécessaire |
| `metrics_cpu.go` | ~110 | `runtime.GOOS != "darwin"` guard | `gopsutil` (déjà cross-platform) | T | Guard à supprimer |
| `metrics_memory.go` | ~90 | Cache Apple specifics | `gopsutil` (déjà cross-platform) | T | Ajuster calcul cached memory |
| `metrics_disk.go` | ~170 | `diskutil info`, APFS detection | `lsblk`, fstype standard | F | APFS → ext4/btrfs/xfs |
| `metrics_network.go` | ~150 | Interface filtering macOS | `gopsutil` (déjà cross-platform) | T | Filtrer `lo`, `virbr*` |
| `metrics_process.go` | ~80 | `runtime.GOOS != "darwin"` guard | `gopsutil` | T | Guard à supprimer |
| `metrics_bluetooth.go` | ~80 | `system_profiler SPBluetoothDataType` | `bluetoothctl devices` — fallback **déjà présent** | T | Linux path déjà codé |
| `metrics.go` | ~100 | Agrégation | Port direct | T | Supprimer guards darwin |
| `main.go` | ~200 | `//go:build darwin` tag | Lever le build tag | T | |

> **Total cmd/status estimé : ~3j** (la moitié des Linux fallbacks est déjà présente)

---

### `cmd/analyze/` — Analyseur disque

| Fichier | Lignes | API macOS utilisée | Équivalent Linux | Effort | Notes |
|---|---|---|---|---|---|
| `delete.go` | ~165 | `osascript` → Finder Trash | `gio trash <path>` (freedesktop) ou `mv ~/.local/share/Trash/` | F | Créer `delete_linux.go` |
| `scanner.go` | ~900 | `mdfind` (Spotlight) pour grands fichiers, `syscall.Stat_t` | `find -size +50M`, `syscall.Stat_t` **identique Linux** | F | `mdfind` → `find` |
| `main.go` | ~600 | `syscall.Statfs`, `open` (Finder) | `syscall.Statfs` identique, `xdg-open` | F | |
| `cleanable.go` | ~200 | `/.Trash/` path, macOS bundle paths | `~/.local/share/Trash/` | T | Ajuster paths corbeille |
| `constants.go` | ~150 | Chemins macOS spécifiques | Chemins Linux XDG | F | |
| `insights.go` | ~150 | Analyse bundle `.app` | Analyse packages Linux | M | Logique différente |
| `view.go` | ~300 | TUI affichage | Port direct (bubbletea cross-platform) | T | |
| `cache.go`, `format.go`, `heap.go` | ~300 | Aucune dépendance OS | Port direct | T | |

> **Total cmd/analyze estimé : ~3j**

---

## Tableau détaillé — Par module Shell

### Infrastructure Core

| Fichier | Lignes | Réf. macOS | Changements requis | Effort |
|---|---|---|---|---|
| `lib/core/base.sh` | 882 | 23 | `~/Library/` → XDG (`~/.cache/`, `~/.local/share/`, `~/.config/`), log path, détection OS | F 1j |
| `lib/core/common.sh` | 228 | 5 | Détection OS, source conditionnelle des modules | F 0.5j |
| `lib/core/sudo.sh` | 326 | 4 | Remplacer Touch ID check par `sudo -v` standard | T 0.25j |
| `lib/core/app_protection.sh` | 1596 | 149 | Refonte majeure : bundle IDs → noms de paquets dpkg, whitelist apps système Linux | E 3j |
| `lib/core/bundle_resolver.sh` | ~200 | 12 | Remplacer `PlistBuddy`/`Info.plist` → lecture `.desktop` + `dpkg -s` | M 1.5j |
| `lib/core/pkg_receipts.sh` | ~100 | ~10 | `pkgutil --files` → `dpkg -L <pkg>` | F 0.5j |
| `lib/core/file_ops.sh` | 830 | ~5 | `~/.Trash/` → `~/.local/share/Trash/` (`gio trash`) | T 0.25j |
| `lib/core/ui.sh` | 504 | 0 | Aucun changement | T |
| `lib/core/log.sh` | 452 | 2 | Chemin log `~/Library/Logs/mole/` → `~/.local/share/mole/logs/` | T |
| `lib/core/timeout.sh` | 255 | 0 | Aucun changement | T |

---

### Commande `clean`

| Fichier | Lignes | Réf. macOS | Changements requis | Effort |
|---|---|---|---|---|
| `bin/clean.sh` | 1308 | 2 | Orchestration — adapter détection OS, appels conditionnels | F 0.5j |
| `lib/clean/caches.sh` | 479 | 8 | Navigateurs : `~/Library/Caches/` → `~/.cache/chromium/`, `~/.cache/mozilla/` etc. | F 1j |
| `lib/clean/system.sh` | 458 | 15 | Logs `/Library/Logs/` → `/var/log/` (avec sudo), `/tmp` identique | F 1j |
| `lib/clean/user.sh` | 1792 | 154 | **Fichier le plus impacté** — tous les `~/Library/` à remapper vers XDG | M 3j |
| `lib/clean/dev.sh` | 1376 | 107 | Xcode → N/A, Homebrew cache → apt/pip/cargo caches, npm/go/rust identiques | M 2j |
| `lib/clean/apps.sh` | 687 | ~30 | Chemins apps spécifiques macOS (Safari, Mail, iCloud) → équivalents Linux | M 1.5j |
| `lib/clean/purge_shared.sh` | 154 | ~5 | Shared logic — peu de changements | T 0.25j |
| `lib/clean/project.sh` | 1674 | ~10 | Node/Python/Rust artifacts — majoritairement cross-platform | F 1j |
| `lib/clean/hints.sh` | 481 | ~5 | Messages d'aide — adapter noms de commandes | T 0.25j |
| `lib/clean/brew.sh` | 127 | 127 | Remplacer entièrement par `apt clean`, `pip cache purge`, `snap refresh` | F 1j |
| `lib/clean/maven.sh` | ~100 | 0 | Aucun changement (cross-platform) | T |
| `lib/clean/app_caches.sh` | 428 | ~20 | Chemins caches apps → Linux equivalents | F 1j |

---

### Commande `optimize`

| Fichier | Lignes | Réf. macOS | Changements requis | Effort |
|---|---|---|---|---|
| `bin/optimize.sh` | 528 | 2 | Orchestration, adapter détection | T 0.25j |
| `lib/optimize/tasks.sh` | 1250 | 69 | `launchctl`→`systemctl`, `dscacheutil`→`resolvectl`, `purge`→`drop_caches`, `atsutil`→`fc-cache`, `lsregister`→`update-desktop-database` | M 3j |
| `lib/optimize/diagnostics.sh` | 419 | ~20 | `system_profiler` → `lshw`/`dmidecode`, disk S.M.A.R.T → `smartctl` | F 1j |
| `lib/optimize/maintenance.sh` | ~200 | ~15 | `periodic` → `systemd timers`/cron, `defaults write` → `gsettings`/config XDG | M 1.5j |

---

### Commande `uninstall`

| Fichier | Lignes | Réf. macOS | Changements requis | Effort |
|---|---|---|---|---|
| `bin/uninstall.sh` | 1375 | 15 | Refonte flux : détection apps par dpkg/snap/flatpak au lieu des `.app` bundles | E 3j |
| `lib/uninstall/batch.sh` | 993 | ~50 | Réécriture complète — plus de bundles macOS, lister/filtrer par gestionnaire de paquets | E 3j |
| `lib/uninstall/brew.sh` | 256 | 256 | → `lib/uninstall/apt.sh` + `lib/uninstall/snap.sh` + `lib/uninstall/flatpak.sh` | M 2j |

---

### Commandes restantes

| Commande | Fichier | Lignes | Réf. macOS | Changements requis | Effort |
|---|---|---|---|---|---|
| `installer` | `bin/installer.sh` | 735 | 13 | `.dmg`/`.pkg` → `.deb`/`.AppImage`/`.run`/`.snap`, chemins `~/Downloads` identiques | F 1j |
| `touchid` | `bin/touchid.sh` | 382 | 18 | Remplacer `pam_tid.so` → `pam_fprintd.so`, détecter `fprintd` + lecteur empreinte | M 2j |
| `check` | `lib/check/all.sh` | 911 | ~25 | `system_profiler` → `lshw`/`inxi`, `diskutil` → `smartctl`, services `launchctl` → `systemctl` | M 2j |
| `check` | `lib/check/health_json.sh` | 195 | ~10 | Adapter sources de données JSON | F 1j |
| `check` | `lib/check/dev_environment.sh` | 142 | ~5 | Homebrew → apt, sinon cross-platform | T 0.5j |

---

### Infrastructure de gestion & CI

| Fichier/Composant | Réf. macOS | Changements requis | Effort |
|---|---|---|---|
| `mole` (main script) | 75 | Détection OS (`uname`), tagline "Mac" → "Linux", update flow sans Homebrew, `is_homebrew_install` → `is_apt_install` | F 1j |
| `lib/manage/update.sh` | 5 | Supprimer branche Homebrew update, garder `curl` direct | T 0.5j |
| `lib/manage/whitelist.sh` | ~3 | Adapter exemples chemins whitelist | T 0.25j |
| `lib/manage/autofix.sh` | ~2 | Peu impacté | T 0.25j |
| `Makefile` | N/A | Ajouter targets `linux-amd64`, `linux-arm64` | T 0.25j |
| `.github/workflows/release.yml` | N/A | Ajouter matrix `ubuntu-latest` | T 0.5j |
| `.github/workflows/test.yml` | N/A | Ajouter job `ubuntu-latest` avec `apt-get install bats` | F 0.5j |
| `install.sh` | N/A | Détecter Debian/Ubuntu, utiliser `apt` ou `curl` direct | F 1j |
| Tests `.bats` | N/A | Adapter stubs macOS, CI Linux | M 2j |

---

## Planning par phases

### Phase 1 — Fondations [`linux/phase-1-foundations`] ~8j

| # | Tâche | Fichiers | Effort |
|---|---|---|---|
| 1.1 | Détection OS dans entry point (`mole`), routing conditionnel | `mole` | 1j |
| 1.2 | Redéfinir constantes XDG dans `lib/core/base.sh` | `lib/core/base.sh` | 1j |
| 1.3 | Lever les build tags `//go:build darwin`, créer fichiers `*_linux.go` stub | `cmd/status/*.go`, `cmd/analyze/*.go` | 1j |
| 1.4 | Porter `cmd/status` — activer Linux fallbacks existants, compléter hardware | `cmd/status/metrics_*.go` | 3j |
| 1.5 | Makefile + CI — ajouter targets Linux | `Makefile`, `.github/workflows/` | 0.5j |
| 1.6 | `bin/completion.sh` — 0 ref macOS, trivial | `bin/completion.sh` | 0.5j |
| 1.7 | `bin/purge.sh` — vérifier les chemins, déjà très cross-platform | `bin/purge.sh` | 1j |

### Phase 2 — Binaires Go [`linux/phase-2-go-binaries`] ~5j

| # | Tâche | Fichiers | Effort |
|---|---|---|---|
| 2.1 | Porter `cmd/analyze/delete.go` → `delete_linux.go` (`gio trash`) | `cmd/analyze/delete*.go` | 1j |
| 2.2 | Porter `cmd/analyze/scanner.go` — `mdfind` → `find` | `cmd/analyze/scanner.go` | 1j |
| 2.3 | Adapter `cleanable.go`, `constants.go` pour Linux paths | `cmd/analyze/` | 0.5j |
| 2.4 | Porter `insights.go` — logique bundles → packages Linux | `cmd/analyze/insights.go` | 1j |
| 2.5 | Tests Go — adapter stubs `osascript` → conditions Linux | `cmd/analyze/*_test.go` | 1j |
| 2.6 | Build & validation croisée Linux/macOS | `Makefile` | 0.5j |

### Phase 3 — `clean` et `optimize` [`linux/phase-3-clean-optimize`] ~12j

| # | Tâche | Fichiers | Effort |
|---|---|---|---|
| 3.1 | `lib/core/common.sh` + `sudo.sh` + `file_ops.sh` | Core files | 1j |
| 3.2 | `lib/clean/system.sh` — logs, tmp, caches système | 1 fichier | 1j |
| 3.3 | `lib/clean/caches.sh` — navigateurs XDG | 1 fichier | 1j |
| 3.4 | `lib/clean/brew.sh` → remplacer par apt/pip/snap equivalents | 1 fichier | 1j |
| 3.5 | `lib/clean/user.sh` — remapper tous les `~/Library/` | 1 fichier (1792L) | 3j |
| 3.6 | `lib/clean/dev.sh` — Xcode N/A, adapter outils dev | 1 fichier | 2j |
| 3.7 | `lib/optimize/tasks.sh` — remplacer toutes les commandes système | 1 fichier (1250L) | 3j |

### Phase 4 — `check`, `installer`, protection système [`linux/phase-4-check-installer`] ~10j

| # | Tâche | Fichiers | Effort |
|---|---|---|---|
| 4.1 | `lib/check/all.sh` + `health_json.sh` — diagnostics Linux | 2 fichiers | 2j |
| 4.2 | `bin/installer.sh` — formats .deb/.AppImage/snap | 1 fichier | 1j |
| 4.3 | `lib/optimize/diagnostics.sh` + `maintenance.sh` | 2 fichiers | 2j |
| 4.4 | `lib/core/app_protection.sh` — système de protection Linux (paquets essentiels dpkg) | 1 fichier (1596L) | 3j |
| 4.5 | `lib/core/bundle_resolver.sh` + `pkg_receipts.sh` → dpkg/flatpak | 2 fichiers | 2j |

### Phase 5 — `uninstall` et `touchid` [`linux/phase-5-uninstall-touchid`] ~9j

| # | Tâche | Fichiers | Effort |
|---|---|---|---|
| 5.1 | `lib/uninstall/brew.sh` → apt/snap/flatpak backends | 1 fichier (réécriture) | 2j |
| 5.2 | `lib/uninstall/batch.sh` — réécriture logique de listing | 1 fichier (993L) | 3j |
| 5.3 | `bin/uninstall.sh` — adapter flux utilisateur | 1 fichier | 2j |
| 5.4 | `bin/touchid.sh` → `bin/fingerprint.sh` avec fprintd/PAM | 1 fichier | 2j |

### Phase 6 — Tests, CI, packaging [`linux/phase-6-tests-ci`] ~5j

| # | Tâche | Fichiers | Effort |
|---|---|---|---|
| 6.1 | Adapter suite BATS pour Linux (stubs, fixtures) | `tests/*.bats` | 2j |
| 6.2 | Script d'installation Linux (apt/deb package ou curl) | `install.sh` | 1j |
| 6.3 | CI GitHub Actions — matrix Ubuntu 22.04 / 24.04 | `.github/workflows/` | 0.5j |
| 6.4 | Documentation — update README, CONTRIBUTING | `README.md` | 0.5j |
| 6.5 | Test end-to-end sur VM Debian fraîche | — | 1j |

---

## Récapitulatif des efforts

| Phase | Branche | Contenu | Effort |
|---|---|---|---|
| Phase 1 | `linux/phase-1-foundations` | Entry point, XDG base, cmd/status Go | 8j |
| Phase 2 | `linux/phase-2-go-binaries` | cmd/analyze Go complet | 5j |
| Phase 3 | `linux/phase-3-clean-optimize` | clean + optimize (shell) | 12j |
| Phase 4 | `linux/phase-4-check-installer` | check + installer + protection système | 10j |
| Phase 5 | `linux/phase-5-uninstall-touchid` | uninstall + fingerprint | 9j |
| Phase 6 | `linux/phase-6-tests-ci` | Tests, CI, packaging, docs | 5j |
| **Total** | | | **~49 jours-développeur** |

---

## Correspondance des API macOS → Linux

### Commandes système

| API macOS | Équivalent Linux/Debian |
|---|---|
| `launchctl load/unload` | `systemctl enable/disable/start/stop` |
| `launchctl list` | `systemctl list-units --state=active` |
| `~/Library/LaunchAgents/` | `~/.config/systemd/user/` |
| `/Library/LaunchDaemons/` | `/etc/systemd/system/` |
| `dscacheutil -flushcache` + `killall mDNSResponder` | `resolvectl flush-caches` ou `systemctl restart nscd` |
| `sudo purge` | `echo 3 > /proc/sys/vm/drop_caches` |
| `atsutil databases -remove` | `fc-cache -fv` |
| `mdutil -E /` | `updatedb` (mlocate) |
| `diskutil resetUserPermissions` | `chown -R $USER:$USER ~` ciblé |
| `pkill bluetoothd` / `killall bluetoothd` | `systemctl restart bluetooth` |
| `periodic daily/weekly/monthly` | `/etc/cron.daily/`, `anacron`, `systemd timers` |
| `arp -a -d` | `ip neigh flush all` |
| `route -n flush` | `ip route flush cache` |
| `scutil` / `networksetup` | `nmcli`, `ip`, `/etc/network/interfaces` |
| `sw_vers -productVersion` | `lsb_release -r`, `/etc/os-release` |
| `system_profiler SPHardwareDataType` | `/proc/cpuinfo`, `lscpu`, `dmidecode -t system` |
| `system_profiler SPDisplaysDataType` | `lspci -v`, `xrandr --verbose` |
| `system_profiler SPBluetoothDataType` | `bluetoothctl devices` (déjà en fallback) |
| `pmset -g batt` | `/sys/class/power_supply/BAT*/` (déjà en fallback) |
| `powermetrics` | `nvidia-smi`, `intel_gpu_top`, `radeontop` |
| `diskutil info` | `lsblk`, `smartctl -a /dev/sdX` |
| `defaults write` | `gsettings set` (GNOME), `xfconf-query` (XFCE), fichiers config XDG |
| `plutil -lint` | Validation JSON/YAML manuelle |
| `PlistBuddy` | `jq` (JSON) ou parsing texte `.desktop` |
| `lsregister` | `update-desktop-database` |
| `mdfind` (Spotlight) | `find`, `locate` |
| `mdls` (métadonnées fichiers) | `stat --format="%X"`, `file` |
| `osascript` (AppleScript) | `gio`, `xdg-open`, `notify-send` |
| `open <file>` | `xdg-open <file>` |
| `pkgutil --files` | `dpkg -L <package>` |
| `pam_tid.so` (Touch ID) | `pam_fprintd.so` (fprintd) |

### Chemins de données

| Chemin macOS | Équivalent Linux (XDG) |
|---|---|
| `~/Library/Caches/` | `~/.cache/` |
| `~/Library/Application Support/` | `~/.local/share/` |
| `~/Library/Preferences/` | `~/.config/` |
| `~/Library/Logs/` | `~/.local/share/mole/logs/` ou `~/.cache/mole/` |
| `/Library/Logs/` | `/var/log/` |
| `~/.Trash/` | `~/.local/share/Trash/` (freedesktop.org) |
| `~/Library/Caches/Homebrew/` | `/var/cache/apt/`, `~/.cache/pip`, `~/.cache/go-build` |
| `/Applications/*.app` | `/usr/share/applications/*.desktop`, `/opt/`, snap/flatpak |
| `~/Library/LaunchAgents/*.plist` | `~/.config/systemd/user/*.service` |
| `/Library/LaunchDaemons/*.plist` | `/etc/systemd/system/*.service` |
| `~/Library/Internet Plug-Ins/` | `~/.mozilla/plugins/` |
| `~/Library/Cookies/` | Profils navigateurs dans `~/.local/share/` |
| `~/Library/Developer/Xcode/DerivedData/` | N/A (pas d'équivalent Xcode) |
| `~/Library/Mobile Documents/` (iCloud) | N/A (service Apple) |

---

## Fonctionnalités non portables

| Fonctionnalité | Raison | Décision recommandée |
|---|---|---|
| Nettoyage iCloud Drive | Service Apple uniquement | Stub + message informatif |
| Nettoyage Safari | Navigateur macOS uniquement | Retirer (Firefox/Chrome couverts) |
| Nettoyage Mail.app | Application Apple | Retirer (Thunderbird à ajouter) |
| Nettoyage iMessage/FaceTime | Services Apple | Retirer |
| `diskutil resetUserPermissions` | HFS+/APFS uniquement | `chown -R $USER:$USER ~` ciblé |
| Désinstallation via Finder | AppleScript | `gio trash` + confirmation terminal |
| GPU via `powermetrics` | Outil Apple privé | `nvidia-smi` / `intel_gpu_top` / `radeontop` |
| Refresh Rate via `system_profiler` | Outil Apple | `xrandr --verbose` |
| Touch ID natif | Hardware Apple | fprintd si lecteur présent, sinon `sudo -v` |

---

## Stratégie de compatibilité croisée

Les modifications doivent préserver la compatibilité macOS existante.
Tout code spécifique à une plateforme doit suivre le pattern :

```bash
# Shell — pattern recommandé
if [[ "$(uname)" == "Darwin" ]]; then
    # code macOS
elif [[ "$(uname)" == "Linux" ]]; then
    # code Linux
fi
```

```go
// Go — pattern existant à généraliser
if runtime.GOOS == "darwin" {
    // macOS path
} else if runtime.GOOS == "linux" {
    // Linux path
}
```

Pour les binaires Go, remplacer les build tags `//go:build darwin` par des
fichiers séparés `*_darwin.go` / `*_linux.go` avec une interface commune.
