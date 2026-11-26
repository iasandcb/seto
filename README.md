# 세토

쿼티 자판으로 한글과 영문을 오가는 입력기입니다. 조합과 한/영 판정은 Rust 코어 하나이고, macOS 입력기, iOS 키보드, Android IME, Windows 11 x64 TSF가 그 코어를 씁니다. 판정은 기기 안에서 합니다. macOS에서 CloudKit 서명을 넣으면 타자 횟수만 iCloud로 갑니다.

글쇠는 물리 쿼티(ANSI) 위치로 읽습니다. 코어의 한글 자판은 세벌식 390(기본), 두벌식, 세벌식 최종입니다. 화면에서 고를 수 있는 자판은 플랫폼마다 다릅니다.

## 코어

`core-rs` 워크스페이스입니다. 툴체인은 Rust stable입니다.

| 크레이트 | 역할 |
| --- | --- |
| `seto-core` | `Session`, 자판, 사전, 오타 교정 |
| `seto-ffi` | UniFFI 0.30. macOS·iOS·Android가 `FieldSession`으로 호출 |
| `seto-tsf` | Windows TSF. UniFFI 없이 `seto-core`를 직접 호출하는 x64 DLL |

사전은 `Resources/`의 UTF-8 단어 목록입니다. 전환 규칙은 [docs/core.md](docs/core.md), 크레이트 안내는 [core-rs/README.md](core-rs/README.md)입니다.

## 플랫폼

| | macOS | iOS | Android | Windows |
| --- | --- | --- | --- | --- |
| 형태 | 입력기 `Seto.app` | 앱 + 키보드 확장 | IME `com.ias.seto` | TSF 텍스트 서비스 |
| 대상 | macOS 13 이상 | iOS 16 이상 | Android 14 (API 34) 이상 | Windows 11 x64 |
| 코어 연결 | UniFFI | UniFFI | UniFFI | `seto-core` 직접 |
| 하드웨어 자판 | 390·두벌식·최종 | 앱 안에서 390·두벌식·최종 | 390·두벌식·최종 | 390·두벌식·최종 |
| 화면 자판 | 하드웨어만 | 두벌식 | 두벌식 | 하드웨어만 |
| 받는 방법 | `./build.sh` | Xcode | `android-v*` 서명 APK | `windows-v*` zip |

### macOS

메뉴 막대에 한글은 **한**, 영문은 **A**로 표시됩니다. 입력기 메뉴에서 자동 한/영(⌃⇧K), 오타 자동 교정, 한글 자판, 단어 사전, 타자 통계를 다룹니다. Shift+Space와 Caps Lock은 방금 자동으로 바뀐 읽기를 되돌리고, 조합 중이 아니면 한/영을 바꿉니다. Terminal은 영문으로 시작하고 자동 전환을 끌 수 있으며(⌃⇧T), Safari·Chrome 주소창도 영문으로 시작합니다. 주소창을 구분하려면 손쉬운 사용에서 세토를 허용합니다. 암호 칸은 쿼티 그대로 넘깁니다. 후보 창 없이, 치는 도중에 읽기를 바꿉니다.

입력기는 `~/Library/Application Support/Sebeol390/Dictionaries/`의 `english-words.txt`, `english-extra.txt`, `korean-words.txt`, `korean-valid.txt`를 읽습니다. 메뉴의 사전 편집이 이 파일을 바로 열기 때문에, 앱 번들의 목록을 그 폴더에 복사해 둡니다. 학습 단어는 UserDefaults의 `learnedWords.v1`이고, 다시 친 오타는 이 맥의 `~/Library/Application Support/Sebeol390/typos.jsonl`입니다. 번들 목록이 바뀌면 복사본을 새 목록으로 갈아끼우고, 사용자가 넣거나 뺀 줄은 그 위에 다시 얹습니다. 그렇게 사용자 파일을 다시 쓸 때는 직전 내용을 같은 이름의 `.bak`으로 남깁니다. 한 줄에 단어 하나, UTF-8입니다. 고친 뒤 메뉴의 **수정한 사전 다시 불러오기**를 누릅니다.

CloudKit을 쓰려면 Apple Developer에서 App ID `com.ias.inputmethod.seto`에 `iCloud.com.ias.seto`를 연결하고, `MacTypingStatistics` 레코드의 `history`(Bytes)와 `recordName` QUERYABLE 인덱스를 Production에 배포한 뒤, 그 프로파일을 `signing/`에 둡니다. `./build.sh`가 프로파일을 읽어 서명합니다. 프로파일이 없으면 임시 서명이며 통계는 이 맥에만 남습니다. [signing/README.md](signing/README.md)

빌드에는 전체 Xcode가 선택된 상태여야 합니다. `./build.sh`는 `xcodebuild -create-xcframework`로 Apple 바인딩을 만듭니다.

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
./build.sh
```

스크립트는 Rust를 준비하고 `scripts/build-apple-xcframework.sh`로 XCFramework와 Swift 바인딩을 만든 뒤 `swift test`, 릴리스 빌드, `~/Library/Input Methods/Seto.app` 설치와 입력 소스 등록을 합니다. `rustup`이 없으면 그 스크립트가 설치합니다. 설치를 건너뛰려면 `INSTALL=0 ./build.sh`이며, 번들은 `.build/package/Sebeol390.app`입니다.

시스템 설정 → 키보드 → 입력 소스에서 **세토**를 추가합니다. 목록에 없으면 로그아웃 후 다시 로그인합니다. Bundle ID는 `com.ias.inputmethod.seto`입니다.

GUI 로그인 세션에서 IMK와 모의 편집기의 연동은 `./test-imk-client.sh`입니다. 실제 앱의 입력칸에는 키를 보내지 않습니다.

### iOS

안내·연습 앱과 시스템 키보드 확장입니다. 터치 자판은 두벌식이고 문구, 추천, 한 손 모드가 있습니다. 앱 안의 하드웨어 키보드는 세벌식 390·두벌식·세벌식 최종을 고릅니다. 키보드 확장은 다른 앱의 하드웨어 키를 받지 않으며, 전체 접근은 필요하지 않습니다. SSH 터미널과 원격 파일 편집은 [remote/README.md](remote/README.md), 설치와 조작은 [iOS/README.md](iOS/README.md)입니다.

Xcode에서 `iOS/Sebeol390.xcodeproj`의 `Sebeol390` 스킴을 실행합니다. 개발자 디렉터리가 Xcode가 아니면 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 붙입니다. Xcode Cloud는 `iOS/ci_scripts/ci_post_clone.sh`에서 Rust와 XCFramework를 만듭니다. App Store용 바이너리는 이 저장소의 Releases에 없습니다.

### Android

하드웨어 키보드는 세벌식 390(기본), 두벌식, 세벌식 최종 중에서 고릅니다. 사용자별 설정은 세토 앱의 설정 화면에 있습니다. 화면 자판은 두벌식입니다. 문구·추천·한 손 모드는 이 버전에 없고, 상태 표시는 **한** / **A**입니다. 홈 화면 아이콘은 없습니다. 암호 칸은 하드웨어 키를 그대로 넘기고, 화면 자판은 보이는 문자를 바로 넣습니다. 입력 동작은 [android/README.md](android/README.md)입니다.

서명 APK는 [Releases](https://github.com/iasandcb/seto/releases)의 `android-v*` 자산입니다. 릴리스 워크플로는 [PR #39](https://github.com/iasandcb/seto/pull/39)에서 추가 중이며 main에 아직 없을 수 있으므로, 태그 주소를 고정하지 말고 Releases 페이지의 `android-v*` APK를 받습니다. 디버그 키로 설치해 둔 `com.ias.seto`는 인증서가 달라 한 번 제거한 뒤 릴리스 APK를 설치합니다. 설정 → 시스템 → 키보드 → 화면 키보드에서 **Seto**를 켭니다.

로컬 빌드는 JDK 17과 `ANDROID_HOME`이 필요합니다. `android/scripts/build-rust.sh`는 NDK `28.2.13676358`과 `cargo-ndk`로 `arm64-v8a`·`x86_64`를 만듭니다.

```sh
cd android
./gradlew assembleDebug testDebugUnitTest
```

디버그 APK는 `android/app/build/outputs/apk/debug/app-debug.apk`입니다.

### Windows

Windows 11 x64 TSF입니다. DLL은 서명하지 않으며, 대상은 x64뿐입니다. 하드웨어 자판은 세벌식 390(기본), 두벌식, 세벌식 최종 중에서 고릅니다. 사용자별로 저장되며, 설정의 한국어 키보드 세토 옵션에서 바꿉니다. 한/영은 한/영 키, 오른쪽 Alt 탭, Shift+Space입니다. 작업 표시줄은 한글 **가**, 영문 **A**입니다. 후보 창, 화면 자판, 오타 기록 파일, Caps Lock 전환, 터미널·주소창 전용 모드는 빠져 있습니다. 동작·한계·제거는 [docs/windows.md](docs/windows.md)입니다.

다른 PC에서는 git이나 GitHub 로그인 없이 [Releases](https://github.com/iasandcb/seto/releases)의 `windows-v*` zip(`seto-windows-x64.zip`)을 받습니다. 현재 공개된 `windows-v0.1.0`은 prerelease라 `releases/latest`에 포함되지 않습니다. PowerShell에 아래 한 줄을 붙여 넣습니다. `regsvr32` 승인 창이 뜹니다.

```powershell
$dest = Join-Path $env:TEMP 'seto-windows-x64'; New-Item -ItemType Directory -Force -Path $dest | Out-Null; Invoke-WebRequest -Uri 'https://github.com/iasandcb/seto/releases/download/windows-v0.1.0/seto-windows-x64.zip' -OutFile (Join-Path $dest 'seto-windows-x64.zip') -UseBasicParsing; Expand-Archive -Path (Join-Path $dest 'seto-windows-x64.zip') -DestinationPath $dest -Force; $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (-not [Environment]::Is64BitProcess) { $nativePs = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'; if (Test-Path -LiteralPath $nativePs) { $ps = $nativePs } }; & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'install.ps1')
```

태그 정책, 저장소 안의 `scripts/windows/install-release.ps1`, 제거 방법은 [docs/windows.md](docs/windows.md)에 있습니다.

이 저장소에서 직접 빌드하려면 Windows에 Rust stable과 MSVC가 필요합니다.

```powershell
rustup target add x86_64-pc-windows-msvc
cd core-rs
cargo test --workspace
cargo build -p seto-tsf --release --target x86_64-pc-windows-msvc
powershell -ExecutionPolicy Bypass -File scripts\windows\install.ps1
```

DLL은 `core-rs\target\x86_64-pc-windows-msvc\release\seto_tsf.dll`입니다. CI는 `.github/workflows/windows-tsf.yml`이 pull request와 `main`에서 워크스페이스 테스트와 x64 DLL을 만들고, `.github/workflows/windows-release.yml`이 `windows-v*` 태그의 zip을 GitHub Release에 올립니다. 버전 태그에 하이픈이 있으면(`windows-v0.1.0-rc.1`) prerelease입니다.

## 테스트

```sh
cd core-rs && cargo test --workspace
swift test
```

`swift test`는 `Apple/SetoFFI.xcframework`가 있어야 합니다. `./build.sh` 또는 `./scripts/build-apple-xcframework.sh`가 만들고, 그 산출물은 커밋하지 않습니다. `cargo test -p seto-tsf`의 키·세션 테스트는 macOS와 Linux에서도 돌고, COM 서버만 Windows 타깃에서 컴파일됩니다. Android JVM 테스트는 위의 `testDebugUnitTest`입니다. iOS UI 테스트는 [iOS/README.md](iOS/README.md)의 `xcodebuild test`입니다.

## 저장소

```
core-rs/          seto-core, seto-ffi, seto-tsf
Sources/          macOS 입력기(SetoIME)와 Swift 어댑터(SetoCore, SetoSupport)
Tests/            Swift 패키지 테스트
Resources/        사전, 아이콘
iOS/              앱, 키보드 확장
android/          IME
scripts/          Apple XCFramework, Windows 설치 스크립트
docs/             전환 설명, Windows 안내, 개선 제안
signing/          macOS CloudKit 프로파일 (README만 커밋)
remote/           iOS SSH 원격 편집 도우미
.github/workflows Windows CI와 windows-v* 릴리스
```

`Apple/`의 XCFramework와 UniFFI 바인딩은 빌드 산출물입니다.

## 문서

- [전환 코어](docs/core.md)
- [Windows](docs/windows.md)
- [iOS](iOS/README.md)
- [Android](android/README.md)
- [Rust 코어](core-rs/README.md)
- [macOS CloudKit 서명](signing/README.md)
- [SSH 원격 편집](remote/README.md)
- [개선 제안](docs/proposal.md)

라이선스는 [MIT](LICENSE)입니다.
