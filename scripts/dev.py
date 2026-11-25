#!/usr/bin/env python3
"""Serve immutable debug builds and preserve browser sessions across source updates."""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
BUILDS = ROOT / '.work/build/dev/builds'
CURRENT = BUILDS.parent / 'current'
POLL_SECONDS = 0.3
DEBOUNCE_SECONDS = 0.5
WATCH_ROOTS = ('src', 'apps', 'web', 'assets', 'scripts', 'nix', 'flake.nix', 'flake.lock', '.vendor/odin_ui', 'LICENSE')
RUNTIME_ASSETS = ('index.html', 'game.js', 'game.wasm', 'odin.js', 'dev.js', 'recording.js')
ASSETS = (*RUNTIME_ASSETS, 'LICENSE.txt', 'RAYLIB-LICENSE.txt', 'FONT-LICENSE.txt', 'ODIN-UI-LICENSE.txt')


def valid_version(version):
    return len(version) == 32 and all(c in '0123456789abcdef' for c in version)


def fingerprint(cache=None):
    digest = hashlib.sha256()
    current = {}
    for folder in WATCH_ROOTS:
        root = ROOT / folder
        paths = [root] if root.is_file() else root.rglob('*')
        for path in sorted(paths):
            relative = path.relative_to(ROOT)
            local = path.relative_to(root if root.is_dir() else root.parent)
            if not path.is_file() or any(part.startswith('.') or part == '__pycache__' for part in local.parts):
                continue
            try:
                stat = path.stat()
                identity = (stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size, stat.st_ino)
                previous = cache.get(path) if cache is not None else None
                if previous and previous[0] == identity:
                    content_hash = previous[1]
                else:
                    content_hash = hashlib.sha256(path.read_bytes()).digest()
            except FileNotFoundError:
                continue
            digest.update(str(relative).encode())
            digest.update(content_hash)
            current[path] = (identity, content_hash)
    if cache is not None:
        cache.clear()
        cache.update(current)
    return digest.digest()


class Development:
    def __init__(self):
        version = CURRENT.read_text().strip() if CURRENT.exists() else ''
        if not valid_version(version) or not all((BUILDS / version / name).is_file() for name in RUNTIME_ASSETS):
            version = ''
        self.status = {'version': version, 'building': False, 'error': ''}
        self.stop = threading.Event()

    def build(self, source):
        version = uuid.uuid4().hex
        output = BUILDS / version
        self.status = dict(self.status, building=True, error='')
        print('Building debug game…', flush=True)
        try:
            result = subprocess.run(['./scripts/build.sh', 'debug'], cwd=ROOT,
                                    env=dict(os.environ, WEB_OUTPUT=str(output)))
            if result.returncode:
                shutil.rmtree(output, ignore_errors=True)
                self.status = dict(self.status, building=False, error='Build failed; keeping the current game. See the terminal.')
                print(self.status['error'], flush=True)
                return True
            if fingerprint() != source:
                shutil.rmtree(output, ignore_errors=True)
                self.status = dict(self.status, building=False)
                return False
            if not all((output / name).is_file() for name in ASSETS):
                self.status = dict(self.status, building=False, error='Build output incomplete; current game retained.')
                return True
            pending = CURRENT.with_suffix('.next')
            pending.write_text(version)
            pending.replace(CURRENT)
        except OSError as error:
            # Keep unpublished output for recovery/inspection if filesystem publication fails.
            self.status = dict(self.status, building=False, error=f'Build or publication failed; current game retained: {error}')
            print(self.status['error'], flush=True)
            return True
        self.status = {'version': version, 'building': False, 'error': ''}
        print(f'Published debug build {version[:8]}', flush=True)
        return True

    def watch(self):
        attempted = None
        # Poll metadata cheaply; build publication still rehashes every input.
        cache = {}
        while not self.stop.is_set():
            try:
                source = fingerprint(cache)
                if source != attempted:
                    if self.stop.wait(DEBOUNCE_SECONDS):
                        break
                    if fingerprint(cache) != source:
                        continue
                    attempted = source if self.build(source) else None
            except OSError as error:
                # Source access can recover without restarting the server. Retry
                # even unchanged inputs so a successful build clears the error.
                attempted = None
                message = f'Cannot inspect source; current game retained: {error}'
                if self.status['error'] != message:
                    print(message, flush=True)
                self.status = dict(self.status, building=False, error=message)
            self.stop.wait(POLL_SECONDS)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, development, **kwargs):
        self.development = development
        super().__init__(*args, directory=str(BUILDS), **kwargs)

    def log_message(self, *_):
        pass

    def send_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path
        status = self.development.status
        if path == '/__dev/status':
            self.send_bytes(json.dumps(status).encode(), 'application/json')
        elif path == '/':
            if status['version']:
                self.send_response(302)
                self.send_header('Location', '/' + status['version'] + '/')
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
            else:
                self.send_bytes(b'<title>Devil\'s Arena development</title><p>Waiting for a successful debug build. See the terminal.</p><script>setTimeout(()=>location.reload(),1000)</script>', 'text/html')
        else:
            parts = path.strip('/').split('/')
            if len(parts) not in (1, 2) or not valid_version(parts[0]):
                self.send_error(404)
                return
            name = parts[1] if len(parts) == 2 else 'index.html'
            if name not in ASSETS:
                self.send_error(404)
                return
            file = BUILDS / parts[0] / name
            if not file.is_file():
                self.send_error(404)
                return
            if path == '/' + parts[0]:
                # Relative runtime URLs need the version directory as their base.
                self.send_response(302)
                self.send_header('Location', path + '/')
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                return
            self.send_bytes(file.read_bytes(), self.guess_type(str(file)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8001)
    args = parser.parse_args()
    BUILDS.mkdir(parents=True, exist_ok=True)
    development = Development()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), functools.partial(Handler, development=development))
    worker = threading.Thread(target=development.watch, daemon=True)
    worker.start()
    print(f'Open http://localhost:{server.server_port} — watching source files. Ctrl-C stops the server.', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        development.stop.set()
        server.server_close()


if __name__ == '__main__':
    main()
