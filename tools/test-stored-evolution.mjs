// Installed target-owned migration: old source cannot compile; a stable module
// name changes fact and closed-recipe shapes in one evolution. Covers scaffold,
// discovery, independent projection, persisted report reload and acceptance.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-stored-evolution-'));
const kb = path.join(temporary, 'kb');
const fixture = path.resolve('tools/fixtures/target-evolution-guest');
const env = {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Stored evolution fixture', GIT_COMMITTER_NAME: 'Stored evolution fixture',
  GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_EMAIL: 'test@example.invalid'};
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    {cwd: temporary, env, encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024});
  assert.equal(result.status, expected, JSON.stringify({args, ...result}));
  return JSON.parse(result.stdout).result;
}
function refusal(args) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    {cwd: temporary, env, encoding: 'utf8', timeout: 600000});
  assert.equal(result.status, 1, JSON.stringify(result));
  return JSON.stringify(JSON.parse(result.stdout));
}
function write(name, value) {
  const file = path.join(kb, name);
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file, value);
}
function git(...args) {
  const result = spawnSync('git', ['-C', kb, ...args], {env, encoding:'utf8'});
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
try {
  cli(['kb', 'init']);
  const root = path.join(kb, 'root');
  const manifest = fs.readFileSync(path.join(root, 'kb.dhall'),'utf8').replaceAll('Schema.metadata','Annotations.metadata');
  write('root/kb.dhall', manifest);
  write('root/src/Schema.hs', 'module Schema where\nold source cannot compile\n');
  write('root/src/Flows.hs', 'module Flows where\nold source cannot compile\n');
  write('root/facts/root.dhall','{=}');
  write('root/facts/items/index.dhall','["one"]');
  write('root/facts/items/one.dhall','{ id = "one", value = { amount = +7 } }');
  write('root/recipes.dhall', 'let Recipe = < OpenAgent : { instructions : Text, stateType : Text } | ClosedAgent : { flow : Text } > in [{ id = "weekly", value = Recipe.ClosedAgent { flow = "Flows.review" } }]');
  git('add','root'); git('commit','-qm','Fixture with missing lifetime');
  const missingLifetime = refusal(['root','recipe','list']);
  assert.match(missingLifetime, /recipes\.dhall/);
  assert.match(missingLifetime, /lifetime/);
  const method = '< OpenAgent : { lifetime : < Ordinary | Interactive : { children : List { recipe : Text, flow : Text } } >, instructions : Text, stateType : Text } | ClosedAgent : { lifetime : < Ordinary | Interactive : { children : List { recipe : Text, flow : Text } } >, flow : Text } >';
  const definition = (id, methodValue, stateType) => `{ id = "${id}", value = ${method}.${methodValue.startsWith('ClosedAgent') ? `ClosedAgent { lifetime = < Ordinary | Interactive : { children : List { recipe : Text, flow : Text } } >.Ordinary, flow = ${methodValue.slice(12)} }` : `OpenAgent { lifetime = < Ordinary | Interactive : { children : List { recipe : Text, flow : Text } } >.Ordinary, instructions = "Obsolete", stateType = "${stateType}" }`} }`;
  write('root/recipes.dhall', '[' + [definition('weekly','ClosedAgent "Flows.review"',''),
    definition('obsolete','ClosedAgent "Missing.obsolete"',''),definition('notAFlow','ClosedAgent "Flows.oldFlow"',''),
    definition('noContract','OpenAgent "Obsolete"','Flows.OldState')].join(',') + ']');
  write('root/recipes/weekly/state.dhall','{ count = +4 }');
  for (const name of ['obsolete','notAFlow','noContract']) write(`root/recipes/${name}/state.dhall`,'{=}');
  git('add','root'); git('commit','-qm','Uncompilable historical source with structurally valid stored data');
  const base = git('rev-parse','HEAD');
  const draft = cli(['evolution','new','migrate stored data','--input-types']);
  assert.equal(fs.existsSync(path.join(draft.path,'before')),false);
  assert.match(fs.readFileSync(path.join(draft.path,'change/Input/Collection001.hs'),'utf8'),/amount :: Integer/);
  for (const name of ['Schema.hs','Flows.hs','Annotations.hs']) fs.copyFileSync(path.join(fixture,'src',name),path.join(draft.path,'target/src',name));
  fs.cpSync(path.join(fixture,'.kyyn-change/Input'),path.join(draft.path,'change/Input'),{recursive:true});
  fs.copyFileSync(path.join(fixture,'.kyyn-change/Evolution.hs'),path.join(draft.path,'change/Evolution.hs'));
  const modules = cli(['guest','module','list','--evolution',draft.id]).modules;
  assert(modules.includes('Kyyn.Workspace.Target'));
  assert(!modules.includes('Kyyn.Workspace.Before'));
  cli(['evolution','check',draft.id]);
  assert.equal(git('rev-parse','HEAD'),base);
  const report = cli(['evolution','show',draft.id]).report;
  assert.equal(report.steps.filter(s=>s.origin==='TargetProjection').length,1);
  assert(report.steps.some(s=>s.changes.some(c=>c.kind==='Field' && c.name==='total')));
  cli(['evolution','ready',draft.id]);
  assert.equal(cli(['evolution','accept',draft.id]).accepted,true);
  assert.deepEqual(cli(['evolution','show',draft.id]).report,report);
  assert.deepEqual(cli(['root','fact','show','items','one']).value,{amount:'7',note:'migrated'});
  assert.equal(cli(['root','recipe','list']).recipes.length,3);
  cli(['root','check']);
  const interactive = cli(['root','recipe','show','conversation']);
  assert.equal(interactive.recipe.lifetime.tag, 'Interactive');
  cli(['root','recipe','describe','conversation']);
  cli(['root','recipe','run','conversation'], 1);
  const removed = cli(['evolution','new','remove referenced child']);
  fs.writeFileSync(path.join(removed.path,'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import qualified Schema

evolution :: Evolution Schema.Root
evolution = prepare (retireRecipe (Rationale "Remove child" []) (RecipeId "conversation")) mempty
`);
  const dangling = refusal(['evolution','check',removed.id]);
  assert.match(dangling, /coordinator/);
  assert.match(dangling, /conversation/);
  const replay = cli(['root','recipe','run','weekly']);
  cli(['evolution','check',replay.id]);
  console.log('Stored migration, input scaffold, stable target names, closed state, archive, acceptance and running the migrated recipe passed.');
} finally {
  fs.rmSync(temporary,{recursive:true,force:true});
}
