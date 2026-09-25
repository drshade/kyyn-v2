import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-curation-declarations.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-curation-declarations-'));
const kb = path.join(temporary, 'kb');
const plugin = path.join(temporary, 'plugin');
const folder = path.join(temporary, 'source');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Curation fixture', GIT_AUTHOR_EMAIL: 'curation@example.invalid',
  GIT_COMMITTER_NAME: 'Curation fixture', GIT_COMMITTER_EMAIL: 'curation@example.invalid' };
function invoke(command, args, status = 0) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (args, status = 0) => JSON.parse(invoke(executable, ['--kb', kb, '--json', ...args], status));
const accept = id => { cli(['evolution', 'ready', id]); cli(['evolution', 'accept', id]); };
const fetch = (instance = 'documents') => cli(['evidence', 'fetch', 'local-file', instance]).result.fetch;
const scope = (id, instance = 'documents') => `EvidenceScope "local-file" "${instance}" ${JSON.stringify(id)}`;
const pending = (recipe = 'syncTodos', instance = 'documents', status = 0) =>
  cli(['root', 'recipe', 'pending', 'list', recipe, 'local-file', instance], status);
function author(draft, declaration, recipe = 'syncTodos', transformation = 'identityEvolution') {
  const source = path.join(draft.path, 'change/Evolution.hs');
  const scaffold = fs.readFileSync(source, 'utf8');
  const authored = scaffold.replace(/^evolution = .*$/m,
    `evolution = withCuration (Curation (RecipeId "${recipe}") [${declaration}]) (${transformation})`);
  assert.notEqual(authored, scaffold);
  fs.writeFileSync(source, authored.replace('import Kyyn.Workspace.Evolution', 'import Kyyn.Workspace.Evolution\nimport Kyyn.Schema'));
  return source;
}
try {
  console.log('Configuring a source and recipe through an evolution...');
  fs.mkdirSync(folder);
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'First revision');
  fs.writeFileSync(path.join(folder, 'temporary.txt'), 'Never curated at latest');
  fs.cpSync(path.join(repository, 'plugins/local-file'), plugin, { recursive: true });
  invoke('git', ['-C', plugin, 'init', '-q', '-b', 'main']);
  invoke('git', ['-C', plugin, 'add', '.']);
  invoke('git', ['-C', plugin, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Plugin fixture']);
  cli(['kb', 'init']);
  const setup = cli(['evolution', 'new', 'configure-source']).result;
  cli(['plugin', 'install', '--evolution', setup.id, '--from', plugin]);
  const config = path.join(setup.path, 'target/plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, `let Connector = < Folder : { directory : Text, recursive : Bool } >
in [${['documents', 'prices'].map(name => `{ name = "${name}", binding = "${name}", connector = Connector.Folder { directory = ${JSON.stringify(folder)}, recursive = False } }`).join(', ')}]`);
  const manifest = path.join(setup.path, 'target/kb.dhall');
  fs.unlinkSync(path.join(setup.path, 'target/src/RootV1.hs'));
  fs.writeFileSync(path.join(setup.path, 'target/src/RootV2.hs'), `module RootV2 where
import Kyyn.Schema
data Todo = Todo { title :: String } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
`);
  for (const file of [manifest, path.join(setup.path, 'target/src/Validate.hs')])
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll('RootV1', 'RootV2'));
  fs.writeFileSync(path.join(setup.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Start tracking tasks" []) (onFacts (\\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Teach the KB its curation tasks" []) (within recipes $ do
    append (Fact (FactId "syncTodos") (Recipe "Inspect evidence"))
    append (Fact (FactId "groceryPrices") (Recipe "Refresh prices")))
`);
  cli(['evolution', 'check', setup.id]);
  accept(setup.id);
  const noRuntime = ['--runtime', path.join(temporary, 'absent-runtime'), 'root', 'recipe'];
  assert.deepEqual(cli([...noRuntime, 'list']).result.recipes.map(r => r.name), ['syncTodos', 'groceryPrices']);
  assert.equal(cli([...noRuntime, 'show', 'syncTodos']).result.instructions, 'Inspect evidence');
  assert.equal(cli([...noRuntime, 'show', 'unknown'], 1).diagnostics[0].code, 'curation.recipe-unknown');
  assert.equal(pending('syncTodos', 'documents', 1).diagnostics[0].code, 'evidence.not-fetched');
  const first = fetch();
  assert.match(first, /^[0-9a-f]{8}$/);
  const pendingHuman = invoke(executable, ['--kb', kb, 'root', 'recipe', 'pending', 'list', 'syncTodos', 'local-file', 'documents']);
  const copiedScope = pendingHuman.split('\n').find(line => line.startsWith('Scope: '))?.slice('Scope: '.length);
  assert.equal(copiedScope, scope(first));
  const prices = fetch('prices');
  console.log('Fetching updates and preparing an acknowledgement of the older fetch...');
  const firstToken = cli(['evidence', 'change', 'list', 'local-file', 'documents']).result.changes.find(c => c.id === 'todo.txt').fingerprint;
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'Second revision');
  fs.unlinkSync(path.join(folder, 'temporary.txt'));
  const second = fetch();
  const unseen = pending().result;
  assert.deepEqual(unseen.scope, { plugin: 'local-file', instance: 'documents', fetch: second });
  assert.deepEqual(unseen.changes, [{ id: 'todo.txt', kind: 'New' }]);
  const draft = cli(['evolution', 'new', 'handle-first-fetch']).result;
  const source = author(draft, `EntireBatch (${copiedScope}), IndividualRecords (${scope(prices, 'prices')}) [EvidenceId "todo.txt"]`,
    'syncTodos', 'edit (Rationale "Track the document task" [EvidenceRef { producer = "local-file", instanceName = "documents", source = "todo.txt", references = [] }]) (within AfterCollections.todos (append (Fact (FactId "task") (After.Todo "Review document"))))');
  const authored = fs.readFileSync(source, 'utf8');
  cli(['evolution', 'check', draft.id]);
  const humanReport = invoke(executable, ['--kb', kb, 'evolution', 'show', draft.id]);
  assert.match(humanReport, /Declared citations:/);
  const report = cli(['evolution', 'show', draft.id]);
  assert.match(JSON.stringify(report), new RegExp(first));
  assert.match(JSON.stringify(report), /EntireBatch/);
  const register = path.join(kb, 'root/curation.dhall');
  assert.equal(fs.existsSync(register), false, 'Preparing changed accepted progress');
  fs.writeFileSync(source, authored.replace(first, 'unavailable-fetch'));
  assert.equal(cli(['evolution', 'check', draft.id], 1).diagnostics[0].code, 'curation.scope-unavailable');
  assert.deepEqual(cli(['evolution', 'show', draft.id]), report, 'Failure replaced the saved report');
  fs.writeFileSync(source, authored.replace('RecipeId "syncTodos"', 'RecipeId "unknown"'));
  assert.equal(cli(['evolution', 'check', draft.id], 1).diagnostics[0].code, 'curation.recipe-unknown');
  fs.writeFileSync(source, authored);
  console.log('Refreshing/clearing evidence, then accepting the saved candidate...');
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'Third revision after preparation');
  fetch();
  cli(['evidence', 'clear', 'local-file', 'documents']);
  accept(draft.id);
  assert(fs.readFileSync(register, 'utf8').includes(JSON.stringify(firstToken)), 'Acceptance did not preserve the selected fetch fingerprint');
  assert.match(JSON.stringify(cli(['evolution', 'show', draft.id])), new RegExp(first));
  assert.equal(pending('syncTodos', 'documents', 1).diagnostics[0].code, 'evidence.not-fetched');
  fetch();
  assert.deepEqual(pending().result.changes.map(c => [c.id,c.kind]).sort(),
    [['temporary.txt','Removed'],['todo.txt','Updated']]);
  assert.deepEqual(pending('groceryPrices').result.changes, [{ id: 'todo.txt', kind: 'New' }]);
  assert.deepEqual(pending('syncTodos', 'prices').result.changes, [{ id: 'temporary.txt', kind: 'New' }]);
  fs.unlinkSync(path.join(folder, 'todo.txt'));
  const empty = fetch();
  const deletion = cli(['evolution', 'new', 'handle-deletion']).result;
  console.log('Acknowledging deletion from a fresh empty fetch...');
  author(deletion, `IndividualRecords (${scope(empty)}) [EvidenceId "todo.txt", EvidenceId "temporary.txt"]`);
  cli(['evolution', 'check', deletion.id]);
  accept(deletion.id);
  assert.deepEqual(pending().result.changes, [], 'Deletion acknowledgement retained pending work');
  const human = invoke(executable, ['--kb', kb, 'root', 'recipe', 'pending', 'list', 'syncTodos', 'local-file', 'documents']);
  assert.match(human, /No unacknowledged changes/);
  const teach = cli(['evolution', 'new', 'teach-and-curate']).result;
  author(teach, `EntireBatch (${scope(empty)})`, 'newTask',
    'edit (Rationale "Teach and perform a task" []) (within recipes (append (Fact (FactId "newTask") (Recipe "Inspect documents"))))');
  cli(['evolution', 'check', teach.id]);
  accept(teach.id);
  assert.deepEqual(pending('newTask').result.changes, [], 'New recipe did not acknowledge in the same evolution');
  console.log('Installed recipe curation: discovery without runtime, net changes, independent recipes/instances, mixed acknowledgements with facts, fixed-scope cache-free acceptance and deletion passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
