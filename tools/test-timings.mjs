// Check opt-in KYYN_TIMINGS semantics, unchanged help/JSON/diagnostics and exit
// statuses without guest compilation.

import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-timings.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
function invoke(args, setting) {
  const env = { ...process.env };
  delete env.KYYN_TIMINGS;
  if (setting !== undefined) env.KYYN_TIMINGS = setting;
  return spawnSync(executable, args, { env, encoding: 'utf8', timeout: 30000 });
}
for (const args of [['--help'], ['--unknown-option'], ['--json', 'guest', 'module', 'show', 'Kyyn.Evolution']]) {
  const normal = invoke(args);
  assert(!normal.stderr.includes('[kyyn timing]'));
  for (const setting of ['0', 'true', '1']) {
    const timed = invoke(args, setting);
    assert.equal(timed.status, normal.status);
    assert.equal(timed.stdout, normal.stdout);
    const events = timed.stderr.split('\n').filter(line => line.startsWith('[kyyn timing]'));
    assert.equal(events.length, setting === '1' ? 1 : 0);
    if (setting === '1') assert.match(events[0], /^\[kyyn timing\] total "command" [0-9.]+ms$/);
    assert.equal(timed.stderr.split('\n').filter(line => !line.startsWith('[kyyn timing]')).join('\n'), normal.stderr);
  }
  if (args.includes('--json')) JSON.parse(normal.stdout);
}
console.log('Opt-in timing preserves stdout, JSON, stderr diagnostics and exit status; only literal 1 enables it.');
