#!/usr/bin/env python3
"""Verify actual packaged libraries, including UniFFI's JNA dependency."""
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

android = Path(__file__).resolve().parents[1]
apk = android / "app/build/outputs/apk/debug/app-debug.apk"
sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
ndk = Path(os.environ.get("ANDROID_NDK_HOME", sdk / "ndk/28.2.13676358"))
readelf = next(ndk.glob("toolchains/llvm/prebuilt/*/bin/llvm-readelf"))
expected = {"arm64-v8a", "x86_64"}
found = set()
with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory() as temporary:
    for name in archive.namelist():
        if not name.endswith(".so"):
            continue
        assert name.split("/")[1] in expected, name
        if name.endswith("/libseto_ffi.so"):
            found.add(name.split("/")[1])
        library = Path(temporary) / name
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_bytes(archive.read(name))
        headers = subprocess.check_output([str(readelf), "-lW", str(library)], text=True)
        loads = [line.strip() for line in headers.splitlines() if line.strip().startswith("LOAD ")]
        assert loads and all(int(line.split()[-1], 16) == 0x4000 for line in loads), headers
        print(f"{name}: all {len(loads)} LOAD segments Align 0x4000")
    assert found == expected, found
    for asset in ("keyboard-english.txt", "keyboard-korean-valid.txt", "korean-words.txt", "korean-valid.LICENSE"):
        assert f"assets/lexicon/{asset}" in archive.namelist(), asset
subprocess.run([str(sdk / "build-tools/35.0.0/zipalign"), "-c", "-P", "16", "4", str(apk)], check=True)
print(f"{apk}: {apk.stat().st_size} bytes; 16 KB ZIP alignment verified")
