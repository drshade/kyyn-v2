// One real target-only Nix/GHC guest: facts, residual fields and a closed recipe
// migrate together; an obsolete flow name is data and is retired without imports.
// The installed CLI/publication proof is a separate journey.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { Readable } from 'node:stream';
import path from 'node:path';
import { encodeFrame, readFrames } from './lib/framing.mjs';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-target-evolution.mjs GUEST');
const executable = path.resolve(process.argv[2]);
async function invoke(request) {
  const bytes = execFileSync('bash', ['-c', 'set -o pipefail; cat | "$@" | cat', 'target-evolution', executable],
    { input: encodeFrame(request), timeout: 60000, maxBuffer: 16 * 1024 * 1024 });
  const replies = [];
  for await (const frame of readFrames(Readable.from([bytes]))) replies.push(frame.metadata);
  assert.equal(replies.length, 1);
  return replies[0];
}
const shape = (tag, contents) => contents === undefined ? {tag} : {tag, contents};
const record = fields => shape('StoredRecord', Object.entries(fields));
const text = shape('StoredText'), integer = shape('StoredInteger');
const stored = (shape, value) => ({shape, value});
const snapshot = {
  fields: [],
  collections: [['items', [['one', stored(record({id: text, value: record({amount: integer})}), {id: 'one', value: {amount: '7'}})]]]],
  recipes: [
    ['weekly', {definition: {kind: 'closed', flow: 'Flows.review'}, state: stored(record({count: integer}), {count: '4'})}],
    ['notAFlow', {definition: {kind: 'closed', flow: 'Flows.oldFlow'}, state: stored(record({}), {})}],
    ['noContract', {definition: {kind: 'open', instructions: 'Obsolete', stateType: 'Flows.OldState'}, state: stored(record({}), {})}],
    ['obsolete', {definition: {kind: 'closed', flow: 'Missing.obsolete'}, state: stored(record({}), {})}],
  ],
};
const description = await invoke({operation: 'describe'});
assert.equal(description.entries.find(e => e.kind === 'evolution').contracts.kind, 'target');
assert(!JSON.stringify(description).includes('.kyyn-before'));
const result = await invoke({operation: 'invoke', entry: 'Evolution.evolution', argument: {snapshot, explanation: 'Fixture migration'}});
assert.equal(result.tag, 'Succeeded', JSON.stringify(result));
assert.deepEqual(result.value.after.facts, {items: [{id: 'one', value: {amount: '7', note: 'migrated'}}], total: '1'});
assert.equal(result.value.after.recipes.length, 1);
assert.equal(result.value.after.recipes[0].id, 'weekly');
assert.deepEqual(result.value.after.recipes[0].value.state, {runs: '4', reviewed: true});
assert.deepEqual(result.value.steps.map(s => s.origin), ['authored', 'authored', 'authored', 'authored', 'authored', 'authored', 'target-projection']);
assert.deepEqual(result.value.steps[0].before, snapshot);
for (let i = 1; i < result.value.steps.length; i++) assert.deepEqual(result.value.steps[i].before, result.value.steps[i-1].after);
assert.equal(result.value.steps.at(-1).rationale.explanation, 'Fixture migration');
const projection = result.value.steps.at(-1);
const verified = await invoke({operation: 'invoke', entry: '$evolution.project',
  argument: {snapshot: projection.before, explanation: 'Fixture migration'}});
assert.equal(verified.tag, 'Succeeded');
assert.equal(verified.value.steps.length, 1);
assert.deepEqual(verified.value.steps[0].after, projection.after);
assert.deepEqual(verified.value.after, result.value.after);
const invalid = structuredClone(snapshot);
invalid.collections[0][1][0][1].shape = record({id: text, value: record({wrong: integer})});
invalid.collections[0][1][0][1].value.value = {wrong: '7'};
const rejected = await invoke({operation: 'invoke', entry: 'Evolution.evolution', argument: {snapshot: invalid, explanation: 'Bad input'}});
assert.equal(rejected.tag, 'Rejected');
console.log('Real target-only guest migration and strict input refusal passed.');
