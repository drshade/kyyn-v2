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
function cli(args, status = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
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
import Kyyn.Agentic (Flow)
import Kyyn.Recipe
import Kyyn.Workspace.FactEdits (RootEdit)
import qualified RootV2
reconcile :: Flow (RecipeInput RootV2.Root) (ProposedCuration RootEdit)
reconcile = A.arr (\\_ -> error "Root checking must not execute this flow")
`);
  cli(['evolution', 'check', closed.id]);
  const review = JSON.stringify(cli(['evolution', 'show', closed.id]));
  assert.match(review, /"kind":"OpenAgent"/);
  assert.match(review, /"kind":"ClosedAgent"/);
  accept(closed.id);
  cli(['root', 'check']);
  const noRuntime = ['--runtime', path.join(temporary, 'absent')];
  assert.deepEqual(cli([...noRuntime, 'root', 'recipe', 'show', 'sync']).result.recipe,
    { kind: 'ClosedAgent', flow: 'Tasks.reconcile' });
  assert.match(JSON.stringify(cli([...noRuntime, 'evolution', 'show', closed.id])), /Tasks.reconcile/);
  console.log('Closed recipes: missing/wrong flows refused; valid flow checked but not executed; constructor change accepted and archived.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
