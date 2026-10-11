<div align="center">
  <h1>Mole</h1>
  <p><b>Nettoyage en profondeur, désinstallation d'apps, optimisation, analyse de disque et surveillance pour Mac. CLI open source gratuite, plus une app Mac native.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · Français · <a href="README_UA.md">Українська</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Résultats du nettoyage avec Mole" width="1000" />
</p>

> 💡 Ce dépôt contient la CLI open source gratuite (`mo`). Vous préférez une app native ? [Mole for Mac](https://mole.fit/) se télécharge séparément : vérification avant suppression, nettoyage des résidus testé sur plus de 800 apps, maintenance, exploration détaillée du disque, état en direct et contrôle des ventilateurs sur les Mac compatibles. `brew install mole` installe uniquement la CLI.

## Fonctionnalités

- **Boîte à outils CLI tout-en-un** : combine les usages façon CleanMyMac, AppCleaner, DaisyDisk et iStat Menus dans une seule commande de terminal
- **Nettoyage en profondeur** : supprime les caches, journaux, résidus et fichiers orphelins pour libérer de l'espace disque
- **Désinstalleur intelligent** : supprime les applications avec leurs LaunchAgents, préférences et fichiers résiduels
- **Analyseur de disque** : visualise l'espace disque via une interface TUI interactive, repère les gros fichiers et explore les dossiers
- **Maintenance système** : purge le cache DNS, rafraîchit QuickLook et les icônes, et optimise les bases de données système
- **Surveillance en direct** : affiche en temps réel le processeur, la mémoire, les E/S disque, le réseau et les processus

## Démarrage rapide

Mole nécessite macOS 12 ou une version plus récente et prend en charge les Mac Intel et Apple Silicon. Si Homebrew ne prend plus en charge votre version de macOS, utilisez plutôt le script d'installation ; une version expérimentale pour Windows est accessible sur la [branche windows](https://github.com/tw93/Mole/tree/windows).

**Installation via Homebrew**

```bash
brew install mole
```

**Ou via le script d'installation**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**Commandes principales**

```bash
mo                           # Menu interactif
mo clean                     # Nettoyage en profondeur + résidus d'applications supprimées
mo uninstall                 # Désinstaller des applications + leurs résidus
mo optimize                  # Actualiser les caches et services système
mo analyze                   # Explorateur visuel de disque (ou 'mo analyse')
mo status                    # Tableau de bord de santé système en direct
mo purge                     # Nettoyer les fichiers de build de projets
mo installer                 # Trouver et supprimer les fichiers d'installation

mo touchid                   # Configurer Touch ID pour sudo dans le terminal
mo completion                # Activer l'autocomplétion du shell
mo update                    # Mettre à jour Mole
mo update --nightly          # Passer sur la dernière version de développement (installation par script uniquement)
mo remove                    # Désinstaller complètement Mole du système
mo --help                    # Afficher l'aide
mo --version                 # Afficher la version installée
```

**Aperçu sans risque (Dry Run)**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Aperçu + journaux détaillés
mo optimize --whitelist      # Gérer les règles d'optimisation protégées
mo clean --whitelist         # Gérer la liste blanche des caches protégés
mo purge --paths             # Configurer les dossiers de scan de projets
mo analyze /Volumes          # Analyser uniquement les disques externes
mo analyze /private/tmp      # Examiner les dossiers temporaires sans nettoyage automatique
```

<details>
<summary><strong>Autres options d'installation</strong></summary>

Pour installer une version spécifique, spécifiez un tag depuis la [page des versions](https://github.com/tw93/mole/releases), avec ou sans le `V` initial. Pour suivre la branche de développement, utilisez `main` :

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` installe le code en cours de développement issu de la branche principale, attendez-vous à quelques imperfections. `latest` est un alias historique pointant vers `main` ; il n'installe pas la version stable la plus récente.

Par défaut, le script installe Mole dans `/usr/local/bin`, ce qui peut nécessiter un mot de passe administrateur. Pour des mises à jour ultérieures sans mot de passe, installez-le dans un dossier utilisateur :

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Ajoutez l'exportation `PATH` correspondante dans votre `~/.zshrc` ou configuration de shell. Mole met à jour l'installation que vous avez lancée et continue donc d'utiliser ce dossier. Les commandes qui modifient des fichiers appartenant au système peuvent toujours demander un accès administrateur.

**Nix**

Sur macOS, les utilisateurs de Nix peuvent installer le flake depuis `main`, qui contient des changements non publiés :

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

Pour une installation déclarative, ajoutez `github:tw93/mole/main` comme entrée flake et utilisez le paquet `packages.${system}.mole`. Mettez à jour ou supprimez Mole via Nix ; `mo update` et `mo remove` ne modifient pas les installations gérées par Nix.

</details>

## Sécurité et fiabilité

Mole peut supprimer des fichiers ; il valide donc les chemins, protège les emplacements partagés et ceux du système, et demande une confirmation quand une action l'exige. Quand Mole ne peut pas prouver qu'un élément peut être modifié sans risque, il l'ignore ou refuse l'opération.

- `clean`, `uninstall`, `purge`, `installer` et `remove` suppriment des fichiers : prévisualisez toujours leurs actions avec `--dry-run`, complété au besoin de `--debug`
- Exécutez Mole **sans `sudo`** : les privilèges administrateur ne sont demandés que pour les actions touchant au système
- `mo analyze` place les éléments sélectionnés dans la Corbeille de macOS après confirmation
- Les opérations de nettoyage sont consignées dans `~/Library/Logs/mole/operations.log` ; consultez-les avec `mo history` ou désactivez la journalisation avec `MO_NO_OPLOG=1`
- Préservez des caches avec `mo clean --whitelist` ou excluez des opérations avec `mo optimize --whitelist`

Consultez [SECURITY.md](SECURITY.md) et [SECURITY_AUDIT.md](SECURITY_AUDIT.md) pour la marche à suivre en cas de vulnérabilité, les limites de sécurité et les restrictions actuelles.

## Détail des fonctionnalités

Les exemples suivants sont abrégés. Les éléments détectés, les tailles et les raisons d'omission dépendent de votre Mac.

### Nettoyage (Clean)

`mo clean` analyse les caches sûrs, les journaux, les fichiers temporaires, les dossiers de développement et les résidus d'applications désinstallées. Il vide la corbeille par défaut ; pour la conserver, sélectionnez Trash dans `mo clean --whitelist`, le même menu qui préserve les caches à garder. La sélection est enregistrée dans `~/.config/mole/whitelist`. Avant d'ajouter des chemins personnalisés, ouvrez le menu et appuyez sur Entrée pour enregistrer la sélection, puis ajoutez un chemin par ligne. Un fichier existant remplace les règles par défaut optionnelles ; les protections de sécurité intégrées s'appliquent toujours.

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

### Désinstallation (Uninstall)

`mo uninstall` supprime une application installée ainsi que les fichiers associés que Mole peut rattacher à cette application. Si une autre copie installée de la même application utilise encore des fichiers partagés, Mole les conserve. Si l'application a déjà été supprimée manuellement, lancez `mo clean` pour trouver les résidus orphelins.

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

### Optimisation (Optimize)

`mo optimize` exécute une maintenance délimitée pour les services Finder, réseau, bases de données et macOS pris en charge. Les tâches inutiles, risquées à ce moment-là ou indisponibles sont ignorées avec justification. Utilisez `mo optimize --whitelist` pour exclure des tâches ou des motifs de chemin, par exemple pour préserver une image disque montée en permanence comme `/Volumes/mail` sans qu'elle ne soit proposée au démontage.

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

### Analyse de l'espace (Analyze)

`mo analyze` ouvre un explorateur de disque interactif dans le terminal. Il prend en charge les touches fléchées et les raccourcis Vim, le filtrage rapide, la sélection multiple, la prévisualisation dans le Finder et le déplacement confirmé vers la Corbeille. Les disques externes sont ignorés par défaut dans la vue générale ; examinez-les avec `mo analyze /Volumes` ou un point de montage précis. Utilisez `mo analyze /private/tmp` pour vérifier les dossiers temporaires sans déclencher de nettoyage automatique.

Une taille terminée par `+` signale une analyse partielle ; `unknown` indique que le volume n'a pas pu être mesuré. Les résultats interrompus par un délai d'attente n'écrasent pas les mesures complètes en cache ; une analyse ultérieure comblera les données manquantes. Les dossiers que macOS ne laisse pas lire au terminal restent marqués comme partiels tant que les droits d'accès ne changent pas. La liste du terminal ne garde que les 30 plus gros éléments, si bien qu'un élément illisible peut ne pas y figurer ; le total signale tout de même une analyse partielle. La sortie JSON d'un dossier inclut tous les éléments analysés.

`mo analyze --json /path` inclut le statut `scan_status` (`complete`, `partial` ou `unavailable`) pour le résultat et pour chaque élément. Les tailles numériques correspondent aux octets mesurés ; un zéro avec `unavailable` ne signifie pas un dossier vide. Une analyse partielle se termine quand même avec le code 0 ; les scripts doivent donc vérifier `scan_status`. La complétude s'entend dans le cadre des exclusions d'analyse existantes de Mole et ne garantit pas un instantané atomique du système de fichiers.

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

### État du système (Status)

`mo status` affiche un tableau de bord en lecture seule pour le matériel, la charge système, l'activité disque, le trafic réseau, l'alimentation et les processus.

Lorsque la route IPv4 par défaut transite par un VPN ou un tunnel, le graphique réseau suit cette interface afin d'éviter tout double comptage du trafic avec la carte physique. La sortie JSON conserve le débit de chaque interface, y compris le tunnel routé ; les tunnels inactifs hors route par défaut restent masqués.

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

Le score de santé combine le CPU, la mémoire, l'espace disque, l'état SMART, les E/S, la température, la batterie et le temps de fonctionnement. Appuyez sur `k` pour basculer le chat animé, `c` pour modifier le nombre de cœurs affichés et `q` pour quitter ; vos préférences sont conservées.

<details>
<summary><strong>JSON, NDJSON et alertes de processus</strong></summary>

- `mo analyze --json ~/Documents` : renvoie un rapport d'analyse ponctuel au format JSON
- `mo status --json` : renvoie un instantané de l'état système au format JSON
- `mo status | jq '.health_score'` : passe automatiquement en mode JSON lorsqu'il est utilisé dans un pipeline
- `mo status --watch --interval 2s` : transmet un flux NDJSON (JSON délimité par des retours à la ligne)
- `mo history --json` : affiche l'historique des nettoyages au format JSON. Les sessions incluent `run_id` (une chaîne opaque, vide si aucune identité n'a été enregistrée) et `attribution` : `run` pour les exécutions identifiées, `command` pour l'ancien regroupement par commande, ou `ambiguous` quand les anciens marqueurs ne permettent pas de distinguer une interruption d'exécutions qui se chevauchent. Les actions enregistrées restent disponibles ; les décomptes ambigus ne peuvent pas être attribués de façon fiable à une exécution précise. Un `ended_at` vide signifie qu'aucun marqueur de fin n'a été enregistré.

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

La détection des processus zombies est en lecture seule ; elle n'interrompt aucun processus et n'altère pas le score de santé. Tant que Mole n'a obtenu aucun échantillon de processus, `process_collected_at`, `process_stale`, `zombie_count` et `zombie_parents_complete` sont omis et `zombie_parents` vaut `null`. Les instantanés fast/watch suivants réutilisent le dernier échantillon réussi avec son `process_collected_at` d'origine et définissent `process_stale: true` ; un nouvel échantillon le repasse à `false`. Une valeur de `0` signifie que Mole a mesuré et n'a trouvé aucun zombie. Le résumé des parents contient au plus trois propriétaires connus ; `zombie_parents_complete: false` signifie que l'attribution était indisponible, incomplète ou tronquée.

Si un collecteur rencontre une erreur, `mo status --json` affiche les métriques disponibles, consigne l'incident dans stderr et quitte avec le code 0, comme `--watch` qui continue de diffuser. Il quitte avec le code 1 uniquement si aucune métrique CPU, mémoire, disque ou processus n'est disponible, ou si la sortie JSON échoue.

Des alertes en lecture seule pour les processus monopolisant le processeur sont également disponibles ; réglez-les avec `--proc-cpu-threshold`, `--proc-cpu-window` ou `--proc-cpu-alerts=false`.

</details>

### Nettoyage de projets (Purge)

`mo purge` identifie les dossiers de build régénérables tels que `node_modules`, `target`, `.build`, `build` et `dist`. Ils sont regroupés par projet, et seuls les éléments confirmés sont supprimés définitivement, sans passer par la Corbeille. Les éléments modifiés au cours des 7 derniers jours, ou dont l'activité ne peut pas être vérifiée, sont décochés par défaut. Mole privilégie `fd` et se rabat sur `find` ; les dossiers contenant des clés de déploiement, des dépôts Git imbriqués ou des fichiers sous contrôle Git sont protégés. En mode non interactif, utilisez `mo purge --yes` ; prévisualisez d'abord avec `mo purge --dry-run`.

Utilisez Page Haut/Bas ou `h`/`l` pour changer de page, `[`/`]` pour naviguer entre les projets et `X` pour ignorer un projet et passer au suivant. `/` recherche dans les chemins de projet et les noms d'artefacts ; `n` passe à l'occurrence suivante sans modifier la sélection, et Entrée ouvre la vérification finale des chemins. L'espace indiqué est une estimation ; les artefacts non mesurés et les analyses incomplètes sont signalés explicitement.

<details>
<summary><strong>Exemple de sortie Purge</strong></summary>

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
<summary><strong>Chemins d'analyse personnalisés</strong></summary>

Lancez `mo purge --paths` pour sélectionner les répertoires à analyser, ou modifiez directement `~/.config/mole/purge_paths` :

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

Si des chemins personnalisés sont définis, Mole scanne exclusivement ces dossiers. Sinon, il utilise des chemins par défaut comme `~/Projects`, `~/GitHub`, `~/dev` et les dossiers de worktrees d'agents pris en charge. Un résultat de recherche incomplet n'est jamais enregistré. L'analyse des artefacts descend jusqu'à 6 niveaux sous chaque racine configurée ; pour des projets plus profonds, ajoutez une racine plus proche. Purge supprime les artefacts régénérables à l'intérieur des worktrees, jamais les worktrees eux-mêmes.

</details>

### Fichiers d'installation (Installer)

`mo installer` recherche les fichiers DMG, PKG, MPKG, ISO, XIP et ZIP d'installation dans Téléchargements, le Bureau, les caches Homebrew, iCloud, Mail, Telegram et d'autres emplacements pris en charge. Chaque élément affiche sa taille et sa provenance avant suppression. L'analyse dispose d'un délai d'expiration global ; si une analyse ou une lecture de métadonnées échoue ou expire, Mole abandonne la liste sans sélectionner de fichiers. Les archives ZIP corrompues ou illisibles sont ignorées, et les racines d'analyse en lien symbolique sont prises en charge, mais les liens symboliques situés en dessous ne sont pas suivis. Une ultime vérification est effectuée juste avant la suppression pour s'assurer que le fichier n'a pas changé.

<details>
<summary><strong>Exemple de sortie Installer</strong></summary>

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

## Lanceurs rapides

<details>
<summary><strong>Configuration pour Raycast et Alfred</strong></summary>

Installez en une commande cinq raccourcis rapides pour Clean, Uninstall, Optimize, Analyze et Status :

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

Le script installe les commandes Raycast et, si des préférences Alfred sont présentes, ajoute les flux de travail Alfred correspondants avec les mots-clés `clean`, `uninstall`, `optimize`, `analyze` et `status`.

Configuration requise dans Raycast :

1. Ouvrez les **Réglages Raycast > Extensions > Script Commands**.
2. Ajoutez `~/Library/Application Support/Raycast/script-commands` comme dossier de scripts.
3. Cliquez sur **Reload Script Directories**.

Les lanceurs reconnaissent automatiquement les principaux terminaux (Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm, Warp). Définissez `MO_LAUNCHER_APP=<nom>` pour choisir votre terminal, ou lancez Mole directement dans [Kaku](https://github.com/tw93/Kaku).

</details>

## Communauté

Merci à tous ceux qui contribuent au développement de Mole. Allez les suivre ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Contributeurs de Mole" width="1000" />
</a>

<br/><br/>
Retours authentiques d'utilisateurs sur X (Twitter) :

<img src="./docs/img/mole-love.png" alt="Retours de la communauté" width="1000" />

Vous préférez un tutoriel vidéo ? Regardez la [présentation de Mole](https://www.youtube.com/watch?v=UEe9-w4CcQ0) par PAPAYA 電腦教室.

## Soutenir le projet

- L'achat de [Mole for Mac](https://mole.fit) est le moyen le plus direct d'encourager le développement continu de Mole
- Si Mole vous rend service, laissez-lui une étoile sur GitHub, [partagez-le sur X](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) ou proposez une issue / PR
- J'ai deux chattes, TangYuan et Coke, et si Mole vous simplifie la vie, n'hésitez pas à leur offrir <a href="https://cats.tw93.fun?name=Mole" target="_blank">une boîte de pâtée 🥩</a>

<details>
<summary>Ceux qui ont déjà régalé les chats 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="Donateurs de Mole" width="1000" loading="lazy" /></a>
</details>

## Licence

Mole est un logiciel libre distribué sous licence GPL-3.0 ; voir [LICENSE](LICENSE). Toute version modifiée et redistribuée doit conserver cette même licence. En cas de fork, veuillez utiliser un nom distinct et mentionner Mole comme projet d'origine. [Mole for Mac](https://mole.fit) est une application propriétaire distincte. Mole est là pour durer.
