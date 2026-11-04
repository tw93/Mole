<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <img src="./docs/img/mole-logo.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Windows</h1>
  <p><b>Nettoyage en profondeur, désinstallation d'apps, optimisation, analyse de disque et surveillance de votre PC Windows. CLI open source gratuite.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · Français · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Menu de Mole CLI for Windows" width="1000" />
</p>

> 💡 Cette branche contient la CLI Windows open source gratuite (`mo`). Vous préférez une app native ? [Mole for Windows](https://mole.fit/fr/windows) se télécharge séparément : nettoyage avec vérification avant suppression, mises à jour des applications, gestion du démarrage, exploration détaillée du disque et état en direct. La CLI macOS se trouve sur la [branche main](https://github.com/tw93/Mole#readme).

## Fonctionnalités

- **Boîte à outils CLI tout-en-un** : combine les usages façon CCleaner, IObit Uninstaller, WinDirStat et Gestionnaire des tâches dans une seule commande de terminal
- **Nettoyage en profondeur** : supprime les fichiers temporaires, caches, journaux et résidus des navigateurs pour libérer de l'espace disque
- **Désinstalleur intelligent** : supprime les applications avec leurs dossiers d'installation résiduels
- **Analyseur de disque** : explore l'espace disque via une interface TUI interactive et repère les gros fichiers
- **Maintenance système** : purge le cache DNS, optimise le disque système et vérifie l'état du disque
- **Surveillance en direct** : affiche en temps réel le processeur, la mémoire, les E/S disque, le réseau et les processus

## Démarrage rapide

Mole fonctionne sous Windows 10 et 11 avec Windows PowerShell 5.1 intégré. L'installation par script nécessite Git et, quand les sources diffèrent de la dernière version publiée, Go pour compiler les outils natifs. Il s'installe dans `%LOCALAPPDATA%\Programs\mole-cli` et ajoute `mo` et `mole` à votre PATH.

**Installation via Scoop**

```powershell
scoop install mole
```

**Ou via le script d'installation**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole est distribué uniquement via ce dépôt GitHub, Scoop et [mole.fit](https://mole.fit/fr/windows) pour l'app Windows. Les sites qui proposent une app « basée sur Mole » ou vous demandent de coller une commande encodée dans un terminal n'ont aucun lien avec Mole.

**Avec un agent IA**

Dites à votre agent :

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

Ou installez le skill vous-même. Avec lui, Claude Code, Codex, Cursor et les autres agents vous montrent chaque nettoyage avec `--dry-run` avant de supprimer quoi que ce soit, et vous laissent les désinstallations d'apps et les étapes administrateur. Mise à jour avec `npx skills update -g -y`.

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

En plugin de l'hôte : dans Claude Code `/plugin marketplace add tw93/Mole` puis `/plugin install mole@mole`, dans Codex `codex plugin marketplace add tw93/Mole` puis `codex plugin add mole@mole`.

**Commandes principales**

```powershell
mo                           # Menu interactif
mo clean                     # Nettoyage en profondeur
mo uninstall                 # Désinstaller des applications + leurs résidus
mo optimize                  # Actualiser les caches et services
mo analyze                   # Explorateur visuel de disque
mo status                    # Tableau de bord de santé système en direct
mo purge                     # Nettoyer les fichiers de build de projets

mo update                    # Mettre à jour Mole
mo remove                    # Supprimer Mole de ce PC
mo --help                    # Afficher l'aide
mo --version                 # Afficher la version installée
```

**Aperçu sans risque (Dry Run)**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Aperçu + journaux détaillés
mo clean --whitelist         # Gérer les chemins protégés
mo clean --system            # Inclure le nettoyage au niveau système (exécuter en tant qu'administrateur)
mo purge --paths             # Configurer les dossiers de scan de projets
mo analyze D:\               # Analyser un autre disque
mo uninstall --list          # Lister les apps installées, en JSON via un pipe
mo analyze --json D:\        # Rapport disque au format JSON
```

<details>
<summary><strong>Autres options d'installation</strong></summary>

Pour examiner le code avant l'installation, clonez la branche `windows` et lancez l'installateur sur place. Il conserve `.git`, ce qui permet à `mo update` de fonctionner par la suite :

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

Ajoutez `-CreateShortcut` pour créer une entrée dans le menu Démarrer. Pour désinstaller, lancez `mo remove`.

</details>

## Sécurité

Mole peut supprimer des fichiers ; il valide donc les chemins et protège les emplacements du système et du profil. `uninstall`, `purge` et `remove` demandent une confirmation avant de supprimer quoi que ce soit. Quand Mole ne peut pas prouver qu'un élément peut être modifié sans risque, il l'ignore.

- `clean`, `uninstall` et `purge` suppriment des fichiers : prévisualisez toujours leurs actions avec `--dry-run`, complété au besoin de `--debug`
- `clean` et `purge` suppriment définitivement ; les restes vérifiés d'`uninstall` vont dans la Corbeille, le désinstalleur de l'application conserve son propre comportement, et les fichiers supprimés dans `mo analyze` vont aussi dans la Corbeille, sauf les éléments trop volumineux pour elle, que Windows propose de supprimer définitivement
- Exécutez Mole avec votre compte utilisateur habituel ; les étapes au niveau système sont ignorées sauf si PowerShell est lancé en tant qu'administrateur
- Protégez des chemins avec `mo clean --whitelist`
- Les opérations de nettoyage sont consignées dans `%USERPROFILE%\.config\mole\operations.log` ; consultez-les avec `mo history` ou désactivez la journalisation avec `MO_NO_OPLOG=1`
- `C:\Windows`, `C:\Program Files`, les dossiers de Windows Defender et la racine de votre profil ne sont jamais modifiés

Consultez [SECURITY.md](SECURITY.md) pour la marche à suivre en cas de vulnérabilité et les limites de sécurité.

## Détail des fonctionnalités

Les captures suivantes proviennent d'un PC de test. Les éléments détectés et les tailles dépendent de votre PC.

### Nettoyage (Clean)

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="Aperçu de mo clean --dry-run" width="736" />

La liste détaillée contient tous les chemins trouvés par l'aperçu. Copiez-en dans la liste blanche pour les conserver.

### Désinstallation (Uninstall)

```powershell
mo uninstall
```

Liste les programmes installés à partir du registre et des applications Windows, du plus volumineux au plus petit, puis supprime ceux que vous choisissez avec leur propre désinstalleur et nettoie le dossier d'installation résiduel. `mo uninstall --dry-run` indique quel désinstalleur serait utilisé pour chaque application et ce qui serait supprimé, sans rien exécuter.

<img src="./docs/img/uninstall-windows.png" alt="Liste des apps de mo uninstall" width="1000" />

### Optimisation (Optimize)

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="Aperçu de mo optimize --dry-run" width="736" />

Certaines étapes, comme l'optimisation du disque et la purge du cache ARP, nécessitent un accès administrateur et sont ignorées sans lui ; lancez PowerShell en tant qu'administrateur pour les inclure.

### Analyse de l'espace (Analyze)

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="Vue d'ensemble de mo analyze" width="1000" />

Un explorateur de disque interactif avec la même disposition que la version macOS : les touches fléchées parcourent les dossiers, `Backspace` revient en arrière, `T` liste les plus gros fichiers et `Del` déplace les éléments sélectionnés vers la Corbeille après confirmation.

### État du système (Status)

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="Tableau de bord de mo status" width="1000" />

Un tableau de bord en direct avec un score de santé, le processeur, la mémoire, le disque, l'alimentation, le réseau et les processus les plus actifs.

### Nettoyage de projets (Purge)

```powershell
mo purge --dry-run
```

Repère les artefacts de build (`node_modules`, `target`, `build`, `dist`, `venv`, et plus) dans vos dossiers de projets et vous laisse choisir les projets à nettoyer ; rien n'est sélectionné tant que vous n'avez pas choisi. Configurez les dossiers analysés avec `mo purge --paths`.

## Communauté

Merci à tous ceux qui contribuent au développement de Mole. Allez les suivre ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Contributeurs de Mole" width="1000" />
</a>

## Soutenir le projet

- L'achat de [Mole for Windows](https://mole.fit/fr/windows) est le moyen le plus direct d'encourager le développement continu de Mole
- Si Mole vous rend service, laissez-lui une étoile, [partagez-le](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.) ou proposez une issue / PR
- Les contributions sont les bienvenues ; lisez d'abord [CONTRIBUTING.md](CONTRIBUTING.md)
- J'ai deux chattes, TangYuan et Coke, et si Mole vous simplifie la vie, n'hésitez pas à leur offrir <a href="https://cats.tw93.fun?name=Mole" target="_blank">une boîte de pâtée 🥩</a>

## Licence

Mole est un logiciel libre distribué sous licence GPL-3.0 ; voir [LICENSE](LICENSE). Toute version modifiée et redistribuée doit conserver cette même licence. En cas de fork, veuillez utiliser un nom distinct et mentionner Mole comme projet d'origine ; voir [TRADEMARK.md](TRADEMARK.md).
