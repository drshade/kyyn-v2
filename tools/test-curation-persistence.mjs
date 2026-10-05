// Installed curation register/recipe persistence and refusal cases in disposable KBs.
// Uses authored recipe edits and stored register data; no live provider.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-curation-persistence.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-curation-persistence-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Curation fixture', GIT_AUTHOR_EMAIL: 'curation@example.invalid',
  GIT_COMMITTER_NAME: 'Curation fixture', GIT_COMMITTER_EMAIL: 'curation@example.invalid' };
function invoke(command, args, status = 0) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (...args) => invoke(executable, ['--kb', kb, '--json', ...args]);
function edit(draft, action) {
  const source = path.join(draft.path, 'change/Evolution.hs');
  const scaffold = fs.readFileSync(source, 'utf8').replace('import Kyyn.Workspace.Evolution', 'import Kyyn.Workspace.Evolution\nimport Kyyn.Schema');
  fs.writeFileSync(source, scaffold.replace(/^evolution = .*$/m,
    `evolution = edit (Rationale "Maintain curation instructions" []) (within recipes $ ${action})`));
}
function accept(id) { cli('evolution', 'ready', id); cli('evolution', 'accept', id); }
try {
  cli('kb', 'init');
  const recipeFile = path.join(kb, 'root/recipes.dhall');
  const add = JSON.parse(cli('evolution', 'new', 'teach-curation')).result;
  const targetRecipes = path.join(add.path, 'target/recipes.dhall');
  assert.equal(fs.existsSync(targetRecipes), false);
  fs.copyFileSync(recipeFile, targetRecipes);
  invoke(executable, ['--kb', kb, 'evolution', 'check', add.id], 1);
  fs.unlinkSync(targetRecipes);
  edit(add, 'append (Fact (FactId "syncTodos") (OpenAgent "Inspect current evidence"))');
  cli('evolution', 'check', add.id);
  const saved = cli('evolution', 'show', add.id);
  assert.match(saved, /"kind":"Recipe"/);
  edit(add, 'append (Fact (FactId "bad-name") (OpenAgent "Invalid"))');
  const invalid = JSON.parse(invoke(executable, ['--kb', kb, '--json', 'evolution', 'check', add.id], 1));
  assert.equal(invalid.diagnostics[0].code, 'recipe.invalid-id');
  assert.equal(cli('evolution', 'show', add.id), saved, 'Rejected recipe replaced the candidate');
  const source = path.join(add.path, 'change/Evolution.hs');
  fs.writeFileSync(source, fs.readFileSync(source, 'utf8').replace('bad-name', 'syncTodos').replace('Invalid', 'Inspect current evidence'));
  cli('evolution', 'check', add.id);
  accept(add.id);
  assert.equal(JSON.parse(cli('root', 'recipe', 'show', 'syncTodos')).result.recipe.instructions, 'Inspect current evidence');
  const register = path.join(kb, 'root/curation.dhall');
  fs.writeFileSync(register, `[{ recipe = "syncTodos", plugin = "files", instance = "documents", producer = "source", contract = "${'0'.repeat(64)}", acknowledged = [{ id = "milk", fingerprint = "v1" }] }]`);
  invoke('git', ['-C', kb, 'add', 'root']);
  invoke('git', ['-C', kb, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Seed acknowledged state']);
  cli('root', 'check');
  const first = JSON.parse(cli('evolution', 'new', 'preserve-curation')).result.id;
  const targetRegister = path.join(kb, 'evolutions', first, 'target/curation.dhall');
  assert.equal(fs.existsSync(targetRegister), false);
  fs.copyFileSync(register, targetRegister);
  invoke(executable, ['--kb', kb, 'evolution', 'check', first], 1);
  fs.unlinkSync(targetRegister);
  cli('evolution', 'check', first);
  cli('evolution', 'ready', first);
  cli('evolution', 'accept', first);
  const accepted = fs.readFileSync(register, 'utf8');
  assert.match(accepted, /syncTodos/);
  assert.match(accepted, /milk/);
  assert.match(accepted, /v1/);
  cli('root', 'check');
  const update = JSON.parse(cli('evolution', 'new', 'refine-instructions')).result;
  edit(update, 'update (FactId "syncTodos") (put (OpenAgent "Read evidence and explain changes"))');
  const second = update.id;
  assert.equal(fs.existsSync(path.join(kb, 'evolutions', second, 'target/curation.dhall')), false);
  cli('evolution', 'check', second);
  cli('evolution', 'ready', second);
  cli('evolution', 'accept', second);
  assert.equal(fs.readFileSync(register, 'utf8'), accepted);
  assert.equal(JSON.parse(cli('root', 'recipe', 'show', 'syncTodos')).result.recipe.instructions, 'Read evidence and explain changes');
  const remove = JSON.parse(cli('evolution', 'new', 'remove-recipe')).result;
  edit(remove, 'remove (FactId "syncTodos")');
  cli('evolution', 'check', remove.id);
  accept(remove.id);
  assert.deepEqual(JSON.parse(cli('root', 'recipe', 'list')).result.recipes, []);
  assert.equal(fs.readFileSync(register, 'utf8'), accepted, 'Removing recipe discarded its progress');
  const restore = JSON.parse(cli('evolution', 'new', 'restore-recipe')).result;
  edit(restore, 'append (Fact (FactId "syncTodos") (OpenAgent "Resume the same task"))');
  cli('evolution', 'check', restore.id);
  accept(restore.id);
  assert.equal(fs.readFileSync(register, 'utf8'), accepted);
  assert.match(cli('--runtime', path.join(temporary, 'absent'), 'evolution', 'show', add.id), /Inspect current evidence/);
  console.log('Installed recipes: add/edit/remove/reuse, target refusal, invalid-ID candidate preservation, archived report and inert curation progress passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
