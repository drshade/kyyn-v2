import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-connector-fetch.mjs INSTALLED_EXECUTABLE');
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
  // The emitted schema is directly usable as the configuration's annotation.
  fs.writeFileSync(configPath, `(${configuration([['sales', sales], ['support', support]])}) : (${schema})\n`);
  assert.equal(cli(['plugin', 'connector', 'list', 'local-file', '--evolution', draft.id]).result.connectors.length, 2);
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.unknown');
  console.log('Checking and accepting two configured instances...');
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const accepted = git(checkout, 'rev-parse', 'HEAD');
  assert.equal(cli(['evidence', 'history', 'list', 'local-file', 'sales'], 1).diagnostics[0].code, 'evidence.history-unavailable');
  const first = fetch('sales');
  const other = fetch('support');
  assert.equal(changes('sales').changes.length, 3);
  assert.equal(changes('support').changes.length, 1);
  fs.writeFileSync(path.join(sales, 'updated.txt'), 'Changed sales evidence λ');
  fs.unlinkSync(path.join(sales, 'removed.txt'));
  fs.writeFileSync(path.join(sales, 'added.txt'), 'New sales evidence');
  const second = fetch('sales');
  const delta = changes('sales', ['--since', first, '--at', second]);
  assert.deepEqual(delta.changes.map(change => [change.id, change.kind]).sort(),
    [['added.txt', 'New'], ['removed.txt', 'Removed'], ['updated.txt', 'Updated']]);
  for (const change of delta.changes) {
    assert.equal(change.fetch, second);
    assert.equal(change.previous, first);
    assert.equal(change.citation.connector, 'sales');
    assert(change.citation.references.includes(path.join(sales, change.id)));
  }
  assert.deepEqual(history('sales').fetches.map(entry => entry.id), [first, second]);
  assert.deepEqual(history('sales', ['--at', first]).fetches.map(entry => entry.id), [first]);
  assert.equal(history('support').selection.fetch, other);
  assert(!JSON.stringify([history('sales'), delta]).includes('sales evidence'));
  const third = fetch('sales');
  assert.deepEqual(changes('sales', ['--since', second, '--at', third]).changes, []);
  fs.renameSync(sales, sales + '-offline');
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.fetch-failed');
  assert.equal(history('sales').selection.fetch, third);
  fs.renameSync(sales + '-offline', sales);
  fs.writeFileSync(path.join(sales, 'bad.bin'), Buffer.from([0xff]));
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'sales'], 1).diagnostics[0].code, 'plugin.fetch-failed');
  assert.equal(history('sales').selection.fetch, third);
  assert.equal(cli(['evidence', 'fetch', 'local-file', 'draft-only'], 1).diagnostics[0].code, 'plugin.instance-unknown');
  assert.equal(cli(['evidence', 'history', 'list', 'local-file', 'sales', '--at', 'missing'], 1).diagnostics[0].code, 'evidence.history-unavailable');
  const evidenceDirectory = path.join(kb, '.kyyn/evidence');
  const stored = fs.readdirSync(evidenceDirectory).map(name => fs.readFileSync(path.join(evidenceDirectory, name, 'state.dhall'), 'utf8')).join('\n');
  assert(stored.includes('Original sales evidence'), 'CLI-produced history discarded the original payload');
  assert(stored.includes('Changed sales evidence'), 'Current evidence was not persisted');
  assert.equal(git(checkout, 'rev-parse', 'HEAD'), accepted);
  assert.equal(git(checkout, 'ls-files', 'knowledge/.kyyn/evidence'), '');
  console.log('Installed nested-KB schema/config acceptance, two-instance fetches, retained history, payload-free deltas and failure preservation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
