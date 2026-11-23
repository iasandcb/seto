#!/usr/bin/env bash
set -euo pipefail
android_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$android_dir/.." && pwd)"
out="${1:?Pass the generated output directory}"
export PATH="$HOME/.cargo/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"
# Release passwords belong to Gradle. Do not pass them through to cargo.
unset ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_PASSWORD || true
cd "$repo_dir/core-rs"
# Host library is used only to extract UniFFI metadata, never packaged.
cargo build --locked -p seto-ffi --lib
case "$(uname -s)" in
    Darwin) host_library=target/debug/libseto_ffi.dylib ;;
    Linux) host_library=target/debug/libseto_ffi.so ;;
    *) echo "Build host must be macOS or Linux" >&2; exit 1 ;;
esac
cargo run --locked -p seto-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library "$host_library" --language kotlin \
    --config seto-ffi/uniffi.toml --out-dir "$out/kotlin"
# NDK r28 and newer support 16 KB; keep the requirement explicit for both ABIs.
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"
cargo ndk -t arm64-v8a -t x86_64 --platform 34 -o "$out/jniLibs" \
    build --locked --release -p seto-ffi --lib
