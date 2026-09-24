import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const timings = process.argv[3] === '--timings';
assert(process.argv.length === 3 || (process.argv.length === 4 && timings),
  'Usage: node tools/measure-compile-cache.mjs INSTALLED_EXECUTABLE [--timings]');
const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-cache-measure-'));
const kb = path.join(temporary, 'kb');
const source = path.join(temporary, 'documents');
const cache = path.join(kb, '.kyyn/compiled');
const inspected = path.join(kb, '.kyyn/inspected');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(temporary, 'gitconfig') };
let lastTimings = [];
function cli(args, timed = false) {
  const selectedEnv = { ...env };
  delete selectedEnv.KYYN_TIMINGS;
  if (timed) selectedEnv.KYYN_TIMINGS = '1';
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env: selectedEnv, encoding: 'utf8', timeout: 180000 });
  assert.equal(result.status, 0, JSON.stringify({ args, ...result }));
  assert(!result.stdout.includes('[kyyn timing]'), 'Timing leaked into stdout');
  lastTimings = result.stderr.split('\n').filter(line => line.startsWith('[kyyn timing]')).map(line => {
    const match = /^\[kyyn timing\] ([a-z-]+) (.+) ([0-9.]+)ms$/.exec(line);
    assert(match, line);
    return { step: match[1], label: match[2], ms: Number(match[3]) };
  });
  if (timed) assert.equal(lastTimings.filter(event => event.step === 'total').length, 1);
  else assert.equal(lastTimings.length, 0, 'Timing emitted while disabled');
  return JSON.parse(result.stdout);
}
function entries(directory, suffix) {
  return fs.readdirSync(directory).filter(name => name.endsWith(suffix)).sort()
    .map(name => [name, fs.statSync(path.join(directory, name), { bigint: true }).mtimeNs.toString()]);
}
function measure(label, args) {
  fs.rmSync(cache, { recursive: true, force: true });
  fs.rmSync(inspected, { recursive: true, force: true });
  const coldStart = performance.now();
  const cold = cli(args, timings);
  if (timings) assert(lastTimings.some(event => event.step === 'compile-miss'));
  const coldMs = performance.now() - coldStart;
  const before = entries(cache, '.comb');
  const inspections = entries(inspected, '.dhall');
  assert(before.length > 0);
  assert(inspections.length > 0, 'Use an installed build with embedded revision');
  const warmStart = performance.now();
  const warm = cli(args, timings);
  const warmMs = performance.now() - warmStart;
  assert.deepEqual(entries(cache, '.comb'), before, 'Warm command rewrote compiled artifacts');
  assert.deepEqual(entries(inspected, '.dhall'), inspections, 'Warm command rewrote inspection results');
  console.log(JSON.stringify({ command: label, coldMs: Math.round(coldMs), warmMs: Math.round(warmMs), artifacts: before.length }));
  if (timings) {
    for (const step of ['inspection-hit', 'compile-hit', 'plugin-registration', 'guest-execution'])
      assert(lastTimings.some(event => event.step === step), `Missing ${step}`);
    assert(!lastTimings.some(event => event.step === 'compile-miss'), 'Warm run compiled again');
    assert(!lastTimings.some(event => event.step === 'inspection'), 'Warm run inspected again');
    console.log(JSON.stringify({ command: label, warmTimings: lastTimings }));
  }
  return [cold,warm];
}
try {
  fs.mkdirSync(kb);
  fs.mkdirSync(source);
  fs.writeFileSync(path.join(source, 'message.txt'), 'Please reply to this message.');
  fs.writeFileSync(env.GIT_CONFIG_GLOBAL, '[user]\nname = Cache fixture\nemail = fixture@example.invalid\n');
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'local-file-judgement']).result;
  cli(['plugin', 'install', '--evolution', draft.id, '--from', path.join(repository, 'plugins/local-file')]);
  const target = path.join(draft.path, 'target');
  const config = path.join(target, 'plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, `let Connector = < Folder : { directory : Text, recursive : Bool } >
in [{ name = "documents", binding = "documents", connector = Connector.Folder { directory = ${JSON.stringify(source)}, recursive = True } }]`);
  const manifest = path.join(target, 'kb.dhall');
  const empty = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  const contents = fs.readFileSync(manifest, 'utf8');
  assert(contents.includes(empty));
  fs.writeFileSync(manifest, contents.replace(empty,
    '[{ name = "assess", description = "Read and judge a document", implementation = "Helpers.assess", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
  fs.writeFileSync(path.join(target, 'src/Helpers.hs'), `module Helpers where
import Kyyn.Plugin (FetchError)
import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_local_file.Folder as Files
import Kyyn.Judgement
type Input = String
type Output = String
assess :: Input -> Tool (Either FetchError Output)
assess name = do
  captured <- Files.content Connectors.documents name
  case captured of
    Left failure -> pure (Left failure)
    Right text -> do
      answer <- judge (Context text) (ask (yesNo "Does this request a reply?" describe))
      pure (Right (text ++ " | " ++ either judgementFailureMessage show answer))
  where describe yes = if yes then "Reply requested" else "No reply requested"
`);
  if (timings) {
    cli(['guest', 'module', 'show', 'Kyyn.Judgement', '--evolution', draft.id], true);
    assert(lastTimings.some(event => event.step === 'api-inspection' && event.label.includes('Kyyn.Judgement')));
    cli(['guest', 'module', 'show', 'Kyyn.Judgement', '--evolution', draft.id], true);
    assert(lastTimings.some(event => event.step === 'api-inspection-hit'));
    assert(!lastTimings.some(event => event.step === 'api-inspection'));
  }
  measure('evolution check', ['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  cli(['evidence', 'fetch', 'local-file', 'documents']);
  const [cold,warm] = measure('root tool execute', ['root', 'tool', 'execute', 'assess', '--input', '"message.txt"']);
  assert.equal(cold.result, warm.result);
  assert.match(warm.result, /Please reply to this message/);
  assert.match(warm.result, /JEV_TOKEN/);
  const status = spawnSync('git', ['-C', kb, 'status', '--porcelain'], { env, encoding: 'utf8' });
  assert.equal(status.status, 0, status.stderr);
  assert.equal(status.stdout, '');
  console.log('Warm artifacts unchanged; local-file read and typed missing-secret judgement preserved. No live provider contacted.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
