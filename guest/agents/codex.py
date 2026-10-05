from pathlib import Path
import subprocess
import tomlkit
home = Path.home()
path = home / '.codex/config.toml'
path.parent.mkdir(parents=True, exist_ok=True)
config = tomlkit.parse(path.read_text()) if path.exists() else tomlkit.document()
config['approval_policy'] = 'never'
config['sandbox_mode'] = 'danger-full-access'
for section in ['analytics', 'feedback']:
    config.setdefault(section, {})['enabled'] = False
config.setdefault('otel', {}).update(exporter='none', trace_exporter='none', log_user_prompt=False)
path.write_text(tomlkit.dumps(config))
path.chmod(0o600)

subprocess.run(['/opt/homebrew/bin/codex', 'mcp', 'add', 'playwright', '--',
                '/opt/homebrew/bin/node', '/opt/homebrew/lib/node_modules/@playwright/mcp/cli.js',
                '--config', str(home / '.config/playwright-brave-mcp.json')], check=True)
result = subprocess.run(['/opt/homebrew/bin/codex','completion','zsh'], capture_output=True, text=True, check=True)
(home / '.local/share/agent-vm/_codex').write_text(result.stdout)
print('Codex privacy settings and Playwright configured.')
