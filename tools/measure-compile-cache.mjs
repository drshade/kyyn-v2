// Measure first/repeated native guest invocations and immutable output reuse.
// This does not clear the shared Nix store or claim a cold compiler benchmark.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const timings = process.argv[3] === '--timings';
assert(process.argv.length === 3 || (process.argv.length === 4 && timings),
  'Usage: node tools/measure-compile-cache.mjs EXECUTABLE [--timings]');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-native-reuse-'));
const kb = path.join(temporary, 'kb');
const cache = path.join(kb, '.kyyn/compiled');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Reuse fixture', GIT_COMMITTER_NAME: 'Reuse fixture',
  GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
delete env.KYYN_TIMINGS;
if (timings) env.KYYN_TIMINGS = '1';
function cli(args) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 600000 });
  assert.equal(result.status, 0, JSON.stringify({ args, ...result }));
  assert(!result.stdout.includes('[kyyn timing]'));
  if (timings) process.stderr.write(result.stderr);
  else assert(!result.stderr.includes('[kyyn timing]'));
  return JSON.parse(result.stdout);
}
function retained() {
  return fs.readdirSync(cache).sort().filter(name => fs.lstatSync(path.join(cache, name)).isSymbolicLink())
    .map(name => {
      const output = fs.realpathSync(path.join(cache, name));
      const binary = path.join(output, 'bin/kyyn-guest');
      return [name, output, fs.statSync(binary, { bigint: true }).mtimeNs.toString()];
    });
}
try {
  cli(['kb', 'init']);
  for (const args of [['root', 'check'], ['guest', 'module', 'show', 'Kyyn.Agentic']]) {
    const firstStart = performance.now();
    const first = cli(args);
    const firstMs = performance.now() - firstStart;
    const before = retained();
    assert(before.length > 0);
    const repeatStart = performance.now();
    const repeated = cli(args);
    const repeatMs = performance.now() - repeatStart;
    assert.deepEqual(retained(), before, 'Repeated invocation changed retained guest outputs');
    assert.deepEqual(repeated, first, 'Repeated invocation changed the result');
    console.log(JSON.stringify({ command: args.join(' '), firstMs: Math.round(firstMs),
      repeatMs: Math.round(repeatMs), retainedBuilds: before.length }));
  }
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
