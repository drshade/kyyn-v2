#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

node tools/test-local-install.mjs

journey_stage=$(mktemp -d /tmp/kyyn-installed-stage.XXXXXXXX)
trap 'rm -rf -- "$journey_stage"' EXIT
bash tools/install-cli.sh "$journey_stage/install"
node tools/test-secrets.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-judgement.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-guest-api.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-cpp-paths.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-curation-persistence.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-fact-proposal.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-curation-declarations.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-install.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-guides.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-taps.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-evolution.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-connector-fetch.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-network-connector.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-graph-install.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-initialization.mjs "$journey_stage/install/bin/kyyn-v2"
make -C vendor/MicroHs bin/mhs
export MHSDIR="$journey_stage/install/lib/kyyn-v2/lib/kyyn/microhs"
export MHSCPPHS="$MHSDIR/bin/cpphs"
compiler_args=(-a -i "-i$PWD/host/kyyn/test/compiler-parity"
  "-i$journey_stage/install/lib/kyyn-v2/lib/kyyn/sdk" "-i$MHSDIR/lib"
  "$PWD/host/kyyn/test/compiler-parity/Main.hs")
"$MHSDIR/bin/mhs" "${compiler_args[@]}" "-o$journey_stage/native.comb"
vendor/MicroHs/bin/mhs "${compiler_args[@]}" "-o$journey_stage/self-hosted.comb"
cmp "$journey_stage/native.comb" "$journey_stage/self-hosted.comb"
"$MHSDIR/bin/mhseval" +RTS "-r$journey_stage/native.comb" -RTS
KYYN_TEST_ROOT="$PWD" KYYN_TEST_CLI="$journey_stage/install/bin/kyyn-v2" \
  cabal test installed-journey --test-show-details=direct
