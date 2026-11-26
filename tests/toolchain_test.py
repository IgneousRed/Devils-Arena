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

    def test_invocation_thread_count_reaches_the_existing_compiler(self):
        project = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(dir=project / '.work') as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'tools').mkdir()
            (root / '.vendor/odin_ui/raylib').mkdir(parents=True)
            (root / '.vendor/odin_ui/raylib/raylib.odin').write_text('synthetic fixture')
            shutil.copyfile(project / 'scripts/odin-ui.sh', root / 'scripts/odin-ui.sh')
            (root / 'tools/prepare_dependencies.py').write_text('')
            (root / 'scripts/version.py').write_text('print("synthetic-build")')
            compiler = root / 'compiler'
            compiler.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            compiler.chmod(0o755)
            environment = dict(os.environ, ODIN=str(compiler), ODIN_THREAD_COUNT='1')
            def invoke(*flags, env=environment):
                return subprocess.run(['sh', str(root / 'scripts/odin-ui.sh'), 'check', 'src', '-vet', *flags],
                                      cwd=root, env=env, capture_output=True, text=True)
            result = invoke()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('-thread-count:1', result.stdout.splitlines())
            self.assertIn('-vet', result.stdout.splitlines())
            explicit = invoke('-thread-count:1')
            self.assertEqual(explicit.returncode, 0, explicit.stderr)
            self.assertEqual(explicit.stdout.splitlines().count('-thread-count:1'), 1)
            for value in ['0', '', '-1', '01', 'bad']:
                with self.subTest(value=value):
                    invalid = invoke(env=dict(environment, ODIN_THREAD_COUNT=value))
                    self.assertEqual(invalid.returncode, 2)
                    self.assertIn('ODIN_THREAD_COUNT', invalid.stderr)
