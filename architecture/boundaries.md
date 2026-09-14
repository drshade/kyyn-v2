# Boundary map and proposed interface sketches

This is the cross-cutting review companion to ADR 0003. Each owning ADR explains
its decision through interleaved prose, types and signatures; this map links those
definitions rather than maintaining a second API specification. The small
composition below connects them. No implementation or unused effect stub exists.
Resolve contradictions in the owning decision before building the package graph.

## Two axes, not one stack

The host's architectural layers and the host/guest execution boundary are
different distinctions. A pure MicroHs host request is **not** native IO, and a
porcelain interpreter is **not** the runtime's byte decoder.

```text
Human Web       Agent MCP       CLI / external runner
      \             |             /
         typed application operations
                   |
            porcelain capabilities ---------- pure domain
                   |
          porcelain lowering interpreters
                   |
             plumbing capabilities
                   |
             native IO interpreters
                   |
          OS / Git / network / child process

MicroHs authored function -> typed guest capabilities
                                      |
                           generated private adapter
                                      |
                              JSON runtime protocol
                                      |
                      host decoder + capability broker
                                      |
                    selected host semantic capabilities
```

The broker's call back into host operations is controlled dispatch, not an import
cycle. An authored KB method can invoke a typed acquisition plugin method; the
plugin's generated adapter uses its own selected host capabilities. No guest
inherits every capability installed by the native application.
Capability rows are the normative interfaces; program roles describe common
compositions, not a separate permission taxonomy (ADR 0009). The outer invocation
owns nested call lifetimes; its cancellation does not leave orphan plugin calls.
The plugin protocol broker lives in the porcelain-interpreter package as
`Kyyn.Porcelain.Protocol.PluginBroker`: it dispatches decoded requests
to semantic EvidenceStore and selected plumbing capabilities. Byte-frame codecs
remain in plumbing; plumbing never imports porcelain to reach evidence storage.

## Package and module ownership

The [repository layout](adr/0026-repository-layout.md) assigns these responsibilities
to packages. [ADR 0003](adr/0003-effects.md) owns the naming distinction between
`run…` interpreter installation, `execute…` application execution and the underlying
effectful workflow. Package names use `interpreters`, not `lowering` or `runners`.

| Package responsibility | May depend on | Must not depend on |
| --- | --- | --- |
| Shared types | Pure libraries supported by both GHC and MicroHs | Host packages, effects, compiler internals, transport implementation |
| Domain | Shared types and pure value libraries | Effects, adapters, IO interpreters, KB-specific modules |
| Porcelain API/operations | Domain, effectful, other explicit porcelain APIs | Plumbing, native IO, interpreter modules |
| Plumbing API | Small pure primitive types, effectful | Porcelain, application workflows, native implementation |
| Porcelain interpreters | Porcelain and plumbing APIs | Native IO libraries/interpreters, UI |
| Plumbing interpreters | Plumbing API and required native libraries | Domain workflow decisions, UI |
| Native compiler integration | Plumbing API, native compiler implementation and required native libraries | Porcelain workflows, UI |
| Transport adapters | Application request/result API and client transport libraries | Store/Git/provider implementation |
| Composition | Selected operations and interpreters | Authored KB-specific code |
| Guest SDK public API | Shared types and MicroHs-compatible pure libraries | Host kernel, OS IO, generated transport implementation |
| Guest runtime adapter | Public SDK, codec and transport implementation | KB business decisions |

Module examples (one interpreter per capability until there is a real alternative):

```text
Kyyn.Domain.Root
Kyyn.Porcelain.Capability.EvolutionStore
Kyyn.Porcelain.Capability.EvolutionStore.Manifest
Kyyn.Porcelain.Capability.EvolutionStore.Persistence
Kyyn.Porcelain.Interpreter.EvolutionStore
Kyyn.Plumbing.Capability.FileSystem
Kyyn.Plumbing.Interpreter.FileSystem
Kyyn.Plumbing.Capability.GuestCompilation
Kyyn.MicroHs.Interpreter.GuestCompilation
Kyyn.Plumbing.Capability.GuestExecution
Kyyn.MicroHs.Interpreter.GuestExecution
Kyyn.Plumbing.Capability.DhallHandling
Kyyn.Plumbing.Capability.DhallHandling.Schema
Kyyn.Plumbing.Interpreter.DhallHandling
Kyyn.Application.CheckEvolution
Kyyn.Application.Compose
Kyyn.Application.Execution.PreviewEvolution
```

`loadEvolutionManifest` belongs with the capability's operations, not as a public
helper exported from its interpreter. If it decodes the on-disk format using
DhallHandling, that specific implementation belongs in the **porcelain-interpreter package**,
as the non-public `EvolutionStore.Persistence` module above; it cannot be
imported into the porcelain API package. `EvolutionStore.Manifest` in the API
package contains only semantic values and operations, not Dhall implementation.
The shared prefix names the capability owner, not equal dependency privileges.
Keep public semantic manifest operations separate from
that format decoder. Do not solve the dependency error by moving every helper
into an unstructured `Internal.hs`.

Package splits enforce dependency boundaries, not one package per capability or
interpreter. The inventory below is vocabulary, not a list of required services
or empty shells to create before a useful slice.

Pure Dhall schema operations belong with DhallHandling; pure KB evolution rules
belong with Evolution. Purity determines permitted dependencies, not whether a
function deserves a capability home. Handler modules install handlers and map
constructors; substantive reusable operations are capability-owned functions.

## Proposed semantic capabilities

This inventory describes ownership, not a requirement to implement all names
before the first slice. Avoid combining unrelated methods solely to shorten rows.

| Capability | Owns | Does not own |
| --- | --- | --- |
| RootStore | Snapshot loading/materialization, plugin-scoped named connector instances/configs, identified fact reads, stable pages | Local secrets, business validation, accepted-ref update |
| EvolutionAuthoring | Create drafts and capture them against an inspected Before source root | Evolution execution, candidate validation, accepted-ref update |
| EvolutionStore | Workspace list/removal, snapshots and lifecycle, candidates, review notes, archived step reports and record-history reads | Source inspection, local secrets, provider effects or accepted-root update |
| RootExecution | Validate selected roots/configs, execute snapshot queries/examples, prepare typed output inputs through renderers | Live acquisition, effectful evolution entries, sink invocation, publication |
| EvolutionExecution | Compile/evaluate evolution entries, dispatch declared snapshot/plugin calls, derive step reports from annotated before/after values | Accepted-ref publication, inferred evidence provenance, implicit delivery or nested proposals |
| RootPublication | Commit a checked evolution and conditionally advance from its Before revision | Conflict resolution, remote coordination, delivery |
| EvidenceStore | Retained fetch deltas/payloads, selected snapshots and source references (ADR 0014) | Domain classification, accepted curation progress or inferred provider changes |
| PluginInvocation | Invoke locally built source-plugin methods with declared typed capabilities | Raw `call bytes`, separate connection-plugin runtime |
| ArtifactStore | Immutable byte-artifact creation and lookup when needed by typed payloads | Universal output representation or external writes |
| Delivery | Invoke typed input on its configured plugin sink; retain dispatch/outcome state | Query/render evaluation, preview custody or accepted-ref updates |

Failure/progress/cancellation are explicit supporting concerns. Do not inject
clock, logging or a universal environment into a function merely because others
need them. Exact implementation rows may be narrower than the capability table.

Plumbing examples: FileSystem (scoped paths and file/tree primitives),
DocumentPersistence (scoped locked documents under ADR 0003), Git
(objects, trees, refs and transport), ProcessExecution (typed lifecycle/pipe
operations), DhallHandling (real library schema/value functions), HTTP, SecretStore
(local named values, independent of plugins), document decoding, clock/entropy and
transport codecs. Guest Secrets requests return raw values through SecretStore;
plugins own authentication, not a ConnectionUse handler. Pure serialization
need not be an effect; it is a helper within its capability. Native process and
filesystem details stay out of porcelain signatures.
SchemaInspection owns checked-type extraction and checking the selected Haskell
schema metadata export. GuestCompilation owns compilation of explicit source bundles;
GuestExecution owns one-shot and conversational execution of compiled artifacts.
Both interpreters, like SchemaInspection's, live in `kyyn-microhs` and receive the
installed toolchain explicitly. Porcelain interpreters request compilation and
execution separately, not raw MicroHs commands. SchemaInspection uses GuestCompilation
for its fixed metadata adapter and GuestExecution for pure metadata evaluation through
the SDK codec; compilation does not call back into inspection. Neither operation calls
RootExecution or loads facts. This keeps the inspection/compilation dependency acyclic.
The metadata attaches field roles (title/timeline/badge) and declares identities
and references; its data types and authoring example belong to ADR 0005.
DhallHandling remains a separate format/library capability, not a dependency
that root execution acquires by default. See ADR 0005 for the passing bounded
experiment and remaining production integration/maintenance gates.

FileSystem receives a scoped location plus relative path. Its scopes are supplied
by the caller/resolver; they are not constructors called `Facts`, `Evolutions` or
other business entities. A semantic store maps those concepts to locations.
Do not invent mount categories until actual callers require them.
ADR 0003 owns the guest-path-to-scoped-write lowering; ADR 0017 selects its base
directory for file sinks. Plugins supply paths/data, not native filesystem code.

## Where the definitions live

| Question | Owning decision and definitions |
| --- | --- |
| Where may native IO occur? | [0003](adr/0003-effects.md): FileSystem operations and IO runner; [0002](adr/0002-runtime.md): scoped process ownership |
| What is selected/captured? | [0004](adr/0004-knowledge-base.md): host Root and wrappers; [0010](adr/0010-evolutions.md): Before/After and captured context |
| What can the schema-agnostic host check? | [0005](adr/0005-contracts.md): contract algebra, CheckedValue and projections |
| Which reads require validation? | [0006](adr/0006-storage.md): RootStore operations, explicit checking read and pages |
| How is a request result typed? | [0008](adr/0008-authoring.md): guest methods/host descriptors; [0009](adr/0009-capabilities.md): Program and request algebras; [0007](adr/0007-wire.md): private envelopes |
| How are changes evaluated and checked? | [0010](adr/0010-evolutions.md): effectful entry, pure Evolution helper, EvolutionExecution; [0011](adr/0011-validation.md): RootExecution, reports and typed data examples |
| What precisely gets accepted? | [0012](adr/0012-acceptance.md): checked candidate, conditional Git update and outcomes |
| How do integrations and outputs differ? | [0014](adr/0014-evidence.md): evidence snapshots; [0015](adr/0015-plugins.md): source/sink connectors and config inputs; [0016](adr/0016-connections.md): Secrets/SecretStore and plugin-owned authentication; [0017](adr/0017-outputs.md): multi-query renderers, typed sink bindings and prepared invocation |
| What do clients share? | [0018](adr/0018-surfaces.md): adapter boundary; [0023](adr/0023-interaction.md): review notes and saved examples |
| How are operational failures reported? | [0019](adr/0019-failures.md): Failure versus domain result types |

For example, once capture and source-root loading have selected their inputs,
preview composes evaluation and checking without acquiring publication:

```haskell
preview captured source = do
  sourceCheck <- send (ValidateRoot source)
  evaluated <- applyEvolution captured
  checked <- case evaluated of
    Left rejection  -> pure (Left rejection)
    Right candidate -> Right <$> checkCandidate candidate
  pure (sourceCheck, checked)
```

Here `source` is the structurally readable `Root` loaded at Before's revision for
the separate validation display; EvolutionExecution loads its own selected input.
It is not a `Validated Root`. The source checking result retains either a pre-execution
diagnostic rejection or the executed report, including semantic errors; it does
not block a repair. `ValidateRoot` runs the checks on this preview;
there is no saved-report fast path. The result separately distinguishes proposed-
code/transformation rejection, candidate validation failure and a checked candidate;
operational failures remain in Failure. This expression
requires RootStore, EvolutionStore, EvolutionExecution and RootExecution, but not
RootPublication. Only entry evaluation dispatches declared acquisition; checking
does not invoke the entry a second time.
`applyEvolution` saves its materialized result through EvolutionStore. The caller
can inspect it and invoke `AcceptEvolution` separately
when desired. No interpreter secretly closes that gap by accepting as part of
checking. See the owning ADRs for the signatures rather than inferring them from
a duplicate list here.

## Operation composition checks

| Operation | Semantic handlers needed | Must not acquire |
| --- | --- | --- |
| List workspaces / review notes | EvolutionStore; RootStore.OpenKnowledgeBase if unopened | Compiler, plugin, accepted-root writer |
| Load/check a root | RootStore, RootExecution | Live evidence/provider/delivery |
| Evaluate evolution entry | RootStore, EvolutionStore, EvolutionExecution; declared plugin/evidence handlers | Accepted-root writer, delivery |
| Check materialized candidate | RootStore, RootExecution; EvolutionStore to load a saved result | Live evidence/provider/delivery, evolution re-execution |
| Inspect a saved candidate diff | RootStore, EvolutionStore | Provider, delivery; runtime unless recomputing a view |
| Inspect record history | EvolutionStore over Git and archived step reports | Historical guest compilation/execution, evidence acquisition, provenance service |
| Acquire evidence | PluginInvocation acquisition, EvidenceStore; plugin HTTP/Secrets plumbing as declared | RootPublication, Delivery |
| Browse records / execute query | RootStore and, for named calculations, RootExecution | Sink invocation, output preparation |
| Prepare output | RootExecution over RootStore's selected snapshot; optional artifact data handling | Source acquisition, Delivery, RootPublication |
| Accept checked result | RootPublication, lowering through RootStore and EvolutionStore | Guest execution, acquisition, delivery |
| Accept in a fresh process | EvolutionStore to load, RootStore/RootExecution to check, then RootPublication | Evolution re-execution, acquisition, delivery |
| Update output | RootExecution for computation (or reuse its result), Delivery, PluginInvocation and the sink's declared plumbing | RootPublication, mandatory retained preview |

Web and MCP access the same application operations. The rows describe these
operations' effects, not whether the initiating client is a human or agent, and
not a closed taxonomy of every future authored workflow. Output preparation and
sink invocation are composed by application operations under ADR 0017. Human/agent
emphasis does not partition the shared operations table.

Host structural browsing uses RootStore and the checked contract algebra; named
domain calculations use selected-snapshot guest execution. Transport adapters
neither recompute business rules nor require a guest call for each structural
table interaction. Per-KB process composition and lifecycle are in ADR 0025.

## What the KB author should see

Follow [authoring](adr/0008-authoring.md) for typed method registration and a
reporting calculation; [capabilities](adr/0009-capabilities.md) for explicit
snapshot/plugin requests; [evolution](adr/0010-evolutions.md) for effectful entries,
pure typed composition and named-entry arguments; and
[validation](adr/0011-validation.md) for the pure validator.

The authored program has no JSON/Dhall transport parsing, method-string dispatch
or native IO entry point. Registered KB tools compose captured-evidence plugin reads
under ADR 0008; queries retain their snapshot-only boundary. An evolution entry can
request evidence and return a proposed
root; checking consumes its materialized candidate and cannot fetch a different
report or rerun acquisition. Validation remains a pure KB entry point.
A guest method descriptor is not itself a serialized function.

## Review questions this map deliberately leaves visible

- Are the semantic effects cohesive, especially RootExecution versus invocation,
  and EvolutionStore's workspace/check-artifact responsibility?
- Does the distinction between public capability helpers and format-specific
  lowering support give us the nesting the owner actually wants?
- Does the checked-evolution/publication interface express the single local-head
  guarantee without adding a sealed-candidate or approval protocol?
- Can the guest capability encoding compile in MicroHs without type-family
  machinery or exposing a generic unchecked dispatcher?

These questions require interface review, not speculative implementations of
alternative modules. The architecture succeeds when permitted calls are evident
from types and dependencies, not merely from comments promising to be careful.
