import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const provenance = readFileSync('vendor/README.md', 'utf8');
const toolchain = readFileSync('host/kyyn-microhs/src/Kyyn/MicroHs/Toolchain.hs', 'utf8');
const archiveRevision = provenance.match(/^\| MicroHs \| \[([0-9a-f]{40})\]/m)?.[1];
const cacheRevision = toolchain.match(/^toolchainRevision = "([0-9a-f]{40})"$/m)?.[1];
assert.ok(archiveRevision, 'Missing MicroHs archive revision');
assert.equal(cacheRevision, archiveRevision, 'Compile-cache identity must match the vendored MicroHs revision');
console.log('MicroHs archive and compile-cache revisions match.');
