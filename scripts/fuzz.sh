#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
exec "$root/scripts/dev" --profile fuzz nice -n 10 python3 tools/run_odin_fuzz.py "$@"
