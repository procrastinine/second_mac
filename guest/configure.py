import hashlib
import json
from pathlib import Path
import secrets
import subprocess
import sys
import sysconfig

home = Path.home()
base = Path(__file__).parent
config = json.loads(Path(sys.argv[1]).read_text())
profiles = config.get('profiles', ['full'])
web = 'web' in profiles or 'full' in profiles
science = 'science' in profiles or 'full' in profiles
latex = 'latex' in profiles or 'full' in profiles
for directory in ['.local/bin', '.local/share/agent-vm', '.config', '.cache/zsh']:
    (home / directory).mkdir(parents=True, exist_ok=True)

for source, destination, mode in [
    ('doctor.rb', '.local/share/agent-vm/doctor.rb', 0o755),
    ('privacy-status.js', '.local/share/agent-vm/privacy-status.js', 0o644),
]:
    target = home / destination
    # Replace owned helper names atomically. Older throwaway setup created
    # root-owned files in this user-owned directory, which cannot be truncated
    # by the guest user but can safely be replaced without following symlinks.
    temporary = target.with_name(target.name + '.' + secrets.token_hex(8))
    try:
        with temporary.open('x') as stream:
            stream.write((base / source).read_text())
        temporary.chmod(mode)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
# Retire only the development probes previously installed by this project.
(home / '.local/bin/agent-vm-check').unlink(missing_ok=True)
for filename in ['check-python.py', 'check-pi.mjs', 'check-browser.mjs', 'check-privacy.js', 'check-extras.sh']:
    (home / '.local/share/agent-vm' / filename).unlink(missing_ok=True)
# Diagnostics are exposed through mac-control; retire only known old launchers.
legacy_doctor = home / '.local/bin/agent-vm-doctor'
if legacy_doctor.is_file() and not legacy_doctor.is_symlink():
    if hashlib.sha256(legacy_doctor.read_bytes()).hexdigest() in {
        'f2f58d661da1fcf18a2ac8bb51b380c5d215cdcad09372a6d651c987583bd57f',
        '8f54f08085175d5b036075cfafb4551dd4f86141e3bfd4ecee387f50bc7385ed',
    }:
        legacy_doctor.unlink()
# Installation inventory is kept privately by the manager, never as guest notes.
(home / '.local/share/agent-vm/versions.txt').unlink(missing_ok=True)


def read(path):
    return json.loads(path.read_text()) if path.exists() else {}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def managed_block(path, body):
    start, end = '# BEGIN second-mac', '# END second-mac'
    original = path.read_text() if path.exists() else ''
    for old_start, old_end in [('# BEGIN agent-vm', '# END agent-vm'), (start, end)]:
        if old_start in original:
            before, rest = original.split(old_start, 1)
            _, after = rest.split(old_end, 1)
            original = before.rstrip() + after
    path.write_text(original.rstrip() + '\n\n' + start + '\n' + body.rstrip() + '\n' + end + '\n')


managed_block(home / '.zshenv', (base / 'environment.zsh').read_text() + '\n' + (base / 'privacy.env').read_text())
managed_block(home / '.zshrc', (base / 'interactive.zsh').read_text())
tmux_path = home / '.config/agent-vm/tmux.conf'
tmux_path.parent.mkdir(parents=True, exist_ok=True)
tmux_path.write_text((base / 'tmux.conf').read_text())
managed_block(home / '.tmux.conf', 'source-file ~/.config/agent-vm/tmux.conf')
alt_click = home / '.local/share/agent-vm/alt-click.sh'
alt_click.write_text((base / 'alt-click.sh').read_text())
alt_click.chmod(0o755)
# The root-owned boot service mounts the built-in VirtioFS device.
(home / '.local/bin/agent-vm-mount-share').unlink(missing_ok=True)
profile = '''export PATH="$HOME/tools/python/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/opt/openjdk/bin:/opt/homebrew/opt/sqlite/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/opt/homebrew/sbin:/Library/TeX/texbin:$PATH"
if [ -n "${VIRTUAL_ENV:-}" ]; then export PATH="$VIRTUAL_ENV/bin:$PATH"; fi
export JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
export MPLBACKEND=Agg HOMEBREW_NO_ANALYTICS=1 LANG=en_US.UTF-8 EDITOR=nvim
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib
export PLAYWRIGHT_MCP_CONFIG="$HOME/.config/playwright-brave.json"
'''
managed_block(home / '.profile', profile + '\n' + (base / 'privacy.env').read_text())
managed_block(home / '.bash_profile', '. "$HOME/.profile"')
managed_block(Path(sysconfig.get_paths()['purelib']) / 'sitecustomize.py', '''import os
os.environ.setdefault("DYLD_FALLBACK_LIBRARY_PATH", "/opt/homebrew/lib")
os.environ.setdefault("MPLBACKEND", "Agg")''')

wrappers = {'devpython': 'exec "$HOME/tools/python/bin/python" "$@"'}
if web:
    wrappers['playwright-brave'] = 'export PLAYWRIGHT_MCP_CONFIG="$HOME/.config/playwright-brave.json"\nexec /opt/homebrew/bin/playwright-cli "$@"'
for name, script in wrappers.items():
    path = home / '.local/bin' / name
    path.write_text('#!/bin/sh\n' + script + '\n')
    path.chmod(0o755)
if latex:
    biber = home / '.local/bin/biber'
    biber.write_text((base / 'biber.rb').read_text())
    biber.chmod(0o755)
if science:
    subprocess.run([sys.executable, '-m', 'ipykernel', 'install', '--user', '--name', config['name'],
                    '--display-name', config['name'] + ' Python'], check=True)

brave = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser'
for suffix, profile_name in ([('', 'playwright'), ('-mcp', 'mcp'), ('-pi', 'pi'), ('-python', 'python')] if web else []):
    profile_path = home / '.local/share' / ('brave-' + profile_name)
    prefs_path = profile_path / 'Default/Preferences'
    # Only seed new profiles; an update must not edit preferences under a running browser.
    if not prefs_path.exists():
        write(prefs_path, {'profile': {'content_settings': {'exceptions': {
            'shieldsAds': {'*,*': {'setting': 2}}, 'trackers': {'*,*': {'setting': 2}},
        }}}})
    write(home / '.config' / f'playwright-brave{suffix}.json', {'browser': {
        'browserName': 'chromium', 'userDataDir': str(profile_path),
        'launchOptions': {'executablePath': brave, 'headless': True, 'chromiumSandbox': True,
                          'ignoreDefaultArgs': ['--disable-component-update', '--disable-background-networking', '--disable-extensions'],
                          'args': ['--no-first-run', '--no-default-browser-check']},
    }})
if web:
    subprocess.run(['/opt/homebrew/bin/ketch', 'config', 'set', 'browser', brave], check=True)
    subprocess.run(['/opt/homebrew/bin/ketch', 'config', 'set', 'cache_ttl', '1h'], check=True)

write(home / '.config/agent-vm.json', config)
print('Shell and selected tool profiles configured.')
