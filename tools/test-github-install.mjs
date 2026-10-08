// Installed GitHub package: source installation, guide, schema/method discovery,
// configuration validation and acceptance. Missing-secret fetch makes no network call.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const executable = path.resolve(process.argv[2]);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-github-install-'));
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
  git(temporary, 'config', '--global', 'user.name', 'GitHub fixture');
  git(temporary, 'config', '--global', 'user.email', 'fixture@example.invalid');
  const source = path.join(temporary, 'source');
  fs.cpSync(path.join(repository, 'plugins/github'), source, { recursive: true });
  git(source, 'init', '-qb', 'main');
  git(source, 'add', '.');
  git(source, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'GitHub fixture');
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'github']).result;
  cli(['plugin', 'install', '--evolution', draft.id, '--from', source]);
  const schema = cli(['plugin', 'connector', 'schema', 'show', 'github', '--evolution', draft.id]).result.schema;
  for (const field of ['repositoryUrl', 'branch', 'since', 'tokenSecret']) assert.match(schema, new RegExp(field));
  assert.match(JSON.stringify(cli(['plugin', 'guide', 'github', '--evolution', draft.id])), /review summaries/);
  const configPath = path.join(draft.path, 'target/plugins/config/github.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  const config = `(let Connector = < Repository : { repositoryUrl : Text, branch : Optional Text, since : Optional Text, tokenSecret : Optional Text } >
    in [ { name = "project", binding = "project", connector = Connector.Repository
      { repositoryUrl = "https://github.com/acme/project", branch = None Text
      , since = Some "2026-01-01T00:00:00Z", tokenSecret = Some "missing-github-token" } } ]) : (${schema})`;
  fs.writeFileSync(configPath, config.replace('2026-01-01', '2026-02-30'));
  assert.match(JSON.stringify(cli(['evolution', 'check', draft.id], 1)), /github.since/);
  fs.writeFileSync(configPath, config);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const head = git(kb, 'rev-parse', 'HEAD');
  const descriptor = cli(['plugin', 'connector', 'show', 'github', 'project']).result;
  assert.equal(descriptor.fetchOptionsType, null);
  for (const method of ['item', 'issue', 'pullRequest', 'commit']) {
    const found = cli(['plugin', 'connector', 'method', 'show', 'github', 'project', method]).result;
    assert.match(found.inputType, /Text/);
    assert(!found.resultType.includes('patch'));
    if (method === 'commit') assert.match(found.resultType, /filesComplete/);
    if (method === 'pullRequest') assert.match(found.resultType, /reviews/);
  }
  const refused = cli(['evidence', 'fetch', 'github', 'project'], 1);
  assert.match(JSON.stringify(refused), /Missing GitHub token secret: missing-github-token/);
  assert.equal(git(kb, 'rev-parse', 'HEAD'), head);
  console.log('Installed GitHub: guide, schema/typed methods, validation, acceptance and missing-secret refusal passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
