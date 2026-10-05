#!/bin/sh
set -eu
base="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "${1:-}" = --name ]; then
  [ "$#" -ge 2 ] || { printf '%s\n' '--name requires a value' >&2; exit 1; }
  name="$2"
  shift 2
  exec "$base/agent-vm" --name "$name" update "$@"
fi
exec "$base/agent-vm" update "$@"
