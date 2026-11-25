#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
./scripts/setup-web.sh
. ./scripts/emscripten.sh
: "${PLAYWRIGHT_BROWSERS_PATH:?The locked Nix browser environment is required}"
: "${PLAYWRIGHT_MODULE:?The locked Nix Playwright module is required}"
export PLAYWRIGHT_BROWSERS_PATH
exec "$NODE" "$@"
