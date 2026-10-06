// Authored schema/tool type errors through installed evolution check; preserve
// useful compiler locations/messages without internal stack traces.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.equal(process.argv.length, 3, 'Usage: node tools/test-compiler-diagnostics.mjs INSTALLED_EXECUTABLE');
const executable = path.resolve(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-diagnostics-'));
const kb = path.join(temporary, 'kb');
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(temporary, 'gitconfig') };
function invoke(args, status = 0, json = true) {
  const result = spawnSync(executable, ['--kb', kb, ...(json ? ['--json'] : []), ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, status, JSON.stringify({ args, ...result }));
  return json ? JSON.parse(result.stdout) : result.stdout + result.stderr;
}
try {
  fs.mkdirSync(kb);
  fs.writeFileSync(env.GIT_CONFIG_GLOBAL, '[user]\nname = Diagnostics fixture\nemail = fixture@example.invalid\n');
  invoke(['kb', 'init']);
  const draft = invoke(['evolution', 'new', 'diagnostic-examples']).result;
  const target = path.join(draft.path, 'target');
  const schemaPath = path.join(target, 'src/RootV1.hs');
  const schema = fs.readFileSync(schemaPath, 'utf8');
  fs.writeFileSync(schemaPath, schema + '\nbad :: Integer\nbad = True\n');
  const check = (code, filename) => {
    const text = invoke(['evolution', 'check', draft.id], 1, false);
    assert(text.includes(`Error [${code}]`), text);
    assert(text.includes(filename), text);
    assert.match(text, /line \d+, col \d+|:\d+:\d+/);
    assert.match(text, /Cannot satisfy constraint|Type mismatch/);
    assert.doesNotMatch(text, /CallStack|backtrace:|called at .* in /);
    return text;
  };
  check('schema.compiler-rejected', 'RootV1.hs');
  fs.writeFileSync(schemaPath, schema);
  const manifest = path.join(target, 'kb.dhall');
  const emptyTools = '[] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }';
  const source = fs.readFileSync(manifest, 'utf8');
  assert(source.includes(emptyTools));
  fs.writeFileSync(manifest, source.replace(emptyTools,
    '[{ name = "assess", description = "Stale tool", implementation = "Tools.assess", inputType = "Tools.Input", resultType = "Tools.Output" }]'));
  fs.writeFileSync(path.join(target, 'src/Tools.hs'), `module Tools where
import Kyyn.Plugin (FetchError)
import Kyyn.Connectors (Tool)
import Agentic.Questions (YesNo(..))
type Input = String
type Output = String
stale :: Double
stale = case YesNo 0.95 of YesNo p -> p
assess :: Input -> Tool (Either FetchError Output)
assess _ = pure (Right (show stale))
`);
  const tool = check('tool.compiler-rejected', 'Tools.hs');
  assert.match(tool, /Probability/);
  assert.match(tool, /Double/);
  assert.doesNotMatch(tool, /schema.compiler-rejected/);
  console.log('Installed schema/tool type errors retain source diagnostics without internal backtraces.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
