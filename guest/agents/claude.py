import json
from pathlib import Path
import subprocess

home = Path.home()
path = home / '.claude/settings.json'
path.parent.mkdir(parents=True, exist_ok=True)
settings = json.loads(path.read_text()) if path.exists() else {}
settings.setdefault('env', {}).update({
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
    'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1',
    'CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY': '1',
    'CLAUDE_CODE_ENABLE_TELEMETRY': '0',
    'OTEL_SDK_DISABLED': 'true', 'OTEL_METRICS_EXPORTER': 'none',
    'OTEL_LOGS_EXPORTER': 'none', 'OTEL_TRACES_EXPORTER': 'none',
})
settings['autoUpdatesChannel'] = 'latest'
settings.setdefault('permissions', {})['defaultMode'] = 'bypassPermissions'
path.write_text(json.dumps(settings, indent=2) + '\n')
path.chmod(0o600)
# Remove only our named entry, so repeated installation can replace its command.
claude = str(home / '.local/bin/claude')
subprocess.run([claude, 'mcp', 'remove', '--scope', 'user', 'agent-vm-playwright'], capture_output=True)
subprocess.run([claude, 'mcp', 'add', '--scope', 'user', 'agent-vm-playwright', '--',
    '/opt/homebrew/bin/node', '/opt/homebrew/lib/node_modules/@playwright/mcp/cli.js',
    '--config', str(home / '.config/playwright-brave-mcp.json')], check=True)
print('Claude Code analytics/error reporting disabled; Playwright configured. Authentication is user-supplied.')
