// Installed empty-KB initialization through first schema-changing acceptance.
// Checks identity, nested/existing repositories, candidate retention, source-only
// discovery, unrelated-file preservation, refusals and checkout recovery.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

if (process.argv.length < 3 || process.argv.length > 4) throw new Error('Usage: node tools/test-initialization.mjs EXECUTABLE [RUNTIME]');
const executable = path.resolve(process.argv[2]);
const runtime = process.argv[3] ? ['--runtime', path.resolve(process.argv[3])] : [];
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-initialization-'));
const home = path.join(temporary, 'home');
fs.mkdirSync(home);
const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: path.join(temporary, 'xdg'), GIT_CONFIG_NOSYSTEM: '1' };
function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, env, encoding: 'utf8' });
  assert.equal(result.status, 0, JSON.stringify(result));
  return result.stdout.trim();
}
function cli(kb, args, expected = 0, options = runtime) {
  const result = spawnSync(executable, ['--kb', kb, ...options, '--json', ...args],
    { cwd: temporary, env, encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, expected, JSON.stringify(result));
  return JSON.parse(result.stdout);
}
function write(file, text) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); }
try {
  git(temporary, 'config', '--global', 'user.name', 'Initialization λ');
  git(temporary, 'config', '--global', 'user.email', 'initialization@example.invalid');
  git(temporary, 'config', '--global', 'init.defaultBranch', 'kb-test');
  const kb = path.join(temporary, 'new λ', 'kb');
  fs.mkdirSync(path.dirname(kb));
  const unrelatedAncestorEntry = path.join(temporary, 'unrelated:entry');
  fs.writeFileSync(unrelatedAncestorEntry, 'preserve me');
  const initialized = cli(kb, ['kb', 'init']).result;
  assert.equal(fs.readFileSync(unrelatedAncestorEntry, 'utf8'), 'preserve me');
  fs.unlinkSync(unrelatedAncestorEntry);
  assert.equal(initialized.branch, 'kb-test');
  assert.equal(initialized.path, kb);
  assert.equal(git(kb, 'rev-list', '--count', 'HEAD'), '1');
  assert.equal(git(kb, 'show', '-s', '--format=%an', 'HEAD'), 'Initialization λ');
  assert.equal(initialized.revision, git(kb, 'rev-parse', 'HEAD'));
  const taps = cli(kb, ['tap', 'list']).result.taps;
  assert.deepEqual(taps, [{ name: 'first-party', source: 'https://github.com/drshade/kyyn-v2', syncedRevision: null }]);
  assert(git(kb, 'show', 'HEAD:taps.dhall').includes('first-party'));
  assert.equal(fs.existsSync(path.join(kb, '.kyyn/taps')), false);
  assert.deepEqual(cli(kb, ['root', 'show']).result.value, {});
  cli(kb, ['root', 'check']);
  assert.equal(cli(kb, ['kb', 'init'], 1).outcome, 'Refused');
  assert.equal(git(kb, 'rev-list', '--count', 'HEAD'), '1');

  const created = cli(kb, ['evolution', 'new', 'first collection']).result;
  assert.equal(created.id, '000001-first-collection');
  const discover = (...args) => cli(kb, ['guest', ...args, '--evolution', created.id]).result;
  const draftEntry = path.join(created.path, 'change', 'Evolution.hs');
  fs.writeFileSync(draftEntry, 'module Evolution where\nevolution = missing\n');
  const emptyApi = discover('module', 'show', 'Kyyn.Workspace.After');
  assert.deepEqual(emptyApi.symbols, []);
  assert.equal(emptyApi.context.beforeRevision, initialized.revision);
  assert.equal(emptyApi.context.evolution, created.id);
  assert.equal(emptyApi.context.kb, kb);
  const catalogue = discover('module', 'list');
  assert.deepEqual(catalogue.modules.filter(name => name.startsWith('Kyyn.Workspace.')),
    ['Kyyn.Workspace.Evolution', 'Kyyn.Workspace.Before', 'Kyyn.Workspace.After', 'Kyyn.Workspace.FactEdits']);
  git(kb, 'switch', '-c', 'discovery-other-head');
  git(kb, 'commit', '--allow-empty', '-m', 'Unrelated head advance');
  assert.equal(discover('module', 'list').context.beforeRevision, initialized.revision);
  git(kb, 'switch', 'kb-test');
  const target = path.join(created.path, 'target');
  fs.unlinkSync(path.join(target, 'src', 'RootV1.hs'));
  write(path.join(target, 'src', 'RootV2.hs'), `module RootV2 where
import Kyyn.Schema
data Todo = Todo { title :: String } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)
metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
`);
  for (const file of ['kb.dhall', 'src/Validate.hs']) {
    const filename = path.join(target, file);
    fs.writeFileSync(filename, fs.readFileSync(filename, 'utf8').replaceAll('RootV1', 'RootV2'));
  }
  const schemaPath = path.join(target, 'src', 'RootV2.hs');
  const validSchema = fs.readFileSync(schemaPath, 'utf8');
  fs.writeFileSync(schemaPath, 'module RootV2 where\nthis is invalid\n');
  const badSchema = cli(kb, ['guest', 'module', 'list', '--evolution', created.id]);
  assert.equal(badSchema.outcome, 'Succeeded');
  assert(badSchema.diagnostics.some(diagnostic => diagnostic.code === 'guest.bindings-unavailable'));
  assert(badSchema.diagnostics.some(diagnostic => diagnostic.code === 'schema.compiler-rejected'));
  assert(badSchema.result.modules.includes('Kyyn.Evolution'));
  assert(!badSchema.result.modules.some(name => name.startsWith('Kyyn.Workspace.')));
  fs.writeFileSync(schemaPath, validSchema);
  const bindings = discover('module', 'show', 'Kyyn.Workspace.Evolution').symbols;
  for (const name of ['edit', 'evolve', 'editBefore']) {
    const symbol = bindings.find(s => s.name === name);
    assert(symbol, name);
    assert(symbol.documentation.includes('recorded step'), JSON.stringify(symbol));
    assert(symbol.declaration.includes('RootV'), JSON.stringify(symbol));
  }
  assert(!bindings.some(s => ['beforeRoot', 'afterRoot', 'evaluateEvolution'].includes(s.name)));
  const handle = discover('symbol', 'show', 'Kyyn.Workspace.After.todos').symbols[0];
  assert.match(handle.declaration, /Collection \(KnowledgeBase RootV2.Root\) RootV2.Todo/);
  assert(handle.documentation.includes('todos'));
  for (const symbol of [...bindings, handle]) {
    assert(!symbol.declaration?.includes('.Internal.'), JSON.stringify(symbol));
  }
  fs.unlinkSync(draftEntry);
  discover('symbol', 'show', 'Kyyn.Workspace.Evolution.edit');
  write(path.join(created.path, 'change', 'Evolution.hs'), `module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
import qualified Kyyn.Workspace.After as Collections
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution =
  evolve (Rationale "Start tracking work." [])
    (onFacts (\\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Record the first task." [])
    (within Collections.todos (append (Fact (FactId "todo-001") (After.Todo "First task"))))
`);
  cli(kb, ['evolution', 'check', created.id]);
  const manifestPath = path.join(created.path, 'manifest.dhall');
  const currentManifest = fs.readFileSync(manifestPath, 'utf8');
  const latestCandidate = fs.readFileSync(path.join(kb, '.kyyn', 'candidates', 'latest', created.id), 'utf8');
  const captureManifestPath = path.join(kb, '.kyyn', 'candidates', latestCandidate, 'capture', 'manifest.dhall');
  const capturedManifest = fs.readFileSync(captureManifestPath, 'utf8');
  const extraField = text => `(${text}) // { extra = [] : List Text }`;
  fs.writeFileSync(captureManifestPath, extraField(capturedManifest));
  const malformedCandidate = cli(kb, ['evolution', 'show', created.id], 1);
  assert(malformedCandidate.diagnostics.some(d => d.code === 'workspace.manifest'), JSON.stringify(malformedCandidate));
  assert(malformedCandidate.diagnostics.some(d => d.message.includes('extra')), JSON.stringify(malformedCandidate));
  fs.writeFileSync(captureManifestPath, capturedManifest);
  fs.writeFileSync(manifestPath, extraField(currentManifest));
  const invalidManifest = cli(kb, ['evolution', 'check', created.id], 1);
  assert(invalidManifest.diagnostics.some(d => d.code === 'workspace.manifest'));
  assert(invalidManifest.diagnostics.some(d => d.message.includes('extra')));
  fs.writeFileSync(manifestPath, currentManifest);
  const validatorPath = path.join(target, 'src', 'Validate.hs');
  const entryPath = path.join(created.path, 'change', 'Evolution.hs');
  const validValidator = fs.readFileSync(validatorPath, 'utf8');
  const updatedEntry = fs.readFileSync(entryPath, 'utf8').replace('First task', 'Updated task');
  fs.writeFileSync(validatorPath, validValidator.replace('ValidationReport []',
    'ValidationReport [Diagnostic Error "test.invalid" "Reject the new candidate" Nothing]'));
  fs.writeFileSync(entryPath, updatedEntry);
  const invalid = cli(kb, ['evolution', 'check', created.id], 1);
  assert.equal(invalid.result.candidateSaved, true);
  assert.equal(invalid.result.passed, false);
  assert(invalid.diagnostics.some(d => d.code === 'test.invalid'));
  const rejectedReport = cli(kb, ['evolution', 'show', created.id]).result.report;
  assert(JSON.stringify(rejectedReport).includes('Updated task'));
  const candidatePointer = path.join(kb, '.kyyn', 'candidates', 'latest', created.id);
  const rejectedPointer = fs.readFileSync(candidatePointer, 'utf8');
  fs.writeFileSync(entryPath, 'module Evolution where\nevolution = missing\n');
  const broken = cli(kb, ['evolution', 'check', created.id], 1);
  assert.equal(broken.result.candidateSaved, false);
  assert.equal(fs.readFileSync(candidatePointer, 'utf8'), rejectedPointer);
  assert.deepEqual(cli(kb, ['evolution', 'show', created.id]).result.report, rejectedReport);
  fs.writeFileSync(entryPath, updatedEntry);
  fs.writeFileSync(validatorPath, validValidator);
  cli(kb, ['evolution', 'check', created.id]);
  assert.equal(git(kb, 'status', '--porcelain', '--untracked-files=all', '--', '.kyyn'), '');
  assert.equal(git(kb, 'check-ignore', '.kyyn/.gitignore'), '.kyyn/.gitignore');
  assert.equal(git(kb, 'rev-parse', 'HEAD'), initialized.revision);
  cli(kb, ['evolution', 'ready', created.id]);
  cli(kb, ['evolution', 'accept', created.id]);
  assert.equal(git(kb, 'rev-parse', 'HEAD^'), initialized.revision);
  assert.deepEqual(cli(kb, ['root', 'show']).result.value,
    { todos: [{ id: 'todo-001', value: { title: 'Updated task' } }] });
  console.log('Initialized empty KB -> first schema-changing evolution -> accepted collection passed.');

  const repo = path.join(temporary, "existing 'quoted' λ");
  fs.mkdirSync(repo);
  git(repo, 'init', '-q');
  write(path.join(repo, 'unrelated'), 'committed');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'Existing repository');
  write(path.join(repo, 'unrelated'), 'staged'); git(repo, 'add', 'unrelated');
  write(path.join(repo, 'unrelated'), 'working');
  write(path.join(repo, 'untracked'), 'preserved');
  for (const selected of [path.join(repo, 'nested', 'kb'), repo]) {
    const parent = git(repo, 'rev-parse', 'HEAD');
    cli(selected, ['kb', 'init']);
    assert.equal(git(repo, 'rev-parse', 'HEAD^'), parent);
    assert.equal(git(repo, 'show', 'HEAD:unrelated'), 'committed');
    assert.equal(git(repo, 'show', ':unrelated'), 'staged');
    assert.equal(fs.readFileSync(path.join(repo, 'unrelated'), 'utf8'), 'working');
    assert.equal(fs.readFileSync(path.join(repo, 'untracked'), 'utf8'), 'preserved');
  }
  const nested = path.join(repo, 'root', 'nested-kb');
  assert.equal(cli(nested, ['kb', 'init'], 1).diagnostics[0].code, 'kb.nested-ownership');
  assert.equal(fs.existsSync(nested), false);
  git(repo, 'checkout', '--detach', '-q', 'HEAD');
  const detached = path.join(repo, 'detached');
  assert.equal(cli(detached, ['kb', 'init'], 1).diagnostics[0].code, 'git.detached-head');
  assert.equal(fs.existsSync(detached), false);
  git(repo, 'checkout', '-q', 'kb-test');
  const indexed = path.join(repo, 'indexed');
  write(path.join(indexed, 'evolutions', 'residue'), 'staged residue');
  git(repo, 'add', 'indexed');
  fs.rmSync(indexed, { recursive: true });
  assert.equal(cli(indexed, ['kb', 'init'], 1).diagnostics[0].code, 'kb.already-exists');
  assert.equal(fs.existsSync(indexed), false);
  const residue = path.join(temporary, 'residue');
  write(path.join(residue, 'evolutions', 'draft'), 'keep');
  cli(residue, ['kb', 'init'], 1);
  assert.equal(fs.existsSync(path.join(residue, '.git')), false);
  const failed = path.join(temporary, 'failed');
  cli(failed, ['kb', 'init'], 3, ['--runtime', path.join(temporary, 'missing-runtime')]);
  assert.equal(fs.existsSync(failed), false);
  git(temporary, 'config', '--global', 'user.name', '');
  const unidentified = path.join(temporary, 'no-identity');
  assert.equal(cli(unidentified, ['kb', 'init'], 1).diagnostics[0].code, 'git.identity');
  assert.equal(fs.existsSync(unidentified), false);
  git(temporary, 'config', '--global', 'user.name', 'Initialization λ');

  const bare = path.join(temporary, 'bare.git');
  git(temporary, 'init', '--bare', '-q', bare);
  const insideBare = path.join(bare, 'new-kb');
  assert.equal(cli(insideBare, ['kb', 'init'], 1).diagnostics[0].code, 'git.repository-unavailable');
  assert.equal(fs.existsSync(insideBare), false);
  for (const kind of ['config', 'HEAD', 'gitfile']) {
    const corrupted = path.join(temporary, `corrupted-${kind}`);
    fs.mkdirSync(corrupted);
    if (kind !== 'gitfile') git(corrupted, 'init', '-q');
    const metadata = kind === 'gitfile' ? path.join(corrupted, '.git') : path.join(corrupted, '.git', kind);
    const bytes = kind === 'gitfile' ? 'gitdir: /nonexistent-kyyn-test-repository\n' : kind === 'config' ? '[broken\n' : 'broken';
    write(metadata, bytes);
    const destination = path.join(corrupted, 'nested', 'kb');
    assert.equal(cli(destination, ['kb', 'init'], 1).diagnostics[0].code, 'git.repository-unavailable');
    assert.equal(fs.existsSync(destination), false);
    assert.equal(fs.readFileSync(metadata, 'utf8'), bytes);
  }
  const repair = path.join(repo, 'repair');
  const lock = path.join(repo, '.git', 'index.lock');
  write(lock, 'held by fixture');
  const incomplete = cli(repair, ['kb', 'init'], 4);
  assert.equal(incomplete.result.checkoutSynchronized, false);
  assert.equal(incomplete.result.revision, git(repo, 'rev-parse', 'HEAD'));
  const recovery = incomplete.diagnostics.find(d => d.code === 'kb.checkout-incomplete').message;
  assert(recovery.includes(`restore --source=${incomplete.result.revision}`));
  assert(recovery.includes("--staged --worktree -- 'repair/root' 'repair/taps.dhall'"));
  fs.unlinkSync(lock);
  cli(repair, ['kb', 'init'], 1);
  const restoreCommand = recovery.split('with: ')[1].split('\n')[0];
  const restored = spawnSync('sh', ['-c', restoreCommand], { cwd: temporary, env, encoding: 'utf8' });
  assert.equal(restored.status, 0, JSON.stringify(restored));
  assert.equal(fs.existsSync(path.join(repair, 'root', 'kb.dhall')), true);
  assert.equal(cli(repair, ['tap', 'list']).result.taps[0].name, 'first-party');
  console.log('Existing/nested repositories, preservation, read-only refusals and post-publication recovery passed.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
