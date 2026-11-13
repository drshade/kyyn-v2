---
id: 0028
title: 'Typed agentic tools and explicitly executable recipes'
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
SystemOne and SystemTwo use Agentic's types directly. Closed agents propose only
fact edits and their own next recipe state, not schema or code changes.
Flows remain inspectable and testable with deterministic fixtures.

## Decision

### A flow belongs to the KB, not to an autonomous kernel

Use the library's inspectable arrow structure with Kyyn's existing typed guest
program as its effect parameter:

```haskell
-- Generated Kyyn.Agentic; Tool is the selected Program row from Kyyn.Connectors.
type Flow input output = Agentic (ExceptT FetchError Tool) input output

interpret :: Flow input output -> input -> Tool (Either FetchError output)
liftTool :: Tool a -> ExceptT FetchError Tool a
```

`Agentic` is the library's arrow. The generated `interpret` wrapper supplies its
runtime and returns typed tool failures; it does not implement another agent loop.
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

The host plumbing boundary uses Agentic.Runtime's types directly:

```haskell
data ModelTurn :: Effect where
  TakeModelTurn :: ModelConfiguration -> Conversation
               -> ModelTurn m (Either ModelFailure Turn)
```

`Conversation` carries the library's instructions, exchange history and tool/result
contracts. There is no Kyyn-owned conversation or turn shim. The transport adapter projects those into provider messages and maps
one response back to the library's `Turn` (tool calls or a final value).
The host does not execute returned tool calls: the guest loop does so through
the supplied typed tool bodies. Internal library values are not an additional
KB-authored wire schema.

The required `model` field in `root/kb.dhall` has type
`Optional { provider : < OpenAI | Anthropic >, model : Text, credential : Text }`.
A configured model selects one provider/model and a secret-store key:

```dhall
Some { provider = < OpenAI | Anthropic >.Anthropic
, model = "your-model-name"
, credential = "MODEL_KEY"
}
```

This is accepted-root configuration, changed through an evolution. Root checking
rejects malformed configuration and missing fields. A KB without a model writes
`model = None { provider : < OpenAI | Anthropic >, model : Text, credential : Text }`;
requesting a model in that state refuses with a diagnostic. Every manifest field
is required, including `outputs` (a typed empty list when unused). Model settings belong with the other authored KB declarations; actual
credentials remain in the secret store.
Tool preparation captures the selection with its source tree; each turn uses
that captured selection, not a fresh read of the working checkout. `root tool show`
displays the provider/model and secret name. No separate profile registry is needed. Its
credential value never crosses this boundary or appears in guest diagnostics.
Support both OpenAI and Anthropic through the upstream native provider packages.
The host supplies the resolved key explicitly; missing or empty local secrets fail
before provider construction, without falling back to environment variables or
dotenv. Provider/HTTP failures become typed, sanitized failures rather than raw
exception text that may contain request headers or response bodies. Cancellation
continues to propagate normally.
This is specific to the model-turn capability; it does not change plugin-owned
authentication under [ADR 0016](0016-connections.md). Native provider packages
may inform the host adapter, but their IO dependencies do not enter the guest.

There are no request-count limits, spend budgets or shared usage accounting.
Ordinary cancellation and provider errors retain their existing
behavior; this is not a guarantee of bounded model use.

### Keep one schema authority and preserve Judgement semantics

Authored Haskell types and [ADR 0005](0005-contracts.md) remain authoritative.
Generate the library's `Codec`/schema projection from the same checked types and
wire conventions as other guest boundaries. Authors must not maintain both a
Kyyn schema and an independently written `Contract` for the same public value.
The library's model-facing schema may need a different projection from the
runtime protocol; make that conversion explicit rather than silently changing
the guest wire encoding. Unsupported projections fail before making model calls.
The known `Probability` scalar follows [ADR 0005's model and storage
projections](0005-contracts.md): reuse its upstream model contract rather than
generating a competing instance.

Derive contracts in the authored defining module with ordinary GHC `Generic`
and `Contract` instances. Flows may share that module; no generated contract
imports or separate module rule is needed. Nonempty enums can derive `Options`,
or supply ordinary instances for custom labels, descriptions and order.

Upstream haskell-agentic's `Contract` is the single structural authority. Extend
it upstream with an extensible scalar vocabulary so Kyyn can supply FactId,
exact decimals and blob references without maintaining a competing contract class.
Kyyn's describe, storage and model-codec interpreters all consume this same
representation. Authors write exactly one `deriving (Generic, Contract)` per type;
there is no additional Kyyn instance or model-facing DerivingVia clause.

This haskell-agentic extension is a required upstream dependency of the GHC guest
implementation. Pin the upstream revision providing it through the repository's
flake input. The scalar extension must preserve typed encoding/decoding and allow
distinct storage and model projections under ADR 0005, rather than flattening
custom scalars into unlabelled primitive shapes. Verify descriptions, storage
round trips and model projections for each supported shape and scalar. Unsupported
projections fail before execution or model calls.

Applied generic types and containers use compositional instances when their
shapes are supported. Type aliases are not new instance identities; wrappers are
needed only for deliberately distinct semantics or instance selection, not as a
blanket restriction on compound types. Internal library tuples or floating-point
values do not expand Kyyn's public schema vocabulary by accident. Authors own the
instructions, tool choices and flow composition.

[ADR 0027](0027-judgement.md) owns the Jev-backed SystemOne integration.
Agentic owns the question and answer types; Kyyn supplies credentials, wire
encoding and host interpretation, not a competing public judgement API.
Filtering thresholds remain authored policy, not proof that the model is correct.
Do not silently substitute an LLM for Jev.

### Open and closed recipes share typed recipe state

[ADR 0014](0014-evidence.md) owns recipe definitions and always-present state.
Open recipes guide an external agent; closed recipes name a regular callable
flow. Both prepare a recipe-based evolution under [ADR 0010](0010-evolutions.md).
A closed run selects exactly one recipe.

The host selects Before and supplies its root, the selected recipe's state and
the caller's typed request. The flow signature defines the request and state
types; the closed recipe's state contract is derived from that signature.
No state initialization occurs here: recipe creation already supplied it.

```haskell
data RecipeInput root input state = RecipeInput
  { root :: root, input :: input, state :: state }

data RecipeProposal edits state = RecipeProposal
  { steps :: [ProposedStep edits], state :: state }

closedRecipe
  :: Flow (RecipeInput Root Request ReviewState)
          (RecipeProposal RootEdit ReviewState)
```

`root recipe run NAME --input DHALL` checks the caller's request against the
inspected input contract. Unit requests may omit input. Generated codecs hide
transport from the author. The selected flow name is stored in the recipe;
there is no second flow registration list.

Flows read current evidence through generated instance bindings and plugin
methods. Each instance is captured lazily on first access and reused for that
invocation. Reads do not update recipe state. Source selection and processing policy belong to authored
code; empty evidence does not prohibit a run. The returned state may preserve
the input state or record whatever the recipe chooses, without host interpretation.

### Describe fact edits as data

A closed agent returns ordered operations, not executable mutation functions or
a replacement root. Use a small typed description of existing collection edits:

```haskell
data FactEdit a
  = Append (Fact a)
  | Replace { factId :: FactId, replacement :: a }
  | Remove FactId

data ProposedStep edits = ProposedStep Rationale [edits]

-- Generated for an example root's domain fact collections.
data RootEdit
  = Edit_todos (FactEdit Todo)
  | Edit_meetings (FactEdit Meeting)
```

`Rationale` already carries evidence citations. Generated root-specific sums
preserve each collection's payload type without an untyped patch language.
`Replace` supplies the complete new payload and retains the selected ID; it is
not a serialized update function. Interpret operations in their listed order
through the existing `append`, `update` and `remove` SDK combinators, with one
annotated evolution step per proposed step. Reuse their missing/ambiguous-ID and
duplicate-append failures; a failed application produces no partial edited root.

The current executable `CollectionEdit` is not a wire value. These data
constructors describe its operations, and generated bindings supply the pure
interpreter. No per-recipe applicator is required. The generated edit type
contains domain fact collections only, not recipe definitions, schema, code,
plugin configuration or other root artifacts. The separately typed next state
updates only the selected recipe. A root with no domain collections still permits
a state-only proposal with an empty step list; do not require a dummy fact collection. The accepted schema and associated
metadata stay fixed; equal endpoint Haskell types alone would not establish that.

### Freeze the result, then use the existing evolution path

All model calls happen during tool/recipe execution. A successful closed recipe
returns typed proposal **data**; it does not return a remotely executable closure
or publish a root. The host writes an ordinary evolution workspace against the
captured Before, with the returned fact-edit steps and typed next recipe state. The workspace's pure `evolution` applies those inputs through checked
KB code. The current check, diff, readiness and acceptance operations then apply
unchanged. Running a recipe does not mark its workspace Ready or accept it.

```haskell
-- Host application operation, not a guest capability.
proposeFromRecipe
  :: (RootOpening :> es, PluginPreparation :> es, PluginRead :> es,
      RecipeExecution :> es, EvolutionAuthoring :> es)
  => KnowledgeBase -> GitRevision -> RecipeId -> DhallText
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
```

RootOpening selects the explicit Before revision; PluginPreparation and PluginRead
supply checked connectors and invocation-local evidence captures. RecipeExecution
executes the authored flow, and EvolutionAuthoring writes its frozen proposal as
a draft. No publication capability appears in this row.

Persist returned steps and next state through the ordinary Dhall path. The
generated recipe-based evolution applies the operations to Before and returns
the proposed state. Schema, code, configuration and recipe definitions remain
unchanged. Derive the review diff through normal observation checks, never from
a model's claimed before/after report. Re-evaluation uses the frozen data without
model calls or serialized closures. State-only proposals are equally reviewable.

The generated entry exposes the captured proposal as a typed value:

```haskell
evolution :: RecipeEvolution Root ReviewState
evolution = frozen
```

Kyyn supplies `frozen` from the workspace's persisted proposal, validating the
Dhall input before guest compilation. Decoding belongs to generated plumbing,
not authored evolution code; a decode failure is a diagnostic, not a fabricated
transformation step or rationale.

Checks and acceptance never rerun the flow. Editing the frozen operations or source
requires fresh checking, just like other source/input edits. A failed or cancelled
run produces no successful proposal and changes no accepted recipe state. If head
changes during the run, its output remains based on the captured Before;
the ordinary stale-base rule applies. Do not relabel it as based on a newer head.

### Describe the method and test execution honestly

`root recipe show` reads the stored definition without compiling the flow.
`root recipe describe NAME` inspects a closed recipe from the selected accepted
revision, using the library's `describe` and `renderTree` projection. Mutually
exclusive `--dot` and `--mermaid` flags select its other renderers. Human output
is just the rendered text on stdout, suitable for redirection; `--json` wraps
the text with recipe, flow, revision and format. Open recipes receive a diagnostic
pointing to `root recipe show`.

Description requires the checked source contract and the referenced flow, not
fact validation or evidence acquisition. Its interpreter compiles and evaluates
the description projection with no model, secret or evidence-read handlers. It
does not interpret the flow's actions. Conceptually:

```haskell
describeRecipe :: RecipeInspection :> es
               => SourceRoot -> FlowEntryRef -> DescriptionFormat
               -> Eff es (Either [Diagnostic] Text)
```

Use the library's named opaque steps. The projection describes declared
composition and available tools, not the behavior
of arbitrary `arr`/`act` functions, the exact future trace, or a proof of safety.
The ordinary evolution report identifies the producing recipe/flow and captured
source revision alongside its changes and rationale. Local run recordings below
retain execution progress separately.

Use record/replay fixtures for individual turns and Judgement calls, plus fixed
captured-evidence handlers, to test the complete flow deterministically. Upstream
`agentic-io` replay only replaces model calls; tool bodies and `act` still execute.
Replay-only tests must refuse missing recordings and must not contact providers.
Production response caching or mandatory transcript retention is not selected.

### Record recipe execution for live viewing and playback

A closed recipe invocation produces a local run recording. CLI and MCP own
execution; Web observes it. Live viewing follows the recorded prefix as it grows,
and playback applies the same records at a chosen pace. Neither reading path
executes guest code, calls providers or applies a proposal.

A run records how the flow executed. The ordinary evolution records proposed and
accepted changes with their rationale. The run's successful terminal event links
to the draft evolution; the evolution has no reference to the disposable local
run. Checking or accepting that draft does not append a new recipe execution.

#### Graph and execution identity

The upstream Agentic library owns one structural addressing scheme shared by
its description and interpretation traversals. The guest captures `flowGraph`
from the same immutable build it invokes. Store the complete graph data: items,
edges, `addressItems` and `bodies`. Encode addresses with `addressText` and
selection identities with `edgeIdText`, never `Show`. The flattened
`descriptionValue` is not a substitute: it omits intermediate composition scopes
needed to map observations. Mermaid is a rendering, not a source of identities.
The graph retains authored labels, descriptions and static prompt text. Addresses
are opaque and local to this captured graph, with no identity across builds.

`addressItems` maps hidden and visible scopes to displayed items. A choice maps
to a decision diamond with two outgoing edges, each with one selection identity.
Junctions are graph-only routing items: no event targets them. The logical run
root exists in the data without a drawn run box. Body relations identify an
owner, optional tool binding site and body root. A call scope lists its possible
targets; `CallResolved` identifies the actual binding and body. Recursive groups
have finite definitions and reference edges with explicit target addresses,
distinct from Repeat's `Again` edges. Static edges indicate possibilities, not
executed calls.

An occurrence is the upstream `Occurrence`: a static address and complete
`ContextFrame` stack, innermost first. Each frames carry index and total; Repeat
frames carry the pass; Call frames carry draft address, turn, call position and
provider call ID. Call position distinguishes repeated provider IDs. Serialize
with `occurrenceValue`. Every observation has an explicit authoritative parent
occurrence; neither address prefixes nor arrival order establish parentage.
The recorder namespaces these identities by run. Reused steps and concurrently
active invocations remain distinct; returning one never finishes another. The
diagram aggregates occurrences while its inspector lists individual histories.
Selections identify logical edges, never inferred from missing child events.

Kyyn consumes the upstream interpreter rather than implementing another one.
Arbitrary pure functions remain opaque. A return means the interpreter's action
returned, not that lazy values were forced or the result was accepted. Durations
measure observed scope progress, not CPU time. `describe` returns
`Either FlowError Description`; description and graph-capture failures are
ordinary diagnostics. Failure before a graph is captured does not create a run
recording, even though upstream can observe a preflight failure on its logical root.

#### Observation and recording contracts

Upstream owns both execution semantics and the payload-free summary vocabulary.
The guest uses `summaryValue . summarise` before transport. Kyyn stores that
lossless encoding rather than defining a competing event sum. The host adds
ordering and timing:

```haskell
-- Opaque wrapper around the upstream summaryValue JSON encoding.
-- Construction in the guest discards Event.payload without evaluating it.
newtype FlowSummary = FlowSummary Value

-- SDK-generated request; not an authored wire/value API.
data ObserveFlow result where
  ObserveFlow :: FlowSummary -> ObserveFlow ()

-- Before/build identify provenance; reading a run does not resolve them.
-- FlowGraph denotes the complete captured graph encoding described above.
data RecipeRunHeader = RecipeRunHeader
  { runId :: RecipeRunId, recipe :: RecipeId, flow :: FlowEntryRef
  , before :: GitRevision, build :: BuildIdentity
  , startedAt :: Instant, graph :: FlowGraph
  }

data RunEvent = RunEvent
  { elapsed :: Duration, body :: RunEventBody }

-- Sequence is the complete record's zero-based position in events.jsonl.
data SequencedRunEvent = SequencedRunEvent Natural RunEvent

data RunEventBody
  = FlowObserved FlowSummary
  | RunCompleted EvolutionId
  | RunFailed [Diagnostic]
  | RunCancelled
```

The summary preserves occurrence, parent, node kind, labels and the upstream
phase: `Entered`, `Returned`, `Failed`, `Cancelled`, `Selected`, `CallResolved`,
`Drafting`, `Turned`, `OutputRejected` or `Judged`. Each entry includes its exact
total, including zero. Progress counts returns of element body roots identified
by the published body relation, not arbitrary descendant returns. Repeat has no
predicted total. Turns carry their index and action kind, not tool names; Judged
has no answer count, and OutputRejected has no rejection text. Call return
outcomes distinguish completed, unknown-tool and invalid-input results. A resolved
call can reject input without entering its body.

The summary excludes inputs, outputs, conversations, model results and exception
payloads. Projection must neither retain payload closures nor evaluate discarded
values. Authored labels and provider call IDs remain metadata; this is not a
redaction mechanism. `RunFailed` diagnostics may quote values and are separate
from observations.

The observation request is available only within closed recipe execution,
including nested flow tool bodies in that invocation. Describe, query, validation,
rendering and evolution contexts do not receive it. It uses the ordinary
HostRequest/HostResponse transport under [ADR 0007](0007-wire.md); a unit response
acknowledges a successful append. Recording failure aborts the invocation through
the existing operational-failure channel, rather than acknowledging a lost event.

Sibling observer callbacks may overlap. The recorder serializes appends while
preserving upstream causality: parent entry before child events, child terminals
before the parent terminal. Host receipt assigns nondecreasing monotonic elapsed
time; complete-record positions provide sequence numbers and paging cursors.
The same RunEvent is stored and served, with that ordinal added in the browser's
SequencedRunEvent wrapper. Guest summaries are the only account of scope and
model progress; capability brokers do not duplicate them.

The host owns invocation lifecycle, including proposal persistence. Scope
`Cancelled` describes an interpreter scope; host `RunCancelled` describes the
owning invocation being cancelled. It is not synthesized from a child cancellation.
Likewise upstream root return does not establish `RunCompleted`: the host must
first persist the proposed evolution. These are different facts with different
owners.

Failure observation depends on the runtime scope hook: `runtimeWith` alone
observes entry and normal return, not a short-circuiting monad's failure. Missing
terminals are not reconstructed from the host outcome.

`Failed` means exceptional scope exit; ancestors can fail as an exception passes
through. Playback may identify deepest observed failures but must not infer a
causal origin. A thrown observer can interrupt delivery. An occurrence without a
terminal remains unknown when recording ends, even beneath a terminated ancestor;
never invent a return, failure or cancellation. During an active recording such
an occurrence has no observed terminal, which does not prove it is still executing.
Handled OutputRejected events are not terminal failures.

#### Local lifetime and failure

After preparing the captured graph/build and validating invocation inputs, create
`.kyyn/runs/<run-id>/header.json` and `events.jsonl`, and publish the header
atomically before dispatching flow actions. Preparation failures remain ordinary
command diagnostics. A run holds a process-scoped exclusive writer lock for its
lifetime; the header is immutable. Each event is appended as one complete JSON
record followed by a newline and flushed before acknowledgement. Flushing provides
visibility to other local processes, not a power-loss durability guarantee.
Stored values use ADR 0007's exact wire-value conventions.

```haskell
-- Host application boundary, implemented with local files and a scoped lock.
withRecipeRun
  :: (RecipeRunStore :> es, Failure :> es)
  => PreparedRecipeRun -> (RecipeRunWriter -> Eff es a) -> Eff es a

appendRunEvent
  :: (RecipeRunStore :> es, Failure :> es)
  => RecipeRunWriter -> RunEventBody -> Eff es RunEvent

listRecipeRuns
  :: (RecipeRunStore :> es, Failure :> es)
  => KnowledgeBase -> Maybe RecipeId -> Eff es [RecipeRunSummary]

readRecipeRun
  :: (RecipeRunStore :> es, Failure :> es)
  => KnowledgeBase -> RecipeRunId -> Maybe Natural -> Natural
  -> Eff es RecipeRunPage

clearRecipeRun
  :: (RecipeRunStore :> es, Failure :> es)
  => KnowledgeBase -> RecipeRunId -> Eff es ()
```

PreparedRecipeRun contains the captured header data; the host assigns its ID and
time. RecipeRunWriter is an operation-scoped handle. A read's optional sequence
is an exclusive cursor; absent means the beginning. The final Natural is the
page-size limit. RecipeRunPage contains the header, ordered complete events,
next cursor, whether more records are available, and derived activity/outcome.
The store owns timestamps, serialization, locking and filesystem operations;
porcelain composes it with recipe execution and proposal authoring.

The successful terminal event is appended only after the ordinary draft workspace
has been written. Failed execution records available diagnostics; caller
cancellation attempts RunCancelled during scoped cleanup. A killed process need
not append anything. A terminal record determines the outcome even while cleanup
holds the lock; without one, a held writer lock means active and a released lock
means interrupted/incomplete. Readers never infer success from EOF or synthesize
missing node returns. Browser disconnection has no effect on execution.

Readers expose the complete event prefix while an append is in progress. A partial
final line after writer death marks an incomplete recording; malformed complete
records are located decode errors. They are not silently skipped.
No terminal event may be followed by another event. A recording write failure
stops further dispatch and reports the run path. Prior external actions are not
rolled back. If draft creation succeeded before the terminal append failed, the
error also reports the existing draft ID; retry is not automatic.

Listing reads run directories. Records remain until explicitly cleared; clearing
requires acquiring the run's writer lock and refuses an active run. Run files are
local and ignored by Git; deleting them changes neither evidence, checkpoints,
facts nor evolutions. Source/build identifiers are provenance for display, not
compatibility gates or prerequisites for reading. The current types decode the
recording; an unreadable record produces an error naming its file. Playback uses
the stored graph even when the source revision or build is unavailable.

#### Viewing the same sequence live and later

[ADR 0023](0023-interaction.md) owns run pages and their read-only endpoints.
One browser state reducer consumes RunEvent records in sequence. Live viewing
first loads the saved prefix and polls after its cursor; playback loads that same
sequence and uses elapsed time for pacing. Pause, speed changes and scrubbing
only change the browser's position in the recording. Refresh reconstructs state
from the saved prefix. Duplicate deliveries are ignored by sequence; a missing
sequence requires reading the missing page, not guessing the intervening state.
The view shows unfinished occurrences honestly and links a completed run to its
draft. Multiple active runs remain individually selectable.

## Verification

Use the haskell-agentic sources pinned by the flake lock, including the required
upstream Contract extension. Library tests and Kyyn integration are separate
obligations: the former does not prove derived codecs, provider adapters or recipe
persistence.

Exercise explicit record/sum contracts, typed tools, nested drafts, malformed
output followed by correction, applicative judgements and flow descriptions under
host and built guest with scripted handlers. Test a generically derived contract flow through
Kyyn's real guest/host protocol, including cancellation and provider failures.

A closed recipe must produce a reviewable frozen ordinary evolution. Verify typed request/state decoding, mandatory initial state, state-only proposals,
failed-run preservation, repeated checking without model calls, edit ordering,
missing/duplicate IDs, rationale and unchanged definitions/schema/configuration.
Two recipes with the same state type must retain separate values; a proposed state
cannot be attributed to a different recipe during acceptance. Live-provider verification uses opt-in credentials and does not replace
deterministic error-path tests.

Verify graph/event correspondence for unnamed steps, repeated labels, both branches,
Each/Repeat and nested concurrent tools. Live attachment, refresh and playback of
the same event prefix must yield identical node/occurrence state. Exercise a failed
flow, cancellation, killed writer, partial final append, malformed complete record,
recording-write failure after draft creation, active-clear refusal, two concurrent
runs of different recipes recorded/listed independently, and missing
source/build provenance. A built-guest installed journey must run from the CLI
while a separate Web process observes, then replay without providers or compilation.

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
