// Installed unit contracts: tool input/output, identified unit facts, acceptance
// and Dhall persistence. Uses a disposable KB; no provider calls or recipe runs.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-unit-contract.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-unit-contract-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Unit fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Unit fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
try {
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'unit values']).result;
  const target = path.join(draft.path, 'target');
  fs.writeFileSync(path.join(target, 'src/RootV2.hs'), `module RootV2 where
import Kyyn.Schema
data Root = Root { markers :: [Fact ()] }
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "markers" "markers" []]
`);
  fs.writeFileSync(path.join(target, 'src/Tools.hs'), `module Tools where
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)
type Unit = ()
echo :: Unit -> Tool (Either FetchError Unit)
echo = pure . Right
`);
  for (const name of ['kb.dhall', 'src/Validate.hs']) {
    const file = path.join(target, name);
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll('RootV1', 'RootV2'));
  }
  const manifest = path.join(target, 'kb.dhall');
  const empty = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  const original = fs.readFileSync(manifest, 'utf8');
  assert(original.includes(empty));
  fs.writeFileSync(manifest, original.replace(empty,
    '[{ name = "echo", description = "Echo unit", implementation = "Tools.echo", inputType = "Tools.Unit", resultType = "Tools.Unit" }]'));
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Store a unit marker" [])
  (onFacts (\\Before.Root -> Right (After.Root [Fact (FactId "ready") ()])))
`);
  const shown = cli(['root', 'tool', 'show', 'echo', '--evolution', draft.id]).result;
  assert.equal(shown.inputType.trim(), '{}');
  assert.equal(shown.resultType.trim(), '{}');
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  cli(['root', 'check']);
  assert.deepEqual(cli(['root', 'fact', 'show', 'markers', 'ready']).result.value, {});
  assert.match(fs.readFileSync(path.join(kb, 'root/facts/markers/ready.dhall'), 'utf8'), /\{=\}/);
  cli(['root', 'tool', 'execute', 'echo', '--input', '{=}']);
  for (const input of ['True', '{ extra = True }', '[] : List Bool']) {
    assert(cli(['root', 'tool', 'execute', 'echo', '--input', input], 1).diagnostics.length > 0);
  }
  console.log('Unit contracts: discovery, tool codecs, fact acceptance, Dhall persistence and invalid-input refusal passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
