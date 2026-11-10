#!/usr/bin/env bash
# Real Nix-built guest fixtures, compiler-owned inspection and host protocol tests.
# Provider callbacks are recorded; no live credentials are used.
set -euo pipefail
cd "$(dirname "$0")/.."
nix_command=(nix --extra-experimental-features 'nix-command flakes')
guest_system=$("${nix_command[@]}" eval --impure --raw --expr builtins.currentSystem)
guest_stage=$(mktemp -d "${TMPDIR:-/tmp}/kyyn-guest-tests.XXXXXXXX")
trap 'rm -rf -- "$guest_stage"' EXIT
guest_source=$("${nix_command[@]}" flake metadata --json --no-update-lock-file | node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>console.log(JSON.parse(s).path))')
checks=(guest-frozen-api guest-model guest guest-schema guest-api guest-api-bindings guest-api-tools guest-plugins
  guest-tool guest-root-api guest-recipe guest-output guest-target-evolution guest-evolution guest-evolution-api
  guest-recipe-evolution guest-first-party)
for check in "${checks[@]}"; do
  "${nix_command[@]}" build "path:$guest_source#checks.$guest_system.$check" --no-update-lock-file --out-link "$guest_stage/$check"
done
protocol() {
  cabal test guest-protocol --test-show-details=direct --test-options="--$1-built $guest_stage/$2/bin/kyyn-guest"
}
cabal test guest-protocol --test-show-details=direct --test-options="--built $guest_stage/guest/bin/kyyn-guest"
protocol schema guest-schema
protocol api guest-api
protocol api-bindings guest-api-bindings
protocol api-tools guest-api-tools
protocol captured guest-plugins
protocol tool guest-tool
protocol root-api guest-root-api
protocol recipe guest-recipe
node tools/test-target-evolution.mjs "$guest_stage/guest-target-evolution/bin/kyyn-guest"
protocol evolution guest-evolution
protocol evolution-api guest-evolution-api
protocol recipe-evolution guest-recipe-evolution
protocol frozen-api guest-frozen-api
cabal test native-guest --test-show-details=direct --test-options="$guest_stage/guest/bin/kyyn-guest"
for pair in Model:guest-model PluginPreparation:guest-plugins ToolPreparation:guest-tool Output:guest-output Recipe:guest-recipe Evolution:guest-evolution EvolutionPreparation:guest-evolution-api; do
  cabal exec -- runghc -XGHC2021 -XOverloadedStrings -XNoFieldSelectors -Wall -Werror \
    -package=kyyn-domain -package=kyyn-types -package=kyyn-porcelain -package=kyyn-porcelain-interpreters \
    -package=kyyn-plumbing -package=kyyn-plumbing-interpreters \
    "host/kyyn-porcelain-interpreters/test/Native${pair%%:*}Tests.hs" "$guest_stage/${pair#*:}/bin/kyyn-guest"
done
KYYN_TEST_FIRST_PARTY="$guest_stage/guest-first-party/bin/kyyn-guest" \
  cabal test graph-directory graph-files graph-calendar graph-mail graph-meetings salesforce-query github --test-show-details=direct

# Independently locked KB: the actual host capture/build interpreter must preserve
# this lock and refuse an incomplete one. Fixture builds above do not prove that.
mkdir "$guest_stage/locked"
cp -R tools/fixtures/ghc-guest/. "$guest_stage/locked/"
cat > "$guest_stage/locked/flake.nix" <<EOF
{
  inputs.kyyn.url = "path:$guest_source";
  outputs = { self, kyyn }: {
    packages.$guest_system.kyyn-guest = kyyn.lib.mkGuest { system = "$guest_system"; src = ./.; };
  };
}
EOF
"${nix_command[@]}" flake lock "$guest_stage/locked"
cabal test nix-guest-build --test-show-details=direct \
  --test-options="$guest_stage/locked $(command -v nix) $guest_system"
