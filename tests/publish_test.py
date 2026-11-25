from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.publish import publish


class PublishTest(unittest.TestCase):
    def test_complete_directory_exchange_and_first_publication(self):
        with tempfile.TemporaryDirectory(dir='.work') as temporary:
            root = Path(temporary)
            stage, output = root / 'stage', root / 'output'
            stage.mkdir()
            (stage / 'game.wasm').write_text('first')
            publish(stage, output)
            self.assertFalse(stage.exists())
            stage.mkdir()
            (stage / 'game.wasm').write_text('second')
            (output / 'dev.js').write_text('old debug client')
            publish(stage, output)
            self.assertEqual((output / 'game.wasm').read_text(), 'second')
            self.assertFalse((output / 'dev.js').exists())
            self.assertEqual((stage / 'game.wasm').read_text(), 'first')

    def test_failed_exchange_retains_both_builds(self):
        with tempfile.TemporaryDirectory(dir='.work') as temporary:
            root = Path(temporary)
            stage, output = root / 'stage', root / 'output'
            stage.mkdir()
            output.mkdir()
            (stage / 'game.wasm').write_text('pending')
            (output / 'game.wasm').write_text('working')
            with patch('scripts.publish.ctypes.CDLL', side_effect=OSError('unavailable')):
                with self.assertRaises(OSError):
                    publish(stage, output)
            self.assertEqual((stage / 'game.wasm').read_text(), 'pending')
            self.assertEqual((output / 'game.wasm').read_text(), 'working')
