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
  const originalRevision = git(source, 'rev-parse', 'HEAD');
  cli(['kb', 'init']);
  const before = git(kb, 'rev-parse', 'HEAD');
  const first = cli(['evolution', 'new', 'add-plugin']).result;
  assert.deepEqual(cli(['evolution', 'check', first.id]).result.report.plugins, []);
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
  const addition = cli(['evolution', 'check', first.id]).result.report.plugins;
  assert.equal(addition[0].name, 'local-file');
  assert.equal(addition[0].before, null);
  assert.equal(addition[0].after.revision, originalRevision);
  cli(['evolution', 'accept', first.id]);
  const accepted = path.join(kb, 'root', packagePath);
  assert.deepEqual(fs.readFileSync(path.join(accepted, 'source/src/LocalFile/Plugin.hs')), expected);
  assert.equal(cli(install(first.id), 1).diagnostics[0].code, 'plugin.evolution-accepted');
  const next = cli(['evolution', 'new', 'next']).result;
  const inherited = path.join(next.path, 'target', packagePath);
  assert.deepEqual(fs.readFileSync(path.join(inherited, 'source/src/LocalFile/Plugin.hs')), expected);
  assert.deepEqual(fs.readFileSync(path.join(inherited, 'origin.dhall')), fs.readFileSync(path.join(accepted, 'origin.dhall')));
  fs.appendFileSync(path.join(source, 'README.md'), '\nUpgrade fixture\n');
  git(source, 'add', '.'); git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Upgrade');
  const updatedRevision = git(source, 'rev-parse', 'HEAD');
  cli(install(next.id));
  const report = cli(['evolution', 'check', next.id]).result.report;
  assert.equal(report.plugins[0].before.revision, originalRevision);
  assert.equal(report.plugins[0].after.revision, updatedRevision);
  assert(report.plugins[0].files.includes('source/README.md'));
  assert.deepEqual(cli(['evolution', 'show', next.id]).result.report, report);
  const human = spawnSync(executable, ['--kb', kb, 'evolution', 'show', next.id], { env, encoding: 'utf8' });
  assert.equal(human.status, 0, human.stderr);
  assert(human.stdout.includes(`Plugin local-file: ${originalRevision.slice(0,8)} → ${updatedRevision.slice(0,8)}`));
  cli(['evolution', 'ready', next.id]);
  cli(['evolution', 'accept', next.id]);
  fs.rmSync(path.join(kb, '.kyyn'), { recursive: true, force: true });
  assert.deepEqual(cli(['evolution', 'show', next.id]).result.report, report);
  assert.deepEqual(fs.readFileSync(path.join(accepted, 'source/src/LocalFile/Plugin.hs')), expected);
  const edit = cli(['evolution', 'new', 'local-edit']).result;
  fs.appendFileSync(path.join(edit.path, 'target', packagePath, 'source/README.md'), '\nLocal edit\n');
  const local = cli(['evolution', 'check', edit.id]).result.report.plugins;
  assert.equal(local[0].before.revision, updatedRevision);
  assert.equal(local[0].after.revision, updatedRevision);
  assert.deepEqual(local[0].files, ['source/README.md']);
  fs.rmSync(path.join(edit.path, 'target', packagePath), { recursive: true });
  const removal = cli(['evolution', 'check', edit.id]).result.report.plugins;
  assert.equal(removal[0].before.revision, updatedRevision);
  assert.equal(removal[0].after, null);
  console.log('Plugin target installation, stale candidate refusal, acceptance and next-evolution inheritance passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
