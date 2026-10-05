import contextlib
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


class PiConfigurationTest(unittest.TestCase):
    def test_offline_reapply_preserves_credentials_and_never_increases_saved_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            agent = home / '.pi/agent'
            agent.mkdir(parents=True)
            model = 'example/model'
            (agent / 'models.json').write_text(json.dumps({'providers': {'openrouter': {
                'modelOverrides': {model: {'contextWindow': 131072}}
            }}}))
            auth = agent / 'auth.json'
            auth.write_text('{}\n')
            config = home / 'setup.json'
            config.write_text(json.dumps({'pi_model': model, 'compact_at': 400000}))
            requests = types.ModuleType('requests')
            requests.RequestException = ConnectionError
            def unavailable(*args, **kwargs):
                raise ConnectionError('offline')
            requests.get = unavailable
            script = Path(__file__).resolve().parents[1] / 'guest/agents/pi.py'
            with patch.dict(sys.modules, requests=requests), patch.object(Path, 'home', return_value=home), \
                    patch.object(sys, 'argv', [str(script), str(config)]), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(script), run_name='__main__')
            provider = json.loads((agent / 'models.json').read_text())['providers']['openrouter']
            self.assertEqual(provider['modelOverrides'][model]['contextWindow'], 131072)
            self.assertEqual(provider['compat']['openRouterRouting'], {
                'zdr': True, 'data_collection': 'deny', 'allow_fallbacks': True, 'sort': 'exacto'
            })
            self.assertEqual(auth.read_text(), '{}\n')
            self.assertEqual(auth.stat().st_mode & 0o777, 0o600)
            config.write_text(json.dumps({'pi_model': 'example/new-model', 'compact_at': 400000}))
            with patch.dict(sys.modules, requests=requests), patch.object(Path, 'home', return_value=home), \
                    patch.object(sys, 'argv', [str(script), str(config)]):
                with self.assertRaisesRegex(RuntimeError, 'no saved context limit'):
                    runpy.run_path(str(script), run_name='__main__')


if __name__ == '__main__':
    unittest.main()
