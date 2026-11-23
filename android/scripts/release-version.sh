#!/usr/bin/env bash
# Map an android-vX.Y.Z tag to Android versionName / versionCode.
# Source it (`source release-version.sh android-v0.1.0`) or execute it.
# The tag is only digits and dots, so the printed assignments contain no shell syntax.

set -euo pipefail

tag="${1:-}"
if [[ ! "$tag" =~ ^android-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "tag must match android-vX.Y.Z (for example android-v0.1.0), got: ${tag:-<empty>}" >&2
  exit 1
fi
major=$((10#${BASH_REMATCH[1]}))
minor=$((10#${BASH_REMATCH[2]}))
patch=$((10#${BASH_REMATCH[3]}))
version_name="${major}.${minor}.${patch}"
version_code=$((major * 10000 + minor * 100 + patch))
if (( version_code < 1 || version_code > 2100000000 )); then
  echo "versionCode ${version_code} is outside 1..2100000000" >&2
  exit 1
fi
default_prerelease=0
if (( major == 0 )); then
  default_prerelease=1
fi

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  TAG="$tag"
  VERSION_NAME="$version_name"
  VERSION_CODE="$version_code"
  DEFAULT_PRERELEASE="$default_prerelease"
else
  printf 'TAG=%s\n' "$tag"
  printf 'VERSION_NAME=%s\n' "$version_name"
  printf 'VERSION_CODE=%s\n' "$version_code"
  printf 'DEFAULT_PRERELEASE=%s\n' "$default_prerelease"
fi
