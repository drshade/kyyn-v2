// Discover installed guides/list/show without runtime, valid schema or compilable
// plugin code. Checks accepted Git versus draft, Unicode and path/guide refusals.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-plugin-guides.mjs EXECUTABLE');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-plugin-guides-'));
const executable = path.join(temporary, 'kyyn-v2');
const repo = path.join(temporary, 'repo');
const kb = path.join(repo, 'nested', 'kb');
const source = path.join(temporary, 'source');
const id = '000001-install';
const workspace = path.join(kb, 'evolutions', id);
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
function write(file, bytes) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); }
function git(directory, ...args) {
  const result = spawnSync('git', ['-C', directory, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function commit(directory) {
  git(directory, 'add', '.');
  git(directory, '-c', 'user.name=Fixture', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture');
  return git(directory, 'rev-parse', 'HEAD');
}
function cli(args, status = 0, human = false) {
  const result = spawnSync(executable, ['--kb', kb, '--runtime', path.join(temporary, 'missing-runtime'),
    ...(human ? [] : ['--json']), 'plugin', ...args], { env, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, status, JSON.stringify(result));
  return human ? result.stdout : JSON.parse(result.stdout);
}
const draft = ['--evolution', id];
try {
  fs.copyFileSync(process.argv[2], executable);
  fs.chmodSync(executable, 0o755);
  write(path.join(kb, 'root/kb.dhall'), 'Invalid schema: documentation must not interpret this');
  git(repo, 'init', '-q', '-b', 'main');
  const initial = commit(repo);
  write(path.join(workspace, 'manifest.dhall'), `{ before.revision = "${initial}", name = "install", explanation = "", state = < Draft | Ready | Accepted >.Draft }`);
  write(path.join(workspace, 'target/kb.dhall'), 'Invalid target');
  assert.deepEqual(cli(['list', ...draft]).result.plugins, []);
  for (const args of [['list'], ['show', 'example'], ['guide', 'example']]) {
    assert.equal(cli([...args, '--evolution', '000002-unknown'], 1).diagnostics[0].code, 'evolution.unknown');
  }
  write(path.join(source, 'kyyn-plugin.dhall'), '{ name = "example", entryModule = "Example.Plugin" }');
  write(path.join(source, 'src/Example/Plugin.hs'), 'This is not valid Haskell');
  const markdown = '# Example λ\n\nSetup, then use it.\n';
  write(path.join(source, 'README.md'), markdown);
  git(source, 'init', '-q', '-b', 'main');
  const origin = commit(source);
  assert.deepEqual(cli(['list']).result.plugins, []);
  const installation = cli(['install', '--from', source, ...draft], 0, true);
  assert(installation.includes(`plugin guide example --evolution ${id}`));
  assert(installation.includes(`plugin connector schema show example --evolution ${id}`));
  assert.deepEqual(cli(['list', ...draft]).result.plugins, ['example']);
  assert.deepEqual(cli(['list']).result.plugins, []);
  const details = cli(['show', 'example', ...draft]).result;
  assert.equal(details.entryModule, 'Example.Plugin');
  assert.equal(details.hasGuide, true);
  assert.equal(details.origin.revision, origin);
  assert.equal(details.evolution, id);
  assert.equal(details.acceptedRevision, null);
  assert(cli(['show', 'example', ...draft], 0, true).includes('plugin guide example'));
  assert.equal(cli(['guide', 'example', ...draft]).result.markdown, markdown);
  assert.equal(cli(['guide', 'example', ...draft], 0, true).trimEnd(), markdown.trimEnd());
  assert.equal(cli(['guide', 'missing', ...draft], 1).diagnostics[0].code, 'plugin.not-installed');

  const packagePath = path.join(workspace, 'target/plugins/packages/example');
  const readme = path.join(packagePath, 'source/README.md');
  fs.unlinkSync(readme);
  assert.equal(cli(['show', 'example', ...draft]).result.hasGuide, false);
  assert.equal(cli(['guide', 'example', ...draft], 1).diagnostics[0].code, 'plugin.guide-missing');
  write(readme, Buffer.from([255]));
  assert.equal(cli(['guide', 'example', ...draft], 1).diagnostics[0].code, 'plugin.guide-invalid');
  fs.unlinkSync(readme);
  fs.symlinkSync(path.join(source, 'README.md'), readme);
  const linked = cli(['guide', 'example', ...draft], 3);
  assert(JSON.stringify(linked).includes('Symlinks are unsupported'));
  fs.unlinkSync(readme);
  write(readme, markdown);

  // Build accepted test material directly; this fixture deliberately cannot pass root validation.
  fs.cpSync(packagePath, path.join(kb, 'root/plugins/packages/example'), { recursive: true });
  const accepted = commit(repo);
  write(path.join(kb, 'root/plugins/packages/example/source/README.md'), 'Uncommitted change');
  assert.deepEqual(cli(['list']).result.plugins, ['example']);
  const guide = cli(['guide', 'example']).result;
  assert.equal(guide.markdown, markdown);
  assert.equal(guide.package.acceptedRevision, accepted);
  assert.equal(guide.package.origin.revision, origin);
  assert.equal(guide.package.evolution, null);
  write(readme, 'Draft guide');
  assert.equal(cli(['guide', 'example', ...draft]).result.markdown, 'Draft guide');
  assert.equal(cli(['guide', 'example']).result.markdown, markdown);
  assert.equal(git(repo, 'rev-parse', 'HEAD'), accepted);
  console.log('Plugin list/show/guide passed: no runtime, broken Haskell/schema, draft versus accepted, origin, Unicode and missing/invalid/symlink guides.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
