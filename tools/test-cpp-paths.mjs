import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-cpp-paths.mjs INSTALLED_EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-cpp-paths-'));
const runtime = path.join(temporary, "runtime with spaces and 'quotes' λ");
const kb = path.join(temporary, "knowledge with 'quotes' λ");
const temp = path.join(temporary, "compiler temp with 'quotes' λ");
const env = { ...process.env, TMPDIR: temp, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_AUTHOR_NAME: 'CPP fixture', GIT_AUTHOR_EMAIL: 'cpp@example.invalid',
  GIT_COMMITTER_NAME: 'CPP fixture', GIT_COMMITTER_EMAIL: 'cpp@example.invalid' };
function invoke(command, args) {
  const result = spawnSync(command, args, { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, 0, JSON.stringify({ command, args, ...result }));
  return result.stdout;
}
const cli = (...args) => invoke(executable, ['--kb', kb, '--runtime', runtime, ...args]);
try {
  fs.mkdirSync(temp);
  fs.cpSync(path.resolve(path.dirname(executable), '../lib/kyyn'), runtime, { recursive: true });
  cli('kb', 'init');
  fs.writeFileSync(path.join(kb, 'root/src/RootV1.hs'), `{-# LANGUAGE CPP #-}
module RootV1 where
import Kyyn.Schema
#define ROOT_TYPE Root
data ROOT_TYPE = Root deriving (Eq, Show)
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []
`);
  fs.writeFileSync(path.join(kb, 'root/src/Validate.hs'), `{-# LANGUAGE CPP #-}
module Validate where
import qualified RootV1 as Schema
import Kyyn.Validation
#define REPORT ValidationReport []
validate :: Schema.Root -> ValidationReport
validate _ = REPORT
`);
  invoke('git', ['-C', kb, 'add', 'root/src']);
  invoke('git', ['-C', kb, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'CPP schema and validator']);
  assert.match(cli('root', 'check'), /checks passed/);
  const created = JSON.parse(cli('--json', 'evolution', 'new', 'cpp-paths')).result;
  const catalogue = cli('guest', 'module', 'show', 'Kyyn.Workspace.Before', '--evolution', created.id);
  assert.match(catalogue, /Kyyn.Workspace.Before/);
  assert.match(cli('evolution', 'check', created.id), /checks passed/);
  console.log('CPP path smoke passed: native schema/API inspection and guest compilation with spaces, quotes and Unicode in runtime, KB and temp paths.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
