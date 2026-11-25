#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
exec "$root/scripts/dev" sh scripts/setup-web-in-env.sh "$@"
