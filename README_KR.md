<p align="right"><a href="https://github.com/tw93/Mole#readme">macOS</a> · <b>Windows</b> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <img src="https://cdn.tw93.fun/pic/cole.png" alt="Mole logo" width="120" />
  <h1>Mole CLI for Windows</h1>
  <p><b>Windows PC 심층 정리, 앱 제거, 시스템 최적화, 디스크 분석 및 상태 모니터링. 무료 오픈소스 CLI.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · 한국어 · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/Mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?filter=*-windows&include_prereleases&label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits/windows"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole/windows?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="Mole CLI for Windows 메뉴" width="736" />
</p>

> 💡 이 브랜치는 무료 오픈소스 Windows CLI(`mo`)입니다. 네이티브 앱을 원한다면 [Mole for Windows](https://mole.fit/ko/windows)를 별도로 내려받을 수 있습니다. 삭제 전 항목별 확인, 앱 업데이트, 시작 프로그램 관리, 디스크 단계별 분석, 실시간 상태 확인을 제공합니다. macOS CLI는 [main 브랜치](https://github.com/tw93/Mole#readme)에 있습니다.

## 주요 기능

- **올인원 CLI 툴킷**: CCleaner, IObit Uninstaller, WinDirStat, 작업 관리자 스타일의 워크플로를 하나의 터미널 명령으로 통합
- **심층 정리**: 임시 파일, 캐시, 로그, 브라우저 잔여물을 제거하여 디스크 공간 확보
- **스마트 앱 제거**: 앱과 함께 남은 설치 폴더를 정리
- **디스크 분석기**: 인터랙티브 TUI로 디스크 사용량을 탐색하고 대용량 파일 탐색
- **시스템 유지보수**: DNS 플러시, 시스템 드라이브 최적화, 디스크 상태 점검
- **실시간 모니터링**: CPU, 메모리, 디스크, 네트워크 및 프로세스 상태를 실시간 확인

## 빠른 시작

Mole은 Windows 10 및 11에서 내장된 Windows PowerShell 5.1로 동작합니다. 스크립트 설치에는 Git이 필요하며, 소스가 최신 릴리스와 다르면 네이티브 도구를 빌드하기 위해 Go도 필요합니다. `%LOCALAPPDATA%\Programs\mole-cli`에 설치되며, `mo`와 `mole`이 PATH에 추가됩니다.

**Scoop으로 설치**

```powershell
scoop install mole
```

**또는 스크립트로 설치**

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

Mole은 이 GitHub 저장소, Scoop, 그리고 Windows 앱용 [mole.fit](https://mole.fit/ko/windows)에서만 배포됩니다. "Mole 기반"이라고 소개하는 다른 앱이나 인코딩된 명령을 터미널에 붙여 넣으라고 하는 사이트는 Mole과 관련이 없습니다.

**AI 에이전트로 설치**

에이전트에게 이렇게 말하면 됩니다:

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

스킬을 직접 설치할 수도 있습니다. 설치하면 Claude Code, Codex, Cursor 등 에이전트가 무엇이든 삭제하기 전에 `--dry-run`으로 목록을 먼저 보여 주고, 앱 제거와 관리자 권한이 필요한 단계는 직접 실행하도록 남겨 둡니다. 업데이트는 `npx skills update -g -y`로 합니다.

```powershell
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

호스트 플러그인으로 설치하려면 Claude Code에서 `/plugin marketplace add tw93/Mole` 다음 `/plugin install mole@mole`, Codex에서 `codex plugin marketplace add tw93/Mole` 다음 `codex plugin add mole@mole`을 실행합니다.

**실행**

```powershell
mo                           # 대화형 메뉴
mo clean                     # 심층 정리
mo uninstall                 # 설치된 앱과 잔여 파일 제거
mo optimize                  # 캐시와 서비스 새로고침
mo analyze                   # 시각적 디스크 탐색기
mo status                    # 실시간 시스템 상태 대시보드
mo purge                     # 프로젝트 빌드 결과물 정리

mo update                    # Mole 업데이트
mo remove                    # 이 PC에서 Mole 삭제
mo --help                    # 도움말 표시
mo --version                 # 설치된 버전 확인
```

**안전 미리보기**

```powershell
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # 미리보기 + 상세 로그
mo clean --whitelist         # 보호할 경로 관리
mo clean --system            # 시스템 수준 정리 포함(관리자 권한으로 실행)
mo purge --paths             # 프로젝트 검사 디렉터리 구성
mo analyze D:\               # 다른 드라이브 분석
mo uninstall --list          # 설치된 앱 목록 표시, 파이프로 보내면 JSON
mo analyze --json D:\        # 디스크 분석을 JSON으로 출력
```

<details>
<summary><strong>기타 설치 옵션</strong></summary>

설치 전에 코드를 검토하려면 `windows` 브랜치를 클론한 뒤 그 자리에서 설치 프로그램을 실행하세요. `.git`이 유지되므로 나중에 `mo update`를 사용할 수 있습니다:

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\mole-cli"
git clone --branch windows https://github.com/tw93/Mole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

시작 메뉴 항목이 필요하면 `-CreateShortcut`을 추가하세요. 삭제하려면 `mo remove`를 실행합니다.

</details>

## 안전성 및 신뢰성

Mole은 파일을 삭제할 수 있으므로 경로를 검증하고, 시스템 및 프로필 위치를 보호합니다. `uninstall`, `purge`, `remove` 명령은 삭제 전에 확인을 요청합니다. 안전하게 변경할 수 있다고 확인할 수 없는 항목은 건너뜁니다.

- `clean`, `uninstall`, `purge` 명령은 파일을 삭제할 수 있으므로 먼저 `--dry-run`으로 확인하고 필요 시 `--debug`를 함께 사용하세요
- `clean`과 `purge`는 영구 삭제하며, 검증된 `uninstall` 잔여 파일은 휴지통으로 이동하고 앱 자체의 제거 프로그램은 기존 동작을 유지합니다. `mo analyze`에서 삭제한 파일도 휴지통으로 이동됩니다
- Mole은 일반 사용자 권한으로 실행하세요. PowerShell을 관리자 권한으로 실행하지 않으면 시스템 수준 단계는 건너뜁니다
- `mo clean --whitelist`로 보호할 경로를 지정하세요
- 정리 내역은 `%USERPROFILE%\.config\mole\operations.log`에 기록되며, `mo history`로 확인하거나 `MO_NO_OPLOG=1`로 비활성화할 수 있습니다
- `C:\Windows`, `C:\Program Files`, Windows Defender 폴더, 사용자 프로필 루트는 절대 건드리지 않습니다

취약점 신고 방법과 안전 경계는 [SECURITY.md](SECURITY.md)를 참고하세요.

## 세부 기능 안내

아래 화면은 테스트 PC에서 캡처했습니다. 실제 표시 항목과 용량은 사용 중인 PC 환경에 따라 다릅니다.

### 심층 정리 (Clean)

```powershell
mo clean --dry-run
```

<img src="./docs/img/clean-windows.png" alt="mo clean --dry-run 미리보기" width="736" />

상세 목록에는 미리보기에서 찾은 모든 경로가 담겨 있습니다. 보존하려는 경로는 화이트리스트에 복사하세요.

### 앱 제거 (Uninstall)

```powershell
mo uninstall
```

레지스트리와 Windows 앱에서 설치된 프로그램을 용량이 큰 순서로 나열한 뒤, 선택한 프로그램을 자체 제거 프로그램으로 삭제하고 남은 설치 폴더를 정리합니다. `mo uninstall --dry-run`은 아무것도 실행하지 않고 각 앱이 사용할 제거 프로그램과 삭제될 항목을 보여줍니다.

<img src="./docs/img/uninstall-windows.png" alt="mo uninstall 앱 목록" width="736" />

### 시스템 최적화 (Optimize)

```powershell
mo optimize --dry-run
```

<img src="./docs/img/optimize-windows.png" alt="mo optimize --dry-run 미리보기" width="736" />

디스크 최적화와 ARP 캐시 플러시 같은 단계는 관리자 권한이 필요하며, 권한이 없으면 건너뜁니다. 이 단계까지 포함하려면 PowerShell을 관리자 권한으로 실행하세요.

### 디스크 분석 (Analyze)

```powershell
mo analyze
mo analyze D:\
```

<img src="./docs/img/analyze-windows.png" alt="mo analyze 개요" width="807" />

macOS 버전과 같은 레이아웃의 인터랙티브 디스크 탐색기입니다. 방향키로 폴더를 이동하고, `Backspace`로 뒤로 가며, `T`로 가장 큰 파일을 나열하고, `Del`로 선택한 항목을 확인 후 휴지통으로 이동합니다.

### 시스템 상태 (Status)

```powershell
mo status
```

<img src="./docs/img/status-windows.png" alt="mo status 대시보드" width="1000" />

건강 점수, CPU, 메모리, 디스크, 전원, 네트워크, 가장 활발한 프로세스를 보여주는 실시간 대시보드입니다.

### 프로젝트 정리 (Purge)

```powershell
mo purge --dry-run
```

프로젝트 폴더에서 빌드 결과물(`node_modules`, `target`, `build`, `dist`, `venv` 등)을 찾아, 정리할 프로젝트를 직접 선택할 수 있게 합니다. 직접 선택하기 전에는 아무것도 선택되어 있지 않습니다. 검사할 폴더는 `mo purge --paths`로 구성하세요.

## 커뮤니티

Mole 제작에 힘을 보태주신 모든 기여자분들께 감사드립니다. 이분들을 팔로우해 보세요 ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Mole 기여자" width="1000" />
</a>

## 후원 및 응원

- [Mole for Windows](https://mole.fit/ko/windows)을 구매하시는 것이 Mole 개발을 지속하는 가장 직접적인 힘이 됩니다
- Mole이 도움이 되셨다면 GitHub Star를 눌러주시고, [주변에 공유](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole/tree/windows&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Windows%20PC.)해 주시거나 Issue/PR로 함께해 주세요
- 기여는 언제나 환영합니다. 먼저 [CONTRIBUTING.md](CONTRIBUTING.md)를 읽어 주세요
- 제게는 '탕위안'과 '콜라'라는 고양이 두 마리가 있는데, Mole이 조금이라도 도움이 되셨다면 두 아이에게 <a href="https://cats.tw93.fun?name=Mole" target="_blank">맛있는 캔 🥩</a> 하나 선물해 주세요

## 라이선스

Mole은 GPL-3.0 라이선스 하에 오픈소스로 공개되어 있습니다. 자세한 내용은 [LICENSE](LICENSE)를 참조하세요. 수정한 버전을 배포하는 경우 동일한 라이선스를 유지해야 합니다. 프로젝트를 포크하는 경우 고유한 이름을 사용하고 Mole을 원출처로 명시해 주세요. 자세한 내용은 [TRADEMARK.md](TRADEMARK.md)를 참조하세요.
