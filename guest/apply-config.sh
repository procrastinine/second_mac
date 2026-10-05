#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$base/privacy.env"
export PATH="$HOME/tools/python/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
python "$base/privacy-user.py"
python "$base/configure.py" "$base/config.json"
agents=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("agents",[])' "$base/config.json")
while IFS= read -r agent; do
  case "$agent" in
    pi|codex|claude) python "$base/agents/$agent.py" "$base/config.json" ;;
    '') ;;
    *) printf 'Unknown agent: %s\n' "$agent" >&2; exit 1 ;;
  esac
done <<< "$agents"
printf 'Guest configuration applied.\n'
