import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-cli-selection.mjs EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-cli-selection-'));
const repo = path.join(temporary, 'repo');
const kb = path.join(repo, 'knowledge', 'sales λ');
const other = path.join(repo, 'knowledge', 'training');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
function git(args) {
  const result = spawnSync('git', ['-C', repo, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
}
function cli(args, expected, cwd = repo) {
  const result = spawnSync(executable, args, { cwd, env, encoding: 'utf8', timeout: 15000 });
  assert.equal(result.status, expected, JSON.stringify(result));
  return JSON.parse(result.stdout);
}
try {
  for (const directory of [kb, other]) {
    fs.mkdirSync(path.join(directory, 'root'), { recursive: true });
    fs.writeFileSync(path.join(directory, 'root', 'kb.dhall'), 'metadata browsing must not parse or compile this');
  }
  git(['init', '-q', '-b', 'main']);
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Initial']);
  const unavailableRuntime = ['--runtime', path.join(temporary, 'missing-runtime')];
  for (const directory of [kb, other]) {
    assert.deepEqual(cli(['--kb', directory, ...unavailableRuntime, '--json', 'evolution', 'list'], 0).result, { evolutions: [] });
    assert.deepEqual(cli([...unavailableRuntime, '--json', 'evolution', 'list'], 0, directory).result, { evolutions: [] });
  }
  const linked = path.join(temporary, 'linked-kb');
  fs.symlinkSync(kb, linked);
  assert.equal(cli(['--kb', linked, ...unavailableRuntime, '--json', 'evolution', 'list'], 0).outcome, 'Succeeded');
  for (const [directory, code] of [[repo, 'kb.not-found'], [temporary, 'git.no-working-tree'], [path.join(temporary, 'absent'), 'kb.directory']]) {
    const response = cli(['--kb', directory, '--json', 'evolution', 'list'], 1);
    assert.equal(response.diagnostics[0].code, code);
  }
  const head = spawnSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { env, encoding: 'utf8' }).stdout.trim();
  git(['checkout', '--detach', '-q', head]);
  assert.equal(cli(['--kb', kb, ...unavailableRuntime, '--json', 'evolution', 'recover', 'abc'], 1).diagnostics[0].code, 'git.detached-head');
  const help = spawnSync(executable, ['--help'], { cwd: temporary, env, encoding: 'utf8' });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /--kb PATH/);
  for (const [args, commands] of [
    [[], ['root', 'evolution']],
    [['root'], ['show', 'check']],
    [['evolution'], ['new', 'list', 'accept']],
    [['root', 'unknown'], ['show', 'check']],
  ]) {
    const result = spawnSync(executable, args, { cwd: temporary, env, encoding: 'utf8', timeout: 15000 });
    assert.equal(result.status, 1, JSON.stringify(result));
    assert.match(result.stderr, /Available commands:/);
    for (const command of commands) assert.match(result.stderr, new RegExp(`^  ${command} +`, 'm'));
  }
  console.log('CLI selection passed: nested/multiple KBs, cwd default, symlink, missing runtime, selection diagnostics and detached recovery.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
