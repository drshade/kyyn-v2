import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const allowed = {
  'kyyn-types': [],
  'kyyn-domain': ['Data.List', 'Control.DeepSeq', 'GHC.Generics', 'System.FilePath'],
  'kyyn-plumbing': ['Data.List', 'Kyyn.Domain.DataType'],
  'kyyn-microhs': [
    'Control.DeepSeq', 'Control.Exception', 'Control.Monad', 'Data.List', 'Kyyn.Domain.DataType',
    'MicroHs.Compile', 'MicroHs.CompileCache', 'MicroHs.Expr', 'MicroHs.Flags', 'MicroHs.Ident',
    'MicroHs.SymTab', 'MicroHs.StateIO', 'MicroHs.TypeCheck',
  ],
  'kyyn-runtime': ['Data.List', 'Text.JSON.Types', 'Text.JSON.String', 'Kyyn.Types.SchemaMetadata', 'Kyyn.Runtime.Json'],
  'kyyn-plumbing-interpreters': [
    'Control.Concurrent.Async', 'Control.Exception', 'Data.ByteString', 'Effectful',
    'Effectful.Dispatch.Dynamic', 'Effectful.Error.Static', 'Effectful.Exception',
    'Kyyn.Domain.Failure', 'Kyyn.Plumbing.Capability.Failure',
    'Kyyn.Plumbing.Capability.ProcessExecution', 'System.IO', 'System.Process.Typed',
    'Kyyn.Domain.Path', 'Kyyn.Plumbing.Capability.FileSystem', 'System.Directory', 'System.FilePath', 'System.IO.Temp',
    'Kyyn.Plumbing.Capability.DhallHandling',
  ],
};

const plumbingModules = {
  'Kyyn.Plumbing.Capability.DhallHandling': ['Data.Aeson', 'Data.Text',
    'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Plumbing.Capability.SchemaInspection.Contract'],
  'Kyyn.Plumbing.Capability.SchemaInspection.Contract': ['Control.Monad', 'Crypto.Hash.SHA256',
    'Data.Aeson', 'Data.ByteString', 'Data.ByteString.Lazy', 'Data.List',
    'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic', 'Kyyn.Types.SchemaMetadata'],
  'Kyyn.Plumbing.Capability.SchemaInspection.Metadata': ['Control.Monad', 'Data.Aeson',
    'Data.Aeson.Types', 'Data.Aeson.Key', 'Data.Aeson.KeyMap', 'Data.ByteString', 'Data.List', 'Data.Char', 'Effectful',
    'Kyyn.Types.SchemaMetadata', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Failure',
    'Kyyn.Plumbing.Capability.Failure', 'Kyyn.Plumbing.Capability.FileSystem',
    'Kyyn.Plumbing.Capability.GuestCompilation', 'Kyyn.Plumbing.Capability.ProcessExecution'],
  'Kyyn.Plumbing.Capability.Failure': ['Effectful', 'Effectful.Error.Static', 'Kyyn.Domain.Failure'],
  'Kyyn.Plumbing.Capability.ProcessExecution': ['Data.ByteString', 'Effectful', 'Effectful.Dispatch.Dynamic'],
  'Kyyn.Plumbing.Capability.FileSystem': ['Data.ByteString', 'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Path'],
  'Kyyn.Plumbing.Capability.GuestCompilation': ['Effectful', 'Effectful.Dispatch.Dynamic',
    'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Path', 'Kyyn.Plumbing.Capability.FileSystem',
    'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.ProcessExecution'],
  'Kyyn.Plumbing.Capability.GuestCompilation.Types': ['Crypto.Hash.SHA256', 'Data.ByteString',
    'Data.ByteString.Builder', 'Data.ByteString.Lazy', 'Data.List', 'Data.Text', 'Data.Text.Encoding', 'Kyyn.Domain.Path'],
};

const interpreterModules = {
  'Kyyn.Plumbing.Interpreter.DhallHandling': ['Control.Monad', 'Data.Bifunctor', 'Data.Aeson', 'Data.Aeson.Key',
    'Data.Aeson.KeyMap', 'Data.List', 'Data.Sequence', 'Dhall.Pretty', 'Prettyprinter', 'Prettyprinter.Render.Text',
    'Data.Foldable', 'Data.Text', 'Data.Void', 'Dhall.Core', 'Dhall.Map', 'Dhall.Parser',
    'Dhall.Src', 'Dhall.TypeCheck', 'Effectful', 'Effectful.Dispatch.Dynamic',
    'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Plumbing.Capability.SchemaInspection.Contract', 'Kyyn.Plumbing.Capability.DhallHandling'],
};

const compilerModules = {
  'Kyyn.MicroHs.Toolchain': ['Kyyn.Domain.Path'],
  'Kyyn.MicroHs.Interpreter.GuestCompilation': ['Control.Monad', 'Data.ByteString', 'Data.Text',
    'Data.Text.Encoding', 'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Domain.Failure', 'Kyyn.Domain.Path', 'Kyyn.MicroHs.Toolchain',
    'Kyyn.Plumbing.Capability.Failure', 'Kyyn.Plumbing.Capability.FileSystem',
    'Kyyn.Plumbing.Capability.GuestCompilation', 'Kyyn.Plumbing.Capability.GuestCompilation.Types',
    'Kyyn.Plumbing.Capability.ProcessExecution'],
};

export function checkImports(packageName, source) {
  if (!allowed[packageName]) throw new Error(`No import policy for ${packageName}`);
  const moduleName = /^module\s+([\w.]+)/m.exec(source)?.[1];
  const permitted = (packageName === 'kyyn-plumbing' && plumbingModules[moduleName]) ||
    (packageName === 'kyyn-microhs' && compilerModules[moduleName]) ||
    (packageName === 'kyyn-plumbing-interpreters' && interpreterModules[moduleName]) || allowed[packageName];
  return source.split('\n').filter(line => /^\s*import\b/.test(line)).flatMap(line => {
    const match = /^\s*import\s+(?:qualified\s+)?([A-Z][\w.]*)(?:\s|$)/.exec(line);
    if (!match) return ['unsupported import syntax; use a plain single-line module import'];
    if (!permitted.includes(match[1])) return [match[1]];
    if ((packageName === 'kyyn-plumbing' || moduleName === 'Kyyn.MicroHs.Interpreter.GuestCompilation') && match[1] === 'Effectful') {
      const explicit = /^\s*import Effectful \((.*)\)\s*$/.exec(line);
      const names = explicit?.[1].split(',').map(name => name.trim());
      const pureNames = ['Effect', 'Eff', 'DispatchOf', 'Dispatch(..)', '(:>)'];
      if (!names || names.some(name => !pureNames.includes(name))) return ['Effectful: explicit API-only imports required'];
    }
    return [];
  });
}

function files(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? files(file) : file.endsWith('.hs') ? [file] : [];
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.argv[2] || process.cwd();
  const errors = Object.keys(allowed).flatMap(pkg =>
    files(path.join(root, pkg === 'kyyn-types' ? 'shared' : pkg === 'kyyn-runtime' ? 'guest' : 'host', pkg, 'src')).flatMap(file =>
      checkImports(pkg, fs.readFileSync(file, 'utf8')).map(name => `${file}: forbidden import ${name}`)));
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else console.log('Owned host/guest source imports match their explicit allowlists.');
}
