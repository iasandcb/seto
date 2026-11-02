#!/bin/sh
set -eu

# SwiftTerm's build-tool plugin requires Xcode Cloud fingerprint checks to be skipped.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
