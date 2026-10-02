import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-recipe-run.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-recipe-run-'));
const kb = path.join(temporary, 'kb'), plugin = path.join(temporary, 'plugin'), folder = path.join(temporary, 'source');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Recipe fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Recipe fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function invoke(command, args, status = 0) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (args, status = 0) => JSON.parse(invoke(executable, ['--kb', kb, '--json', ...args], status));
const accept = id => { cli(['evolution', 'ready', id]); cli(['evolution', 'accept', id]); };
const run = (name, extra = [], status = 0) => cli(['root', 'recipe', 'run', name, 'local-file', 'documents', ...extra], status);
const countDrafts = () => fs.readdirSync(path.join(kb, 'evolutions')).length;
try {
  fs.mkdirSync(folder);
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'Captured task');
  fs.cpSync(path.join(repository, 'plugins/local-file'), plugin, { recursive: true });
  invoke('git', ['-C', plugin, 'init', '-q', '-b', 'main']);
  invoke('git', ['-C', plugin, 'add', '.']);
  invoke('git', ['-C', plugin, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Plugin fixture']);
  cli(['kb', 'init']);
  const setup = cli(['evolution', 'new', 'configure-recipes']).result;
  cli(['plugin', 'install', '--evolution', setup.id, '--from', plugin]);
  const target = path.join(setup.path, 'target');
  fs.writeFileSync(path.join(target, 'model.dhall'),
    '{ provider = < OpenAI | Anthropic >.OpenAI, model = "fixture", credential = "RECIPE_TEST_KEY" }');
  const config = path.join(target, 'plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, `let Connector = < Folder : { directory : Text, recursive : Bool } >
in [${['documents', 'prices'].map(name => `{ name = "${name}", binding = "${name}", connector = Connector.Folder { directory = ${JSON.stringify(folder)}, recursive = False } }`).join(', ')}]`);
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
  fs.writeFileSync(path.join(target, 'src/Tasks.hs'), `module Tasks where
import qualified Agentic as A
import qualified Data.Text as Text
import Control.Monad.Trans.Except (throwE)
import Kyyn.Agentic (Flow, liftTool, interpret)
import Kyyn.Recipe
import Kyyn.Schema (Fact(..), FactId(..))
import Kyyn.Evolution (Rationale(..))
import Kyyn.Plugin (FetchError(..))
import Kyyn.Workspace.FactEdits
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_local_file.Folder as Folder
import qualified RootV2
reconcile :: Flow (RecipeInput RootV2.Root) (ProposedCuration RootEdit)
reconcile = A.act $ \\(RecipeInput recipe@(RecipeId name) (RootV2.Root facts) batches) -> do
  let removed = or [case change of Removed _ -> True; _ -> False | PendingEvidence _ changes <- batches, change <- changes]
  text <- if removed || name == "empty" then pure "" else liftTool (Folder.content Connectors.documents "todo.txt") >>= either throwE pure
  if name == "needsModel" then do
    _ <- liftTool (interpret (A.draft (A.Instruction (Text.pack "Summarise")) :: Flow Text.Text Text.Text) (Text.pack text)) >>= either throwE pure
    pure ()
    else pure ()
  if name == "failFlow" then throwE (FetchError "Authored refusal") else pure ()
  let scopes = [scope | PendingEvidence scope _ <- batches]
      handled = if name == "empty" then []
        else if name == "wrongScope" then [EntireBatch (EvidenceScope "local-file" "documents" "invented")]
        else if name == "wrongId" then [IndividualRecords scope [EvidenceId "not-pending"] | scope <- scopes]
        else map EntireBatch scopes
      selected = if name == "wrongRecipe" then RecipeId "someoneElse" else recipe
      change = if removed then Remove (FactId "todo.txt")
        else if null facts then Append (Fact (FactId "todo.txt") (RootV2.Todo text))
        else Replace (FactId "todo.txt") (RootV2.Todo text)
      steps = if name == "empty" then [] else [ProposedStep (Rationale "Use captured evidence" []) [Edit_todos change]]
  pure (ProposedCuration steps (Curation selected handled))
`);
  fs.writeFileSync(path.join(setup.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Track tasks" []) (onFacts (\\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Teach recipes" []) (within recipes $ do
    append (Fact (FactId "open") (OpenAgent "Use an external agent"))
    mapM_ (\\name -> append (Fact (FactId name) (ClosedAgent (FlowEntryRef "Tasks.reconcile"))))
      ["sync", "wrongRecipe", "wrongScope", "wrongId", "failFlow", "needsModel", "empty"])
`);
  cli(['evolution', 'check', setup.id]);
  accept(setup.id);
  for (const instance of ['documents', 'prices']) cli(['evidence', 'fetch', 'local-file', instance]);
  const before = countDrafts();
  for (const [name, code] of [['open', 'recipe.open-agent'], ['wrongRecipe', 'recipe.curation-mismatch'],
    ['wrongScope', 'recipe.curation-scope'], ['wrongId', 'recipe.curation-record'], ['failFlow', 'tool.failed']]) {
    assert.match(JSON.stringify(run(name, [], 1)), new RegExp(code));
    assert.equal(countDrafts(), before, 'Refused run created an evolution');
  }
  assert.match(JSON.stringify(run('sync', ['local-file', 'documents'], 1)), /recipe.duplicate-input/);
  assert.match(JSON.stringify(run('needsModel', [], 1)), /Missing model secret RECIPE_TEST_KEY/);
  assert.equal(countDrafts(), before);
  invoke(executable, ['--kb', kb, 'root', 'recipe', 'run', 'sync', 'local-file'], 2);
  const proposal = run('sync', ['local-file', 'prices']).result;
  const frozen = fs.readFileSync(path.join(proposal.path, 'change/proposal.dhall'), 'utf8');
  assert.match(frozen, /Captured task/);
  assert.match(frozen, /prices/);
  assert.match(JSON.stringify(cli(['evolution', 'show', proposal.id])), /Draft/);
  assert.match(JSON.stringify(cli(['root', 'recipe', 'pending', 'list', 'sync', 'local-file', 'documents'])), /todo.txt/);
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'Newer source text');
  cli(['evidence', 'fetch', 'local-file', 'documents']);
  cli(['evolution', 'check', proposal.id]);
  cli(['evolution', 'check', proposal.id]);
  assert.equal(fs.readFileSync(path.join(proposal.path, 'change/proposal.dhall'), 'utf8'), frozen);
  accept(proposal.id);
  const shown = JSON.stringify(cli(['root', 'show']));
  assert.match(shown, /Captured task/);
  assert(!shown.includes('Newer source text'));
  assert.match(JSON.stringify(cli(['root', 'recipe', 'pending', 'list', 'sync', 'local-file', 'documents'])), /Updated/);
  assert.deepEqual(cli(['root', 'recipe', 'pending', 'list', 'sync', 'local-file', 'prices']).result.changes, []);
  fs.unlinkSync(path.join(folder, 'todo.txt'));
  cli(['evidence', 'fetch', 'local-file', 'documents']);
  const deletion = run('sync').result;
  assert.match(fs.readFileSync(path.join(deletion.path, 'change/proposal.dhall'), 'utf8'), /Remove/);
  cli(['evolution', 'check', deletion.id]);
  accept(deletion.id);
  assert.deepEqual(cli(['root', 'recipe', 'pending', 'list', 'sync', 'local-file', 'documents']).result.changes, []);
  const empty = run('empty').result;
  assert.equal(empty.state, 'Draft', 'Empty pending input should remain an authored decision');
  cli(['evolution', 'check', empty.id]);
  console.log('Recipe run: captured reads, multiple scopes, refused proposals, Draft persistence, repeatable checking and ordinary acceptance passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
