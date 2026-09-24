import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/measure-compile-cache.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-cache-measure-'));
const kb = path.join(temporary, 'kb');
const source = path.join(temporary, 'documents');
const cache = path.join(kb, '.kyyn/compiled');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(temporary, 'gitconfig') };
function cli(args) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 180000 });
  assert.equal(result.status, 0, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
function entries() {
  return fs.readdirSync(cache).filter(name => name.endsWith('.comb')).sort()
    .map(name => [name, fs.statSync(path.join(cache, name), { bigint: true }).mtimeNs.toString()]);
}
function measure(label, args) {
  fs.rmSync(cache, { recursive: true, force: true });
  const coldStart = performance.now();
  const cold = cli(args);
  const coldMs = performance.now() - coldStart;
  const before = entries();
  assert(before.length > 0);
  const warmStart = performance.now();
  const warm = cli(args);
  const warmMs = performance.now() - warmStart;
  assert.deepEqual(entries(), before, 'Warm command rewrote compiled artifacts');
  console.log(JSON.stringify({ command: label, coldMs: Math.round(coldMs), warmMs: Math.round(warmMs), artifacts: before.length }));
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
