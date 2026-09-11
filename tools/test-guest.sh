#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export KYYN_TEST_ROOT="$PWD"
export MHSDIR="$PWD/vendor/MicroHs"
make -C vendor/MicroHs bin/mhs bin/mhseval bin/cpphs
cabal test guest-api --test-show-details=direct
cabal test codecs --test-show-details=direct
cabal test metadata --test-show-details=direct
cabal test queries --test-show-details=direct
cabal test evolutions --test-show-details=direct
cabal test workspace-evolutions --test-show-details=direct
