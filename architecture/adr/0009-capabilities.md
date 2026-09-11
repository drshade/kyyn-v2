---
id: 0009
title: 'Typed capability rows describe program effects'
status: accepted
date: 2026-09-11
---
# Typed capability rows describe program effects

Basis: the accepted typed Program and snapshot-read encoding has passed the
pinned MicroHs/GHC feasibility proof; plugin capability composition and transport
remain unimplemented. The KB-tool read boundary is under design review.

## Context

“PluginHost” and “KnowledgeBaseHost” are useful contexts but become service
locators if every operation is available everywhere. Hidden `IO` would reproduce
the prototype's boundary problems on the other side of the pipe.

## Decision

The capability row is the contract; role names are useful descriptions, not a
separate product permission taxonomy. Retain these explicit boundaries:

- Validators and pure transformation helpers calculate over supplied inputs.
- Evolution entry points may use declared snapshot/evidence/plugin capabilities
  while producing a candidate; they do not accept it or start a nested proposal.
- Snapshot queries and output renderers may read their selected immutable snapshot,
  not live providers. A renderer can compose multiple queries in that context.
- The proposed KB tools compose selected-root and captured-evidence plugin reads; they do not fetch from providers,
  invoke sinks or propose/accept roots.
- Accepted-root publication is not a guest capability.
- Delivery invokes a configured plugin sink with its prepared typed input under
  ADR 0017; it does not implicitly render or accept knowledge.

Illustrative capability sets, not a closed list of mandatory roles:

| Program | Available work | Excluded work |
| --- | --- | --- |
| Validator / pure transformation helper | Pure input-to-result calculation | Host calls, current time, provider access |
| Snapshot query/output renderer | Typed reads of one selected immutable snapshot; pure computation and query composition | Proposal writes, live providers, sink invocation |
| Evolution entry point | Selected snapshot/evidence reads and declared plugin acquisition/read calls | Accepted-root publication, nested proposal authoring, delivery |
| KB tool (proposed addition) | Declared SnapshotRead root and typed plugin reads against selected captured evidence; pure composition | Live acquisition, sinks, proposal/accepted-root writes |
| Source acquisition method | HTTP/filesystem acquisition, secret lookup, prior evidence snapshot reads | KB acceptance, sink invocation |
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

Composition of capability algebras can later be as small as a typed sum:

```haskell
data (left :+: right) a = InLeft (left a) | InRight (right a)

-- Illustrative generated proxy for a registered Microsoft method.
data MicrosoftCalls a where
  ReadEmail :: Mail.Instance -> EmailId -> MicrosoftCalls Email

type EvolutionHost root = SnapshotRead root :+: MicrosoftCalls
```

This particular `EvolutionHost` is an illustrative evolution entry's
context, not an all-purpose permanent role. [Storage](0006-storage.md) owns the
guest `Fact` envelope. The generated instance value selects the configured Mail
instance; the invocation context resolves its fixed `EvidenceSnapshotRef` under
ADR 0014. The plugin reads that captured evidence through its own host capabilities.
Another registered method can explicitly acquire fresh evidence. The generated
proxy carries a method identity and checked types, not arbitrary code over JSON.

### Proposed addition: KB-tool read composition

Acquisition and captured reads have distinct request algebras. A KB tool may compose
`SnapshotRead root :+: (MailReads :+: CalendarReads)`, but its interpreter supplies neither acquisition nor
sink handlers. Plugin read implementations likewise receive captured-store reads,
not HTTP/Secrets. Calling a read method therefore does not hide a fresh fetch in
browsing. Pure helpers can be shared by both kinds of plugin implementation.
An evolution may declare acquisition separately; selecting its returned fetch is
explicit and does not silently replace an already selected snapshot. Role labels
do not enforce this: the generated signatures and installed handler rows must agree.

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
plugin's HTTP/Secrets requirements do not become requirements available to the
caller. The generated caller proxy, plugin registration and host dispatch must be
proved together; registering a `Method PluginHost input output` does not by itself
make that method callable as `Program EvolutionHost output`.

## Alternatives and consequences

Reject arbitrary `IO`, a universal untyped host RPC escape hatch, or a durable
continuation service. Also reject pretending capability omission is an OS
sandbox. Host-authored adapters legitimately perform transport IO; authored
programs do not. New capabilities require a real use case and a reviewed type,
not speculative stubs for every possible integration.

## Verification

Compile ordinary composition and examples with missing required capabilities under pinned MicroHs.
Script host responses and test a live continuation across several requests.
Reject an unexpected capability before dispatch. Prove a KB acquisition call
routes through a plugin's own host context without granting the caller that
plugin's HTTP/Secrets capabilities or causing a broker deadlock. The plugin itself
can receive raw secret values under ADR 0016; this is not credential containment.
