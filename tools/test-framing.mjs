// Native guest transport: large UTF-8/raw frames, malformed lengths and partial
// results. Compiled in the pinned contributor environment; no provider calls.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { encodeFrame, readFrames } from './lib/framing.mjs';

const root = path.resolve(import.meta.dirname, '..');
const temporary = mkdtempSync(path.join(tmpdir(), 'kyyn-framing-'));
const run = (bin, args, input) => execFileSync(bin, args, { cwd: root, input, timeout: 60000, maxBuffer: 16 * 1024 * 1024 });
try {
  const main = path.join(root, 'tools/fixtures/framing/Main.hs');
  const native = path.join(temporary, 'guest');
  run('cabal', ['exec', '--', 'ghc', '-v0', '-i', `-i${path.join(root, 'guest/kyyn-runtime/src')}`,
    '-outputdir', temporary, main, '-o', native]);
  for (const [bin,args] of [[native,[]]]) {
    // Node creates socket-backed descriptors; cat supplies the OS pipe used by the native host.
    const invoke = (input, extra = []) => run('bash', ['-c', 'set -o pipefail; cat | "$@" | cat', 'kyyn-framing', bin, ...args, ...extra], input);
    for (const value of [{}, [], '', { nested: ['雪🦋λ\n"\\', true, false] }, { text: '雪🦋λ\n"\\'.repeat(20000) }]) {
      const body = Buffer.from('raw body 🦋\n'.repeat(8000));
      const output = invoke(encodeFrame(value, body));
      const frames = [];
      for await (const frame of readFrames(Readable.from([output]))) frames.push(frame);
      assert.equal(frames.length, 1);
      assert.deepEqual(frames[0].metadata, value);
      assert.deepEqual(frames[0].body, body);
    }
    for (const bad of ['00\n','65537\n','1\nx0\n','2\nx','0\n','+1\nx','1\r\nx']) {
      assert.throws(() => invoke(Buffer.from(bad)));
    }
    let partial;
    try { invoke(Buffer.alloc(0), ['fail']); assert.fail('Invalid result was encoded'); }
    catch (error) { assert.notEqual(error.status, 0); partial = error.stdout; }
    assert.equal(partial.length, 0, 'Invalid profile emitted bytes before validation');
    const rawFrame = source => Buffer.concat([Buffer.from(Buffer.byteLength(source) + '\n'), Buffer.from(source), Buffer.from('0\n0\n')]);
    for (const source of ['{"a":true,"a":false}', '{"a":{"x":true,"x":false}}',
      '{"a":true,"\\u0061":false}', '"\\ud800"', '"\\udc00"', 'null', '[true,1]', '{} garbage']) {
      assert.throws(() => invoke(rawFrame(source)));
    }
    const escaped = [];
    for await (const frame of readFrames(Readable.from([invoke(rawFrame('"\\ud83d\\ude00"'))]))) escaped.push(frame);
    assert.equal(escaped[0].metadata, '😀');
    console.log(`Framing roundtrips and malformed-input refusal passed: ${bin}`);
  }
} finally { rmSync(temporary, { recursive: true, force: true }); }
