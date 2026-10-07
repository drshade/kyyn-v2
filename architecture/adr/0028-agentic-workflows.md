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

The optional `root/model.dhall` selects one provider/model and a secret-store key:

```dhall
{ provider = < OpenAI | Anthropic >.Anthropic
, model = "your-model-name"
, credential = "MODEL_KEY"
}
```

This is accepted-root configuration, changed through an evolution. Root checking
rejects malformed configuration; absence is valid until a tool requests a model.
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

Keep authored type definitions in modules independent of flows and generated
contracts. A flow requests a generated instance through an ordinary import:

```haskell
import Todos (Todo)
import Kyyn.Contracts.Todos.Todo ()

extractTodo :: Flow Text Todo
extractTodo = draft "Extract the actionable task from this evidence."
```

`Kyyn.Contracts.<Module>.<Type>` names the type at its defining module. The host
parses authored imports with the compiler, inspects each requested type, and
generates its codec plus `Contract` instance before compiling the authored flow.
Imports in other authored helper modules count too; repeated imports select the
same instance. Generated public modules are available through guest API discovery.
For a nonempty enum (all constructors nullary), the same import also generates
`Options`: constructor labels, declaration order and no optional descriptions.
This supports `choice` and `score` without a handwritten instance. Payload-bearing
sums and records receive only `Contract`. Authors needing custom option labels,
descriptions or ordering own their instances instead of importing that generated
module; generated and handwritten instances for the same class/type cannot coexist.
There is no second registration list, handwritten structural contract, or generated
flow. Agents and humans own the instructions, tool choices and flow composition.

Initially generate instances for monomorphic `data`/`newtype` declarations at
their defining names. A type alias is not a new instance identity: import the
underlying nominal type's contract. Use a named wrapper for a standalone model
contract over a container or applied generic type. This avoids competing with
upstream's existing instances. Defining modules must not import their generated
contracts, directly or through a flow; that would make inspection circular.

Upstream supports explicit codecs under both GHC and MicroHs; Generic deriving
of `Contract` and `Options` is GHC-only. It uses its own JSON-shaped `Value`.
Kyyn generates explicit codecs and instances without requiring GHC metadata in the
guest. Internal library tuples or floating-point
values do not expand Kyyn's public schema vocabulary by accident.

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
source revision alongside its changes and rationale. It need not retain model
reasoning transcripts or a separate agent-run ledger.

Use record/replay fixtures for individual turns and Judgement calls, plus fixed
captured-evidence handlers, to test the complete flow deterministically. Upstream
`agentic-io` replay only replaces model calls; tool bodies and `act` still execute.
Replay-only tests must refuse missing recordings and must not contact providers.
Production response caching or mandatory transcript retention is not selected.

## Verification

Use the pinned unmodified library sources recorded in
[vendored inputs](../../vendor/README.md). Core portability and Kyyn integration
are separate obligations: the former does not prove generated codecs, provider
adapters or recipe persistence.

Exercise explicit record/sum contracts, typed tools, nested drafts, malformed
output followed by correction, applicative judgements and flow descriptions under
both GHC and MicroHs with scripted handlers. Test a generated-contract flow through
Kyyn's real guest/host protocol, including cancellation and provider failures.

A closed recipe must produce a reviewable frozen ordinary evolution. Verify typed request/state decoding, mandatory initial state, state-only proposals,
failed-run preservation, repeated checking without model calls, edit ordering,
missing/duplicate IDs, rationale and unchanged definitions/schema/configuration.
Two recipes with the same state type must retain separate values; a proposed state
cannot be attributed to a different recipe during acceptance. Live-provider verification uses opt-in credentials and does not replace
deterministic error-path tests.

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
