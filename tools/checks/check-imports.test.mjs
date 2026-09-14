import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkImports } from './check-imports.mjs';

test('pure dependencies are permitted', () => {
  assert.deepEqual(checkImports('kyyn-domain', 'import Data.List (nub)'), []);
  assert.deepEqual(checkImports('kyyn-plumbing', 'import Kyyn.Domain.DataType'), []);
});
test('CLI adapters cannot acquire native IO or interpreter dependencies', () => {
  assert.deepEqual(checkImports('kyyn-surfaces', 'import Options.Applicative'), []);
  for (const name of ['System.IO', 'System.Directory', 'Kyyn.Plumbing.Capability.Git',
    'Kyyn.Porcelain.Interpreter.EvolutionStore', 'Kyyn.MicroHs.Inspection',
    'Kyyn.Porcelain.Capability.Validation', 'Kyyn.Porcelain.Capability.RootOpening',
    'Kyyn.Porcelain.Capability.EvolutionExecution', 'Effectful']) {
    assert.deepEqual(checkImports('kyyn-surfaces', `import ${name}`), [name]);
  }
  assert.deepEqual(checkImports('kyyn-surfaces', 'import Effectful (Eff, IOE)'), ['Effectful']);
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

test('evidence semantics cannot acquire IO and document persistence cannot know evidence', () => {
  const semantic = 'module Kyyn.Porcelain.Interpreter.EvidenceStore where\n';
  assert.deepEqual(checkImports('kyyn-porcelain-interpreters', semantic + 'import Kyyn.Plumbing.Capability.DocumentPersistence'), []);
  for (const name of ['System.Directory', 'System.FileLock', 'Kyyn.Plumbing.Interpreter.DocumentPersistence']) {
    assert.deepEqual(checkImports('kyyn-porcelain-interpreters', semantic + `import ${name}`), [name]);
  }
  assert.match(checkImports('kyyn-porcelain-interpreters', semantic + 'import Effectful (Eff, IOE)').join(), /API-only/);
  const native = 'module Kyyn.Plumbing.Interpreter.DocumentPersistence where\n';
  for (const name of ['Kyyn.Domain.Evidence', 'Kyyn.Porcelain.Capability.EvidenceStore']) {
    assert.deepEqual(checkImports('kyyn-plumbing-interpreters', native + `import ${name}`), [name]);
  }
  assert.deepEqual(checkImports('kyyn-plumbing', 'import Kyyn.Porcelain.Capability.EvidenceStore'), ['Kyyn.Porcelain.Capability.EvidenceStore']);
});
test('publication cannot import validation, source loading or native effects', () => {
  const header = 'module Kyyn.Porcelain.Interpreter.RootPublication where\n';
  for (const name of ['Kyyn.Porcelain.Capability.Validation', 'Kyyn.Porcelain.Capability.RootOpening',
    'Kyyn.Porcelain.Capability.RootExecution', 'Kyyn.Porcelain.Capability.EvolutionExecution',
    'Kyyn.Plumbing.Capability.FileSystem', 'Effectful.Error.Static', 'System.IO']) {
    assert.deepEqual(checkImports('kyyn-porcelain-interpreters', header + `import ${name}`), [name]);
  }
  assert.deepEqual(checkImports('kyyn-porcelain-interpreters', header + 'import Kyyn.Plumbing.Capability.Git'), []);
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

test('prepared root constructors stay behind the capability', () => {
  const internal = 'import Kyyn.Porcelain.RootExecution.Types';
  for (const pkg of ['kyyn-porcelain', 'kyyn-surfaces', 'kyyn-domain', 'kyyn-plumbing']) {
    assert.deepEqual(checkImports(pkg, 'module Other where\n' + internal), ['Kyyn.Porcelain.RootExecution.Types']);
  }
  assert.deepEqual(checkImports('kyyn-porcelain', 'module Kyyn.Porcelain.Capability.RootExecution where\n' + internal), []);
  assert.deepEqual(checkImports('kyyn-porcelain-interpreters', 'module Kyyn.Porcelain.Interpreter.RootExecution where\n' + internal), []);
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

test('guest compilation and execution lower only through plumbing despite their native package', () => {
  for (const module of ['GuestCompilation', 'GuestExecution']) {
    const header = `module Kyyn.MicroHs.Interpreter.${module} where\n`;
    for (const name of ['System.IO', 'System.Process', 'MicroHs.Compile', 'Control.Exception']) {
      assert.deepEqual(checkImports('kyyn-microhs', header + `import ${name}`), [name]);
    }
    assert.match(checkImports('kyyn-microhs', header + 'import Effectful (Eff, IOE)').join(), /API-only/);
    assert.deepEqual(checkImports('kyyn-microhs', header + 'import Kyyn.Plumbing.Capability.FileSystem'), []);
  }
  const types = 'module Kyyn.Plumbing.Capability.GuestCompilation.Types where\n';
  assert.deepEqual(checkImports('kyyn-plumbing', types + 'import Effectful'), ['Effectful']);
  const compilation = 'module Kyyn.Plumbing.Capability.GuestCompilation where\n';
  assert.deepEqual(checkImports('kyyn-plumbing', compilation + 'import Kyyn.Plumbing.Capability.GuestExecution'),
    ['Kyyn.Plumbing.Capability.GuestExecution']);
  const execution = 'module Kyyn.Plumbing.Capability.GuestExecution where\n';
  assert.deepEqual(checkImports('kyyn-plumbing', execution + 'import Kyyn.Plumbing.Capability.GuestCompilation'),
    ['Kyyn.Plumbing.Capability.GuestCompilation']);
});
