import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


class ConfigureTest(unittest.TestCase):
    def test_updates_replace_read_only_helpers_without_following_symlinks(self):
        source = Path(__file__).resolve().parents[1] / 'guest/configure.py'
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'home'
            helper = home / '.local/share/agent-vm/doctor.rb'
            helper.parent.mkdir(parents=True)
            helper.write_text('old helper')
            helper.chmod(0o444)
            unrelated = Path(directory) / 'unrelated.js'
            unrelated.write_text('preserve this file')
            status = home / '.local/share/agent-vm/privacy-status.js'
            status.parent.mkdir(parents=True, exist_ok=True)
            status.symlink_to(unrelated)
            purelib = Path(directory) / 'purelib'
            purelib.mkdir()
            config = Path(directory) / 'settings.json'
            config.write_text(json.dumps({'name': 'test-box', 'profiles': ['base']}))
            shell = home / '.zshrc'
            shell.write_text('alias kept=true\n# BEGIN agent-vm\nold managed body\n# END agent-vm\n# user tail\n')
            with patch.object(Path, 'home', return_value=home), \
                    patch('sysconfig.get_paths', return_value={'purelib': str(purelib)}), \
                    patch('sys.argv', [str(source), str(config)]), \
                    contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(source))
                first = shell.read_text()
                runpy.run_path(str(source))
            self.assertEqual(helper.read_text(), (source.parent / 'doctor.rb').read_text())
            self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
            self.assertFalse(status.is_symlink())
            self.assertEqual(unrelated.read_text(), 'preserve this file')
            self.assertEqual(shell.read_text(), first)
            self.assertIn('alias kept=true', first)
            self.assertIn('# user tail', first)
            self.assertNotIn('# BEGIN agent-vm', first)
            self.assertEqual(first.count('# BEGIN second-mac'), 1)


if __name__ == '__main__':
    unittest.main()
