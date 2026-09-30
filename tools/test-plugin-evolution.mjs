import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-plugin-evolution.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-plugin-evolution-'));
const kb = path.join(temporary, 'kb');
const source = path.join(temporary, 'source');
const taskHome = path.join(temporary, 'home');
fs.mkdirSync(taskHome);
const env = { ...process.env, HOME: taskHome, XDG_CONFIG_HOME: path.join(temporary, 'xdg'),
  GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(taskHome, '.gitconfig') };
function git(directory, ...args) {
  const result = spawnSync('git', ['-C', directory, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, JSON.stringify(result));
  return result.stdout.trim();
}
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify(result));
  return JSON.parse(result.stdout);
}
try {
  git(temporary, 'config', '--global', 'user.name', 'Plugin fixture');
  git(temporary, 'config', '--global', 'user.email', 'plugin@example.invalid');
  fs.cpSync(path.join(repository, 'plugins/local-file'), source, { recursive: true });
  git(source, 'init', '-q', '-b', 'main');
  git(source, 'add', '.');
  git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Plugin source');
  cli(['kb', 'init']);
  const before = git(kb, 'rev-parse', 'HEAD');
  const first = cli(['evolution', 'new', 'add-plugin']).result;
  cli(['evolution', 'check', first.id]);
  cli(['evolution', 'ready', first.id]);
  const install = id => ['plugin', 'install', '--evolution', id, '--from', source];
  cli(install(first.id));
  const packagePath = 'plugins/packages/local-file';
  const installed = path.join(first.path, 'target', packagePath);
  const expected = fs.readFileSync(path.join(installed, 'source/src/LocalFile/Plugin.hs'));
  assert(!fs.existsSync(path.join(kb, 'root', packagePath)));
  assert.equal(git(kb, 'rev-parse', 'HEAD'), before);
  cli(['evolution', 'accept', first.id], 1);
  assert.equal(git(kb, 'rev-parse', 'HEAD'), before, 'Accepted a candidate checked before plugin installation');
  cli(['evolution', 'check', first.id]);
  cli(['evolution', 'accept', first.id]);
  const accepted = path.join(kb, 'root', packagePath);
  assert.deepEqual(fs.readFileSync(path.join(accepted, 'source/src/LocalFile/Plugin.hs')), expected);
  assert.equal(cli(install(first.id), 1).diagnostics[0].code, 'plugin.evolution-accepted');
  const next = cli(['evolution', 'new', 'next']).result;
  const inherited = path.join(next.path, 'target', packagePath);
  assert.deepEqual(fs.readFileSync(path.join(inherited, 'source/src/LocalFile/Plugin.hs')), expected);
  assert.deepEqual(fs.readFileSync(path.join(inherited, 'origin.dhall')), fs.readFileSync(path.join(accepted, 'origin.dhall')));
  cli(install(next.id));
  cli(['evolution', 'check', next.id]);
  cli(['evolution', 'ready', next.id]);
  cli(['evolution', 'accept', next.id]);
  assert.deepEqual(fs.readFileSync(path.join(accepted, 'source/src/LocalFile/Plugin.hs')), expected);
  console.log('Plugin target installation, stale candidate refusal, acceptance and next-evolution inheritance passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
