<div align="center">
  <h1>Mole</h1>
  <p><b>Mac 심층 정리, 앱 제거, 시스템 최적화, 디스크 분석 및 상태 모니터링. 무료 오픈소스 CLI와 네이티브 Mac 앱.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · 한국어 · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Mole 정리 결과" width="1000" />
</p>

> 💡 이 저장소는 무료 오픈소스 CLI(`mo`)입니다. 네이티브 앱을 원한다면 [Mole for Mac](https://mole.fit/)을 별도로 내려받을 수 있습니다. 삭제 전 항목별 확인, 800개 이상 앱에서 테스트한 잔여 파일 정리, 유지보수, 디스크 단계별 분석, 실시간 상태 확인, 지원되는 Mac에서의 팬 제어를 제공합니다. `brew install mole`은 CLI만 설치합니다.

## 주요 기능

- **올인원 CLI 툴킷**: CleanMyMac, AppCleaner, DaisyDisk, iStat Menus 스타일의 워크플로를 하나의 터미널 명령으로 통합
- **심층 정리**: 캐시, 로그, 잔여물 및 삭제된 앱이 남긴 데이터를 안전하게 제거하여 디스크 공간 확보
- **스마트 앱 제거**: 앱과 함께 연결된 LaunchAgents, 환경설정, 잔여 파일을 정리
- **디스크 분석기**: 인터랙티브 TUI로 디스크 사용량을 시각화하고 대용량 파일 탐색
- **시스템 최적화**: DNS 플러시, QuickLook 및 아이콘 캐시 재구축, 핵심 시스템 데이터베이스 최적화
- **실시간 모니터링**: CPU, 메모리, 디스크 I/O, 네트워크 트래픽 및 프로세스 상태를 실시간 확인

## 빠른 시작

Mole은 macOS 12 이상을 지원하며, Intel 및 Apple Silicon Mac 모두에서 동작합니다. 현재 macOS 버전에서 Homebrew 설치가 어려우면 설치 스크립트를 사용하고, 실험적인 Windows 버전은 [windows 브랜치](https://github.com/tw93/Mole/tree/windows)에서 확인할 수 있습니다.

**Homebrew로 설치**

```bash
brew install mole
```

**설치 스크립트로 설치**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**주요 명령어**

```bash
mo                           # 대화형 메뉴 열기
mo clean                     # 심층 정리: 시스템 캐시, 로그 및 삭제된 앱 잔여 파일 정리
mo uninstall                 # 앱 제거: 설치된 소프트웨어와 관련 설정 파일 완전 삭제
mo optimize                  # 시스템 최적화: 시스템 서비스와 캐시 새로고침
mo analyze                   # 디스크 분석: 인터랙티브 디스크 용량 분석 및 대용량 파일 탐색
mo status                    # 상태 모니터링: CPU, 메모리, 네트워크 및 하드웨어 실시간 대시보드
mo purge                     # 프로젝트 정리: 개발 빌드 결과물(node_modules, target 등) 정리
mo installer                 # 설치 파일 정리: 설치 파일 탐색 및 삭제

mo touchid                   # 터미널 sudo용 Touch ID 지문 인증 설정
mo completion                # 셸 Tab 키 자동완성 구성
mo update                    # Mole 업데이트 확인 및 실행
mo update --nightly          # 최신 미출시 개발 빌드로 업데이트(스크립트 설치 환경 전용)
mo remove                    # 시스템에서 Mole 완전 삭제
mo --help                    # 도움말 표시
mo --version                 # 설치된 버전 확인
```

**안전 미리보기 (Dry Run)**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 안전 미리보기 + 상세 진단 로그
mo optimize --whitelist      # 보호할 최적화 규칙 관리
mo clean --whitelist         # 보호할 캐시 화이트리스트 관리
mo purge --paths             # 프로젝트 검사 디렉터리 구성
mo analyze /Volumes          # 외장 드라이브만 분석
mo analyze /private/tmp      # 임시 디렉터리 검토(자동 삭제 없음)
```

<details>
<summary><strong>기타 설치 옵션</strong></summary>

특정 버전을 설치하려면 [릴리스 페이지](https://github.com/tw93/mole/releases)의 태그를 지정하세요(앞자리 `V` 유무 무관). 최신 개발 브랜치를 설치하려면 `main`을 전달합니다:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.51.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main`은 메인 브랜치의 미출시 최신 코드를 설치합니다. `latest`는 과거의 별칭이며 최신 안정 릴리스를 의미하지 않습니다.

설치 스크립트는 기본적으로 `/usr/local/bin`에 설치되며 관리자 암호를 요청할 수 있습니다. 암호 입력 없이 `mo update`를 진행하려면 사용자 홈 디렉터리에 설치할 수 있습니다:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

해당 `PATH` 설정을 `~/.zshrc` 또는 셸 프로필 파일에 추가하세요. Mole은 실행한 설치본을 업데이트하므로 이후에도 이 디렉터리를 계속 사용합니다. 시스템 소유 파일을 변경하는 명령은 여전히 관리자 권한을 요청할 수 있습니다.

**Nix**

macOS 환경의 Nix 사용자는 아직 릴리스되지 않은 변경 사항이 포함된 `main` 브랜치에서 플레이크로 직접 설치할 수 있습니다:

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

선언적 구성의 경우 `github:tw93/mole/main`을 flake 입력으로 추가하고 `packages.${system}.mole` 패키지를 사용하세요. 업데이트와 제거는 Nix로 진행하며, `mo update`와 `mo remove`는 Nix가 관리하는 설치를 변경하지 않습니다.

</details>

## 안전성 및 신뢰성

Mole은 파일을 삭제할 수 있으므로 경로를 검증하고, 공유 위치와 시스템 소유 위치를 보호하며, 필요할 때 확인을 요청합니다. 안전하게 변경할 수 있다고 확인할 수 없는 항목은 건너뛰거나 거부합니다.

- `clean`, `uninstall`, `purge`, `installer`, `remove` 명령은 파일을 삭제하므로 먼저 `--dry-run`으로 확인하고 필요 시 `--debug`를 함께 사용하세요
- 일상적인 Mole 실행에는 **`sudo`가 필요하지 않으며**, 시스템 수준의 정리 작업에만 관리자 권한을 요청합니다
- `mo analyze`에서 선택한 항목은 확인 후 macOS 휴지통으로 이동됩니다
- 정리 내역은 `~/Library/Logs/mole/operations.log`에 기록되며, `mo history`로 확인하거나 `MO_NO_OPLOG=1`로 비활성화할 수 있습니다
- `mo clean --whitelist`로 보존할 캐시를 지정하거나 `mo optimize --whitelist`로 제외할 유지보수 작업을 관리하세요

취약점 신고 방법, 안전 경계, 현재 한계는 [SECURITY.md](SECURITY.md) 및 [SECURITY_AUDIT.md](SECURITY_AUDIT.md)를 참고하세요.

## 세부 기능 안내

아래 예시는 축약된 화면입니다. 실제 표시 항목과 용량은 사용 중인 Mac 환경에 따라 다릅니다.

### 심층 정리 (Clean)

`mo clean`은 안전한 캐시, 로그, 임시 파일, 개발 도구 캐시 및 이미 삭제된 앱의 잔여 파일을 검사하고 정리하며, 기본적으로 휴지통을 비웁니다. 휴지통을 유지하려면 `mo clean --whitelist`에서 Trash를 선택하세요. 같은 메뉴에서 보존할 캐시도 지정할 수 있고, 선택한 항목은 `~/.config/mole/whitelist`에 저장됩니다. 직접 경로를 추가하려면 먼저 메뉴를 열고 Enter를 눌러 선택 항목을 저장한 뒤, 한 줄에 하나씩 경로를 추가하세요. 이 파일이 있으면 선택적 기본 규칙을 대체하며, 내장 안전 보호는 계속 적용됩니다.

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

### 앱 제거 (Uninstall)

`mo uninstall`은 설치된 앱과 함께 Mole이 해당 앱의 것으로 확인할 수 있는 관련 파일을 제거합니다. 같은 앱의 다른 설치본이 아직 사용하는 공유 파일은 보존됩니다. 이미 휴지통으로 지운 앱의 경우 `mo clean`을 실행하여 남은 잔여물을 찾으세요.

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

### 시스템 최적화 (Optimize)

`mo optimize`는 지원되는 Finder, 네트워크, 데이터베이스, macOS 서비스에 대해 범위가 정해진 유지보수를 실행합니다. 불필요하거나, 지금 실행하기에 안전하지 않거나, 사용할 수 없는 작업은 이유와 함께 건너뜁니다. `mo optimize --whitelist`로 작업이나 경로 패턴을 제외할 수 있어, `/Volumes/mail`처럼 상시 마운트되는 디스크 이미지가 마운트 해제 후보로 표시되지 않게 할 수 있습니다.

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

### 디스크 분석 (Analyze)

`mo analyze`는 터미널 기반의 인터랙티브 디스크 탐색기입니다. 방향키와 Vim 단축키 탐색, 빠른 필터링, 다중 선택, Finder 미리보기 및 휴지통 이동을 지원합니다. 외장 드라이브는 기본 뷰에서 제외되며 `mo analyze /Volumes`로 확인할 수 있습니다. `mo analyze /private/tmp`를 사용하면 자동 삭제 없이 임시 파일만 확인할 수 있습니다.

크기 뒤에 `+`가 붙은 항목은 부분 검사를 의미하며, `unknown`은 계산이 불가능했음을 나타냅니다. 일시적인 시간 초과로 중단된 결과는 기존 캐시를 덮어쓰지 않으므로 나중에 다시 검사하여 보완할 수 있습니다. macOS가 터미널의 읽기를 허용하지 않는 폴더는 접근 권한이 바뀔 때까지 부분 검사로 남습니다. 터미널에는 상위 30개 항목만 표시되므로 읽을 수 없는 항목이 목록 밖에 있을 수 있지만, 합계는 여전히 부분 검사로 표시됩니다. JSON 출력에는 모든 항목이 포함됩니다.

`mo analyze --json /path` 출력에는 결과 전체와 각 항목의 `scan_status`(`complete`, `partial`, `unavailable`)가 포함됩니다. 숫자 크기는 실제로 측정한 바이트이며, `unavailable`일 때의 0은 빈 디렉터리를 뜻하지 않습니다. 부분 검사도 종료 코드 0으로 끝나므로 스크립트에서는 `scan_status`를 확인해야 합니다. 완전성은 Mole의 기존 검사 제외 범위 안에서만 판단되며, 파일 시스템의 원자적 스냅샷을 보장하지 않습니다.

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

### 시스템 상태 (Status)

`mo status`는 하드웨어, 시스템 부하, 디스크 읽기/쓰기, 네트워크 트래픽, 전원 및 프로세스를 한눈에 보여주는 읽기 전용 대시보드입니다.

기본 IPv4 라우팅이 VPN이나 터널 인터페이스를 사용하는 경우 물리 어댑터와의 중복 집계를 방지하기 위해 해당 인터페이스를 추적합니다. JSON 출력에는 라우팅된 터널을 포함해 인터페이스별 속도가 남고, 기본 경로가 아닌 유휴 터널은 숨겨집니다.

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

건강 점수는 CPU, 메모리, 여유 공간, SMART 상태, 입출력, 온도, 배터리 상태, 가동 시간을 종합하여 산출합니다. `k` 키로 고양이 표시 전환, `c` 키로 표시 코어 수 조절, `q` 키로 종료할 수 있으며, 설정은 자동 저장됩니다.

<details>
<summary><strong>JSON, NDJSON 및 프로세스 알림</strong></summary>

- `mo analyze --json ~/Documents`: 지정 경로의 디스크 분석 결과를 JSON으로 출력합니다
- `mo status --json`: 현재 시스템 상태 스냅샷을 JSON으로 출력합니다
- `mo status | jq '.health_score'`: 출력이 파이프로 연결되면 자동으로 JSON 모드로 전환됩니다
- `mo status --watch --interval 2s`: NDJSON(줄바꿈 구분 JSON) 형식으로 실시간 스트리밍합니다
- `mo history --json`: 정리 작업 이력을 JSON으로 출력합니다. 각 세션에는 `run_id`(불투명한 문자열이며 식별 정보가 기록되지 않았으면 빈 값)와 `attribution`이 들어 있으며, 식별된 실행은 `run`, 예전 명령 단위 묶음은 `command`, 예전 마커로 중단과 겹친 실행을 구분할 수 없으면 `ambiguous`입니다. 기록된 작업은 계속 확인할 수 있지만 `ambiguous` 개수는 개별 실행에 정확히 나눌 수 없습니다. `ended_at`이 비어 있으면 종료 마커가 기록되지 않은 것입니다.

```text
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

좀비 프로세스 진단은 읽기 전용이며, 프로세스를 임의로 종료하거나 건강 점수를 차감하지 않습니다. Mole이 프로세스 샘플을 한 번도 수집하지 못한 동안에는 `process_collected_at`, `process_stale`, `zombie_count`, `zombie_parents_complete`가 생략되고 `zombie_parents`는 `null`입니다. 이후의 fast/watch 스냅샷은 마지막으로 성공한 샘플을 원래의 `process_collected_at` 그대로 재사용하며 `process_stale: true`로 표시하고, 새 프로세스 샘플을 얻으면 `false`가 됩니다. `0`은 Mole이 측정한 결과 좀비 프로세스가 없다는 뜻입니다. 부모 프로세스 요약은 확인된 상위 세 개까지만 담으며, `zombie_parents_complete: false`는 귀속 정보를 얻지 못했거나 불완전하거나 잘렸다는 뜻입니다.

특정 수집기에서 에러가 발생하더라도 `mo status --json`은 가용한 지표를 정상 출력하고 stderr에 에러를 기록하며 정상 종료(코드 0)합니다. `--watch`도 같은 방식으로 스트리밍을 이어 갑니다. CPU, 메모리, 디스크, 프로세스 지표를 모두 수집하지 못했거나 JSON 출력에 실패한 경우에만 코드 1로 종료합니다.

높은 CPU 사용률을 지속하는 프로세스에 대한 읽기 전용 알림도 제공되며, `--proc-cpu-threshold`, `--proc-cpu-window`, `--proc-cpu-alerts=false`로 조정하거나 끌 수 있습니다.

</details>

### 프로젝트 정리 (Purge)

`mo purge`는 언제든 다시 빌드할 수 있는 프로젝트 산출물(`node_modules`, `target`, `.build`, `build`, `dist` 등)을 탐색합니다. 프로젝트별로 묶어 보여주며, 체크하여 승인한 항목만 휴지통을 거치지 않고 영구 삭제합니다. 최근 7일 내 변경되었거나 변경 시점을 확인할 수 없는 항목은 기본적으로 체크 해제됩니다. `fd`를 우선 사용하고 없을 경우 `find`로 대체하며, 배포 키 파일, 중첩된 Git 저장소, Git 추적 파일이 포함된 디렉터리는 자동으로 보호됩니다. 비대화형 모드는 `mo purge --yes`가 필요하고, `mo purge --dry-run`으로 후보를 먼저 확인할 수 있습니다.

Page Up/Down 또는 `h`/`l`로 페이지 이동, `[`/`]`로 프로젝트 간 이동, `X`로 해당 프로젝트를 건너뛰고 다음으로 이동합니다. `/`로 프로젝트 경로와 산출물 이름을 검색하고, `n`으로 선택 상태를 바꾸지 않고 다음 일치 항목을 찾으며, Enter 키는 최종 경로 확인 화면을 엽니다. 표시되는 용량은 추정치이며, 측정하지 못한 산출물과 불완전한 검사는 따로 표시됩니다.

<details>
<summary><strong>Purge 출력 예시</strong></summary>

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
<summary><strong>사용자 지정 검사 경로</strong></summary>

`mo purge --paths`를 실행하여 검사할 경로를 설정하거나 `~/.config/mole/purge_paths` 파일을 직접 편집하세요:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

사용자 지정 경로가 설정되면 해당 디렉터리만 검사합니다. 미설정 시 기본 경로(`~/Projects`, `~/GitHub`, `~/dev` 및 지원되는 에이전트 worktree 디렉터리)를 탐색합니다. 탐색 중 얻은 불완전한 결과는 저장하지 않습니다. 검사는 지정된 루트 아래 최대 6단계까지 진행되며, 더 깊은 프로젝트는 가까운 루트를 추가하세요. Purge는 worktree 안의 다시 빌드할 수 있는 산출물만 삭제하며 worktree 자체는 삭제하지 않습니다.

</details>

### 설치 패키지 정리 (Installer)

`mo installer`는 다운로드, 데스크탑, Homebrew 캐시, iCloud, Mail, Telegram 등 자주 쓰이는 디렉터리에서 DMG, PKG, MPKG, ISO, XIP 및 설치용 ZIP 파일을 찾습니다. 삭제 전 각 파일의 용량과 위치가 표시됩니다. 검사에는 전체 제한 시간이 적용되며, 검사나 메타데이터 확인이 실패하거나 시간 초과되면 목록을 버리고 파일을 선택하지 않습니다. 손상되었거나 읽을 수 없는 ZIP 압축 파일은 건너뛰고, 심볼릭 링크로 된 검사 루트는 지원하지만 그 아래의 심볼릭 링크는 따라가지 않습니다. 최종 삭제 직전에는 파일 변경 여부를 한 번 더 확인합니다.

<details>
<summary><strong>Installer 출력 예시</strong></summary>

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

## 퀵 런처

<details>
<summary><strong>Raycast 및 Alfred 설정</strong></summary>

Clean, Uninstall, Optimize, Analyze, Status 5개 기능을 실행하는 런처를 한 번에 설치합니다:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

이 스크립트는 Raycast 명령어를 추가하고, Alfred 설정이 감지되면 `clean`, `uninstall`, `optimize`, `analyze`, `status` 키워드가 연결된 Alfred Workflow를 함께 생성합니다.

Raycast 설정 방법:

1. **Raycast Settings > Extensions > Script Commands**를 엽니다.
2. `~/Library/Application Support/Raycast/script-commands` 폴더를 스크립트 디렉터리로 추가합니다.
3. Raycast에서 **Reload Script Directories**를 실행합니다.

런처는 시스템 터미널(Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm, Warp)을 자동 감지합니다. `MO_LAUNCHER_APP=<이름>`으로 터미널을 지정하거나 [Kaku](https://github.com/tw93/Kaku)에서 직접 실행할 수도 있습니다.

</details>

## 커뮤니티

Mole 제작에 힘을 보태주신 모든 기여자분들께 감사드립니다. 이분들을 팔로우해 보세요 ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole 기여자" width="1000" />
</a>

<br/><br/>
X (Twitter)에 공유해 주신 사용자들의 생생한 후기:

<img src="./docs/img/mole-love.png" alt="커뮤니티 후기" width="1000" />

영상 설명이 편하신가요? PAPAYA 電腦教室에서 제작한 [Mole 튜토리얼 영상](https://www.youtube.com/watch?v=UEe9-w4CcQ0)을 확인해 보세요.

## 후원 및 응원

- [Mole for Mac](https://mole.fit)을 구매하시는 것이 Mole 개발을 지속하는 가장 직접적인 힘이 됩니다
- Mole이 마음에 드셨다면 GitHub Star를 눌러주시고, [주변에 공유](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.)해 주시거나 Issue/PR로 함께해 주세요
- 제게는 '탕위안'과 '콜라'라는 고양이 두 마리가 있는데, Mole이 유용하셨다면 두 아이에게 <a href="https://cats.tw93.fun?name=Mole" target="_blank">맛있는 캔 🥩</a> 하나 선물해 주세요

<details>
<summary>이미 고양이들에게 간식을 선물해 주신 분들 🐱</summary>
<br/>
<a href="https://cats.tw93.fun?name=Mole"><img src="https://cdn.jsdelivr.net/gh/tw93/sponsors@main/assets/sponsors.svg" alt="Mole 후원자" width="1000" loading="lazy" /></a>
</details>

## 라이선스

Mole은 GPL-3.0 라이선스 하에 오픈소스로 공개되어 있습니다. 자세한 내용은 [LICENSE](LICENSE)를 참조하세요. 코드를 수정하여 배포하는 경우 동일한 라이선스를 유지해야 합니다. 프로젝트를 포크하는 경우 고유한 이름을 사용하고 Mole을 원출처로 명시해 주세요. [Mole for Mac](https://mole.fit)은 별도의 비공개 소스 앱입니다. Mole은 앞으로도 계속 유지보수됩니다.
