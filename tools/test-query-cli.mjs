// Installed query discovery/execution over accepted code, typed and unit arguments.
// Disposable KB; no live providers or output writes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-query-cli-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Query fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Query fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, expected = 0, json = true) {
  const result = spawnSync(executable, ['--kb', kb, ...(json ? ['--json'] : []), ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return json ? JSON.parse(result.stdout) : result.stdout;
}
try {
  cli(['kb', 'init']);
  assert.deepEqual(cli(['root', 'query', 'list']).result.queries, []);
  const draft = cli(['evolution', 'new', 'reporting']).result;
  const target = path.join(draft.path, 'target');
  fs.writeFileSync(path.join(target, 'src/Reporting.hs'), `module Reporting where
import Kyyn.Schema
import KyynQueryBindings (Query)
type Unit = ()
type Input = String
type Output = String
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
hello :: Unit -> Query Output
hello () = pure "Hello from the KB"
echo :: Input -> Query Output
echo = pure
`);
  const manifest = path.join(target, 'kb.dhall');
  const original = fs.readFileSync(manifest, 'utf8');
  const empty = 'queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }';
  assert(original.includes(empty));
  const declaration = (name, input) => `{ name = "${name}", description = "${name} query", implementation = "Reporting.${name}", inputType = "Reporting.${input}", inputMetadata = "Reporting.metadata", resultType = "Reporting.Output", resultMetadata = "Reporting.metadata" }`;
  fs.writeFileSync(manifest, original.replace(empty, `queries = [${declaration('hello', 'Unit')}, ${declaration('echo', 'Input')}]`));
  assert.deepEqual(cli(['root', 'query', 'list']).result.queries, []);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  assert.deepEqual(cli(['root', 'query', 'list']).result.queries.map(q => q.name), ['hello', 'echo']);
  assert.equal(cli(['root', 'query', 'show', 'hello']).result.inputType.trim(), '{}');
  assert.equal(cli(['root', 'query', 'show', 'echo']).result.inputType.trim(), 'Text');
  assert.equal(cli(['root', 'query', 'execute', 'hello']).result, 'Hello from the KB');
  assert.equal(cli(['root', 'query', 'execute', 'echo', '--input', '"Snow 雪"']).result, 'Snow 雪');
  assert.match(cli(['root', 'query', 'execute', 'hello'], 0, false), /"Hello from the KB"/);
  assert.equal(cli(['root', 'query', 'execute', 'echo'], 1).diagnostics[0].code, 'query.arguments');
  assert.equal(cli(['root', 'query', 'execute', 'echo', '--input', 'True'], 1).diagnostics[0].code, 'dhall.type');
  assert.equal(cli(['root', 'query', 'show', 'missing'], 1).diagnostics[0].code, 'query.unknown');
  console.log('Installed query discovery, accepted revision, unit/typed arguments and Dhall/JSON execution passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
