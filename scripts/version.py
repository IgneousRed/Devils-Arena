#!/usr/bin/env python3
"""Identify the exact source/toolchain/configuration accepted by a replay."""
import hashlib
import os
import platform
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
digest = hashlib.sha256()
for folder in ('src', 'apps', 'scripts', 'web', 'assets', 'nix', 'flake.nix', 'flake.lock'):
    base = root / folder
    for path in sorted([base] if base.is_file() else base.rglob('*')):
        if path.is_file() and not any(part.startswith('.') or part == '__pycache__' for part in path.relative_to(root).parts):
            digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes())
ui = Path(os.environ.get('ODIN_UI_SOURCE', root / '.vendor/odin_ui'))
if not (ui / 'raylib/raylib.odin').is_file():
    raise SystemExit('Locked Odin UI payload is missing; enter the Nix project environment.')
for path in sorted(ui.rglob('*')):
    relative = path.relative_to(ui)
    if path.is_file() and not any(part.startswith('.') for part in relative.parts):
        digest.update(str(Path('odin_ui') / relative).encode() + b'\0' + path.read_bytes())
digest.update(subprocess.check_output([sys.argv[1], 'version']))
digest.update((sys.platform + ':' + platform.machine()).encode())
library = os.environ.get('RAYLIB_WEB_LIB')
if library:
    digest.update(hashlib.sha256(Path(library).read_bytes()).digest())
# Output paths and the check/build/test verb do not change application behavior.
for arg in sys.argv[2:]:
    if arg.startswith(('-target:', '-define:', '-o:', '-debug')):
        digest.update(arg.encode() + b'\0')
print(digest.hexdigest())
