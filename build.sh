#!/bin/bash
# Build, test, and install the 세벌식 390 input method.
# Requires Xcode Command Line Tools (swift). Does not use xcodebuild or sudo.
set -euo pipefail
cd "$(dirname "$0")"

# InputMethodKit discovers input methods through this bundle-ID segment.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
case "${BUNDLE_ID}" in
    *.inputmethod.*) ;;
    *) echo "입력기 Bundle ID에는 소문자 .inputmethod. 구간이 필요합니다: ${BUNDLE_ID}" >&2; exit 1 ;;
esac

echo "== test =="
swift test

echo "== build =="
swift build -c release

APP_DIR="${HOME}/Library/Input Methods"
APP="${APP_DIR}/Seto.app"
BIN=".build/release/Sebeol390"
STAGE="$(mktemp -d)/Sebeol390.app"

mkdir -p "${STAGE}/Contents/MacOS" "${STAGE}/Contents/Resources"
cp "${BIN}" "${STAGE}/Contents/MacOS/Sebeol390"
cp Resources/Info.plist "${STAGE}/Contents/Info.plist"
cp Resources/SetoMenu.pdf "${STAGE}/Contents/Resources/"
cp Resources/english-words.txt Resources/english-extra.txt Resources/korean-words.txt Resources/korean-valid.txt Resources/korean-valid.LICENSE "${STAGE}/Contents/Resources/"
printf 'APPL????' > "${STAGE}/Contents/PkgInfo"
chmod +x "${STAGE}/Contents/MacOS/Sebeol390"

SIGN_ARGS=(--force --sign "${SIGNING_IDENTITY:--}" --identifier "${BUNDLE_ID}")
if [[ -n "${ICLOUD_ENTITLEMENTS:-}" ]]; then
    : "${SIGNING_IDENTITY:?CloudKit requires a signing identity}"
    : "${ICLOUD_PROFILE:?CloudKit requires a provisioning profile}"
    cp "${ICLOUD_PROFILE}" "${STAGE}/Contents/embedded.provisionprofile"
    SIGN_ARGS+=(--entitlements "${ICLOUD_ENTITLEMENTS}")
fi
codesign "${SIGN_ARGS[@]}" "${STAGE}"

if [[ "${INSTALL:-1}" == 0 ]]; then
    mkdir -p .build/package
    ditto "${STAGE}" .build/package/Sebeol390.app
    echo "빌드됨: $(pwd)/.build/package/Sebeol390.app"
    exit 0
fi

mkdir -p "${APP_DIR}"
# Replace a previous copy. The system may be holding the old binary.
killall Sebeol390 2>/dev/null || true
rm -rf "${APP}"
cp -R "${STAGE}" "${APP}"
codesign --verify --strict "${APP}"

echo "== register =="
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f "${APP}"
fi
"${APP}/Contents/MacOS/Sebeol390" --register || echo "등록 호출이 실패했습니다. 로그아웃 후 시스템 설정에서 직접 추가하세요."

echo "설치됨: ${APP}"
