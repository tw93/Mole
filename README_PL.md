<p align="right"><b>macOS</b> · <a href="https://github.com/tw93/Mole/tree/windows#readme">Windows</a> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <h1>Mole</h1>
  <p><b>Głębokie czyszczenie, odinstalowywanie, optymalizacja, analiza dysku i monitorowanie Twojego Maca. Darmowe CLI open source, a do tego aplikacja na Maca.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · Polski · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://x.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=x" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Wyniki czyszczenia Mole" width="1000" />
</p>

> 💡 To repozytorium zawiera darmowe CLI open source (`mo`). Wolisz natywną aplikację? [Mole for Mac](https://mole.fit/) to osobna aplikacja do pobrania: czyszczenie z podglądem przed usunięciem, sprawdzone pozostałości dla ponad 800 aplikacji, konserwacja, szczegółowa analiza dysku, bieżący stan systemu i sterowanie wentylatorami na obsługiwanych Macach. Na Windowsie natywną aplikacją jest [Mole for Windows](https://mole.fit/windows). `brew install mole` instaluje tylko CLI.

## Funkcje

- **Kompletny zestaw narzędzi CLI**: łączy w jednym poleceniu terminala funkcje w stylu CleanMyMac, AppCleaner, DaisyDisk i iStat Menus
- **Głębokie czyszczenie**: usuwa pamięci podręczne, logi, pozostałości i osierocone dane aplikacji, odzyskując miejsce na dysku
- **Inteligentny deinstalator**: usuwa aplikacje razem z LaunchAgents, preferencjami i pozostałościami
- **Analizator dysku**: wizualizuje zajętość dysku w interaktywnym TUI, wyszukuje duże pliki i pozwala przeglądać katalogi
- **Konserwacja systemu**: czyści pamięć DNS, odświeża QuickLook i ikony oraz optymalizuje bazy danych systemu
- **Monitorowanie na żywo**: pokazuje w czasie rzeczywistym CPU, pamięć, operacje dyskowe, ruch sieciowy i procesy

## Szybki start

Mole wymaga macOS 12 lub nowszego i obsługuje Maki z procesorami Intel oraz Apple Silicon. Jeśli Homebrew nie obsługuje już Twojej wersji macOS, użyj instalacji skryptem.

**Instalacja przez Homebrew**

```bash
brew install mole
```

**Lub skryptem**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**Za pomocą agenta AI**

Napisz do swojego agenta:

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

Możesz też samodzielnie zainstalować skill. Dzięki niemu Claude Code, Codex, Cursor i inne agenty pokazują każde czyszczenie z `--dry-run`, zanim cokolwiek zostanie usunięte, a odinstalowywanie aplikacji i kroki wymagające uprawnień administratora zostawiają Tobie. Aktualizacja: `npx skills update -g -y`.

```bash
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

Jako plugin: w Claude Code `/plugin marketplace add tw93/Mole`, a potem `/plugin install mole@mole`; w Codex `codex plugin marketplace add tw93/Mole`, a potem `codex plugin add mole@mole`.

**Polecenia**

```bash
mo                           # Menu interaktywne
mo clean                     # Głębokie czyszczenie + pozostałości po odinstalowanych aplikacjach
mo uninstall                 # Usuwanie zainstalowanych aplikacji + ich pozostałości
mo optimize                  # Odświeżenie pamięci podręcznych i usług
mo analyze                   # Wizualny eksplorator dysku (lub 'mo analyse')
mo status                    # Bieżący panel stanu systemu
mo purge                     # Czyszczenie artefaktów budowania projektów
mo installer                 # Wyszukiwanie i usuwanie plików instalatorów
mo slim                      # Usuwanie kodu Intel z aplikacji uniwersalnych

mo touchid                   # Konfiguracja Touch ID dla sudo
mo completion                # Konfiguracja autouzupełniania w powłoce
mo update                    # Aktualizacja Mole
mo update --nightly          # Aktualizacja do najnowszej niewydanej wersji z main, tylko instalacja skryptem
mo remove                    # Usunięcie Mole z systemu
mo --help                    # Wyświetlenie pomocy
mo --version                 # Wyświetlenie zainstalowanej wersji
```

**Bezpieczny podgląd**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo slim --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Podgląd + szczegółowe logi
mo optimize --whitelist      # Zarządzanie chronionymi regułami optymalizacji
mo clean --whitelist         # Zarządzanie chronionymi pamięciami podręcznymi
mo purge --paths             # Konfiguracja katalogów skanowania projektów
mo analyze /Volumes          # Analiza tylko dysków zewnętrznych
mo analyze /private/tmp      # Przegląd katalogów tymczasowych użytkownika
```

<details>
<summary><strong>Inne sposoby instalacji</strong></summary>

Aby zainstalować konkretne wydanie, podaj dowolny tag ze [strony wydań](https://github.com/tw93/mole/releases), z początkowym `V` lub bez niego. Aby śledzić gałąź rozwojową, podaj `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` instaluje niewydany kod z domyślnej gałęzi, więc mogą pojawić się niedoróbki. `latest` nadal działa jako starszy alias dla `main`; wbrew nazwie nie instaluje najnowszego stabilnego wydania.

Skrypt domyślnie instaluje do `/usr/local/bin`, co może wymagać hasła administratora. Zainstaluj do katalogu należącego do użytkownika, jeśli chcesz, aby kolejne `mo update` nie pytały o hasło:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Dodaj ten sam eksport `PATH` do `~/.zshrc` lub profilu powłoki, aby działał w nowych terminalach. Mole aktualizuje tę instalację, z której zostało uruchomione, więc nadal będzie korzystać z tego katalogu. Polecenia zmieniające pliki należące do systemu mogą nadal prosić o uprawnienia administratora.

**Nix**

Na macOS użytkownicy Nix mogą zainstalować flake z `main`, który zawiera niewydane zmiany:

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

W instalacji deklaratywnej dodaj `github:tw93/mole/main` jako wejście flake i użyj jego pakietu `packages.${system}.mole`. Aktualizuj i usuwaj Mole przez Nix; `mo update` i `mo remove` nie zmieniają instalacji zarządzanych przez Nix.

</details>

**Na Windowsie** ([Windows CLI](https://github.com/tw93/Mole/tree/windows#readme))

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole jest dystrybuowane wyłącznie przez Homebrew, to repozytorium i [mole.fit](https://mole.fit/). `molemac.com`, `moleapp.net` i `molefit.com` nie są Mole, a aplikacja na Windowsa pod adresem `mole.bluecatbot.com` to osobny projekt społeczności.

## Bezpieczeństwo

Mole może usuwać pliki, dlatego weryfikuje ścieżki, chroni lokalizacje współdzielone i należące do systemu oraz prosi o potwierdzenie, gdy dana akcja tego wymaga. Gdy Mole nie może udowodnić, że zmiana elementu jest bezpieczna, pomija go lub odmawia wykonania.

- `clean`, `uninstall`, `purge`, `installer`, `slim` i `remove` mogą usuwać pliki, więc najpierw sprawdź je z `--dry-run`, a w razie potrzeby dodaj `--debug`
- Uruchamiaj Mole bez `sudo`; poprosi o uprawnienia administratora tylko wtedy, gdy będą potrzebne
- `mo uninstall`, `mo analyze` i `mo slim` po potwierdzeniu domyślnie przenoszą usuwane elementy do Kosza; `clean`, `purge` i `installer` usuwają trwale. `mo uninstall --permanent` pomija Kosz
- Aktywność czyszczenia jest zapisywana w `~/Library/Logs/mole/operations.log`; przejrzysz ją przez `mo history`, a wyłączysz przez `MO_NO_OPLOG=1`
- Chroń pamięci podręczne przez `mo clean --whitelist`, a elementy konserwacji przez `mo optimize --whitelist`
- Jeśli pliku whitelisty nie da się odczytać, `clean`, `purge` i `optimize` zatrzymują się zamiast działać bez niego

Wskazówki dotyczące zgłaszania problemów, granice bezpieczeństwa i obecne ograniczenia opisują [SECURITY.md](SECURITY.md) i [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

## Konfiguracja

Mole działa bez konfiguracji. Te zmienne środowiskowe dostosowują go do wolnych dysków oraz zawieszonych zasobów sieciowych lub chmurowych; zwiększaj limit czasu tylko wtedy, gdy Mole zgłosi, że któryś krok przekroczył limit czasu (`timed out`).

- `MOLE_TIMEOUT_QUICK_DETECT_SEC` (2): sprawdzanie dostępności poleceń
- `MOLE_TIMEOUT_SHORT_QUERY_SEC` (3): lekkie zapytania, takie jak `df` i `tmutil status`
- `MOLE_TIMEOUT_MEDIUM_PROBE_SEC` (5): sondy przeglądające drzewo katalogów lub korzystające z sieci
- `MOLE_TIMEOUT_PKG_LIST_SEC` (10): listowanie pakietów, np. `brew list`
- `MOLE_TIMEOUT_PKG_CLEANUP_SEC` (20): czyszczenie pamięci podręcznych, które przegląda dysk
- `MOLE_TIMEOUT_DISK_VERIFY_SEC` (30): weryfikacja i naprawa systemu plików
- `MOLE_TIMEOUT_HINT_SCAN_SEC` (15): nieograniczone skanowanie katalogów użytkownika
- `MOLE_CLOUD_OFFICE_SECTION_BUDGET_SEC` (300): łączny limit czasu dla sekcji czyszczenia chmury i pakietu Office

Liczba w nawiasie to wartość domyślna w sekundach. Na przykład, aby dać skanowaniu więcej czasu na wolnym dysku:

```bash
MOLE_TIMEOUT_HINT_SCAN_SEC=60 MOLE_TIMEOUT_MEDIUM_PROBE_SEC=15 mo clean
```

## Funkcje w szczegółach

Poniższe przykłady są skrócone. Dostępne elementy, rozmiary i powody pominięcia zależą od Twojego Maca.

### Czyszczenie

`mo clean` przegląda znane jako bezpieczne pamięci podręczne, logi, pliki tymczasowe, artefakty narzędzi deweloperskich i pozostałości po aplikacjach, które nie są już zainstalowane. Domyślnie opróżnia `~/.Trash`; aby go zachować, zaznacz Trash w `mo clean --whitelist`, czyli w tym samym menu, które chroni pamięci podręczne, które chcesz zatrzymać. Kosze woluminów, takie jak `/Volumes/*/.Trashes`, nie są przy tym opróżniane. Wybór zapisuje się w `~/.config/mole/whitelist`. Zanim dodasz własne ścieżki, otwórz menu i naciśnij Enter, aby zapisać wybór, a potem dopisz po jednej ścieżce w wierszu. Istniejący plik zastępuje opcjonalne ustawienia domyślne; wbudowane zabezpieczenia nadal obowiązują.

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
Removed: 4.5GB · 97 items
Free space: 223.5GB (+4.5GB)
======================================================================
```

### Odinstalowywanie

`mo uninstall` usuwa zainstalowaną aplikację razem z powiązanymi plikami, które Mole potrafi jednoznacznie przypisać do tej aplikacji. Zachowuje dane współdzielone, jeśli korzysta z nich inna zainstalowana kopia. Jeśli aplikacji już nie ma, użyj `mo clean`, aby poszukać pozostałości.

Dane osobiste, w tym ustawienia i wtyczki, są domyślnie zachowywane. Naciśnij `D` w podglądzie usuwania, aby wybrać poszczególne ścieżki danych. `mo uninstall --with-data` zaczyna z zaznaczonymi danymi, z wyjątkiem profili przeglądarek i kontenerów App Group; podgląd wymienia je osobno, a `D` nadal pozwala zachować dowolną ścieżkę. Po usunięciu odwołania w konfiguracji powłoki, Hooków lub MCP są wymieniane tylko z nazwą pliku i numerem wiersza; Mole nie edytuje tych konfiguracji.

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

### Optymalizacja

`mo optimize` wykonuje ograniczoną konserwację obsługiwanych usług Findera, sieci, baz danych i macOS. Zadania niepotrzebne, w danej chwili niebezpieczne lub niedostępne są pomijane z podaniem powodu. Użyj `mo optimize --whitelist`, aby wykluczyć zadania lub wzorce ścieżek, na przykład długo zamontowany obraz dysku w `/Volumes/mail`, który nie powinien pojawiać się jako kandydat do odłączenia.

```text
$ mo optimize

Optimize

⚙ System  18/32 GB RAM | 616/926 GB Disk | Uptime 6d

PERFORMANCE DIAGNOSIS
  ✓ No sustained high-CPU bottleneck detected

➤ Finder Cache Refresh
  ✓ QuickLook thumbnails refreshed
  ✓ Icon services cache rebuilt

➤ Network Cache Refresh
  ✓ DNS cache refreshed

➤ Database Optimization
  ◎ Close these apps before database optimization: Safari

➤ Disk Health
  ✓ Disk verify skipped

======================================================================
Optimization Complete
Applied 2 optimizations
13 unchanged | 3 skipped | 1 unavailable
======================================================================
```

### Analiza

`mo analyze` otwiera eksplorator dysku w terminalu. Obsługuje nawigację strzałkami i klawiszami Vima, filtrowanie, zaznaczanie wielu elementów, podgląd w Finderze i potwierdzone przenoszenie do Kosza. Dyski zewnętrzne są pomijane w domyślnym przeglądzie; sprawdzisz je przez `mo analyze /Volumes` lub konkretną ścieżkę montowania. Użyj `mo analyze /private/tmp`, aby przejrzeć pliki tymczasowe użytkownika bez czynienia z nich celów automatycznego czyszczenia. Skanowanie plik po pliku liczy jednokrotnie klony APFS, które współdzielą wszystkie bloki; szybkie szacunki folderów mogą nadal liczyć współdzielone bloki więcej niż raz.

Rozmiar zakończony `+` zawiera bajty zmierzone podczas częściowego skanowania; `unknown` oznacza, że rozmiaru nie udało się zmierzyć. Wyniki przerwane przez chwilowe błędy, takie jak przekroczenie limitu czasu, nie zastępują kompletnych pomiarów z pamięci podręcznej, a późniejsze odświeżenie może uzupełnić brakujące dane. Foldery, których macOS nie pozwala terminalowi odczytać, pozostają częściowe, dopóki dostęp się nie zmieni. Lista w terminalu zawiera 30 największych pozycji, więc nieczytelna pozycja może znaleźć się poza nią; suma nadal wskazuje częściowe skanowanie. Wyjście JSON katalogu obejmuje wszystkie przeskanowane pozycje.

`mo analyze --json /path` zawiera `scan_status` dla wyniku i każdej pozycji: `complete`, `partial` lub `unavailable`. Rozmiary liczbowe zawierają zmierzone bajty; zero ze statusem `unavailable` nie oznacza pustego katalogu. Częściowe skanowanie nadal kończy się sukcesem, więc automatyzacja powinna sprawdzać `scan_status`. Kompletność dotyczy zakresu w ramach istniejących wykluczeń skanowania Mole i nie gwarantuje atomowej migawki systemu plików.

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

### Status

`mo status` to panel tylko do odczytu pokazujący sprzęt, obciążenie systemu, aktywność dysku, ruch sieciowy, zasilanie i procesy.

Gdy domyślna trasa IPv4 prowadzi przez tunel, wykresy sieci używają przepustowości tego interfejsu, aby nie liczyć drugi raz tego samego ruchu na jego fizycznym nośniku. JSON zachowuje przepustowość każdego interfejsu, w tym tunelu, przez który biegnie trasa; nieaktywne tunele niebędące trasą domyślną pozostają ukryte.

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

Wskaźnik zdrowia łączy CPU, pamięć, zajętość dysku, status SMART, operacje wejścia/wyjścia, temperatury, stan baterii i czas pracy, z zakresami oznaczonymi kolorami. Naciśnij `k`, aby pokazać lub ukryć kota, `c`, aby zmienić liczbę wyświetlanych rdzeni CPU, lub `q`, aby wyjść; preferencje wyświetlania są zapisywane.

<details>
<summary><strong>JSON, NDJSON i alerty procesów</strong></summary>

- `mo analyze --json ~/Documents` zwraca jednorazowy raport dysku w formacie JSON
- `mo status --json` zwraca jednorazową migawkę stanu w formacie JSON
- `mo status | jq '.health_score'` automatycznie przełącza się na JSON, gdy wyjście jest przekazywane potokiem
- `mo status --watch --interval 2s` strumieniuje JSON rozdzielany znakami nowej linii z działającego w tle kolektora
- `mo history --json` zwraca aktywność czyszczenia w formacie JSON. Sesje zawierają `run_id` (nieprzezroczysty ciąg znaków, pusty, gdy nie zapisano identyfikatora) oraz `attribution`: `run` dla zidentyfikowanych uruchomień, `command` dla starszego grupowania według poleceń lub `ambiguous`, gdy starsze znaczniki nie pozwalają odróżnić przerwania od nakładających się uruchomień. Zapisane akcje pozostają dostępne; niejednoznacznych liczników nie da się wiarygodnie przypisać do poszczególnych uruchomień. Puste `ended_at` oznacza, że nie zapisano znacznika zakończenia
- `mo uninstall --list` zwraca zainstalowane aplikacje w formacie JSON z polami `name`, `bundle_id`, `source`, `uninstall_name`, `path` i `size`

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

Diagnostyka procesów zombie działa tylko do odczytu i nie wpływa na wskaźnik zdrowia ani nie kończy
procesów. Zanim Mole uzyska pierwszą udaną próbkę procesów, pola `process_collected_at`,
`process_stale`, `zombie_count` i `zombie_parents_complete` są pomijane, a `zombie_parents` ma
wartość `null`. Późniejsze migawki trybu szybkiego i `--watch` używają ostatniej udanej próbki z jej
pierwotnym `process_collected_at` i ustawiają `process_stale: true`; bieżąca próbka procesów ustawia
`false`. Licznik `0` oznacza, że Mole nie wykryło procesów zombie. Podsumowania procesów nadrzędnych
zawierają najwyżej trzech znanych właścicieli; `zombie_parents_complete: false` oznacza, że
przypisanie było niedostępne, niepełne lub obcięte.

Jeśli jeden z kolektorów zawiedzie, `mo status --json` nadal wypisuje zebrane metryki, zgłasza błąd
na stderr i kończy się sukcesem, tak samo jak `--watch` nadal strumieniuje dane. Kończy się kodem 1,
gdy niedostępna jest żadna z metryk CPU, pamięci, dysku ani procesów albo gdy zapis JSON się nie powiedzie.

Status obsługuje też alerty tylko do odczytu dla procesów, które przez dłuższy czas przekraczają próg CPU. Użyj `--proc-cpu-threshold`, `--proc-cpu-window` lub `--proc-cpu-alerts=false`, aby je dostroić lub wyłączyć.

</details>

### Purge

`mo purge` wyszukuje artefakty projektów, które można odtworzyć, takie jak `node_modules`, `target`, `.build`, `build` i `dist`. Grupuje je według projektów i trwale usuwa tylko elementy, które potwierdzisz. Artefakty z aktywnością plików w ciągu ostatnich 7 dni lub z aktywnością, której Mole nie może zweryfikować, są domyślnie odznaczone. Mole używa `fd`, jeśli jest dostępne, a w przeciwnym razie `find`, i chroni katalogi zawierające pliki par kluczy wdrożeniowych, zagnieżdżone repozytoria Git lub pliki śledzone przez Git. Uruchomienia nieinteraktywne wymagają `mo purge --yes`; najpierw przejrzyj kandydatów przez `mo purge --dry-run`.

Klawisze Page Up/Down lub `h`/`l` przewijają o stronę, `[`/`]` przeskakują między projektami, a `X` pomija projekt i przechodzi dalej. `/` przeszukuje ścieżki projektów i nazwy artefaktów, `n` znajduje kolejne dopasowanie bez zmiany zaznaczenia, a Enter otwiera końcowy przegląd ścieżek. Podawane miejsce jest szacunkowe; niezmierzone artefakty i niepełne skanowania są wyraźnie oznaczone.

<details>
<summary><strong>Przykładowe wyjście purge</strong></summary>

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
<summary><strong>Własne ścieżki skanowania</strong></summary>

Uruchom `mo purge --paths`, aby skonfigurować katalogi skanowania, lub edytuj bezpośrednio `~/.config/mole/purge_paths`:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

Gdy skonfigurowano własne ścieżki, Mole skanuje tylko te katalogi. W przeciwnym razie używa domyślnych, takich jak `~/Projects`, `~/GitHub`, `~/dev` i obsługiwane kontenery worktree agentów. Wyszukiwanie nie zapisuje niepełnego wyniku. Skanowanie artefaktów sięga sześć poziomów poniżej każdego skonfigurowanego katalogu głównego; dla głębiej położonych projektów dodaj bliższy katalog główny. Purge usuwa odtwarzalne artefakty wewnątrz worktree, nigdy same worktree.

</details>

### Instalatory

`mo installer` wyszukuje pliki DMG, PKG, MPKG, ISO, XIP i archiwa ZIP z instalatorami w Pobranych, na Biurku, w pamięci podręcznej Homebrew, iCloud, Mail, Telegramie i innych obsługiwanych lokalizacjach, a przed usunięciem pokazuje rozmiar i źródło każdego elementu. Wyszukiwanie ma łączny limit czasu: jeśli skanowanie lub odczyt metadanych zawiedzie albo przekroczy limit czasu, Mole odrzuca listę i kończy działanie bez zaznaczania plików. Uszkodzone i nieczytelne archiwa ZIP są pomijane, katalogi skanowania będące dowiązaniami symbolicznymi są obsługiwane, ale dowiązania wewnątrz nich nie są śledzone, a zaznaczone pliki są ponownie sprawdzane względem potwierdzonej tożsamości tuż przed usunięciem.

<details>
<summary><strong>Przykładowe wyjście installer</strong></summary>

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

### Slim

`mo slim` usuwa kod Intel, który aplikacje uniwersalne przenoszą na Makach z Apple Silicon. Wyświetla należące do Ciebie aplikacje podpisane Developer ID wraz z rozmiarem kodu Intel w każdej z nich i zmienia tylko wybrane aplikacje. Każda aplikacja jest odchudzana na kopii, przy czym zmieniane są tylko główne pliki wykonywalne i zagnieżdżony kod z własnym podpisem; kopia zastępuje aplikację dopiero wtedy, gdy zachowuje kod Apple Silicon i przechodzi weryfikację podpisu kodu oraz Gatekeepera, a oryginał trafia do Kosza. Aplikacje z App Store, aplikacje Apple, aplikacje ustawione do otwierania przez Rosettę, aplikacje należące do innego użytkownika i uruchomione aplikacje pozostają nietknięte. Nie wymaga narzędzi deweloperskich, a aktualizacja aplikacji przywraca kod Intel.

## Szybkie uruchamianie

<details>
<summary><strong>Konfiguracja Raycast i Alfred</strong></summary>

Zainstaluj pięć skrótów dla Clean, Uninstall, Optimize, Analyze i Status:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

Skrypt dodaje polecenia Raycast oraz, jeśli istnieją preferencje Alfreda, odpowiadające im workflow Alfreda ze słowami kluczowymi `clean`, `uninstall`, `optimize`, `analyze` i `status`.

Raycast wymaga jednego kroku ręcznego:

1. Otwórz **Raycast Settings > Extensions > Script Commands**.
2. Dodaj `~/Library/Application Support/Raycast/script-commands` jako katalog skryptów.
3. Uruchom w Raycast **Reload Script Directories**.

Skróty automatycznie wykrywają Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm i Warp. Ustaw `MO_LAUNCHER_APP=<name>`, aby wybrać jeden z nich; Mole możesz też uruchamiać bezpośrednio w [Kaku](https://github.com/tw93/Kaku).

</details>

## Społeczność

Dziękuję wszystkim, którzy pomogli zbudować Mole. Zaobserwuj ich. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Współtwórcy Mole" width="1000" />
</a>

<br/><br/>
Prawdziwe opinie użytkowników, którzy polecali Mole na 𝕏.

<img src="./docs/img/mole-love.png" alt="Opinie społeczności o Mole" width="1000" />

Obejrzyj [film instruktażowy o Mole](https://www.youtube.com/watch?v=UEe9-w4CcQ0) przygotowany przez PAPAYA 電腦教室.

## Wsparcie

- Zakup [Mole for Mac](https://mole.fit) to najbardziej bezpośredni sposób wsparcia rozwoju Mole
- Jeśli Mole Ci pomogło, daj gwiazdkę, [udostępnij je](https://x.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) albo otwórz issue lub PR
- Mam dwa koty, TangYuan i Coke; jeśli Mole choć trochę ułatwia Ci życie, możesz postawić im <a href="https://cats.tw93.fun?name=Mole" target="_blank">puszkę karmy 🥩</a>

Te wspaniałe osoby już to zrobiły 🐱

<a href="https://cats.tw93.fun?name=Mole"><img src="https://raw.githubusercontent.com/tw93/sponsors/main/assets/sponsors.svg" alt="Wspierający Mole" width="1000" loading="lazy" /></a>

## Licencja

Mole jest projektem open source na licencji GPL-3.0; szczegóły w [LICENSE](LICENSE). Każda udostępniana zmodyfikowana wersja musi pozostać na tej samej licencji. Jeśli tworzysz fork Mole, użyj innej nazwy i wskaż Mole jako źródło upstream. [Mole for Mac](https://mole.fit) to osobna, zamknięta aplikacja, a Mole zostaje na długo.
