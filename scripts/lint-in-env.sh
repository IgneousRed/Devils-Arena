#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ODIN=$(./scripts/odin-ui.sh --compiler)
export ODIN
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/lint.sh' >&2; exit 1; fi
mkdir -p .work/build
vet_flags='-vet -vet-tabs -vet-using-param -vet-nil-deref -vet-uninitialized -vet-atomic-access -strict-style -warnings-as-errors'
owned_vet="$vet_flags -vet-packages:src,catalog,effects,engine,functions,migrations,procedures,state,views,schema,headless,tests -strict-style-packages:src,catalog,effects,engine,functions,migrations,procedures,state,views,schema,headless,tests"
# The shared analyzer assumes every selected configuration passed Odin first.
./scripts/odin-ui.sh check src $owned_vet
./scripts/odin-ui.sh check src $vet_flags -vet-unused-procedures -vet-packages:src -strict-style-packages:src
for development in true false; do
    echo "Checking browser WEB_DEVELOPMENT=$development (all owned-package vet flags)"
    ./scripts/odin-ui.sh check src -target:js_wasm32 -webkit-switch-workaround \
        -define:RAYLIB_WASM_LIB=env.o -define:WEB_DEVELOPMENT="$development" $owned_vet
    echo "Checking browser WEB_DEVELOPMENT=$development (closed entry point, unused procedures)"
    ./scripts/odin-ui.sh check src -target:js_wasm32 -webkit-switch-workaround \
        -define:RAYLIB_WASM_LIB=env.o -define:WEB_DEVELOPMENT="$development" \
        $vet_flags -vet-unused-procedures -vet-packages:src -strict-style-packages:src
done
./scripts/odin-ui.sh check scripts/schema $owned_vet
./scripts/odin-ui.sh check scripts/schema $vet_flags -vet-unused-procedures -vet-packages:schema -strict-style-packages:schema
./scripts/odin-ui.sh check apps/headless $owned_vet
./scripts/odin-ui.sh check apps/headless $vet_flags -vet-unused-procedures -vet-packages:headless -strict-style-packages:headless
./scripts/odin-ui.sh test src/engine $owned_vet -out:.work/build/engine-tests
./scripts/odin-ui.sh test tests $owned_vet -out:.work/build/tests
./scripts/odin-ui.sh test scripts/schema $owned_vet -out:.work/build/schema-tests
./scripts/odin-ui.sh test apps/headless $owned_vet -out:.work/build/headless-tests
storage=$(mktemp -d .work/storage.XXXXXX)
storage_root=$PWD
trap 'rm -rf "$storage"' EXIT
(cd "$storage" && "$storage_root/scripts/odin-ui.sh" test "$storage_root/src/effects" \
    $owned_vet -out:"$storage_root/.work/build/storage-tests")
echo 'Odin compiler checks and tests passed; running shared odin-lint.'
odin-lint \
    --root . --source-root src --collection odin_ui=.vendor/odin_ui \
    src apps/headless scripts/schema tests
