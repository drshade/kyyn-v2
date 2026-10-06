#!/usr/bin/env bash
# Real MicroHs integration with a disposable bundled native toolchain.
# Selects KYYN_TEST_ROOT/TOOLCHAIN and CPP explicitly; no live provider credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
export KYYN_TEST_ROOT="$PWD"
guest_test_stage=$(mktemp -d "${TMPDIR:-/tmp}/kyyn-guest-tests.XXXXXXXX")
trap 'rm -rf -- "$guest_test_stage"' EXIT
export KYYN_TEST_TOOLCHAIN="$guest_test_stage/microhs"
bash tools/stage-microhs.sh "$KYYN_TEST_TOOLCHAIN"
export MHSDIR="$KYYN_TEST_TOOLCHAIN"
export MHSCPPHS="$KYYN_TEST_TOOLCHAIN/bin/cpphs"
node tools/test-large-lines.mjs
node tools/test-framing.mjs
cabal test guest-api --test-show-details=direct
cabal test codecs --test-show-details=direct
cabal test metadata --test-show-details=direct
cabal test queries --test-show-details=direct
cabal test plugin-fetch --test-show-details=direct
cabal test graph-calendar --test-show-details=direct
cabal test plugin-registration --test-show-details=direct
cabal test judgements --test-show-details=direct
node tools/test-agentic.mjs
cabal test fact-edit-bindings --test-show-details=direct
cabal test agentic-contracts --test-show-details=direct
cabal test model-tools --test-show-details=direct
cabal test evolutions --test-show-details=direct
cabal test workspace-evolutions --test-show-details=direct
