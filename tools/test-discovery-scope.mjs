// Installed selected-module discovery ignores unrelated broken source/manifests;
// generated workspace APIs still require their actual endpoint schemas.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
assert.equal(process.argv.length, 3, 'Usage: node tools/test-discovery-scope.mjs EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-discovery-scope-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Discovery fixture', GIT_COMMITTER_NAME: 'Discovery fixture',
  GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, status = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 600000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
const helper = 'module Helpers (greet) where\nimport Data.Text (Text)\ngreet :: Text -> Text\ngreet = id\n';
function inspect(flags) {
  assert(cli(['guest', 'module', 'show', 'Kyyn.Schema', ...flags]).result.symbols.some(s => s.name === 'Fact'));
  const selected = cli(['guest', 'symbol', 'show', 'Helpers.greet', ...flags]).result.symbols;
  assert.equal(selected.length, 1);
  assert.match(selected[0].signature, /Text.*Text/s);
  assert.equal(cli(['guest', 'module', 'list', ...flags], 1).outcome, 'Refused');
  assert.equal(cli(['guest', 'module', 'show', 'Kyyn.Workspace.Target', ...flags], 1).diagnostics[0].code, 'guest.build');
}
try {
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'unfinished-source']).result;
  const target = path.join(draft.path, 'target');
  const manifest = fs.readFileSync(path.join(target, 'kb.dhall'));
  fs.writeFileSync(path.join(target, 'src/Helpers.hs'), helper);
  fs.writeFileSync(path.join(target, 'src/Unrelated.hs'), 'module unfinished');
  fs.writeFileSync(path.join(target, 'src/RootV1.hs'), 'module RootV1 where\nunfinished =\n');
  fs.writeFileSync(path.join(target, 'kb.dhall'), 'unfinished manifest');
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), 'module Evolution where\nunfinished =\n');
  inspect(['--evolution', draft.id]);
  fs.writeFileSync(path.join(target, 'kb.dhall'), manifest);
  const refused = cli(['guest', 'module', 'show', 'Kyyn.Workspace.Target', '--evolution', draft.id], 1);
  assert.match(JSON.stringify(refused), /RootV1/);
  for (const [name,bytes] of [['src/Helpers.hs', helper], ['src/RootV1.hs', 'module RootV1 where\nunfinished =\n'], ['kb.dhall', 'unfinished manifest']])
    fs.writeFileSync(path.join(kb, 'root', name), bytes);
  for (const args of [['add', 'root'], ['commit', '-qm', 'Unfinished accepted source fixture']]) {
    const result = spawnSync('git', ['-C', kb, ...args], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
  inspect([]);
  console.log('Selected SDK/authored discovery survives broken Root, manifests and evolution bodies; dependent generated APIs refuse.');
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
