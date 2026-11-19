#!/bin/sh
set -eu

# SwiftTerm's build-tool plugin requires Xcode Cloud fingerprint checks to be skipped.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

# Xcode Cloud images do not include Rust. Build the Apple XCFramework from the
# sources in this checkout so Archive/TestFlight link the same core as Android.
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
"$root/scripts/build-apple-xcframework.sh"
