// Installed judgement discovery and ordinary registered-tool missing-secret refusal.
// No live Jev call.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-judgement.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-judgement-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: path.join(temporary, 'gitconfig'),
  GIT_AUTHOR_NAME: 'Judgement fixture', GIT_COMMITTER_NAME: 'Judgement fixture',
  GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
function cli(args, status = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout);
}
function git(...args) {
  const result = spawnSync('git', ['-C', kb, ...args], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
try {
  fs.mkdirSync(kb);
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'add-judgement-tool']).result;
  const modules = cli(['guest', 'module', 'list', '--evolution', draft.id]).result.modules;
  assert(modules.includes('Kyyn.Agentic') && modules.includes('Kyyn.Connectors'));
  assert(modules.includes('Agentic') && modules.includes('Agentic.Questions'));
  const api = cli(['guest', 'module', 'show', 'Agentic.Questions']).result;
  for (const name of ['yesNo', 'choice', 'score', 'Questions', 'YesNo', 'Probability'])
    assert(api.symbols.some(symbol => symbol.name === name), name);
  const manifestPath = path.join(draft.path, 'target/kb.dhall');
  const manifest = fs.readFileSync(manifestPath, 'utf8');
  const emptyTools = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  assert(manifest.includes(emptyTools));
  fs.writeFileSync(manifestPath, manifest.replace(emptyTools,
    '[{ name = "assess", description = "Assess a supplied message", implementation = "Helpers.assess", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
  fs.writeFileSync(path.join(draft.path, 'target/src/Helpers.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Helpers where
import qualified Agentic as A
import Agentic.Questions (yesNo, YesNo(..), basisPoints)
import Control.Arrow ((>>>), arr)
import qualified Data.Text as Text
import Kyyn.Agentic (Flow, interpret)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)
type Input = String
type Output = Integer
assessment :: Flow Text.Text Integer
assessment = A.judge (yesNo "Does this require a reply?")
  >>> arr (\\(YesNo p) -> toInteger (basisPoints p))
assess :: Input -> Tool (Either FetchError Output)
assess = interpret assessment . Text.pack
`);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const head = git('rev-parse', 'HEAD');
  assert.deepEqual(cli(['secret', 'list']).result.names, []);
  const missing = cli(['root', 'tool', 'execute', 'assess', '--input', '"Please reply"'], 1);
  assert.match(JSON.stringify(missing), /JEV_TOKEN/);
  assert.match(JSON.stringify(missing), /secret set/);
  assert.equal(git('rev-parse', 'HEAD'), head);
  assert.equal(git('status', '--porcelain'), '');
  console.log('Installed Agentic judgement tool: discovery, compile without credentials, missing-key refusal, unchanged root. No live provider contacted.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
