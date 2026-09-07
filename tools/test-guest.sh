#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export KYYN_TEST_ROOT="$PWD"
export MHSDIR="$PWD/vendor/MicroHs"
make -C vendor/MicroHs bin/mhs bin/mhseval bin/cpphs
cabal test codecs --test-show-details=direct
