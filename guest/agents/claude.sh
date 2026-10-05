#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$base/privacy.env"
installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl --fail --location --show-error --silent --retry 3 --max-time 120 \
  --proto '=https' --proto-redir '=https' https://claude.ai/install.sh -o "$installer"
/bin/bash "$installer" latest
"$HOME/tools/python/bin/python" "$base/agents/claude.py"
claude --version
