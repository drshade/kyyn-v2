import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-authored-api.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-authored-api-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_COUNT: '2', GIT_CONFIG_KEY_0: 'user.name',
  GIT_CONFIG_VALUE_0: 'API test', GIT_CONFIG_KEY_1: 'user.email', GIT_CONFIG_VALUE_1: 'test@example.invalid' };
function cli(args, expected = 0, json = true) {
  const result = spawnSync(executable, ['--kb', kb, ...(json ? ['--json'] : []), ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return json ? JSON.parse(result.stdout) : result.stdout;
}
function git(...args) {
  const result = spawnSync('git', ['-C', kb, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}
try {
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'helpers']).result;
  const source = path.join(draft.path, 'target/src');
  fs.mkdirSync(path.join(source, 'Helpers'));
  const helpers = `module Helpers (Greeting(..), greet) where
-- | A greeting for a person.
data Greeting = Greeting { message :: String }
-- | Build a friendly greeting without running any host capability.
greet :: String -> Greeting
greet name = Greeting (privatePrefix ++ name)
privatePrefix :: String
privatePrefix = "Hello "
`;
  fs.writeFileSync(path.join(source, 'Helpers.hs'), helpers);
  fs.writeFileSync(path.join(source, 'Helpers/Nested.hs'), `module Helpers.Nested where
import Helpers
-- | Greet twice.
twice :: String -> [Greeting]
twice name = [greet name, greet name]
`);
  fs.writeFileSync(path.join(source, 'Broken.hs'), 'module Broken where\nbad :: Bool\nbad = "not a boolean"\n');
  const selection = ['--evolution', draft.id];
  const listing = cli(['guest', 'module', 'list', ...selection]).result;
  for (const name of ['Helpers', 'Helpers.Nested', 'Broken', 'RootV1', 'Validate']) {
    assert(listing.modules.includes(name), name);
    assert.equal(listing.origins[name], 'kb');
  }
  assert.equal(listing.origins['Kyyn.Evolution'], 'sdk');
  assert.equal(listing.origins['Kyyn.Connectors'], 'generated');
  assert.equal(listing.origins['Kyyn.Workspace.After'], 'generated');
  const shown = cli(['guest', 'module', 'show', 'Helpers', ...selection]).result;
  assert.equal(shown.origin, 'kb');
  assert(shown.symbols.some(s => s.name === 'Greeting' && s.namespace === 'type'));
  assert(!shown.symbols.some(s => s.name === 'privatePrefix'));
  assert.match(shown.symbols.find(s => s.name === 'greet').documentation, /friendly greeting/);
  const symbol = cli(['guest', 'symbol', 'show', 'Helpers.Nested.twice', ...selection]).result;
  assert.equal(symbol.module, 'Helpers.Nested');
  assert.equal(symbol.origin, 'kb');
  assert.match(symbol.symbols[0].checkedSignature, /Greeting/);
  assert.match(cli(['guest', 'module', 'show', 'Helpers', ...selection], 0, false), /-- \[kb\]/);
  assert.equal(cli(['guest', 'symbol', 'show', 'Helpers.privatePrefix', ...selection], 1).diagnostics[0].code, 'guest.symbol-not-found');
  const broken = cli(['guest', 'module', 'show', 'Broken', ...selection], 1);
  assert(broken.diagnostics.some(d => d.code === 'guest.api-compiler-rejected'));
  assert.equal(cli(['guest', 'module', 'show', 'Kyyn.Connectors', ...selection]).result.origin, 'generated');
  assert.equal(cli(['guest', 'module', 'show', 'Kyyn.Evolution']).result.origin, 'sdk');
  fs.unlinkSync(path.join(source, 'Broken.hs'));
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const status = git('status', '--porcelain');
  const accepted = cli(['guest', 'module', 'show', 'Helpers']).result;
  assert.equal(accepted.context.revision, git('rev-parse', 'HEAD').trim());
  assert.equal(accepted.context.evolution, null);
  assert.equal(accepted.origin, 'kb');
  fs.writeFileSync(path.join(kb, 'root/src/Helpers.hs'), 'invalid uncommitted edit');
  assert.deepEqual(cli(['guest', 'module', 'show', 'Helpers']).result, accepted);
  git('restore', 'root/src/Helpers.hs');
  assert.equal(git('status', '--porcelain'), status);
  console.log('Authored API discovery: exported types/signatures/docs, private hiding, origins, selected checking, nested symbols and accepted/draft source passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
