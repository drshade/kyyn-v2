import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execute = promisify(execFile);
const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-network-'));
const kb = path.join(temporary, 'kb');
const home = path.join(temporary, 'home');
fs.mkdirSync(home);
const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig') };
const git = async (cwd, ...args) => (await execute('git', args, { cwd, env })).stdout.trim();
const calls = [];
let payload = 'first 雪';
let failFetch = false;
const server = http.createServer((request, response) => {
  calls.push(request.url);
  if (request.url === '/login') response.end('private-fixture-token');
  else {
    assert.equal(request.headers.authorization, 'private-fixture-token');
    response.statusCode = failFetch ? 500 : 200;
    response.end(payload);
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
async function cli(args, expected = 0, selected = kb) {
  let output;
  try { output = await execute(executable, ['--kb', selected, '--json', ...args], { cwd: temporary, env, timeout: 120000 }); }
  catch (error) { assert.equal(error.code, expected, error.stderr); output = error; }
  if (expected === 0) assert.equal(output.code, undefined, output.stderr);
  assert(!output.stdout.includes('private-fixture-token'));
  assert(!output.stderr.includes('private-fixture-token'));
  return { ...output, value: JSON.parse(output.stdout) };
}
try {
  await git(temporary, 'config', '--global', 'user.name', 'Network fixture');
  await git(temporary, 'config', '--global', 'user.email', 'fixture@example.invalid');
  const source = path.join(temporary, 'source');
  fs.cpSync(path.join(repository, 'tools/fixtures/network-plugin'), source, { recursive: true });
  await git(source, 'init', '-qb', 'main');
  await git(source, 'add', '.');
  await git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture');
  await cli(['kb', 'init']);
  const draft = (await cli(['evolution', 'new', 'network'])).value.result;
  await cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  const schema = (await cli(['plugin', 'connector', 'schema', 'show', 'network-fixture', '--evolution', draft.id])).value.result.schema;
  const configPath = path.join(draft.path, 'target/plugins/config/network-fixture.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, `([ { name = "test", binding = "test", connector =
    < Network : { endpoint : Text, secretKey : Text } >.Network
      { endpoint = "http://127.0.0.1:${server.address().port}", secretKey = "test-token" } } ]) : (${schema})`);
  await cli(['evolution', 'check', draft.id]);
  await cli(['evolution', 'ready', draft.id]);
  await cli(['evolution', 'accept', draft.id]);
  assert.deepEqual(calls, [], 'preparation executed network/authentication');
  const head = await git(kb, 'rev-parse', 'HEAD');
  const missing = await cli(['evidence', 'fetch', 'network-fixture', 'test'], 1);
  assert(missing.value.diagnostics.some(d => d.code === 'plugin.fetch-failed'));
  assert.deepEqual(calls, []);
  const loggedIn = await cli(['plugin', 'connector', 'login', 'network-fixture', 'test']);
  assert.match(loggedIn.stderr, /Fixture login instructions/);
  const fetch = () => cli(['evidence', 'fetch', 'network-fixture', 'test']);
  await fetch();
  payload = 'second 雪';
  await fetch();
  const latest = (await cli(['evidence', 'list', 'network-fixture', 'test'])).value.result;
  assert.equal(latest.items[0].fingerprint, payload);
  failFetch = true;
  await cli(['evidence', 'fetch', 'network-fixture', 'test'], 1);
  assert.deepEqual((await cli(['evidence', 'list', 'network-fixture', 'test'])).value.result, latest);
  assert.equal(await git(kb, 'rev-parse', 'HEAD'), head);
  assert.match(await git(kb, 'check-ignore', '.kyyn/secrets/test-token.dhall'), /test-token/);
  console.log('Installed network connector: explicit login, local secrets, latest evidence and failed-fetch atomicity passed.');
} finally {
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(temporary, { recursive: true, force: true });
}
