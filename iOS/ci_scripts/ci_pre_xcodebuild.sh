#!/bin/sh
set -eu

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "CI_BUILD_NUMBER is unset; keeping the project build number unchanged."
  exit 0
fi

# Start above the manually uploaded build numbers; override the offset if needed.
build_number_offset=${BUILD_NUMBER_OFFSET:-5}
next_build_number=$((CI_BUILD_NUMBER + build_number_offset))

if [ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ] && [ -f "${CI_PRIMARY_REPOSITORY_PATH}/iOS/Sebeol390.xcodeproj/project.pbxproj" ]; then
  project_file="${CI_PRIMARY_REPOSITORY_PATH}/iOS/Sebeol390.xcodeproj/project.pbxproj"
else
  project_file="$(dirname "$0")/../Sebeol390.xcodeproj/project.pbxproj"
fi

sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${next_build_number};/g" "$project_file"

if ! grep -q 'CURRENT_PROJECT_VERSION' "$project_file"; then
  echo "No CURRENT_PROJECT_VERSION settings found in ${project_file}." >&2
  exit 1
fi

if grep -E 'CURRENT_PROJECT_VERSION' "$project_file" | grep -Ev ".*CURRENT_PROJECT_VERSION = ${next_build_number};.*"; then
  echo "Failed to set every CURRENT_PROJECT_VERSION to ${next_build_number} in ${project_file}." >&2
  exit 1
fi

echo "Set CURRENT_PROJECT_VERSION to ${next_build_number} in ${project_file}."
