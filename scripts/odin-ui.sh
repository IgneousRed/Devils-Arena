#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
compiler=${ODIN:?Enter the locked Nix project environment through scripts/dev}
compiler=$(python3 - "$compiler" <<'PY'
from pathlib import Path
import shutil
import sys
compiler = shutil.which(sys.argv[1])
if compiler is None:
    raise SystemExit(f'Odin compiler not found: {sys.argv[1]}')
print(Path(compiler).resolve())
PY
)
if [ "${1:-}" = --compiler ]; then
    printf '%s\n' "$compiler"
    exit 0
fi
python3 "$project/tools/prepare_dependencies.py"
ui="$project/.vendor/odin_ui"
if [ ! -f "$ui/raylib/raylib.odin" ]; then
    echo "Locked Odin UI dependency view is missing: $ui" >&2
    exit 1
fi
version=$(python3 "$project/scripts/version.py" "$compiler" "$@")
exec "$compiler" "$@" "-define:APPLICATION_VERSION=$version" "-collection:odin_ui=$ui"
