import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const allowed = {
  'kyyn-domain': ['Data.List', 'Control.DeepSeq', 'GHC.Generics'],
  'kyyn-plumbing': ['Data.List', 'Kyyn.Domain.DataType'],
  'kyyn-microhs': [
    'Control.DeepSeq', 'Control.Exception', 'Control.Monad', 'Data.List', 'Kyyn.Domain.DataType',
    'MicroHs.Compile', 'MicroHs.CompileCache', 'MicroHs.Expr', 'MicroHs.Flags', 'MicroHs.Ident',
    'MicroHs.SymTab', 'MicroHs.StateIO', 'MicroHs.TypeCheck',
  ],
  'kyyn-runtime': ['Data.List', 'Text.JSON.Types', 'Text.JSON.String'],
  'kyyn-plumbing-interpreters': [
    'Control.Concurrent.Async', 'Control.Exception', 'Data.ByteString', 'Effectful',
    'Effectful.Dispatch.Dynamic', 'Effectful.Error.Static', 'Effectful.Exception',
    'Kyyn.Domain.Failure', 'Kyyn.Plumbing.Capability.Failure',
    'Kyyn.Plumbing.Capability.ProcessExecution', 'System.IO', 'System.Process.Typed',
  ],
};

const plumbingModules = {
  'Kyyn.Plumbing.Capability.Failure': ['Effectful', 'Effectful.Error.Static', 'Kyyn.Domain.Failure'],
  'Kyyn.Plumbing.Capability.ProcessExecution': ['Data.ByteString', 'Effectful', 'Effectful.Dispatch.Dynamic'],
};

export function checkImports(packageName, source) {
  if (!allowed[packageName]) throw new Error(`No import policy for ${packageName}`);
  const moduleName = /^module\s+([\w.]+)/m.exec(source)?.[1];
  const permitted = (packageName === 'kyyn-plumbing' && plumbingModules[moduleName]) || allowed[packageName];
  return source.split('\n').filter(line => /^\s*import\b/.test(line)).flatMap(line => {
    const match = /^\s*import\s+(?:qualified\s+)?([A-Z][\w.]*)(?:\s|$)/.exec(line);
    if (!match) return ['unsupported import syntax; use a plain single-line module import'];
    if (!permitted.includes(match[1])) return [match[1]];
    if (packageName === 'kyyn-plumbing' && match[1] === 'Effectful') {
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
    files(path.join(root, pkg === 'kyyn-runtime' ? 'guest' : 'host', pkg, 'src')).flatMap(file =>
      checkImports(pkg, fs.readFileSync(file, 'utf8')).map(name => `${file}: forbidden import ${name}`)));
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else console.log('Owned host/guest source imports match their explicit allowlists.');
}
