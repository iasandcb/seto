# Seto Android IME — phase 3

`com.ias.seto`, minSdk 34 (Android 14), target/compile SDK 35. Hardware QWERTY
and the on-screen keyboard both feed the existing Sebeolsik 390 Rust Session.
Shift+Space toggles only if no other key was typed during that Shift hold;
autorepeat does not toggle again. Password/raw fields pass through on a hardware
keyboard and, on the soft keyboard, insert the visible character directly.
Navigation, Enter, Tab and shortcuts commit the displayed composition and pass
through, as in the desktop oracle.

The soft keyboard follows the iOS touch-keyboard rows: a number row, QWERTY
letters, and a bottom row with ※, ↔, `-`, space, `.`, `?`, and return. Korean
mode shows 390 jamo with the QWERTY character underneath; English mode reverses
that. The home row also has `;` and `'` so choseong ㅂ and ㅌ are reachable.
Tapping a number in Korean mode sends that 390 key (ㅛㅠㅑ on 4 5 6, and so on);
a long-press inserts the digit itself. English number taps are digits, and a
long-press inserts the shifted symbol. ※ toggles the iOS symbol layer; holding
it calls `convertOpenWord`. ↔ calls `toggle` (undo the last automatic conversion
or flip the open word); holding it turns automatic switching on or off. Holding
`-` inserts `→`. Backspace deletes on contact and then repeats: 20 characters,
then word waves. A mode change shows a short toast, `한` or `A`, because the
status bar is often hidden. While a hardware keyboard is the active input the
framework hides this view; the system "show on-screen keyboard" setting brings
it back. Hardware keys keep the previous path. JVM tests cover the 390 caps,
the symbol map, the holds, the backspace cadence, and word waves.

While a normal input field is active, a small white **한** (Korean) or **A**
(English) status icon follows every Session mode update, including automatic
conversion and Shift+Space. The icon is cleared on field finish, password/raw
pass-through, or session failure. This uses
[InputMethodService.showStatusIcon](https://developer.android.com/reference/android/inputmethodservice/InputMethodService#showStatusIcon(int));
visibility depends on the device's system status bar. There is no launcher activity.
The on-screen keyboard is a separate window and is hidden while a hardware
keyboard is the active input.

The `jj` follow-up exposed a shared Swift/Rust core issue, rather than an Android
key or commit bug: `ㅇㅇ` was already a recognized chat reaction, but `jj` is also
a prefix of the bundled English entry `jjs`. English-prefix preference masked
the reaction before it could be selected. Both cores now let that existing
reaction outrank the prefix. Complete words (`jjs`), uppercase input, manual
English mode, and period/domain handling retain their existing behavior.
Regression tests cover open `jj`, space/newline boundaries, and Rust with both
the desktop and Android keyboard lexicons. Swift core changes were necessary
because the new oracle test reproduced the same failure there.

## Build

On the macOS machine used for this phase:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$HOME/.cargo/bin:$PATH"
cd android
./gradlew assembleDebug testDebugUnitTest
python3 scripts/verify-apk.py
```

Gradle 8.11.1 is downloaded by the checked-in wrapper (SHA-256 pinned). AGP 8.9.2,
Kotlin 2.1.20, AndroidX annotations 1.9.1, and JNA 5.17.0 AAR are resolved by
Gradle. UniFFI 0.30.0 is pinned in Cargo. Debug signing needs no release keystore.
The build does not install anything on a device or run an emulator.

`preBuild` runs `scripts/build-rust.sh`: builds a host metadata library, generates
Kotlin with `android = true`, and uses cargo-ndk to build release native libraries
for arm64-v8a and x86_64 at API 34. Both links explicitly pass
`-Wl,-z,max-page-size=16384`. Generated Kotlin/native/assets are build outputs,
not checked-in copies. The APK is `app/build/outputs/apk/debug/app-debug.apk`.
`verify-apk.py` extracts the APK and checks every LOAD segment of every `.so`,
including JNA's `libjnidispatch.so`, plus 16 KB APK ZIP alignment.

## Assets, ownership and editing

Gradle stages existing `iOS/Keyboard/Resources/keyboard-{english,korean-valid}.txt`
and `Resources/korean-words.txt` plus `korean-valid.LICENSE`. No additional
repository dictionaries are introduced. These keyboard sidecars already contain
the expanded English lists and Korean validity entries used by the core.
On first field use, the IME copies them atomically to `filesDir/lexicon-v1` and
passes absolute paths to `loadLexicon`. Bump that directory version whenever
assets change: a file mapped by the process-wide Rust lexicon must never be
modified in place. Same-path initialization is idempotent; different paths in
the same process are rejected.

Each input field has its own `FieldSession`; `shutdown()` drops its core Session,
and generated Kotlin `destroy()` releases the UniFFI handle. `input` accepts one
Unicode scalar encoded as a String. All exported engine operations return
`Result`; Rust panics are caught with unwind enabled (Cargo's default). A panic
while mutating a Session poisons it, and later calls return errors. Android
finishes composition and releases failed sessions. Do not build with panic=abort.

The FFI exposes input/backspace/toggle/convertOpenWord/commitDisplayed/discard,
forceMode, setOptions (autoSwitch/correctsTypos), and state (mode/preedit/document).
No language or composition logic is reimplemented. `FieldEdit` spans remain
UTF-16 code units as `u64`/Kotlin `ULong`, checked before narrowing to Android Int.
The adapter batches edits, finishes composition before deleting a full span,
and explicitly clears marks for clearMarkThenInsert/Mark. Selection callbacks
acknowledge/coalesce expected edits; external caret moves start an empty session
at the new caret. Native backspace is passed through when the core requests no
edit. A native deletion wider than one UTF-16 unit safely resets the session.

Typo records leave Rust through a callback with wrong/wrongKeys/finalText/finalKeys.
Rust retains per-field correction memory and calls foreign code after releasing
the Session lock. Kotlin owns the private `filesDir/typos.jsonl` file, using JSON
fields wrong/wrongKeys/final/finalKeys. Password fields never create a session;
IME_FLAG_NO_PERSONALIZED_LEARNING disables the persistence callback. Logs are
local, backup is disabled, and the manifest requests no network permission.

API references: [UniFFI Android configuration](https://mozilla.github.io/uniffi-rs/0.30/kotlin/configuration.html),
[InputConnection](https://developer.android.com/reference/android/view/inputmethod/InputConnection),
[AGP 8.9 compatibility](https://developer.android.com/build/releases/agp-8-9-0-release-notes).

## Tooling installed for this phase

- Homebrew `openjdk@17` **17.0.21.0.3**; no global Java symlink or shell profile edits.
- Homebrew cask `android-commandlinetools` **15859902** (SDK command-line tools **22.0**), under
  `/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest`.
- SDK root `$HOME/Library/Android/sdk`: `platforms;android-35` **revision 2**,
  `build-tools;35.0.0`, `ndk;28.2.13676358` (**r28c**), and
  `platform-tools` **37.0.1** (the latter installed automatically by AGP).
  SDK licenses were accepted using sdkmanager. No system image/emulator installed.
- `cargo-ndk` **4.1.2** installed with `cargo install cargo-ndk --locked`.
- Rust standard-library targets **aarch64-linux-android** and **x86_64-linux-android**
  added with rustup; the existing Rust/cargo **1.100.0** was retained.
- Gradle wrapper downloaded **8.11.1**, and Gradle/Cargo downloaded the pinned
  project dependencies and their transitive dependencies into normal caches.

Homebrew also installed JDK dependencies: brotli 1.2.1, giflib 6.1.3,
graphite2 1.3.15, icu4c@79 79.1, harfbuzz 15.1.0, jpeg-turbo 3.2.1,
webp 1.6.0, libtiff 4.7.2, little-cms2 2.20.
It upgraded existing dependencies: libpng 1.6.58 → 1.6.59,
freetype 2.14.3 → 2.15.0, libunistring 1.4.2 → 1.5,
fontconfig 2.18.2 → 2.18.3, glib 2.88.2 → 2.90.1,
xorgproto 2025.1 → 2026.1, libx11 1.8.13 → 1.8.14,
libxrender 0.9.12 → 0.9.13, cairo 1.18.4 → 1.18.6,
xz 5.8.3 → 5.8.4, lz4 1.10.0 → 1.11.1.

## Verification

- `cd core-rs && cargo test`: **78 passed** (74 core tests + 4 FFI tests).
  Golden replay: **3661 scenarios / 25238 keystrokes**.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`:
  **157 passed**. Includes the new English-mode `jj` regression.
- `./gradlew assembleDebug testDebugUnitTest`: successful; **7 Android unit tests**
  cover physical mapping, Shift+Space, every FieldEdit, surrogate-pair spans,
  coalesced selections, native backspace tracking, and Ctrl+comma/period with
  all modifier combinations. The Rust/Swift `머지하고` regressions also pass.
- APK inspection: both `libseto_ffi.so` ABIs have all **4 LOAD Align 0x4000**;
  both JNA libraries have all **2 LOAD Align 0x4000**. `zipalign -c -P 16 4` passes.
- Debug APK: `app/build/outputs/apk/debug/app-debug.apk`, **7478249 bytes**.
- No APK/IME was installed, and no phone or emulator runtime testing was performed.
