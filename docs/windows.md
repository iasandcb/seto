# Windows용 세토 (1단계)

세벌식 390 하드웨어 키보드 입력기입니다. 조합·한/영 자동 전환은 macOS·Android와 같은 Rust `Session`(`core-rs/seto-core`)을 직접 호출합니다. UniFFI는 쓰지 않습니다. 이 단계는 **Windows 11 x64**만 대상으로 하고, DLL은 **서명하지 않습니다**. 32비트와 ARM64는 만들지 않습니다.

## 빌드

Windows에서 Rust stable과 MSVC 빌드 도구가 필요합니다.

```powershell
rustup target add x86_64-pc-windows-msvc
cd core-rs
cargo test --workspace
cargo build -p seto-tsf --release --target x86_64-pc-windows-msvc
```

결과 DLL은 `core-rs\target\x86_64-pc-windows-msvc\release\seto_tsf.dll`입니다. 키 판정과 세션 드라이버 단위 테스트는 macOS·Linux의 `cargo test -p seto-tsf`에서도 돌아갑니다. COM 서버만 Windows 타깃에서 컴파일됩니다.

## 설치

관리자 권한이 필요한 부분은 `regsvr32`입니다. 스크립트는 DLL과 사전을 먼저 `%LOCALAPPDATA%\Seto`에 복사한 뒤, 필요하면 그 경로만 상승된 `regsvr32`로 등록합니다.

저장소를 빌드한 경우:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\install.ps1
```

GitHub Actions 산출물(`seto-windows-x64`)을 푼 경우, `seto_tsf.dll`과 `Resources\`가 스크립트 옆에 있습니다. 그 폴더에서 `install.ps1`을 실행합니다. 다른 경로의 DLL은 `-DllPath`, 사전 폴더는 `-Resources`로 지정합니다.

사전(`english-words.txt`, `english-extra.txt`, `korean-words.txt`, `korean-valid.txt`)이 있으면 자동 한/영 전환이 macOS와 같은 사전을 씁니다. 없어도 세벌식 조합 자체는 동작합니다.

등록 후:

1. 한국어 언어 팩이 없으면 설정 → 시간 및 언어 → 언어 및 지역에서 한국어를 추가합니다.
2. 한국어 옵션 → 키보드에서 **세토**를 추가합니다. 목록에 없으면 한 번 로그아웃했다가 다시 로그인합니다.
3. 작업 표시줄 입력 표시기에서 세토를 고릅니다. 프로필 언어는 ko-KR(`0x0412`)입니다.

## 제거

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\uninstall.ps1
```

`%LOCALAPPDATA%\Seto\seto_tsf.dll` 등록을 지우고 파일을 삭제합니다. `Resources` 사전은 남겨 둡니다. DLL이 사용 중이면 로그아웃한 뒤 같은 경로를 지우면 됩니다.

## 동작

- 물리 글쇠는 스캔 코드(ANSI QWERTY 위치)로 읽고, 스캔 코드가 없으면 가상 키로 읽습니다. 그 문자를 세벌식 390 `Session`에 넘깁니다.
- 조합 중 한글은 밑줄(`TF_ATTR_INPUT`, 실선)로 표시합니다.
- 공백·문장 부호·단어 경계는 코어가 확정합니다. Enter·Tab·Esc·방향키·포커스를 잃으면 조합을 확정한 뒤 그 키는 앱으로 넘깁니다.
- Backspace는 코어를 거칩니다. 조합이 없으면 앱이 지웁니다.
- 한/영은 `VK_HANGUL`(한/영 키)과 **오른쪽 Alt** 탭입니다. Shift+Space도 전환입니다. Shift를 누른 뒤 다른 글쇠를 치고 Space를 누르면 일반 공백입니다(macOS `ShiftSpaceToggleTracker`와 같음).
- 오른쪽 Alt를 누른 채 다른 키를 치면 전환하지 않고, 그 키는 Alt 단축키로 넘깁니다. 왼쪽 Alt·Ctrl·Win 단축키는 조합만 확정하고 앱에 그대로 전달합니다.
- 암호 칸과 TSF 보안 모드에서는 조합하지 않고 키를 넘깁니다.

## 알려진 한계

- 서명되지 않은 DLL입니다. 조직 정책이 미서명 텍스트 서비스를 막으면 목록에 나타나지 않습니다. 그때는 등록 로그 `%LOCALAPPDATA%\Seto\seto-tsf.log`를 확인합니다.
- 편집은 비동기 TSF 편집 세션으로 넣습니다. Windows 11 메모장 같은 몰입형 앱은 동기 세션에서 프로세스가 죽을 수 있어 그렇게 했습니다. 키가 매우 빨리 이어져도 세션은 순서대로 적용됩니다. 앱이 그 사이에 커서를 옮기면 조합이 어긋날 수 있고, 포커스를 잃으면 세션을 비웁니다.
- 후보 창, 소프트 키보드, 언어 표시줄 버튼, Caps Lock 한/영 전환은 없습니다. Caps Lock은 대문자 고정을 만들지 않도록 먹습니다.
- 오른쪽 Alt는 한/영 키로 쓰므로 AltGr이 아닙니다. 단축키는 왼쪽 Alt를 씁니다.
- 숫자 패드와 F키는 조합하지 않고 앱으로 넘깁니다.
- 오타 기록 파일, 자판 전환 UI, 터미널·주소창 전용 모드는 이 단계에 없습니다. 터미널도 일반 한글 모드로 시작합니다.
- x64 전용입니다.

## 손으로 확인할 목록

각 앱에서 세토를 고른 뒤 확인합니다.

| 앱 | 확인할 것 |
| --- | --- |
| 메모장 | `kf`가 밑줄 그은 `가`로 보이다가 Space로 `가 `가 확정되는지. Backspace가 음절을 되돌리는지. Enter가 줄을 바꾸며 조합을 끝는지. 한/영 키, 오른쪽 Alt 탭, Shift+Space가 다음 글의 한/영을 바꾸는지. Ctrl+C가 글자를 집어넣지 않는지. |
| Chrome | 웹 페이지 입력칸과 주소창에서 조합 밑줄과 확정이 같은지. Ctrl+T 같은 단축키가 페이지로 가는지. 암호 칸은 쿼티 그대로인지. |
| VS Code | 편집기에서 `했어`(글쇠 `mr2jt`)가 조합되다 Space나 Enter로 확정되는지. 확정된 영문이 자동 전환으로 바뀌는지(사전을 설치했을 때). |
| Windows Terminal | Enter가 조합을 확정하고 셸에 줄을 넘기는지. Ctrl+C가 셸 단축키로 동작하는지. 방향키가 커서를 옮기는지. |

자동 전환을 보려면 `install.ps1`이 `Resources`를 복사했는지 확인합니다. 사전이 없으면 한글 조합만 기대하면 됩니다.
