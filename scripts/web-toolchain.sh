# Immutable artifacts come from the same Nix SDK/runtime closure used by builds.
ODIN=$(./scripts/odin-ui.sh --compiler)
export ODIN
. ./scripts/emscripten.sh
: "${RAYLIB_WEB_LIB:?The locked Nix environment must supply WebAssembly Raylib}"
: "${RAYLIB_WEB_LICENSE:?The locked Nix environment must supply the Raylib license}"
if [ ! -f "$RAYLIB_WEB_LIB" ] || [ ! -f "$RAYLIB_WEB_LICENSE" ]; then
    echo 'The locked WebAssembly Raylib artifact is unavailable; rerun scripts/dev.' >&2
    exit 2
fi
export RAYLIB_WEB_LIB RAYLIB_WEB_LICENSE
