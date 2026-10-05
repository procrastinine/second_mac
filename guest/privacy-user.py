from pathlib import Path
import json
import subprocess

home = Path.home()
# Ordinary per-user opt-outs remain off while macOS rebuilds its managed cache
# during login. The same policy source drives the root maintenance job.
policy_source = Path(__file__).resolve().parent.parent / 'lib/privacy-policies.rb'
policies = json.loads(subprocess.check_output(['/usr/bin/ruby', str(policy_source), '--json']))
for domain, keys in policies.items():
    for key, value in keys.items():
        kind = '-bool' if isinstance(value, bool) else '-int'
        text = str(value).lower()
        subprocess.run(['/usr/bin/defaults', 'write', domain, key, kind, text], check=True)
for domain, key, kind, value in [
    ('com.apple.Siri', 'StatusMenuVisible', '-bool', 'false'),
    ('com.apple.screensaver', 'idleTime', '-int', '0'),
    # Sparkle's first-launch update permission dialog blocks headless Brave.
    # Update browser binaries with Homebrew inside the guest.
    ('com.brave.Browser', 'SUEnableAutomaticChecks', '-bool', 'false'),
    ('com.brave.Browser', 'SUHasLaunchedBefore', '-bool', 'true'),
    ('com.brave.Browser', 'SUSendProfileInfo', '-bool', 'false'),
]:
    subprocess.run(['/usr/bin/defaults', 'write', domain, key, kind, value], check=True)
subprocess.run(['/opt/homebrew/bin/brew', 'analytics', 'off'], check=True)
if Path('/opt/homebrew/bin/go').exists():
    subprocess.run(['/opt/homebrew/bin/go', 'telemetry', 'off'], check=True)
print('Available tool telemetry disabled; headless user preferences set.')
