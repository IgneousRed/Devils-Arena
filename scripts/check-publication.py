#!/usr/bin/env python3
"""Reject unknown or reserved paths in this game's public source tree."""
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


FILES = {
    'ARCHITECTURE.md', 'README.md', 'LICENSE', 'VERSION',
    '.gitignore', '.gitattributes', 'flake.nix', 'flake.lock', 'ols.json',
    'odin-fuzz.json', 'odin-lint.lock.json',
}
DIRECTORIES = {'src', 'apps', 'assets', 'web', 'tests', 'scripts', 'tools',
               'nix', 'vendor', 'docs', '.githooks'}
RESERVED = {'.private', '.local', '.vendor', '.work', '.tmp', '.deps', 'binaries',
            '.codex-tmp', '.git', '__pycache__', 'node_modules', 'AGENTS.md'}


def allowed(path):
    parts = PurePosixPath(path).parts
    return (bool(parts) and not RESERVED.intersection(parts) and
            (path in FILES or len(parts) > 1 and parts[0] in DIRECTORIES))


def lowered_visibility(path):
    parts = PurePosixPath(path).parts
    return (bool({'.private', '.local', 'AGENTS.md'}.intersection(parts)) or
            path in {'GameDocument.md', 'TODO.md', 'REWORKS.md', 'docs/compiler-investigation.md'} or
            path.startswith(('design/', '.tmp/visualizations/', 'docs/evidence/compiler/')))


def main():
    outgoing = []
    if sys.argv[1:] == ['--push']:
        for line in sys.stdin:
            local_ref, local_oid, remote_ref, _ = line.split()
            if local_ref != 'refs/heads/main' or remote_ref != 'refs/heads/main' or set(local_oid) == {'0'}:
                raise SystemExit('Only the approved outgoing refs/heads/main update is permitted; never push recovery/backup refs.')
            outgoing.append(local_oid)
        commands = [['git', 'ls-tree', '-rz', oid] for oid in outgoing]
    elif sys.argv[1:] == ['--committed']:
        commands = [['git', 'ls-tree', '-rz', 'HEAD']]
    elif not sys.argv[1:]:
        commands = [['git', 'ls-files', '--stage', '-z']]
    else:
        raise SystemExit('Usage: scripts/check-publication.py [--committed|--push]')
    rejected = []
    for command in commands:
        for record in subprocess.check_output(command).split(b'\0'):
            if not record:
                continue
            metadata, path = record.split(b'\t', 1)
            name = path.decode('utf-8')
            if metadata.split()[0] not in (b'100644', b'100755') or not allowed(name):
                rejected.append(name)
    if rejected:
        raise SystemExit('Public publication blocked; review these paths: ' + repr(rejected))
    # App-owned undo/recovery refs are machine-only and must remain untouched.
    # Publication inspects only the approved outgoing ancestry, never --all.
    if not sys.argv[1:]:
        print('Public index contains only reviewed source/documentation roots.')
        return
    if sys.argv[1:] == ['--committed']:
        outgoing = ['HEAD']
    audit = Path('.local/publication/outgoing-audit.json')
    forbidden = set(json.loads(audit.read_text())['lowered_blob_ids']) if audit.exists() else set()
    revisions = subprocess.check_output(['git', 'rev-list', *outgoing]).decode().splitlines() if outgoing else []
    for revision in revisions:
        # rev-list's object names are hints, not a complete path inventory:
        # identical blobs can have different paths in different historical trees.
        for record in subprocess.check_output(['git', 'ls-tree', '-rz', revision]).split(b'\0'):
            if record:
                metadata, path = record.split(b'\t', 1)
                if (metadata.split()[2].decode() in forbidden or lowered_visibility(path.decode())
                        or RESERVED.intersection(PurePosixPath(path.decode()).parts)):
                    raise SystemExit('Public outgoing history contains reclassified material; sanitize the owned branch before publication.')
    print('Public source paths contain only reviewed source/documentation roots.')


if __name__ == '__main__':
    main()
