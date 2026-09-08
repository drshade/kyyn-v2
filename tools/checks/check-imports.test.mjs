import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkImports } from './check-imports.mjs';

test('pure dependencies are permitted', () => {
  assert.deepEqual(checkImports('kyyn-domain', 'import Data.List (nub)'), []);
  assert.deepEqual(checkImports('kyyn-plumbing', 'import Kyyn.Domain.DataType'), []);
});
test('evolution SDK stays pure and independent of private transport and native host', () => {
  for (const name of ['System.IO', 'Kyyn.Runtime.Json', 'Effectful', 'Kyyn.Domain.Root']) {
    assert.deepEqual(checkImports('kyyn-sdk', `import ${name}`), [name]);
  }
  assert.deepEqual(checkImports('kyyn-sdk', 'import Kyyn.Types.Evolution'), []);
  assert.deepEqual(checkImports('kyyn-domain', 'import Kyyn.Evolution.Internal'), ['Kyyn.Evolution.Internal']);
});
test('Git reads lower through process plumbing rather than native IO', () => {
  const module = 'module Kyyn.Plumbing.Interpreter.Git where\n';
  assert.deepEqual(checkImports('kyyn-plumbing-interpreters', module + 'import Kyyn.Plumbing.Capability.ProcessExecution'), []);
  assert.deepEqual(checkImports('kyyn-plumbing-interpreters', module + 'import System.Process.Typed'), ['System.Process.Typed']);
  assert.match(checkImports('kyyn-plumbing-interpreters', module + 'import Effectful (Eff, IOE)').join(), /API-only/);
});
test('RootStore API cannot depend on plumbing and its interpreter cannot acquire IO', () => {
  assert.deepEqual(checkImports('kyyn-porcelain', 'import Kyyn.Plumbing.Capability.DhallHandling'),
    ['Kyyn.Plumbing.Capability.DhallHandling']);
  for (const packageName of ['kyyn-porcelain', 'kyyn-porcelain-interpreters']) {
    for (const name of ['System.IO', 'Dhall.Core', 'Kyyn.Plumbing.Interpreter.DhallHandling']) {
      assert.deepEqual(checkImports(packageName, `import ${name}`), [name]);
    }
    assert.match(checkImports(packageName, 'import Effectful (Eff, IOE)').join(), /API-only/);
  }
  assert.deepEqual(checkImports('kyyn-porcelain-interpreters', 'import Kyyn.Plumbing.Capability.DhallHandling'), []);
});
test('Dhall library stays behind its interpreter', () => {
  const api = 'module Kyyn.Plumbing.Capability.DhallHandling where\n';
  const implementation = 'module Kyyn.Plumbing.Interpreter.DhallHandling where\n';
  for (const name of ['Dhall.Core', 'Dhall.Parser', 'Dhall.TypeCheck']) {
    assert.deepEqual(checkImports('kyyn-plumbing', api + `import ${name}`), [name]);
    assert.deepEqual(checkImports('kyyn-plumbing-interpreters', implementation + `import ${name}`), []);
  }
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

test('only validation can import the private Validated constructor', () => {
  const privateImport = 'import Kyyn.Porcelain.Validation.Types';
  assert.deepEqual(checkImports('kyyn-porcelain',
    'module Kyyn.Porcelain.Capability.Validation where\n' + privateImport), []);
  for (const pkg of ['kyyn-domain', 'kyyn-porcelain', 'kyyn-porcelain-interpreters']) {
    assert.deepEqual(checkImports(pkg, 'module Other where\n' + privateImport), ['Kyyn.Porcelain.Validation.Types']);
  }
  const facade = 'module Kyyn.Porcelain.Validated where\n';
  assert.deepEqual(checkImports('kyyn-porcelain', facade + privateImport + ' (Validated, validatedValue)'), []);
  assert.match(checkImports('kyyn-porcelain', facade + privateImport + ' (Validated(..))').join(), /abstract type/);
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

test('effect APIs do not grant IO to capabilities or pure codec generation', () => {
  const header = 'module Kyyn.Plumbing.Capability.ProcessExecution where\n';
  assert.deepEqual(checkImports('kyyn-plumbing', header + 'import Effectful (Eff, (:>))'), []);
  for (const clause of ['Effectful', 'Effectful (Eff, liftIO)', 'qualified Effectful as E']) {
    assert.match(checkImports('kyyn-plumbing', header + `import ${clause}`).join(), /API-only/);
  }
  assert.deepEqual(checkImports('kyyn-plumbing', 'import Effectful (Eff)'), ['Effectful']);
  assert.deepEqual(checkImports('kyyn-plumbing', header + 'import System.Process.Typed'), ['System.Process.Typed']);
  assert.deepEqual(checkImports('kyyn-plumbing-interpreters', 'import System.Process.Typed'), []);
  assert.deepEqual(checkImports('kyyn-plumbing-interpreters', 'import MicroHs.Expr'), ['MicroHs.Expr']);
});

test('guest compilation lowers only through plumbing despite its native package', () => {
  const header = 'module Kyyn.MicroHs.Interpreter.GuestCompilation where\n';
  for (const name of ['System.IO', 'System.Process', 'MicroHs.Compile', 'Control.Exception']) {
    assert.deepEqual(checkImports('kyyn-microhs', header + `import ${name}`), [name]);
  }
  assert.match(checkImports('kyyn-microhs', header + 'import Effectful (Eff, IOE)').join(), /API-only/);
  assert.deepEqual(checkImports('kyyn-microhs', header + 'import Kyyn.Plumbing.Capability.FileSystem'), []);
  const types = 'module Kyyn.Plumbing.Capability.GuestCompilation.Types where\n';
  assert.deepEqual(checkImports('kyyn-plumbing', types + 'import Effectful'), ['Effectful']);
});
