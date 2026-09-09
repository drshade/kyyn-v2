import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const allowed = {
  'kyyn-surfaces': ['Kyyn.Domain.Evolution', 'Kyyn.Domain.Git', 'Options.Applicative',
    'Kyyn.Domain.KnowledgeBase',
    'Data.Aeson', 'Data.ByteString.Lazy', 'Data.Text', 'Data.Text.Encoding', 'Kyyn.Domain.Contract', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Domain.EvolutionReport', 'Kyyn.Domain.Failure', 'Kyyn.Domain.Path', 'Kyyn.Domain.Publication',
    'Kyyn.Domain.Root', 'Kyyn.Domain.Workspace', 'Kyyn.Types.Evolution', 'Kyyn.Types.Evidence', 'Kyyn.Types.Fact',
    'Kyyn.Porcelain.Validated'],
  'kyyn': ['Control.Applicative', 'Control.Monad.Trans.Except', 'Control.Monad.IO.Class',
    'Kyyn.Domain.Publication', 'Kyyn.Porcelain.Capability.KnowledgeBaseInitialization',
    'Kyyn.Porcelain.Interpreter.KnowledgeBaseInitialization',
    'Data.Time.Clock.POSIX', 'Effectful', 'Kyyn.Configuration', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Domain.Evolution', 'Kyyn.Domain.Failure', 'Kyyn.Domain.FileTree', 'Kyyn.Domain.Git',
    'Kyyn.Domain.KnowledgeBase', 'Kyyn.Domain.Path', 'Kyyn.Domain.Workspace',
    'Kyyn.MicroHs.Toolchain', 'Kyyn.MicroHs.Interpreter.GuestCompilation', 'Kyyn.MicroHs.Interpreter.SchemaInspection',
    'Kyyn.Plumbing.Capability.DhallHandling', 'Kyyn.Plumbing.Capability.Failure',
    'Kyyn.Plumbing.Capability.FileSystem', 'Kyyn.Plumbing.Capability.Git',
    'Kyyn.Plumbing.Capability.GuestCompilation', 'Kyyn.Plumbing.Capability.ProcessExecution',
    'Kyyn.Plumbing.Capability.SchemaInspection', 'Kyyn.Plumbing.Interpreter.DhallHandling',
    'Kyyn.Plumbing.Interpreter.Failure', 'Kyyn.Plumbing.Interpreter.FileSystem',
    'Kyyn.Plumbing.Interpreter.Git', 'Kyyn.Plumbing.Interpreter.ProcessExecution',
    'Kyyn.Porcelain.Capability.Root', 'Kyyn.Porcelain.Capability.Evolution', 'Kyyn.Porcelain.Capability.EvolutionAuthoring',
    'Kyyn.Porcelain.Capability.EvolutionExecution', 'Kyyn.Porcelain.Capability.EvolutionStore',
    'Kyyn.Porcelain.Capability.RootExecution', 'Kyyn.Porcelain.Capability.RootOpening',
    'Kyyn.Porcelain.Capability.RootPublication', 'Kyyn.Porcelain.Capability.RootStore',
    'Kyyn.Porcelain.Capability.WorkspaceStore', 'Kyyn.Porcelain.Interpreter.EvolutionAuthoring',
    'Kyyn.Porcelain.Interpreter.EvolutionExecution', 'Kyyn.Porcelain.Interpreter.EvolutionStore',
    'Kyyn.Porcelain.Interpreter.RootExecution', 'Kyyn.Porcelain.Interpreter.RootOpening',
    'Kyyn.Porcelain.Interpreter.RootPublication', 'Kyyn.Porcelain.Interpreter.RootStore',
    'Kyyn.Porcelain.Interpreter.WorkspaceStore', 'Kyyn.Surfaces.Cli',
    'Kyyn.Surfaces.Result', 'System.Directory', 'System.Environment', 'System.FilePath'],
  'kyyn-types': ['Data.List', 'Kyyn.Types.Fact', 'Kyyn.Types.Program', 'Kyyn.Types.Diagnostic', 'Kyyn.Types.Evidence'],
  'kyyn-sdk': ['Kyyn.Types.Evolution', 'Kyyn.Types.Evidence', 'Kyyn.Evolution.Internal', 'Text.JSON.Types'],
  'kyyn-porcelain': ['Control.Monad', 'Data.Aeson', 'Data.Aeson.Types', 'Data.Aeson.Key', 'Data.Foldable', 'Data.List', 'Data.Coerce', 'Effectful', 'Effectful.Dispatch.Dynamic',
    'Kyyn.Porcelain.Capability.RootOpening',
    'Kyyn.Domain.Publication', 'Kyyn.Domain.Path', 'Kyyn.Porcelain.Capability.RootPublication', 'Kyyn.Porcelain.Capability.Validation',
    'Kyyn.Porcelain.Capability.EvolutionExecution', 'Kyyn.Porcelain.Capability.EvolutionStore', 'Kyyn.Porcelain.Capability.EvolutionAuthoring',
    'Kyyn.Domain.EvolutionReport', 'Kyyn.Types.Fact',
    'Kyyn.Domain.Workspace', 'Kyyn.Domain.Evolution', 'Kyyn.Domain.KnowledgeBase',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Root', 'Kyyn.Domain.Query', 'Kyyn.Domain.Example', 'Kyyn.Domain.FileTree', 'Kyyn.Domain.Git',
    'Kyyn.Porcelain.Capability.RootExecution', 'Kyyn.Porcelain.Capability.RootStore', 'Kyyn.Porcelain.Validated'],
  'kyyn-porcelain-interpreters': ['Control.Monad', 'Control.Monad.Trans.Except',
    'Kyyn.Porcelain.Capability.EvolutionAuthoring',
    'Kyyn.Domain.Publication', 'Kyyn.Porcelain.Capability.RootPublication',
    'Data.Aeson.Types', 'Kyyn.Domain.EvolutionReport', 'Kyyn.Types.Fact',
    'Data.ByteString.Char8', 'Kyyn.Plumbing.Protocol.EvolutionRecord',
    'Kyyn.Types.Evolution', 'Kyyn.Porcelain.Capability.EvolutionExecution', 'Kyyn.Porcelain.Capability.EvolutionReport',
    'Kyyn.Domain.KnowledgeBase', 'Kyyn.Domain.Evolution', 'Kyyn.Porcelain.Capability.EvolutionStore', 'Kyyn.Plumbing.Protocol.Evolution',
    'Kyyn.Domain.Git', 'Kyyn.Domain.Workspace', 'Kyyn.Porcelain.Capability.WorkspaceStore',
    'Data.Aeson', 'Data.Aeson.Key', 'Data.Aeson.KeyMap', 'Data.ByteString', 'Data.Foldable',
    'Data.List', 'Data.Text', 'Data.Text.Encoding', 'Data.ByteString.Lazy', 'Numeric', 'Effectful', 'Effectful.Dispatch.Dynamic',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Path',
    'Kyyn.Domain.Root', 'Kyyn.Domain.FileTree', 'Kyyn.Plumbing.Capability.DhallHandling', 'Kyyn.Porcelain.Capability.RootStore',
    'Kyyn.Plumbing.Capability.SchemaInspection', 'Kyyn.Plumbing.Capability.Git', 'Kyyn.Porcelain.Capability.RootOpening',
    'Kyyn.Domain.Failure', 'Kyyn.Plumbing.Capability.Failure', 'Kyyn.Plumbing.Capability.FileSystem',
    'Kyyn.Plumbing.Capability.GuestCompilation', 'Kyyn.Plumbing.Capability.ProcessExecution',
    'Kyyn.Plumbing.Protocol.Validation', 'Kyyn.Plumbing.Protocol.Query', 'Kyyn.Domain.Query', 'Kyyn.Domain.Example', 'Kyyn.Porcelain.Capability.RootExecution', 'Kyyn.Porcelain.Validated'],
  'kyyn-domain': ['Data.List', 'Control.DeepSeq', 'GHC.Generics', 'System.FilePath'],
  'kyyn-plumbing': ['Data.List', 'Kyyn.Domain.DataType'],
  'kyyn-microhs': [
    'Control.DeepSeq', 'Control.Exception', 'Control.Monad', 'Data.List', 'Kyyn.Domain.DataType',
    'MicroHs.Compile', 'MicroHs.CompileCache', 'MicroHs.Expr', 'MicroHs.Flags', 'MicroHs.Ident',
    'MicroHs.SymTab', 'MicroHs.StateIO', 'MicroHs.TypeCheck',
  ],
  'kyyn-runtime': ['Data.List', 'Text.JSON.Types', 'Text.JSON.String', 'Kyyn.Types.SchemaMetadata', 'Kyyn.Types.Diagnostic', 'Kyyn.Runtime.Json', 'Kyyn.Types.Fact', 'Kyyn.Types.Query',
    'Kyyn.Evolution.Internal', 'Kyyn.Types.Evolution', 'Kyyn.Types.Evidence', 'Kyyn.Types.Program', 'Kyyn.Runtime.Validation'],
  'kyyn-plumbing-interpreters': [
    'Data.Word', 'Numeric', 'System.IO.Error', 'System.Random',
    'Control.Concurrent.Async', 'Control.Exception', 'Data.ByteString', 'Effectful',
    'Effectful.Dispatch.Dynamic', 'Effectful.Error.Static', 'Effectful.Exception',
    'Kyyn.Domain.Failure', 'Kyyn.Plumbing.Capability.Failure',
    'Kyyn.Plumbing.Capability.ProcessExecution', 'System.IO', 'System.Process.Typed',
    'Kyyn.Domain.Path', 'Kyyn.Plumbing.Capability.FileSystem', 'System.Directory', 'System.FilePath', 'System.IO.Temp',
    'Kyyn.Plumbing.Capability.DhallHandling',
    'Control.Monad', 'Data.List', 'Kyyn.Domain.FileTree',
  ],
};

const domainModules = {
  'Kyyn.Domain.CompiledProgram': ['Data.ByteString', 'Kyyn.Domain.Path'],
  'Kyyn.Domain.Publication': ['Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Evolution', 'Kyyn.Domain.Git', 'Kyyn.Domain.Path', 'Kyyn.Domain.Workspace', 'Kyyn.Domain.KnowledgeBase'],
  'Kyyn.Domain.EvolutionReport': ['Data.Aeson', 'Kyyn.Domain.Contract', 'Kyyn.Types.Evolution', 'Kyyn.Types.Fact'],
  'Kyyn.Domain.KnowledgeBase': ['Kyyn.Domain.Git', 'Kyyn.Domain.Path'],
  'Kyyn.Domain.Evolution': ['Data.Coerce', 'Data.Char', 'Data.List', 'Kyyn.Domain.Contract', 'Kyyn.Domain.Git', 'Kyyn.Domain.KnowledgeBase', 'Kyyn.Domain.Workspace',
    'Kyyn.Domain.Value', 'Kyyn.Domain.Root', 'Kyyn.Domain.Path', 'Kyyn.Domain.EvolutionReport', 'Kyyn.Domain.Diagnostic', 'Kyyn.Types.Evolution'],
  'Kyyn.Domain.Workspace': ['Data.List', 'Kyyn.Domain.FileTree', 'Kyyn.Domain.Git', 'Kyyn.Domain.Path'],
  'Kyyn.Domain.Diagnostic': ['Kyyn.Types.Diagnostic'],
  'Kyyn.Domain.Contract': ['Control.Monad', 'Data.Coerce', 'Crypto.Hash.SHA256', 'Numeric',
    'Data.Aeson.Types',
    'Data.Aeson', 'Data.ByteString', 'Data.ByteString.Lazy', 'Data.List',
    'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic', 'Kyyn.Types.SchemaMetadata'],
  'Kyyn.Domain.Root': ['Kyyn.Domain.Contract', 'Kyyn.Domain.FileTree', 'Kyyn.Domain.Query', 'Kyyn.Domain.Value', 'Kyyn.Domain.Path'],
  'Kyyn.Domain.Value': ['Data.Aeson', 'Kyyn.Domain.Contract'],
  'Kyyn.Domain.Query': ['Kyyn.Domain.Contract', 'Kyyn.Domain.Value', 'Kyyn.Types.Query'],
  'Kyyn.Domain.Example': ['Kyyn.Domain.Query', 'Kyyn.Domain.Value'],
  'Kyyn.Domain.FileTree': ['Data.ByteString', 'Data.List', 'Kyyn.Domain.Path'],
  'Kyyn.Domain.Git': ['Kyyn.Domain.Path', 'Kyyn.Domain.FileTree'],
};

const plumbingModules = {
  'Kyyn.Plumbing.Protocol.EvolutionRecord': ['Data.Aeson', 'Data.ByteString', 'Data.Text.Encoding', 'Effectful',
    'Kyyn.Plumbing.Capability.DhallHandling', 'Kyyn.Plumbing.Protocol.EvolutionRecord.Document',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Evolution', 'Kyyn.Domain.EvolutionReport'],
  'Kyyn.Plumbing.Protocol.EvolutionRecord.Contract': ['Control.Monad', 'Data.Aeson', 'Data.Aeson.Types', 'Data.List',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic', 'Kyyn.Types.SchemaMetadata'],
  'Kyyn.Plumbing.Protocol.EvolutionRecord.Document': ['Control.Monad', 'Data.Aeson', 'Data.Aeson.Types',
    'Data.Aeson.Key', 'Data.Aeson.KeyMap', 'Data.List', 'Kyyn.Domain.DataType', 'Kyyn.Plumbing.Protocol.EvolutionRecord.Contract',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Evolution', 'Kyyn.Domain.EvolutionReport',
    'Kyyn.Types.Evolution', 'Kyyn.Types.Evidence', 'Kyyn.Types.Fact'],
  'Kyyn.Plumbing.Protocol.Evolution': ['Control.Monad', 'Data.List', 'Data.ByteString', 'Data.Text', 'Data.Text.Encoding',
    'Data.Aeson', 'Data.Aeson.Types', 'Data.Aeson.Key', 'Data.Aeson.KeyMap', 'Data.Foldable',
    'Kyyn.Domain.EvolutionReport', 'Kyyn.Types.Evolution', 'Kyyn.Types.Evidence', 'Kyyn.Types.Diagnostic', 'Kyyn.Plumbing.Protocol.Validation',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.DataType', 'Kyyn.Domain.FileTree', 'Kyyn.Domain.Path',
    'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.SchemaInspection.Codecs'],
  'Kyyn.Plumbing.Protocol.Query': ['Control.Monad', 'Data.Aeson', 'Data.Aeson.Types',
    'Data.Aeson.KeyMap', 'Data.ByteString', 'Data.Foldable', 'Data.List', 'Data.Text', 'Data.Text.Encoding',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.DataType', 'Kyyn.Domain.Path', 'Kyyn.Types.Fact', 'Kyyn.Types.Query',
    'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.SchemaInspection.Codecs'],
  'Kyyn.Plumbing.Protocol.Validation': ['Control.Monad', 'Data.Aeson', 'Data.Aeson.Types',
    'Data.Aeson.Key', 'Data.Aeson.KeyMap', 'Data.ByteString', 'Data.Foldable', 'Data.List', 'Kyyn.Domain.Diagnostic',
    'Data.Text', 'Data.Text.Encoding', 'Kyyn.Domain.DataType', 'Kyyn.Domain.Path',
    'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.SchemaInspection.Codecs'],
  'Kyyn.Plumbing.Capability.Git': ['Effectful', 'Effectful.Dispatch.Dynamic',
    'Data.ByteString', 'Kyyn.Domain.Path',
    'Kyyn.Domain.Git', 'Kyyn.Domain.FileTree', 'Kyyn.Domain.Diagnostic'],
  'Kyyn.Plumbing.Capability.SchemaInspection': ['Data.ByteString', 'Data.Text', 'Data.Text.Encoding',
    'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Contract', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Domain.Path', 'Kyyn.Plumbing.Capability.GuestCompilation.Types',
    'Kyyn.Plumbing.Capability.SchemaInspection.Metadata'],
  'Kyyn.Plumbing.Capability.DhallHandling': ['Data.Aeson', 'Data.Text',
    'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Domain.DataType'],
  'Kyyn.Plumbing.Capability.SchemaInspection.Metadata': ['Control.Monad', 'Data.Aeson',
    'Data.Aeson.Types', 'Data.Aeson.Key', 'Data.Aeson.KeyMap', 'Data.ByteString', 'Data.List', 'Effectful',
    'Kyyn.Types.SchemaMetadata', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Failure',
    'Kyyn.Plumbing.Capability.Failure', 'Kyyn.Plumbing.Capability.FileSystem',
    'Kyyn.Plumbing.Capability.GuestCompilation', 'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.ProcessExecution'],
  'Kyyn.Plumbing.Capability.Failure': ['Effectful', 'Effectful.Error.Static', 'Kyyn.Domain.Failure'],
  'Kyyn.Plumbing.Capability.ProcessExecution': ['Data.ByteString', 'Effectful', 'Effectful.Dispatch.Dynamic'],
  'Kyyn.Plumbing.Capability.FileSystem': ['Data.ByteString', 'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Path', 'Kyyn.Domain.FileTree'],
  'Kyyn.Plumbing.Capability.GuestCompilation': ['Effectful', 'Effectful.Dispatch.Dynamic',
    'Data.ByteString', 'Kyyn.Domain.Failure', 'Kyyn.Plumbing.Capability.Failure',
    'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.CompiledProgram',
    'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.ProcessExecution'],
  'Kyyn.Plumbing.Capability.GuestCompilation.Types': ['Crypto.Hash.SHA256', 'Data.Char', 'Data.ByteString',
    'Data.ByteString.Builder', 'Data.ByteString.Lazy', 'Data.List', 'Data.Text', 'Data.Text.Encoding', 'Kyyn.Domain.Path'],
};

const interpreterModules = {
  'Kyyn.Porcelain.Interpreter.KnowledgeBaseInitialization': ['Control.Monad', 'Control.Monad.Trans.Except',
    'Data.List', 'Data.Maybe', 'Effectful', 'Effectful.Dispatch.Dynamic', 'System.FilePath',
    'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Git', 'Kyyn.Domain.KnowledgeBase', 'Kyyn.Domain.Path', 'Kyyn.Domain.Publication',
    'Kyyn.Plumbing.Capability.FileSystem', 'Kyyn.Plumbing.Capability.Git',
    'Kyyn.Porcelain.Capability.KnowledgeBaseInitialization', 'Kyyn.Porcelain.Capability.RootStore'],
  'Kyyn.Porcelain.Interpreter.RootPublication': ['Control.Monad', 'Control.Monad.Trans.Except',
    'Effectful', 'Effectful.Dispatch.Dynamic', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Evolution',
    'Kyyn.Domain.Git', 'Kyyn.Domain.KnowledgeBase', 'Kyyn.Domain.Publication', 'Kyyn.Domain.Workspace',
    'Kyyn.Plumbing.Capability.Git', 'Kyyn.Porcelain.Capability.RootPublication',
    'Kyyn.Porcelain.Capability.EvolutionStore', 'Kyyn.Porcelain.Capability.RootStore'],
  'Kyyn.Plumbing.Interpreter.Git': ['System.FilePath', 'Control.Monad', 'Control.Monad.Trans.Except', 'Data.Char', 'Data.List', 'Data.ByteString', 'Data.ByteString.Char8',
    'Data.Text', 'Data.Text.Encoding', 'Effectful', 'Effectful.Dispatch.Dynamic', 'Effectful.Error.Static',
    'Kyyn.Domain.FileTree', 'Kyyn.Domain.Git', 'Kyyn.Domain.Path', 'Kyyn.Domain.Failure', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Plumbing.Capability.Failure', 'Kyyn.Plumbing.Capability.Git', 'Kyyn.Plumbing.Capability.ProcessExecution'],
  'Kyyn.Plumbing.Interpreter.DhallHandling': ['Control.Monad', 'Data.Bifunctor', 'Data.Aeson', 'Data.Aeson.Key',
    'Data.Aeson.KeyMap', 'Data.List', 'Data.Sequence', 'Dhall.Pretty', 'Prettyprinter', 'Prettyprinter.Render.Text',
    'Data.Foldable', 'Data.Text', 'Data.Void', 'Dhall.Core', 'Dhall.Map', 'Dhall.Parser',
    'Dhall.Src', 'Dhall.TypeCheck', 'Effectful', 'Effectful.Dispatch.Dynamic',
    'Kyyn.Domain.DataType', 'Kyyn.Domain.Diagnostic',
    'Kyyn.Domain.DataType', 'Kyyn.Plumbing.Capability.DhallHandling'],
};

const compilerModules = {
  'Kyyn.MicroHs.Interpreter.SchemaInspection': ['Control.Monad', 'Effectful', 'Effectful.Dispatch.Dynamic',
    'Kyyn.Domain.Contract', 'Kyyn.Domain.Diagnostic', 'Kyyn.Domain.Failure', 'Kyyn.Domain.Path',
    'Kyyn.MicroHs.Inspection', 'Kyyn.MicroHs.Toolchain', 'Kyyn.Plumbing.Capability.Failure',
    'Kyyn.Plumbing.Capability.FileSystem', 'Kyyn.Plumbing.Capability.GuestCompilation',
    'Kyyn.Plumbing.Capability.GuestCompilation.Types', 'Kyyn.Plumbing.Capability.ProcessExecution',
    'Kyyn.Plumbing.Capability.SchemaInspection', 'Kyyn.Plumbing.Capability.SchemaInspection.Metadata'],
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
  const permitted = (packageName === 'kyyn-domain' && domainModules[moduleName]) || (packageName === 'kyyn-plumbing' && plumbingModules[moduleName]) ||
    (packageName === 'kyyn-porcelain' && moduleName === 'Kyyn.Porcelain.RootExecution.Types' &&
      ['Kyyn.Domain.CompiledProgram', 'Kyyn.Domain.Query', 'Kyyn.Domain.Root']) ||
    (packageName === 'kyyn-porcelain' && moduleName === 'Kyyn.Porcelain.Capability.RootExecution' &&
      [...allowed['kyyn-porcelain'], 'Kyyn.Porcelain.RootExecution.Types']) ||
    (packageName === 'kyyn-porcelain-interpreters' && moduleName === 'Kyyn.Porcelain.Interpreter.RootExecution' &&
      [...allowed['kyyn-porcelain-interpreters'], 'Kyyn.Porcelain.RootExecution.Types']) ||
    (packageName === 'kyyn-porcelain' && ['Kyyn.Porcelain.Capability.Validation', 'Kyyn.Porcelain.Validated'].includes(moduleName) && [...allowed['kyyn-porcelain'], 'Kyyn.Porcelain.Validation.Types']) ||
    (packageName === 'kyyn-microhs' && compilerModules[moduleName]) ||
    (['kyyn-plumbing-interpreters', 'kyyn-porcelain-interpreters'].includes(packageName) && interpreterModules[moduleName]) || allowed[packageName];
  return source.split('\n').filter(line => /^\s*import\b/.test(line)).flatMap(line => {
    const match = /^\s*import\s+(?:qualified\s+)?([A-Z][\w.]*)(?:\s|$)/.exec(line);
    if (!match) return ['unsupported import syntax; use a plain single-line module import'];
    if (!permitted.includes(match[1])) return [match[1]];
    if (moduleName === 'Kyyn.Porcelain.Validated' && match[1] === 'Kyyn.Porcelain.Validation.Types' &&
        line.trim() !== 'import Kyyn.Porcelain.Validation.Types (Validated, validatedValue)') {
      return ['Validated facade must import only the abstract type and accessor'];
    }
    if ((['kyyn-plumbing', 'kyyn-porcelain', 'kyyn-porcelain-interpreters', 'kyyn-surfaces'].includes(packageName) || ['Kyyn.MicroHs.Interpreter.GuestCompilation', 'Kyyn.Plumbing.Interpreter.Git'].includes(moduleName)) && match[1] === 'Effectful') {
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
    files(path.join(root, pkg === 'kyyn-types' ? 'shared' : ['kyyn-runtime', 'kyyn-sdk'].includes(pkg) ? 'guest' : 'host', pkg, 'src')).flatMap(file =>
      checkImports(pkg, fs.readFileSync(file, 'utf8')).map(name => `${file}: forbidden import ${name}`)));
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else console.log('Owned host/guest source imports match their explicit allowlists.');
}
