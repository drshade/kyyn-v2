// GHC/MicroHs proof over real pipe frames: nested typed drafting, malformed-output
// retry, provider refusal, response IDs, fact-edit ordering and failures.
// Uses scripted providers/handwritten codecs, not production binding generation.
// Also checks pair-pattern authoring and branch-selecting diagrams under both compilers.

import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, cpSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFrames, encodeFrame } from './lib/framing.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const toolchain = process.env.KYYN_TEST_TOOLCHAIN;
if (!toolchain) throw new Error('Set KYYN_TEST_TOOLCHAIN to a staged MicroHs runtime');
const temporary = mkdtempSync(path.join(tmpdir(), 'kyyn-agentic-'));
const env = { ...process.env, MHSDIR: toolchain, MHSCPPHS: path.join(toolchain, 'bin/cpphs') };
const fixture = path.join(root, 'tests/integration/agentic');
const includes = ['tests/integration/agentic', 'vendor/agentic/src', 'guest/kyyn-runtime/src',
  'guest/kyyn-sdk/src', 'shared/kyyn-types/src', 'vendor/json', 'vendor/transformers']
  .map(p => `-i${path.join(root, p)}`);
const run = (bin, args, input = '') => execFileSync(bin, args, { cwd: temporary, env,
  encoding: 'utf8', input, timeout: 60000, maxBuffer: 4 * 1024 * 1024 });
const tag = (tag, value) => value === undefined ? { tag } : { tag, value };
function encode(v) {
  if (v === null) return tag('Null');
  if (typeof v === 'string') return tag('String', v);
  if (typeof v === 'boolean') return tag('Bool', v);
  if (Array.isArray(v)) return tag('Array', v.map(encode));
  if (typeof v === 'object') return tag('Object', Object.entries(v).map(([key, value]) => ({ key, value: encode(value) })));
  throw new Error('Fixture value not supported');
}
function decode(v) {
  switch (v.tag) {
    case 'Null': return null;
    case 'String': case 'Bool': return v.value;
    case 'Array': return v.value.map(decode);
    case 'Object': return Object.fromEntries(v.value.map(({ key, value }) => [key, decode(value)]));
    default: throw new Error(`Unexpected fixture value ${v.tag}`);
  }
}
const citation = { producer: 'fixture', connector: 'files', source: 'folder', externalReferences: ['file:///e-1'] };
const plans = [
  { reason: 'Update and retire old evidence', citations: [citation], edits: [
    { tag: 'Todos', edit: { tag: 'Replace', id: 'old', value: 'updated 雪' } },
    { tag: 'Todos', edit: { tag: 'Remove', id: 'remove' } }] },
  { reason: 'Add reviewed facts', citations: [], edits: [
    { tag: 'Todos', edit: { tag: 'Append', id: 'new', value: 'new item' } },
    { tag: 'Flags', edit: { tag: 'Append', id: 'reviewed', value: true } }] }
];
const proposal = { steps: plans };

async function broker(bin, args, scenario) {
  const child = spawn('bash', ['-c', 'set -o pipefail; cat | "$@" | cat', 'kyyn-agentic', bin, ...args],
    { cwd: temporary, env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  let diagnostic = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', s => { diagnostic += s; });
  const completed = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', code => resolve(code));
  });
  const stop = () => { if (child.exitCode === null) { try { process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; } } };
  const timer = setTimeout(stop, 20000);
  const trace = [];
  let result;
  try {
    for await (const { metadata: frame, body } of readFrames(child.stdout)) {
      assert.equal(body.length, 0);
      if (frame.tag === 'Completed') { result = frame.result; child.stdin.end(); continue; }
      assert.equal(frame.tag, 'HostRequest');
      assert.equal(frame.id, String(trace.length + 1));
      assert.equal(frame.capability, 'model');
      assert.equal(frame.method, 'turn');
      const c = frame.arguments;
      trace.push(c);
      let response;
      if (scenario === 'refuse') response = tag('Left', 'provider unavailable');
      else if (scenario === 'malformed') response = tag('Right', {});
      else {
        let action;
        if (trace.length === 1) {
          assert.equal(c.instruction, 'Propose fact edits');
          assert.equal(decode(c.state), 'captured evidence 雪');
          assert.equal(c.output.shape.tag, 'Object');
          assert.equal(c.tools[0].name, 'review');
          action = tag('CallTools', [{ id: 'review-1', name: 'review', input: encode('evidence to review') }]);
        } else if (trace.length === 2) {
          assert.equal(c.instruction, 'Review this evidence');
          assert.equal(decode(c.state), 'evidence to review');
          action = tag('Respond', encode('reviewed'));
        } else if (trace.length === 3) {
          assert.equal(c.history[0].tag, 'Called');
          assert.equal(decode(c.history[0].value.results[0].result.value), 'reviewed');
          assert.deepEqual(decode(c.history[0].value.raw), { turn: '1' });
          action = tag('Respond', encode([{ reason: 'missing edits' }]));
        } else {
          assert.equal(trace.length, 4);
          assert.equal(c.history[1].tag, 'Rejected');
          action = tag('Respond', encode(proposal));
        }
        response = tag('Right', { raw: encode({ turn: String(trace.length) }), action });
      }
      child.stdin.write(encodeFrame({ tag: 'HostResponse', id: scenario === 'wrong-id' ? '999' : frame.id, result: response }));
    }
    const code = await completed;
    if (scenario === 'malformed' || scenario === 'wrong-id') {
      assert.notEqual(code, 0); assert.equal(result, undefined);
    } else {
      assert.equal(code, 0, diagnostic);
      if (scenario === 'refuse') assert.deepEqual(result, tag('Left', 'provider unavailable'));
      else { assert.equal(result.tag, 'Right'); assert.deepEqual(decode(result.value), proposal); }
    }
    return result;
  } finally { clearTimeout(timer); stop(); }
}

try {
  const upstream = path.join(temporary, 'agentic');
  cpSync(path.join(root, 'vendor/agentic/src'), upstream, { recursive: true });
  for (const file of readdirSync(upstream, { recursive: true }).filter(p => p.endsWith('.hs'))) {
    const target = path.join(upstream, file);
    writeFileSync(target, '{-# LANGUAGE NoFieldSelectors, OverloadedRecordDot, DuplicateRecordFields #-}\n' + readFileSync(target, 'utf8'));
  }
  const native = path.join(temporary, 'native');
  const bytecode = path.join(temporary, 'proof.comb');
  run(process.env.KYYN_TEST_GHC || 'ghc-9.10.3', ['-v0', '-XGHC2021', '-XDataKinds',
    '-XDefaultSignatures', '-XDeriveAnyClass', '-XDerivingVia', '-XGADTs', '-XLambdaCase',
    '-XOverloadedStrings', '-XRankNTypes', '-i', `-i${upstream}`, ...includes, '-outputdir', path.join(temporary, 'objects'),
    path.join(fixture, 'Main.hs'), '-o', native]);
  run(path.join(toolchain, 'bin/mhs'), ['-DMIN_VERSION_base(x,y,z)=1', '-a', '-i', ...includes,
    `-i${path.join(toolchain, 'lib')}`, path.join(fixture, 'Main.hs'), `-o${bytecode}`]);
  const programs = [[native, []], [path.join(toolchain, 'bin/mhseval'), ['+RTS', `-r${bytecode}`, '-RTS']]];
  const outputs = [];
  for (const [bin, args] of programs) {
    const pairs = run(bin, [...args, 'pairs']);
    assert.match(pairs, /n1 --> n2/);
    assert.doesNotMatch(pairs, /n0 --> n2/);
    assert.match(pairs, /digraph/);
    assert.match(run(bin, [...args, 'describe']), /tool review/);
    const result = await broker(bin, args, 'normal');
    for (const scenario of ['refuse', 'malformed', 'wrong-id']) await broker(bin, args, scenario);
    const apply = value => JSON.parse(run(bin, [...args, 'apply'], `${JSON.stringify(encode(value))}\n`));
    const output = apply(decode(result.value));
    assert.deepEqual(apply(proposal), output, 'Frozen replay changed the output');
    assert.equal(output.tag, 'Succeeded');
    assert.deepEqual(output.value.after, { todos: [{ id: 'old', value: 'updated 雪' }, { id: 'new', value: 'new item' }], flags: [{ id: 'reviewed', value: true }] });
    assert.equal(output.value.steps.length, 2);
    assert.equal(output.value.steps[0].rationale.explanation, plans[0].reason);
    assert.deepEqual(output.value.steps[0].rationale.evidence, [citation]);
    assert.deepEqual(output.value.steps[0].after, output.value.steps[1].before);
    assert.equal(output.value.steps[1].after.contract, 'fixture-root-v1');
    const one = edit => [{ reason: 'failure case', citations: [], edits: [{ tag: 'Todos', edit }] }];
    const sequential = apply({ steps: [{ reason: 'Ordered edits', citations: [], edits: [
      { tag: 'Todos', edit: { tag: 'Append', id: 'fresh', value: 'first' } },
      { tag: 'Todos', edit: { tag: 'Replace', id: 'fresh', value: 'second' } }
    ] }] });
    assert.equal(sequential.tag, 'Succeeded');
    assert.deepEqual(sequential.value.after.todos.at(-1), { id: 'fresh', value: 'second' });
    const unchanged = apply({ steps: [] });
    assert.equal(unchanged.tag, 'Succeeded');
    assert.deepEqual(unchanged.value.steps, []);
    for (const edit of [{ tag: 'Remove', id: 'missing' }, { tag: 'Replace', id: 'missing', value: 'x' }, { tag: 'Append', id: 'old', value: 'x' }]) {
      assert.equal(apply({ steps: one(edit) }).tag, 'Rejected');
      assert.equal(apply({ steps: [...plans, ...one(edit)] }).tag, 'Rejected', 'Partial proposal succeeded');
    }
    outputs.push(output);
  }
  assert.deepEqual(outputs[0], outputs[1], 'GHC/MicroHs output diverged');
  console.log('Agentic proof passed under GHC and MicroHs: real host turns, nested tool, retry/refusal, typed fact edits and pure replay.');
} finally { rmSync(temporary, { recursive: true, force: true }); }
