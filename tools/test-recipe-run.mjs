// Installed closed recipe: generic current reads across two instances, typed
// fact/state proposals, frozen replay and acceptance. Model failures use no network.

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
const run = (name, extra = [], status = 0) => cli(['root', 'recipe', 'run', name, ...extra], status);
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
  assert(!cli(['guest', 'module', 'list', '--evolution', setup.id]).result.modules.includes('KyynFrozenProposal'));
  cli(['plugin', 'install', '--evolution', setup.id, '--from', plugin]);
  const target = path.join(setup.path, 'target');
  fs.writeFileSync(path.join(target, 'model.dhall'),
    '{ provider = < OpenAI | Anthropic >.OpenAI, model = "fixture", credential = "RECIPE_TEST_KEY" }');
  const config = path.join(target, 'plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, `let Connector = < Folder : { directory : Text, recursive : Bool } | File : { path : Text } >
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
  fs.writeFileSync(path.join(target, 'src/Tasks.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Tasks where
import qualified Agentic as A
import qualified Agentic.Questions as Q
import qualified Data.Text as Text
import Control.Monad.Trans.Except (throwE)
import Kyyn.Agentic (Step, Flow, liftTool, interpret)
import Kyyn.Recipe
import Kyyn.Schema (Fact(..), FactId(..))
import Kyyn.Evolution (Rationale(..), EvidenceRef(..))
import Kyyn.Plugin (FetchError(..), Evidence(..), EvidencePayload(..), EvidenceId(..))
import Kyyn.Workspace.FactEdits
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_local_file.Folder.Evidence as Evidence
import qualified LocalFile.Types as Local
import qualified RootV2
reconcile :: Flow (RecipeInput RootV2.Root String Integer) (RecipeProposal RootEdit Integer)
reconcile = A.act reconcileStep
reconcileStep :: RecipeInput RootV2.Root String Integer -> Step (RecipeProposal RootEdit Integer)
reconcileStep (RecipeInput (RootV2.Root facts) mode runs) = do
  if mode == "failFlow" then throwE (FetchError "Authored refusal") else pure ()
  if mode == "needsModel" then do
    _ <- liftTool (interpret (A.draft (A.Instruction "Summarise") :: Flow Text.Text Text.Text) "task") >>= either throwE pure
    pure ()
    else pure ()
  if mode == "needsJev" then do
    _ <- liftTool (interpret (A.judge (Q.yesNo "Does this need action?") :: Flow Text.Text Q.YesNo) "task") >>= either throwE pure
    pure ()
    else pure ()
  ids <- liftTool (Evidence.listEvidenceIds Connectors.documents) >>= either throwE pure
  prices <- liftTool (Evidence.listEvidenceIds Connectors.prices) >>= either throwE pure
  captured <- mapM (\\key -> liftTool (Evidence.readEvidence Connectors.documents key) >>= either throwE pure) ids
  missing <- liftTool (Evidence.readEvidence Connectors.documents (EvidenceId "absent.txt")) >>= either throwE pure
  case missing of Just _ -> throwE (FetchError "Missing ID resolved"); Nothing -> pure ()
  let texts = [Text.unpack text | Just (Evidence _ _ (Available (Local.Document text))) <- captured]
      citations = [EvidenceRef "local-file" "documents" key refs |
        (EvidenceId key, Just (Evidence _ refs _)) <- zip ids captured]
      edits = case texts of
        [] -> [Edit_todos (Remove key) | Fact key _ <- facts]
        text:_ -> [Edit_todos (if null facts then Append (Fact (FactId "todo.txt") (RootV2.Todo text))
          else Replace (FactId "todo.txt") (RootV2.Todo text))]
      rationale = Rationale (Text.pack ("Read current evidence; price items=" ++ show (length prices))) citations
  pure (RecipeProposal [ProposedStep rationale edits] (runs + 1))
`);
  fs.writeFileSync(path.join(setup.path, 'change/Evolution.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import qualified Kyyn.Workspace.After.RecipeFlows.Tasks as Tasks
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Track tasks" []) (onFacts (\\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Teach recipes" []) (do
    createRecipe (RecipeId "open") (openRecipe unitRecipeType "Use an external agent") ()
    createRecipe (RecipeId "sync") Tasks.reconcile 0
    createRecipe (RecipeId "untouched") Tasks.reconcile 100)
`);
  console.log('Creating evidence-reading recipe and typed state');
  cli(['evolution', 'check', setup.id]);
  accept(setup.id);
  const state = name => fs.readFileSync(path.join(kb, 'root/recipes', name, 'state.dhall'), 'utf8');
  const initialState = state('sync'), untouched = state('untouched');
  const apiName = 'Kyyn.Plugins.P_local_file.Folder.Evidence';
  assert(cli(['guest', 'module', 'list']).result.modules.includes(apiName));
  const api = cli(['guest', 'module', 'show', apiName]).result;
  assert.match(JSON.stringify(api), /listEvidenceIds/);
  assert.match(JSON.stringify(api), /LocalFile.Types.Document/);
  assert.match(JSON.stringify(cli(['evidence', 'show', 'local-file', 'documents', 'todo.txt'], 1)), /evidence.not-fetched/);
  for (const instance of ['documents', 'prices']) cli(['evidence', 'fetch', 'local-file', instance]);
  const item = cli(['evidence', 'show', 'local-file', 'documents', 'todo.txt']).result;
  assert.deepEqual(item.payload, { tag: 'Available', value: { text: 'Captured task' } });
  assert(item.fingerprint.length > 0);
  assert.deepEqual(item.externalReferences, [path.join(folder, 'todo.txt')]);
  assert.match(JSON.stringify(cli(['evidence', 'show', 'local-file', 'documents', 'absent.txt'], 1)), /evidence.not-found/);
  const before = countDrafts();
  assert.match(JSON.stringify(run('open', [], 1)), /recipe.open-agent/);
  for (const [mode, diagnostic] of [['failFlow', /tool.failed/], ['needsModel', /Missing model secret RECIPE_TEST_KEY/],
    ['needsJev', /Missing model secret JEV_TOKEN/]]) {
    assert.match(JSON.stringify(run('sync', ['--input', JSON.stringify(mode)], 1)), diagnostic);
    assert.equal(countDrafts(), before, 'Refused run created an evolution');
  }
  assert.equal(state('sync'), initialState);
  console.log('Running generic current evidence reads and freezing fact/state output');
  const proposal = run('sync', ['--input', '"sync"']).result;
  const frozen = fs.readFileSync(path.join(proposal.path, 'change/proposal.dhall'), 'utf8');
  assert.match(fs.readFileSync(path.join(proposal.path, 'change/Evolution.hs'), 'utf8'), /^evolution = frozen$/m);
  assert.match(frozen, /Captured task/);
  assert.match(frozen, /price items=1/);
  assert.doesNotMatch(frozen, /curation/);
  assert.match(JSON.stringify(cli(['guest', 'module', 'show', 'KyynFrozenProposal', '--evolution', proposal.id])), /RecipeEvolution/);
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'Newer source text');
  cli(['evidence', 'fetch', 'local-file', 'documents']);
  assert.equal(cli(['evidence', 'show', 'local-file', 'documents', 'todo.txt']).result.payload.value.text, 'Newer source text');
  cli(['evolution', 'check', proposal.id]);
  cli(['evolution', 'check', proposal.id]);
  assert.equal(fs.readFileSync(path.join(proposal.path, 'change/proposal.dhall'), 'utf8'), frozen);
  assert.equal(state('sync'), initialState, 'Checking advanced recipe state');
  accept(proposal.id);
  const shown = JSON.stringify(cli(['root', 'show']));
  assert.match(shown, /Captured task/);
  assert.doesNotMatch(shown, /Newer source text/);
  assert.equal(state('sync').trim(), '+1');
  assert.equal(state('untouched'), untouched);
  fs.unlinkSync(path.join(folder, 'todo.txt'));
  cli(['evidence', 'fetch', 'local-file', 'documents']);
  assert.match(JSON.stringify(cli(['evidence', 'show', 'local-file', 'documents', 'todo.txt'], 1)), /evidence.not-found/);
  const deletion = run('sync', ['--input', '"sync"']).result;
  assert.match(fs.readFileSync(path.join(deletion.path, 'change/proposal.dhall'), 'utf8'), /Remove/);
  cli(['evolution', 'check', deletion.id]);
  accept(deletion.id);
  assert.equal(state('sync').trim(), '+2');
  cli(['evidence', 'clear', 'local-file', 'documents']);
  assert.equal(state('sync').trim(), '+2', 'Cache clearing changed accepted state');
  assert.equal(state('untouched'), untouched);
  cli(['root', 'check']);
  console.log('Generic current reads, inspection, typed proposals, frozen replay and recipe isolation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
