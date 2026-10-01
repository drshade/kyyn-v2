---
id: 0028
title: 'Typed agentic tools and explicitly executable recipes'
status: proposed
date: 2026-10-01
---

# Typed agentic tools and explicitly executable recipes

## Context

[Issue #158](https://github.com/drshade/kyyn-v2/issues/158) asks how a KB can
retain a repeatable model-assisted working method, rather than requiring every
calling agent to reconstruct it from instructions. The selected library is
[haskell-agentic](https://github.com/drshade/haskell-agentic), owned by Tom.
Necessary library changes should be requested upstream, not implemented as a
private Kyyn orchestration fork.

**Owner-established direction:** KB tools may execute typed agentic flows,
including model-assisted drafting and subagents. Recipes support both external
instruction-led work and explicit flow execution. Kyyn is not an autonomous
agent; evolutions remain pure and nothing is automatically accepted. The host
performs individual model turns with per-KB credentials hidden from guest code.
Existing Jev Judgement semantics remain unchanged. Runs need bounded model use,
inspectable flow descriptions and deterministic test fixtures.

The signatures and integration choices below are proposals, not implemented APIs.
In particular, partial acknowledgement, flow registration, frozen proposal
representation and model configuration require review. This ADR does not
authorize production integration.

## Decision

### A flow belongs to the KB, not to an autonomous kernel

Use the library's inspectable arrow structure with Kyyn's existing typed guest
program as its effect parameter:

```haskell
type Flow calls input output = Agentic (Program calls) input output

interpret
  :: Monad m => Runtime m -> Agentic m input output -> input -> m output
```

`Agentic` and `interpret` are library concepts, not new Kyyn effect interpreters.
The runtime supplied by the generated adapter implements requests through
[ADR 0009](0009-capabilities.md). `arr` composes pure transformations; `act`
uses the selected guest capabilities, not ambient IO. `draft` asks a model to
produce a typed result and may expose explicitly supplied tools whose bodies
are themselves flows. A nested drafting tool is a subagent with its own
conversation, not a separately scheduled Kyyn agent.

The library owns the loop: request a turn, dispatch requested tools, return their
results and decode the response. Kyyn supplies capability handlers and ordinary
execution/cancellation. It does not duplicate this loop, choose a goal, schedule
recipes or keep agents alive after the requested invocation.

Existing ordinary KB tools remain ordinary functions. Registering a flow-backed
tool exposes the same checked input/output contract to CLI/MCP callers. It adds
no proposal-writing ability to the tool context. Agentic tools can investigate
captured evidence, call Judgement and draft results; they cannot accept roots,
acquire evidence or invoke sinks. Query, validation, rendering and evolution
capabilities do not gain model access.

### The host provides a turn, not a provider SDK to the guest

Illustrative request/result boundary:

```haskell
data ModelTurn result where
  TakeModelTurn :: ModelProfileRef -> TurnRequest
               -> ModelTurn (Either ModelFailure TurnResponse)

data TurnRequest = TurnRequest
  { conversation :: Conversation
  , outputContract :: CheckedContract
  , availableTools :: [CheckedToolContract]
  }
```

`Conversation` here denotes the library's instruction, state and exchange
history. The transport adapter projects those into provider messages and maps
one response back to the library's `Turn` (tool calls or a final value).
The host does not execute returned tool calls: the guest loop does so through
the supplied typed tool bodies. Internal library values are not an additional
KB-authored wire schema.

A host-resolved profile selects provider/model and a secret-store key. Its
credential value never crosses this boundary or appears in guest diagnostics.
This is specific to the model-turn capability; it does not change plugin-owned
authentication under [ADR 0016](0016-connections.md). Native provider packages
may inform the host adapter, but their IO dependencies do not enter the guest.

One invocation has one shared limit across nested drafting tools, retries and
parallel branches. Reserve a turn before dispatch; exhaustion returns a useful
failure and cannot yield a successful recipe proposal. A fresh nested
conversation does not reset the allowance. Failed dispatched calls count too.
Judgement requests within the invocation also consume its model-request allowance;
this does not change their result semantics. The library's current `capped`
helper limits each conversation, so it is not sufficient for this contract.

Use a hard request-count limit initially; the desired cost limit needs a concrete
provider usage/pricing and maximum-output policy before claiming an exact spend
ceiling. Do not label a turn count a monetary guarantee. Limits do not prove
termination of arbitrary pure `arr` or `repeat` code; ordinary cancellation remains
available. Profile storage, defaults, per-run overrides and monetary-limit
semantics are unresolved, not permission to add a general provider registry.

### Keep one schema authority and preserve Judgement semantics

Authored Haskell types and [ADR 0005](0005-contracts.md) remain authoritative.
Generate the library's `Codec`/schema projection from the same checked types and
wire conventions as other guest boundaries. Authors must not maintain both a
Kyyn schema and an independently written `Contract` for the same public value.
The library's model-facing schema may need a different projection from the
runtime protocol; make that conversion explicit rather than silently changing
the guest wire encoding. Unsupported projections fail before making model calls.

Upstream supports explicit codecs under both GHC and MicroHs; Generic deriving
of `Contract` and `Options` is GHC-only. It uses its own JSON-shaped `Value`.
Kyyn must generate the explicit codecs without requiring GHC metadata in the
guest. The library's explicit-codec support is proven below; Kyyn's automatic
mapping remains an integration gate. Internal library tuples or floating-point
values do not expand Kyyn's public schema vocabulary by accident.

[ADR 0027](0027-judgement.md) owns Jev semantics. Its explicit criteria,
fixed-point values, whole-batch errors and ordinal scale answers are not replaced
by similarly named library types. In the inspected library, `yesNo` lacks Kyyn's
two answer descriptions and `Score` carries a `Double` position. Ask upstream
for a compatible bridge or API changes before exposing a unified `judge` facade.
`score` versus `scale`, and helpers such as `keep`/`gate`/`clearly`, remain naming
and ergonomics decisions; filtering thresholds are authored policy, not proof
that the model is correct. Do not silently substitute an LLM for Jev.

### Open and closed recipes share ordinary curation

Recipe identity, instructions and curation progress remain owned by
[ADR 0014](0014-evidence.md). Open recipes continue to guide an external agent
investigating evidence and authoring an evolution. Closed recipes let a caller
explicitly execute a typed flow to prepare that work. Both still carry
instructions, and both use the same recipe ID and curation register. A closed
recipe is not a scheduled job or a promise that every input will be resolved.

**Recommended, pending owner review:** keep the recipe as data and register the
optional flow in `kb.dhall` alongside existing tool entry registrations:

```haskell
data RecipeFlowRegistration = RecipeFlowRegistration
  { recipe :: RecipeId
  , entry :: FlowEntryRef
  }
```

The reference identifies checked KB code, not a serialized Haskell closure. The
host resolves a registration against the selected root's recipe IDs and code
exports; dangling or duplicate registrations are errors. Discovery joins these
to show whether the recipe offers explicit execution. Both data and registration
changes still belong to ordinary evolutions.

The alternative is `recipeMode :: Open | Closed FlowEntryRef` inside the recipe
payload. That keeps the association together and avoids a join, but puts code
export references inside fact data, unlike current tool registration. Neither
location has been settled by the owner; do not persist both or create another
recipe identity. Open/Closed describe these modes, not two curation systems.

At invocation, the host selects a Before root and captures the pending evidence
inputs for the selected connector instances. The flow gets typed pending data
and captured-read bindings, not live provider access. The same capture is used
for subsequent reads during this invocation. This does not archive old evidence
payloads: after a run, [latest-only storage](0014-evidence.md) still applies.

```haskell
closedRecipe
  :: Flow RecipeCalls (RecipeInput root) (ProposedCuration root)

data ProposedCuration root = ProposedCuration
  { proposal :: FrozenProposal root
  , handled :: [HandledInput]
  }

data HandledInput
  = EntireInput InputRef
  | SelectedItems InputRef [EvidenceId]
```

`RecipeInput` contains the selected root and pending changes grouped by captured
instance; `InputRef` addresses one supplied group, not a new persisted selection
registry. Recipes are not restricted to one connector. A CLI spelling such as
`root recipe run NAME PLUGIN INSTANCE` selects input to one invocation; it does
not define what other invocations of that recipe may use. Multi-instance CLI
syntax and the concrete typed input representation remain to be designed.

**Recommended, pending owner review:** the flow explicitly selects whole supplied
inputs or individual pending items, including deletions. The host fills the exact
fetch scopes and converts these selections to ADR 0014 acknowledgements. Reject
unknown input references and items outside the supplied pending input. Reading,
citing or changing a fact does not acknowledge evidence. Empty selection is valid;
low-confidence work can stay pending for an external agent. This adds no second
watermark or inference that model confidence means successful curation.

### Freeze the result, then use the existing evolution path

All model calls happen during tool/recipe execution. A successful closed recipe
returns typed proposal **data**; it does not return a remotely executable closure
or publish a root. The host writes an ordinary evolution workspace against the
captured Before, with frozen inputs, declared acknowledgements and producer
information. The workspace's pure `evolution` applies those inputs through checked
KB code. The current check, diff, readiness and acceptance operations then apply
unchanged. Running a recipe does not mark its workspace Ready or accept it.

```haskell
-- Host application operation, not a guest capability.
prepareRecipeEvolution
  :: RecipeInvocation -> Eff es (Either RecipeFailure EvolutionWorkspace)
```

This signature elides the existing execution/authoring/store effects; it does
not permit ambient IO in porcelain. The implementation must give the operation
an explicit effect row when those dependencies are known.

`FrozenProposal root` above is intentionally an unresolved boundary. It needs to
represent fact and recipe changes with step rationale/citations, without requiring
the model to author Haskell or inventing a second general mutation language.
Two candidates deserve comparison in the first proof:

- Generated, root-specific typed edits, grouped into annotated steps, applied
  through the existing SDK edit operations by a generated conventional entry.
  This minimizes per-recipe boilerplate. The existing report's fact/recipe change
  vocabulary informs it, but a report is a derived observation, not an executable
  patch API. Typed edit generation and application are new work to prove.
- A KB-authored typed plan and pure
  `plan -> Evolution (KnowledgeBase root) (KnowledgeBase root)` applicator.
  This reuses ordinary Haskell for domain-specific application semantics, but
  each recipe author must provide that function.

Prefer generated edits if that proof establishes a small implementation using
existing SDK semantics; otherwise bring the tradeoff back for a decision. Do not
implement both speculatively. Persist frozen inputs through the ordinary Dhall
path. In either approach, apply them to the actual captured Before and derive
the review diff through the normal observation checks. Never substitute a model's
claimed before/after report for the computed changes. Prove missing/duplicate-ID,
ordering and step-rationale behavior before settling the public SDK shape. The
first proof is same-schema; automatic schema-changing proposals are not established
by this sketch or by wrapping a wire value in an existential type.

Checks and acceptance never rerun the flow. Editing the frozen plan or applicator
requires fresh checking, just like other source/input edits. A failed or cancelled
run produces no successful proposal and advances no curation progress. If head
changes during the run, its output remains based on the captured Before;
the ordinary stale-base rule applies. Do not relabel it as based on a newer head.

### Describe the method and test execution honestly

`root tool show` and `root recipe show` should expose flow structure without
invoking models. Use the library's description projection, with named opaque
steps. It describes declared composition and available tools, not the behavior
of arbitrary `arr`/`act` functions, the exact future trace, or a proof of safety.
The ordinary evolution report identifies the producing recipe/flow and captured
source revision alongside its changes and rationale. It need not retain model
reasoning transcripts or a separate agent-run ledger.

Use record/replay fixtures for individual turns and Judgement calls, plus fixed
captured-evidence handlers, to test the complete flow deterministically. Upstream
`agentic-io` replay only replaces model calls; tool bodies and `act` still execute.
Replay-only tests must refuse missing recordings and must not contact providers.
Production response caching or mandatory transcript retention is not selected.

## Compatibility evidence and required proof

Verified library commit
[`9c74f01`](https://github.com/drshade/haskell-agentic/tree/9c74f019424d88c20ac457b2e655585c5df7c30f),
package `agentic` 0.2.0.2, against Kyyn's pinned MicroHs
[`8bf3d4d`](https://github.com/augustss/MicroHs/tree/8bf3d4d4242c8707b31c2338716977d24a95ad39)
on 2026-10-01. Using the installed native compiler, libraries and bundled cpphs,
with cleared package/module paths and explicit core/library include directories:

- `mhs ... -fno-code Agentic` passed.
- Compiled upstream's `agentic/test/Portable.hs` to a combinator artifact and
  executed it using `mhseval +RTS -r<artifact> -RTS`: all 14 checks passed.
- The proof covers explicit record and payload-bearing sum codecs, typed tool
  calls/results, a nested drafting tool, malformed output followed by correction,
  an applicative Judgement batch, and flow descriptions. Interpretation uses a
  pure non-IO monad with scripted handlers.
- Upstream runs the same portable test under GHC and has a MicroHs workflow
  pinned to the same compiler revision. This local verification ran MicroHs;
  it did not independently rerun the GHC suite or call live providers.

The earlier text-operation and Generic-metadata blockers are resolved upstream:
portable helpers replace unsupported operations and Generic deriving is excluded
under MicroHs. Explicit codecs remain available. No Kyyn fork or source patch
was required. This establishes core portability, not Kyyn's generated-codec,
wire, provider or recipe integration; no dependency was vendored by this proof.

Judgement alignment remains an upstream integration discussion. The one-turn
provider abstraction and generic monadic interpreter already exist; do not
request or reimplement them as missing features. Kyyn can own shared run
accounting at its host capability boundary; usage metadata needed for monetary
limits must be checked against provider support.

Before production integration, demonstrate a generated-contract flow under GHC
and pinned MicroHs with a recording host: typed draft, nested tool, malformed
response retry, Judgement and exhausted shared budget. Then demonstrate one closed
recipe producing a reviewable frozen ordinary evolution, partial/deletion
acknowledgements, failed-run preservation and repeated checking without model
calls. That proof must settle the proposal boundary and public authoring shape;
documentation approval alone is not evidence they work.

## Consequences and alternatives

Executable recipes retain more of the KB's working knowledge and reduce repeated
agent orchestration. Typed outputs improve composition, not factual reliability;
validation and review still matter. Provider failures, nondeterminism and costs
are new operational concerns at this explicit invocation boundary.

Keeping only external agents and prompt recipes is simpler but cannot expose a
reusable typed model-assisted tool as KB code. Writing a Kyyn-specific agent loop
duplicates the selected library. Allowing models inside evolution checks would
make ordinary review repeat nondeterministic external work. These are rejected
in favor of an explicit flow followed by a frozen pure proposal.
