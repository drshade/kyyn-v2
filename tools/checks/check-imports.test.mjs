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

test('indented imports are checked and unrecognized syntax fails closed', () => {
  assert.deepEqual(checkImports('kyyn-domain', '  import System.IO'), ['System.IO']);
  for (const source of ['import {-# SOURCE #-} System.IO', 'import "base" System.IO', 'import\n  System.IO']) {
    assert.match(checkImports('kyyn-domain', source).join('\n'), /unsupported import syntax/);
  }
});

test('compiler internals stay native and guest transport stays private', () => {
  assert.deepEqual(checkImports('kyyn-microhs', 'import MicroHs.Expr'), []);
  assert.deepEqual(checkImports('kyyn-runtime', 'import Text.JSON.Types'), []);
  assert.deepEqual(checkImports('kyyn-runtime', 'import Kyyn.MicroHs.Inspection'), ['Kyyn.MicroHs.Inspection']);
  assert.deepEqual(checkImports('kyyn-microhs', 'import Kyyn.Porcelain.Capability.RootStore'), ['Kyyn.Porcelain.Capability.RootStore']);
});
