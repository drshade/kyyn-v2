// Installed source vendoring from committed local/file-URL repositories without a
// runtime. Checks nested KBs, exclusions, origins, independent copies and refusals.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-plugin-install.mjs EXECUTABLE');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-plugin-cli-'));
const executable = path.join(temporary, 'kyyn-v2');
const repo = path.join(temporary, 'knowledge');
const kb = path.join(repo, 'nested', 'kb λ');
const source = path.join(temporary, 'source:repo');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
const evolution = '000001-install';
const workspace = path.join(kb, 'evolutions', evolution);
const installed = path.join(workspace, 'target/plugins/packages');
function git(directory, args) {
  const result = spawnSync('git', ['-C', directory, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function commit(directory) {
  git(directory, ['add', '.']);
  git(directory, ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture']);
  return git(directory, ['rev-parse', 'HEAD']);
}
function write(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}
function packageAt(directory, name) {
  write(path.join(directory, 'kyyn-plugin.dhall'), `{ name = "${name}", entryModule = "Example.Plugin" }`);
  write(path.join(directory, 'src/Example/Plugin.hs'), 'module Example.Plugin where\ndescription = "fixture"\n');
}
function invoke(args, status = 0, { cwd = temporary, json = true, selected = evolution } = {}) {
  const result = spawnSync(executable,
    ['--kb', kb, '--runtime', path.join(temporary, 'no-runtime'), ...(json ? ['--json'] : []), 'plugin', 'install',
      ...(selected === null ? [] : ['--evolution', selected]), ...args],
    { cwd, env, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, status, JSON.stringify(result));
  return json ? JSON.parse(result.stdout) : result.stdout;
}
function snapshot(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory).sort().flatMap(name => {
    const file = path.join(directory, name);
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) return [[name, 'link', fs.readlinkSync(file)]];
    if (stat.isDirectory()) return [[name, 'directory'], ...snapshot(file).map(entry => [name + '/' + entry[0], ...entry.slice(1)])];
    return [[name, 'file', fs.readFileSync(file).toString('base64')]];
  });
}
function refuse(args, code) {
  const before = snapshot(repo);
  const response = invoke(args, 1);
  assert.equal(response.diagnostics[0].code, code, JSON.stringify(response));
  assert.deepEqual(snapshot(repo), before, `Refusal ${code} wrote to the KB`);
}
try {
  fs.copyFileSync(path.resolve(process.argv[2]), executable);
  fs.chmodSync(executable, 0o755);
  write(path.join(kb, 'root/kb.dhall'), 'Plugin installation must not parse the root schema or load the SDK');
  write(path.join(repo, 'unrelated'), 'preserve');
  git(repo, ['init', '-q', '-b', 'main']);
  const beforeHead = commit(repo);
  write(path.join(workspace, 'manifest.dhall'), `{ before.revision = "${beforeHead}", name = "install", explanation = "", state = < Draft | Ready | Accepted >.Draft, kind = < AdHoc | RecipeBased : Text >.AdHoc }`);
  write(path.join(workspace, 'target/kb.dhall'), 'An unfinished target must not require compilation to install plugins');
  const acceptedRoot = snapshot(path.join(kb, 'root'));
  invoke(['--from', source], 2, { json: false, selected: null });
  const missing = invoke(['--from', source], 1, { selected: '000002-missing' });
  assert.equal(missing.diagnostics[0].code, 'evolution.unknown');
  fs.mkdirSync(source);
  git(source, ['init', '-q', '-b', 'main']);
  fs.cpSync(path.join(root, 'plugins/local-file'), path.join(source, 'plugins/local-file'), { recursive: true });
  for (const name of ['remote', 'human', 'empty', 'linked', 'invalid', 'entry', 'unsupported']) packageAt(path.join(source, 'plugins', name), name);
  write(path.join(source, 'plugins/invalid/kyyn-plugin.dhall'), './outside.dhall');
  fs.unlinkSync(path.join(source, 'plugins/entry/src/Example/Plugin.hs'));
  write(path.join(source, 'plugins/missing/README.md'), 'no manifest');
  fs.symlinkSync('/missing', path.join(source, 'plugins/unsupported/link'));
  write(path.join(source, 'plugins/local-file/dist-newstyle/cache'), 'excluded tracked build product');
  write(path.join(source, 'plugins/local-file/dist-newstyle-extra'), 'keep sibling');
  write(path.join(source, '.gitignore'), 'scratch/\n');
  const sourceHead = commit(source);
  write(path.join(source, 'plugins/local-file/scratch/ignored'), 'ignored untracked file');
  const local = invoke(['--from', './source:repo/plugins', '--path', 'local-file']);
  assert.equal(local.result.name, 'local-file');
  assert.equal(local.result.location, path.join(installed, 'local-file'));
  assert.deepEqual(local.result.origin, { repository: { kind: 'Local', location: source }, path: 'plugins/local-file', revision: sourceHead });
  assert.equal(fs.readFileSync(path.join(installed, 'local-file/source/src/LocalFile/Plugin.hs'), 'utf8'),
    fs.readFileSync(path.join(root, 'plugins/local-file/src/LocalFile/Plugin.hs'), 'utf8'));
  assert.ok(fs.readFileSync(path.join(installed, 'local-file/origin.dhall'), 'utf8').includes(sourceHead));
  for (const excluded of ['dist-newstyle', 'scratch', '.git']) assert.ok(!fs.existsSync(path.join(installed, 'local-file/source', excluded)));
  assert.equal(fs.readFileSync(path.join(installed, 'local-file/source/dist-newstyle-extra'), 'utf8'), 'keep sibling');
  const remoteUrl = pathToFileURL(source).href;
  const remote = invoke(['--from', remoteUrl, '--path', 'plugins/remote']);
  assert.deepEqual(remote.result.origin, { repository: { kind: 'Git', location: remoteUrl }, path: 'plugins/remote', revision: sourceHead });
  const human = invoke(['--from', source, '--path', 'plugins/human'], 0, { json: false });
  for (const text of ['Installed plugin human', path.join(installed, 'human'), source, sourceHead]) assert.ok(human.includes(text), human);
  const installedBefore = snapshot(repo);
  invoke(['--from', source, '--path', 'plugins/local-file']);
  assert.deepEqual(snapshot(repo), installedBefore);
  for (const name of ['empty', 'linked']) {
    if (name === 'empty') fs.mkdirSync(path.join(installed, name));
    else fs.symlinkSync('/missing', path.join(installed, name));
    if (name === 'empty') invoke(['--from', source, '--path', `plugins/${name}`]);
    else {
      const unchanged = snapshot(repo);
      assert.equal(invoke(['--from', source, '--path', `plugins/${name}`], 3).diagnostics[0].code, 'storage.unavailable');
      assert.deepEqual(snapshot(repo), unchanged);
    }
  }
  for (const [name, code] of [['missing', 'plugin.manifest-missing'], ['invalid', 'plugin.manifest-invalid'],
    ['entry', 'plugin.entry-missing'], ['unsupported', 'git.unsupported-entry']]) {
    refuse(['--from', source, '--path', `plugins/${name}`], code);
  }
  for (const input of ['git@example.org:team/repo', 'ssh://example.org/repo', 'http://example.org/repo', ''])
    refuse(['--from', input], 'plugin.source-invalid');
  refuse(['--from', path.join(temporary, 'absent')], 'plugin.source-unavailable');
  refuse(['--from', source, '--path', '../escape'], 'plugin.path-invalid');
  refuse(['--from', source, '--path', 'absent'], 'git.missing-subtree');
  refuse(['--from', pathToFileURL(path.join(temporary, 'absent.git')).href], 'git.clone-failed');
  const outside = path.join(temporary, 'outside');
  packageAt(outside, 'outside');
  refuse(['--from', outside], 'git.no-working-tree');
  const installedSource = path.join(installed, 'local-file/source/src/LocalFile/Plugin.hs');
  const copied = fs.readFileSync(installedSource, 'utf8');
  write(path.join(source, 'plugins/local-file/src/LocalFile/Plugin.hs'), 'edited source');
  refuse(['--from', source, '--path', 'plugins/local-file'], 'plugin.source-uncommitted');
  assert.equal(fs.readFileSync(installedSource, 'utf8'), copied);
  assert.equal(git(repo, ['rev-parse', 'HEAD']), beforeHead);
  assert.deepEqual(snapshot(path.join(kb, 'root')), acceptedRoot, 'Installation modified accepted root');
  assert.equal(fs.readFileSync(path.join(repo, 'unrelated'), 'utf8'), 'preserve');
  console.log('Plugin CLI passed: standalone host, local/remote packages, source origins, refusals, copies and unchanged HEAD.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
