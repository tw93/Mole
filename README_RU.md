<p align="right"><b>macOS</b> · <a href="https://github.com/tw93/Mole/tree/windows">Windows</a></p>

<div align="center">
  <h1>Mole</h1>
  <p><b>Глубокая очистка, удаление приложений, оптимизация, анализ диска и мониторинг вашего Mac. Бесплатный CLI с открытым исходным кодом, а также нативное приложение для Mac.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a> · Русский</p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Результаты очистки Mole" width="1000" />
</p>

> 💡 В этом репозитории живёт бесплатный CLI с открытым исходным кодом (`mo`). Нужно нативное приложение? [Mole for Mac](https://mole.fit/) загружается отдельно: очистка с просмотром перед удалением, проверенные остаточные файлы для более чем 800 приложений, обслуживание системы, детальный разбор диска, состояние системы в реальном времени и управление вентиляторами на поддерживаемых Mac. Для Windows есть нативное приложение [Mole for Windows](https://mole.fit/windows). `brew install mole` устанавливает только CLI.

## Возможности

- **Всё в одном CLI**: объединяет сценарии в духе CleanMyMac, AppCleaner, DaisyDisk и iStat Menus в одной команде терминала
- **Глубокая очистка**: удаляет кеши, журналы, остаточные файлы и осиротевшие данные приложений, освобождая место на диске
- **Умное удаление приложений**: удаляет приложения вместе с LaunchAgents, настройками и остаточными файлами
- **Анализ диска**: наглядно показывает, чем занят диск, в интерактивном TUI, находит крупные файлы и позволяет переходить между каталогами
- **Обслуживание системы**: сбрасывает кеш DNS, обновляет QuickLook и значки, оптимизирует системные базы данных
- **Мониторинг в реальном времени**: показывает загрузку CPU, память, дисковый I/O, сетевой трафик и статистику процессов

## Быстрый старт

Mole требует macOS 12 или новее и работает на Mac с процессорами Intel и Apple Silicon. Если Homebrew больше не поддерживает вашу версию macOS, воспользуйтесь установкой через скрипт.

**Установка через Homebrew**

```bash
brew install mole
```

**Или через скрипт**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**В Windows** ([Windows CLI](https://github.com/tw93/Mole/tree/windows))

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole распространяется только через Homebrew, этот репозиторий на GitHub и [mole.fit](https://mole.fit/) (приложения под Mac и Windows). Сайты, которые предлагают приложение «на основе Mole» или просят вставить в Терминал закодированную команду, не имеют к Mole никакого отношения.

**Запуск**

```bash
mo                           # Интерактивное меню
mo clean                     # Глубокая очистка + остатки уже удалённых приложений
mo uninstall                 # Удалить установленные приложения вместе с их остатками
mo optimize                  # Обновить кеши и службы
mo analyze                   # Наглядный обозреватель диска (или 'mo analyse')
mo status                    # Панель состояния системы в реальном времени
mo purge                     # Удалить артефакты сборки проектов
mo installer                 # Найти и удалить файлы установщиков

mo touchid                   # Настроить Touch ID для sudo
mo completion                # Настроить автодополнение в командной оболочке
mo update                    # Обновить Mole
mo update --nightly          # Обновить до свежей сборки из main (только для установки скриптом)
mo remove                    # Удалить Mole из системы
mo --help                    # Показать справку
mo --version                 # Показать установленную версию
```

**Безопасный предпросмотр**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Предпросмотр + подробные журналы
mo optimize --whitelist      # Управление защищёнными правилами оптимизации
mo clean --whitelist         # Управление защищёнными кешами
mo purge --paths             # Настроить каталоги для поиска проектов
mo analyze /Volumes          # Анализировать только внешние диски
mo analyze /private/tmp      # Просмотреть временные каталоги пользователя
```

<details>
<summary><strong>Другие способы установки</strong></summary>

Чтобы установить конкретный выпуск, передайте любой тег со [страницы релизов](https://github.com/tw93/mole/releases), с ведущей `V` или без неё. Чтобы следить за веткой разработки, передайте `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` устанавливает невыпущенный код из ветки по умолчанию, поэтому возможны шероховатости. `latest` по-прежнему работает как устаревший псевдоним для `main`; несмотря на название, он не устанавливает новейший стабильный выпуск.

Обычно скрипт устанавливает Mole в `/usr/local/bin`, из-за чего может потребоваться пароль администратора. Установите его в каталог, принадлежащий вашему пользователю, если хотите, чтобы будущие запуски `mo update` обходились без пароля:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Добавьте такой же экспорт `PATH` в `~/.zshrc` или в профиль вашей оболочки, чтобы он действовал и в новых терминалах. Mole обновляет именно тот экземпляр, который вы запустили, поэтому он продолжит использовать этот каталог. Команды, изменяющие системные файлы, всё же могут запросить права администратора.

**Nix**

На macOS пользователи Nix могут установить flake из ветки `main`, где есть невыпущенные изменения:

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

Для декларативной установки добавьте `github:tw93/mole/main` как flake input и используйте пакет `packages.${system}.mole`. Обновляйте и удаляйте Mole через Nix: `mo update` и `mo remove` не меняют установки, которыми управляет Nix.

</details>

## Безопасность

Mole умеет удалять файлы, поэтому он проверяет пути, защищает общие и системные расположения и запрашивает подтверждение, когда действие того требует. Если Mole не может убедиться, что объект безопасно изменять, он пропускает его или отказывается от действия.

- `clean`, `uninstall`, `purge`, `installer` и `remove` могут удалять файлы, поэтому сначала просматривайте их с `--dry-run`, а при необходимости добавляйте `--debug`
- Запускайте Mole без `sudo`: он запрашивает права администратора только тогда, когда они действительно нужны
- `mo analyze` перемещает выбранные объекты в Корзину после подтверждения
- Действия по очистке записываются в `~/Library/Logs/mole/operations.log`; просмотреть их можно командой `mo history`, а отключить запись можно переменной `MO_NO_OPLOG=1`
- Защищайте кеши через `mo clean --whitelist`, а задачи обслуживания через `mo optimize --whitelist`

Загляните в [SECURITY.md](SECURITY.md) и [SECURITY_AUDIT.md](SECURITY_AUDIT.md), чтобы узнать, как сообщать о проблемах, какие границы безопасности действуют и какие ограничения есть сейчас.

## Подробнее о возможностях

Примеры ниже сокращены. Доступные пункты, размеры и причины пропуска зависят от вашего Mac.

### Очистка (Clean)

`mo clean` просматривает заведомо безопасные кеши, журналы, временные файлы, артефакты инструментов разработки и остатки приложений, которые уже не установлены. По умолчанию команда очищает Корзину; чтобы сохранить её содержимое, отметьте строку Trash в `mo clean --whitelist`, в том же меню, где защищаются нужные вам кеши. Выбор сохраняется в `~/.config/mole/whitelist`. Прежде чем добавлять собственные пути, откройте меню и нажмите Enter, чтобы сохранить выбор, а затем допишите пути по одному в строке. Существующий файл заменяет необязательные значения по умолчанию, но встроенная защита продолжает действовать.

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

### Удаление приложений (Uninstall)

`mo uninstall` удаляет установленное приложение вместе со связанными файлами, которые Mole может уверенно отнести к этому приложению. Общие данные сохраняются, если их всё ещё использует другая установленная копия. Если приложение уже удалено, поищите его остатки командой `mo clean`.

Личные данные, включая настройки и плагины, по умолчанию сохраняются. Нажмите `D` в предварительном просмотре удаления, чтобы выбрать отдельные пути данных. После удаления ссылки на исчезнувшие пути в конфигурациях shell, Hook или MCP показываются только как имя файла и номер строки; Mole не изменяет эти конфигурации.

```text
$ mo uninstall

Select Apps to Remove  1/3 selected

➤ ● Photoshop 2024                4.20GB | 2mo ago
  ○ IntelliJ IDEA                 2.80GB | 3d ago
  ○ Premiere Pro                  3.40GB | 2w ago

Files to be removed:

✓ Photoshop 2024, 4.20GB
  ✓ /Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app

Personal data kept:
  ~/Library/Application Support/Adobe/Adobe Photoshop 2024
  ~/Library/Preferences/com.adobe.Photoshop.plist

D choose personal data

======================================================================
Uninstall complete
Removed 1 app, freed 4.20GB: Photoshop 2024
======================================================================
```

### Оптимизация (Optimize)

`mo optimize` выполняет ограниченный набор задач обслуживания для поддерживаемых служб Finder, сети, баз данных и macOS. Задачи, которые не нужны, небезопасны в данный момент или недоступны, пропускаются с указанием причины. С помощью `mo optimize --whitelist` можно исключить отдельные задачи или шаблоны путей, например, постоянно смонтированный образ диска в `/Volumes/mail`, который не должен попадать в кандидаты на отключение.

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

### Анализ диска (Analyze)

`mo analyze` открывает обозреватель диска прямо в терминале. Он поддерживает стрелки и навигацию в стиле Vim, фильтрацию, выбор нескольких объектов, предпросмотр в Finder и перемещение в Корзину после подтверждения. Внешние диски не попадают в обзор по умолчанию; чтобы их проверить, используйте `mo analyze /Volumes` или укажите конкретную точку монтирования. Команда `mo analyze /private/tmp` позволяет просмотреть временные файлы пользователя, не превращая их в цели автоматической очистки.

Размер, оканчивающийся на `+`, содержит измеренные байты неполного сканирования; `unknown` означает, что размер измерить не удалось. Результаты, оборванные временными сбоями вроде тайм-аутов, не заменяют собой полные измерения из кеша, а следующее обновление может восстановить недостающие данные. Папки, которые macOS не даёт прочитать из терминала, остаются неполными, пока не изменятся права доступа. Список в терминале хранит 30 крупнейших записей, поэтому нечитаемая запись может в него не попасть; при этом итог всё равно укажет на неполное сканирование. Вывод каталога в JSON включает все просканированные записи.

`mo analyze --json /path` добавляет поле `scan_status` как к результату, так и к каждой записи: `complete`, `partial` или `unavailable`. Числовые размеры содержат измеренные байты; ноль вместе с `unavailable` не означает, что каталог пуст. Неполное сканирование всё равно завершается успешно, поэтому автоматизации следует проверять `scan_status`. Полнота определяется в рамках уже действующих исключений сканирования Mole и не гарантирует атомарный снимок файловой системы.

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

### Состояние системы (Status)

`mo status` представляет собой панель, работающая только на чтение: она показывает оборудование, нагрузку на систему, активность диска, сетевой трафик, питание и процессы.

Если маршрут IPv4 по умолчанию проходит через туннель, графики сети строятся по скорости этого интерфейса, чтобы не учитывать тот же трафик повторно на физическом носителе. В JSON сохраняются скорости по каждому интерфейсу, включая маршрутизируемый туннель; неактивные туннели, не используемые по умолчанию, остаются скрытыми.

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

Оценка состояния объединяет CPU, память, занятость диска, статус SMART, I/O, температуру, состояние батареи и время работы системы, а диапазоны выделяются цветом. Нажмите `k`, чтобы показать или скрыть кота, `c`, чтобы изменить число отображаемых ядер CPU, и `q`, чтобы выйти; настройки отображения сохраняются.

<details>
<summary><strong>JSON, NDJSON и оповещения о процессах</strong></summary>

- `mo analyze --json ~/Documents` возвращает разовый отчёт о диске в формате JSON
- `mo status --json` возвращает разовый снимок состояния в формате JSON
- `mo status | jq '.health_score'` автоматически переключается на JSON, когда вывод передаётся по конвейеру
- `mo status --watch --interval 2s` транслирует JSON, разделённый переводами строк (NDJSON), из уже прогретого сборщика данных
- `mo history --json` возвращает историю очистки в формате JSON. Сессии содержат `run_id` (непрозрачная строка, пустая, если идентификатор не записывался) и `attribution`: `run` для опознанных запусков, `command` для устаревшей группировки по командам или `ambiguous`, когда по старым меткам невозможно отличить прерывание от перекрывающихся запусков. Записанные действия остаются доступными, но неоднозначные счётчики нельзя надёжно отнести к отдельным запускам. Пустое `ended_at` означает, что метка завершения не записана

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

Диагностика процессов-зомби работает только на чтение: она не влияет на оценку состояния и не завершает процессы. Пока Mole не получит первую успешную выборку процессов, поля `process_collected_at`, `process_stale`, `zombie_count` и `zombie_parents_complete` отсутствуют, а `zombie_parents` имеет значение `null`. Последующие быстрые снимки и снимки в режиме `--watch` повторно используют последнюю успешную выборку с её исходным `process_collected_at` и выставляют `process_stale: true`; свежая выборка процессов выставляет `false`. Значение `0` означает, что Mole выполнил измерение и не нашёл ни одного зомби. Сводка по родительским процессам содержит не более трёх известных владельцев; `zombie_parents_complete: false` означает, что определить принадлежность не удалось, удалось лишь частично или список был обрезан.

Если один из сборщиков данных даёт сбой, `mo status --json` всё равно выводит собранные метрики, сообщает о сбое в stderr и завершается успешно, так же, как `--watch` продолжает трансляцию. Код выхода 1 возвращается только тогда, когда недоступна ни одна из метрик CPU, памяти, диска и процессов или когда не удалось вывести JSON.

Status также умеет сообщать о процессах, не вмешиваясь в их работу,, которые долго держатся выше порога загрузки CPU. Настроить или отключить такие оповещения можно через `--proc-cpu-threshold`, `--proc-cpu-window` или `--proc-cpu-alerts=false`.

</details>

### Очистка проектов (Purge)

`mo purge` находит артефакты проектов, которые можно собрать заново: `node_modules`, `target`, `.build`, `build` и `dist`. Он группирует артефакты по проектам и безвозвратно удаляет только то, что вы подтвердили. Артефакты, файлы которых менялись за последние 7 дней, а также те, активность которых Mole не может проверить, по умолчанию не выбраны. Mole использует `fd`, если он доступен, а иначе переходит к `find`, и защищает каталоги с файлами ключевых пар для развёртывания, вложенными репозиториями Git и файлами под контролем Git. Неинтерактивный запуск требует `mo purge --yes`; чтобы сначала просмотреть кандидатов, используйте `mo purge --dry-run`.

Page Up/Down или `h`/`l` листают страницу, `[`/`]` перемещают между проектами, а `X` пропускает проект и переходит к следующему. `/` ищет по путям проектов и названиям артефактов, `n` находит следующее совпадение, не меняя выбор, а Enter открывает финальный просмотр путей. Указанный объём является оценкой; неизмеренные артефакты и неполные сканирования отмечаются явно.

<details>
<summary><strong>Пример вывода purge</strong></summary>

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
<summary><strong>Собственные пути сканирования</strong></summary>

Выполните `mo purge --paths`, чтобы настроить каталоги сканирования, или отредактируйте `~/.config/mole/purge_paths` напрямую:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

Если заданы собственные пути, Mole сканирует только эти каталоги. Иначе он использует значения по умолчанию: `~/Projects`, `~/GitHub`, `~/dev` и поддерживаемые контейнеры worktree агентов. Неполный результат поиска не сохраняется. Сканирование артефактов опускается на шесть уровней ниже каждого заданного корня; для более глубоко вложенных проектов добавьте более близкий корень. Purge удаляет пересобираемые артефакты внутри worktree, но никогда не удаляет сами worktree.

</details>

### Файлы установщиков (Installer)

`mo installer` находит файлы DMG, PKG, MPKG, ISO, XIP и ZIP-установщики в Загрузках, на Рабочем столе, в кешах Homebrew, iCloud, Mail, Telegram и других поддерживаемых расположениях и перед удалением показывает размер и источник каждого объекта. На поиск отведён суммарный лимит времени: если сканирование или запрос метаданных завершается ошибкой или тайм-аутом, Mole отбрасывает список и выходит, ничего не выбрав. Повреждённые и нечитаемые ZIP-архивы пропускаются; корни сканирования, заданные символьными ссылками, поддерживаются, но ссылки внутри них не раскрываются, а выбранные файлы на границе удаления повторно сверяются с подтверждённой идентичностью.

<details>
<summary><strong>Пример вывода installer</strong></summary>

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

## Быстрый запуск

<details>
<summary><strong>Настройка Raycast и Alfred</strong></summary>

Установите пять команд быстрого запуска для Clean, Uninstall, Optimize, Analyze и Status:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

Скрипт добавляет команды Raycast, а если найдёт настройки Alfred, то и соответствующие рабочие процессы Alfred с ключевыми словами `clean`, `uninstall`, `optimize`, `analyze` и `status`.

Для Raycast нужно одно ручное действие:

1. Откройте **Raycast Settings > Extensions > Script Commands**.
2. Добавьте `~/Library/Application Support/Raycast/script-commands` как каталог со скриптами.
3. Выполните в Raycast **Reload Script Directories**.

Команды сами определяют Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm и Warp. Чтобы выбрать конкретный терминал, задайте `MO_LAUNCHER_APP=<name>`; также Mole можно запускать прямо в [Kaku](https://github.com/tw93/Kaku).

</details>

## Сообщество

Спасибо всем, кто помогал создавать Mole. Подпишитесь на них! ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Контрибьюторы Mole" width="1000" />
</a>

<br/><br/>
Настоящие отзывы пользователей, которые рассказывали о Mole в X.

<img src="./docs/img/mole-love.png" alt="Отзывы сообщества о Mole" width="1000" />

Посмотрите [видеоурок о Mole](https://www.youtube.com/watch?v=UEe9-w4CcQ0) от PAPAYA 電腦教室.

## Поддержать проект

- Самый прямой способ поддержать разработку Mole: приобрести [Mole for Mac](https://mole.fit)
- Если Mole вам помог, поставьте звезду, [расскажите о нём](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) или откройте issue либо PR
- У меня двое котов, TangYuan и Coke; если Mole хоть немного облегчил вам жизнь, можете угостить их <a href="https://cats.tw93.fun?name=Mole" target="_blank">консервами 🥩</a>

<details>
<summary>Эти замечательные люди уже угостили 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="Спонсоры Mole" width="1000" loading="lazy" /></a>
</details>

## Лицензия

Mole представляет собой программное обеспечение с открытым исходным кодом под лицензией GPL-3.0; подробности в [LICENSE](LICENSE). Любая изменённая версия, которую вы распространяете, должна оставаться под той же лицензией. Если вы делаете форк Mole, пожалуйста, дайте ему другое название и укажите Mole как первоисточник. [Mole for Mac](https://mole.fit) является отдельным проприетарным приложением, а Mole здесь надолго.
