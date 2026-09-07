#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
    echo "The development gate requires Node.js 22+; see docs/PROJECT-PRACTICES.md." >&2
    exit 1
fi
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node.js 22+ is required for the development gate."); process.exit(1); }'

bash -n tools/test.sh
node --check tools/checks/check-docs.mjs
node --check tools/checks/check-docs.test.mjs
node --check architecture/evidence/json-probe/check.mjs
node tools/checks/check-docs.test.mjs
node tools/checks/check-docs.mjs

echo "Complete current gate passed: documentation and checker regression tests."
echo "No host, guest, plugin or Web implementation is present yet."
