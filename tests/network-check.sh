#!/bin/bash
set -euo pipefail
command -v go >/dev/null || { printf 'Install Go first: brew install go\n' >&2; exit 1; }
network_test_root=$(cd -- "$(dirname -- "$0")/../lib/network" && pwd)
network_test_temp=$(mktemp -d "${TMPDIR:-/tmp}/second-mac-network.XXXXXX")
trap 'rm -rf "$network_test_temp"' EXIT
cp "$network_test_root/"*.go "$network_test_temp/"
cd -- "$network_test_temp"
export GOWORK=off GOTELEMETRY=off
go mod init second-mac-network-test
go get github.com/containers/gvisor-tap-vsock@latest
go mod tidy
go test -race ./...
