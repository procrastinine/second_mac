#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/second-mac-keyboard.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
/usr/bin/xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$temporary/modules" \
  -Ilib/display/include -framework AppKit -framework Virtualization \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  -framework Vision tests/keyboard-check.m lib/display/Keyboard.m -o "$temporary/keyboard-check"
"$temporary/keyboard-check"
