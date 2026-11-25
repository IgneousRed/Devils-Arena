import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('publication', Path(__file__).resolve().parents[1] / 'scripts/check-publication.py')
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def test_public_sources_and_notices(self):
        for path in ['src/main.odin', 'assets/licenses/Game-icons.txt', 'nix/toolchain.nix',
                     'README.md', 'docs/gameplay.md', '.githooks/pre-push']:
            with self.subTest(path=path):
                self.assertTrue(publication.allowed(path))

    def test_reserved_and_unknown_paths_require_review(self):
        for path in ['.private/design/agreed-game.md', '.local/data/save.json',
                     '.vendor/odin_ui/raylib/raylib.odin',
                     '.work/build/game.wasm', 'assets/.local/save.json', 'unknown.txt',
                     'design/draft.md', 'TODO.md', 'GameDocument.md', 'AGENTS.md', 'docs/AGENTS.md', 'src/engine/AGENTS.md']:
            with self.subTest(path=path):
                self.assertFalse(publication.allowed(path))

    def test_history_classification_does_not_privatize_implemented_docs(self):
        for path in ['GameDocument.md', 'design/old-name.txt', '.private/archive/main.go', 'docs/AGENTS.md',
                     'docs/evidence/compiler/schema-debugger.log', 'docs/compiler-investigation.md']:
            self.assertTrue(publication.lowered_visibility(path))
        for path in ['docs/gameplay.md', 'src/procedures/procedures.odin', 'assets/icons/armor_vest.png']:
            self.assertFalse(publication.lowered_visibility(path))


class PublicationGitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Synthetic fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.write('README.md', 'synthetic public fixture')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', *args], cwd=self.root, env=self.environment, text=True).strip()

    def write(self, path, contents):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def commit(self):
        self.git('add', '-f', '.')
        self.git('commit', '-q', '-m', 'synthetic fixture')
        return self.git('rev-parse', 'HEAD')

    def check(self, *args, input=None):
        return subprocess.run([sys.executable, str(Path(publication.__file__)), *args],
                              cwd=self.root, env=self.environment, input=input, text=True, capture_output=True)

    def test_index_only_reserved_file_is_rejected(self):
        self.write('.local/recordings/synthetic.jsonl', 'synthetic fixture')
        self.git('add', '-f', '.local')
        (self.root / '.local/recordings/synthetic.jsonl').unlink()
        self.assertNotEqual(self.check().returncode, 0)

    def test_history_checks_paths_even_when_a_blob_is_reused_under_another_name(self):
        self.write('design/note.md', 'synthetic historical fixture')
        self.commit()
        self.git('mv', '-f', 'design/note.md', 'README.md')
        self.commit()
        result = self.check('--committed')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('history contains reclassified', result.stderr)

    def test_disposable_dependency_views_are_rejected_even_after_tip_removal(self):
        for name in ['.work/build/probe.txt', '.vendor/tool/probe.txt', '.deps/probe.txt']:
            with self.subTest(path=name):
                self.write(name, 'synthetic historical fixture')
                self.commit()
                (self.root / name).unlink()
                self.commit()
                result = self.check('--push', input=f'refs/heads/main {self.git("rev-parse", "HEAD")} refs/heads/main {"0" * 40}\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('history contains reclassified', result.stderr)

    def test_other_outgoing_branch_gets_the_reviewed_root_check(self):
        clean = self.git('rev-parse', 'HEAD')
        self.write('unreviewed.txt', 'synthetic fixture')
        other = self.commit()
        self.git('checkout', '-q', '-b', 'clean', clean)
        result = self.check('--push', input=f'refs/heads/main {other} refs/heads/main {"0" * 40}\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unreviewed.txt', result.stderr)

    def test_unapproved_outgoing_names_are_refused_without_resolving_them(self):
        oid = self.git('rev-parse', 'HEAD')
        for name in ['refs/t3/never-publish', 'refs/codex/never-publish',
                     'refs/original/backup', 'refs/heads/other', 'refs/tags/v0.1.0']:
            result = self.check('--push', input=f'{name} {oid} {name} {"0" * 40}\n')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('approved outgoing', result.stderr)
