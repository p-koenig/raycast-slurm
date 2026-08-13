#!/usr/bin/env bash
#
# Run the SlurmKit test suite.
#
# On a machine with Xcode installed this is a plain `swift test --package-path
# macos/SlurmKit`. On a Command Line Tools-only machine two things are broken and this
# script papers over both:
#
#   1. CLT ships Swift Testing at
#        <DEVELOPER_DIR>/Library/Developer/Frameworks/Testing.framework
#      (plus lib_TestingInterop.dylib under <DEVELOPER_DIR>/Library/Developer/usr/lib),
#      while SwiftPM only wires up the Xcode layout
#        <DEVELOPER_DIR>/Platforms/MacOSX.platform/Developer/Library/Frameworks.
#      Without `-F`/`-rpath` you get `no such module 'Testing'`, and once that compiles,
#      a dyld miss at launch.
#
#   2. Worse, the failure is silent. SwiftPM synthesises the test runner
#      (`<Pkg>PackageTests.derived/runner.swift`) with the Swift Testing entry point behind
#      `#if canImport(Testing)`. That synthesised target does *not* inherit the test
#      target's `swiftSettings`, so the flags cannot be fixed in Package.swift — and when
#      `Testing` is unimportable the runner compiles down to a no-op: `swift test` prints
#      "Build complete" and exits 0 having executed zero tests.
#
# Hence: the flags go on the command line (where they reach every target), and the exit
# code is not trusted on its own — the run must report an actual test count.
#
# Usage: macos/scripts/test-slurmkit.sh [extra swift-test args...]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_path="$(cd "${script_dir}/../SlurmKit" && pwd)"

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
xcode_testing="${developer_dir}/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework"
clt_frameworks="${developer_dir}/Library/Developer/Frameworks"
clt_libraries="${developer_dir}/Library/Developer/usr/lib"

extra_args=()
if [[ ! -d "${xcode_testing}" ]]; then
  if [[ -d "${clt_frameworks}/Testing.framework" ]]; then
    extra_args=(
      -Xswiftc -F -Xswiftc "${clt_frameworks}"
      -Xlinker -rpath -Xlinker "${clt_frameworks}"
      -Xlinker -rpath -Xlinker "${clt_libraries}"
    )
  else
    echo "error: Swift Testing not found under ${developer_dir}." >&2
    echo "       Install Xcode or the Command Line Tools (xcode-select --install)." >&2
    exit 1
  fi
fi

log="$(mktemp -t slurmkit-test)"
trap 'rm -f "${log}"' EXIT

set +e
swift test --package-path "${package_path}" \
  ${extra_args[@]+"${extra_args[@]}"} \
  ${@+"$@"} 2>&1 | tee "${log}"
status="${PIPESTATUS[0]}"
set -e

if [[ "${status}" -ne 0 ]]; then
  exit "${status}"
fi

# Guard against the silent-skip described above: a real run always reports a test count.
if ! grep -qE 'Test run with [0-9]+ test' "${log}"; then
  echo "error: swift test exited 0 but no Swift Testing tests were executed." >&2
  echo "       The synthesized runner most likely compiled out its \`#if canImport(Testing)\`" >&2
  echo "       branch. Check the Testing.framework search paths above." >&2
  exit 1
fi
