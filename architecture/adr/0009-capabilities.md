# 0009 — Typed capability rows describe program effects

Status: Proposed. Guest effect encoding remains a bounded SDK design gate.

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
- Accepted-root publication is not a guest capability.
- Delivery invokes a configured plugin sink with its prepared typed input under
  ADR 0017; it does not implicitly render or accept knowledge.

Illustrative capability sets, not a closed list of mandatory roles:

| Program | Available work | Excluded work |
| --- | --- | --- |
| Validator / pure transformation helper | Pure input-to-result calculation | Host calls, current time, provider access |
| Snapshot query/output renderer | Typed reads of one selected immutable snapshot; pure computation and query composition | Proposal writes, live providers, sink invocation |
| Evolution entry point | Selected snapshot/evidence reads and declared plugin acquisition/read calls | Accepted-root publication, nested proposal authoring, delivery |
| Source connector method | HTTP read/query, secret lookup, scoped cache/checkpoint operations | KB acceptance, sink invocation |
| Sink connector method | Prepared typed input and instance config; filesystem/Git/HTTP/Secrets as declared | KB acceptance or implicit curation |

A plugin can export source and sink connectors, but registration and host
dispatch use the declared capabilities of the selected method. Provider-read
intent is declared by the plugin author, not proven by an HTTP verb or method
label. The host checks supported methods, contracts and available capabilities;
generic HTTP cannot establish that a remote operation is read-only.

Application operations compose output preparation and explicit sink invocation
as specified in ADR 0017. The KB renderer computes the typed input; it does not
invoke the sink itself or need a fourth effectful workflow entry point. Prepared
values are inspectable, but types do not prove that someone inspected them.
Configured headless automation can call the same operations without human approval
at each invocation. Query browsing does not pass through this output path.

Use composable typed request algebras with a pure `Program capabilities a`-like
representation in the guest. The exact MicroHs-compatible encoding is not
assumed to be host `effectful`. `PluginHost` and `KnowledgeBaseHost` can be aliases
for selected capabilities, not an all-access record. A request's result type
determines the continuation input; a raw wire value never reaches it unchecked.

We can show the request/result relationship without prematurely selecting a
type-family-based row library. One candidate core is a typed request tree:

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
private adapter IO; ordinary code builds `Program`. This is the candidate encoding
to compile/test under pinned MicroHs, not a claim that the proof already passed.
The continuation stays in the running guest and is never encoded on the wire.

Composition of capability algebras can initially be as small as a typed sum:

```haskell
data (left :+: right) a = InLeft (left a) | InRight (right a)

data SnapshotRead a where
  ReadPage
    :: SnapshotRef -> CollectionBinding fact -> PageRequest
    -> SnapshotRead (Page (Fact fact))

-- Illustrative generated proxy for a registered Microsoft method.
data MicrosoftCalls a where
  ReadEmail :: EvidenceRef -> EmailId -> MicrosoftCalls Email

type EvolutionHost = SnapshotRead :+: MicrosoftCalls
```

This particular `EvolutionHost` is an illustrative evolution entry's
context, not an all-purpose permanent role. `SnapshotRef` denotes an explicitly
selected host snapshot; `CollectionBinding fact` is a generated handle connecting
the collection contract to the guest payload type. The host verifies both snapshot
and collection context. [Storage](0006-storage.md) owns `Page` and the guest `Fact`
envelope. `EvidenceRef` selects already fetched evidence; the plugin reads it
through its own host capabilities. This method need not contact the provider.
Another registered method can explicitly acquire fresh evidence. The generated
proxy carries a method identity and checked types, not arbitrary code over JSON.

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
