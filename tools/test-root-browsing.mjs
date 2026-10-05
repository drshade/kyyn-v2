// Installed schema/collection/fact browsing: reachable types, roles/references,
// IDs/titles, Dhall payloads, accepted Git selection and draft source inspection.
// Checks corrupt-fact refusal and rejects --evolution on fact commands.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-root-browsing.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-browsing-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_COUNT: '2', GIT_CONFIG_KEY_0: 'user.name',
  GIT_CONFIG_VALUE_0: 'Browsing test', GIT_CONFIG_KEY_1: 'user.email', GIT_CONFIG_VALUE_1: 'test@example.invalid' };
function cli(args, expected = 0, json = true) {
  const result = spawnSync(executable, ['--kb', kb, ...(json ? ['--json'] : []), ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return json ? JSON.parse(result.stdout) : result.stdout;
}
function git(...args) {
  const result = spawnSync('git', ['-C', kb, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}
try {
  cli(['kb', 'init']);
  const initial = cli(['evolution', 'new', 'tasks']).result;
  const target = path.join(initial.path, 'target');
  fs.unlinkSync(path.join(target, 'src/RootV1.hs'));
  fs.writeFileSync(path.join(target, 'src/Tasks.hs'), `module Tasks where
import Kyyn.Schema
data Todo = Todo { title :: Maybe String, parent :: Maybe FactId }
data Root = Root { todos :: [Fact Todo] }
data Unreachable = Unreachable String
metadata :: SchemaMetadata
metadata = SchemaMetadata [RoleDecl "label" "Task title" Title]
  [FieldRole "Tasks.Todo" "title" "label"]
  [CollectionDecl "tasks" "todos" [("parent", "tasks")]]
`);
  for (const name of ['kb.dhall', 'src/Validate.hs']) {
    const file = path.join(target, name);
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll('RootV1', 'Tasks'));
  }
  const validatePath = path.join(target, 'src/Validate.hs');
  const validator = fs.readFileSync(validatePath, 'utf8');
  fs.writeFileSync(validatePath, 'this is not valid Haskell');
  const selection = ['--evolution', initial.id];
  const schemas = cli(['root', 'schema', 'list', ...selection]).result;
  assert(schemas.types.includes('Tasks.Todo'));
  assert(schemas.types.includes('Tasks.Root'));
  assert(!schemas.types.includes('Tasks.Unreachable'));
  assert.equal(schemas.context.evolution, initial.id);
  const schema = cli(['root', 'schema', 'show', 'Tasks.Todo', ...selection]).result;
  assert.match(schema.dhallType, /Optional Text/);
  assert.equal(schema.roles[0].affordance, 'Title');
  assert.equal(cli(['root', 'schema', 'show', 'Tasks.Unreachable', ...selection], 1).diagnostics[0].code, 'schema.type-unknown');
  assert.equal(cli(['root', 'collection', 'list', ...selection]).result.collections[0].rootField, 'todos');
  const collection = cli(['root', 'collection', 'show', 'tasks', ...selection]).result;
  assert.deepEqual(collection.references, [{ field: 'parent', collection: 'tasks' }]);
  assert.equal(collection.payloadType, 'Tasks.Todo');
  cli(['root', 'fact', 'list', 'tasks', ...selection], 2, false);
  cli(['root', 'fact', 'show', 'tasks', 'id', ...selection], 2, false);
  fs.writeFileSync(validatePath, validator);
  fs.writeFileSync(path.join(initial.path, 'change/Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified Tasks as After
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = evolve (Rationale "Track tasks" []) (onFacts (\\Before.Root -> Right
  (After.Root [Fact (FactId "some/♥ id") (After.Todo (Just "Review λ") Nothing),
               Fact (FactId "") (After.Todo Nothing (Just (FactId "some/♥ id")))])))
`);
  cli(['evolution', 'check', initial.id]);
  cli(['evolution', 'ready', initial.id]);
  cli(['evolution', 'accept', initial.id]);
  const status = git('status', '--porcelain');
  const facts = cli(['root', 'fact', 'list', 'tasks']).result;
  assert.deepEqual(facts.facts, [{ id: 'some/♥ id', title: 'Review λ' }, { id: '', title: null }]);
  assert.equal(facts.context.revision, git('rev-parse', 'HEAD').trim());
  assert.equal(facts.context.evolution, null);
  assert.match(cli(['root', 'fact', 'list', 'tasks'], 0, false), /some\/♥ id — Review λ/);
  assert.deepEqual(cli(['root', 'fact', 'show', 'tasks', 'some/♥ id']).result.value,
    { title: { tag: 'Some', value: 'Review λ' }, parent: { tag: 'None' } });
  assert.equal(cli(['root', 'fact', 'show', 'tasks', '']).result.id, '');
  assert.equal(cli(['root', 'fact', 'show', 'tasks', 'missing'], 1).diagnostics[0].code, 'fact.unknown');
  assert.equal(cli(['root', 'fact', 'list', 'missing'], 1).diagnostics[0].code, 'fact.collection-unknown');
  assert.equal(git('status', '--porcelain'), status, 'Browsing changed tracked/untracked KB files');
  fs.writeFileSync(path.join(kb, 'root/src/Tasks.hs'), 'bad working tree');
  assert(cli(['root', 'schema', 'list']).result.types.includes('Tasks.Todo'), 'Must inspect accepted Git source');
  git('restore', 'root/src/Tasks.hs');
  fs.writeFileSync(path.join(kb, 'root/facts/root.dhall'), 'False');
  git('add', 'root/facts/root.dhall');
  git('commit', '-m', 'Broken facts fixture');
  assert(cli(['root', 'schema', 'list']).result.types.includes('Tasks.Todo'));
  assert.equal(cli(['root', 'collection', 'show', 'tasks']).result.name, 'tasks');
  assert.equal(cli(['root', 'fact', 'list', 'tasks'], 1).outcome, 'Refused');
  console.log('Root browsing: source-only drafts, reachable schema, roles/references, validated facts, exact IDs, selection and refusals passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
