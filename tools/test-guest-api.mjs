// Copied executable/catalogue-only SDK discovery without KB, Git, source or compiler.
// Checks public exports, docs, human/JSON signatures and missing/malformed refusals.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

const installed = realpathSync(process.argv[2]);
const temporary = mkdtempSync(join(tmpdir(), 'kyyn-api-discovery-'));
try {
  const executable = join(temporary, 'bin', 'kyyn-v2');
  const runtime = join(temporary, 'lib', 'kyyn');
  mkdirSync(dirname(executable), { recursive: true });
  mkdirSync(runtime, { recursive: true });
  copyFileSync(installed, executable);
  chmodSync(executable, 0o755);
  const catalogue = readFileSync(join(dirname(dirname(installed)), 'lib', 'kyyn', 'guest-api.dhall'));
  writeFileSync(join(runtime, 'guest-api.dhall'), catalogue);
  // Deliberately no SDK, compiler, Git, or KB in this executable/catalogue-only bundle.
  const call = (...args) => spawnSync(executable, ['--kb', '/no-kb', '--git', '/no-git', ...args], {
    cwd: temporary, env: { ...process.env, PATH: '/no-executables' }, encoding: 'utf8', timeout: 10000,
  });
  const json = (...args) => {
    const result = call('--json', ...args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, '');
    return JSON.parse(result.stdout).result;
  };
  const listing = json('guest', 'module', 'list');
  const modules = listing.modules;
  assert.deepEqual(modules, ['Agentic', 'Agentic.Contract', 'Agentic.Core', 'Agentic.Describe',
    'Agentic.Interpret', 'Agentic.Questions', 'Agentic.Runtime', 'Agentic.Schema', 'Agentic.Scripted',
    'Agentic.Settings', 'Agentic.Value', 'Agentic.ViaLLM', 'Kyyn.Edit', 'Kyyn.Evolution',
    'Kyyn.Evolution.Proposal', 'Kyyn.Optics', 'Kyyn.Plugin', 'Kyyn.Plugin.Host', 'Kyyn.Plugin.Sink', 'Kyyn.Query',
    'Kyyn.Recipe', 'Kyyn.Schema', 'Kyyn.Validation']);
  assert(modules.every(name => listing.origins[name] === 'sdk'));
  const kyynModules = modules.filter(name => name.startsWith('Kyyn.'));
  assert.ok(modules.includes('Kyyn.Edit'));
  assert.ok(kyynModules.every(name => !name.includes('Internal') && !name.includes('Runtime')));
  for (const name of modules) {
    const rendered = call('guest', 'module', 'show', name);
    assert.equal(rendered.status, 0, rendered.stderr);
    assert.ok(!/inst\$|get\$|_a\d+|[a-z]\$/.test(rendered.stdout), name + ' leaks compiler machinery');
  }
  const edit = json('guest', 'module', 'show', 'Kyyn.Edit');
  assert.equal(edit.origin, 'sdk');
  assert.ok(edit.symbols.some(s => s.name === 'Collection' && s.namespace === 'type'));
  assert.ok(!edit.symbols.some(s => s.name === 'Collection' && s.namespace === 'value'));
  const update = json('guest', 'symbol', 'show', 'Kyyn.Evolution.update').symbols;
  assert.equal(update.length, 1);
  assert.equal(update[0].definedAs, 'Kyyn.Edit.update');
  assert.equal(update[0].declaration, 'update :: FactId -> Edit a r -> CollectionEdit a r');
  assert.equal(update[0].documentation, "Modify one fact's payload by its ID, keeping the ID unchanged.\nFails if the ID is missing or ambiguous.");
  const human = call('guest', 'symbol', 'show', 'Kyyn.Edit.update');
  assert.equal(human.status, 0, human.stderr);
  assert.ok(human.stdout.includes(update[0].declaration));
  assert.ok(human.stdout.includes('Fails if the ID is missing or ambiguous.'));
  assert.ok(human.stdout.includes("-- Modify one fact's payload by its ID, keeping the ID unchanged.\n-- Fails if the ID is missing or ambiguous.\n"));
  assert.ok(human.stdout.includes('-- [Defined as Kyyn.Edit.update]'));
  assert.ok(human.stdout.includes('-- [Defined as Kyyn.Edit.update]\n' + update[0].declaration));
  assert.ok(human.stdout.indexOf('Fails if the ID') < human.stdout.indexOf('-- [Defined as'));
  assert.ok(human.stdout.indexOf('Fails if the ID') < human.stdout.indexOf(update[0].declaration));
  assert.equal(human.stderr, '');
  const fact = json('guest', 'symbol', 'show', 'Kyyn.Schema.Fact');
  assert.deepEqual(fact.symbols.map(s => s.namespace).sort(), ['type', 'value']);
  assert.ok(json('guest', 'symbol', 'show', 'Kyyn.Evolution.>=>').symbols[0].declaration.startsWith('(>=>) ::'));
  const fallback = json('guest', 'symbol', 'show', 'Kyyn.Edit.modify').symbols[0];
  assert.equal(fallback.declaration, 'modify :: Monad m => (s -> s) -> StateT s m ()');
  const modify = call('guest', 'symbol', 'show', 'Kyyn.Edit.modify').stdout;
  assert.ok(modify.includes('\nmodify :: '));
  assert.ok(!modify.includes('-- [compiler signature]'));
  assert.ok(!modify.includes('value modify'));
  const source = call('guest', 'symbol', 'show', 'Kyyn.Evolution.source').stdout;
  assert.ok(source.includes('\nsource :: EvidenceRef -> Text'));
  assert.ok(!source.includes('-- [compiler signature]'));
  assert.ok(source.includes('-- [Defined as Kyyn.Types.Evidence.source]'));
  assert.ok(source.includes('-- [Defined as Kyyn.Types.Evidence.source]\nsource ::'));
  assert.ok(!source.includes('get$'));
  const sourceJson = json('guest', 'symbol', 'show', 'Kyyn.Evolution.source').symbols[0];
  assert.equal(sourceJson.namespace, 'value');
  assert.equal(sourceJson.definedAs, 'Kyyn.Types.Evidence.get$.EvidenceRef.source');
  assert.equal(sourceJson.checkedSignature, 'EvidenceRef -> Text');
  assert.ok(call('guest', 'symbol', 'show', 'Kyyn.Schema.Fact').stdout.includes('\nFact :: '));
  assert.ok(call('guest', 'symbol', 'show', 'Kyyn.Schema.Fact').stdout.includes('data Fact a = Fact FactId a'));
  assert.ok(call('guest', 'symbol', 'show', 'Kyyn.Schema.FactId').stdout.includes('newtype FactId = FactId Text'));
  assert.ok(call('guest', 'symbol', 'show', 'Kyyn.Edit.Collection').stdout.includes('data Collection root a'));
  const metadata = json('guest', 'module', 'show', 'Kyyn.Schema');
  assert.ok(metadata.symbols.every(s => !s.name.includes('inst$') && !s.name.includes('@')));
  assert.deepEqual(metadata.symbols.filter(s => s.namespace === 'type').map(s => s.name).sort(),
    ['Affordance', 'CollectionDecl', 'Fact', 'FactId', 'FieldRole', 'RoleDecl', 'SchemaMetadata']);
  const query = json('guest', 'module', 'show', 'Kyyn.Query');
  assert.ok(!query.symbols.some(s => s.name === 'CollectionBinding' && s.namespace === 'value'));
  const forbidden = ['Pure', 'Request', 'EvidenceRead', 'FileRead', 'request', 'interpretProgram', 'SnapshotRead', 'ReadAccess', 'runLocally',
    'CheckResult', 'checkReport', 'EvolutionOutput', 'evaluateEvolution'];
  for (const name of kyynModules) assert.ok(json('guest', 'module', 'show', name).symbols.every(s => !forbidden.includes(s.name)));
  assert.equal(call('guest', 'module', 'show', 'Kyyn.Types.Fact').status, 1);
  for (const args of [['module', 'show', 'Kyyn.Missing'], ['symbol', 'show', 'Kyyn.Edit.missing']]) {
    const response = call('--json', 'guest', ...args);
    assert.equal(response.status, 1);
    assert.equal(JSON.parse(response.stdout).outcome, 'Refused');
  }
  const override = call('--runtime', runtime, 'guest', 'module', 'list');
  assert.equal(override.status, 0, override.stderr);
  writeFileSync(join(runtime, 'guest-api.dhall'), 'malformed catalogue');
  assert.equal(call('guest', 'module', 'list').status, 1);
  rmSync(join(runtime, 'guest-api.dhall'));
  const missing = call('guest', 'module', 'list');
  assert.equal(missing.status, 1);
  assert.ok(missing.stderr.includes('reinstall Kyyn'));
  console.log('Installed guest discovery passed without a KB, Git, SDK sources or compiler.');
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
