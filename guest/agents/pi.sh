#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$base/privacy.env"
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@latest
pi install npm:pi-web-access
pi update --extensions
"$HOME/tools/python/bin/python" "$base/agents/pi.py" "$base/config.json"
