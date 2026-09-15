import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const configurationSmoke = process.argv[3] === '--configuration-smoke';
const readSmoke = process.argv[3] === '--read-smoke';
if (process.argv.length !== 3 && !(process.argv.length === 4 && (configurationSmoke || readSmoke)))
  throw new Error('Usage: node tools/test-connector-fetch.mjs INSTALLED_EXECUTABLE [--configuration-smoke|--read-smoke]');
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
const history = (name, options = []) => cli(['evidence', 'history', 'list', 'local-file', name, ...options]).result;
const changes = (name, options = []) => cli(['evidence', 'change', 'list', 'local-file', name, ...options]).result;
const content = (name, id, expected = 0) => cli(['plugin', 'connector', 'method', 'execute', 'local-file', name,
  'content', '--input', JSON.stringify(id)], expected);
function main() {
try {
  git(temporary, 'config', '--global', 'user.name', 'Evidence fixture');
  git(temporary, 'config', '--global', 'user.email', 'evidence@example.invalid');
  git(checkout, 'init', '-q', '-b', 'main');
  fs.cpSync(path.join(repository, 'plugins/local-file'), source, { recursive: true });
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
  const configPath = path.join(draft.path, 'target/plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, 'not valid Dhall');
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
  assert.equal(cli(['plugin', 'connector', 'list', 'local-file', '--evolution', draft.id]).result.connectors.length, 2);
  if (readSmoke || !configurationSmoke) {
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
  assert.equal(cli(['evidence', 'history', 'list', 'local-file', 'sales'], 1).diagnostics[0].code, 'evidence.not-fetched');
  if (readSmoke || !configurationSmoke)
    assert.equal(content('sales', 'updated.txt', 1).diagnostics[0].code, 'evidence.not-fetched');
  const first = fetch('sales');
  if (configurationSmoke) {
    assert.equal(history('sales').selection.fetch, first);
    assert(fs.existsSync(path.join(kb, '.kyyn/evidence')));
    assert(!fs.existsSync(path.join(checkout, '.kyyn/evidence')));
    assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
    const clear = ['--runtime', path.join(temporary, 'missing-runtime'), 'evidence', 'clear', 'local-file', 'sales'];
    assert.equal(cli(clear).result.cleared, true);
    assert.equal(cli(clear).result.cleared, false);
    console.log('Installed nested-KB bad-config refusal, repair, acceptance, fetch and history scope smoke passed.');
    return;
  }
  const other = fetch('support');
  if (readSmoke || !configurationSmoke) {
    fs.renameSync(sales, sales + '-offline');
    assert.equal(content('sales', 'updated.txt').result, 'Original sales evidence Ω');
    assert.equal(content('support', 'ticket.txt').result, 'Independent support evidence');
    assert.equal(content('sales', 'ticket.txt', 1).diagnostics[0].code, 'plugin.read-failed');
    const badInput = cli(['plugin', 'connector', 'method', 'execute', 'local-file', 'sales', 'content', '--input', 'True'], 1);
    assert.equal(badInput.diagnostics[0].code, 'dhall.type');
    assert.equal(cli(['plugin', 'connector', 'method', 'show', 'local-file', 'sales', 'missing'], 1).diagnostics[0].code, 'plugin.method-unknown');
    fs.renameSync(sales + '-offline', sales);
  }
  assert.equal(changes('sales').changes.length, 3);
  assert.equal(changes('support').changes.length, 1);
  fs.writeFileSync(path.join(sales, 'updated.txt'), 'Changed sales evidence λ');
  fs.unlinkSync(path.join(sales, 'removed.txt'));
  fs.writeFileSync(path.join(sales, 'added.txt'), 'New sales evidence');
  const second = fetch('sales');
  if (readSmoke || !configurationSmoke) {
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
  const delta = changes('sales', ['--since', first]);
  assert.equal(delta.selection.fetch, second);
  assert.deepEqual(delta.changes.map(change => [change.id, change.kind]).sort(),
    [['added.txt', 'New'], ['removed.txt', 'Removed'], ['updated.txt', 'Updated']]);
  for (const change of delta.changes) {
    assert.equal(change.fetch, second);
    assert.equal(change.previous, first);
    assert.equal(typeof change.fingerprint, 'string');
    assert(change.fingerprint.length > 0);
    assert.equal(change.citation.connector, 'sales');
    assert(change.citation.references.includes(path.join(sales, change.id)));
  }
  assert.deepEqual(history('sales').fetches.map(entry => entry.id), [first, second]);
  assert.equal(history('support').selection.fetch, other);
  assert(!JSON.stringify([history('sales'), delta]).includes('sales evidence'));
  const third = fetch('sales');
  assert.deepEqual(changes('sales', ['--since', second]).changes, []);
  fs.renameSync(sales, sales + '-offline');
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.fetch-failed');
  assert.equal(history('sales').selection.fetch, third);
  fs.renameSync(sales + '-offline', sales);
  fs.writeFileSync(path.join(sales, 'bad.bin'), Buffer.from([0xff]));
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.fetch-failed');
  assert.equal(history('sales').selection.fetch, third);
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'draft-only'], 1).diagnostics[0].code, 'plugin.instance-unknown');
  assert.equal(cli(['evidence', 'change', 'list', 'local-file', 'sales', '--since', 'missing'], 1).diagnostics[0].code, 'evidence.cursor-unavailable');
  const evidenceDirectory = path.join(kb, '.kyyn/evidence');
  const stored = fs.readdirSync(evidenceDirectory, { withFileTypes: true }).filter(entry => entry.isDirectory())
    .map(entry => fs.readFileSync(path.join(evidenceDirectory, entry.name, 'state.dhall'), 'utf8')).join('\n');
  assert(!stored.includes('Original sales evidence'), 'Superseded payload was retained');
  assert(!stored.includes('Removed sales evidence'), 'Removed payload was retained');
  assert(stored.includes('Changed sales evidence'), 'Current evidence was not persisted');
  fs.unlinkSync(path.join(sales, 'bad.bin'));
  const salesState = path.join(evidenceDirectory, 'local-file-73616c6573', 'state.dhall');
  fs.writeFileSync(salesState, '{ broken = True }');
  const invalid = cli(['evidence', 'history', 'list', 'local-file', 'sales'], 1);
  assert.equal(invalid.diagnostics[0].code, 'evidence.invalid-data');
  assert.match(invalid.diagnostics[0].message, /clear.*fetch/i);
  assert.equal(cli(['--runtime', path.join(temporary, 'missing-runtime'), 'evidence', 'clear', 'local-file', 'sales']).result.cleared, true);
  assert(!fs.existsSync(path.dirname(salesState)));
  assert.equal(cli(['--runtime', path.join(temporary, 'missing-runtime'), 'evidence', 'clear', 'local-file', 'sales']).result.cleared, false);
  assert.equal(history('support').selection.fetch, other);
  assert.equal(cli(['evidence', 'history', 'list', 'local-file', 'sales'], 1).diagnostics[0].code, 'evidence.not-fetched');
  const refetched = fetch('sales');
  assert.equal(history('sales').selection.fetch, refetched);
  assert.equal(cli(['evidence', 'change', 'list', 'local-file', 'sales', '--since', third], 1).diagnostics[0].code, 'evidence.cursor-unavailable');
  assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
  assert.equal(git(checkout, 'ls-files', 'knowledge/.kyyn/evidence'), '');
  console.log('Installed nested-KB config acceptance, latest payloads, change markers, scoped clear/refetch and failure preservation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
}
main();
