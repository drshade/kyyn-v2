// Installed discovery through the KB's locked guest: SDK exports, compiler-owned
// signatures, authored docs, hidden values and human rendering. No host catalogue.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-api-discovery-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'API fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'API fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, expected = 0, json = true) {
  const result = spawnSync(executable, ['--kb', kb, ...(json ? ['--json'] : []), ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return json ? JSON.parse(result.stdout) : result.stdout;
}
try {
  assert.equal(cli(['guest', 'module', 'list'], 1).outcome, 'Refused');
  cli(['kb', 'init']);
  const list = cli(['guest', 'module', 'list']).result;
  for (const name of ['Kyyn.Edit', 'Kyyn.Schema', 'Kyyn.Evolution', 'Kyyn.Recipe', 'Agentic.Contract']) {
    assert(list.modules.includes(name), name);
    assert.equal(list.origins[name], 'sdk');
  }
  const edit = cli(['guest', 'module', 'show', 'Kyyn.Edit']).result;
  assert.equal(edit.origin, 'sdk');
  assert(edit.symbols.some(s => s.name === 'Collection' && s.kind === 'type'));
  assert(!edit.symbols.some(s => s.name === 'Collection' && s.kind === 'constructor'));
  const update = cli(['guest', 'symbol', 'show', 'Kyyn.Evolution.update']).result.symbols;
  assert.equal(update.length, 1);
  assert.match(update[0].origin, /Kyyn\.Edit\.update$/);
  assert.match(update[0].signature, /FactId.*Edit.*CollectionEdit/s);
  const human = cli(['guest', 'symbol', 'show', 'Kyyn.Evolution.update'], 0, false);
  assert(human.includes(update[0].signature));
  assert(human.includes(`[Defined as ${update[0].origin}]`));
  const draft = cli(['evolution', 'new', 'documented api']).result;
  fs.writeFileSync(path.join(draft.path, 'target/src/Example.hs'), `module Example (greet) where
import Data.Text (Text)
-- | Return a friendly greeting: café.
greet :: Text -> Text
greet = id
private :: Bool
private = True
`);
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), 'module Evolution where\nunfinished =\n');
  const authored = cli(['guest', 'module', 'show', 'Example', '--evolution', draft.id]).result;
  assert.equal(authored.origin, 'kb');
  assert.deepEqual(authored.symbols.map(s => s.name), ['greet']);
  assert.match(authored.symbols[0].documentation.value, /friendly greeting: café/);
  assert.match(authored.symbols[0].signature, /Text.*Text/s);
  assert.equal(cli(['guest', 'module', 'show', 'Missing'], 1).outcome, 'Refused');
  assert.equal(cli(['guest', 'symbol', 'show', 'Kyyn.Edit.missing'], 1).outcome, 'Refused');
  assert.notEqual(cli(['--nix', path.join(temporary, 'missing-nix'), 'guest', 'module', 'list'], 1).outcome, 'Succeeded');
  console.log('Locked guest SDK discovery, signatures, authored documentation and refusals passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
