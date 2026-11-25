# Sourced from the project root after scripts/dev applies the locked manifest.
: "${EMCC:?Enter the locked Nix project environment through scripts/dev}"
: "${NODE:?Enter the locked Nix project environment through scripts/dev}"
if [ ! -x "$EMCC" ] || [ ! -x "$NODE" ]; then
    echo 'The locked Emscripten/Node environment is unavailable; rerun scripts/dev.' >&2
    exit 2
fi
PATH="$(dirname "$EMCC"):$(dirname "$NODE"):$PATH"
export PATH
unset EM_CACHE
EM_FROZEN_CACHE=1
EM_NODE_JS="$NODE"
export EM_FROZEN_CACHE EM_NODE_JS
