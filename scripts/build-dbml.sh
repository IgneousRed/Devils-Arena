#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then echo 'Usage: scripts/build-dbml.sh' >&2; exit 1; fi
mkdir -p .work .work/build/schema
work=$(mktemp -d .work/schema.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
./scripts/odin-ui.sh build scripts/schema -vet -out:"$work/schema"
for diagram in runtime persistence; do
    "$work/schema" "$diagram" > "$work/$diagram.dbml"
done
for diagram in runtime persistence; do
    mv "$work/$diagram.dbml" ".work/build/schema/$diagram.dbml"
    echo "Wrote .work/build/schema/$diagram.dbml"
done
