#!/usr/bin/env python3
"""Publish the locked Odin UI payload as an ordinary-file dependency view."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def main():
    source = Path(os.environ['ODIN_UI_SOURCE'])
    if not (source / 'raylib/raylib.odin').is_file() or not (source / 'LICENSE').is_file():
        raise RuntimeError('The Nix Odin UI source package is incomplete')
    parent = ROOT / '.vendor'
    parent.mkdir(parents=True, exist_ok=True)
    target = parent / 'odin_ui'
    files = sorted(path.relative_to(source) for path in source.rglob('*') if path.is_file())
    if target.is_dir() and not target.is_symlink():
        current = sorted(path.relative_to(target) for path in target.rglob('*') if path.is_file())
        if current == files and all((target / path).read_bytes() == (source / path).read_bytes() for path in files):
            return
    with tempfile.TemporaryDirectory(prefix='.odin-ui-', dir=parent) as temporary:
        stage = Path(temporary) / 'odin_ui'
        # copyfile keeps generated directories/files writable for later atomic
        # replacement; immutable Nix store modes must not leak into this view.
        for path in files:
            destination = stage / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / path, destination)
        subprocess.run([sys.executable, str(ROOT / 'scripts/publish.py'), str(stage), str(target)], check=True)


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Dependency setup failed: {error}. Enter the locked Nix environment.', file=sys.stderr)
        sys.exit(2)
