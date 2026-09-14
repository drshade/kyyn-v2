---
id: 0002
title: 'Native Haskell kernel and bundled MicroHs execution'
status: proposed
date: 2026-09-09
---
# Native Haskell kernel and bundled MicroHs execution

Basis: owner-established distribution direction. Runtime integration and release
gates remain outstanding; the scoped process interface below specifies native
implementation mechanics, not a renewed toolchain choice.

## Context

KBs and plugins contain code written after Kyyn is installed. Requiring a
different language toolchain for every plugin defeats a coherent distribution.
The native kernel needs mature integration libraries; authored programs need a
small, uniform typed runtime, not the kernel's full dependency graph.

## Decision

Use a GHC-built Haskell kernel and pinned MicroHs compiler/evaluator for both
KB-resident and tap-provided programs. Ship the compiler, evaluator, base/SDK
libraries and required preprocessing tools, including `cpphs`.
Tap plugins arrive as vendored source under ADR 0015 and are compiled locally
with this toolchain. The bundled compiler/evaluator are release executables;
third-party plugin executables are not an additional distribution contract.

Stage the pinned MicroHs compiler using its upstream GHC-built `bin/gmhs` target,
installed at the existing `bin/mhs` path; the self-hosted `make bin/mhs` remains
the bootstrap/reference build. The metadata-entry comparison measured 1.3 seconds
versus 30.0 seconds with identical bytecode, without adding a cache or changing
the guest interface. Full integration includes that bytecode parity fixture and
the installed journey; existing guest suites also exercise the self-hosted build.
This changes how the same compiler source is built, not its revision or language.

Initially invoke a managed child process with a private typed protocol. A
generated adapter retains the live continuation while requesting host effects.
Only request/result data crosses that boundary. Process loss loses the current
call, not accepted state. No serialization of closures or durable continuations.
No in-process ABI or persistent worker pool until demonstrated needs justify it.

The native side compiles code separately from loading fact values. Porcelain
interpretation selects the source modules and prepares generated adapters from the
captured code; it does not assemble MicroHs commands. Compilation is a plumbing
capability whose inputs contain no KB/root layout or fact data:

```haskell
data GuestSources  -- fixed module contents, generated adapters and selected entry
data CompiledProgram  -- immutable bytecode and build identity; no launch configuration

data GuestCompilation :: Effect where
  CompileGuest
    :: GuestSources
    -> GuestCompilation m (Either [Diagnostic] CompiledProgram)

compileGuest
  :: GuestCompilation :> es
  => GuestSources -> Eff es (Either [Diagnostic] CompiledProgram)
```

`GuestSources` is a fixed compilation input, not the host's `CodeSnapshot` or a
live workspace directory. Composition combines captured KB/generated modules with
the installed SDK/runtime/dependency source bytes to form this input. It does not
require vendoring the installed SDK into each KB repository. Its digest covers
those bytes alongside authored sources, not an unrecorded SDK include directory.
It includes the selected local dependency source closure;
semantic preparation selects which captured files become source and which are
runtime configuration, examples or data. Schema inspection and pure adapter
generation retain their ownership in [ADR 0005](0005-contracts.md).

The capability and its forwarding helper belong to `kyyn-plumbing`. Its interpreter
belongs to `kyyn-microhs`, where compiler flags, `MHSDIR`, `cpphs` paths and compiled
artifact layout are understood. The installed toolchain is supplied explicitly by
application composition, not rediscovered from a caller's ambient PATH:

```haskell
data GuestToolchain  -- resolved installed compiler/evaluator, preprocessor and SDK

runGuestCompilation
  :: (FileSystem :> es, ProcessExecution :> es, Failure :> es)
  => GuestToolchain -> Eff (GuestCompilation : es) a -> Eff es a
```

The interpreter writes source/build artifacts through FileSystem and invokes the
compiler through ProcessExecution; it does not need ambient IO merely because its
package also contains native compiler-library integration. Composition supplies
the same selected toolchain to schema inspection and guest compilation. Inspection
and compilation do not choose independent compiler revisions.

The first interpreter compiles the captured files in a temporary filesystem scope
and returns MicroHs `.comb` bytes. It does not ask MicroHs to generate a native
executable, which would invoke a C compiler on the user's machine. The installed
`mhseval` consumes these bytes. C remains a development/distribution build input
for the bundled compiler and evaluator, not a KB-authoring dependency.

`GuestSources` checks duplicate paths, file/directory collisions and presence of
the selected entry. Its source identity is SHA-256 over the selected entry and a
sorted, length-delimited path/byte sequence. The captured file tree includes the
generated adapters and required SDK/dependency source; it contains no fact values.
The interpreter clears ambient source/package search paths and selects the bundled
library explicitly. Its compiler environment selects `MHSDIR` and `MHSCPPHS` and
has an empty `PATH`. Compilation currently has one supported mode: uncompressed
combinators. No build-options type precedes a concrete second mode.
The current locale selection is `C.UTF-8`, verified on Linux; the installed
toolchain composition must establish the appropriate selection on other supported
platforms before their release gates pass.
Source-path collision checks currently compare names case-sensitively. Platforms
with case-insensitive filesystems also need their filename collision behavior
verified before the same source-tree contract can be claimed there.

The returned artifact records its input identity:

```haskell
data BuildIdentity = BuildIdentity
  { toolchainRevision :: String
  , sourcesDigest     :: Bytes
  }

data CompiledProgram = CompiledProgram
  { identity :: BuildIdentity
  , artifact :: (RelativePath, Bytes)
  }

data GuestExecution :: Effect where
  ExecuteCompiled
    :: CompiledProgram -> Bytes
    -> GuestExecution m (Bytes, ProcessExit)
  ExecuteGuest
    :: CompiledProgram -> Bytes -> (Bytes -> m (Maybe Bytes))
    -> GuestExecution m (Bytes, ProcessExit)

executeCompiled
  :: GuestExecution :> es
  => CompiledProgram -> Bytes -> Eff es (Bytes, ProcessExit)

executeCompiledEntry
  :: (GuestExecution :> es, Failure :> es)
  => String -> CompiledProgram -> Bytes -> Eff es Bytes
```

The revision identifies the selected pinned MicroHs source; it is not an
attestation of arbitrary installed binaries. There is no persistent artifact cache
in this increment. Reuse the immutable `CompiledProgram` for multiple runtime inputs.
Its representation belongs to the domain package so porcelain can carry prepared
code without depending on plumbing. ExecuteCompiled materializes the artifact in
a fresh temporary scope; its interpreter supplies the evaluator and launch
configuration from the explicitly installed toolchain. Callers do not reconstruct
flags or carry process configuration in domain values. The operation writes the
supplied bytes, closes stdin, drains stdout and returns output plus exit status/stderr.
The selected-entry helper turns a nonzero exit into RuntimeUnavailable; metadata
decoding retains its specific diagnostic context using the raw result.
Process startup/transport failures remain Failure. The build scope can disappear before any invocation, and the invocation
scope is removed after process cleanup. No live build path is returned as the
artifact. GuestCompilation only compiles; GuestExecution owns both one-shot
input/output and framed conversations with host callbacks. Neither execution mode
requires the compilation effect. Its `runGuestExecution` interpreter lives in
`kyyn-microhs` and requires only FileSystem, ProcessExecution and Failure, just as
the compilation interpreter does. Schema metadata, validation and pure query/evolution
adapters use one-shot execution; plugin host calls use the conversational operation.
The conversation's callback stays in the caller's effect row, not native IO.
Both modes retain the same scoped process cleanup and explicit installed toolchain.

Ordinary parse/type rejection returns diagnostics. The preview/checking caller
maps them into its normal result channel; inability to start the compiler or a
compiler crash uses Failure. A broken proposed module is not a broken installation.
For the pinned command-line compiler, status 1 returns its UTF-8 diagnostic text
under `guest.compiler-rejected`, without parsing prose for control flow or source
locations. Other nonzero statuses (including signals) and malformed diagnostic
encoding are operational failures. This does not distinguish an internal compiler
error that itself exits with status 1 from other compiler rejection. Missing or
unreadable artifacts fail at the filesystem boundary; an empty artifact is an
operational failure, not successful compilation.

Process ownership belongs below the semantic runtime. A scoped plumbing primitive
can express who releases the child without handing native `IO` to porcelain:

```haskell
data ProcessExecution :: Effect where
  WithProcess
    :: ProcessSpec -> Eff (ProcessPipes : es) a
    -> ProcessExecution (Eff es) a

withProcess
  :: ProcessExecution :> es
  => ProcessSpec -> Eff (ProcessPipes : es) a -> Eff es a

data ProcessPipes :: Effect where
  WriteStdin
    :: Bytes -> ProcessPipes m ()
  CloseStdin
    :: ProcessPipes m ()
  ReadStdout
    :: ProcessPipes m (Maybe Bytes)
  AwaitExit
    :: ProcessPipes m ProcessExit

data ProcessExit = ProcessExit
  { exitCode :: Int
  , stderr   :: Bytes
  }

runProcessExecutionIO
  :: (IOE :> es, Failure :> es)
  => Eff (ProcessExecution : es) a -> Eff es a
```

`ProcessPipes` is the inner effect installed for the selected child, not a native
handle or a token requiring a registry. Nested `withProcess` calls install distinct
pipe scopes; ordinary effect-row lifting can address an outer scope explicitly.
The interpreter holds native handles privately and preserves the caller's local
effects when interpreting the inner action. It uses effectful's scoped lifting,
not an `IO` callback in the public API.
The initial handler uses `SeqUnlift`: pipe operations stay on the inner action's
thread. An inner action must not fork work that uses these pipes. The sequential
protocol adapter fits this constraint; cancellation comes from the owning caller.
The native stderr worker handles bytes privately and does not execute guest or
caller effects on its worker thread.

`Nothing` means EOF, not a successful protocol result. Reads are byte chunks, not
complete messages; [the adapter](0007-wire.md) owns framing. Writes flush; closing
stdin signals input completion. Callers drain stdout or finish their protocol
before awaiting exit, since an unread output pipe can fill. Stderr drains
concurrently and is returned as bytes with the exit status, not printed or logged.
A nonzero exit is data for the compiler/runtime caller to interpret. Spawn and
pipe IO failures use the operational Failure channel; cancellation propagates
after cleanup rather than being misclassified as process rejection.
If cleanup itself fails after a successful inner action, report that operational
failure. When already unwinding an exception or cancellation, a secondary cleanup
IO error must not replace the primary failure; cleanup is best-effort on that path.

`ProcessSpec` supplies an executable, argument list, working directory and complete
environment explicitly. There is no implicit shell command or environment merge.
`WithProcess` owns the child and stderr reader until its inner action returns,
fails or is cancelled; leaving early terminates and reaps the child. Use
`AwaitExit` when normal completion is required. The native interpreter reuses
typed-process for process lifetime and scopes the stderr worker so it is cancelled
before pipes are closed. This is ownership of the directly launched child, not a
process-tree supervisor or a promise of forced termination of arbitrary programs
that ignore termination. Those are not capabilities required by the bundled guest.

## Boundaries and alternatives

The native host must not import KB-specific types; it operates on checked
contracts and opaque root/artifact handles. MicroHs-authored modules must not
import host implementation libraries. A child process is a packaging/failure
boundary, not a sandbox. Reject per-plugin native binaries as the primary model,
and reject moving all host integrations into MicroHs merely to have one compiler.

## Consequences and verification

Dependency/import tests prohibit MicroHs implementation imports and command
construction in porcelain interpreters. Exercise GuestCompilation's diagnostics
versus operational failures, and compilation through the same installed toolchain
used by schema inspection. A fact-only change must reuse an unchanged code build;
changed source, compiler, SDK or build options must not reuse an incompatible one.

MicroHs compatibility is a release gate, not inferred from valid GHC code.
The pinned `4557821` identifies version 0.16.6.0 and matched upstream head when
checked on 5 September 2026. Probes reject type-family syntax used by microlens
and dhall-haskell even after bundled preprocessing. Updating a pin is deliberate.

Before adopting this runtime for production, pass runtime-data decoding,
heterogeneous-root evolution, cancellation and clean-install tests with the
chosen SDK dependencies. If the bridge needs substantial compiler/library forks,
reopen this ADR instead of concealing that cost inside an interpreter.
Name the compatibility checks separately: compile the GADT/existential request
tree and rank-N fold under pinned MicroHs; prove the higher-order `WithProcess`
handler and cleanup under native GHC/effectful. The latter is not guest code.
ADR 0005 records the passing bounded checked-type extraction experiment and the
owner's Haskell schema-authority decision. Production schema-adapter integration
and maintenance remain separate from these runtime compatibility checks.
