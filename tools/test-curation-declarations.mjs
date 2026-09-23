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
const fetch = () => cli(['evidence', 'fetch', 'local-file', 'documents']).result.fetch;
const scope = id => `EvidenceScope "local-file" "documents" ${JSON.stringify(id)}`;
function author(draft, declaration, recipe = 'syncTodos') {
  const source = path.join(draft.path, 'change/Evolution.hs');
  const scaffold = fs.readFileSync(source, 'utf8');
  const authored = scaffold.replace(/^evolution = .*$/m,
    `evolution = withCuration (Curation (RecipeId "${recipe}") [${declaration}]) identityEvolution`);
  assert.notEqual(authored, scaffold);
  fs.writeFileSync(source, authored);
  return source;
}
try {
  console.log('Configuring a source and recipe through an evolution...');
  fs.mkdirSync(folder);
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'First revision');
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
in [{ name = "documents", binding = "documents", connector = Connector.Folder { directory = ${JSON.stringify(folder)}, recursive = False } }]`);
  const manifest = path.join(setup.path, 'target/kb.dhall');
  fs.writeFileSync(manifest, `(${fs.readFileSync(manifest, 'utf8')}) // { recipes = [{ name = "syncTodos", instructions = "Inspect evidence" }] }`);
  cli(['evolution', 'check', setup.id]);
  accept(setup.id);
  const first = fetch();
  console.log('Fetching updates and preparing an acknowledgement of the older fetch...');
  const firstToken = cli(['evidence', 'change', 'list', 'local-file', 'documents']).result.changes[0].fingerprint;
  fs.writeFileSync(path.join(folder, 'todo.txt'), 'Second revision');
  fetch();
  const draft = cli(['evolution', 'new', 'handle-first-fetch']).result;
  const source = author(draft, `EntireBatch (${scope(first)})`);
  const authored = fs.readFileSync(source, 'utf8');
  cli(['evolution', 'check', draft.id]);
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
  assert.match(fs.readFileSync(register, 'utf8'), new RegExp(firstToken));
  assert.match(JSON.stringify(cli(['evolution', 'show', draft.id])), new RegExp(first));
  fs.unlinkSync(path.join(folder, 'todo.txt'));
  const empty = fetch();
  const deletion = cli(['evolution', 'new', 'handle-deletion']).result;
  console.log('Acknowledging deletion from a fresh empty fetch...');
  author(deletion, `IndividualRecords (${scope(empty)}) [EvidenceId "todo.txt"]`);
  cli(['evolution', 'check', deletion.id]);
  accept(deletion.id);
  assert(!fs.readFileSync(register, 'utf8').includes('todo.txt'), 'Deletion acknowledgement retained the ID');
  console.log('Installed curation declarations: historical scope, failure retention, cache-free acceptance, archive and fresh-refetch deletion passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
