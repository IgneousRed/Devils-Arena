import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('fuzz_runner', PROJECT / 'tools/run_odin_fuzz.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class FuzzSetupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.environment = Path(self.temporary.name)
        (self.environment / 'share').mkdir()
        (self.environment / 'bin').mkdir()
        self.variables = {}
        for name, filename in [('ODIN_FUZZ', 'odin-fuzz'), ('ODIN_FUZZ_SCANNER', 'scanner'),
                               ('ODIN', 'application-odin'), ('FUZZ_ODIN', 'fuzz-odin')]:
            executable = self.environment / 'bin' / filename
            executable.write_text('#!/bin/sh\nexit 99\n')
            executable.chmod(0o755)
            self.variables[name] = str(executable)
        self.variables['FUZZ_ODIN_ROOT'] = str(self.environment / 'fuzz-odin-root')
        self.manifest = self.environment / 'share/project-environment.json'
        self.manifest.write_text(json.dumps({'schema': 1, 'variables': self.variables, 'unset': ['EM_CACHE']}))

    def test_public_entrypoint_selects_only_the_fuzz_profile(self):
        scripts = self.environment / 'project/scripts'
        scripts.mkdir(parents=True)
        (scripts / 'fuzz.sh').write_bytes((PROJECT / 'scripts/fuzz.sh').read_bytes())
        (scripts / 'dev').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        (scripts / 'dev').chmod(0o755)
        result = runner.subprocess.run(['sh', str(scripts / 'fuzz.sh'), '--budget', '1'],
                                       text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ['--profile', 'fuzz', 'nice', '-n', '10',
                         'python3', 'tools/run_odin_fuzz.py', '--budget', '1'])

    def test_selects_current_checkout_and_ignores_ambient_substitutes(self):
        with patch.dict(os.environ, {'PATH': '/untrusted', 'ODIN': '/other/odin',
                                     'ODIN_FUZZ': '/other/tool', 'ODIN_FUZZ_SCANNER': '/other/scanner',
                                     'ODIN_FUZZ_TOOL': '/legacy/tool', 'EM_CACHE': '/old/cache',
                                     'PROJECT_NIX_ENVIRONMENT': '/stale/environment'}), \
                patch.object(runner.subprocess, 'check_output', return_value=str(self.environment)) as evaluate, \
                patch.object(runner.subprocess, 'run') as execute:
            tool, odin, environment = runner.locked_setup()
        self.assertEqual(tool, self.variables['ODIN_FUZZ'])
        self.assertEqual(odin, self.variables['FUZZ_ODIN'])
        self.assertEqual(environment['ODIN'], self.variables['FUZZ_ODIN'])
        self.assertEqual(environment['ODIN_ROOT'], self.variables['FUZZ_ODIN_ROOT'])
        self.assertEqual(environment['ODIN_FUZZ_SCANNER'], self.variables['ODIN_FUZZ_SCANNER'])
        self.assertNotIn('ODIN_FUZZ_TOOL', environment)
        self.assertNotIn('EM_CACHE', environment)
        self.assertEqual(environment['PROJECT_NIX_ENVIRONMENT'], str(self.environment))
        self.assertEqual(environment['PATH'].split(os.pathsep)[0], str(self.environment / 'bin'))
        self.assertNotIn('/untrusted', environment['PATH'])
        self.assertEqual(evaluate.call_args.args[0], [str(PROJECT / 'scripts/dev'), '--eval',
                         'packages.aarch64-darwin.fuzz-environment.outPath', '--raw',
                         '--option', 'allow-import-from-derivation', 'false'])
        execute.assert_not_called()

    def test_missing_locked_environment_does_not_fall_back(self):
        self.manifest.unlink()
        with patch.object(runner.subprocess, 'check_output', return_value=str(self.environment)), \
                patch.object(runner.subprocess, 'run') as execute:
            with self.assertRaises(OSError):
                runner.locked_setup()
        execute.assert_not_called()

    def test_missing_locked_scanner_does_not_fall_back(self):
        Path(self.variables['ODIN_FUZZ_SCANNER']).unlink()
        with patch.object(runner.subprocess, 'check_output', return_value=str(self.environment)), \
                patch.object(runner.subprocess, 'run') as execute:
            with self.assertRaisesRegex(RuntimeError, 'Locked fuzz dependencies'):
                runner.locked_setup()
        execute.assert_not_called()

    def test_failed_checkout_evaluation_does_not_fall_back(self):
        with patch.object(runner.subprocess, 'check_output', side_effect=runner.subprocess.CalledProcessError(2, 'dev')), \
                patch.object(runner.subprocess, 'run') as execute:
            with self.assertRaises(runner.subprocess.CalledProcessError):
                runner.locked_setup()
        execute.assert_not_called()


class FuzzStorageTest(unittest.TestCase):
    def campaign(self, status):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        ui = root / '.vendor/odin_ui'
        ui.mkdir(parents=True)
        (ui / 'LICENSE').write_text('synthetic fixture')
        (root / 'odin-fuzz.json').write_text('{"applications":[]}')
        (root / '.private').mkdir()
        (root / '.private/do-not-copy.txt').write_text('synthetic private marker')
        (root / 'AGENTS.md').write_text('synthetic private instructions')
        work, store = root / '.work/fuzz', root / '.local/fuzz'
        environment = {'PROJECT_NIX_ENVIRONMENT': '/synthetic/locked-environment'}

        def explore(args, env):
            self.assertEqual(args[args.index('--thread-count') + 1], '1')
            project = Path(args[2])
            self.assertFalse((project / '.private').exists())
            self.assertFalse((project / 'AGENTS.md').exists())
            corpus = Path(args[args.index('--corpus-dir') + 1])
            self.assertTrue(corpus.is_relative_to(store))
            corpus.mkdir(parents=True)
            (corpus / 'synthetic-case').write_bytes(b'synthetic fixture')
            reports = Path(args[args.index('--work-dir') + 1])
            run = reports / 'runs/synthetic-run'
            run.mkdir(parents=True)
            (run / 'summary.json').write_text(json.dumps({
                'status': 'ok' if status == 0 else 'error', 'finding_count': 0,
                'applications': [{'path': 'apps/headless', 'status': 'explored',
                                  'coverage_mode': 'llvm_sancov', 'executions': 2,
                                  'first_party_edges_hit': 1, 'corpus_loaded': 0,
                                  'ordinary_or_unclassified_exits': 0, 'timeouts': 0,
                                  'workspace_errors': 0, 'unconfirmed_withheld': 0}],
            }))
            (run / 'synthetic-staging').write_text('disposable on success')
            return status

        with patch.multiple(runner, ROOT=root, WORK=work, STORE=store), \
                patch.object(runner, 'locked_setup', return_value=('/synthetic/tool', '/synthetic/odin', environment)), \
                patch.object(runner.sys, 'platform', 'darwin'), \
                patch.object(runner.sys, 'argv', ['fuzz-check', '--thread-count', '1']), \
                patch.object(runner.subprocess, 'run') as run, \
                patch.object(runner.subprocess, 'check_output', side_effect=['synthetic-build', b'{}']), \
                patch.object(runner.subprocess, 'call', side_effect=explore):
            self.assertEqual(runner.main(), status)
        generator_calls = [c.args[0] for c in run.call_args_list if len(c.args[0]) > 1 and c.args[0][1] == 'build']
        self.assertEqual(len(generator_calls), 1)
        self.assertIn('-thread-count:1', generator_calls[0])
        self.assertEqual(list(work.iterdir()), [])
        self.assertTrue((store / 'latest-summary.json').is_file())
        self.assertEqual(next((store / 'corpus').rglob('synthetic-case')).read_bytes(), b'synthetic fixture')
        return store, run

    def test_clean_campaign_keeps_corpus_not_staging(self):
        store, _ = self.campaign(0)
        self.assertFalse((store / 'triage').exists())
        self.assertFalse(list(store.rglob('synthetic-staging')))

    def test_unsuccessful_campaign_preserves_restricted_evidence_outside_work(self):
        store, run = self.campaign(2)
        retained = next((store / 'triage').iterdir())
        self.assertTrue((retained / 'runs/synthetic-run/synthetic-staging').is_file())
        self.assertEqual(run.call_args.args[0][-1], str(retained / 'nix-environment'))
