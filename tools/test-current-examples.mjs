// Installed current-type decoding: a saved example survives a type documentation
// edit, while an incompatible result type reports the named example. A malformed
// guest description exercises the installed host reader with a stub guest. No providers.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-current-examples-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'Current types fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
  GIT_COMMITTER_NAME: 'Current types fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, expected = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.status, expected, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
function accept(draft) {
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
}
try {
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'saved-example']).result;
  const target = path.join(draft.path, 'target');
  const source = `{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
module Reporting where
import GHC.Generics (Generic)
import Kyyn.Schema
import KyynQueryBindings (Query)
type Unit = ()
-- | The result before its documentation edit.
data Answer = Answer { count :: Integer } deriving stock Generic deriving anyclass Contract
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
answer :: Unit -> Query Answer
answer () = pure (Answer 7)
`;
  fs.writeFileSync(path.join(target, 'src/Reporting.hs'), source);
  const manifest = path.join(target, 'kb.dhall');
  const empty = 'queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }';
  const original = fs.readFileSync(manifest, 'utf8');
  assert(original.includes(empty));
  fs.writeFileSync(manifest, original.replace(empty, 'queries = [{ name = "answer", description = "Saved example", implementation = "Reporting.answer", inputType = "Reporting.Unit", inputMetadata = "Reporting.metadata", resultType = "Reporting.Answer", resultMetadata = "Reporting.metadata" }]'));
  const example = path.join(target, 'examples/answer');
  fs.mkdirSync(example, { recursive: true });
  fs.writeFileSync(path.join(example, 'example.dhall'), '{ name = "answer", query = "answer", explanation = "Seven items", requirement = < Required | Illustrative >.Required }');
  fs.writeFileSync(path.join(example, 'arguments.dhall'), '{=}');
  fs.writeFileSync(path.join(example, 'expected.dhall'), '{ count = +7 }');
  accept(draft);
  const docs = cli(['evolution', 'new', 'document-answer']).result;
  fs.writeFileSync(path.join(docs.path, 'target/src/Reporting.hs'), source.replace('The result before its documentation edit.', 'The number of captured items.'));
  accept(docs);
  cli(['root', 'check']);
  const incompatible = cli(['evolution', 'new', 'change-answer-type']).result;
  fs.writeFileSync(path.join(incompatible.path, 'target/src/Reporting.hs'), source.replace('count :: Integer', 'count :: Bool').replace('Answer 7', 'Answer True'));
  const rejected = cli(['evolution', 'check', incompatible.id], 1);
  assert.match(JSON.stringify(rejected), /dhall.type/);
  assert.match(JSON.stringify(rejected), /answer/);
  assert.doesNotMatch(JSON.stringify(rejected), /contracts changed|rebuild the example/);
  const mismatch = cli(['evolution', 'new', 'guest-shape-mismatch']).result;
  fs.appendFileSync(path.join(mismatch.path, 'target/src/Reporting.hs'), '\n-- Distinct build for the malformed guest fixture.\n');
  const output = path.join(temporary, 'stub-output');
  fs.mkdirSync(path.join(output, 'bin'), { recursive: true });
  const guest = path.join(output, 'bin/kyyn-guest');
  fs.writeFileSync(guest, `#!${process.execPath}
process.stdin.resume();
process.stdin.on('end', () => {
  const value = JSON.stringify({ entries: true, modules: [] });
  process.stdout.write(Buffer.byteLength(value) + '\\n' + value + '0\\n0\\n');
});
`, { mode: 0o755 });
  const nix = path.join(temporary, 'stub-nix');
  fs.writeFileSync(nix, `#!${process.execPath}
const fs = require('node:fs');
const output = ${JSON.stringify(output)};
const retention = process.argv[process.argv.indexOf('--out-link') + 1];
fs.symlinkSync(output, retention);
process.stdout.write(JSON.stringify([{ drvPath: output + '.drv', outputs: { out: output } }]));
`, { mode: 0o755 });
  const malformed = cli(['--nix', nix, 'evolution', 'check', mismatch.id], 1);
  assert.match(JSON.stringify(malformed), /guest.description/);
  assert.match(JSON.stringify(malformed), /entries/);
  console.log('Saved example survived documentation edit; incompatible result and guest description produced located decode errors.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
