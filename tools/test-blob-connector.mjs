// Installed loopback acquisition, generated BlobRef codecs, two-instance composed
// tool paths and failed-fetch cleanup. No external network or credentials.
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
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-blob-journey-'));
const kb = path.join(temporary, 'kb');
const taskHome = path.join(temporary, 'home');
fs.mkdirSync(taskHome);
const env = { ...process.env, HOME: taskHome, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(taskHome, '.gitconfig') };
const git = async (cwd, ...args) => (await execute('git', args, { cwd, env })).stdout.trim();
let failAfter = false;
let first = Buffer.from([0, 255, 1, 254]);
const second = Buffer.from('second attachment');
const server = http.createServer((request, response) => {
  if (request.url.endsWith('/finish')) {
    response.statusCode = failAfter ? 500 : 200;
    response.end('finished');
  } else response.end(request.url.startsWith('/one/') ? first : second);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
async function cli(args, expected = 0) {
  let result;
  try { result = await execute(executable, ['--kb', kb, '--json', ...args], { cwd: temporary, env, timeout: 120000 }); }
  catch (error) { assert.equal(error.code, expected, error.stderr + error.stdout); result = error; }
  if (expected === 0) assert.equal(result.code, undefined, result.stderr);
  return JSON.parse(result.stdout);
}
try {
  await git(temporary, 'config', '--global', 'user.name', 'Blob fixture');
  await git(temporary, 'config', '--global', 'user.email', 'fixture@example.invalid');
  const source = path.join(temporary, 'source');
  fs.cpSync(path.join(repository, 'tools/fixtures/blob-plugin'), source, { recursive: true });
  await git(source, 'init', '-qb', 'main');
  await git(source, 'add', '.');
  await git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture');
  await cli(['kb', 'init']);
  const draft = (await cli(['evolution', 'new', 'blobs'])).result;
  await cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  const schema = (await cli(['plugin', 'connector', 'schema', 'show', 'blob-fixture', '--evolution', draft.id])).result.schema;
  const config = path.join(draft.path, 'target/plugins/config/blob-fixture.dhall');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, `([${['one', 'two'].map(name => `{ name = "${name}", binding = "${name}", connector =
    < Files : { endpoint : Text } >.Files { endpoint = "http://127.0.0.1:${server.address().port}/${name}" } }`).join(',')}]) : (${schema})`);
  const manifestPath = path.join(draft.path, 'target/kb.dhall');
  const manifest = fs.readFileSync(manifestPath, 'utf8');
  const empty = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  assert(manifest.includes(empty));
  fs.writeFileSync(manifestPath, manifest.replace(empty,
    '[{ name = "both", description = "Two captured attachments", implementation = "Helpers.both", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
  fs.writeFileSync(path.join(draft.path, 'target/src/Helpers.hs'), `module Helpers where
import Data.Text (Text)
import Kyyn.Plugin (BlobRef, FetchError)
import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_blob_fixture.Files as Files
type Input = Text
type Output = [BlobRef]
both :: Input -> Tool (Either FetchError Output)
both key = do
  one <- Files.attachment Connectors.one key
  two <- Files.attachment Connectors.two key
  pure (sequence [one,two])
`);
  await cli(['evolution', 'check', draft.id]);
  await cli(['evolution', 'ready', draft.id]);
  await cli(['evolution', 'accept', draft.id]);
  for (const name of ['one', 'two']) await cli(['evidence', 'fetch', 'blob-fixture', name]);
  const both = (await cli(['root', 'tool', 'execute', 'both', '--input', '"file"'])).result;
  assert.equal(both.blobs.length, 2);
  assert.deepEqual(fs.readFileSync(both.blobs[0].path), first);
  assert.deepEqual(fs.readFileSync(both.blobs[1].path), second);
  assert.notEqual(path.dirname(both.blobs[0].path), path.dirname(both.blobs[1].path));
  const before = (await cli(['evidence', 'list', 'blob-fixture', 'one'])).result;
  const filesBefore = fs.readdirSync(path.dirname(both.blobs[0].path));
  failAfter = true;
  first = Buffer.from('unpublished replacement');
  await cli(['evidence', 'fetch', 'blob-fixture', 'one'], 1);
  assert.deepEqual((await cli(['evidence', 'list', 'blob-fixture', 'one'])).result, before);
  assert.deepEqual(fs.readdirSync(path.dirname(both.blobs[0].path)), filesBefore);
  assert.deepEqual(fs.readFileSync(both.blobs[0].path), Buffer.from([0, 255, 1, 254]));
  console.log('Installed blobs: generated codecs, binary capture, composed instance paths and failed-fetch cleanup passed.');
} finally {
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(temporary, { recursive: true, force: true });
}
