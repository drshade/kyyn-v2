// Installed query -> local-file sink journey: contracts, preview, UTF-8 publication,
// configured and override paths, rejected writes, binding/type failures. No live services.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const executable = fs.realpathSync(process.argv[2]);
const repository = fs.realpathSync(process.argv[3] || '.');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-output-cli-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Output fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Output fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 180000 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
try {
  cli(['kb', 'init']);
  assert.deepEqual(cli(['root', 'output', 'list']).result.outputs, []);
  const draft = cli(['evolution', 'new', 'file-output']).result;
  const target = path.join(draft.path, 'target');
  cli(['plugin', 'install', '--evolution', draft.id, '--from', repository, '--path', 'plugins/local-file']);
  fs.writeFileSync(path.join(target, 'src/Reporting.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Reporting where
import Data.Text (Text)
import Kyyn.Schema
import KyynQueryBindings (Query)
type Input = Text
type Output = Text
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
page :: Input -> Query Output
page title = pure ("<!doctype html><title>" <> title <> "</title><h1>雪</h1>")
`);
  const manifest = path.join(target, 'kb.dhall');
  const original = fs.readFileSync(manifest, 'utf8');
  const empty = 'queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }';
  assert(original.includes(empty));
  const withoutOutputs = original.replace(/, outputs = \[\] : List \{ name : Text, description : Text, query : Text, sink : \{ plugin : Text, instanceName : Text, method : Text \} \}/, '');
  fs.writeFileSync(manifest, withoutOutputs.replace(empty, `queries = [{ name = "page", description = "HTML page", implementation = "Reporting.page", inputType = "Reporting.Input", inputMetadata = "Reporting.metadata", resultType = "Reporting.Output", resultMetadata = "Reporting.metadata" }]
  , outputs = [{ name = "page", description = "Publish HTML", query = "page", sink = { plugin = "local-file", instanceName = "website", method = "publish" } }]`));
  const schema = cli(['plugin', 'connector', 'schema', 'show', 'local-file', '--evolution', draft.id]);
  // Obtain the whole advertised union, including both source and sink variants.
  assert.match(JSON.stringify(schema.result), /File/);
  const configPath = path.join(target, 'plugins/config/local-file.dhall');
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, `let Connector = < Folder : { directory : Text, recursive : Bool } | File : { path : Text } >
in [{ name = "website", binding = "website", connector = Connector.File { path = "published/index.html" } }]`);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  assert.equal(cli(['root', 'output', 'list']).result.outputs[0].name, 'page');
  const description = cli(['root', 'output', 'show', 'page']).result;
  assert.equal(description.inputType.trim(), 'Text');
  assert.match(description.optionsType, /pathOverride/);
  assert.equal(description.configuration.path, 'published/index.html');
  const preview = cli(['root', 'output', 'preview', 'page', '--input', '"Architecture"']).result;
  assert.match(preview.content, /<h1>雪<\/h1>/);
  assert(!fs.existsSync(path.join(kb, 'published')));
  const publication = cli(['root', 'output', 'publish', 'page', '--input', '"Architecture"']).result;
  assert.equal(publication.publication, 'Acknowledged');
  assert.equal(publication.result, path.join(kb, 'published/index.html'));
  assert.equal(fs.readFileSync(publication.result, 'utf8'), preview.content);
  const override = cli(['root', 'output', 'publish', 'page', '--input', '"Override"', '--options', '{ pathOverride = Some "alternate/page.html" }']).result;
  assert.equal(override.result, path.join(kb, 'alternate/page.html'));
  assert.match(fs.readFileSync(override.result, 'utf8'), /Override/);
  const absolute = path.join(temporary, 'outside.html');
  cli(['root', 'output', 'publish', 'page', '--input', '"Absolute"', '--options', `{ pathOverride = Some "${absolute}" }`]);
  assert.match(fs.readFileSync(absolute, 'utf8'), /Absolute/);
  const before = fs.readFileSync(publication.result, 'utf8');
  assert.equal(cli(['root', 'output', 'publish', 'page', '--input', 'True'], 1).diagnostics[0].code, 'dhall.type');
  assert.equal(cli(['root', 'output', 'publish', 'page', '--input', '"X"', '--options', 'True'], 1).diagnostics[0].code, 'dhall.type');
  assert.equal(fs.readFileSync(publication.result, 'utf8'), before);
  const rejected = cli(['root', 'output', 'publish', 'page', '--input', '"X"', '--options', '{ pathOverride = Some "" }'], 1);
  assert.equal(rejected.result.publication, 'RejectedByDestination');
  // Every invocation rerenders; no retained approval token or prepared-output cache.
  fs.writeFileSync(absolute, 'external contents');
  fs.symlinkSync(absolute, path.join(kb, 'symlink.html'));
  cli(['root', 'output', 'publish', 'page', '--input', '"Symlink"', '--options', '{ pathOverride = Some "symlink.html" }']);
  assert(!fs.lstatSync(path.join(kb, 'symlink.html')).isSymbolicLink());
  assert.equal(fs.readFileSync(absolute, 'utf8'), 'external contents');
  assert.equal(fs.statSync(path.join(kb, 'symlink.html')).mode & 0o777, 0o666 & ~process.umask());
  fs.writeFileSync(path.join(kb, 'blocked'), 'parent is a file');
  assert.equal(cli(['root', 'output', 'publish', 'page', '--input', '"Blocked"', '--options', '{ pathOverride = Some "blocked/page.html" }'], 1).result.publication, 'RejectedByDestination');
  const timings = [];
  for (let n = 0; n < 3; n++) {
    const start = performance.now();
    cli(['root', 'query', 'execute', 'page', '--input', '"Timing"']);
    timings.push(Math.round(performance.now() - start));
  }
  console.log(`Warm query with source+sink plugin and output binding (ms): ${timings.join(', ')}`);
  const invalidDraft = cli(['evolution', 'new', 'wrong-output-type']).result;
  const wrongModule = path.join(invalidDraft.path, 'target/src/Reporting.hs');
  fs.writeFileSync(wrongModule, fs.readFileSync(wrongModule, 'utf8').replace('type Output = Text', 'type Output = String')
    .replace('page title = pure ("<!doctype html><title>" <> title <> "</title><h1>雪</h1>")', 'page _ = pure "wrong representation"'));
  const wrongResult = cli(['evolution', 'check', invalidDraft.id], 1);
  assert(wrongResult.diagnostics.some(d => d.code === 'guest.compiler-rejected'));
  assert.equal(fs.readFileSync(publication.result, 'utf8'), before);
  console.log('Installed output contracts, preview, UTF-8 publication, overrides and rejection passed.');
} finally {
  if (process.env.KYYN_KEEP_TEST_KB) console.log(`Retained test KB: ${kb}`);
  else fs.rmSync(temporary, { recursive: true, force: true });
}
