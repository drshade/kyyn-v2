import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { encodeFrame, readFrames } from './lib/framing.mjs';

const root = path.resolve(import.meta.dirname, '..');
const toolchain = process.env.KYYN_TEST_TOOLCHAIN;
if (!toolchain) throw new Error('Set KYYN_TEST_TOOLCHAIN');
const temporary = mkdtempSync(path.join(tmpdir(), 'kyyn-framing-'));
const env = { ...process.env, MHSDIR: toolchain, MHSCPPHS: path.join(toolchain, 'bin/cpphs') };
const includes = ['guest/kyyn-runtime/src', 'vendor/json'].map(p => `-i${path.join(root, p)}`);
const run = (bin, args, input) => execFileSync(bin, args, { cwd: temporary, env, input, timeout: 60000, maxBuffer: 16 * 1024 * 1024 });
try {
  const main = path.join(root, 'tools/fixtures/framing/Main.hs');
  const native = path.join(temporary, 'guest'), bytecode = path.join(temporary, 'guest.comb');
  run(process.env.KYYN_TEST_GHC || 'ghc-9.10.3', ['-v0', '-i', ...includes, '-outputdir', temporary, main, '-o', native]);
  run(path.join(toolchain, 'bin/mhs'), ['-a', '-i', ...includes, `-i${path.join(toolchain, 'lib')}`, main, `-o${bytecode}`]);
  for (const [bin,args] of [[native,[]],[path.join(toolchain,'bin/mhseval'),['+RTS',`-r${bytecode}`,'-RTS']]]) {
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
    assert(partial.length > 8192, 'Fixture failed before emitting a chunk');
    let dispatched = 0;
    await assert.rejects(async () => {
      for await (const frame of readFrames(Readable.from([partial]))) { void frame; dispatched++; }
    }, /Incomplete frame/);
    assert.equal(dispatched, 0, 'Partial result became dispatchable');
    console.log(`Framing roundtrips and malformed-input refusal passed: ${bin}`);
  }
} finally { rmSync(temporary, { recursive: true, force: true }); }
