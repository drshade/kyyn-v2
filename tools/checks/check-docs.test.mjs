import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { checkAdr, checkMarkdown, checkRepository } from './check-docs.mjs';

const adr = `---
id: 0027
title: 'An example decision'
status: proposed
date: 2026-09-07
---

# An example decision

Current guidance.
`;

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kyyn-doc-check-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (file, contents) => {
    const full = path.join(root, file);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, contents);
  };
  return { root, write };
}

test('new ADR metadata and imported prose statuses both work', () => {
  assert.deepEqual(checkAdr('0027-example.md', adr), []);
  assert.deepEqual(checkAdr('0003-effects.md', '# 0003 — Effects\n\nStatus: Proposed mechanics; owner-selected boundaries.\n'), []);
  assert.match(checkAdr('0027-example.md', '# 0027 — Example\n\nStatus: Proposed.\n').join('\n'), /requires front matter/);
  assert.deepEqual(checkAdr('0026-layout.md', '# 0026 — Layout\n\nStatus: Accepted.\n'), []);
  assert.deepEqual(checkAdr('0026-layout.md', adr.replace('id: 0027', 'id: 0026')), []);
});

test('metadata errors fail rather than manufacturing a lifecycle state', () => {
  for (const [before, after, expected] of [
    ['id: 0027', 'id: 0028', /ID must match/],
    ['status: proposed', 'status: done', /invalid lifecycle/],
    ['date: 2026-09-07', 'date: 2026-02-30', /invalid decision date/],
    ['# An example decision', '# Something else', /title must match/],
    ['status: proposed', 'status: proposed\nstatus: accepted', /duplicate metadata/],
    ['status: proposed', 'status: proposed\nowner: anyone', /unknown metadata/],
    ['date: 2026-09-07\n---', 'date: 2026-09-07', /not closed/],
  ]) assert.match(checkAdr('0027-example.md', adr.replace(before, after)).join('\n'), expected);
  assert.match(checkAdr('bad-name.md', adr).join('\n'), /filename/);
});

test('duplicate ADR numbers are rejected across different filenames', t => {
  const { root, write } = fixture(t);
  write('architecture/adr/0027-one.md', adr);
  write('architecture/adr/0027-two.md', adr);
  assert.match(checkRepository(root).errors.join('\n'), /duplicate ADR ID/);
});

test('local links work from a clean isolated checkout', t => {
  const { root, write } = fixture(t);
  write('docs/guide.md', '# Guide\n');
  write('README.md', '# Test\n\n[Guide](docs/guide.md#section) and [Web](https://example.com).\n');
  assert.deepEqual(checkRepository(root).errors, []);
  assert.match(checkMarkdown(root, 'README.md', '[Missing](docs/missing.md)\n').join('\n'), /missing local/);
  assert.match(checkMarkdown(root, 'README.md', '[Sibling](../another-repo/README.md)\n').join('\n'), /leaves the checkout/);
  assert.deepEqual(checkMarkdown(root, 'README.md', 'Historical source: `another-repo/README.md`.\n'), []);
});

test('literal Markdown examples are not treated as live links', t => {
  const { root } = fixture(t);
  assert.deepEqual(checkMarkdown(root, 'README.md', '```markdown\n[Example](not-a-real-file.md)\n```\n'), []);
  assert.match(checkMarkdown(root, 'README.md', '```text\nunclosed\n').join('\n'), /unclosed/);
  assert.match(checkMarkdown(root, 'README.md', 'Trailing space \n').join('\n'), /trailing whitespace/);
  assert.match(checkMarkdown(root, 'README.md', 'No newline').join('\n'), /final newline/);
});

test('generated and third-party docs are outside authored documentation checks', t => {
  const { root, write } = fixture(t);
  write('README.md', '# Test\n');
  write('.cache/unrelated.md', '[Broken](missing.md)\n');
  assert.deepEqual(checkRepository(root).errors, []);
  write('vendor/upstream/README.md', '[Upstream](upstream-missing.md)\n');
  const errors = checkRepository(root).errors.join('\n');
  assert.doesNotMatch(errors, /missing local link/);
  assert.match(errors, /extend tools\/test.sh/);
});

test('single-line code spans hide literal links but not adjacent real links', t => {
  const { root } = fixture(t);
  for (const source of [
    '`[Literal](missing.md)`\n',
    '``[Literal](missing.md) with a ` inside``\n',
    '``[One](missing.md)`` and `[Two](missing-too.md)`\n',
  ]) assert.deepEqual(checkMarkdown(root, 'README.md', source), []);
  assert.match(checkMarkdown(root, 'README.md', '`code \\` then [Real](missing.md)\n').join('\n'), /missing local/);
  assert.match(checkMarkdown(root, 'README.md', '`[Literal](ignored.md)` [Real](missing.md)\n').join('\n'), /missing local.*missing.md/);
  assert.match(checkMarkdown(root, 'README.md', '[`Label`](missing.md)\n').join('\n'), /missing local/);
  assert.match(checkMarkdown(root, 'README.md', '`unclosed [Real](missing.md)\n').join('\n'), /missing local/);
  assert.match(checkMarkdown(root, 'README.md', '\\`[Real](missing.md)\\`\n').join('\n'), /missing local/);
});

test('integration test inputs cannot bypass the documentation-only guard', t => {
  const { root, write } = fixture(t);
  write('tests/integration/Example.hs', 'main = pure ()\n');
  assert.match(checkRepository(root).errors.join('\n'), /tests\/integration\/ contains implementation inputs/);
});

test('documentation-only success cannot silently stand for a new software build', t => {
  const { root, write } = fixture(t);
  write('host/example/src/Main.hs', 'main = pure ()\n');
  write('cabal.project', 'packages: host/example\n');
  const errors = checkRepository(root).errors.join('\n');
  assert.match(errors, /implementation inputs/);
  assert.match(errors, /replace the documentation-only gate/);
});
