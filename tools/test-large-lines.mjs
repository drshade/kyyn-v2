// Real MicroHs line input: discard, preserve contents and repeat reads across GC.
// Synthetic payloads only; default and constrained stacks. No live Graph calls.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const toolchain = process.argv[2] || process.env.KYYN_TEST_TOOLCHAIN;
assert(toolchain, 'Supply the MicroHs toolchain directory');
const root = resolve(import.meta.dirname, '..');
const temporary = mkdtempSync(join(tmpdir(), 'kyyn-large-lines-'));
function run(executable, args, input) {
  const result = spawnSync(executable, args, {
    cwd: temporary, input, encoding: 'utf8', timeout: 120000,
    env: {...process.env, MHSDIR: toolchain, MHSCPPHS: join(toolchain, 'bin/cpphs')},
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${result.signal || ''}\n${result.stderr}`);
  return result.stdout;
}
try {
  run(join(toolchain, 'bin/mhs'), ['-a', '-i', `-i${toolchain}/lib`,
    join(root, 'tools/fixtures/large-line/Main.hs'), '-oprogram.comb']);
  const input = [500000, 368219, 500000, 1000000, 1000000]
    .map(size => 'x'.repeat(size) + '\n').join('');
  for (const limits of [[], ['-H8M', '-K4096']]) {
    assert.equal(run(join(toolchain, 'bin/mhseval'),
      ['+RTS', '-rprogram.comb', ...limits, '-RTS'], input), 'discarded\nchecked\n');
  }
  console.log('Large-line input passed with default and constrained stacks.');
} finally {
  rmSync(temporary, {recursive: true, force: true});
}
