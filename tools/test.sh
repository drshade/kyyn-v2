#!/usr/bin/env bash
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

bash -n tools/test.sh
bash -n tools/test-guest.sh
bash -n tools/stage-cli.sh
bash -n tools/stage-microhs.sh
bash -n tools/install-cli.sh
bash -n tools/test-installed.sh
node --check tools/checks/check-docs.mjs
node --check tools/checks/check-docs.test.mjs
node --check tools/test-local-install.mjs
node --check tools/test-guest-api.mjs
node --check architecture/evidence/json-probe/check.mjs
node tools/checks/check-docs.test.mjs
node tools/checks/check-docs.mjs
node --test tools/checks/check-imports.test.mjs
node tools/checks/check-imports.mjs
cabal build all
cabal test cli-arguments --test-show-details=direct
cabal test cli-adapters --test-show-details=direct
cabal test guest-catalogue --test-show-details=direct
node tools/test-cli-selection.mjs "$(cabal list-bin exe:kyyn-v2)"
node --check tools/test-initialization.mjs
node --check tools/test-plugin-install.mjs
cabal test processes --test-show-details=direct
cabal test dhall-values --test-show-details=direct
cabal test roots --test-show-details=direct
cabal test git-snapshots --test-show-details=direct
cabal test file-trees --test-show-details=direct
cabal test plugin-packages --test-show-details=direct
cabal test evidence-store --test-show-details=direct
cabal test curation-core --test-show-details=direct
cabal test document-persistence --test-show-details=direct
cabal test file-acquisition --test-show-details=direct
cabal test plugin-installation --test-show-details=direct
cabal test metadata --test-options=--codec-only --test-show-details=direct
cabal test queries --test-options=--pure --test-show-details=direct
cabal test evolution-core --test-show-details=direct
cabal test evolution-reports --test-show-details=direct
cabal test evolutions --test-options=--pure --test-show-details=direct
if [[ "${1:-}" == --full ]]; then
  bash tools/test-guest.sh
  bash tools/test-installed.sh
  echo "Full check passed, including real MicroHs integration tests."
else
  echo "Fast check passed: documentation, import boundaries, native build and process/filesystem tests."
fi
