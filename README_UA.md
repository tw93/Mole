<div align="center">
  <h1>Mole</h1>
  <p><b>Глибоке очищення, видалення застосунків, оптимізація, аналіз диска й моніторинг вашого Mac. Безкоштовний CLI з відкритим кодом, а також нативний застосунок для Mac.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · Українська</p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Результати очищення Mole" width="1000" />
</p>

> 💡 Цей репозиторій — безкоштовний CLI з відкритим кодом (`mo`). Хочете нативний застосунок? [Mole for Mac](https://mole.fit/) завантажується окремо: перегляд перед видаленням, перевірене прибирання залишків для понад 800 застосунків, обслуговування системи, детальний розбір диска, стан у реальному часі та керування вентиляторами на підтримуваних Mac. `brew install mole` встановлює лише CLI.

## Можливості

- **Усе в одному CLI**: поєднує сценарії в дусі CleanMyMac, AppCleaner, DaisyDisk та iStat Menus в одній команді термінала
- **Глибоке очищення**: видаляє кеші, журнали, залишки й осиротілі дані застосунків, щоб звільнити місце на диску
- **Розумне видалення застосунків**: прибирає застосунки разом із LaunchAgents, налаштуваннями та залишками
- **Аналіз диска**: наочно показує, чим зайнятий диск, в інтерактивному TUI, знаходить великі файли й дає змогу ходити між теками
- **Обслуговування системи**: скидає кеш DNS, оновлює QuickLook та іконки, оптимізує системні бази даних
- **Моніторинг у реальному часі**: показує навантаження на CPU, пам'ять, дисковий I/O, мережевий трафік і процеси

## Швидкий старт

Mole потребує macOS 12 або новішої версії й працює на Mac з процесорами Intel та Apple Silicon. Якщо Homebrew більше не підтримує вашу версію macOS, встановіть Mole скриптом. Експериментальна версія для Windows розвивається в [гілці windows](https://github.com/tw93/Mole/tree/windows).

**Встановлення через Homebrew**

```bash
brew install mole
```

**Або скриптом**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**Запуск**

```bash
mo                           # Інтерактивне меню
mo clean                     # Глибоке очищення + залишки вже видалених застосунків
mo uninstall                 # Видалити встановлені застосунки разом із залишками
mo optimize                  # Оновити кеші та служби
mo analyze                   # Наочний огляд диска (або 'mo analyse')
mo status                    # Панель стану системи в реальному часі
mo purge                     # Прибрати артефакти збирання проєктів
mo installer                 # Знайти й видалити інсталятори

mo touchid                   # Налаштувати Touch ID для sudo
mo completion                # Налаштувати автодоповнення в оболонці
mo update                    # Оновити Mole
mo update --nightly          # Оновити до свіжої збірки з main (лише для встановлення скриптом)
mo remove                    # Видалити Mole із системи
mo --help                    # Показати довідку
mo --version                 # Показати встановлену версію
```

**Безпечний попередній перегляд**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Попередній перегляд + докладні журнали
mo optimize --whitelist      # Керувати захищеними правилами оптимізації
mo clean --whitelist         # Керувати захищеними кешами
mo purge --paths             # Налаштувати теки для пошуку проєктів
mo analyze /Volumes          # Аналізувати лише зовнішні диски
mo analyze /private/tmp      # Переглянути тимчасові теки користувача
```

<details>
<summary><strong>Інші способи встановлення</strong></summary>

Щоб встановити конкретний реліз, передайте будь-який тег зі [сторінки релізів](https://github.com/tw93/mole/releases), з початковою `V` або без неї. Щоб стежити за гілкою розробки, передайте `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` встановлює ще не випущений код з основної гілки, тож можливі шорсткості. `latest` досі працює як застарілий псевдонім для `main`: попри назву, він не встановлює найновіший стабільний реліз.

Зазвичай скрипт встановлює Mole до `/usr/local/bin`, тож може попросити пароль адміністратора. Якщо хочете, щоб наступні запуски `mo update` обходилися без пароля, встановіть Mole в теку, що належить вашому користувачу:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Додайте той самий експорт `PATH` до `~/.zshrc` або профілю вашої оболонки, щоб він працював і в нових вікнах термінала. Mole оновлює саме ту інсталяцію, яку ви запустили, тож і надалі користуватиметься цією текою. Команди, що змінюють системні файли, однаково можуть запитувати права адміністратора.

**Nix**

У macOS користувачі Nix можуть встановити flake з `main`, де вже є ще не випущені зміни:

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

Для декларативного встановлення додайте `github:tw93/mole/main` як вхід flake і використовуйте його пакет `packages.${system}.mole`. Оновлюйте й видаляйте Mole через Nix: `mo update` і `mo remove` не чіпають інсталяції, якими керує Nix.

</details>

## Безпека

Mole вміє видаляти файли, тому перевіряє шляхи, захищає спільні й системні розташування та просить підтвердження, коли дія цього потребує. Якщо Mole не може довести, що елемент безпечно змінювати, він його пропускає або відмовляється з ним працювати.

- `clean`, `uninstall`, `purge`, `installer` і `remove` можуть видаляти файли, тож спершу перегляньте, що саме зміниться, з `--dry-run`, а за потреби додайте `--debug`
- Запускайте Mole без `sudo`: права адміністратора він запитує лише тоді, коли вони справді потрібні
- `mo analyze` переміщує вибрані елементи до Смітника лише після підтвердження
- Дії з очищення записуються до `~/Library/Logs/mole/operations.log`; переглянути їх можна через `mo history`, а вимкнути запис — змінною `MO_NO_OPLOG=1`
- Захищайте кеші через `mo clean --whitelist`, а завдання обслуговування — через `mo optimize --whitelist`

Як повідомити про вразливість, де пролягають межі безпеки й які обмеження діють зараз, описано в [SECURITY.md](SECURITY.md) і [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

## Докладніше про можливості

Наведені нижче приклади скорочено. Доступні елементи, розміри й причини пропуску залежать від вашого Mac.

### Очищення (Clean)

`mo clean` перевіряє кеші, журнали, тимчасові файли, артефакти інструментів розробки та залишки вже видалених застосунків, які точно безпечно прибрати. Типово команда спорожнює Смітник; щоб зберегти його вміст, позначте рядок Trash у `mo clean --whitelist` — у тому самому меню, де захищаються потрібні вам кеші. Вибір зберігається у `~/.config/mole/whitelist`. Перш ніж додавати власні шляхи, відкрийте меню й натисніть Enter, щоб зберегти вибір, а тоді допишіть шляхи — по одному в рядку. Наявний файл замінює необов'язкові типові налаштування, але вбудований захист діє однаково.

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

### Видалення застосунків (Uninstall)

`mo uninstall` видаляє встановлений застосунок разом із пов'язаними файлами, які Mole може однозначно до нього прив'язати. Спільні дані лишаються на місці, якщо ними ще користується інша встановлена копія. Якщо застосунок уже видалено, шукайте залишки через `mo clean`.

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

### Оптимізація (Optimize)

`mo optimize` виконує чітко окреслене обслуговування підтримуваних служб Finder, мережі, баз даних і macOS. Завдання, які зараз непотрібні, небезпечні чи недоступні, пропускаються з поясненням причини. Через `mo optimize --whitelist` можна виключити завдання або шаблони шляхів — наприклад, образ диска, що постійно змонтований у `/Volumes/mail` і не має потрапляти до кандидатів на від'єднання.

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

### Аналіз диска (Analyze)

`mo analyze` відкриває провідник диска просто в терміналі. Він підтримує навігацію стрілками й клавішами Vim, фільтрування, вибір кількох елементів, попередній перегляд у Finder і переміщення до Смітника з підтвердженням. Зовнішні диски до типового огляду не потрапляють; перевіряйте їх через `mo analyze /Volumes` або конкретну точку монтування. Команда `mo analyze /private/tmp` дає змогу переглянути тимчасові файли користувача, не перетворюючи їх на цілі автоматичного очищення.

Розмір із `+` у кінці містить байти, виміряні під час часткового сканування; `unknown` означає, що розмір виміряти не вдалося. Результати, перервані тимчасовими збоями на кшталт тайм-аутів, не замінюють повних вимірювань у кеші, а наступне оновлення може дозібрати відсутні дані. Теки, які macOS не дозволяє терміналу читати, лишаються частковими, доки не зміниться доступ. Список у терміналі показує 30 найбільших елементів, тож нечитабельний елемент може до нього не потрапити, але загальний підсумок однаково вкаже на часткове сканування. JSON-вивід для теки містить усі проскановані елементи.

`mo analyze --json /path` додає `scan_status` до результату й до кожного елемента: `complete`, `partial` або `unavailable`. Числові розміри містять виміряні байти; нуль зі статусом `unavailable` не означає, що тека порожня. Часткове сканування однаково завершується успішно, тож автоматизація має перевіряти `scan_status`. Повнота рахується в межах наявних винятків сканування Mole і не гарантує атомарного знімка файлової системи.

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

### Стан системи (Status)

`mo status` — панель лише для читання, яка показує обладнання, навантаження на систему, активність дисків, мережевий трафік, живлення та процеси.

Коли типовий маршрут IPv4 проходить через тунель, мережеві графіки беруть швидкості саме цього інтерфейсу, щоб не рахувати той самий трафік удруге на фізичному інтерфейсі під ним. JSON зберігає швидкості кожного інтерфейсу, зокрема й тунелю, через який іде маршрут; неактивні тунелі, що не є типовими, приховано.

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

Оцінка здоров'я системи враховує CPU, пам'ять, заповненість диска, стан SMART, I/O, температуру, стан батареї та час роботи без перезавантаження, а діапазони позначено кольорами. Натисніть `k`, щоб показати чи сховати кота, `c` — щоб змінити кількість показаних ядер CPU, або `q` — щоб вийти; налаштування відображення зберігаються.

<details>
<summary><strong>JSON, NDJSON і сповіщення про процеси</strong></summary>

- `mo analyze --json ~/Documents` повертає разовий звіт про диск у JSON
- `mo status --json` повертає разовий знімок стану в JSON
- `mo status | jq '.health_score'` автоматично перемикається на JSON, коли вивід передається конвеєром
- `mo status --watch --interval 2s` транслює JSON, розділений на рядки (NDJSON), з уже прогрітого збирача даних
- `mo history --json` повертає історію очищень у JSON. Сесії містять `run_id` (непрозорий рядок, порожній, якщо ідентифікатор не записано) та `attribution`: `run` для ідентифікованих запусків, `command` для застарілого групування за командами або `ambiguous`, коли за старими позначками неможливо відрізнити переривання від запусків, що накладаються один на одного. Записані дії лишаються доступними, але неоднозначні лічильники не можна надійно віднести до окремих запусків. Порожній `ended_at` означає, що позначку завершення не записано.

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

Діагностика процесів-зомбі працює лише на читання: вона не впливає на оцінку здоров'я й не завершує жодних процесів. Доки Mole не отримає першу успішну вибірку процесів, поля `process_collected_at`, `process_stale`, `zombie_count` і `zombie_parents_complete` відсутні, а `zombie_parents` має значення `null`. Подальші швидкі знімки та знімки в режимі `--watch` повторно використовують останню успішну вибірку з її початковим `process_collected_at` і ставлять `process_stale: true`; свіжа вибірка процесів ставить `false`. Значення `0` означає, що Mole перевірив процеси й не знайшов жодного зомбі. Зведення батьківських процесів містять щонайбільше трьох відомих власників; `zombie_parents_complete: false` означає, що визначити власників не вдалося, вдалося лише частково або список обрізано.

Якщо один зі збирачів даних дає збій, `mo status --json` однаково виводить зібрані метрики, повідомляє про збій у stderr і завершується успішно — так само, як `--watch` продовжує трансляцію. Код виходу 1 буде лише тоді, коли недоступна жодна з метрик CPU, пам'яті, диска й процесів або коли не вдалося вивести JSON.

Також status може лише повідомляти (без жодних дій) про процеси, які тривалий час перевищують поріг завантаження CPU. Налаштувати або вимкнути ці сповіщення можна через `--proc-cpu-threshold`, `--proc-cpu-window` чи `--proc-cpu-alerts=false`.

</details>

### Очищення проєктів (Purge)

`mo purge` знаходить артефакти проєктів, які можна зібрати заново, як-от `node_modules`, `target`, `.build`, `build` і `dist`. Він групує артефакти за проєктами й остаточно видаляє лише те, що ви підтвердили. Артефакти, файли яких змінювалися протягом останніх 7 днів або активність яких Mole не може перевірити, типово не вибрано. Mole використовує `fd`, якщо його встановлено, а інакше — `find`, і захищає теки з файлами ключових пар для розгортання, вкладеними Git-репозиторіями або файлами, що відстежуються Git. Неінтерактивний запуск потребує `mo purge --yes`; щоб спершу переглянути кандидатів, скористайтеся `mo purge --dry-run`.

Page Up/Down або `h`/`l` гортають сторінку, `[`/`]` перескакують між проєктами, а `X` пропускає проєкт і переходить до наступного. `/` шукає за шляхами проєктів і назвами артефактів, `n` переходить до наступного збігу, не змінюючи вибору, а Enter відкриває фінальний перегляд шляхів. Указаний обсяг — це оцінка; невиміряні артефакти й неповні сканування позначено явно.

<details>
<summary><strong>Приклад виводу purge</strong></summary>

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
<summary><strong>Власні шляхи для сканування</strong></summary>

Запустіть `mo purge --paths`, щоб налаштувати теки для сканування, або відредагуйте `~/.config/mole/purge_paths` напряму:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

Якщо власні шляхи задано, Mole сканує лише ці теки. Інакше він використовує типові, як-от `~/Projects`, `~/GitHub`, `~/dev`, а також підтримувані теки з робочими деревами (worktree) агентів. Незавершений результат пошуку не зберігається. Сканування артефактів сягає шести рівнів углиб від кожного налаштованого кореня; для глибших проєктів додайте ближчий корінь. Purge видаляє артефакти, які можна зібрати заново, всередині робочих дерев, але ніколи не самі робочі дерева.

</details>

### Інсталятори (Installer)

`mo installer` знаходить файли DMG, PKG, MPKG, ISO, XIP і ZIP-архіви з інсталяторами в Завантаженнях, на Робочому столі, у кешах Homebrew, iCloud, Mail, Telegram та інших підтримуваних місцях і перед видаленням показує розмір і джерело кожного елемента. Пошук має сумарне обмеження в часі: якщо сканування чи перевірка метаданих завершується збоєм або тайм-аутом, Mole відкидає список і виходить, нічого не вибравши. Пошкоджені й нечитабельні ZIP-архіви пропускаються. Символьні посилання як корені сканування підтримуються, але посилань усередині них Mole не відстежує, а вибрані файли ще раз звіряються з підтвердженою ідентичністю безпосередньо перед видаленням.

<details>
<summary><strong>Приклад виводу installer</strong></summary>

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

## Швидкий запуск

<details>
<summary><strong>Налаштування Raycast і Alfred</strong></summary>

Встановіть п'ять команд швидкого запуску для Clean, Uninstall, Optimize, Analyze і Status:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

Скрипт додає команди Raycast, а якщо знайде налаштування Alfred — ще й відповідні робочі процеси Alfred із ключовими словами `clean`, `uninstall`, `optimize`, `analyze` і `status`.

Raycast потребує одного ручного налаштування:

1. Відкрийте **Raycast Settings > Extensions > Script Commands**.
2. Додайте `~/Library/Application Support/Raycast/script-commands` як теку зі скриптами.
3. Виконайте в Raycast **Reload Script Directories**.

Команди самі визначають Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm і Warp. Щоб вибрати конкретний термінал, задайте `MO_LAUNCHER_APP=<name>`; також Mole можна запускати просто в [Kaku](https://github.com/tw93/Kaku).

</details>

## Спільнота

Дякую всім, хто допомагав створювати Mole. Підпишіться на них! ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Контриб'ютори Mole" width="1000" />
</a>

<br/><br/>
Справжні відгуки користувачів, які розповідали про Mole в X.

<img src="./docs/img/mole-love.png" alt="Відгуки спільноти про Mole" width="1000" />

Перегляньте [відеоурок про Mole](https://www.youtube.com/watch?v=UEe9-w4CcQ0) від PAPAYA 電腦教室.

## Підтримка

- Придбати [Mole for Mac](https://mole.fit) — найпряміший спосіб підтримати розробку Mole
- Якщо Mole вам допоміг, поставте зірку, [розкажіть про нього](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) або відкрийте issue чи PR
- У мене двоє котів, TangYuan і Coke; якщо Mole хоч трохи полегшив вам життя, можете пригостити їх <a href="https://cats.tw93.fun?name=Mole" target="_blank">консервами 🥩</a>

<details>
<summary>Ці чудові люди вже пригостили 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="Прихильники Mole" width="1000" loading="lazy" /></a>
</details>

## Ліцензія

Mole — відкрите програмне забезпечення під ліцензією GPL-3.0; подробиці в [LICENSE](LICENSE). Будь-яка змінена версія, яку ви поширюєте, має залишатися під тією самою ліцензією. Якщо ви робите форк Mole, будь ласка, дайте йому іншу назву й зазначте Mole як першоджерело. [Mole for Mac](https://mole.fit) — окремий пропрієтарний застосунок, а Mole тут надовго.
