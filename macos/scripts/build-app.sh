#!/usr/bin/env bash
#
# Build the SlurmBar app target.
#
# Requires full Xcode (`xcodebuild`), unlike SlurmKit itself which builds and tests with
# Command Line Tools alone (macos/scripts/test-slurmkit.sh). Signing is deferred to
# Phase 5, so this is an ad-hoc/unsigned Debug build — see the CODE_SIGN_* settings in
# macos/project.yml.
#
# Usage: macos/scripts/build-app.sh [configuration]   # default: Debug
#
# The built app lands in a repo-local DerivedData directory (macos/.build/DerivedData)
# so its path is stable and the snapshot runner can find it without parsing xcodebuild
# output.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_dir="$(cd "${script_dir}/.." && pwd)"
configuration="${1:-Debug}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found — full Xcode is required for the app target." >&2
  exit 1
fi
# `xcode-select -p` pointing at the Command Line Tools is the failure mode that produces
# a confusing "SDK not found" much later; catch it here.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild is present but not usable. Is xcode-select pointing at Xcode?" >&2
  echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

"${script_dir}/generate-project.sh"

derived_data="${macos_dir}/.build/DerivedData"
mkdir -p "${derived_data}"

echo "==> xcodebuild ${configuration}"
xcodebuild \
  -project "${macos_dir}/SlurmBar.xcodeproj" \
  -scheme SlurmBar \
  -configuration "${configuration}" \
  -derivedDataPath "${derived_data}" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

app="${derived_data}/Build/Products/${configuration}/SlurmBar.app"
if [[ ! -d "${app}" ]]; then
  echo "error: build reported success but ${app} does not exist." >&2
  exit 1
fi

# Ad-hoc sign the bundle. With CODE_SIGNING_ALLOWED=NO the product is only
# linker-signed and its code-signing identifier is "SlurmBar", not the bundle id —
# notificationd then refuses delivery (UNErrorCodeNotificationsNotAllowed), so every
# dev build would have dead notifications. Re-signing the bundle infers the identifier
# from CFBundleIdentifier. Real Developer ID signing lands in Phase 5.
echo "==> ad-hoc codesign"
codesign --force --sign - "${app}"

echo "==> built ${app}"
