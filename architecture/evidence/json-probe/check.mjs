import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

const [baseline, profile, host] = process.argv.slice(2);
assert.ok(baseline && profile && host, 'Usage: node check.mjs BASELINE PROFILE HOST');

function invoke(executable, input = '') {
  const result = spawnSync(executable, [], {
    input, encoding: 'utf8', timeout: 10000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

const value = {
  text: 'München 日本語 🦋\n\t\u0000',
  amount: '123456789012345678901234567890.001',
  option: { tag: 'Some', value: { tag: 'None' } },
  empty: [],
};
const escaped = '{"x":"\\ud83e\\udd8b"}';
const raw = invoke(baseline, JSON.stringify(value) + '\n');
assert.equal(raw.status, 0, raw.stderr);
assert.deepEqual(JSON.parse(raw.stdout), value);
const broken = invoke(baseline, escaped + '\n');
assert.notEqual(broken.status, 0);
assert.match(broken.stderr, /surrogate/);
assert.throws(() => JSON.parse(broken.stdout));

const cases = [
  [JSON.stringify(value), value],
  [escaped, { error: true }],
  ['{"x":01}', { error: true }],
  ['{"x":', { error: true }],
  ['{"x":true} rubbish', { error: true }],
  ['{"x":"first","x":"last"}', { x: 'first' }],
  ['{"nested":[{"x":"\\ud83e\\udd8b"}]}', { error: true }],
  ['{"nested":[{"\\ud83e\\udd8b":"x"}]}', { error: true }],
];
for (const [input, expected] of cases) {
  const result = invoke(profile, input + '\n');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), expected);
  assert.equal(result.stdout.split('\n').length, 2, 'exactly one complete frame');
}

const native = invoke(host);
assert.equal(native.status, 0, native.stderr);
const [encoded, duplicates, trailing] = native.stdout.split('\n');
assert.deepEqual(JSON.parse(encoded), { text: value.text });
assert.ok(encoded.includes('日本語 🦋'), 'Aeson must emit literal UTF-8');
assert.ok(encoded.includes('\\u0000'), 'Aeson must escape NUL');
assert.equal(duplicates, 'Right (Object (fromList [("x",Number 1.0)]))',
  'pinned Aeson 2.2.5.0 keeps the first duplicate key');
assert.equal(trailing, '');
const fromHost = invoke(profile, encoded + '\n');
assert.equal(fromHost.status, 0, fromHost.stderr);
assert.deepEqual(JSON.parse(fromHost.stdout), { text: value.text });
console.log('Baseline failure reproduced; 8 profile cases and pinned Aeson checks passed.');
