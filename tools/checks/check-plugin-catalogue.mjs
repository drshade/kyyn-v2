import assert from 'node:assert/strict';
import fs from 'node:fs';

// This checks the repository's literal catalogue convention, not general Dhall.
const catalogue = fs.readFileSync('kyyn-tap.dhall', 'utf8');
const entries = [...catalogue.matchAll(/\{([^{}]*)\}/g)].map(match => ({
  name: match[1].match(/\bname\s*=\s*"([^"]+)"/)?.[1],
  path: match[1].match(/\bpath\s*=\s*"([^"]+)"/)?.[1]
}));
const packages = fs.readdirSync('plugins').filter(name => fs.existsSync(`plugins/${name}/kyyn-plugin.dhall`)).sort();
assert.deepEqual(entries.sort((a,b) => a.name.localeCompare(b.name)),
  packages.map(name => ({ name, path: `plugins/${name}` })),
  'First-party catalogue entries must match plugin packages');
for (const name of packages) {
  const manifest = fs.readFileSync(`plugins/${name}/kyyn-plugin.dhall`, 'utf8');
  assert.equal(manifest.match(/\bname\s*=\s*"([^"]+)"/)?.[1], name, 'Plugin directory and manifest names must agree');
}
console.log('First-party catalogue matches plugin packages.');
