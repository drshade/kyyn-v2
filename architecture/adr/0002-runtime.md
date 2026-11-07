---
id: 0002
title: 'Native host and KB-owned Nix guest builds'
---
# Native host and KB-owned Nix guest builds

## Context

KB authors need ordinary Haskell libraries for calculations, rendering and
integration without a host release for every dependency. Compiler-specific type
inspection in the host couples that freedom to the host's compiler frontend.
The host needs checked contracts and a managed executable, not the guest's
compiler AST or a prescribed global library set.

## Decision

Keep the native GHC host. Each KB is a Nix flake: `flake.nix` declares its build
and `flake.lock` pins external inputs, including the compiler, Kyyn guest SDK and
libraries. Use Nix's existing lock file, not another dependency registry. GHC is
the first guest compiler. Other implementations may satisfy the same build,
description and invocation boundary; do not implement a second backend now.

The KB author selects arbitrary libraries. Vendored tap plugins remain source
under ADR 0015 and use the KB's selected SDK and dependency environment. Their
adapters are built with that environment; no per-plugin compiler or SDK universe
is resolved by the host. First-party libraries follow the same rule.

Authors and dependencies are trusted. Neither Nix nor Kyyn promises to prevent
direct guest I/O. The typed SDK states the supported role/capability discipline;
the host checks effects requested through its protocol. Build purity and query
purity are author obligations, not a security sandbox or an assurance about
arbitrary native libraries. Build/describe must not read facts, secrets, live
providers or the wall clock to determine contracts or generated code.

### Capture and build

The host captures the selected source/configuration and the flake/lock bytes.
Facts, evidence, credentials, `.git`, disposable caches and unrelated workspace
files are excluded from Nix inputs: the Nix store is not a private KB data store.
The flake must build from this explicit source tree and locked dependencies,
without reading the mutable original checkout or ambient package databases.
Local path dependencies are captured with the source; external inputs must be
locked and available. Reject inputs outside that captured/locked closure.

The conventional flake output is `packages.${system}.kyyn-guest`, containing
`bin/kyyn-guest`. The SDK provides the build helper for this output. The host
supplies a fixed build selection in the captured tree; it is a build input, not
an ambient environment override. Exact internal build-request encoding is private.

```haskell
data GuestSelection
  = RootEntries
  | EvolutionEntry
  | DiscoveryEntries DiscoverySelection

data GuestSources -- captured source, manifests, flake/lock and build selection

data BuildIdentity = BuildIdentity
  { sourcesDigest :: Bytes
  , targetSystem :: String
  , derivationPath :: FilePath
  , outputPath :: FilePath
  }

data CompiledProgram -- identity plus retained immutable output and entry point

data GuestCompilation :: Effect where
  CompileGuest
    :: GuestSources
    -> GuestCompilation m (Either [Diagnostic] CompiledProgram)

compileGuest
  :: GuestCompilation :> es
  => GuestSources -> Eff es (Either [Diagnostic] CompiledProgram)
```

The host selects the execution platform; the flake supplies that platform's build.
An absent output, unlocked dependency, unsupported selection or missing executable
is a diagnostic. No automatic lock update or backend fallback occurs during a
check. A source/type rejection remains distinct from missing provisioning or an
unavailable build/runtime process; do not parse compiler prose to decide control flow.
Preserve compiler messages and source locations where available.

The SDK owns generic contract derivation, compiler-checked export inspection and
private entry adapters (ADR 0005). Contract instances live with authored types;
there is no generated-contract import cycle. A narrow Root-schema prepass produces
collection/edit bindings for their consumers. After authored exports type-check,
the build generates and compiles the private entry adapters. All stages use the
same compiler, SDK and lock inside one Nix derivation, not a host
describe/codegen/rebuild round trip. Codecs and embedded descriptions use the same
SDK lowering. An unsupported contract shape or incompatible renderer/sink binding
fails the build.

Discovery selection compiles only the exports/schema dependencies needed for the
requested catalogue (ADR 0018). An incomplete evolution body must not prevent
Before/After schema or generated-handle discovery. Root and evolution selections
compile the corresponding runnable entries. Discovery builds do not establish
that the full root or transformation compiles or passes semantic validation.
When full compilation fails, source-only discovery can still report valid schema
information separately from implementation diagnostics. Do not assume a failed
Nix derivation publishes successful partial outputs.

Checks may ask Nix to fetch or build the exact locked inputs and outputs (ADR
0020). They never update the lock or resolve an alternative dependency version.
Missing inputs, network/build failures and unavailable platform outputs are normal
setup/build diagnostics. A binary cache may supply an exact output; a cache miss
may require a local build. No unmeasured build-latency promise is made.

Nix identities cover compiler, SDK, library inputs and build options through the
derivation. The capture digest also records selected source paths/bytes and entry
selection. Fact values and invocation arguments are not compiler inputs. Retain
an output through ordinary Nix output retention for as long as an in-flight or
cached CompiledProgram uses it; cache removal may release that retention. No
accepted-revision closure registry or historical guest build is required.
The host may reuse a retained output across commands by the capture digest and
execution platform. Store the successful Nix build result beside its retention
link; require both the retained executable and immutable output to exist before
reuse. Missing or unreadable result data and missing outputs take the normal
locked Nix build path. Never cache failed builds. This is disposable build data,
not a second dependency lock or an accepted-revision registry.
Never return a bare temporary build-directory path. Cache deletion discards derived code, not accepted knowledge.

### Describe and invoke the same build

The host invokes the immutable executable's description entry through the framed
protocol (ADR 0007), checks it under ADR 0005, and uses that same CompiledProgram
for execution. It does not independently resolve a flake or latest workspace
between describe and invoke. Descriptions may be cached by build identity, but
are derived data, not an additional authored or committed schema authority.

```haskell
data GuestDescription -- current protocol identity, contracts, entries and API exports

data GuestInspection :: Effect where
  DescribeGuest
    :: CompiledProgram
    -> GuestInspection m (Either [Diagnostic] GuestDescription)

data GuestExecution :: Effect where
  ExecuteCompiled
    :: CompiledProgram -> Bytes
    -> GuestExecution m (Bytes, ProcessExit)
  ExecuteGuest
    :: CompiledProgram -> Bytes -> (Bytes -> m (Maybe Bytes))
    -> GuestExecution m (Bytes, ProcessExit)
```

A prepared `CompiledEntry` pairs that immutable program with an entry from its
checked description. Its constructor is private: brokers receive a verified entry,
not a free-text dispatch name or a separately compiled adapter.

Description takes no facts, secrets or capability grants. It returns build-derived
structure and pure authored metadata, not query results. The host rejects malformed
descriptions, unsupported shapes and an incompatible current protocol identity;
there is no version negotiation or historical runtime. Different SDK revisions may
implement the same current protocol. The author updates an incompatible pin through
ordinary source repair; the host does not rewrite the lock automatically.

Invocations retain the existing typed entry contracts and capability requests.
Only request/result data crosses the boundary; a generated adapter holds the live
continuation. Process loss loses the current call, not accepted state. No closure
serialization, persistent worker pool or in-process ABI is required.

Compilation and execution remain plumbing capabilities. The Nix build interpreter
and native process interpreter live in host plumbing; compiler-specific inspection
and adapter generation live in guest build tooling. Composition resolves Nix's
absolute executable path and supplies it explicitly. It does not rediscover a
compiler from PATH or an ambient Cabal environment on each invocation.

Nix provisions/builds the executable and its runtime closure. Ordinary execution
launches the selected store executable directly; it does not run a development
shell, update dependencies or invoke Nix for every host call. Runtime facts and
secrets travel only through their existing host operations.

### Process ownership

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

## Development diagnostics

`KYYN_TIMINGS=1` emits timing events to stderr without changing normal/JSON
results. Distinguish dependency provisioning, guest build/cache reuse, description,
execution and command wall time. Durations are inclusive; nested timings must not
be summed as independent costs. Other values leave timing disabled.

## Consequences and verification

The host imports no KB types or guest compiler frontend. Compiler-specific build
tooling is maintained and tested against the compiler it selects. Type checking
is not runtime isolation and the host description checks are not an attestation
of trusted authored code.

Verify fresh builds and reuse of already available dependencies; source/lock/SDK/compiler changes
invalidate derived code while fact-only changes reuse it. Exercise missing locks,
missing outputs, failed builds, output lifetime, cancellation and malformed describe
responses. A changed description must not silently relabel stored facts: normal decoding, contract checks and explicit evolution conversion
still apply.

Run a real GHC guest through discovery, runtime fact loading, validation, query,
plugin host calls, typed evolution and output publication. Test the actual guest
protocol and dependency environment, not only host-linked SDK unit tests. Verify the decided contract shapes and exact-value semantics; existing
fixtures and KBs impose no compatibility or porting requirement. Verify Linux, macOS and WSL2 distribution separately.
