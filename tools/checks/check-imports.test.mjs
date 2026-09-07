import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkImports } from './check-imports.mjs';

test('pure dependencies are permitted', () => {
  assert.deepEqual(checkImports('kyyn-domain', 'import Data.List (nub)'), []);
  assert.deepEqual(checkImports('kyyn-plumbing', 'import Kyyn.Domain.DataType'), []);
});
test('native compiler and IO cannot enter pure generation', () => {
  for (const name of ['MicroHs.Expr', 'Kyyn.MicroHs.Inspection', 'System.IO', 'System.IO.Unsafe', 'Data.Text.IO']) {
    assert.deepEqual(checkImports('kyyn-plumbing', `import qualified ${name} as X`), [name]);
  }
});
test('domain cannot depend on effects or higher layers', () => {
  for (const name of ['Effectful', 'Kyyn.Plumbing.Capability.SchemaInspection.Codecs', 'Control.Exception']) {
    assert.deepEqual(checkImports('kyyn-domain', `import ${name}`), [name]);
  }
});
