#!/usr/bin/env python3
"""Run the Nix-owned fuzz tool and verify only its safe setup/coverage summary."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / '.work' / 'fuzz'
STORE = ROOT / '.local' / 'fuzz'


def locked_setup():
    # Evaluate this checkout even for direct calls or inherited/stale markers.
    # Evaluation never realizes a missing environment or starts the fuzz tool.
    selected = subprocess.check_output([
        str(ROOT / 'scripts/dev'), '--eval',
        'packages.aarch64-darwin.fuzz-environment.outPath', '--raw',
        '--option', 'allow-import-from-derivation', 'false'], text=True).strip()
    directory = Path(selected)
    if not directory.is_absolute():
        raise RuntimeError('Locked Nix environment is unavailable; use scripts/fuzz.sh')
    manifest = json.loads((directory / 'share/project-environment.json').read_text())
    if manifest['schema'] != 1:
        raise RuntimeError('Unsupported locked environment manifest')
    variables = manifest['variables']
    tool, scanner, odin = (variables[name] for name in ('ODIN_FUZZ', 'ODIN_FUZZ_SCANNER', 'FUZZ_ODIN'))
    for executable in (tool, scanner, odin):
        if not Path(executable).is_absolute() or not os.access(executable, os.X_OK):
            raise RuntimeError('Locked fuzz dependencies are unavailable; use scripts/fuzz.sh')
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith('ODIN_FUZZ') and name not in manifest['unset']}
    environment.update(variables)
    # The published tool's compiler/scanner remain one verified package boundary.
    # Application builds may use a newer backend without substituting it here.
    environment.update(ODIN=odin, ODIN_ROOT=variables['FUZZ_ODIN_ROOT'])
    environment.update(PROJECT_ROOT=str(ROOT), PROJECT_NIX_ENVIRONMENT=str(directory),
                       PATH=os.pathsep.join((str(directory / 'bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin')))
    return tool, odin, environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--budget', type=float, default=30)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('odin-fuzz commit checks require macOS; this is not a skipped/pass result')
    if not math.isfinite(args.budget) or args.budget <= 0:
        parser.error('--budget must be positive')
    tool, odin, environment = locked_setup()
    WORK.mkdir(parents=True, exist_ok=True)
    subprocess.run([tool, 'doctor', '--odin', odin], check=True, env=environment)
    subprocess.run([sys.executable, str(ROOT / 'tools/prepare_dependencies.py')], check=True, env=environment)
    # Generate seeds/configuration in a private copy. Never replace files used by
    # an active development session, and include uncommitted application changes.
    with tempfile.TemporaryDirectory(prefix='project-', dir=WORK) as temporary:
        project = Path(temporary) / 'project'
        shutil.copytree(ROOT, project, symlinks=True, ignore=lambda _, names: [
            name for name in names if name.startswith('.') or name in ('binaries', '__pycache__', 'node_modules', 'AGENTS.md')])
        # Hidden dependency views are excluded by the upstream snapshotter.
        # Materialize the locked payload under an ordinary relative collection.
        ui = project / 'vendor/odin_ui'
        if ui.exists() or ui.is_symlink():
            if ui.is_symlink():
                ui.unlink()
            else:
                shutil.rmtree(ui)
        shutil.copytree(ROOT / '.vendor/odin_ui', ui)
        config = json.loads((project / 'odin-fuzz.json').read_text())
        config.setdefault('collections', {})['odin_ui'] = 'vendor/odin_ui'
        environment = dict(environment, ODIN_UI_SOURCE=str(ui))
        build = subprocess.check_output([
            sys.executable, str(project / 'scripts/version.py'), odin, '-debug',
            *config.get('odin_flags', [])], text=True, env=environment).strip()
        config.setdefault('odin_flags', []).append(f'-define:APPLICATION_VERSION={build}')
        (project / 'odin-fuzz.json').write_text(json.dumps(config, indent=2) + '\n')
        generator = Path(temporary) / 'headless'
        subprocess.run([odin, 'build', str(project / 'apps/headless'), '-debug',
                        *config['odin_flags'], f'-collection:odin_ui={ui}', f'-out:{generator}'], check=True, env=environment)
        seed = subprocess.check_output([str(generator), '--example'], env=environment)
        if len(seed) > 4096:
            raise RuntimeError('Valid replay seed exceeds the documented odin-fuzz input limit')
        seeds = project / 'fuzz'
        seeds.mkdir(exist_ok=True)
        (seeds / 'replay.json').write_bytes(seed)
        STORE.mkdir(parents=True, exist_ok=True)
        reports = Path(tempfile.mkdtemp(prefix='check-', dir=WORK))
        accepted = False
        try:
            status = subprocess.call([
                tool, 'explore', str(project), '--odin', odin,
                '--work-dir', str(reports), '--corpus-dir', str(STORE / 'corpus' / build),
                '--budget', str(args.budget), '--seed', str(args.seed)], env=environment)
            created = list(reports.glob('runs/*/summary.json'))
            if len(created) != 1:
                raise RuntimeError('Expected one safe odin-fuzz summary; detailed triage requires Gemini 4 Neon')
            summary_bytes = created.pop().read_bytes()
            summary = json.loads(summary_bytes)
            (STORE / 'latest-summary.json').write_bytes(summary_bytes)
            (STORE / 'latest-setup.json').write_text(json.dumps({
                'application_build': build, 'seed': args.seed,
                'environment': environment['PROJECT_NIX_ENVIRONMENT'],
                'odin': odin, 'tool': tool,
            }, indent=2) + '\n')
            if status == 1 or summary['finding_count'] > 0 or summary['status'] == 'findings':
                print(f"Fuzz check found {summary['finding_count']} confirmed findings; Gemini 4 Neon triage is required.", file=sys.stderr)
                return 1
            if status != 0 or summary['status'] != 'ok':
                print('Fuzz check did not complete; use summary.json for setup checks and Gemini 4 Neon for detailed triage.', file=sys.stderr)
                return 2
            applications = summary['applications']
            if len(applications) != 1 or applications[0]['path'] != 'apps/headless':
                raise RuntimeError('Fuzz summary does not cover the configured application')
            app = applications[0]
            if (app['status'] != 'explored' or app['coverage_mode'] != 'llvm_sancov' or
                    app['executions'] < 1 or app['first_party_edges_hit'] < 1 or
                    app['ordinary_or_unclassified_exits'] >= app['executions'] or
                    app['timeouts'] or app['workspace_errors'] or app['unconfirmed_withheld']):
                raise RuntimeError('Fuzz check has failures, incomplete execution or missing coverage guidance; inspect summary.json; detailed triage requires Gemini 4 Neon')
            print(f"Fuzz check passed: {app['executions']} cases, {app['first_party_edges_hit']} edges; "
                  f"loaded {app['corpus_loaded']} corpus cases. Coverage is limited to the headless combat application.")
            accepted = True
            return 0
        finally:
            if accepted:
                # No findings: source captures and binaries are disposable. Keep
                # reusable corpus and the latest safe setup/coverage summary only.
                shutil.rmtree(reports)
            else:
                # An interrupted/error/finding campaign needs restricted triage.
                # Preserve its opaque evidence outside disposable work storage.
                triage = STORE / 'triage'
                triage.mkdir(exist_ok=True)
                retained = Path(shutil.move(reports, triage / reports.name))
                subprocess.run([str(ROOT / 'scripts/retain-nix-environment'),
                                str(retained / 'nix-environment')], check=True, env=environment)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'odin-fuzz check failed: {error}', file=sys.stderr)
        sys.exit(2)
