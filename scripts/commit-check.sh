#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/check-deps
./scripts/check.sh "$@"
exec ./scripts/fuzz.sh
