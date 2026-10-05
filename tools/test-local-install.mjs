// Local installer behavior and bundled-runtime lookup in disposable prefixes.
// Checks replacement, failed-build preservation and refusals without altering the user's installation.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-local-install-'));
const prefix = path.join(temporary, 'prefix with spaces');
const bundle = path.join(prefix, 'lib/kyyn-v2');
const executable = path.join(prefix, 'bin/kyyn-v2');
const invoke = (command, args, expected = 0, env = process.env) => {
  const result = spawnSync(command, args, { cwd: repository, env, encoding: 'utf8' });
  assert.equal(result.status, expected, `${command} ${args.join(' ')}\n${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  assert(!result.stderr.includes('cannot find config file:'), result.stderr);
  return result.stdout;
};
const install = (destination = prefix, expected = 0, env = process.env) =>
  invoke('bash', ['tools/install-cli.sh', destination], expected, env);

try {
  fs.mkdirSync(path.join(prefix, 'bin'), { recursive: true });
  const legacy = path.join(prefix, 'bin/kyyn');
  fs.writeFileSync(legacy, 'existing v1 executable');
  install();
  assert.equal(fs.readlinkSync(executable), path.join(bundle, 'bin/kyyn-v2'));
  assert.match(invoke(executable, ['--help']), /kyyn-v2/);
  assert.deepEqual(fs.readFileSync(path.join(bundle, 'lib/kyyn/microhs/bin/mhs')),
    fs.readFileSync(path.join(repository, 'vendor/MicroHs/bin/gmhs')),
    'Installed compiler differs from the native toolchain');
  for (const entry of ['microhs/mhs.conf', 'microhs/bin/mhs', 'microhs/bin/mhseval', 'microhs/bin/cpphs', 'sdk/Kyyn/Types/Fact.hs']) {
    assert.ok(fs.existsSync(path.join(bundle, 'lib/kyyn', entry)), entry);
  }
  const stale = path.join(bundle, 'lib/kyyn/sdk/Retired.hs');
  fs.writeFileSync(stale, 'old generated installation file');
  install();
  assert.ok(!fs.existsSync(stale), 'Reinstallation retained obsolete SDK files');
  assert.equal(fs.readFileSync(legacy, 'utf8'), 'existing v1 executable');

  const kb = path.join(temporary, 'todos');
  fs.cpSync(path.join(repository, 'examples/todos'), kb, { recursive: true });
  invoke('git', ['-C', kb, 'init', '-b', 'main']);
  invoke('git', ['-C', kb, 'config', 'user.name', 'Install fixture']);
  invoke('git', ['-C', kb, 'config', 'user.email', 'install@example.invalid']);
  invoke('git', ['-C', kb, 'add', '.']);
  invoke('git', ['-C', kb, 'commit', '-m', 'Initial todos']);
  assert.match(invoke(executable, ['--kb', kb, 'root', 'check']), /checks passed/);

  const before = fs.readFileSync(executable);
  const fakeBin = path.join(temporary, 'fail-build');
  fs.mkdirSync(fakeBin);
  fs.writeFileSync(path.join(fakeBin, 'cabal'), '#!/bin/sh\nexit 73\n', { mode: 0o755 });
  install(prefix, 73, { ...process.env, PATH: `${fakeBin}:${process.env.PATH}` });
  assert.deepEqual(fs.readFileSync(executable), before, 'Failed build replaced the installation');
  assert.deepEqual(fs.readdirSync(path.join(prefix, 'lib')), ['kyyn-v2']);

  const unrelated = path.join(temporary, 'unrelated');
  fs.mkdirSync(path.join(unrelated, 'bin'), { recursive: true });
  fs.writeFileSync(path.join(unrelated, 'bin/kyyn-v2'), 'not this installer');
  install(unrelated, 1);
  assert.equal(fs.readFileSync(path.join(unrelated, 'bin/kyyn-v2'), 'utf8'), 'not this installer');
  console.log('Local install, symlink, complete runtime, reinstall, failed build and v1 preservation passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
