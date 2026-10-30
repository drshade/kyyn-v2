// Installed production Meetings reader/registration with synthetic loopback
// acquisition. Exercises KB-tool text composition, strict UTF-8, missing/corrupt
// blobs and no-network reads. No pilot data, credentials or model requests.
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
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-transcript-'));
const kb = path.join(temporary, 'kb');
const taskHome = path.join(temporary, 'home');
fs.mkdirSync(taskHome);
const env = { ...process.env, HOME: taskHome, GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: path.join(taskHome, '.gitconfig'), KYYN_TIMINGS: '1' };
const git = async (cwd, ...args) => (await execute('git', args, { cwd, env })).stdout.trim();
const vtt = 'WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\n<v Synthetic Speaker>LOCAL_ONLY_TRANSCRIPT 雪 🦋</v>\r\n';
let bytes = Buffer.from(vtt);
let requests = 0;
const server = http.createServer((_, response) => { requests++; response.end(bytes); });
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
async function cli(args, expected = 0) {
  let result;
  try { result = await execute(executable, ['--kb', kb, '--json', ...args], { cwd: temporary, env, timeout: 120000 }); }
  catch (error) { assert.equal(error.code, expected, error.stderr + error.stdout); result = error; }
  if (expected === 0) assert.equal(result.code, undefined, result.stderr);
  assert(!result.stderr.includes('LOCAL_ONLY_TRANSCRIPT'), 'transcript entered diagnostics/timings');
  if (expected !== 0) assert(!result.stdout.includes('LOCAL_ONLY_TRANSCRIPT'), 'transcript entered an error result');
  return JSON.parse(result.stdout);
}
try {
  await git(temporary, 'config', '--global', 'user.name', 'Transcript fixture');
  await git(temporary, 'config', '--global', 'user.email', 'fixture@example.invalid');
  const source = path.join(temporary, 'source');
  fs.cpSync(path.join(repository, 'tools/fixtures/transcript-plugin'), source, { recursive: true });
  for (const file of ['Plugin.hs', 'Types.hs', 'Meetings/Types.hs', 'Meetings/Read.hs']) {
    const destination = path.join(source, 'src/MicrosoftGraph', file);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(repository, 'plugins/microsoft-graph/src/MicrosoftGraph', file), destination);
  }
  await git(source, 'init', '-qb', 'main');
  await git(source, 'add', '.');
  await git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Synthetic transcript fixture');
  await cli(['kb', 'init']);
  const draft = (await cli(['evolution', 'new', 'transcript-reader'])).result;
  await cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  const schema = (await cli(['plugin', 'connector', 'schema', 'show', 'transcript-fixture', '--evolution', draft.id])).result.schema;
  const config = path.join(draft.path, 'target/plugins/config/transcript-fixture.dhall');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, `([{ name = "meetings", binding = "meetings", connector =
    < Meetings : { endpoint : Text } >.Meetings { endpoint = "http://127.0.0.1:${server.address().port}/transcript" } }]) : (${schema})`);
  const manifestPath = path.join(draft.path, 'target/kb.dhall');
  const manifest = fs.readFileSync(manifestPath, 'utf8');
  const empty = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  assert(manifest.includes(empty));
  fs.writeFileSync(manifestPath, manifest.replace(empty,
    '[{ name = "redactFixture", description = "Synthetic local redaction composition", implementation = "Helpers.redactFixture", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
  fs.writeFileSync(path.join(draft.path, 'target/src/Helpers.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Helpers where
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin (FetchError)
import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_transcript_fixture.Meetings as Meetings
type Input = Text
type Output = Text
redactFixture :: Input -> Tool (Either FetchError Output)
redactFixture key = fmap (fmap (Text.replace "Synthetic Speaker" "Person-1"))
  (Meetings.transcript Connectors.meetings key)
`);
  await cli(['evolution', 'check', draft.id]);
  await cli(['evolution', 'ready', draft.id]);
  await cli(['evolution', 'accept', draft.id]);
  const head = await git(kb, 'rev-parse', 'HEAD');
  assert.equal(requests, 0, 'discovery executed acquisition');
  const method = (await cli(['plugin', 'connector', 'method', 'show', 'transcript-fixture', 'meetings', 'transcript'])).result;
  assert.equal(method.inputType.trim(), 'Text');
  assert.equal(method.resultType.trim(), 'Text');
  await cli(['evidence', 'fetch', 'transcript-fixture', 'meetings']);
  const read = (key, expected = 0) => cli(['root', 'tool', 'execute', 'redactFixture', '--input', JSON.stringify(key)], expected);
  assert.equal((await read('transcript')).result, vtt.replace('Synthetic Speaker', 'Person-1'));
  for (const [key, message] of [['missing', 'No captured meeting artifact'], ['truncated', 'truncated'], ['attendance', 'attendance report']]) {
    const refused = await read(key, 1);
    assert(refused.diagnostics.some(d => d.message.includes(message)), JSON.stringify(refused));
  }
  const artifact = (await cli(['evidence', 'show', 'transcript-fixture', 'meetings', 'transcript'])).result;
  const blobPath = artifact.blobs[0].path;
  const original = fs.readFileSync(blobPath);
  const corrupt = Buffer.from(original);
  corrupt[0] ^= 1; // Same length: require hash validation, not just a size check.
  fs.writeFileSync(blobPath, corrupt);
  await read('transcript', 1);
  fs.writeFileSync(blobPath, original);
  assert.equal((await read('transcript')).result, vtt.replace('Synthetic Speaker', 'Person-1'));
  fs.unlinkSync(blobPath);
  await read('transcript', 1);
  assert.equal(requests, 1, 'captured reads fetched missing data');
  await cli(['evidence', 'clear', 'transcript-fixture', 'meetings']);
  bytes = Buffer.from([86, 84, 84, 255]);
  await cli(['evidence', 'fetch', 'transcript-fixture', 'meetings']);
  const invalid = await read('transcript', 1);
  assert(invalid.diagnostics.some(d => d.message.includes('not valid UTF-8')));
  assert.equal(requests, 2);
  assert.equal(await git(kb, 'rev-parse', 'HEAD'), head);
  console.log('Installed Meetings transcript: local tool composition, exact VTT, refusals, blob integrity and no-network reads passed.');
} finally {
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(temporary, { recursive: true, force: true });
}
