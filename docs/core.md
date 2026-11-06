# 한/영 전환 코어

이 문서는 현재 구현의 전환 흐름을 설명합니다. 핵심 로직은 `Sources/SetoCore/Session.swift`에 있고, macOS의 키 이벤트 연결은 `Sources/SetoIME/InputController.swift`가 맡습니다. iOS 앱의 하드웨어 키보드 편집기(`iOS/App/HardwareTextEditor.swift`)와 SSH 터미널 입력(`iOS/App/TerminalInput.swift`)도 같은 `Session`을 사용합니다.

## 전환 모델

세토는 글자마다 입력 언어를 바꾸지 않고, 현재 단어의 물리 키 입력 전체를 QWERTY와 선택한 한글 자판(세벌식 390·두벌식·세벌식 최종)으로 다시 읽습니다. `Session`은 키열(`keys`), 구간별 선택 언어(`segments`), 확정 언어(`mode`), 현재 조합 표시(`preedit`)를 별도로 보관합니다.

영문은 확정되는 즉시 편집기에 삽입하고, 한글과 아직 언어가 정해지지 않은 Shift 문장 부호는 편집기의 표시 조합(marked text)으로 유지합니다. 판정 중 읽기가 바뀌면 `FieldEdit`를 만들어 삽입·조합 범위를 갱신합니다. 따라서 영문 접두어와 한글 어미처럼 한 단어 안에서 언어가 갈리는 경우도 처리할 수 있습니다.

```mermaid
flowchart TD
    A[키 이벤트] --> B{보안 입력?}
    B -- 예 --> C0[조합 버림·앱에 전달]
    B -- 아니오 --> B2{단축키?}
    B2 -- Control+Shift+K / T --> C1[설정 전환]
    B2 -- Control+, / Control+. --> C2[← / → 문자 입력]
    B2 -- 기타 Command·Control·Option --> C3[조합 확정 후 앱에 전달]
    B2 -- 아니오 --> D{전환 키인가?}
    D -- Shift+Space / Caps Lock --> E[Session.toggle]
    D -- 일반 문자 --> F[현재 단어 키열에 추가]
    F --> G{자동 전환 켜짐·잠금 없음?}
    G -- 아니오 --> H[잠금 언어 또는 현재 확정 언어로 읽기]
    G -- 예 --> I[우선 규칙 확인]
    I --> J[규칙 미적용 시 후보 경로 점수 비교]
    H --> K[편집기에 FieldEdit 반영]
    J --> K
    K --> L{단어 경계인가?}
    L -- 아니오 --> M[계속 조합]
    L -- 예 --> N[단어 확정·오타 교정·문맥 갱신]
    E --> K
```

## 자동 판정

1. 키를 `KeyboardLayout.atom(for:)`로 `KeyAtom`으로 바꿉니다. 각 키에는 QWERTY 읽기와 현재 한글 자판 읽기가 함께 있습니다.
2. 키열을 `Composer`와 언어별 후보 경로로 읽습니다. 후보 평가는 `Lexicon`의 영어 단어·추가 단어, 한국어 단어, 한국어 유효 단어(오타 보호 목록), 약어, 코드 토큰 정보와 조합 형태를 이용합니다.
3. `Session.recompute`는 잠금(`locked`)이나 자동 전환 꺼짐이면 그 언어로 단어 전체를 읽습니다. 그 밖에는 일반 점수 비교보다 다음 우선 규칙을 순서대로 확인합니다.
   - 파일명·코드 토큰이나 한 글자 영문 뒤에 붙은 한국어 조사 (`a.md를`)
   - Shift 숫자 키 + 한글 꼬리 (`8시`), 대문자로 시작하는 영어 단어 (`Open`, `Int`)
   - 두벌식 자리 키만으로 된 알려진 한국어 단어·어간·채팅 반응 (`ㅋㅋ`, `ㅎㅎ`)
   - 약어 + 한국어 조사 (`AI로`, `ktx는`)
   - 영어 문맥의 짧은 기능어 (`of`)와 영문 모드에서의 영문 유지
   - 한글로는 사전에 없는 영어 단어 (`world`)
   - 한 음절 이상 이어지는 한글 조합 유지, 세벌식 390 Shift 숫자열, 겹자음, 자모 연속
   - 파일명·주소·경로 같은 코드 토큰, 영어 단어 및 접두어
4. 우선 규칙으로 결정되지 않으면 가능한 언어 구간 조합을 점수화합니다(`selectBestPath`). 현재 화면에 보이는 조합을 불필요하게 깨지 않도록 기존 경로를 유지하며, 기존 경로가 조합 경계를 깨거나 점수가 없거나 새 경로가 일정 차이(`Scoring.margin`) 이상 나을 때만 읽기를 바꿉니다.
5. 단어 중간의 읽기가 정해지면 `confirmMode`가 `mode`를 갱신합니다. 한 글쇠, 숫자, 사전 접두어만으로는 확정하지 않습니다. 영문은 두 글자 이상의 영어 단어·약어·코드 토큰일 때, 한글은 두 음절 이상, 사전 단어, 또는 분할된 단어 끝의 조사일 때 모드를 바꿉니다.

단어 경계에서는 `finishWord`가 최종 판정을 수행하고 입력을 확정합니다. 공백과 두 자판에서 같은 문장 부호는 경계 입력입니다. 영문 모드에서는 영문 문장 부호도 단어를 끝내지만, 세벌식 390에서 자모인 키(`;`, `'`, `/` 등)가 한글 조합을 이어가는 경우와 `.`, `:`, `@`, `_`, `-` 등이 코드 토큰을 이어가는 경우는 예외입니다. 한글 모드에서 한글 단어 뒤의 세벌식 390 문장 부호(Shift+B → `!` 등)는 단어를 끝냅니다.

오타 자동 교정이 켜져 있고 잠금이 없으며 단어가 한 언어 구간일 때 `TypoCorrector`가 확정 단어를 사전 단어로 교정할 수 있습니다. 첫 백스페이스 뒤 다시 친 단어는 `TypoLog`에 기록되어 이후 교정에 쓰입니다. `.`, `?`, `!`, 줄바꿈으로 끝나는 단어와, 단어를 확정하는 탐색 키·단축키·Return은 앞 단어 언어 문맥(`contextLanguage`)을 지우지만 다음 단어의 기본 모드 자체는 유지합니다.

```mermaid
flowchart LR
    K[물리 키열] --> R1[한글 자판 읽기]
    K --> R2[QWERTY 읽기]
    R1 --> X{우선 규칙 적용}
    R2 --> X
    X -->|분명한 코드·약어·숫자·한글 형태| S[해당 언어 경로 선택]
    X -->|판정 보류| P[사전·조합 경로 점수 비교]
    P -->|기존 조합이 유효| H[조합을 유지]
    P -->|새 경로 우세| S
    S --> V[실시간 표시 반영]
    H --> V
    V --> C{단어 경계}
    C -->|아니오| K
    C -->|예| F[최종 확정·오타 교정·다음 단어 문맥 저장]
```

### 단어 안의 언어 구간

후보 경로는 단어 전체를 한 언어로만 처리하지 않습니다. `deploy했는데`, `AI로`처럼 먼저 확인된 영어·약어 뒤에 한글이 오면 구간을 나눠 선택합니다. 언어 경계는 한글 조합 경계와도 일치해야 하며, 초성·중성·종성 중간에서는 나누지 않습니다. `.`, `/`, `:`, `@` 등이 이어지는 파일명·주소·경로는 코드 토큰 규칙으로 영문 구간을 유지합니다. 한국어 조사가 붙은 파일명이나 약어는 전용 분할 규칙이 적용됩니다.

영문 모드에서는 `of`처럼 짧고 한글 음절로도 읽히는 입력을 영어 문맥에서 영문으로 유지합니다. 반대로 한글 모드에서 한글 음절이 자연스럽게 이어지는 동안에는 짧은 영어 단어처럼 보이더라도 한글 조합을 우선합니다. 모드와 현재 단어의 후보 읽기는 서로 다를 수 있으며, 후보만 바뀐 상태에서 모드가 성급히 바뀌지 않도록 분리되어 있습니다.

## 수동 전환과 되돌리기

| 동작 | 현재 단어가 있을 때 | 조합 중이 아닐 때 |
| --- | --- | --- |
| Shift+Space 또는 Caps Lock | 현재 단어의 읽기를 반대로 고정 | 다음 입력의 기본 언어를 반대로 변경 |
| 메뉴에서 한글·영문 선택 | 현재 조합을 확정하고 선택 언어 지정 | 선택 언어 지정 |
| Control+Shift+K | 자동 전환을 켜거나 끔 | 동일 |
| Control+Shift+T | 터미널의 영문 시작·자동 전환 끄기 설정을 켜거나 끔 | 동일 |

Shift+Space는 Shift를 누른 뒤 다른 키를 치지 않았을 때만 전환으로 봅니다(`ShiftSpaceToggleTracker`). `?`(Shift+/)를 친 뒤 Shift를 누른 채 Space를 치면 일반 공백입니다. Caps Lock은 누를 때마다 전환하고 Caps Lock 표시등 상태를 다시 끕니다.

자동 전환 또는 오타 교정 직후 수동 전환을 하면 그 판정을 취소해 원래 친 읽기를 복원하고 해당 단어의 언어를 고정합니다. 단어가 이미 경계 입력으로 확정된 직후에도 다음 키를 치기 전이라면 확정된 단어를 되돌려 다시 조합 상태로 만듭니다. 한 단어 안에 두 언어 구간이 있으면 자동 전환 취소보다 우선해, 단어가 시작될 때 언어의 반대 읽기로 단어 전체를 잠급니다. `locked`가 설정된 단어는 이후 자동 판정과 오타 교정으로 덮어쓰지 않으며, 단어가 끝나면 잠금은 해제됩니다.

자동 전환을 끄면 현재 `mode`로 입력합니다. 단, Shift+Space/Caps Lock과 메뉴의 언어 선택은 계속 쓸 수 있습니다. 메뉴 선택은 `forceMode`가 진행 중인 표시를 먼저 확정하고 다음 입력 언어를 설정합니다. 터미널이나 브라우저 주소창에서 Control+Shift+K로 바꾼 자동 전환 상태는 저장된 설정을 바꾸지 않고 해당 입력 컨텍스트에만 적용됩니다.

## macOS 이벤트 흐름

`SebeolInputController`는 키 이벤트를 받아 `Keymap`으로 물리 키의 QWERTY 문자를 구한 뒤 `Session`을 호출하고, 반환된 `FieldEdit`를 `IMKTextInput`의 삽입·표시 조합 API로 적용합니다. 화살표·Tab·Return·Esc·Home·End 등 탐색 키는 현재 입력을 확정한 뒤 앱으로 전달합니다. Command·Control·Option 조합도 조합을 확정하고 앱에 넘기며, Control+,와 Control+.는 각각 `←`, `→` 문자를 입력합니다. Backspace는 조합 중인 단어를 다시 읽고, 지울 키가 없으면 앱에 넘깁니다.

입력 컨텍스트가 새로 시작되면 세션과 단어 문맥을 초기화합니다. 기본은 한글입니다. Terminal은 설정(기본 켜짐, Control+Shift+T)에 따라 영문으로 시작하고 자동 전환을 끕니다. Safari·Chrome 주소창은 영문으로 시작하고 자동 전환과 오타 교정을 끕니다. 주소창 감지는 접근성 권한이 필요하며(`FocusedElementReader`, `AddressBar`), 주소창이 아니었던 브라우저 컨텍스트는 처음 키 입력 때 한 번 더 확인합니다. 보안 입력에서는 진행 중 조합을 버리고 키 처리를 앱에 넘깁니다.

편집기가 IMK 이벤트 없이 조합을 끝내거나 커서를 옮기면(`reconcileComposition`) 텍스트를 고치지 않고 세션만 새로 시작합니다. 한글 자판을 바꾸거나 사전을 다시 불러오면 현재 표시를 확정한 뒤 새 세션을 만듭니다.

```mermaid
sequenceDiagram
    participant OS as macOS
    participant IC as InputController
    participant S as Session
    participant L as Lexicon / Composer
    participant App as 편집기
    OS->>IC: keyDown / flagsChanged
    IC->>IC: 외부 편집 확인, 보안·단축키·탐색 키 확인
    IC->>S: input(Character) / toggle / backspace
    S->>L: 한글·영문 읽기 및 후보 판정
    L-->>S: 선택 경로와 조합 결과
    S-->>IC: SessionUpdate(mode, preedit, field)
    IC->>App: insertText / setMarkedText
    App-->>IC: commitComposition 등 콜백
    IC->>S: commitDisplayed
```

## 주요 상태와 구현 위치

| 개념 | 역할 | 구현 |
| --- | --- | --- |
| `mode` | 확인된 현재 언어, 다음 단어의 기본값 | `Session` |
| `wordMode` | 현재 단어가 시작될 때의 언어 | `Session` |
| `segments` | 현재 단어를 나눈 언어 구간 | `Session` |
| `locked` | 사용자가 명시적으로 고정한 현재 단어 언어 | `Session` |
| `preedit` | 편집기가 표시하는 미확정 한글·문장 부호 조합 | `Session` |
| `contextLanguage` | 같은 문장 안의 앞 단어 언어 | `Session` |
| `FieldEdit` | 편집기에 전달할 삽입·교체·조합 명령 | `Session` |
| 자동 후보 비교 | 우선 규칙, 후보 읽기, 경계, 문맥, 특수 토큰 처리 | `Session.recompute`, `selectBestPath` |
| 물리 키 처리 | macOS 키 코드에서 QWERTY 문자 추출 | `Keymap`, `InputController` |
| Shift+Space 판정 | Shift 누름 동안 다른 키 입력 여부 확인 | `ShiftSpaceToggleTracker` |
| 키별 한글 읽기 | 선택 자판의 한글·영문 `KeyAtom` 생성 | `KeyboardLayout`, `Layout390`, `LayoutDubeol`, `LayoutFinal` |
| 사전 판정 | 단어·약어·코드 토큰 판별 | `Lexicon` |
| 오타 교정 | 확정 단어 교정, 다시 친 단어 기록 | `TypoCorrector`, `TypoLog` |
| 주소창 감지 | Safari·Chrome 주소창 판별 | `AddressBar`, `FocusedElementReader` |
| iOS 하드웨어 키 | USB HID 키 처리, 글자 단위 교체 | `HardwareKeymap`, `KeyboardReplacement` |

전환 예시와 사용자 설정은 저장소 루트의 `README.md`에, 기본 조합·전환 동작 검증은 `Tests/Sebeol390CoreTests/SessionTests.swift`와 `TransitionCorpusTests.swift`에, Shift+Space 판정은 `ShiftSpaceToggleTrackerTests.swift`에 정리되어 있습니다.
