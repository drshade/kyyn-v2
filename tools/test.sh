#!/usr/bin/env bash
# Fast native/docs checks by default; --full adds real guest and installed journeys.
# Suite coverage/setup belongs in test headers, not the process document.
set -euo pipefail

cd "$(dirname "$0")/.."

case "${*}" in
  ""|--full) ;;
  *) echo "Usage: bash tools/test.sh [--full]" >&2; exit 2 ;;
esac

if ! command -v node >/dev/null 2>&1; then
    echo "The development gate requires Node.js 22+; see docs/PROJECT-PRACTICES.md." >&2
    exit 1
fi
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node.js 22+ is required for the development gate."); process.exit(1); }'

for script in tools/test.sh tools/test-guest.sh tools/test-installed.sh; do bash -n "$script"; done
for script in tools/test-*.mjs tools/checks/*.mjs; do node --check "$script"; done
node tools/checks/check-docs.test.mjs
node tools/checks/check-docs.mjs
node tools/checks/check-plugin-catalogue.mjs
node --test tools/checks/check-imports.test.mjs
node tools/checks/check-imports.mjs
cabal build all
cabal test sync-timings cli-arguments cli-adapters guest-catalogue \
  processes frames concurrent-execution dhall-values roots git-snapshots file-trees \
  plugin-packages evidence-store blob-storage document-persistence file-acquisition \
  secret-store judgement-provider model-turn-provider contract-roles plugin-installation \
  evolution-core snapshot-preparation target-evolution stored-snapshots snapshot-reports snapshot-archives input-types recipe-state evidence-index plugin-host scalar-storage \
  description-storage guest-compilation-cache inspection captured-bindings edit-bindings source-inventory recipe-bindings \
  wire-contracts guest-protocol capabilities guest-scheduler \
  --test-show-details=direct
cabal exec -- runghc -package=kyyn-guest-build tools/test-plugin-source.hs
node tools/test-inspection-flow.mjs
node tools/test-framing.mjs
node tools/test-cli-selection.mjs "$(cabal list-bin exe:kyyn-v2)"
if [[ "${1:-}" == --full ]]; then
  bash tools/test-guest.sh
  bash tools/test-installed.sh
  echo "Full check passed, including real Nix/GHC guest integration tests."
else
  echo "Fast check passed: documentation, import boundaries, native build and process/filesystem tests."
fi
