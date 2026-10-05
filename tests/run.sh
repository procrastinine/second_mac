#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
[[ $(uname -s) == Darwin ]] || { printf 'Host tests require macOS.\n' >&2; exit 1; }
command -v uv >/dev/null || { printf 'Install uv first: brew install uv\n' >&2; exit 1; }
command -v node >/dev/null || { printf 'Install Node first: brew install node\n' >&2; exit 1; }
for test in tests/*_test.rb; do /usr/bin/ruby "$test"; done
bash tests/network-check.sh
uv run --no-project --with xattr python -m unittest discover -s tests -p '*_test.py'
uv run --no-project --with xattr python - <<'PY'
import ast
from pathlib import Path
for directory in ('guest', 'lib'):
    for path in Path(directory).rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
print('Python source syntax passed.')
PY
for file in bootstrap.sh install.sh update.sh agent-vm guest/*.sh guest/agents/*.sh tests/*.sh; do bash -n "$file"; done
for file in lib/*.rb guest/*.rb; do /usr/bin/ruby -c "$file" >/dev/null; done
for file in guest/*.js guest/*.mjs; do
  if [[ -f "$file" ]]; then node --check "$file"; fi
done
swift_cache=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-vm-swift.XXXXXX")
trap 'rm -rf "$swift_cache"' EXIT
for file in lib/*.swift; do /usr/bin/xcrun swiftc -typecheck -module-cache-path "$swift_cache" "$file"; done
for file in lib/*.m guest/*.m; do /usr/bin/xcrun clang -fmodules -fmodules-cache-path="$swift_cache" -fobjc-arc -fsyntax-only "$file"; done
for file in lib/display/*.m; do /usr/bin/xcrun clang -fmodules -fmodules-cache-path="$swift_cache" -fobjc-arc -fsyntax-only -Ilib/display/include "$file"; done
printf 'Host tests and source syntax passed.\n'
