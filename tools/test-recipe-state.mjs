// Staged/installed CLI: typed recipe creation, migration, identity and removal.
// Checks candidate/archive reload, acceptance and per-recipe isolation. No flows/providers.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-recipe-state.mjs EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-recipe-state-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Recipe state fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Recipe state fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, status = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 180000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
function author(draft, imports, body) {
  fs.writeFileSync(path.join(draft.path, 'change/Evolution.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import qualified RootV1
${imports}
evolution :: Evolution (KnowledgeBase RootV1.Root) (KnowledgeBase RootV1.Root)
evolution = ${body}
`);
}
function accept(draft) {
  cli(['evolution', 'check', draft.id]);
  const report = cli(['evolution', 'show', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  cli(['root', 'check']);
  assert.deepEqual(cli(['evolution', 'show', draft.id]).result.report, report.result.report);
  return report;
}
const statePath = name => path.join(kb, 'root/recipes', name, 'state.dhall');
try {
  cli(['kb', 'init']);
  const creation = cli(['evolution', 'new', 'create-recipes']).result;
  fs.writeFileSync(path.join(creation.path, 'target/src/ReviewV1.hs'),
    'module ReviewV1 where\ndata State = State { reviewed :: [String] }\n');
  author(creation, `import qualified ReviewV1
import qualified Kyyn.Workspace.After.RecipeTypes.ReviewV1.State as State`,
    `edit (Rationale "Teach two independent recipes" []) $ do
  createRecipe (RecipeId "mail") (openRecipe State.recipeType "Review mail") (ReviewV1.State ["mail-1"])
  createRecipe (RecipeId "calendar") (openRecipe State.recipeType "Review calendar") (ReviewV1.State [])
  createRecipe (RecipeId "stateless") (openRecipe unitRecipeType "Investigate") ()`);
  assert.match(JSON.stringify(accept(creation)), /ReviewV1.State/);
  const calendar = fs.readFileSync(statePath('calendar'), 'utf8');
  assert.match(fs.readFileSync(statePath('mail'), 'utf8'), /mail-1/);
  assert.match(fs.readFileSync(statePath('stateless'), 'utf8'), /\{=\}/);
  assert.equal(cli(['root', 'recipe', 'list']).result.recipes.length, 3);

  const migration = cli(['evolution', 'new', 'migrate-mail']).result;
  fs.writeFileSync(path.join(migration.path, 'target/src/ReviewV2.hs'),
    'module ReviewV2 where\ndata State = State { reviewed :: [String], window :: Maybe String }\n');
  author(migration, `import qualified ReviewV1
import qualified ReviewV2
import qualified Kyyn.Workspace.Before.RecipeTypes.ReviewV1.State as Old
import qualified Kyyn.Workspace.After.RecipeTypes.ReviewV2.State as New`,
    `edit (Rationale "Limit the mail review window" []) $
  updateRecipe Old.recipeType (RecipeId "mail") (openRecipe New.recipeType "Review recent mail")
    (\\(ReviewV1.State seen) -> Right (ReviewV2.State seen (Just "October")))`);
  const report = JSON.stringify(accept(migration));
  assert.match(report, /ReviewV1.State/);
  assert.match(report, /ReviewV2.State/);
  assert.match(report, /October/);
  assert.equal(fs.readFileSync(statePath('calendar'), 'utf8'), calendar);

  const identity = cli(['evolution', 'new', 'unchanged-recipes']).result;
  const files = ['mail', 'calendar', 'stateless'].map(name => fs.readFileSync(statePath(name), 'utf8'));
  accept(identity);
  assert.deepEqual(['mail', 'calendar', 'stateless'].map(name => fs.readFileSync(statePath(name), 'utf8')), files);

  const removal = cli(['evolution', 'new', 'remove-mail']).result;
  author(removal, '', 'edit (Rationale "Stop reviewing mail" []) (removeRecipe (RecipeId "mail"))');
  accept(removal);
  assert.equal(fs.existsSync(statePath('mail')), false);
  assert.equal(fs.readFileSync(statePath('calendar'), 'utf8'), calendar);
  console.log('Recipe state creation, typed migration, identity, removal and accepted archive inspection passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
