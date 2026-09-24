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
  assert(modules.includes('Kyyn.Connectors') && modules.includes('Kyyn.Judgement'));
  assert(!modules.includes('KyynToolCalls') && !modules.includes('Kyyn.Judgement.Question'));
  const showModule = name => cli(['guest', 'module', 'show', name, '--evolution', draft.id]).result;
  const connectors = showModule('Kyyn.Connectors');
  const tool = connectors.symbols.find(symbol => symbol.name === 'Tool');
  assert.match(tool.documentation, /Input -> Tool \(Either FetchError Result\)/);
  const judgement = showModule('Kyyn.Judgement');
  const judge = judgement.symbols.find(symbol => symbol.name === 'judge');
  assert.match(judge.declaration, /Context -> Questions a -> Tool \(Either JudgementFailure a\)/);
  assert.match(judge.documentation, /secret set JEV_TOKEN/);
  assert.match(judge.documentation, /judge \(Context body\) \(ask/);
  for (const name of ['ask', 'yesNo', 'choice', 'scale', 'Questions', 'YesNoAnswer', 'judgementFailureMessage'])
    assert(judgement.symbols.some(symbol => symbol.name === name), `Missing ${name}`);
  const targetManifestPath = path.join(draft.path, 'target/kb.dhall');
  const targetManifest = fs.readFileSync(targetManifestPath, 'utf8');
  fs.writeFileSync(targetManifestPath, 'not valid Dhall');
  assert(cli(['--git', '/no-git', 'guest', 'module', 'show', 'Kyyn.Schema', '--evolution', draft.id]).result.symbols.length > 0);
  const partial = cli(['guest', 'module', 'list', '--evolution', draft.id]);
  assert(partial.result.modules.includes('Kyyn.Schema'));
  assert(partial.diagnostics.some(diagnostic => diagnostic.code === 'guest.bindings-unavailable'));
  const unavailable = cli(['guest', 'module', 'show', 'Kyyn.Judgement', '--evolution', draft.id], 1);
  assert(unavailable.result.modules.includes('Kyyn.Schema'));
  fs.writeFileSync(targetManifestPath, targetManifest);
  const manifestPath = path.join(draft.path, 'target/kb.dhall');
  const manifest = fs.readFileSync(manifestPath, 'utf8');
  const emptyTools = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  assert(manifest.includes(emptyTools));
  fs.writeFileSync(manifestPath, manifest.replace(emptyTools,
    '[{ name = "assess", description = "Assess a supplied message", implementation = "Helpers.assess", inputType = "Helpers.Input", resultType = "Helpers.Output" }]'));
  const helper = path.join(draft.path, 'target/src/Helpers.hs');
  fs.writeFileSync(helper, 'module Helpers where\ntype Input = String\ntype Output = String\nassess :: Input -> Output\nassess = id\n');
  assert(showModule('Kyyn.Judgement').symbols.some(symbol => symbol.name === 'judge'));
  const rejected = cli(['evolution', 'check', draft.id], 1);
  const expected = rejected.diagnostics.find(diagnostic => diagnostic.code === 'tool.signature');
  assert.match(expected.message, /Helpers.assess :: Helpers.Input -> Tool \(Either FetchError Helpers.Output\)/);
  assert.match(expected.message, /Kyyn.Connectors/);
  // The imports, entry contract and judgement vocabulary were inspected above.
  fs.writeFileSync(helper, `module Helpers where
import Kyyn.Plugin (FetchError)
import Kyyn.Connectors (Tool)
import Kyyn.Judgement
type Input = String
type Output = String
assess :: Input -> Tool (Either FetchError Output)
assess body = do
  result <- if body == "empty" then judge (Context body) (pure "unused")
    else fmap (fmap show) (judgeAnswer body)
  pure (Right (either judgementFailureMessage id result))
judgeAnswer :: String -> Tool (Either JudgementFailure YesNoAnswer)
judgeAnswer body = judge (Context body) (ask (yesNo "Does this require a reply?" describe))
  where describe yes = if body == "blank" then "" else if yes then "Reply requested" else "No reply requested"
`);
  cli(['evolution', 'check', draft.id]);
  cli(['evolution', 'ready', draft.id]);
  cli(['evolution', 'accept', draft.id]);
  const head = git('rev-parse', 'HEAD');
  const acceptedModules = cli(['guest', 'module', 'list']).result.modules;
  assert(acceptedModules.includes('Kyyn.Judgement') && acceptedModules.includes('Kyyn.Connectors'));
  assert(cli(['guest', 'symbol', 'show', 'Kyyn.Judgement.judge']).result.symbols.some(symbol => symbol.name === 'judge'));
  assert.deepEqual(cli(['secret', 'list']).result.names, []);
  const execute = body => cli(['root', 'tool', 'execute', 'assess', '--input', JSON.stringify(body)]);
  const missing = JSON.stringify(execute('message'));
  assert.match(missing, /JEV_TOKEN/);
  assert.match(missing, /secret set/);
  assert.match(JSON.stringify(execute('empty')), /At least one question/);
  assert.match(JSON.stringify(execute('blank')), /descriptions must not be empty/);
  assert.equal(git('rev-parse', 'HEAD'), head);
  assert.equal(git('status', '--porcelain'), '');
  console.log('Installed judgement tool: compilation without credentials, typed missing-key and invalid-batch outcomes, unchanged root. No live provider contacted.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
