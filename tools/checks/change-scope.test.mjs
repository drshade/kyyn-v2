import { test } from 'node:test';
import assert from 'node:assert/strict';
import { docsOnly, changedDocsOnly } from './change-scope.mjs';

test('only known documentation paths skip native checks', () => {
  assert.equal(docsOnly(['README.md', 'AGENTS.md', 'docs/SDLC.md', 'architecture/adr/0002-runtime.md']), true);
  for (const path of ['host/Main.hs', 'docs/example.hs', 'architecture/evidence/probe.mjs',
    '.github/workflows/check.yml', 'cabal.project', 'vendor/README.md', 'unknown.md']) {
    assert.equal(docsOnly(['README.md', path]), false, path);
  }
  assert.equal(docsOnly([]), false);
  assert.equal(docsOnly(['host/Old.hs', 'docs/New.md']), false);
});

test('PRs compare the whole branch; pushes compare before and after', () => {
  const git = expected => args => {
    assert.deepEqual(args, ['diff', '--name-only', '--no-renames', '-z', expected, '--']);
    return 'docs/design.md\0';
  };
  assert.equal(changedDocsOnly('pull_request', { pull_request: { base: { sha: 'base' }, head: { sha: 'head' } } }, git('base...head')), true);
  assert.equal(changedDocsOnly('push', { before: 'old', after: 'new' }, git('old..new')), true);
});

test('manual runs and new branches always use normal checks', () => {
  const unexpected = () => assert.fail('should not inspect a diff');
  assert.equal(changedDocsOnly('workflow_dispatch', { inputs: { full: true } }, unexpected), false);
  assert.equal(changedDocsOnly('workflow_dispatch', {}, unexpected), false);
  assert.equal(changedDocsOnly('push', { before: '000000', after: 'new' }, unexpected), false);
});
