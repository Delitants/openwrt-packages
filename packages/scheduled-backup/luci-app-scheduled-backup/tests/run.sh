#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ROOT
for test in "$ROOT"/tests/test_*.sh; do sh "$test"; done
