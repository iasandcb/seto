#!/usr/bin/env bash
# Build seto-ffi for Apple and the Swift bindings the macOS package and the
# iOS project link. Xcode Cloud has no Rust toolchain, so ci_post_clone.sh
# runs this after checkout instead of committing the binary.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
    Darwin) ;;
    *) echo "Apple XCFramework는 macOS에서만 만듭니다 (지금은 $(uname -s))." >&2; exit 1 ;;
esac

if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
fi
# shellcheck disable=SC1090
. "${CARGO_HOME:-$HOME/.cargo}/env"
rustup toolchain install stable --profile minimal
rustup target add --toolchain stable \
    aarch64-apple-darwin x86_64-apple-darwin \
    aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

cd "$repo/core-rs"
targets=(
    aarch64-apple-darwin
    x86_64-apple-darwin
    aarch64-apple-ios
    aarch64-apple-ios-sim
    x86_64-apple-ios
)
for target in "${targets[@]}"; do
    cargo +stable build --locked --release -p seto-ffi --lib --target "$target"
done

host="$(rustc +stable -vV | awk '/^host:/{print $2}')"
library="target/${host}/release/libseto_ffi.dylib"
if [[ ! -f "$library" ]]; then
    echo "UniFFI 메타데이터를 읽을 호스트 라이브러리가 없습니다: $library" >&2
    exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cargo +stable run --locked --release -p seto-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library "$library" --language swift --out-dir "$stage/swift"

headers="$stage/headers"
mkdir -p "$headers"
cp "$stage/swift/seto_ffiFFI.h" "$headers/"
cp "$stage/swift/seto_ffiFFI.modulemap" "$headers/module.modulemap"

lipo -create \
    target/aarch64-apple-darwin/release/libseto_ffi.a \
    target/x86_64-apple-darwin/release/libseto_ffi.a \
    -output "$stage/macos.a"
lipo -create \
    target/aarch64-apple-ios-sim/release/libseto_ffi.a \
    target/x86_64-apple-ios/release/libseto_ffi.a \
    -output "$stage/sim.a"
cp target/aarch64-apple-ios/release/libseto_ffi.a "$stage/ios.a"

out="$repo/Apple"
rm -rf "$out/SetoFFI.xcframework" "$out/Generated"
mkdir -p "$out/Generated"
cp "$stage/swift/seto_ffi.swift" "$out/Generated/seto_ffi.swift"
xcodebuild -create-xcframework \
    -library "$stage/macos.a" -headers "$headers" \
    -library "$stage/ios.a" -headers "$headers" \
    -library "$stage/sim.a" -headers "$headers" \
    -output "$out/SetoFFI.xcframework"
echo "Apple/SetoFFI.xcframework"
