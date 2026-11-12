#!/usr/bin/env bash
# Flake-built CLI in a disposable GC root. Real Git/Dhall/locked guest journeys;
# no live credentials or changes to the user installation.
set -euo pipefail
cd "$(dirname "$0")/.."

journey_stage=$(mktemp -d /tmp/kyyn-installed-stage.XXXXXXXX)
trap 'rm -rf -- "$journey_stage"' EXIT
nix --extra-experimental-features 'nix-command flakes' build .#kyyn --no-update-lock-file --out-link "$journey_stage/install"
node tools/test-native-guest.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-stored-evolution.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-guide.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-secrets.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-compiler-diagnostics.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-judgement.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-discovery-scope.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-guest-api.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-closed-recipes.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-recipe-state.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-recipe-state-run.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-recipe-run.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-fact-proposal.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-root-browsing.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-authored-api.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-install.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-onboarding.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-guides.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-taps.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-plugin-evolution.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-connector-fetch.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-connector-fetch.mjs "$journey_stage/install/bin/kyyn-v2" --report-smoke
node tools/test-network-connector.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-blob-connector.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-graph-install.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-graph-transcript.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-salesforce-install.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-github-install.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-initialization.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-model-tool.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-probability.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-unit-contract.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-web.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-evidence-web.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-query-cli.mjs "$journey_stage/install/bin/kyyn-v2"
node tools/test-output-cli.mjs "$journey_stage/install/bin/kyyn-v2"
KYYN_TEST_ROOT="$PWD" KYYN_TEST_CLI="$journey_stage/install/bin/kyyn-v2" \
  cabal test installed-journey --test-show-details=direct
