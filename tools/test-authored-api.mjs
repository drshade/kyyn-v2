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
  const helpers = `module Helpers (Greeting(..), Priority(..), greet) where
data Priority = Low | High
-- | A greeting for a person.
data Greeting = Greeting { message :: String }
-- | Build a friendly greeting without running any host capability.
greet :: String -> Greeting
greet name = Greeting (privatePrefix ++ name)
privatePrefix :: String
privatePrefix = "Hello "
`;
  fs.writeFileSync(path.join(source, 'Helpers.hs'), helpers);
  fs.writeFileSync(path.join(source, 'Instances.hs'), `{-# LANGUAGE CPP #-}
module Instances () where
import qualified Helpers as H
data Box a = Box a
instance Eq a => Eq (Box a) where
  Box a == Box b = a == b
#ifdef __MHS__
instance Show H.Greeting where
  show (H.Greeting message) = message
#else
instance Show H.Priority where
  show _ = "wrong compiler branch"
#endif
`);
  fs.writeFileSync(path.join(source, 'ContractUser.hs'), `module ContractUser () where
import Kyyn.Contracts.Helpers.Priority ()
import Instances ()
`);
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
  const instances = cli(['guest', 'module', 'show', 'Instances', ...selection]).result;
  assert.deepEqual(instances.symbols, [], 'instance-only module has no named exports');
  assert.deepEqual(instances.instances, ['instance Eq a => Eq (Box a)', 'instance Show H.Greeting']);
  assert.deepEqual(cli(['guest', 'module', 'show', 'ContractUser', ...selection]).result.instances, [],
    'imported instances are not claimed as local declarations');
  const contracts = cli(['guest', 'module', 'show', 'Kyyn.Contracts.Helpers.Priority', ...selection]).result;
  assert(contracts.instances.some(s => /instance .*Contract .*Priority/.test(s)), JSON.stringify(contracts));
  assert(contracts.instances.some(s => /instance .*Options .*Priority/.test(s)), JSON.stringify(contracts));
  const humanContracts = cli(['guest', 'module', 'show', 'Kyyn.Contracts.Helpers.Priority', ...selection], 0, false);
  assert.match(humanContracts, /-- Explicit instances declared here/);
  assert.match(humanContracts, /instance .*Options .*Priority/);
  fs.writeFileSync(path.join(source, 'BadInstance.hs'), `module BadInstance () where
data Bad = Bad
instance Show Bad where
  show _ = True
`);
  assert(cli(['guest', 'module', 'show', 'BadInstance', ...selection], 1).diagnostics
    .some(d => d.code === 'guest.api-compiler-rejected'));
  fs.unlinkSync(path.join(source, 'BadInstance.hs'));
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
  console.log('Authored API discovery: exports/docs, checked explicit instance headers, generated Options/Contract, private hiding, origins, selected checking and accepted/draft source passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
