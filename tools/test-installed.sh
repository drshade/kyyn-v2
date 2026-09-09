#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

journey_stage=$(mktemp -d /tmp/kyyn-installed-stage.XXXXXXXX)
trap 'rm -rf -- "$journey_stage"' EXIT
bash tools/stage-cli.sh "$journey_stage/install"
make -C vendor/MicroHs bin/mhs
export MHSDIR="$journey_stage/install/lib/kyyn/microhs"
export MHSCPPHS="$MHSDIR/bin/cpphs"
compiler_args=(-a -i "-i$PWD/host/kyyn/test/compiler-parity"
  "-i$journey_stage/install/lib/kyyn/sdk" "-i$MHSDIR/lib"
  "$PWD/host/kyyn/test/compiler-parity/Main.hs")
"$MHSDIR/bin/mhs" "${compiler_args[@]}" "-o$journey_stage/native.comb"
vendor/MicroHs/bin/mhs "${compiler_args[@]}" "-o$journey_stage/self-hosted.comb"
cmp "$journey_stage/native.comb" "$journey_stage/self-hosted.comb"
"$MHSDIR/bin/mhseval" +RTS "-r$journey_stage/native.comb" -RTS
KYYN_TEST_ROOT="$PWD" KYYN_TEST_CLI="$journey_stage/install/bin/kyyn" \
  cabal test installed-journey --test-show-details=direct
