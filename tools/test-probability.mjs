// Installed Probability contracts: generated model instance, direct tool payload,
// nested and scalar facts, schema evolution and exact Dhall persistence.
// Refuses out-of-range stored/input values; no live model provider.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-probability.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-probability-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Probability fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Probability fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function invoke(command, args, status = 0) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (args, status = 0) => JSON.parse(invoke(executable, ['--kb', kb, '--json', ...args], status));
try {
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'probabilities']).result;
  const target = path.join(draft.path, 'target');
  fs.writeFileSync(path.join(target, 'src/Results.hs'), `module Results where
import Agentic.Questions (Probability)
data Result = Result { confidence :: Probability, alternatives :: [Probability] }
`);
  fs.writeFileSync(path.join(target, 'src/RootV2.hs'), `module RootV2 where
import Kyyn.Schema
import Agentic.Questions (Probability)
import Results (Result)
data Root = Root { estimates :: [Fact Result], probabilities :: [Fact Probability] }
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "estimates" "estimates" [], CollectionDecl "probabilities" "probabilities" []]
`);
  fs.writeFileSync(path.join(target, 'src/Tools.hs'), `module Tools where
import qualified Agentic as A
import Agentic.Questions (Probability)
import qualified Data.Text as Text
import Kyyn.Agentic (Flow)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)
import Kyyn.Contracts.Results.Result ()
import Results (Result)
type Input = Probability
type Output = Probability
echo :: Input -> Tool (Either FetchError Output)
echo = pure . Right
draft :: Flow Text.Text Result
draft = A.draft (A.Instruction (Text.pack "Estimate confidence"))
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
    '[{ name = "echo", description = "Echo probability", implementation = "Tools.echo", inputType = "Tools.Input", resultType = "Tools.Output" }]'));
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import Results (Result(..))
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Store confidence" []) (onFacts (\\Before.Root -> Right
  (After.Root [Fact (FactId "estimate") (Result 0.85 [0, 1])]
    [Fact (FactId "direct") 0.85])))
`);
  const selection = ['--evolution', draft.id];
  assert.match(cli(['root', 'schema', 'show', 'Results.Result', ...selection]).result.dhallType, /Natural/);
  cli(['root', 'tool', 'show', 'echo', ...selection]);
  assert.match(JSON.stringify(cli(['guest', 'module', 'show', 'Kyyn.Contracts.Results.Result', ...selection])), /codec/);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  cli(['root', 'check']);
  assert.deepEqual(cli(['root', 'fact', 'show', 'estimates', 'estimate']).result.value,
    { confidence: '8500', alternatives: ['0', '10000'] });
  assert.equal(cli(['root', 'fact', 'show', 'probabilities', 'direct']).result.value, '8500');
  for (const n of ['0', '8500', '10000']) {
    const response = cli(['root', 'tool', 'execute', 'echo', '--input', n]);
    assert.match(JSON.stringify(response.result), new RegExp(n));
  }
  for (const n of ['10001', '-1', '0.85']) {
    assert(cli(['root', 'tool', 'execute', 'echo', '--input', n], 1).diagnostics.length > 0);
  }
  const factRelative = 'root/facts/estimates/estimate.dhall';
  const facts = path.join(kb, factRelative);
  const stored = fs.readFileSync(facts, 'utf8');
  assert.match(stored, /8500/);
  assert.doesNotMatch(stored, /0\.85/);
  fs.writeFileSync(facts, stored.replace('8500', '10001'));
  invoke('git', ['-C', kb, 'add', factRelative]);
  invoke('git', ['-C', kb, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Invalid probability fixture']);
  assert(cli(['root', 'check'], 1).diagnostics.length > 0);
  console.log('Probability: generated model/tool contracts, scalar/nested facts, acceptance, basis-point persistence and invalid-range refusals passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
