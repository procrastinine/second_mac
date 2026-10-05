#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")" && pwd)"
export PATH="$HOME/tools/python/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "$base/privacy.env"
map_agents=$(/usr/bin/ruby -rjson -e '
  configured = JSON.parse(File.read(ARGV.shift)).fetch("agents", [])
  selected = ARGV.empty? ? configured : ARGV.uniq
  abort "Choose configured agents: pi, codex, claude." unless
    (selected - %w[pi codex claude]).empty? && (selected - configured).empty?
  puts selected
' "$base/config.json" "$@")
while IFS= read -r agent; do
  [[ -z "$agent" ]] && continue
  case "$agent" in
    pi|codex|claude) /bin/bash "$base/agents/$agent.sh" ;;
    *) printf 'Unsupported agent: %s\n' "$agent" >&2; exit 1 ;;
  esac
done <<< "$map_agents"
install -m 644 "$base/config.json" "$HOME/.config/agent-vm.json"
printf 'Selected agents installed and configured.\n'
