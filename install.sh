#!/bin/sh
set -eu
exec /usr/bin/ruby "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib/install-cli.rb" "$@"
