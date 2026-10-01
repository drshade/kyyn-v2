import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-fact-proposal.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-proposal-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_COUNT: '2', GIT_CONFIG_KEY_0: 'user.name',
  GIT_CONFIG_VALUE_0: 'Proposal test', GIT_CONFIG_KEY_1: 'user.email', GIT_CONFIG_VALUE_1: 'proposal@example.invalid' };
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify(result));
  return JSON.parse(result.stdout);
}
function accept(id) { cli(['evolution', 'ready', id]); return cli(['evolution', 'accept', id]); }
try {
  cli(['kb', 'init']);
  const initial = cli(['evolution', 'new', 'schema']).result;
  const target = path.join(initial.path, 'target');
  fs.unlinkSync(path.join(target, 'src/RootV1.hs'));
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
  fs.writeFileSync(path.join(initial.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Start tracking tasks" [])
  (onFacts (\\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Teach curation" []) (within recipes (append (Fact (FactId "sync") (Recipe "Review tasks"))))
`);
  cli(['evolution', 'check', initial.id]);
  accept(initial.id);
  const beforeSchema = fs.readFileSync(path.join(kb, 'root/src/RootV2.hs'), 'utf8');
  const beforeRecipes = fs.readFileSync(path.join(kb, 'root/recipes.dhall'), 'utf8');
  const draft = cli(['evolution', 'new', 'frozen-proposal']).result;
  const dataPath = path.join(draft.path, 'change/proposal.dhall');
  const proposal = `let Edit = < Append : { id : Text, value : { title : Text } }
                 | Replace : { factId : Text, replacement : { title : Text } }
                 | Remove : Text >
let RootEdit = < Edit_todos : Edit >
let Ack = < EntireBatch : { plugin : Text, instance : Text, fetch : Text }
          | IndividualRecords : { scope : { plugin : Text, instance : Text, fetch : Text }, ids : List Text } >
in { steps = [ { rationale = { explanation = "Record useful work", evidence =
       [ { producer = "notes", connector = "inbox", source = "file:///tasks", references = [ "todo-1" ] } ] }
     , edits = [ RootEdit.Edit_todos (Edit.Append { id = "todo-1", value = { title = "Do this" } }) ] } ]
   , curation = { recipe = "sync", handled = [] : List Ack } }
`;
  fs.writeFileSync(dataPath, proposal);
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Workspace.FactEdits
import qualified KyynFrozenProposal
import qualified RootV2
evolution :: Evolution (KnowledgeBase RootV2.Root) (KnowledgeBase RootV2.Root)
evolution = either error proposalEvolution KyynFrozenProposal.proposal
`);
  cli(['evolution', 'check', draft.id]);
  const reviewed = cli(['evolution', 'show', draft.id]);
  assert.match(JSON.stringify(reviewed), /Record useful work/);
  assert.match(JSON.stringify(reviewed), /file:\/\/\/tasks/);
  cli(['evolution', 'check', draft.id]);
  assert.deepEqual(cli(['evolution', 'show', draft.id]), reviewed);
  cli(['evolution', 'ready', draft.id]);
  fs.writeFileSync(dataPath, proposal.replace('Do this', 'Do something else'));
  cli(['evolution', 'accept', draft.id], 1);
  fs.writeFileSync(dataPath, 'True');
  cli(['evolution', 'check', draft.id], 1);
  const retained = cli(['evolution', 'show', draft.id]);
  assert.deepEqual(retained.result.report, reviewed.result.report);
  assert.equal(retained.result.revision, reviewed.result.revision);
  fs.writeFileSync(dataPath, proposal);
  cli(['evolution', 'check', draft.id]);
  accept(draft.id);
  assert.deepEqual(cli(['root', 'show']).result.value, { todos: [{ id: 'todo-1', value: { title: 'Do this' } }] });
  assert.equal(fs.readFileSync(path.join(kb, 'root/src/RootV2.hs'), 'utf8'), beforeSchema);
  assert.equal(fs.readFileSync(path.join(kb, 'root/recipes.dhall'), 'utf8'), beforeRecipes);
  assert.equal(fs.readFileSync(dataPath, 'utf8'), proposal);
  assert.match(JSON.stringify(cli(['evolution', 'show', draft.id])), /Record useful work/);
  console.log('Frozen Dhall proposal: repeated checking, rationale/citations, stale-input refusal, failed-check preservation and ordinary acceptance passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
