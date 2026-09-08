---
id: 0003
title: 'Effects express architectural dependencies'
status: proposed
date: 2026-09-08
---
# Effects express architectural dependencies

Basis: owner-established porcelain/plumbing separation and interpreter/application
execution naming convention. Concrete filesystem operations and remaining
implementation mechanics refine those boundaries rather than reopen them.

## Context

An effect named `ListFacts` returning `()` while printing, or a helper exposing
`IO` beneath an apparently semantic interface, defeats the architecture. Module
names alone do not prevent this. The dependency graph must enforce the boundary.

## Decision

Use `effectful` for host operations, with explicit public effect rows. Separate:

1. Pure domain values and computations.
2. Porcelain capabilities and application operations in the KB's vocabulary.
3. Porcelain interpreters lowering those effects to narrower effects/plumbing.
4. Plumbing capabilities and their native IO interpreters.
5. Transport adapters and the command-specific composition root.

Only native plumbing interpreters may use `IOE`, `liftIO`, native libraries or
process handles. Transport IO belongs in adapters, which call the application
execution functions; it does not grant application operations ambient IO. Guest adapters have
their own private IO boundary under ADR 0009.

Use `Kyyn.Porcelain.Capability.*`, `Kyyn.Porcelain.Interpreter.*`,
`Kyyn.Plumbing.Capability.*`, and `Kyyn.Plumbing.Interpreter.*`. A capability
owns its vocabulary, pure helpers and effectful combinators. Its interpreter
owns handler installation and interpretation, not a miscellaneous helper API.
No `.IO` or `.FileSystem` suffix until a real second interpreter warrants one.

Every operation takes explicit KB/snapshot/workspace context and returns data.
`()` is appropriate for an actual command with no result, not a disguised
printer. No whole-environment `AppEffects` constraint on every function.
Reserve `run…` for effect interpretation, `execute…` for application execution
that composes interpreters, and ordinary operation names for the workflows:

| Example | Responsibility | Package |
| --- | --- | --- |
| `previewEvolution` | Describes the workflow using explicit semantic effects | `kyyn-porcelain` |
| `runRootStore` | Interprets one semantic effect through other capabilities | `kyyn-porcelain-interpreters` |
| `runFileSystemIO` | Interprets a plumbing effect through native IO | `kyyn-plumbing-interpreters` |
| `executePreviewEvolution` | Supplies context, composes interpreters and executes the workflow | `kyyn` |

These names distinguish responsibilities, not two copies of the workflow. An
`execute…` function supplies handlers and execution context; business logic stays
in the effectful application operation. Transport adapters receive the relevant
execution functions from composition rather than importing interpreter packages.
Pure transformations and guest evaluation helpers do not acquire a `run…` name
merely because someone invokes them.

Application composition lives in `Kyyn.Application.Compose`, with operation-specific
execution modules under `Kyyn.Application.Execution.*` when splitting is useful.
Do not call those modules `Runner`. Interpreter installation functions remain with
their respective interpreter modules, not in the application composition package.
The [repository layout](0026-repository-layout.md) maps these responsibilities to disk.

For example, the plumbing filesystem accepts a caller-supplied scope and relative
path, not a KB noun. These are representative operations, not the full filesystem
API. `DirectoryScope` and `RelativePath` are opaque resolved/checked values;
`Bytes` means encoded file contents, not a semantic fact.

```haskell
data FileSystem :: Effect where
  WithTemporaryScope
    :: (DirectoryScope -> m a) -> FileSystem m a
  ReadBytes
    :: DirectoryScope -> RelativePath -> FileSystem m Bytes
  WriteBytes
    :: DirectoryScope -> RelativePath -> Bytes -> FileSystem m ()
  CreateUniqueDirectory
    :: DirectoryScope -> FileSystem m RelativePath

runFileSystemIO
  :: (IOE :> es, Failure :> es)
  => DirectoryScope -> Eff (FileSystem : es) a -> Eff es a
```

Here `()` really means a completed write; it is not printed output hiding a
missing result. `runFileSystemIO` receives the parent of its temporary directories
explicitly. WithTemporaryScope creates a private child there and removes it on
return, failure or cancellation, preserving local effects. Directory scopes hold
absolute paths; file operations take checked relative paths with no empty, `.` or
`..` components. The process adapter can resolve a scoped file path at its native
boundary. These are path conventions, not symlink containment or a sandbox.

`ReadTree DirectoryScope` captures the files beneath one selected directory into
an immutable FileTree with relative paths. It does not follow symlinks, preserve
empty directories or retain mode bits. Missing/unreadable directories fail rather
than becoming empty trees. This is a sequential working-directory capture, not an
atomic snapshot under concurrent edits; use a fixed Git revision for that selection.

`CreateUniqueDirectory` creates missing parents and reserves a persistent empty
child using exclusive directory creation. It returns the child's single-component
lowercase hexadecimal name relative to the supplied parent. The native interpreter
generates a random Word64 through the random library and retries only name
collisions; existing files/directories are never reused or overwritten. This is
allocation, not a cryptographic identity or automatically cleaned temporary scope.
Other native errors remain storage Failure.

These initial byte writes populate private compiler/artifact scopes. They do not
promise atomic persistent-file replacement. Store and sink operations that publish
files require that additional operation; atomic replacement of one file still
does not promise atomic updates of a KB. [Acceptance](0012-acceptance.md) owns the
Git-level publication operation. A temporary scope is not a root snapshot: callers
return captured bytes or results, not a path-dependent snapshot after cleanup.
The interpreter translates native failures into [Failure](0019-failures.md); callers
cannot recover a fact by interpreting an inaccessible file as empty data.

The host adapter for a guest filesystem write translates path text into this
scoped API. Its lowering helper has an explicit base directory:

```haskell
writeRequestedFile
  :: (FileSystem :> es, Failure :> es)
  => DirectoryScope -> FilePath -> Bytes -> Eff es ()
```

The composition root supplies the base; for a file sink it is the selected KB's
checkout directory (ADR 0017). The adapter resolves a relative request against
that base, or uses an absolute request as given, producing DirectoryScope and
RelativePath for WriteBytesAtomically. Native path handling and access errors
belong to filesystem plumbing, not the plugin's configuration parser. This is
location resolution, not a grant registry or a proof of filesystem containment.
The helper needs no IOE in its public row; any native work goes through FileSystem.

The contrast is the [EvolutionStore interpreter](0010-evolutions.md): it removes
a semantic effect and introduces only plumbing requirements, with no `IOE` in
its required row. A polymorphic row may eventually be composed with native IO;
it does not grant the function an `IOE` dictionary. Package/import checks are
still needed to prevent helpers bypassing this contract.

## Alternatives and consequences

Reject ambient-IO helpers, callbacks carrying arbitrary IO, service-locator
records and a universal command effect. Do not turn pure calculations into
effects merely for symmetry. Plumbing FileSystem understands scoped paths,
not Facts or Evolutions; semantic layout belongs with its store capability.

Use separate packages for domain, porcelain API/operations, plumbing API,
porcelain interpreters, plumbing interpreters, and adapters/composition. GHC package visibility
plus import checks enforce the dependency DAG. The porcelain-interpreter package may see both
APIs but not IO libraries. See [boundary map](../boundaries.md).
These are dependency boundaries, not one package or service per capability.
Several capability modules can share a package; split packages when required to
enforce permitted imports, not because another capability or interpreter exists.
Implement only the capabilities required by the current end-to-end slice.

## Verification

Compile-fail/import tests prohibit IO and interpreter imports from domain and
operations, including qualified or re-exported escape hatches. Review signatures
and handler composition together. Listing evolutions installs no compiler,
plugin or outbound capability. Deterministic interpreters test the same operation
functions as native execution. These are architectural checks, not an adversarial
security proof against deliberately malicious Haskell source.
