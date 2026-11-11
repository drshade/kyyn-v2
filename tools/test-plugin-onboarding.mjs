// Installed guide-led plugin configuration: fresh KB -> install hints -> packaged
// example -> valid draft -> accepted source -> fetch. Reinstall preserves settings.
// No provider credentials or network acquisition are used; Nix builds real guests.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-plugin-onboarding.mjs EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const repo = path.resolve(import.meta.dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-plugin-onboarding-'));
const kb = path.join(temporary, 'kb with spaces');
const env = {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Fixture', GIT_COMMITTER_NAME: 'Fixture',
  GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_EMAIL: 'fixture@example.invalid'};
function cli(...args) {
  console.error(`Plugin onboarding: ${args.join(' ')}`);
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    {cwd: temporary, env, encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024});
  assert.equal(result.status, 0, result.stderr + result.stdout);
  return JSON.parse(result.stdout).result;
}
function suggested(command) {
  assert(command.startsWith('kyyn-v2 '));
  // These generated arguments contain validated plugin/evolution identifiers;
  // --kb above preserves the selected workspace when invoked from elsewhere.
  return cli(...command.slice('kyyn-v2 '.length).split(' '));
}
try {
  cli('kb', 'init');
  const draft = cli('evolution', 'new', 'add-documents');
  const install = () => cli('plugin', 'install', '--evolution', draft.id, '--from', path.join(repo, 'plugins/local-file'));
  const config = install().configuration;
  assert.equal(config.relativeTo, 'kb');
  const file = path.join(kb, config.path);
  assert(fs.statSync(path.dirname(file)).isDirectory());
  assert(!fs.existsSync(file));
  const guide = suggested(config.guideCommand);
  const markdown = guide.markdown;
  assert.equal(typeof markdown, 'string');
  const example = markdown.match(/```dhall\n([\s\S]*?)```/)[1];
  suggested(config.schemaCommand);
  fs.mkdirSync(path.join(kb, 'documents'));
  fs.writeFileSync(path.join(kb, 'documents/notes.txt'), 'A captured document.\n');
  const authored = example.replace('/path/to/documents', 'documents');
  assert.notEqual(authored, example, 'Guide must identify the directory setting');
  fs.writeFileSync(file, authored); // No mkdir: install must prepare this path.
  install();
  assert.equal(fs.readFileSync(file, 'utf8'), authored);
  suggested(config.checkCommand);
  cli('evolution', 'ready', draft.id);
  cli('evolution', 'accept', draft.id);
  cli('evidence', 'fetch', 'local-file', 'documents');
  assert(cli('evidence', 'list', 'local-file', 'documents').items.some(item => item.id === 'notes.txt'));
  console.log('Guide-led plugin configuration, preservation, acceptance and capture passed.');
} finally {
  fs.rmSync(temporary, {recursive: true, force: true});
}
