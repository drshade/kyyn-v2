---
id: 0009
title: 'Typed capability rows describe program effects'
status: proposed
date: 2026-09-25
---
# Typed capability rows describe program effects

Basis: the typed Program, snapshot-read encoding and generated plugin acquisition/
captured-read adapters pass the pinned MicroHs/GHC proofs. Native dispatch connects
filesystem and snapshot reads to evidence publication. Source registration and
configured instances, CLI acquisition and captured-read KB-tool composition are
implemented. Judgement extends the tool row under ADR 0027.
Installed network connectors receive HTTP, plugin secret access and cancellable
waits. Explicit connector login additionally receives user instructions on stderr.
Registration checks the selected context and login signature; compilation and
discovery do not execute login. File and captured-read contexts remain separate.

## Context

“PluginHost” and “KnowledgeBaseHost” are useful contexts but become service
locators if every operation is available everywhere. Hidden `IO` would reproduce
the prototype's boundary problems on the other side of the pipe.

## Decision

The capability row is the contract; role names are useful descriptions, not a
separate product permission taxonomy. Retain these explicit boundaries:

- Validators and pure transformation helpers calculate over supplied inputs.
- Evolution execution follows [ADR 0010](0010-evolutions.md#pure-evolution-execution).
- Snapshot queries and output renderers may read their selected immutable snapshot,
  not live providers. A renderer can compose multiple queries in that context.
- KB tools compose captured-evidence plugin reads and
  [model judgements](0027-judgement.md); they do not acquire evidence, invoke sinks
  or propose/accept roots.
- Accepted-root publication is not a guest capability.
- Delivery invokes a configured plugin sink with its prepared typed input under
  ADR 0017; it does not implicitly render or accept knowledge.

Illustrative capability sets, not a closed list of mandatory roles:

| Program | Available work | Excluded work |
| --- | --- | --- |
| Validator / pure transformation helper | Pure input-to-result calculation | Host calls, current time, provider access |
| Snapshot query/output renderer | Typed reads of one selected immutable snapshot; pure computation and query composition | Proposal writes, live providers, sink invocation |
| Evolution entry point | [ADR 0010's transformation contract](0010-evolutions.md#pure-evolution-execution) | Accepted-root publication, nested proposal authoring, delivery |
| KB tool | Typed plugin captured reads and model judgements under ADR 0027 | Evidence acquisition, sinks, proposal/accepted-root writes |
| Source acquisition method | HTTP/filesystem acquisition, secret read/write, prior evidence snapshot reads | Interactive login, KB acceptance, sink invocation |
| Explicit connector login | HTTP, secret read/write, user instructions and cancellable waits | Evidence publication, KB acceptance |
| Captured-evidence plugin method | Typed reads of the selected evidence snapshot; pure interpretation | Live acquisition, secrets, sinks, KB acceptance |
| Sink connector method | Prepared typed input and instance config; filesystem/Git/HTTP/Secrets as declared | KB acceptance or implicit curation |

A plugin can export source and sink connectors, but registration and host
dispatch use the declared capabilities of the selected method. Provider-read
intent is declared by the plugin author, not proven by an HTTP verb or method
label. The host checks supported methods, contracts and available capabilities;
generic HTTP cannot establish that a remote operation is read-only.

Application operations compose output preparation and explicit sink invocation
as specified in ADR 0017. The KB renderer computes the typed input; it does not
invoke the sink itself or use the KB-tool entry point. Prepared
values are inspectable, but types do not prove that someone inspected them.
Configured headless automation can call the same operations without human approval
at each invocation. Query browsing does not pass through this output path.

Use composable typed request algebras with a pure `Program capabilities a`-like
representation in the guest. The exact MicroHs-compatible encoding is not
assumed to be host `effectful`. `PluginHost` and `KnowledgeBaseHost` can be aliases
for selected capabilities, not an all-access record. A request's result type
determines the continuation input; a raw wire value never reaches it unchecked.

The request/result relationship uses a typed request tree, without selecting a
type-family-based row library:

```haskell
data Program request a where
  Pure    :: a -> Program request a
  Request :: request x -> (x -> Program request a) -> Program request a

request :: effect a -> Program effect a

interpretProgram
  :: Monad m
  => (forall x. effect x -> m x)
  -> Program effect a
  -> m a
```

The existential `x` links a request to exactly the value accepted by its
continuation. `interpretProgram` is a pure fold into an explicit handler, not
native IO hidden in the authored program. The generated transport handler uses
private adapter IO; ordinary code builds `Program`. The shared implementation
compiles unchanged under GHC and pinned MicroHs, including dependent continuations
whose read operations return different payload types.
The continuation stays in the running guest and is never encoded on the wire.

The first snapshot interpreter is entirely local and pure. Its generated binding
associates a collection's declared identity with its typed root selector:

```haskell
data CollectionBinding root fact = CollectionBinding String (root -> [Fact fact])

data SnapshotRead root a where
  ReadCollection :: CollectionBinding root fact -> SnapshotRead root [Fact fact]
  ReadFact :: CollectionBinding root fact -> FactId
           -> SnapshotRead root (Maybe (Fact fact))

newtype Query root a = Query (Program (SnapshotRead root) a)

runLocally :: root -> Program (SnapshotRead root) a -> (a, [ReadAccess])
data ReadAccess = CollectionRead String | FactRead String FactId
```

The adapter receives the whole root and query arguments on stdin and returns the
result and ordered logical read trace. There is no request wire encoding or host
request loop in this implementation. Missing facts still appear as fact-read
requests; repeated reads and conditional branches retain their execution order.
This is execution information, not declared evolution evidence, a cache key, or
a claim that arbitrary Haskell computation is statically understandable. It does
not list every physical read needed to load the root.

Generated bindings give authored modules a root-specific `Query a` alias. Changing
the storage/transport interpreter must not force business queries to handle wire
values or continuations themselves. Paging and plugin calls are later additions,
not speculative constructors in the current request algebra.

Plugin acquisition now composes capability algebras using a typed sum:

```haskell
data (left :+: right) a = InLeft (left a) | InRight (right a)

data EvidenceRead payload a where
  ListEvidenceIds :: EvidenceSnapshot payload
                  -> EvidenceRead payload (Either FetchError [EvidenceId])
  ReadEvidence :: EvidenceSnapshot payload -> EvidenceId
               -> EvidenceRead payload (Either FetchError (Maybe (Evidence payload)))

data FileRead a where
  ListFiles :: FilePath -> Bool -> FileRead (Either FetchError [FilePath])
  ReadTextFile :: FilePath -> FileRead (Either FetchError CapturedText)

data CapturedText = CapturedText String EvidenceFingerprint

type CapturedRead payload a = Program (EvidenceRead payload) a
```

A registered captured method implements:

```haskell
content :: Input -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Result)
```

The compiler derives `Input`, `Payload` and `Result` from the authored signature
under ADR 0015, then generates the execution adapter. SDK types/helpers are generic
in payload, so inspection needs no pre-generated bindings. The author writes neither an IO entry nor a codec. The host supplies
the latest captured evidence at invocation start; method failure does not fetch or
change that evidence. ADR 0015 owns registration and checked native dispatch.

The snapshot argument is explicit. `Host.Acquisition` is the SDK row defined below;
captured readers have only the two snapshot questions above. Native text
acquisition decodes UTF-8 and computes a lowercase hexadecimal SHA-256 fingerprint
from the same captured bytes. The generated `readTextFile` returns both together.
The folder
proof requires an absolute directory and returns a typed error before requesting
effects for a relative path. Enumeration failure is a typed error, never an empty
directory. The generated adapters and request/response transport are exercised
under both compilers with recording responses. The native MicroHs broker additionally
exercises live filesystem acquisition and EvidenceStore publication, including
invocation-local reads and failed acquisitions that leave the previous head unchanged.

### Provider acquisition and explicit login

Microsoft Graph supplies the concrete consumer for HTTP and secret requests.
Keep these ordinary typed guest algebras; the broker delegates to host plumbing
interpreters rather than performing IO itself. These sketches describe the first
text-based HTTP boundary, sufficient for JSON Graph and form-encoded token requests:

```haskell
data HttpRequest = HttpRequest
  { method :: String, url :: String
  , headers :: [(String, String)], body :: String
  }
data HttpResponse = HttpResponse
  { status :: Int, headers :: [(String, String)], body :: String }

data Http a where
  SendHttp :: HttpRequest -> Http (Either HttpError HttpResponse)

data Secrets a where
  GetSecret :: String -> Secrets (Either SecretError String)
  PutSecret :: String -> String -> Secrets ()

data LoginInteraction a where
  DisplayInstructions :: String -> LoginInteraction ()

data Waiting a where
  WaitSeconds :: Int -> Waiting ()

type Acquisition payload a =
  Program (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: EvidenceRead payload)))) a
type PluginLogin a =
  Program (Http :+: (Secrets :+: (Waiting :+: LoginInteraction))) a
```

Native HTTP handles TLS and UTF-8 transport. HTTP status responses remain values
for provider code to interpret; transport failures have sanitized diagnostics,
not a serialized native exception containing request details. Secret storage
failures and cancellation remain invocation failures. Validate secret names at
the host boundary using ADR 0016's existing rule. Waits require nonnegative
durations and remain cancellable. No host OAuth implementation is introduced.

Every source connector uses this one acquisition row, generated adapter and host
dispatcher. Generated helpers hide sum injections and protocol codecs; a fetch can
combine file, HTTP, secret, waiting and evidence requests without another registration
declaration. Acquisition can save a rotated credential and wait, but cannot display
interactive instructions. Optional login uses its separate row and can guide a user
but cannot publish evidence. Absent capabilities fail compilation or protocol dispatch.
Neither row is added to captured-read methods, KB tools, validators or evolutions.

Graph acquisition honours valid `Retry-After` delays on 429/503 responses through
`WaitSeconds` before retrying the failed request. Without a usable delay it returns
an actionable retry-later error, not a tight retry loop. Cancellation interrupts
the wait and abandons acquisition without publishing a partial batch. Retry policy
belongs to the plugin; HTTP transport does not hide retries of arbitrary requests.
This follows [Graph's throttling guidance](https://learn.microsoft.com/en-us/graph/throttling).

`DisplayInstructions` is deliberate output of a selected login operation, not
generic logging of an HTTP response. The CLI writes those instructions to stderr
so `--json` stdout remains the final structured result. Routine traces follow
[ADR 0016's secret/transport omission rule](0016-connections.md#trust-and-consequences).
Provider code chooses the user-facing instructions and safe errors; token response
bodies are not echoed. [ADR 0016](0016-connections.md#authentication-belongs-to-the-integration)
owns login registration and authentication behavior.

### KB-tool read composition

The initial generated `Tool a` is `Program Calls a`, where `Calls` is a closed
GADT with one typed constructor per advertised captured-read method, plus the
judgement operations specified in [ADR 0027](0027-judgement.md). Its input
and output refer to the plugin's actual Haskell types. Generated proxy functions
hide these constructors and wire codecs from authors:

```haskell
content :: Files.Instance -> ContentId -> Tool (Either FetchError Content)
```

The host resolves the named instance against the selected code/configuration,
checks its connector type and method, and lazily loads its latest captured input
on first use. It reuses that explicit input for subsequent calls to the same
instance during this tool invocation; it does not reopen the evidence store per
callback. Each method executes in the plugin's captured-read context. The first
implementation starts a method guest per call, without a plugin-process pool.

A method's declared `FetchError` remains a typed value that the helper may handle.
Not-fetched, incompatible-producer and invalid stored evidence stop the invocation
with a diagnostic naming the instance; these are not converted into catchable
method failures. Acquisition and sink requests are absent from this caller row.

Acquisition and captured reads have distinct request algebras. A KB tool may compose
`MailReads :+: CalendarReads`, but its interpreter supplies neither acquisition nor
sink handlers. Plugin read implementations likewise receive captured-store reads,
not HTTP/Secrets. Calling a read method therefore does not hide a fresh fetch in
browsing. Pure helpers can be shared by both kinds of plugin implementation.
The generated signatures and installed handler rows must agree.

### Typed dispatch

Generated ergonomic helpers perform the sum injections, so KB authors need not
write `InLeft` or `InRight` at each call. Adding a row-membership library is an
alternative implementation of this composition, not a different capability model.
A request interpreter for `SnapshotRead` cannot accept `ReadEmail` by type. This
does not establish an OS sandbox or prove two runtime snapshot IDs are equal.

Generated private adapters interpret guest requests via the native host's
semantic operations. A guest package cannot import the adapter implementation
as its ordinary API. No native accepted-ref capability is exported to guests.

A generated plugin-call capability is also a typed request in the **caller's**
algebra. The host routes it to a separately interpreted plugin invocation. The
plugin's implementation requirements do not become requirements available to the
caller. The generated caller proxy, plugin registration and host dispatch must be
proved together; registering a `Method PluginHost input output` does not by itself
make that method callable through the generated `Tool` interface.

On the host, the broker requires GuestExecution plus precisely the capabilities
it dispatches, not GuestCompilation. For example:

```haskell
executeAcquisition
  :: (GuestExecution :> es, FileAcquisition :> es, Failure :> es)
  => CompiledProgram -> Value -> Maybe CurrentEvidence
  -> Eff es (Either [Diagnostic] Value)
```

The acquisition workflow loads current evidence before entering the broker.
Its argument value is assembled from checked config and typed fetch options;
the envelope is wire data, not a value stamped with the config-only contract.
Guest evidence reads use that immutable input directly; the broker has no
EvidenceStore requirement. Publication uses the loaded fetch as its expected base.
When the producer has changed, acquisition instead starts empty and uses the
head observed before the refused load as its replacement base.

GuestExecution supplies both one-shot evaluation and conversational execution
(ADR 0002). The latter preserves the broker callback's effect row while the guest
continuation waits for a reply; moving process execution does not grant additional
guest capabilities or change the request protocol.

## Alternatives and consequences

Reject arbitrary `IO`, a universal untyped host RPC escape hatch, or a durable
continuation service. Also reject pretending capability omission is an OS
sandbox. Host-authored adapters legitimately perform transport IO; authored
programs do not. New capabilities require a real use case and a reviewed type,
not speculative stubs for every possible integration.

## Verification

Compile ordinary composition and examples with missing required capabilities under pinned MicroHs.
Script host responses and test a live continuation across several requests.
Reject an unexpected capability before dispatch. Prove a captured-read method call
routes through the plugin's own context without granting acquisition capabilities
to the caller or causing a broker deadlock. ADR 0027 owns judgement-specific proofs.
