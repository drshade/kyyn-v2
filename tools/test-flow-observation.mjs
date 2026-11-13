// Real generated observer/dispatch, scripted host, no provider calls. Matches
// Each/Repeat/choice/tool/failed occurrences to the same built guest's graph.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { encodeFrame, readFrames } from './lib/framing.mjs';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-flow-observation.mjs GUEST');
const guest = process.argv[2];
const tagged = (tag, value) => value === undefined ? {tag} : {tag,value};
function value(x) {
  if (x === null) return tagged('Null');
  if (typeof x === 'string') return tagged('String', x);
  throw new Error('Fixture needs only string/null model values');
}
function decode(x) {
  switch (x.tag) {
    case 'Null': return null;
    case 'String': case 'Bool': return x.value;
    case 'Integer': case 'Number': return Number(x.value);
    case 'Array': return x.value.map(decode);
    case 'Object': return Object.fromEntries(x.value.map(({key,value}) => [key,decode(value)]));
    default: throw new Error(`Unknown library value ${JSON.stringify(x)}`);
  }
}
async function invoke(entry, argument, handle) {
  const child = spawn(guest, [], {stdio: ['pipe','pipe','pipe']});
  const closed = once(child, 'close');
  let errors = '';
  child.stderr.on('data', bytes => { errors += bytes; });
  const timer = setTimeout(() => child.kill('SIGKILL'), 60000);
  try {
    child.stdin.write(encodeFrame({operation: 'invoke', entry, argument}));
    let completed;
    for await (const {metadata,body} of readFrames(child.stdout)) {
      assert.equal(body.length, 0);
      if (metadata.tag === 'HostRequest') {
        const result = handle(metadata);
        child.stdin.write(encodeFrame({tag: 'HostResponse', id: metadata.id, result}));
      } else {
        assert.equal(completed, undefined, 'Only one completion');
        completed = metadata;
        child.stdin.end();
      }
    }
    const [code] = await closed;
    assert.equal(code, 0, errors);
    assert.notEqual(completed, undefined);
    return completed;
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null) child.kill();
  }
}
const graph = decode(await invoke('$recipe.Flows.trace', {operation: 'graph'}, () => {
  throw new Error('Graph capture attempted an effect');
}));
const addresses = new Set(graph.addressItems.map(x => x.address));
const selections = new Set(graph.edges.flatMap(x => x.selections));
const key = occurrence => JSON.stringify(occurrence);
for (const failModel of [false, true]) {
  const summaries = [];
  let modelCalls = 0;
  const result = await invoke('$recipe.Flows.observedTrace', {
    operation: 'run', root: {items: []}, input: false, state: {runs: '0'},
  }, request => {
    if (request.capability === 'flow') {
      assert.equal(request.method, 'observe');
      summaries.push(decode(request.arguments));
      return {};
    }
    assert.equal(request.capability, 'model');
    assert.equal(request.method, 'turn');
    modelCalls++;
    if (failModel) return tagged('Left', 'model unavailable');
    let action;
    if (modelCalls === 1) action = tagged('CallTools', [{id: 'call', name: 'helper', input: value('private input')}]);
    else action = tagged('Respond', value('private output'));
    return tagged('Right', {raw: value(null), action});
  });
  assert.equal(result.tag, 'Completed');
  assert.equal(result.result.tag, failModel ? 'Left' : 'Right');
  assert.equal(modelCalls, failModel ? 1 : 3);
  const entered = new Map(), terminals = new Set();
  for (const summary of summaries) {
    assert(!('payload' in summary));
    assert(addresses.has(summary.occurrence.address), 'Occurrence missing from captured graph');
    const id = key(summary.occurrence);
    if (summary.event.kind === 'entered') {
      assert(!entered.has(id), 'Occurrence identity collision');
      if (summary.parent !== null) assert(entered.has(key(summary.parent)), 'Parent entry must precede child');
      entered.set(id, summary);
    } else {
      assert(entered.has(id), 'Event before entry');
      assert.deepEqual(summary.parent, entered.get(id).parent);
      if (['returned','failed','cancelled'].includes(summary.event.kind)) {
        assert(!terminals.has(id), 'Second terminal');
        for (const [childId,child] of entered) {
          if (child.parent !== null && key(child.parent) === id) assert(terminals.has(childId), 'Child must finish first');
        }
        terminals.add(id);
      }
    }
    if (summary.event.kind === 'selected') assert(selections.has(summary.event.edge));
    if (summary.event.kind === 'callResolved') {
      assert(graph.bodies.some(b => b.binding === summary.event.binding && b.bodyRoot === summary.event.body));
    }
  }
  assert.equal(terminals.size, entered.size);
  const sides = new Set(summaries.filter(s => s.event.kind === 'selected').map(s => s.event.edge));
  assert.equal(sides.size, 2, 'Both choice sides executed');
  assert(summaries.some(s => s.node === 'each' && s.event.total === 2));
  assert(summaries.some(s => s.occurrence.context.some(frame => frame[0] === 'repeat' && frame[2] === 1)));
  assert(!JSON.stringify(summaries).includes('private input'));
  assert(!JSON.stringify(summaries).includes('private output'));
  if (failModel) {
    assert.equal(result.result.value, 'model unavailable');
    assert(summaries.some(s => s.node === 'draft' && s.event.kind === 'failed'));
    assert.equal(summaries.at(-1).node, 'run');
    assert.equal(summaries.at(-1).event.kind, 'failed');
  } else {
    assert(summaries.some(s => s.event.kind === 'callResolved'));
    assert(summaries.some(s => s.node === 'draft' && s.occurrence.context.some(frame => frame[0] === 'call')));
  }
}
console.log('Built guest: graph-linked Each, Repeat, choices, nested tools and Left failure observations passed.');
