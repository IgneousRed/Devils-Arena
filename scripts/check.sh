#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
exec "$root/scripts/dev" bash scripts/check-in-env.sh "$@"
