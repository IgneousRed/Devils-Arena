import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ToolchainTest(unittest.TestCase):
    def test_web_setup_uses_the_locked_compiler_and_artifacts(self):
        project = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(dir=project / '.work') as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            scripts.mkdir()
            for filename in ('odin-ui.sh', 'web-toolchain.sh', 'emscripten.sh'):
                shutil.copyfile(project / 'scripts' / filename, scripts / filename)
                (scripts / filename).chmod(0o755)
            binaries = root / 'bin'
            binaries.mkdir()
            for name in ('odin', 'emcc', 'node'):
                executable = binaries / name
                executable.write_text('#!/bin/sh\nexit 0\n')
                executable.chmod(0o755)
            archive, license = root / 'libraylib.web.a', root / 'LICENSE'
            archive.write_text('locked archive fixture')
            license.write_text('locked license fixture')
            environment = dict(os.environ, ODIN=str(binaries / 'odin'), EMCC=str(binaries / 'emcc'),
                               NODE=str(binaries / 'node'), PROJECT_ROOT=str(root),
                               RAYLIB_WEB_LIB=str(archive), RAYLIB_WEB_LICENSE=str(license))
            result = subprocess.run(
                ['sh', '-c', '. ./scripts/web-toolchain.sh; printf "%s\\n%s\\n" "$ODIN" "$RAYLIB_WEB_LIB"'],
                cwd=root, env=environment, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), [str((binaries / 'odin').resolve()), str(archive)])
            environment.pop('ODIN')
            rejected = subprocess.run(['sh', 'scripts/odin-ui.sh', '--compiler'], cwd=root,
                                      env=environment, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('locked Nix project environment', rejected.stderr)
