import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-model-tool.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-model-installed-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(temporary, 'gitconfig'),
  OPENAI_API_KEY: 'ambient-key-must-not-be-used' };
function cli(args, status = 0) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  assert(!result.stderr.includes('cannot find config file'), result.stderr);
  return JSON.parse(result.stdout);
}
try {
  fs.mkdirSync(kb);
  fs.writeFileSync(env.GIT_CONFIG_GLOBAL, '[user]\nname = Model fixture\nemail = fixture@example.invalid\n');
  cli(['kb', 'init']);
  const draft = cli(['evolution', 'new', 'model-tool']).result;
  const target = path.join(draft.path, 'target');
  fs.writeFileSync(path.join(target, 'model.dhall'),
    '{ provider = < OpenAI | Anthropic >.OpenAI, model = "fixture-model", credential = "MODEL_FIXTURE_KEY" }');
  const manifest = path.join(target, 'kb.dhall');
  const empty = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  const original = fs.readFileSync(manifest, 'utf8');
  assert(original.includes(empty));
  fs.writeFileSync(manifest, original.replace(empty,
    '[{ name = "summary", description = "Summarise supplied text", implementation = "Helpers.summary", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
  fs.writeFileSync(path.join(target, 'src/Helpers.hs'), `{-# LANGUAGE OverloadedStrings #-}
module Helpers where
import qualified Agentic as A
import qualified Data.Text as Text
import Kyyn.Agentic (Flow, interpret)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)
type Input = String
type Output = String
summarise :: Flow Text.Text Text.Text
summarise = A.draft "Summarise in one sentence"
summary :: Input -> Tool (Either FetchError Output)
summary input = fmap (fmap Text.unpack) (interpret summarise (Text.pack input))
`);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  cli(['root', 'check']);
  const shown = cli(['root', 'tool', 'show', 'summary']).result;
  assert.deepEqual(shown.model, { provider: 'OpenAI', model: 'fixture-model', credential: 'MODEL_FIXTURE_KEY' });
  cli(['guest', 'module', 'show', 'Agentic']);
  cli(['guest', 'module', 'show', 'Kyyn.Agentic']);
  const refused = cli(['root', 'tool', 'execute', 'summary', '--input', '"hello"'], 1);
  assert.match(JSON.stringify(refused.diagnostics), /Missing model secret MODEL_FIXTURE_KEY/);
  assert.match(JSON.stringify(refused.diagnostics), /secret set MODEL_FIXTURE_KEY/);
  assert(!JSON.stringify(refused).includes(env.OPENAI_API_KEY));
  console.log('Installed model tool: evolve/check/accept, safe model discovery, Agentic API discovery and local-secret refusal passed. No live provider contacted.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
