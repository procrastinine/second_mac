#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$base/privacy.env"
npm install -g @openai/codex@latest
"$HOME/tools/python/bin/python" "$base/agents/codex.py"
