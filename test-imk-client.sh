#!/bin/bash
# Exercise the actual IMK controller with a mock editor, without typing into apps.
# Requires a macOS GUI login session, like the input method itself.
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/sebeol390-clang-cache}"
swift build --disable-sandbox
SEBEOL_BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
SEBEOL_SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "${SEBEOL_SMOKE_DIR}"' EXIT
for name in english-words.txt english-extra.txt korean-words.txt korean-valid.txt; do
    ln -s "${PWD}/Resources/${name}" "${SEBEOL_SMOKE_DIR}/${name}"
done
if [[ -f "${SEBEOL_BIN_DIR}/Sebeol390Core.o" ]]; then
    SEBEOL_CORE_OBJECTS=("${SEBEOL_BIN_DIR}/Sebeol390Core.o")
else
    SEBEOL_CORE_OBJECTS=("${SEBEOL_BIN_DIR}/Sebeol390Core.build/"*.o)
fi
swiftc -swift-version 6 -module-cache-path "${CLANG_MODULE_CACHE_PATH}" \
    -I "${SEBEOL_BIN_DIR}" -I "${SEBEOL_BIN_DIR}/Modules" \
    Sources/Sebeol390IME/InputController.swift \
    Sources/Sebeol390IME/FocusedElementReader.swift \
    Sources/Sebeol390IME/ModeStatusItem.swift \
    Sources/Sebeol390IME/CapsLock.swift \
    Sources/Sebeol390IME/StatisticsSync.swift \
    Tests/Integration/ClientSmoke.swift "${SEBEOL_CORE_OBJECTS[@]}" \
    -o "${SEBEOL_SMOKE_DIR}/ClientSmoke"
"${SEBEOL_SMOKE_DIR}/ClientSmoke"
