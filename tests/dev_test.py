import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

from scripts import dev


class DevelopmentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=dev.ROOT / '.work')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.builds = self.root / 'builds'
        self.builds.mkdir()
        self.current = self.root / 'current'
        self.old = 'a' * 32
        old_output = self.builds / self.old
        old_output.mkdir()
        for name in dev.ASSETS:
            (old_output / name).write_text('previous build')
        self.current.write_text(self.old)
        self.paths = patch.multiple(dev, ROOT=self.root, BUILDS=self.builds, CURRENT=self.current)
        self.paths.start()
        self.addCleanup(self.paths.stop)
        self.development = dev.Development()

    def compiler(self, args, cwd, env):
        self.assertEqual(args, ['./scripts/build.sh', 'debug'])
        output = Path(env['WEB_OUTPUT'])
        output.mkdir()
        for name in dev.ASSETS:
            (output / name).write_text('completed build')
        return subprocess.CompletedProcess(args, 0)

    def test_only_complete_unchanged_debug_builds_are_published(self):
        with patch.object(dev.subprocess, 'run', side_effect=self.compiler), patch.object(dev, 'fingerprint', return_value=b'new'):
            self.assertFalse(self.development.build(b'old'))
        self.assertEqual(self.current.read_text(), self.old)
        with patch.object(dev.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            self.assertTrue(self.development.build(b'new'))
        self.assertEqual(self.current.read_text(), self.old)
        self.assertTrue(self.development.status['error'])
        with patch.object(dev.subprocess, 'run', side_effect=self.compiler), patch.object(dev, 'fingerprint', return_value=b'new'):
            self.assertTrue(self.development.build(b'new'))
        version = self.current.read_text()
        self.assertNotEqual(version, self.old)
        self.assertEqual(self.development.status['version'], version)
        self.assertTrue((self.builds / self.old / 'game.wasm').exists())

    def test_status_and_immutable_asset_routes(self):
        handler = functools.partial(dev.Handler, development=self.development)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            origin = f'http://127.0.0.1:{server.server_port}'
            with urlopen(origin + '/__dev/status') as response:
                self.assertEqual(json.load(response)['version'], self.old)
            for route in ('/', '/' + self.old, '/' + self.old + '/'):
                with urlopen(origin + route) as response:
                    self.assertEqual(response.geturl(), origin + '/' + self.old + '/')
                    self.assertEqual(response.read(), b'previous build')
            with urlopen(origin + '/' + self.old + '/game.wasm') as response:
                self.assertEqual(response.read(), b'previous build')
            with self.assertRaises(HTTPError) as error:
                urlopen(origin + '/' + self.old + '/../../../AGENTS.md')
            error.exception.close()
            self.assertEqual(error.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_missing_compiler_does_not_leave_building_status_stuck(self):
        with patch.object(dev.subprocess, 'run', side_effect=FileNotFoundError('build script missing')):
            self.assertTrue(self.development.build(b'source'))
        self.assertEqual(self.development.status['version'], self.old)
        self.assertFalse(self.development.status['building'])
        self.assertTrue(self.development.status['error'])

    def test_editor_metadata_does_not_trigger_builds(self):
        source = self.root / 'src'
        source.mkdir()
        code = source / 'main.odin'
        code.write_text('package main')
        before = dev.fingerprint()
        (source / '.DS_Store').write_bytes(b'finder metadata')
        self.assertEqual(dev.fingerprint(), before)
        code.write_text('package main\n')
        self.assertNotEqual(dev.fingerprint(), before)

    def test_root_license_changes_trigger_builds(self):
        license = self.root / 'LICENSE'
        license.write_text('original license')
        cache = {}
        before = dev.fingerprint(cache)
        license.write_text('updated license')
        self.assertNotEqual(dev.fingerprint(cache), before)
        self.assertEqual(dev.fingerprint(cache), dev.fingerprint())

    def test_raylib_recipe_changes_trigger_builds(self):
        recipe = self.root / 'nix/web-raylib.nix'
        recipe.parent.mkdir()
        recipe.write_text('original build recipe')
        cache = {}
        before = dev.fingerprint(cache)
        recipe.write_text('updated build recipe')
        self.assertNotEqual(dev.fingerprint(cache), before)
        self.assertEqual(dev.fingerprint(cache), dev.fingerprint())

    def test_generated_ui_changes_trigger_builds(self):
        source = self.root / '.vendor/odin_ui/raylib/raylib.odin'
        source.parent.mkdir(parents=True)
        source.write_text('original UI source')
        cache = {}
        before = dev.fingerprint(cache)
        source.write_text('updated UI source')
        self.assertNotEqual(dev.fingerprint(cache), before)
        self.assertEqual(dev.fingerprint(cache), dev.fingerprint())

    def test_publication_failure_retains_current_and_completed_builds(self):
        for operation in ('write_text', 'replace'):
            with self.subTest(operation=operation):
                with patch.object(dev.subprocess, 'run', side_effect=self.compiler), \
                     patch.object(dev, 'fingerprint', return_value=b'source'):
                    # Compile successfully before failing the current-version update.
                    # The compiler fixture also uses write_text, so fail only the pointer path.
                    original = getattr(Path, operation)
                    def fail_pointer(path, *args, **kwargs):
                        if path == self.current.with_suffix('.next'):
                            raise OSError('publication fixture')
                        return original(path, *args, **kwargs)
                    with patch.object(Path, operation, fail_pointer):
                        self.assertTrue(self.development.build(b'source'))
                self.assertEqual(self.current.read_text(), self.old)
                self.assertEqual(self.development.status['version'], self.old)
                self.assertFalse(self.development.status['building'])
                self.assertIn('publication fixture', self.development.status['error'])
        self.assertEqual(len(list(self.builds.iterdir())), 3, 'Retain both unpublished builds and the working build')
        with patch.object(dev.subprocess, 'run', side_effect=self.compiler), patch.object(dev, 'fingerprint', return_value=b'source'):
            self.assertTrue(self.development.build(b'source'))
        self.assertNotEqual(self.development.status['version'], self.old, 'A later edit can still publish')

    def test_new_license_files_do_not_invalidate_previous_working_builds(self):
        (self.builds / self.old / 'FONT-LICENSE.txt').unlink()
        self.assertEqual(dev.Development().status['version'], self.old)

    def test_poll_read_errors_recover_without_restarting(self):
        for during_debounce in (False, True):
            with self.subTest(during_debounce=during_debounce):
                self.current.write_text(self.old)
                self.development = dev.Development()
                errors = []
                def wait(_):
                    if self.development.status['error']:
                        errors.append(dict(self.development.status))
                    if self.development.status['version'] != self.old:
                        self.development.stop.set()
                    return self.development.stop.is_set()
                fingerprints = ([b'source'] if during_debounce else []) + [PermissionError('source fixture')] + [b'source'] * 3
                with patch.object(dev, 'fingerprint', side_effect=fingerprints), \
                     patch.object(dev.subprocess, 'run', side_effect=self.compiler), \
                     patch.object(self.development.stop, 'wait', side_effect=wait):
                    self.development.watch()
                self.assertTrue(errors, 'Expose the error while retaining the previous build')
                for status in errors:
                    self.assertEqual(status['version'], self.old)
                    self.assertFalse(status['building'])
                    self.assertIn('source fixture', status['error'])
                self.assertNotEqual(self.development.status['version'], self.old)
                self.assertEqual(self.development.status['error'], '')
                self.assertEqual(self.current.read_text(), self.development.status['version'])

    def test_poll_cache_detects_edits_deletion_and_preserved_mtime(self):
        source = self.root / 'src'
        source.mkdir()
        code = source / 'main.odin'
        code.write_text('before')
        cache = {}
        before = dev.fingerprint(cache)
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('unchanged content reread')):
            self.assertEqual(dev.fingerprint(cache), before)
        stat = code.stat()
        code.write_text('after!')
        os.utime(code, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        after = dev.fingerprint(cache)
        self.assertNotEqual(before, after)
        self.assertEqual(after, dev.fingerprint(), 'Publication performs the same full content check')
        code.unlink()
        self.assertNotEqual(dev.fingerprint(cache), after)


if __name__ == '__main__':
    unittest.main()
