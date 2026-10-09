// A copied executable exposes the exact embedded authoring guide without a KB,
// source checkout, Git, compiler or runtime bundle. Checks human and JSON output.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-guide.mjs EXECUTABLE');
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const expected = fs.readFileSync(path.join(repository, 'docs/guide.md'), 'utf8');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-guide-'));
try {
  const executable = path.join(temporary, 'kyyn-v2');
  fs.copyFileSync(fs.realpathSync(process.argv[2]), executable);
  fs.chmodSync(executable, 0o755);
  const invoke = (...args) => {
    const result = spawnSync(executable, ['--kb', '/missing-kb', '--runtime', '/missing-runtime',
      '--git', '/missing-git', ...args], { cwd: temporary, encoding: 'utf8',
      env: { ...process.env, PATH: '/no-tools' }, timeout: 10000 });
    assert.equal(result.status, 0, JSON.stringify(result));
    assert.equal(result.stderr, '');
    return result.stdout;
  };
  assert.equal(invoke('guide'), expected.endsWith('\n') ? expected : expected + '\n');
  assert.deepEqual(JSON.parse(invoke('--json', 'guide')),
    { outcome: 'Succeeded', result: { markdown: expected }, diagnostics: [] });
  assert.match(invoke('--help'), /guide\s+Read the bundled authoring guide/);
  console.log('Embedded guide matches source in human/JSON output without KB, Git or runtime assets.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
