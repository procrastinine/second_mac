#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/second-mac-display.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
/usr/bin/xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$temporary/modules" \
  -Ilib/display/include -framework AppKit -framework Virtualization \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  -framework Vision tests/display-check.m -o "$temporary/display-check"
"$temporary/display-check"
