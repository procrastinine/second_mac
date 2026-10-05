import json
from pathlib import Path
import shutil
import sys
import requests

home = Path.home()
base = Path(__file__).parent.parent
config = json.loads(Path(sys.argv[1]).read_text())


def read(path):
    return json.loads(path.read_text()) if path.exists() else {}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


agent = home / '.pi/agent'
models = read(agent / 'models.json')
try:
    catalog = requests.get('https://openrouter.ai/api/v1/models', timeout=30)
    catalog.raise_for_status()
except requests.RequestException:
    saved = models.get('providers', {}).get('openrouter', {}).get('modelOverrides', {}).get(config['pi_model'], {})
    limit = saved.get('contextWindow')
    if not isinstance(limit, int) or limit <= 36384:
        raise RuntimeError('OpenRouter catalog unavailable and this model has no saved context limit; retry when online') from None
    print('OpenRouter catalog unavailable; retaining the saved model context limit.')
else:
    selected = next((m for m in catalog.json()['data'] if m['id'] == config['pi_model']), None)
    if selected is None:
        raise RuntimeError('Configured model is absent from the current OpenRouter catalog')
    limit = selected['context_length']
context_window = min(config['compact_at'] + 16384, limit)
if context_window <= 36384:
    raise RuntimeError('Configured model has too little context for this compaction configuration')

agent.mkdir(parents=True, exist_ok=True)
agent.chmod(0o700)
settings = read(agent / 'settings.json')
settings.update(defaultProvider='openrouter', defaultModel=config['pi_model'], shellPath='/opt/homebrew/bin/bash')
settings['compaction'] = {'enabled': True, 'reserveTokens': 16384, 'keepRecentTokens': 20000}
write(agent / 'settings.json', settings)
provider = models.setdefault('providers', {}).setdefault('openrouter', {})
routing = provider.setdefault('compat', {}).setdefault('openRouterRouting', {})
routing.update(zdr=True, data_collection='deny', allow_fallbacks=True, sort='exacto')
routing.pop('quantizations', None)
provider.setdefault('modelOverrides', {}).setdefault(config['pi_model'], {})['contextWindow'] = context_window
write(agent / 'models.json', models)
web = read(agent / 'web-search.json')
web.pop('provider', None)
web.update(workflow='none', autoOpenBrowser=False, allowBrowserCookies=False,
           searchRouting={'providers': ['exa', 'parallel-mcp', 'duckduckgo'], 'useCurrentModel': False,
                          'fallbackOn': ['unsupported', 'transient', 'quota', 'network', 'invalid-response']},
           fetchRouting={'providers': ['http', 'parallel-mcp', 'jina'], 'allowRemoteHostedProviders': True})
write(agent / 'web-search.json', web)
extensions = agent / 'extensions'
extensions.mkdir(exist_ok=True)
shutil.copyfile(base / 'pi-web-browser.ts', extensions / 'web-browser.ts')
auth = agent / 'auth.json'
if not auth.exists():
    write(auth, {})
auth.chmod(0o600)
print('Pi search, compaction and Exacto/ZDR configured.')
