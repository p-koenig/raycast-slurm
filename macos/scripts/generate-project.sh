#!/usr/bin/env bash
#
# Generate macos/SlurmBar.xcodeproj from macos/project.yml.
#
# The .xcodeproj is gitignored on purpose: project.yml is the source of truth, so a
# checkout has no project file until this runs. Both the app build script and CI call
# it first.
#
# XcodeGen is installed via Homebrew when missing. Set SLURMBAR_NO_INSTALL=1 to fail
# instead of installing (useful on a locked-down machine).
#
# Usage: macos/scripts/generate-project.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_dir="$(cd "${script_dir}/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  if [[ "${SLURMBAR_NO_INSTALL:-0}" == "1" ]]; then
    echo "error: xcodegen is not installed and SLURMBAR_NO_INSTALL=1." >&2
    echo "       Install it with: brew install xcodegen" >&2
    exit 1
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: xcodegen is not installed and Homebrew is unavailable." >&2
    echo "       Install XcodeGen manually: https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
  echo "==> installing xcodegen via Homebrew"
  brew install xcodegen
fi

echo "==> xcodegen $(xcodegen --version 2>/dev/null | tail -n 1)"
cd "${macos_dir}"
xcodegen generate --spec project.yml --project .
