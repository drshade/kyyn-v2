// Install Salesforce source through the actual CLI; exercise schema discovery,
// config validation/acceptance, captured-method discovery and missing-secret
// failures. No provider requests or live credentials.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-salesforce-install-'));
const kb = path.join(temporary, 'kb');
const home = path.join(temporary, 'home');
fs.mkdirSync(home);
const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig') };
function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
}
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args], { cwd: temporary, env, encoding: 'utf8', timeout: 180000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
try {
  git(temporary, 'config', '--global', 'user.name', 'Salesforce fixture');
  git(temporary, 'config', '--global', 'user.email', 'fixture@example.invalid');
  const source = path.join(temporary, 'source');
  fs.cpSync(path.join(repository, 'plugins/salesforce'), source, { recursive: true });
  git(source, 'init', '-qb', 'main');
  git(source, 'add', '.');
  git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Salesforce fixture');
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'salesforce']).result;
  cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  const schema = cli(['plugin', 'connector', 'schema', 'show', 'salesforce', '--evolution', draft.id]).result.schema;
  for (const field of ['Query', 'DeviceCode', 'ClientSecret', 'apiVersion', 'idField']) assert(schema.includes(field));
  const configPath = path.join(draft.path, 'target/plugins/config/salesforce.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  const config = `let Auth = < ClientSecret : { clientId : Text, secretKey : Text } | DeviceCode : { clientId : Text, tokenKey : Text } >
    let Connector = < Query : { instanceUrl : Text, auth : Auth, apiVersion : Text, query : Text, idField : Text } >
    in [ { name = "pipeline", binding = "pipeline", connector = Connector.Query
      { instanceUrl = "https://example.my.salesforce.com"
      , auth = Auth.ClientSecret { clientId = "client", secretKey = "missing-salesforce-secret" }
      , apiVersion = "v62.0", query = "SELECT Id, Amount FROM Opportunity", idField = "Id" } } ]`;
  fs.writeFileSync(configPath, `(${config}) : (${schema})`);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const descriptor = cli(['plugin', 'connector', 'show', 'salesforce', 'pipeline']).result;
  assert.equal(descriptor.fetchOptionsType, null);
  const method = cli(['plugin', 'connector', 'method', 'show', 'salesforce', 'pipeline', 'record']).result;
  assert.match(method.resultType, /recordId\s*:\s*Text/);
  assert.match(method.resultType, /json\s*:\s*Text/);
  for (const args of [['plugin', 'connector', 'login', 'salesforce', 'pipeline'], ['evidence', 'fetch', 'salesforce', 'pipeline']]) {
    assert(cli(args, 1).diagnostics.some(d => d.message.includes('Missing secret missing-salesforce-secret')));
  }
  const invalid = cli(['evolution', 'new', 'salesforce-validation']).result;
  const invalidPath = path.join(invalid.path, 'target/plugins/config/salesforce.dhall');
  for (const [from, to, code] of [
    ['https://example.my.salesforce.com', 'http://example.my.salesforce.com', 'salesforce.origin'],
    ['https://example.my.salesforce.com', 'https://example.my.salesforce.com/path', 'salesforce.origin'],
    ['v62.0', '../v62.0', 'salesforce.version'],
    ['SELECT Id, Amount FROM Opportunity', 'DELETE FROM Account', 'salesforce.query'],
    ['idField = "Id"', 'idField = ""', 'salesforce.id-field'],
    ['missing-salesforce-secret', '../invalid', 'salesforce.secret'],
  ]) {
    fs.writeFileSync(invalidPath, config.replace(from, to));
    assert(cli(['evolution', 'check', invalid.id], 1).diagnostics.some(d => d.code === code));
  }
  fs.writeFileSync(invalidPath, config.replace('Auth.ClientSecret { clientId = "client", secretKey = "missing-salesforce-secret" }', 'Auth.DeviceCode { clientId = "client", tokenKey = "salesforce-refresh" }'));
  cli(['evolution', 'check', invalid.id]);
  console.log('Installed Salesforce: schema, validation, acceptance, record discovery and missing-secret failures passed (no provider calls).');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
