import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-plugin-taps.mjs EXECUTABLE');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-taps-'));
const exe = path.join(temp, 'kyyn-v2');
const repo = path.join(temp, 'kb-repo');
const kb = path.join(repo, 'nested');
const upstream = path.join(temp, 'upstream');
const other = path.join(temp, 'other');
const url = pathToFileURL(upstream).href;
const otherUrl = pathToFileURL(other).href;
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
const id = '000001-install';
function write(file, bytes) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); }
function git(directory, ...args) {
  const r = spawnSync('git', ['-C', directory, ...args], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
}
function commit(directory) {
  git(directory, 'add', '.');
  git(directory, '-c', 'user.name=Fixture', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture');
  return git(directory, 'rev-parse', 'HEAD');
}
function cli(args, status = 0, selected = kb) {
  const r = spawnSync(exe, ['--kb', selected, '--runtime', path.join(temp, 'absent'), '--json', ...args], { env, encoding: 'utf8', timeout: 30000 });
  assert.equal(r.status, status, JSON.stringify(r)); return JSON.parse(r.stdout);
}
function packageAt(directory, name, guide) {
  write(path.join(directory, 'kyyn-plugin.dhall'), `{ name = "${name}", entryModule = "Example.Plugin" }`);
  write(path.join(directory, 'src/Example/Plugin.hs'), 'Not valid Haskell');
  if (guide !== null) write(path.join(directory, 'README.md'), guide);
}
function catalogue(description = 'Folder evidence') {
  write(path.join(upstream, 'kyyn-tap.dhall'), `[
    { name = "local", description = "${description}", source = "${url}", path = "plugins/local" },
    { name = "external", description = "Other repository", source = "${otherUrl}", path = "plugin" },
    { name = "wrong", description = "Wrong name", source = "${url}", path = "plugins/local" },
    { name = "unguided", description = "No guide", source = "${url}", path = "plugins/unguided" }
  ]`);
}
try {
  fs.copyFileSync(process.argv[2], exe); fs.chmodSync(exe, 0o755);
  write(path.join(kb, 'root/kb.dhall'), 'Invalid schema: discovery must not read this');
  git(repo, 'init', '-q', '-b', 'main');
  const initial = commit(repo);
  const workspace = path.join(kb, 'evolutions', id);
  write(path.join(workspace, 'manifest.dhall'), `{ before.revision = "${initial}", name = "install", explanation = "", state = < Draft | Ready | Accepted >.Draft }`);
  write(path.join(workspace, 'target/kb.dhall'), 'Unfinished target');
  packageAt(path.join(upstream, 'plugins/local'), 'local', '# Local λ\n');
  packageAt(path.join(upstream, 'plugins/unguided'), 'unguided', null);
  packageAt(path.join(other, 'plugin'), 'external', '# External\n');
  git(other, 'init', '-q', '-b', 'main'); const externalRevision = commit(other);
  catalogue(); git(upstream, 'init', '-q', '-b', 'main'); const first = commit(upstream);

  assert.deepEqual(cli(['tap', 'list']).result.taps, []);
  cli(['tap', 'add', 'local', '--from', url]);
  assert.equal(git(repo, 'rev-parse', 'HEAD'), initial);
  assert.equal(fs.existsSync(path.join(kb, '.kyyn/taps')), false);
  assert.equal(cli(['plugin', 'search'], 1).diagnostics[0].code, 'tap.not-synced');
  assert.equal(cli(['tap', 'add', 'local', '--from', url], 1).diagnostics[0].code, 'tap.exists');
  assert.equal(cli(['tap', 'update', 'missing'], 1).diagnostics[0].code, 'tap.unknown');
  cli(['tap', 'update']);
  assert.equal(git(path.join(kb, '.kyyn/taps/local/repository'), 'rev-parse', '--is-shallow-repository'), 'true');
  assert(git(repo, 'check-ignore', 'nested/.kyyn/taps/local/sync.dhall'));
  let results = cli(['plugin', 'search', 'FOLDER']).result.plugins;
  assert.equal(results.length, 1); assert.equal(results[0].name, 'local/local');
  assert.equal(results[0].catalogueRevision, first);
  fs.renameSync(upstream, upstream + '-offline');
  assert.equal(cli(['plugin', 'guide', 'local/local']).result.markdown, '# Local λ\n');
  assert.equal(cli(['plugin', 'search', 'Folder']).result.plugins.length, 1);
  const unavailable = cli(['tap', 'update', 'local'], 1);
  assert.equal(unavailable.diagnostics[0].code, 'git.fetch-failed');
  assert(unavailable.diagnostics[0].message.includes('Check access to the tap repository'));
  fs.renameSync(upstream + '-offline', upstream);
  const guide = cli(['plugin', 'guide', 'local/external']).result;
  assert.equal(guide.markdown, '# External\n'); assert.equal(guide.package.origin.revision, externalRevision);
  assert.equal(guide.package.acceptedRevision, null);
  assert.equal(cli(['plugin', 'guide', 'local/unguided'], 1).diagnostics[0].code, 'plugin.guide-missing');
  assert.equal(cli(['plugin', 'install', 'local/wrong', '--evolution', id], 1).diagnostics[0].code, 'tap.package-mismatch');
  assert.equal(fs.existsSync(path.join(workspace, 'target/plugins')), false);
  const installed = cli(['plugin', 'install', 'local/local', '--evolution', id]).result;
  assert.equal(installed.origin.revision, first);
  assert.equal(installed.origin.repository.location, url);
  const installedGuide = path.join(workspace, 'target/plugins/packages/local/source/README.md');
  catalogue('Updated description'); write(path.join(upstream, 'plugins/local/README.md'), '# New guide\n'); const second = commit(upstream);
  assert.equal(cli(['plugin', 'search', 'Updated']).result.plugins.length, 0);
  cli(['tap', 'update', 'local']);
  assert.equal(cli(['plugin', 'search', 'Updated']).result.plugins[0].catalogueRevision, second);
  assert.equal(cli(['plugin', 'guide', 'local/local']).result.markdown, '# New guide\n');
  assert.equal(fs.readFileSync(installedGuide, 'utf8'), '# Local λ\n');
  write(path.join(workspace, 'target/plugins/config/local.dhall'), 'Keep connector configuration');
  write(path.join(workspace, 'target/plugins/packages/local/source/obsolete'), 'Old package file');
  const upgraded = cli(['plugin', 'install', 'local/local', '--evolution', id]).result;
  assert.equal(upgraded.origin.revision, second);
  assert.equal(fs.readFileSync(installedGuide, 'utf8'), '# New guide\n');
  assert.equal(fs.existsSync(path.join(workspace, 'target/plugins/packages/local/source/obsolete')), false);
  assert.equal(fs.readFileSync(path.join(workspace, 'target/plugins/config/local.dhall'), 'utf8'), 'Keep connector configuration');
  assert(!fs.readdirSync(workspace).some(name => name.startsWith('.kyyn-replace-')));
  const failedUpgrade = path.join(upstream, 'plugins/local/kyyn-plugin.dhall');
  write(failedUpgrade, 'Invalid manifest'); commit(upstream);
  assert.equal(cli(['plugin', 'install', 'local/local', '--evolution', id], 1).outcome, 'Refused');
  assert.equal(fs.readFileSync(installedGuide, 'utf8'), '# New guide\n');
  write(failedUpgrade, '{ name = "local", entryModule = "Example.Plugin" }'); commit(upstream);
  write(path.join(upstream, 'kyyn-tap.dhall'), 'Invalid catalogue'); commit(upstream);
  assert.equal(cli(['tap', 'update', 'local'], 1).outcome, 'Refused');
  assert.equal(cli(['plugin', 'search', 'Updated']).result.plugins[0].catalogueRevision, second);
  assert.equal(cli(['plugin', 'guide', 'local/local']).result.markdown, '# New guide\n');
  catalogue('Updated description'); commit(upstream);
  fs.rmSync(path.join(kb, '.kyyn/taps/local'), { recursive: true });
  assert.equal(cli(['plugin', 'search'], 1).diagnostics[0].code, 'tap.not-synced');
  cli(['tap', 'update']);
  commit(repo);
  const clone = path.join(temp, 'clone'); git(temp, 'clone', '-q', repo, clone);
  assert.equal(cli(['tap', 'list'], 0, path.join(clone, 'nested')).result.taps[0].source, url);
  assert.equal(cli(['plugin', 'search'], 1, path.join(clone, 'nested')).diagnostics[0].code, 'tap.not-synced');
  cli(['tap', 'update'], 0, path.join(clone, 'nested'));
  cli(['tap', 'remove', 'local']);
  assert.deepEqual(cli(['tap', 'list']).result.taps, []);
  assert.equal(fs.readFileSync(installedGuide, 'utf8'), '# New guide\n');
  assert.equal(cli(['plugin', 'search'], 0, path.join(clone, 'nested')).result.plugins.length, 4);
  write(path.join(kb, 'taps.dhall'), 'Invalid Dhall');
  assert.equal(cli(['tap', 'list'], 1).outcome, 'Refused');
  assert.equal(cli(['plugin', 'guide', 'local', '--evolution', id]).result.markdown, '# New guide\n');
  console.log('Tap journey passed: offline search/guides, external guides, qualified install, name mismatch, refresh, cache reconstruction, cloned KB isolation and declaration independence.');
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
