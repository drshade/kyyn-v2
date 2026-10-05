// Installed recipe references and description: entry/signature refusal, accepted
// open/closed changes, archive inspection, FactEdits discovery and schema changes.
// Tree/DOT/Mermaid project a flow with a failing action without invoking it;
// type-invalid validators/corrupt facts do not block description. No live provider.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-closed-recipes.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-closed-recipes-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Recipe fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Recipe fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, status = 0, json = true) {
  const result = spawnSync(executable, ['--kb', kb, ...(json ? ['--json'] : []), ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  return json ? JSON.parse(result.stdout) : result.stdout;
}
const accept = id => { cli(['evolution', 'ready', id]); cli(['evolution', 'accept', id]); };
try {
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'teach-recipe']).result;
  const target = path.join(draft.path, 'target');
  const initialSource = path.join(draft.path, 'change/Evolution.hs');
  fs.writeFileSync(initialSource, fs.readFileSync(initialSource, 'utf8')
    .replace('import Kyyn.Workspace.Evolution', 'import Kyyn.Workspace.Evolution\nimport Kyyn.Schema')
    .replace('evolution = identityEvolution',
      'evolution = edit (Rationale "Needs a collection" []) (within recipes (append (Fact (FactId "sync") (ClosedAgent (FlowEntryRef "Tasks.reconcile")))))'));
  assert.match(JSON.stringify(cli(['evolution', 'check', draft.id], 1)), /at least one domain fact collection/);
  fs.writeFileSync(path.join(target, 'src/RootV2.hs'), `module RootV2 where
import Kyyn.Schema
data Todo = Todo { title :: String }
data Root = Root { todos :: [Fact Todo] }
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
`);
  for (const name of ['kb.dhall', 'src/Validate.hs']) {
    const file = path.join(target, name);
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll('RootV1', 'RootV2'));
  }
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Track tasks" []) (onFacts (\\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Teach curation" []) (within recipes
    (append (Fact (FactId "sync") (OpenAgent "Review tasks"))))
`);
  cli(['evolution', 'check', draft.id]);
  accept(draft.id);
  assert.match(JSON.stringify(cli(['root', 'recipe', 'describe', 'sync'], 1)), /Open-agent recipes have instructions/);
  assert.match(JSON.stringify(cli(['root', 'recipe', 'describe', 'missing'], 1)), /curation.recipe-unknown/);
  const closed = cli(['evolution', 'new', 'close-recipe']).result;
  const source = path.join(closed.path, 'change/Evolution.hs');
  fs.writeFileSync(source, fs.readFileSync(source, 'utf8').replace('import Kyyn.Workspace.Evolution',
    'import Kyyn.Workspace.Evolution\nimport Kyyn.Schema').replace('evolution = identityEvolution',
    'evolution = edit (Rationale "Use the authored flow" []) (within recipes (update (FactId "sync") (put (ClosedAgent (FlowEntryRef "Tasks.reconcile")))))'));
  let rejected = cli(['evolution', 'check', closed.id], 1);
  assert.match(JSON.stringify(rejected), /recipe.signature/);
  const flowFile = path.join(closed.path, 'target/src/Tasks.hs');
  fs.writeFileSync(flowFile, 'module Tasks where\nreconcile :: String\nreconcile = "wrong type"\n');
  rejected = cli(['evolution', 'check', closed.id], 1);
  assert.match(JSON.stringify(rejected), /recipe.signature/);
  fs.writeFileSync(flowFile, `module Tasks where
import qualified Agentic as A
import qualified Data.Text as T
import Kyyn.Agentic (Flow)
import Kyyn.Recipe
import Kyyn.Workspace.FactEdits (RootEdit)
import qualified RootV2
reconcile :: Flow (RecipeInput RootV2.Root) (ProposedCuration RootEdit)
reconcile = A.note (T.pack "Read λ notes") (T.pack "Inspect captured notes") (A.arr id)
  A.>>> A.note (T.pack "Propose edits") (T.pack "Prepare curation")
    (A.act (\\_ -> error "Checking and description must not execute this flow"))
`);
  const scoped = ['--evolution', closed.id];
  assert.equal(cli(['guest', 'module', 'show', 'Tasks', ...scoped]).result.origin, 'kb');
  assert.equal(cli(['guest', 'module', 'list', ...scoped]).result.origins['Kyyn.Workspace.FactEdits'], 'generated');
  assert(cli(['guest', 'module', 'show', 'Kyyn.Workspace.FactEdits', ...scoped]).result.symbols.some(s => s.name === 'RootEdit'));
  cli(['evolution', 'check', closed.id]);
  const review = JSON.stringify(cli(['evolution', 'show', closed.id]));
  assert.match(review, /"kind":"OpenAgent"/);
  assert.match(review, /"kind":"ClosedAgent"/);
  accept(closed.id);
  cli(['root', 'check']);
  assert(cli(['guest', 'module', 'show', 'Tasks']).result.symbols.some(s => s.name === 'reconcile'));
  assert(cli(['guest', 'module', 'show', 'Kyyn.Workspace.FactEdits']).result.symbols.some(s => s.name === 'Edit_todos'));
  for (const [flags,format,pattern] of [[[], 'tree', /Read λ notes/], [['--dot'], 'dot', /^digraph/],
    [['--mermaid'], 'mermaid', /^flowchart/]]) {
    const result = cli(['root', 'recipe', 'describe', 'sync', ...flags]).result;
    assert.equal(result.kind, 'recipe-description');
    assert.equal(result.flow, 'Tasks.reconcile');
    assert.equal(result.recipe, 'sync');
    assert.equal(result.format, format);
    assert.match(result.revision, /^[0-9a-f]{40}$/);
    assert.match(result.description, pattern);
    assert.match(result.description, /Propose edits/);
    const raw = cli(['root', 'recipe', 'describe', 'sync', ...flags], 0, false);
    assert.equal(raw.trimEnd(), result.description.trimEnd(), 'Human stdout must contain only upstream rendering');
  }
  cli(['root', 'recipe', 'describe', 'sync', '--dot', '--mermaid'], 2, false);
  const noRuntime = ['--runtime', path.join(temporary, 'absent')];
  assert.deepEqual(cli([...noRuntime, 'root', 'recipe', 'show', 'sync']).result.recipe,
    { kind: 'ClosedAgent', flow: 'Tasks.reconcile' });
  assert.match(JSON.stringify(cli([...noRuntime, 'evolution', 'show', closed.id])), /Tasks.reconcile/);
  const changed = cli(['evolution', 'new', 'new-schema']).result;
  const changedTarget = path.join(changed.path, 'target');
  const oldSchema = fs.readFileSync(path.join(changedTarget, 'src/RootV2.hs'), 'utf8');
  fs.writeFileSync(path.join(changedTarget, 'src/RootV3.hs'), oldSchema.replaceAll('RootV2', 'RootV3')
    .replace('title :: String', 'title :: String, done :: Bool'));
  for (const name of ['kb.dhall', 'src/Validate.hs', 'src/Tasks.hs']) {
    const file = path.join(changedTarget, name);
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll('RootV2', 'RootV3'));
  }
  const targetScope = ['--evolution', changed.id];
  const recipeApi = cli(['guest', 'module', 'show', 'Kyyn.Workspace.FactEdits', ...targetScope]).result;
  assert.match(recipeApi.symbols.find(s => s.name === 'proposalEvolution').declaration, /RootV3.Root/);
  assert.doesNotMatch(recipeApi.symbols.find(s => s.name === 'proposalEvolution').declaration, /RootV2.Root/);
  assert(cli(['guest', 'module', 'show', 'Tasks', ...targetScope]).result.symbols.some(s => s.name === 'reconcile'));
  const evolutionApi = cli(['guest', 'module', 'show', 'Kyyn.Workspace.Evolution', ...targetScope]).result;
  assert.match(evolutionApi.symbols.find(s => s.name === 'evolve').declaration, /RootV2.Root/);
  assert.match(evolutionApi.symbols.find(s => s.name === 'evolve').declaration, /RootV3.Root/);
  fs.writeFileSync(path.join(kb, 'root/src/Validate.hs'), 'module Validate where\nvalidate :: Bool\nvalidate = "wrong type"\n');
  fs.writeFileSync(path.join(kb, 'root/facts/root.dhall'), 'False');
  for (const args of [['add', 'root/src/Validate.hs', 'root/facts/root.dhall'], ['commit', '-m', 'Broken validation fixture']]) {
    const result = spawnSync('git', ['-C', kb, ...args], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
  assert.match(cli(['root', 'recipe', 'describe', 'sync']).result.description, /Propose edits/);
  console.log('Closed recipes: signature checks, accepted/draft/schema-changing API discovery, tree/DOT/Mermaid descriptions without flow execution or fact validation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
