// Installed, prelocked KB initialization and identity evolution through real Nix
// builds. Covers a missing KB directory, empty Root edit bindings, SDK/workspace
// discovery, default-library execution and acceptance. No provider credentials or global configuration.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length !== 3) throw new Error('Usage: node tools/test-native-guest.mjs EXECUTABLE');
const executable = fs.realpathSync(process.argv[2]);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-native-guest-'));
const kb = path.join(temporary, 'kb');
const home = path.join(temporary, 'home');
fs.mkdirSync(home);
fs.writeFileSync(path.join(home, '.gitconfig'), '[user]\n name = Native guest test\n email = fixture@example.invalid\n[init]\n defaultBranch = main\n');
const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: path.join(temporary, 'xdg'), GIT_CONFIG_NOSYSTEM: '1' };
delete env.GIT_CONFIG_GLOBAL;
function cli(...args) {
  const result = spawnSync(executable, ['--kb', kb, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.status, 0, JSON.stringify({ args, ...result }));
  return JSON.parse(result.stdout).result;
}
try {
  assert.equal(fs.existsSync(kb), false);
  const initialized = cli('kb', 'init');
  assert.equal(initialized.checkoutSynchronized, true);
  const lock = fs.readFileSync(path.join(kb, 'root', 'flake.lock'), 'utf8');
  assert(JSON.parse(lock).nodes.root.inputs.kyyn);
  assert.deepEqual(cli('root', 'show').value, {});
  const evolution = cli('evolution', 'new', 'native identity');
  fs.copyFileSync(new URL('./fixtures/default-libraries/LibraryDefaults.hs', import.meta.url),
    path.join(evolution.path, 'target/src/LibraryDefaults.hs'));
  fs.writeFileSync(path.join(evolution.path, 'target/src/Validate.hs'), `module Validate where
import qualified Schema
import Kyyn.Validation
import LibraryDefaults (librariesWork)
validate :: Schema.Root -> ValidationReport
validate _ | librariesWork = ValidationReport []
           | otherwise = error "Default guest libraries did not execute correctly"
`);
  assert.equal(cli('guest', 'module', 'show', 'Kyyn.Evolution').origin, 'sdk');
  assert.equal(cli('guest', 'module', 'show', 'Kyyn.Workspace.Evolution', '--evolution', evolution.id).origin, 'generated');
  cli('evolution', 'check', evolution.id);
  cli('evolution', 'ready', evolution.id);
  assert.equal(cli('evolution', 'accept', evolution.id).accepted, true);
  assert.equal(cli('root', 'check').passed, true);
  assert.equal(fs.readFileSync(path.join(kb, 'root', 'flake.lock'), 'utf8'), lock);
  console.log('Installed prelocked initialization, guest discovery, default libraries, identity evolution and accepted-root validation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
