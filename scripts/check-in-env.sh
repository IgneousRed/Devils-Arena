#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
    ""|browser) ;;
    *) echo 'Usage: scripts/check.sh [browser]' >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then echo 'Usage: scripts/check.sh [browser]' >&2; exit 1; fi
mkdir -p .work
python3 -B tools/test_shared_raylib.py
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m unittest discover -s tests -p '*_test.py'
./scripts/build.sh native
WEB_OUTPUT=.work/build/debug-check ./scripts/build.sh debug
WEB_OUTPUT=.work/build/release-check ./scripts/build.sh
. ./scripts/emscripten.sh
for script in web/*.js tests/*.mjs; do node --check "$script"; done
node --test tests/web_test.mjs
if [ "${1:-}" = browser ]; then ./scripts/browser.sh tests/browser.mjs; fi
# Run lint last so existing non-lint checks also run when shared policies find debt.
./scripts/lint.sh
