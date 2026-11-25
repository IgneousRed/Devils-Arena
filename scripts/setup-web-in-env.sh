#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 tools/prepare_dependencies.py
. ./scripts/web-toolchain.sh
printf 'Shared web raylib: %s\n' "$RAYLIB_WEB_LIB"
