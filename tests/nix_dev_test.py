"""Discover the unchanged shared launcher fixtures beside their scripts."""
from pathlib import Path
from runpy import run_path

LauncherTests = run_path(str(Path(__file__).resolve().parents[1] / 'scripts/test-dev.py'),
                         run_name='nix_dev_fixtures')['LauncherTests']
