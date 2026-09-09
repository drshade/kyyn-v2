#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

journey_stage=$(mktemp -d /tmp/kyyn-installed-stage.XXXXXXXX)
trap 'rm -rf -- "$journey_stage"' EXIT
bash tools/stage-cli.sh "$journey_stage/install"
KYYN_TEST_ROOT="$PWD" KYYN_TEST_CLI="$journey_stage/install/bin/kyyn" \
  cabal test installed-journey --test-show-details=direct
