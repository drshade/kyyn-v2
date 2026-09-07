#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
    echo "The development gate requires Node.js 22+; see docs/PROJECT-PRACTICES.md." >&2
    exit 1
fi
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node.js 22+ is required for the development gate."); process.exit(1); }'

bash -n tools/test.sh
bash -n tools/test-guest.sh
node --check tools/checks/check-docs.mjs
node --check tools/checks/check-docs.test.mjs
node --check architecture/evidence/json-probe/check.mjs
node tools/checks/check-docs.test.mjs
node tools/checks/check-docs.mjs
node --test tools/checks/check-imports.test.mjs
node tools/checks/check-imports.mjs
cabal build all
cabal test processes --test-show-details=direct
bash tools/test-guest.sh
echo "Complete gate passed: documentation, import boundaries, native process lifetimes and real MicroHs codec tests."
