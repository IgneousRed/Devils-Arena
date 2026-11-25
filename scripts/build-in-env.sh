#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ODIN=$(./scripts/odin-ui.sh --compiler)
export ODIN
development=false
optimization=speed
emcc_flags=-O2
odin_debug=
case "${1:-}" in
    "") ;;
    debug) development=true; optimization=none; emcc_flags='-O0 -g'; odin_debug=-debug ;;
    native)
        mkdir -p .work/build
        exec ./scripts/odin-ui.sh build src -vet -debug -out:.work/build/devils-arena
        ;;
    *) echo 'Usage: scripts/build.sh [debug|native]' >&2; exit 1 ;;
esac
. ./scripts/web-toolchain.sh
output=${WEB_OUTPUT:-.work/build/web}
mkdir -p "$(dirname "$output")"
# Staging beside the output keeps atomic directory exchange on one filesystem.
stage=$(mktemp -d "$(dirname "$output")/.web-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
# Published web assets must be traversable by a deployment server.
chmod u=rwx,go=rx "$stage"
# Odin's JS imports are connected by the host page; Emscripten supplies raylib's imports.
# The switch workaround also supports WebKit's WebAssembly JIT.
./scripts/odin-ui.sh build src -target:js_wasm32 -build-mode:obj -webkit-switch-workaround \
    -define:RAYLIB_WASM_LIB=env.o -define:WEB_DEVELOPMENT="$development" \
    -vet $odin_debug -o:"$optimization" -out:"$stage/game.o"
"$EMCC" "$stage/game.o" "$RAYLIB_WEB_LIB" -o "$stage/game.js" $emcc_flags \
    -sUSE_GLFW=3 -sSTACK_SIZE=2097152 -sINITIAL_MEMORY=33554432 \
    -sALLOW_MEMORY_GROWTH=1 -sASSERTIONS=1 -sENVIRONMENT=web \
    -sERROR_ON_UNDEFINED_SYMBOLS=0 -sWARN_ON_UNDEFINED_SYMBOLS=0 \
    --js-library web/storage.js
unlink "$stage/game.o"
cp "$("$ODIN" root)/core/sys/wasm/js/odin.js" "$stage/odin.js"
cp web/index.html "$stage/index.html"
cp web/recording.js "$stage/recording.js"
cp LICENSE "$stage/LICENSE.txt"
cp .vendor/odin_ui/LICENSE "$stage/ODIN-UI-LICENSE.txt"
cp "$RAYLIB_WEB_LICENSE" "$stage/RAYLIB-LICENSE.txt"
cp assets/licenses/AtkinsonHyperlegibleNext-OFL.txt "$stage/FONT-LICENSE.txt"
if [ "$development" = true ]; then
    cp web/dev.js "$stage/dev.js"
    python3 - "$stage/index.html" <<'PY'
from pathlib import Path
import sys
page = Path(sys.argv[1])
page.write_text(page.read_text().replace('<!-- DEVELOPMENT -->', '<script src="dev.js"></script>'))
PY
fi
# Compilation and publication failures leave the complete previous output intact.
python3 scripts/publish.py "$stage" "$output"
echo "Web build created in $output"
