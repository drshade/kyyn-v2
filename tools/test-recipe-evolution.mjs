// Recipe edits share target projection and structural observations with migrations.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { Readable } from 'node:stream';
import path from 'node:path';
import { encodeFrame, readFrames } from './lib/framing.mjs';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-recipe-evolution.mjs GUEST');
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
const state = stored(record({reviewed: shape('StoredBool'), runs: integer}), {runs: '4', reviewed: false});
const recipe = () => ({definition: {kind: 'closed', flow: 'Flows.review'}, state: structuredClone(state)});
const snapshot = {
  fields: [['total', stored(integer, '0')]],
  collections: [['items', []]],
  recipes: [['weekly', recipe()], ['untouched', recipe()]],
};
const request = snapshot => ({operation: 'invoke', entry: 'Evolution.evolution',
  argument: {snapshot, recipe: 'weekly', explanation: 'Run selected recipe'}});
const result = await invoke(request(snapshot));
assert.equal(result.tag, 'Succeeded', JSON.stringify(result));
assert.deepEqual(result.value.steps.map(s => s.origin), ['target-projection', 'authored']);
assert.deepEqual(result.value.steps[0].before, snapshot);
assert.deepEqual(result.value.steps[1].before, result.value.steps[0].after);
assert.deepEqual(result.value.after.facts, {items: [{id: 'new', value: {amount: '9', note: 'new'}}], total: '0'});
const recipes = result.value.after.recipes;
assert.deepEqual(recipes.find(r => r.id === 'weekly').value.state, {runs: '5', reviewed: true});
assert.deepEqual(recipes.find(r => r.id === 'untouched').value.state, state.value);
assert.deepEqual(result.value.steps[1].after.recipes.find(([id]) => id === 'untouched')[1],
  result.value.steps[1].before.recipes.find(([id]) => id === 'untouched')[1]);
const projected = await invoke({operation: 'invoke', entry: '$evolution.project',
  argument: {snapshot, explanation: 'Run selected recipe'}});
assert.equal(projected.tag, 'Succeeded');
assert.deepEqual(projected.value.steps[0], result.value.steps[0]);
const missing = request(snapshot); missing.argument.recipe = 'missing';
assert.equal((await invoke(missing)).tag, 'Rejected');
const malformed = structuredClone(snapshot);
malformed.recipes[0][1].state = stored(record({wrong: integer}), {wrong: '4'});
assert.equal((await invoke(request(malformed))).tag, 'Rejected');
console.log('Recipe evolution uses structural projection, edits only selected state, and rejects invalid inputs.');
