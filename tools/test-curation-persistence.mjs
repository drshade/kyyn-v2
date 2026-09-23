import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-curation-persistence.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-curation-persistence-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Curation fixture', GIT_AUTHOR_EMAIL: 'curation@example.invalid',
  GIT_COMMITTER_NAME: 'Curation fixture', GIT_COMMITTER_EMAIL: 'curation@example.invalid' };
function invoke(command, args, status = 0) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (...args) => invoke(executable, ['--kb', kb, '--json', ...args]);
try {
  cli('kb', 'init');
  const manifest = path.join(kb, 'root/kb.dhall');
  fs.writeFileSync(manifest, `(${fs.readFileSync(manifest, 'utf8')}) // { recipes = [{ name = "syncTodos", instructions = "Inspect current evidence" }] }`);
  const register = path.join(kb, 'root/curation.dhall');
  fs.writeFileSync(register, `[{ recipe = "syncTodos", plugin = "files", instance = "documents", producer = "source", contract = "${'0'.repeat(64)}", acknowledged = [{ id = "milk", fingerprint = "v1" }] }]`);
  invoke('git', ['-C', kb, 'add', 'root']);
  invoke('git', ['-C', kb, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Seed acknowledged state']);
  cli('root', 'check');
  const first = JSON.parse(cli('evolution', 'new', 'preserve-curation')).result.id;
  const targetRegister = path.join(kb, 'evolutions', first, 'target/curation.dhall');
  assert.equal(fs.existsSync(targetRegister), false);
  fs.copyFileSync(register, targetRegister);
  invoke(executable, ['--kb', kb, 'evolution', 'check', first], 1);
  fs.unlinkSync(targetRegister);
  cli('evolution', 'check', first);
  cli('evolution', 'ready', first);
  cli('evolution', 'accept', first);
  const accepted = fs.readFileSync(register, 'utf8');
  assert.match(accepted, /syncTodos/);
  assert.match(accepted, /milk/);
  assert.match(accepted, /v1/);
  cli('root', 'check');
  const second = JSON.parse(cli('evolution', 'new', 'preserve-again')).result.id;
  assert.equal(fs.existsSync(path.join(kb, 'evolutions', second, 'target/curation.dhall')), false);
  cli('evolution', 'check', second);
  cli('evolution', 'ready', second);
  cli('evolution', 'accept', second);
  assert.equal(fs.readFileSync(register, 'utf8'), accepted);
  console.log('Installed curation persistence: init, recipe check, target refusal, two acceptances and canonical register preservation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
