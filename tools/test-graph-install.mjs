// Install actual Graph source, discover contracts, accept configuration and check
// RSVP payload discovery, shared delegated scope validation and missing-secret
// failures. No live provider requests.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-graph-install-'));
const kb = path.join(temporary, 'kb');
const home = path.join(temporary, 'home');
fs.mkdirSync(home);
const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig') };
function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args], { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
try {
  git(temporary, 'config', '--global', 'user.name', 'Graph fixture');
  git(temporary, 'config', '--global', 'user.email', 'fixture@example.invalid');
  const source = path.join(temporary, 'source');
  fs.cpSync(path.join(repository, 'plugins/microsoft-graph'), source, { recursive: true });
  git(source, 'init', '-qb', 'main');
  git(source, 'add', '.');
  git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Graph fixture');
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'graph']).result;
  cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  const schema = cli(['plugin', 'connector', 'schema', 'show', 'microsoft-graph', '--evolution', draft.id]).result.schema;
  assert.match(schema, /ClientSecret/);
  assert.match(schema, /DeviceCode/);
  const configPath = path.join(draft.path, 'target/plugins/config/microsoft-graph.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, `(let Auth = < ClientSecret : { tenant : Text, clientId : Text, secretKey : Text }
    | DeviceCode : { tenant : Text, clientId : Text, tokenKey : Text, scopes : List Text } >
    let Connector = < Calendar : { auth : Auth, mailbox : Text, calendarId : Optional Text, sharedCalendar : Bool, windowStart : Text, windowEnd : Text } >
    in [ { name = "test", binding = "calendar", connector = Connector.Calendar
      { auth = Auth.ClientSecret { tenant = "fixture", clientId = "fixture", secretKey = "missing-graph-secret" }
      , mailbox = "user@example.test", calendarId = None Text, sharedCalendar = False
      , windowStart = "2026-01-01T00:00:00Z", windowEnd = "2027-01-01T00:00:00Z" } } ]) : (${schema})`);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const head = git(kb, 'rev-parse', 'HEAD');
  const descriptor = cli(['plugin', 'connector', 'show', 'microsoft-graph', 'test']).result;
  assert.equal(descriptor.fetchOptionsType, null);
  const method = cli(['plugin', 'connector', 'method', 'show', 'microsoft-graph', 'test', 'event']).result;
  assert.match(method.resultType, /bodyPreview/);
  assert.match(method.resultType, /responseStatus\s*:\s*Optional/);
  assert.match(method.resultType, /\bstatus\s*:\s*Optional/);
  assert.match(method.resultType, /\bresponse\s*:\s*Text/);
  assert.match(method.resultType, /\btime\s*:\s*Optional Text/);
  for (const args of [['plugin', 'connector', 'login', 'microsoft-graph', 'test'], ['evidence', 'fetch', 'microsoft-graph', 'test']]) {
    const result = cli(args, 1);
    assert(result.diagnostics.some(d => d.message.includes('Missing secret missing-graph-secret')), JSON.stringify(result));
  }
  const delegated = cli(['evolution', 'new', 'delegated-scopes']).result;
  const delegatedPath = path.join(delegated.path, 'target/plugins/config/microsoft-graph.dhall');
  const applicationConfig = fs.readFileSync(delegatedPath, 'utf8');
  function delegatedConfig(scopes) {
    return applicationConfig.replace(
      'Auth.ClientSecret { tenant = "fixture", clientId = "fixture", secretKey = "missing-graph-secret" }',
      `Auth.DeviceCode { tenant = "fixture", clientId = "fixture", tokenKey = "missing-graph-secret", scopes = ${scopes} }`
    ).replace('sharedCalendar = False', 'sharedCalendar = True');
  }
  fs.writeFileSync(delegatedPath, delegatedConfig('[ "Calendars.Read", "Mail.Read" ]'));
  const missingScope = cli(['evolution', 'check', delegated.id], 1);
  assert.match(JSON.stringify(missingScope), /Calendars.Read.Shared/);
  fs.writeFileSync(delegatedPath, delegatedConfig('[ "https://graph.microsoft.com/Calendars.Read.Shared", "Mail.Read" ]'));
  cli(['evolution', 'check', delegated.id]);
  fs.writeFileSync(delegatedPath, delegatedConfig('[ "https://graph.microsoft.com/calendars.readwrite.shared" ]'));
  cli(['evolution', 'check', delegated.id]);
  fs.writeFileSync(delegatedPath, delegatedConfig('[ "Calendars.Read.Shared" ]').replace('sharedCalendar = True', 'sharedCalendar = False'));
  cli(['evolution', 'check', delegated.id]);
  assert.equal(git(kb, 'rev-parse', 'HEAD'), head);
  console.log('Installed Graph plugin: schema, validation, acceptance, method discovery and missing-secret paths passed (no provider calls).');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
