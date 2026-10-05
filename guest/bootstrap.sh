#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")" && pwd)"
guest_user=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("user")' "$base/config.json")
/usr/bin/ruby "$base/privacy.rb" "$guest_user"
# Establish the matching resolver before CLT/Homebrew downloads. A native
# router's DHCP DNS is blocked by isolation; the VPN router supplies safe DNS.
/usr/bin/ruby "$base/network-dns.rb"

clt_ready() {
  /usr/bin/xcode-select -p >/dev/null 2>&1 &&
    /usr/bin/xcrun clang --version >/dev/null 2>&1 &&
    /usr/bin/xcrun swiftc --version >/dev/null 2>&1
}
if ! clt_ready; then
  marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$marker"
  trap 'rm -f "$marker"' EXIT
  catalog=$(/usr/sbin/softwareupdate --list 2>&1)
  label=$(printf '%s\n' "$catalog" | /usr/bin/sed -n 's/.*Label: \(Command Line Tools.*\)/\1/p' | /usr/bin/tail -1)
  if [[ -z "$label" ]]; then
    printf 'No Command Line Tools update found. Install CLT in the guest, then rerun install.sh.\n%s\n' "$catalog" >&2
    exit 1
  fi
  /usr/sbin/softwareupdate --install "$label" --verbose
  /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools
  clt_ready || { printf 'Guest Command Line Tools are not ready. Complete any pending Apple prompt, then rerun the host installer.\n' >&2; exit 1; }
fi

# Let the ordinary guest account run Homebrew's official installer without
# granting the agent unrestricted passwordless sudo.
if [[ ! -d /opt/homebrew ]]; then
  /usr/bin/install -d -o "$guest_user" -g admin -m 775 /opt/homebrew
fi
if [[ ! -w /opt/homebrew ]]; then
  printf 'Homebrew prefix is not writable.\n' >&2
  exit 1
fi
/usr/bin/install -d -m 755 /usr/local/bin /usr/local/libexec/agent-vm /etc/agent-vm
/usr/bin/install -o root -g wheel -m 755 "$base/tart-guest-agent" /usr/local/bin/tart-guest-agent
/usr/bin/install -o root -g wheel -m 644 "$base/../lib/core.rb" /usr/local/libexec/agent-vm/core.rb
/usr/bin/install -o root -g wheel -m 644 "$base/../lib/profile-plan.rb" /usr/local/libexec/agent-vm/profile-plan.rb
/usr/bin/install -o root -g wheel -m 644 "$base/config.json" /etc/agent-vm/config.json
printf 'Guest base prepared.\n'
