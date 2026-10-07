// Installed acquisition: typed configuration, independent instances, latest payloads,
// one latest-fetch summary, refresh/removal, clear/refetch and failed-fetch preservation.
// --options-smoke covers option contracts; --read-smoke covers captured methods;
// --tool-smoke covers a registered helper composing sources. Uses disposable files.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const configurationSmoke = process.argv[3] === '--configuration-smoke';
const readSmoke = process.argv[3] === '--read-smoke';
const toolSmoke = process.argv[3] === '--tool-smoke';
const optionsSmoke = process.argv[3] === '--options-smoke';
const methodChecks = readSmoke || (!configurationSmoke && !toolSmoke && !optionsSmoke);
const toolChecks = toolSmoke || (!configurationSmoke && !readSmoke && !optionsSmoke);
if (process.argv.length !== 3 && !(process.argv.length === 4 && (configurationSmoke || readSmoke || toolSmoke || optionsSmoke)))
  throw new Error('Usage: node tools/test-connector-fetch.mjs INSTALLED_EXECUTABLE [--configuration-smoke|--read-smoke|--tool-smoke|--options-smoke]');
const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-connector-fetch-'));
const checkout = path.join(temporary, 'checkout');
const kb = path.join(checkout, 'knowledge');
const source = path.join(temporary, 'source');
const sales = path.join(temporary, 'sales');
const support = path.join(temporary, 'support');
const taskHome = path.join(temporary, 'home');
for (const directory of [checkout, sales, support, taskHome]) fs.mkdirSync(directory);
const env = { ...process.env, HOME: taskHome, XDG_CONFIG_HOME: path.join(temporary, 'xdg'),
  GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(taskHome, '.gitconfig') };
function git(directory, ...args) {
  const result = spawnSync('git', ['-C', directory, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, JSON.stringify(result));
  return result.stdout.trim();
}
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
const config = directory => `{ directory = ${JSON.stringify(directory)}, recursive = True }`;
const instance = (name, directory) => `{ name = "${name}", binding = "${name}", connector = Connector.Folder ${config(directory)} }`;
const configuration = entries => 'let Connector = < Folder : { directory : Text, recursive : Bool } >\nin [ '
  + entries.map(([name, directory]) => instance(name, directory)).join(', ') + ' ]\n';
const fetch = name => cli(['evidence', 'fetch', 'local-file', name]).result.fetch;
const counts = summary => [summary.added, summary.updated, summary.removed];
const current = name => cli(['evidence', 'list', 'local-file', name]).result;
function fileFingerprint(filename) {
  const framed = bytes => {
    const length = Buffer.alloc(8);
    length.writeBigUInt64BE(BigInt(bytes.length));
    return Buffer.concat([length, bytes]);
  };
  return createHash('sha256').update(Buffer.concat([
    framed(Buffer.from(filename, 'utf8')), framed(fs.readFileSync(filename))])).digest('hex');
}
const content = (name, id, expected = 0) => cli(['plugin', 'connector', 'method', 'execute', 'local-file', name,
  'content', '--input', JSON.stringify(id)], expected);
function main() {
try {
  git(temporary, 'config', '--global', 'user.name', 'Evidence fixture');
  git(temporary, 'config', '--global', 'user.email', 'evidence@example.invalid');
  git(checkout, 'init', '-q', '-b', 'main');
  fs.cpSync(path.join(repository, 'plugins/local-file'), source, { recursive: true });
  if (optionsSmoke) {
    const declaration = path.join(source, 'src/LocalFile/Plugin.hs');
    fs.writeFileSync(declaration, fs.readFileSync(declaration, 'utf8')
      .replace('fetchOptionsType = Nothing', 'fetchOptionsType = Just "LocalFile.Types.FetchOptions"'));
    fs.appendFileSync(path.join(source, 'src/LocalFile/Types.hs'), '\ndata FetchOptions = FetchOptions { skip :: Bool }\n');
    const implementation = path.join(source, 'src/LocalFile/Folder.hs');
    fs.writeFileSync(implementation, fs.readFileSync(implementation, 'utf8')
      .replace('fetch ::', 'fetchDefault ::').replace('fetch (Schema.', 'fetchDefault (Schema.') + `
fetch :: Schema.FolderConfig -> Maybe Schema.FetchOptions -> EvidenceSnapshot Schema.Document
  -> Acquisition (Either FetchError [EvidenceChange Schema.Document])
fetch config options snapshot = case options of
  Just (Schema.FetchOptions True) -> pure (Right [])
  _ -> fetchDefault config snapshot
`);
  }
  git(source, 'init', '-q', '-b', 'main');
  git(source, 'add', '.');
  git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Plugin fixture');
  fs.writeFileSync(path.join(sales, 'updated.txt'), 'Original sales evidence Ω');
  fs.writeFileSync(path.join(sales, 'removed.txt'), 'Removed sales evidence');
  fs.writeFileSync(path.join(sales, 'unchanged.txt'), 'Stable sales evidence');
  fs.writeFileSync(path.join(support, 'ticket.txt'), 'Independent support evidence');
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'configure-local-folders']).result;
  cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  if (optionsSmoke) {
    const installedDeclaration = path.join(draft.path, 'target/plugins/packages/local-file/source/src/LocalFile/Plugin.hs');
    const declared = fs.readFileSync(installedDeclaration, 'utf8');
    fs.writeFileSync(installedDeclaration, declared.replace(/^.*fetchOptionsType.*\n/m, ''));
    const outdated = cli(['plugin', 'connector', 'schema', 'show', 'local-file', '--evolution', draft.id], 1);
    assert(outdated.diagnostics.some(diagnostic => diagnostic.code === 'plugin.preparation'
      && diagnostic.message.includes('fetchOptionsType')), JSON.stringify(outdated));
    fs.writeFileSync(installedDeclaration, declared);
  }
  const configPath = path.join(draft.path, 'target/plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, 'not valid Dhall');
  if (toolChecks) {
    const started = performance.now();
    assert(cli(['--git', '/not-a-git-executable', 'guest', 'module', 'show', 'Kyyn.Schema', '--evolution', draft.id]).result.symbols.length > 0);
    console.log(`Fixed SDK discovery with broken plugin config: ${Math.round(performance.now() - started)} ms`);
    const partial = cli(['guest', 'module', 'list', '--evolution', draft.id]);
    assert(partial.result.modules.includes('Kyyn.Schema'));
    assert(partial.diagnostics.some(diagnostic => diagnostic.code === 'guest.bindings-unavailable'));
  }
  const schema = cli(['plugin', 'connector', 'schema', 'show', 'local-file', '--evolution', draft.id]).result.schema;
  assert.match(schema, /directory/);
  assert.match(schema, /recursive/);
  assert.match(schema, /Folder/);
  fs.writeFileSync(configPath, configuration([['sales', 'relative-folder'], ['support', support]]));
  const rejected = cli(['evolution', 'check', draft.id], 1);
  assert(rejected.diagnostics.some(diagnostic => diagnostic.code === 'local-file.directory'
    && diagnostic.message.includes('local-file/sales')), JSON.stringify(rejected));
  // The emitted schema is directly usable as the configuration's annotation.
  fs.writeFileSync(configPath, `(${configuration([['sales', sales], ['support', support]])}) : (${schema})\n`);
  if (toolChecks) {
    const discoveryStarted = performance.now();
    const modules = cli(['guest', 'module', 'list', '--evolution', draft.id]).result.modules;
    console.log(`Generated local-file guest discovery: ${Math.round(performance.now() - discoveryStarted)} ms`);
    assert(modules.includes('Kyyn.Plugins.P_local_file.Folder'));
    assert(!modules.includes('KyynToolCalls'));
    const bindings = cli(['guest', 'module', 'show', 'Kyyn.Connectors', '--evolution', draft.id]).result.symbols;
    for (const name of ['Tool', 'sales', 'support']) assert(bindings.some(symbol => symbol.name === name));
    const proxy = cli(['guest', 'module', 'show', 'Kyyn.Plugins.P_local_file.Folder', '--evolution', draft.id]).result.symbols;
    assert(proxy.some(symbol => symbol.name === 'content' && /Instance/.test(symbol.declaration)));
    const manifestPath = path.join(draft.path, 'target/kb.dhall');
    const manifest = fs.readFileSync(manifestPath, 'utf8');
    const emptyTools = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
    assert(manifest.includes(emptyTools));
    fs.writeFileSync(manifestPath, manifest.replace(emptyTools,
      '[{ name = "bulk", description = "Read captured folders", implementation = "Helpers.bulk", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
    fs.writeFileSync(path.join(draft.path, 'target/src/Helpers.hs'), `module Helpers where
import Data.Text (Text)
import Kyyn.Plugin (FetchError)
import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_local_file.Folder as Files
type Input = [Text]
type Output = [Text]
bulk :: Input -> Tool (Either FetchError Output)
bulk ids = do
  sales <- mapM (Files.content Connectors.sales) ids
  support <- Files.content Connectors.support "ticket.txt"
  pure (sequence (sales ++ [support]))
`);
    assert.deepEqual(cli(['root', 'tool', 'list', '--evolution', draft.id]).result.tools.map(t => t.name), ['bulk']);
    const descriptor = cli(['root', 'tool', 'show', 'bulk', '--evolution', draft.id]).result;
    assert.equal(descriptor.inputType.trim(), 'List Text');
    assert.equal(descriptor.resultType.trim(), 'List Text');
  }
  assert.equal(cli(['plugin', 'connector', 'list', 'local-file', '--evolution', draft.id]).result.connectors.length, 2);
  if (methodChecks) {
    const methods = cli(['plugin', 'connector', 'method', 'list', 'local-file', 'sales', '--evolution', draft.id]).result.methods;
    assert.deepEqual(methods.map(method => method.name), ['content']);
    assert.match(methods[0].description, /latest fetched text/);
    const contract = cli(['plugin', 'connector', 'method', 'show', 'local-file', 'sales', 'content', '--evolution', draft.id]).result;
    assert.equal(contract.inputType.trim(), 'Text');
    assert.equal(contract.resultType.trim(), 'Text');
  }
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.unknown');
  console.log('Checking and accepting two configured instances...');
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const accepted = git(checkout, 'rev-parse', 'HEAD');
  assert.equal(cli(['evidence', 'list', 'local-file', 'sales'], 1).diagnostics[0].code, 'evidence.not-fetched');
  if (optionsSmoke) {
    const descriptor = cli(['plugin', 'connector', 'show', 'local-file', 'sales']).result;
    assert.match(descriptor.fetchOptionsType, /skip\s*:\s*Bool/);
    cli(['evidence', 'fetch', 'local-file', 'sales', '--options', 'True'], 1);
    assert.equal(cli(['evidence', 'list', 'local-file', 'sales'], 1).diagnostics[0].code, 'evidence.not-fetched');
    cli(['evidence', 'fetch', 'local-file', 'sales', '--options', 'let flag = True in { skip = flag }']);
    assert.deepEqual(current('sales').items, []);
    const scoped = current('sales').latest;
    assert.deepEqual(counts(scoped), [0, 0, 0]);
    assert.match(scoped.options, /skip\s*=\s*True/);
    assert(!scoped.options.includes('let flag'));
    fetch('sales');
    assert.equal(current('sales').items.length, 3);
    assert.equal(current('sales').latest.options, null);
    assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
    console.log('Typed fetch options: discovery, refusal, guest defaults and Dhall latest summary passed.');
    return;
  }
  assert.equal(cli(['plugin', 'connector', 'show', 'local-file', 'sales']).result.fetchOptionsType, null);
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales', '--options', '{}'], 1)
    .diagnostics[0].code, 'plugin.fetch-options-unsupported');
  if (methodChecks)
    assert.equal(content('sales', 'updated.txt', 1).diagnostics[0].code, 'evidence.not-fetched');
  const first = fetch('sales');
  const listedFirst = current('sales');
  assert.equal(listedFirst.selection.fetch, first);
  assert.equal(listedFirst.selection.instance, 'sales');
  assert.deepEqual(Object.keys(listedFirst.selection).sort(), ['fetch', 'instance', 'plugin']);
  for (const item of listedFirst.items) {
    assert.match(item.fingerprint, /^[0-9a-f]{64}$/);
    assert.equal(item.fingerprint, fileFingerprint(path.join(sales, item.id)));
  }
  assert.deepEqual(listedFirst.items.map(item => item.id).sort(), ['removed.txt', 'unchanged.txt', 'updated.txt']);
  assert(listedFirst.items.every(item => item.fingerprint.length > 0 && Object.keys(item).sort().join(',') === 'fingerprint,id'));
  assert(!JSON.stringify(listedFirst).includes('sales evidence'));
  if (configurationSmoke) {
    assert.equal(current('sales').selection.fetch, first);
    const restarted = cli(['evidence', 'fetch', 'local-file', 'sales', '--restart-sync']);
    assert(restarted.diagnostics.some(d => d.code === 'plugin.sync-stateless'));
    assert.deepEqual(current('sales').items, listedFirst.items);
    assert.deepEqual(counts(current('sales').latest), [0, 0, 0]);
    assert(fs.existsSync(path.join(kb, '.kyyn/evidence')));
    assert(!fs.existsSync(path.join(checkout, '.kyyn/evidence')));
    assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
    const clear = ['--runtime', path.join(temporary, 'missing-runtime'), 'evidence', 'clear', 'local-file', 'sales'];
    assert.equal(cli(clear).result.cleared, true);
    assert.equal(cli(clear).result.cleared, false);
    console.log('Installed nested-KB bad-config refusal, repair, acceptance, fetch and snapshot scope smoke passed.');
    return;
  }
  const other = fetch('support');
  if (toolChecks) {
    assert(cli(['guest', 'module', 'list']).result.modules.includes('Kyyn.Plugins.P_local_file.Folder'));
    fs.renameSync(sales, sales + '-offline');
    const args = ['root', 'tool', 'execute', 'bulk', '--input', '["updated.txt", "unchanged.txt"]'];
    assert.deepEqual(cli(args).result, ['Original sales evidence Ω', 'Stable sales evidence', 'Independent support evidence']);
    const human = spawnSync(executable, ['--kb', kb, ...args], { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
    assert.equal(human.status, 0, JSON.stringify(human));
    assert.match(human.stdout, /Original sales evidence Ω/);
    assert.match(human.stdout, /Independent support evidence/);
    assert.equal(cli(['root', 'tool', 'execute', 'bulk', '--input', 'True'], 1).diagnostics[0].code, 'dhall.type');
    assert.equal(cli(['root', 'tool', 'execute', 'bulk', '--input', '["missing.txt"]'], 1).diagnostics[0].code, 'tool.failed');
    assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
    console.log('Installed KB helper discovery, evolution acceptance, two-instance captured reads and Dhall/JSON results passed.');
    if (toolSmoke) return;
    fs.renameSync(sales + '-offline', sales);
  }
  if (methodChecks) {
    fs.renameSync(sales, sales + '-offline');
    assert.equal(content('sales', 'updated.txt').result, 'Original sales evidence Ω');
    assert.equal(content('support', 'ticket.txt').result, 'Independent support evidence');
    assert.equal(content('sales', 'ticket.txt', 1).diagnostics[0].code, 'plugin.read-failed');
    const badInput = cli(['plugin', 'connector', 'method', 'execute', 'local-file', 'sales', 'content', '--input', 'True'], 1);
    assert.equal(badInput.diagnostics[0].code, 'dhall.type');
    assert.equal(cli(['plugin', 'connector', 'method', 'show', 'local-file', 'sales', 'missing'], 1).diagnostics[0].code, 'plugin.method-unknown');
    fs.renameSync(sales + '-offline', sales);
  }
  assert.deepEqual(counts(current('sales').latest), [3, 0, 0]);
  assert.deepEqual(counts(current('support').latest), [1, 0, 0]);
  fs.writeFileSync(path.join(sales, 'updated.txt'), 'Changed sales evidence λ');
  fs.unlinkSync(path.join(sales, 'removed.txt'));
  fs.writeFileSync(path.join(sales, 'added.txt'), 'New sales evidence');
  const second = fetch('sales');
  const listedSecond = current('sales');
  assert.equal(listedSecond.selection.fetch, second);
  assert.deepEqual(listedSecond.items.map(item => item.id).sort(), ['added.txt', 'unchanged.txt', 'updated.txt']);
  const fingerprint = (listing, id) => listing.items.find(item => item.id === id).fingerprint;
  assert.equal(fingerprint(listedFirst, 'unchanged.txt'), fingerprint(listedSecond, 'unchanged.txt'));
  assert.notEqual(fingerprint(listedFirst, 'updated.txt'), fingerprint(listedSecond, 'updated.txt'));
  assert.deepEqual(current('support').items.map(item => item.id), ['ticket.txt']);
  if (methodChecks) {
    assert.equal(content('sales', 'updated.txt').result, 'Changed sales evidence λ');
    assert.equal(content('sales', 'removed.txt', 1).diagnostics[0].code, 'plugin.read-failed');
    const human = spawnSync(executable, ['--kb', kb, 'plugin', 'connector', 'method', 'execute',
      'local-file', 'support', 'content', '--input', '"ticket.txt"'], { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
    assert.equal(human.status, 0, JSON.stringify(human));
    assert.equal(human.stdout.trim(), '"Independent support evidence"');
    assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
    if (readSmoke) {
      console.log('Installed typed method discovery, captured content, refresh/removal, independent instances, input refusal and Dhall output passed.');
      return;
    }
  }
  assert.equal(listedSecond.latest.id, second);
  assert.deepEqual(counts(listedSecond.latest), [1, 1, 1]);
  assert.equal(current('support').selection.fetch, other);
  assert(!JSON.stringify(listedSecond).includes('sales evidence'));
  const third = fetch('sales');
  assert.deepEqual(counts(current('sales').latest), [0, 0, 0]);
  fs.renameSync(sales, sales + '-offline');
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.fetch-failed');
  assert.equal(current('sales').selection.fetch, third);
  fs.renameSync(sales + '-offline', sales);
  fs.writeFileSync(path.join(sales, 'bad.bin'), Buffer.from([0xff]));
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.fetch-failed');
  assert.equal(current('sales').selection.fetch, third);
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'draft-only'], 1).diagnostics[0].code, 'plugin.instance-unknown');
  const evidenceDirectory = path.join(kb, '.kyyn/evidence');
  const stored = fs.readdirSync(evidenceDirectory, { withFileTypes: true }).filter(entry => entry.isDirectory())
    .map(entry => fs.readFileSync(path.join(evidenceDirectory, entry.name, 'state.dhall'), 'utf8')).join('\n');
  assert(!stored.includes('history'), 'Acquisition history was retained');
  assert(!stored.includes(first), 'First fetch summary was retained');
  assert(!stored.includes(second), 'Second fetch summary was retained');
  assert(!stored.includes('Original sales evidence'), 'Superseded payload was retained');
  assert(!stored.includes('Removed sales evidence'), 'Removed payload was retained');
  assert(stored.includes('Changed sales evidence'), 'Current evidence was not persisted');
  fs.unlinkSync(path.join(sales, 'bad.bin'));
  const salesState = path.join(evidenceDirectory, 'local-file-73616c6573', 'state.dhall');
  fs.writeFileSync(salesState, '{ broken = True }');
  const invalid = cli(['evidence', 'list', 'local-file', 'sales'], 1);
  assert.equal(invalid.diagnostics[0].code, 'evidence.invalid-data');
  assert.match(invalid.diagnostics[0].message, /clear.*fetch/i);
  assert.equal(cli(['--runtime', path.join(temporary, 'missing-runtime'), 'evidence', 'clear', 'local-file', 'sales']).result.cleared, true);
  assert(!fs.existsSync(path.dirname(salesState)));
  assert.equal(cli(['--runtime', path.join(temporary, 'missing-runtime'), 'evidence', 'clear', 'local-file', 'sales']).result.cleared, false);
  assert.equal(current('support').selection.fetch, other);
  assert.equal(cli(['evidence', 'list', 'local-file', 'sales'], 1).diagnostics[0].code, 'evidence.not-fetched');
  const refetched = fetch('sales');
  assert.equal(current('sales').selection.fetch, refetched);
  assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
  assert.equal(git(checkout, 'ls-files', 'knowledge/.kyyn/evidence'), '');
  console.log('Installed nested-KB config acceptance, latest payloads, latest summary, scoped clear/refetch and failure preservation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
}
main();
