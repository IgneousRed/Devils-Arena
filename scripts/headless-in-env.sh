#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mkdir -p "$project/.work/build"
"$project/scripts/odin-ui.sh" build "$project/apps/headless" -vet -debug -out:"$project/.work/build/headless"
exec "$project/.work/build/headless" "$@"
