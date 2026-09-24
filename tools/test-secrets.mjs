import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, chmodSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';

const executable = process.argv[2];
assert(executable, 'Usage: node tools/test-secrets.mjs INSTALLED_EXECUTABLE');
const scratch = mkdtempSync(path.join(tmpdir(), 'kyyn-secrets-cli-'));
const cli = path.join(scratch, 'kyyn-v2');
const kb = path.join(scratch, 'kb');
const other = path.join(scratch, 'other');
const fixture = 'jev-fixture-private-value';
copyFileSync(executable, cli);
chmodSync(cli, 0o755);
mkdirSync(kb);
mkdirSync(other);

function invoke(args, options = {}, status = 0) {
  const { selectedKb = kb, ...processOptions } = options;
  const result = spawnSync(cli, ['--kb', selectedKb, '--json', ...args], { encoding: 'utf8', ...processOptions });
  assert.equal(result.status, status, result.stderr);
  assert(!`${result.stdout}${result.stderr}`.includes(fixture), 'Complete secret appeared in output');
  return JSON.parse(result.stdout);
}
function stored(name) { return readFileSync(path.join(kb, '.kyyn/secrets', `${name}.dhall`), 'utf8'); }
function shellQuote(value) { return `'${value.replaceAll("'", "'\\''")}'`; }

try {
  assert.deepEqual(invoke(['secret', 'list']).result.names, []);
  assert(!existsSync(path.join(kb, '.kyyn')), 'Read created local store');
  const command = `${shellQuote(cli)} --kb ${shellQuote(kb)} secret set JEV_TOKEN "$JEV_TOKEN"`;
  const set = spawnSync('sh', ['-c', command], { encoding: 'utf8', env: { ...process.env, JEV_TOKEN: fixture } });
  assert.equal(set.status, 0, set.stderr);
  assert(!`${set.stdout}${set.stderr}`.includes(fixture));
  assert.equal(stored('JEV_TOKEN'), `"${fixture}"\n`);
  assert.equal(invoke(['secret', 'show', 'JEV_TOKEN']).result.masked, 'jev-' + '*'.repeat(fixture.length - 4));
  assert.deepEqual(invoke(['secret', 'list']).result.names, ['JEV_TOKEN']);
  assert.equal(invoke(['secret', 'show', 'JEV_TOKEN'], { selectedKb: other }, 1).diagnostics[0].code, 'secret.not-found');
  invoke(['secret', 'set', 'JEV_TOKEN', ''], {}, 1);
  invoke(['secret', 'set', 'JEV_TOKEN'], { input: '\n' }, 1);
  invoke(['secret', 'set', 'JEV_TOKEN'], { input: Buffer.from([255]) }, 1);
  assert.equal(stored('JEV_TOKEN'), `"${fixture}"\n`, 'Refused input replaced prior value');
  invoke(['secret', 'set', 'SHORT', 'eight888']);
  assert.equal(invoke(['secret', 'show', 'SHORT']).result.masked, '********');
  invoke(['secret', 'set', 'UNICODE'], { input: '雪éabcdefghi\r\n' });
  assert.equal(invoke(['secret', 'show', 'UNICODE']).result.masked, '雪éab*******');
  invoke(['secret', 'set', 'LINES'], { input: 'first\nsecond\n\n' });
  assert(stored('LINES').includes('second'), 'Multiline value was lost');
  invoke(['secret', 'set', 'ARG_NEWLINE', 'verbatim\n']);
  assert.equal(invoke(['secret', 'show', 'ARG_NEWLINE']).result.masked.length, 9);
  const git = (...args) => spawnSync('git', ['-C', kb, ...args], { encoding: 'utf8' });
  assert.equal(git('init', '-q').status, 0);
  assert.equal(git('check-ignore', '.kyyn/secrets/JEV_TOKEN.dhall').status, 0);
  assert.equal(git('status', '--porcelain', '--untracked-files=all').stdout, '');
  writeFileSync(path.join(kb, '.kyyn/secrets/JEV_TOKEN.dhall'), `"${fixture}" : Natural`);
  const invalid = invoke(['secret', 'show', 'JEV_TOKEN'], {}, 3);
  assert.equal(invalid.outcome, 'Failed');
  assert(invalid.diagnostics.length > 0);
  invoke(['secret', 'set', 'JEV_TOKEN', fixture]);
  assert.equal(invoke(['secret', 'remove', 'JEV_TOKEN']).result.removed, true);
  assert.equal(invoke(['secret', 'remove', 'JEV_TOKEN']).result.removed, false);
  assert.equal(invoke(['secret', 'show', 'JEV_TOKEN'], {}, 1).diagnostics[0].code, 'secret.not-found');

  // Linux's script supplies a real terminal; send input only after echo is disabled.
  if (process.argv.includes('--terminal')) {
    await new Promise((resolve, reject) => {
      const child = spawn('script', ['-q', '-e', '-c', `${shellQuote(cli)} --kb ${shellQuote(kb)} secret set TERMINAL`, '/dev/null']);
      let output = '', sent = false;
      const timer = setTimeout(() => { child.kill(); reject(new Error('Terminal input timed out')); }, 10000);
      child.on('error', reject);
      child.stdout.on('data', bytes => {
        output += bytes;
        if (!sent && output.includes('Secret value: ')) { sent = true; child.stdin.write(fixture + '\n'); }
      });
      child.stderr.on('data', bytes => { output += bytes; });
      child.on('exit', code => {
        clearTimeout(timer);
        try { assert.equal(code, 0, output); assert(!output.includes(fixture), 'Terminal echoed value'); resolve(); }
        catch (error) { reject(error); }
      });
    });
    assert.equal(stored('TERMINAL'), `"${fixture}"\n`);
  }
  console.log('Installed secrets journey passed (no runtime bundle or valid KB schema).');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
