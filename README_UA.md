<p align="right"><a href="https://github.com/tw93/Mole">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux">Linux</a></p>

<div align="center">
  <h1>Mole CLI for Windows</h1>
  <p><b>Глибоке очищення, видалення застосунків, оптимізація, аналіз диска й моніторинг вашого ПК з Windows. Безкоштовний CLI з відкритим кодом.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · Українська · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Меню Mole CLI for Windows" width="736" />
</p>

> 💡 Ця гілка містить безкоштовний CLI для Windows з відкритим кодом (`mo`). Хочете нативний застосунок? [Mole for Windows](https://mole.fit/windows) завантажується окремо: перегляд перед видаленням, оновлення застосунків, керування автозапуском, детальний розбір диска та стан у реальному часі. CLI для macOS розташований у [гілці main](https://github.com/tw93/Mole).

## Можливості

- **Усе в одному CLI**: поєднує сценарії в дусі CCleaner, IObit Uninstaller, WinDirStat та Диспетчера завдань в одній команді термінала
- **Глибоке очищення**: видаляє тимчасові файли, кеші, журнали й залишки браузерів, щоб звільнити місце на диску
- **Розумне видалення застосунків**: прибирає застосунки разом із теками встановлення, що залишилися
- **Аналіз диска**: наочно показує, чим зайнятий диск, в інтерактивному TUI та знаходить великі файли
- **Обслуговування системи**: скидає кеш DNS, оптимізує системний диск і перевіряє його стан
- **Моніторинг у реальному часі**: показує навантаження на CPU, пам'ять, диск, мережу та процеси

## Швидкий старт

Mole працює у Windows 10 і 11 зі вбудованим Windows PowerShell 5.1. Для встановлення скриптом потрібен Git, а також Go для збирання нативних інструментів, якщо вихідний код відрізняється від останнього релізу. Mole встановлюється до `%LOCALAPPDATA%\Programs\mole-cli` і додає `mo` та `mole` до вашого PATH.

**Встановлення через Scoop**

```powershell
scoop install mole
```

**Або скриптом**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole поширюється лише через цей репозиторій GitHub, Scoop і [mole.fit](https://mole.fit/windows) для застосунку Windows. Сайти, що пропонують застосунок «на основі Mole» або просять вставити закодовану команду в термінал, не мають стосунку до Mole.

**Через ШІ-агента**

Скажіть своєму агенту:

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

Або встановіть скіл самі. З ним Claude Code, Codex, Cursor та інші агенти перед будь-яким видаленням показують список через `--dry-run`, а видалення застосунків і кроки з правами адміністратора залишають вам. Оновлення: `npx skills update -g -y`.

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

Як плагін хоста: у Claude Code `/plugin marketplace add tw93/Mole`, потім `/plugin install mole@mole`, у Codex `codex plugin marketplace add tw93/Mole`, потім `codex plugin add mole@mole`.

**Запуск**

```powershell
mo                           # Інтерактивне меню
mo clean                     # Глибоке очищення
mo uninstall                 # Видалити встановлені застосунки разом із залишками
mo optimize                  # Оновити кеші та служби
mo analyze                   # Наочний огляд диска
mo status                    # Панель стану системи в реальному часі
mo purge                     # Прибрати артефакти збирання проєктів

mo update                    # Оновити Mole
mo remove                    # Видалити Mole з цього ПК
mo --help                    # Показати довідку
mo --version                 # Показати встановлену версію
```

**Безпечний попередній перегляд**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Попередній перегляд + докладні журнали
mo clean --whitelist         # Керувати захищеними шляхами
mo clean --system            # Додати системне очищення (запускайте від імені адміністратора)
mo purge --paths             # Налаштувати теки для пошуку проєктів
mo analyze D:\               # Аналізувати інший диск
mo uninstall --list          # Список встановлених застосунків, у JSON через конвеєр
mo analyze --json D:\        # Звіт про диск у JSON
```

<details>
<summary><strong>Інші способи встановлення</strong></summary>

Щоб переглянути код перед встановленням, клонуйте гілку `windows` і запустіть інсталятор на місці. Тека `.git` зберігається, тож пізніше працюватиме `mo update`:

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

Додайте `-CreateShortcut`, щоб створити ярлик у меню «Пуск». Щоб видалити Mole, виконайте `mo remove`.

</details>

## Безпека

Mole вміє видаляти файли, тому перевіряє шляхи та захищає системні розташування й теку профілю. `uninstall`, `purge` і `remove` просять підтвердження, перш ніж щось видалити. Якщо Mole не може довести, що елемент безпечно змінювати, він його пропускає.

- `clean`, `uninstall` і `purge` можуть видаляти файли, тож спершу перегляньте, що саме зміниться, з `--dry-run`, а за потреби додайте `--debug`
- `clean` і `purge` видаляють остаточно; перевірені залишки `uninstall` потрапляють до Кошика, власний деінсталятор застосунку зберігає свою поведінку, а файли, видалені в `mo analyze`, також потрапляють до Кошика
- Запускайте Mole від імені звичайного користувача; кроки системного рівня пропускаються, якщо PowerShell запущено не від імені адміністратора
- Захищайте шляхи через `mo clean --whitelist`
- Дії з очищення записуються до `%USERPROFILE%\.config\mole\operations.log`; переглянути їх можна через `mo history`, а вимкнути запис можна змінною `MO_NO_OPLOG=1`
- `C:\Windows`, `C:\Program Files`, теки Windows Defender і корінь вашого профілю ніколи не чіпаються

Як повідомити про вразливість і де пролягають межі безпеки, описано в [SECURITY.md](SECURITY.md).

## Докладніше про можливості

Знімки екрана нижче зроблено на тестовому ПК. Доступні елементи й розміри залежать від вашого ПК.

### Очищення (Clean)

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="Попередній перегляд mo clean --dry-run" width="736" />

Докладний список містить усі шляхи, знайдені під час попереднього перегляду. Скопіюйте будь-який із них до білого списку (whitelist), щоб його зберегти.

### Видалення застосунків (Uninstall)

```powershell
mo uninstall
```

Показує встановлені програми з реєстру та Windows Apps, від найбільших до найменших, потім видаляє вибрані власним деінсталятором і прибирає теку встановлення, що залишилася. `mo uninstall --dry-run` показує, який деінсталятор використає кожен застосунок і що буде видалено, нічого не запускаючи.

<img src="./docs/img/uninstall-windows.png" alt="Список програм mo uninstall" width="736" />

### Оптимізація (Optimize)

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="Попередній перегляд mo optimize --dry-run" width="736" />

Кроки на кшталт оптимізації диска та скидання кешу ARP потребують прав адміністратора, а без них пропускаються; щоб їх виконати, запустіть PowerShell від імені адміністратора.

### Аналіз диска (Analyze)

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="Огляд mo analyze" width="807" />

Інтерактивний провідник диска з тим самим розташуванням, що й у версії для macOS: стрілки переміщують між теками, `Backspace` повертає назад, `T` показує найбільші файли, а `Del` після підтвердження переміщує вибрані елементи до Кошика.

### Стан системи (Status)

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="Панель mo status" width="1000" />

Панель у реальному часі з оцінкою здоров'я системи, CPU, пам'яттю, диском, живленням, мережею та найактивнішими процесами.

### Очищення проєктів (Purge)

```powershell
mo purge --dry-run
```

Знаходить артефакти збирання (`node_modules`, `target`, `build`, `dist`, `venv` та інші) у теках ваших проєктів і дає змогу вибрати, які проєкти очистити; доки ви не оберете, нічого не вибрано. Теки для сканування налаштовуються через `mo purge --paths`.

## Спільнота

Дякую всім, хто допомагав створювати Mole. Підпишіться на них! ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Контриб'ютори Mole" width="1000" />
</a>

## Підтримка

- Придбати [Mole for Windows](https://mole.fit/windows): це найпряміший спосіб підтримати розробку Mole
- Якщо Mole вам допоміг, поставте зірку, [розкажіть про нього](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.) або відкрийте issue чи PR
- Контриб'ютори вітаються; спершу прочитайте [CONTRIBUTING.md](CONTRIBUTING.md)
- У мене двоє котів, TangYuan і Coke; якщо Mole хоч трохи полегшив вам життя, можете пригостити їх <a href="https://cats.tw93.fun?name=Mole" target="_blank">консервами 🥩</a>

## Ліцензія

Mole є відкритим програмним забезпеченням під ліцензією GPL-3.0; подробиці в [LICENSE](LICENSE). Будь-яка змінена версія, яку ви поширюєте, має залишатися під тією самою ліцензією. Якщо ви робите форк Mole, будь ласка, дайте йому іншу назву й зазначте Mole як першоджерело; див. [TRADEMARK.md](TRADEMARK.md).
