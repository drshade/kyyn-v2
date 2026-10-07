// Real closed-flow request/state execution, state-only frozen proposal, discovery
// and acceptance without rerunning the flow. Recipes are created through generated
// flow-definition handles, deriving request/state types from authored signatures.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-recipe-state-run.mjs EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-state-run-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Recipe fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Recipe fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function invoke(command, args, status = 0) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 180000 });
  assert.equal(result.status, status, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (args, status = 0) => JSON.parse(invoke(executable, ['--kb', kb, '--json', ...args], status));
let rootLocation = 'root';
function write(name, contents) {
  const file = path.join(kb, name.replace(/^root\//, `${rootLocation}/`));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}
try {
  cli(['kb', 'init']);
  const setup = cli(['evolution', 'new', 'define-recipes']).result;
  rootLocation = path.relative(kb, path.join(setup.path, 'target'));
  write('root/src/Review.hs', 'module Review where\ndata State = State { seen :: [String] }\n');
  write('root/src/Flows.hs', `module Flows where
import Control.Arrow (arr)
import Kyyn.Agentic (Flow)
import Kyyn.Recipe
import Kyyn.Workspace.FactEdits (RootEdit)
import qualified RootV1
import qualified Review
review :: Flow (RecipeInput RootV1.Root String Review.State) (RecipeProposal RootEdit Review.State)
review = arr (\\(RecipeInput _ request (Review.State seen)) ->
  if request == "explode" then error "Flow ran again" else RecipeProposal [] (Review.State (seen ++ [request])))
unit :: Flow (RecipeInput RootV1.Root () ()) (RecipeProposal RootEdit ())
unit = arr (\\_ -> RecipeProposal [] ())
`);
  write(path.relative(kb, path.join(setup.path, 'change/Evolution.hs')), `{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import qualified Kyyn.Workspace.After.RecipeFlows.Flows as Flows
import qualified RootV1
import qualified Review
evolution :: Evolution (KnowledgeBase RootV1.Root) (KnowledgeBase RootV1.Root)
evolution = edit (Rationale "Teach review recipes" []) $ do
  createRecipe (RecipeId "review") Flows.review (Review.State [])
  createRecipe (RecipeId "unit") Flows.unit ()
`);
  console.log('Creating closed recipes through generated definition handles');
  const handle = cli(['guest', 'module', 'show', 'Kyyn.Workspace.After.RecipeFlows.Flows', '--evolution', setup.id]);
  assert.match(JSON.stringify(handle), /RecipeDefinition/);
  cli(['evolution', 'check', setup.id]);
  cli(['evolution', 'ready', setup.id]);
  cli(['evolution', 'accept', setup.id]);
  rootLocation = 'root';
  cli(['root', 'check']);
  assert.match(JSON.stringify(cli(['root', 'recipe', 'run', 'review'], 1)), /recipe.input-required/);
  assert.match(JSON.stringify(cli(['root', 'recipe', 'run', 'review', '--input', 'True'], 1)), /dhall.type/);
  console.log('Running typed recipe and freezing its state-only proposal');
  const draft = cli(['root', 'recipe', 'run', 'review', '--input', '"message-1"']).result;
  const entry = fs.readFileSync(path.join(draft.path, 'change/Evolution.hs'), 'utf8');
  assert.match(entry, /evolution = frozen/);
  assert.doesNotMatch(entry, /case |proposal.decode/);
  const proposal = fs.readFileSync(path.join(draft.path, 'change/proposal.dhall'), 'utf8');
  assert.match(proposal, /message-1/);
  assert.doesNotMatch(proposal, /curation/);
  cli(['guest', 'module', 'show', 'KyynFrozenProposal', '--evolution', draft.id]);
  // Accepted source and state remain authoritative: changing only the working
  // checkout must not affect checking; acceptance must refuse overlapping edits.
  const flowSource = fs.readFileSync(path.join(kb, 'root/src/Flows.hs'), 'utf8');
  write('root/src/Flows.hs', 'module Flows where\nreview = error "Flow must not run"\n');
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'check', draft.id]);
  assert.equal(fs.readFileSync(path.join(draft.path, 'change/proposal.dhall'), 'utf8'), proposal);
  cli(['evolution', 'ready', draft.id]);
  assert.match(JSON.stringify(cli(['evolution', 'accept', draft.id], 1)), /acceptance.overlapping-edits/);
  write('root/src/Flows.hs', flowSource);
  cli(['evolution', 'accept', draft.id]);
  assert.match(fs.readFileSync(path.join(kb, 'root/recipes/review/state.dhall'), 'utf8'), /message-1/);
  assert.match(JSON.stringify(cli(['evolution', 'show', draft.id])), /message-1/);
  cli(['root', 'check']);
  const unit = cli(['root', 'recipe', 'run', 'unit']).result;
  cli(['evolution', 'check', unit.id]);
  console.log('Typed requests, unit input, state-only freezing, discovery and acceptance passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
