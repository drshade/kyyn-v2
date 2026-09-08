---
id: 0010
title: 'One evolution mechanism for facts, schema and meaning'
status: proposed
date: 2026-09-07
---
# One evolution mechanism for facts, schema and meaning

Basis: one composable evolution mechanism, retained archives and distinct schema
module names with friendly qualified aliases are owner-established. Capture,
persistence and workspace operation signatures are proposed mechanics.

## Context

Updating facts, migrating a schema and revising the tools that interpret them
must not be disconnected workflows. Evaluation must be useful without acceptance.

## Decision

An evolution is one of the three KB entry-point kinds in ADR 0008. Its entry
function may obtain evidence through declared host/plugin capabilities and returns
the proposed after value with its annotated step observations; Kyyn materializes
a candidate and derives its review report. It never calls `propose`
internally or implicitly accepts its result. This replaces a separate proposal-
authoring tool that first gathers inputs and then submits a pure evolution.

The reusable `Evolution before after` helper still describes a fallible pure
transformation plus human-readable intent. Same-schema changes use the same type. A workspace
contains before and after specifications, proposed code, captured inputs and an
explanation. Code/rule-only changes use an identity data transformation
but still check the proposed code and examples.
Non-secret plugin/source configuration changes follow the same route: capture
their files alongside proposed schema/code and publish them with the checked root.
Local secret-store contents are never implicit capture inputs.

On the **guest**, this is an input/output relationship, not a filesystem command:

```haskell
data Rationale = Rationale
  { explanation :: Text
  , evidence    :: [EvidenceRef]
  }

data Evolution before after  -- pure transformation with annotated boundaries

data RootBinding a  -- generated contract identity and encoding support

evolve
  :: RootBinding before -> RootBinding after
  -> Rationale -> (before -> Either EvolutionFailure after)
  -> Evolution before after

(>=>) :: Evolution a b -> Evolution b c -> Evolution a c

identityEvolution :: Evolution a a

-- Internal representation, not exported constructors or record-update selectors:
data EvolutionOutput a = EvolutionOutput
  { value        :: a
  , observations :: [StepObservation]
  }

data StepObservation  -- rationale paired with encoded before/after root values

evaluateEvolution
  :: Evolution a b -> a -> Either EvolutionFailure (EvolutionOutput b)

data EvolutionFailure = EvolutionFailure [Diagnostic]
```

`EvolutionOutput` and `StepObservation` are abstract in the public SDK API; authors
obtain a successful output through `evaluateEvolution`. The generated adapter uses
`Kyyn.Evolution.Internal`, which an author can also import from the vendored source.
Public exports guide construction; they do not enforce observation completeness.
The host's contract/value and chain checks below are the actual boundary checks.

`RootBinding` is also abstract. Generated `beforeRoot`, `afterRoot` and explicit
intermediate bindings pair a checked whole contract identity with its typed
encoder; authors supply those values, not codecs. A type-indexed class would
conflate distinct metadata contracts on the same Haskell type, so bindings name
contracts explicitly. For example, a metadata-only edge can use two bindings of
type `RootBinding Schema.Root` with different identities:

```haskell
changeMetadata = evolve beforeRoot afterRoot (Rationale "Revise display metadata" []) Right
```

The guest `kyyn-sdk` package owns the pure composition implementation and private
observation constructors. Its public `Kyyn.Evolution` module exposes no JSON types.
The private encoding values use the existing JSON library; the guest runtime can
consume them without the SDK depending on runtime transport. Pure binding generation
lives with the host plumbing protocol helpers, outside compiler-specific code.
An SDK output is not yet a host EvolutionReport: execution must check its chain
and derive changes as described below.

The intermediate type must line up, including across a schema change. A failed
step stops composition; `Diagnostic` is the shared value described in
[validation](0011-validation.md). The `evaluateEvolution` function is pure guest
evaluation; it is not the native host's compiler/process interpreter. No host
capability appears in that pure helper. The enclosing entry point is different:

```haskell
-- Guest entry; generated MicrosoftCalls is illustrated in ADR 0009.
fromEmail
  :: (EvidenceSnapshotRef, EvidenceRef, EmailId) -> Before.Root
  -> Program MicrosoftCalls (Either EvolutionFailure (EvolutionOutput After.Root))

fromEmail (snapshot, evidence, emailId) before = do
  email <- Microsoft.readEmail snapshot emailId
  pure (evaluateEvolution (changeFromEmail email) before)

changeFromEmail :: Email -> Evolution Before.Root After.Root
```

The imported proxy returns a typed Email; the author writes matching/business
logic in `changeFromEmail`. These are illustrative signatures, not implemented
SDK functions. A purely local entry can simply return `Pure` with its result.
The entry's request algebra states which work it needs; naming something an
evolution does not install every host capability.

`StepObservation` is SDK-produced data, not a closure or a second authored wire
format. Generated bindings retain the contract identity and encoded root values
on both sides of each `evolve` boundary. The host decodes those observations and
derives the actual changes while both sides are available. This explicitly
includes intermediate schemas: each annotated boundary must have a supported
root contract and generated encoding. There is no introspection of arbitrary
intermediate Haskell values. Ordinary helper functions within a step need no
annotation or encoding instance.
For a Before-to-Mid-to-After composition, Mid is an explicit schema in the
workspace and goes through inspection/binding generation like Before and After.
The intermediate contract is not inferred from an uninspected function body.

The host must check that observations form the evaluated chain from the selected
Before to the returned result; an independently authored list of claimed changed
IDs is not the diff. Compare contract identities and decoded values structurally:
the first observed before must match the selected Before, adjacent endpoints
must match, and the final observed after must match the returned result. An empty
chain is valid only for an unchanged root value and contract, as with identity.
A mismatch returns `ProposedCodeRejected` with a host diagnostic, not a successful
candidate with an invented unannotated step or incomplete report.
This checks the report's completeness, not whether its declared rationale is true.

The SDK carries the observations alongside the output over
the existing data protocol; this does not select a different protocol or require
KB authors to encode them. Intermediate root values need only survive derivation
of the report, not remain as full archived root snapshots. This first model may
do whole-root encoding, transfer and diffing per annotated step; it promises traceability, not
incremental execution or bounded memory.

Changing a reporting policy while leaving facts unchanged is ordinary useful
evolution, not an exceptional migration case. Review its source, changed checks
and resulting report alongside the empty fact diff. It needs no separate command,
type or lifecycle. The first reporting slice also includes a schema-changing
edge, so both uses of the same mechanism are exercised early (ADR 0021).

`Before` identifies an existing root by its **Git commit revision** and schema.
The revision selects the actual source facts, schema and code. Kyyn derives the
schema from that commit; an editable schema copy cannot independently redefine
what the revision means. `After` describes the target schema and proposed result,
with **no future Git revision**. That commit does not exist before acceptance.
Source-root reads use the selected commit, never ambient edited fact files.
The proposed target schema, code and captured inputs come from the authored
workspace; those files are legitimate evaluation inputs. ADR 0012 describes
where drafts live and which files enter an accepting commit.

Conceptually, these are workspace specifications, not additional type parameters
on every authored transformation:

```haskell
data Before = Before
  { revision :: GitRevision
  , schema   :: RootContract
  }

data After = After { schema :: RootContract }
```

These are host specifications. The concrete guest types remain `Before.Root`
and `After.Root`; sharing those namespace spellings does not mean the host imports
those modules. `Before.schema` is derived from the selected commit, not supplied
as a second author-controlled creation argument. `After.schema` is derived by
inspecting the captured target source before evaluation. Neither has an independent
schema field that a caller must keep in sync by hand.

An editable workspace and one captured evaluation input are distinct. Capture
the source files, target schema source, examples, local dependency sources and
supporting input files before
starting evaluation. There is exactly one base/provenance context in a candidate:

```haskell
data EvolutionWorkspace = EvolutionWorkspace
  { knowledgeBase :: KnowledgeBase
  , workspace :: EvolutionId
  }
data WorkspaceSnapshot  -- immutable file-tree value; ADR 0006

data EvolutionContext = EvolutionContext
  { knowledgeBase :: KnowledgeBase
  , workspace     :: EvolutionId
  , before        :: Before
  , material      :: WorkspaceSnapshot
  }

newtype CapturedEvolution = CapturedEvolution EvolutionContext
```

Here a workspace is simply the evolution's folder inside the KB, containing its
specifications, transformation source and supporting files. It is not a separate
Git worktree, interactive session or service. Capture fixes those bytes for one
evaluation; it does not introduce an invocation registry or a replay obligation.

Propose a complete target copy, not a patch overlay on the current root:

```text
evolutions/<id>/
  manifest.dhall      Before revision, state, name, explanation, intermediate bindings
  before/            source schema/imports copied from the selected commit
  target/            complete proposed non-fact contents of root/
  change/            Evolution.hs and evolution-only helpers/input files
  notes/             review notes, excluded from evaluation inputs
```

Creation copies the base root's code, configuration and examples into `target/`.
Editing that copy proposes their replacement; removing a target file proposes its
deletion. Facts are produced by `evolution`, not edited in a parallel `target/facts/`
tree. RootStore combines the returned facts with this target code snapshot. This
costs a copy of source/dependencies per workspace; begin there rather than invent
overlay rules, tombstones or dependency-sharing machinery.

`before/` preserves the source definitions for the author and archive, but the
selected Git commit remains authoritative. Capture verifies those definitions
against that commit; rebasing refreshes them. `change/` and `before/` are archived,
not installed into the current root. The manifest's explanation covers the whole
proposal, including source/config/example-only changes with no fact history entry.
Its explanation, Before selection and intermediate declarations are captured; lifecycle state and separate
review notes are not evaluation inputs. Changing a note does not change a candidate.

The manifest is a hermetic Dhall value with this shape:

```dhall
{ before : { revision : Text }
, name : Text
, explanation : Text
, state : < Draft | Ready | Accepted >
, intermediates : List { name : Text, schemaType : Text, schemaMetadata : Text }
}
```

Creation sets `intermediates` to an empty list. An author declares a named intermediate
binding here, selecting its Haskell type and metadata export; the defining modules
can live in `change/`. `beforeRoot` and `afterRoot` are generated from the selected
Before and target, not repeated in this list. Names must be valid, unique binding
identifiers and must not collide with those two generated names. Build preparation
checks declarations and inspects their exports; capture still permits unfinished code.

The revision is a full Git commit object ID, not a branch name or short prefix.
`WorkspaceStore` decodes and projects an explicit file tree; it does not inspect
Haskell or resolve the selected revision:

```haskell
data WorkspaceStore :: Effect where
  ReadWorkspaceSnapshot
    :: FileTree -> WorkspaceStore m (Either [Diagnostic] WorkspaceSnapshot)
  EncodeWorkspaceSnapshot
    :: WorkspaceSnapshot -> WorkspaceStore m (Either [Diagnostic] FileTree)

runWorkspaceStore
  :: DhallHandling :> es
  => Eff (WorkspaceStore : es) a -> Eff es a

matchesCapturedInputs :: WorkspaceSnapshot -> WorkspaceSnapshot -> Bool
```

The snapshot retains the parsed manifest and separate before, target, change and
notes trees with their directory prefixes stripped. Projection rejects files
outside the layout and any `target/facts` tree. Incomplete draft source is
capturable; projection does not promise that it compiles or matches the selected
commit. Evolution capture performs that source-selection check separately.
Input equality compares the parsed Before revision, name, explanation and intermediate declarations, and
the exact before/target/change paths and bytes. Manifest formatting, lifecycle
state and notes are excluded. A same-schema code/configuration edit still changes
the inputs. This pure comparison is not the store's live-workspace read or its
independent Accepted/Ready check.
Encoding restores those prefixes and uses DhallHandling to render the manifest;
it preserves source/input/note bytes, not the manifest's formatting. The same
layout checks apply when encoding an authored snapshot.

Use stable, non-conflicting authored module names for schema definitions that must
coexist in an evolution build. Two different definitions of a module named `Schema`
cannot simply be placed on the same import path. Friendly qualified aliases keep
the underlying names out of ordinary type signatures and expressions:

```haskell
-- Ordinary current KB module
import qualified SchemaV2 as Schema

validate :: Schema.Root -> ValidationReport
```

The evolution instead makes both sides explicit:

```haskell
import qualified SchemaV1 as Before
import qualified SchemaV2 as After

change :: Evolution Before.Root After.Root
```

This is the owner-selected authoring convention, not only a first-proof workaround.
`SchemaV1`/`SchemaV2` illustrate distinct names, not a prescribed numbering scheme
or a new version registry. An unchanged shared definition keeps its name and needs
no duplicate module; distinct changed definitions required together need distinct
names, including dependencies where applicable. When adopting the new schema,
ordinary modules update their import declaration but retain the friendly `Schema`
alias. Actual schema changes may of course require changes to their code too.
Kyyn can scaffold these imports without compiler namespace rewriting. The accepted
root retains only the current definitions; previous definitions live in evolution
archives and Git, as illustrated in the [walkthrough](../walkthroughs/todo-evolution.md).

Captured material contains the projected target bytes, not a stored compiler
adapter or independently selected schema descriptor. During build preparation,
EvolutionExecution reads `target/kb.dhall` through RootStore's
`ReadRootDefinition`, then constructs `SchemaSource` from those captured modules,
selected exports and the installed SDK. That compiler input is derived, not
persisted in the context. Capture does not require even an unfinished target
manifest or proposed source to compile;
the context exists even when deriving `After` or compiling the evolution fails.
That permits reviewing failed proposals under ADR 0023.
Module inventory and collision diagnostics belong to build preparation inside
`EvaluateEvolution`, not capture. Assemble target modules, evolution-only modules,
generated adapters and the Before schema's import closure. Identical shared modules
are compiled once; different definitions of the same module name are rejected with
their source locations. Import-path order must not choose a winner. This includes
changed dependencies of schemas: rename those modules and update their importers
when both versions are needed. Do not import Before's unrelated validators/queries
or delete its archival copies merely to deduplicate compiler inputs.
SchemaInspection returns the captured source paths loaded while checking the selected
type, using compiler module source locations. These paths select the Before subset;
they are not part of contract identity. Keep the target's authored sources and
`change/` available for ordinary helper imports: a helper used by the entry need
not occur in the target Root type's own import closure. The compiler selects what
the resulting entry actually imports. Generated adapters must not overwrite authored
files. Collision diagnostics identify the path and direct authors to use distinct
module names for definitions that must coexist. Authored Haskell inputs use `.hs`;
preparation rejects `.lhs` and `.hsc` rather than allowing the compiler's extension
search order to select a different definition. This does not prohibit non-code
supporting files in the workspace.
The material identifies both the proposed executable code and the selected
workspace contents to archive. Together with the evaluated root it is sufficient
to construct acceptance without rereading live source and substituting different
bytes. The [candidate wrapper](0004-knowledge-base.md) retains this context and
the report subsequently produced by evaluation while
its result is checked. Temporary input evidence need survive only as long as
needed for evaluation/checking; the archive policy need not preserve all evidence
bytes forever. No registry of approved snapshots is introduced.

Workspace operations return entities rather than printing, and listing remains
independent of root compilation:

```haskell
data EvolutionStore :: Effect where
  ListEvolutions
    :: KnowledgeBase -> EvolutionFilter -> EvolutionStore m [EvolutionSummary]
  ResolveEvolution
    :: KnowledgeBase -> EvolutionId -> EvolutionStore m EvolutionWorkspace
  CreateEvolution
    :: KnowledgeBase -> EvolutionName -> GitRevision
    -> EvolutionStore m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] CapturedEvolution)
  SaveCandidate
    :: Candidate Root -> EvolutionStore m ()
  LoadCandidate
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] (Maybe (Candidate Root)))
  ReadEvolutionState
    :: EvolutionWorkspace -> EvolutionStore m EvolutionState
  MarkReady
    :: EvolutionWorkspace -> EvolutionStore m ()
  MarkDraft
    :: EvolutionWorkspace -> EvolutionStore m ()
  MatchesCapturedInputs
    :: EvolutionContext -> EvolutionStore m (Either [Diagnostic] Bool)
  ExportAcceptedWorkspace
    :: Candidate Root -> EvolutionStore m SubtreeReplacement

runEvolutionStore
  :: (RootStore :> es, RootOpening :> es, WorkspaceStore :> es,
      FileSystem :> es, Git :> es, DhallHandling :> es, Failure :> es)
  => Eff (EvolutionStore : es) a -> Eff es a
```

These are selected constructors; review-note persistence is defined in
[interaction](0023-interaction.md). Git is needed to resolve the specified source
commit, not to advance it. RootOpening supplies the source commit's derived contract
through `LoadSourceAt` (ADR 0006); RootStore remains Dhall-only. WorkspaceStore
decodes workspace manifests through DhallHandling; it does not execute proposed
Haskell. Listing needs no compiler frontend,
and capturing proposed bytes does not compile them. Creation/capture may derive
the source schema on a cold load through RootOpening's SchemaInspection dependency,
including evaluation of its pure schema metadata export under ADR 0005. This does
not decode facts or run root validators/transformations. Operation-specific composition installs
the semantic handlers needed by the command.
Installing Git plumbing for a complete store handler does not launch Git on every
list call; do not use partial handlers that fail on the store's other operations.

The implemented store handler requires `FileSystem`, `WorkspaceStore`, `RootOpening`,
`RootStore`, `DhallHandling`, `Git` and `Failure`. Git supplies the implemented
FindAcceptance lookup from ADR 0012. Capture reads the workspace at the derived location,
decodes its manifest, and calls `LoadSourceAt` for that manifest's Before revision
and the owning KB's root subtree. The projected `before/` tree must equal that
source root's entire authored `src/` tree (prefix stripped) exactly, including
helper additions, deletions and byte edits. A mismatch returns a diagnostic asking
the author to refresh the copy; it does not choose edited definitions over Git.
The resulting Before contract comes from the selected source root, never the
target or copied modules. The captured context and files are immutable values;
this operation does not yet save them to local storage.

Live `MatchesCapturedInputs` reads and decodes the current workspace and applies
the pure comparison above. It does not load the source root or require its compiler
to run. A valid changed workspace returns `Right False`; malformed workspace
contents return diagnostics, and storage/compiler/Git infrastructure errors remain
operational Failure. Neither operation confers readiness or acceptance.

Each `EvolutionSummary` includes its stable `EvolutionId`, human name and state.
Names may repeat; IDs do not. Commands use the ID returned by creation/listing,
and `ResolveEvolution` reports an unknown ID without creating a workspace.
IDs use nonempty lowercase hexadecimal directory keys, distinct from author-chosen
names. They are within the storage filename pass-through alphabet and need no
escaping; generation belongs to workspace creation. The workspace's location is
derived from its owning KB and ID, not stored as another path that can disagree.
This also resolves a saved candidate's context to its owning workspace without
publication reconstructing a private directory convention.

`ListEvolutions` and `ReadEvolutionState` resolve the checkout's current HEAD once
per operation and use the [acceptance lookup](0012-acceptance.md) for that revision.
An Accepted archive there takes precedence over a stale local Ready manifest;
the summary includes the accepting commit. Otherwise they report local manifest
state. This reads Git metadata, not guest code, and neither repairs local files
nor advances a ref. Listing after interrupted synchronization must not invite
accepting the same change again.
The manifest's state field never establishes acceptance: the committed archive
and its introducing commit do (ADR 0012). A local `Accepted` label alone is not
a successful acceptance lookup.

The target code is a pure projection of the captured WorkspaceSnapshot; it needs
no store effect. `SaveCandidate` persists
the materialized root, context and derived report so another process can load them;
it does not advance Git or persist a `Validated` marker. The root/context must
refer to fixed stored bytes, not source files that will change when editing resumes.
`LoadCandidate` returns `Right (Just candidate)` for the workspace's latest saved result,
or `Right Nothing` only when its latest pointer is absent. Readable contract
descriptions that no longer reconstruct their stored fingerprints return a
`candidate.stale` diagnostic asking for a new application. Unreadable or malformed
saved material raises operational Failure, not `Nothing` or an implicit request
to rerun the evolution. Loading does not compile source or execute the guest.
[Checking](0011-validation.md) earns validation
again after loading. Deleted local results can be regenerated by explicit evaluation.

Use ignored local storage for captures and candidates. A save publishes a complete
result before making it the workspace's latest result; never expose a partial save.
Replacing that selection does not change previously loaded snapshot values.
One simple implementation uses private directories and a latest-result
pointer, not an attempt history, approved-candidate registry or public content store.
Store-local locations are not committed as portable identities in the archive.

The implementation writes a fresh `.kyyn/candidates/<id>/` containing `capture/`,
the materialized `root/` and host-owned `candidate.json` metadata/report. Fact
files remain Dhall. Contract descriptions carry one format version, the complete
DataType and SchemaMetadata and the whole-contract fingerprint. Restore runs
`checkContract` and `checkRootLayout` and requires fingerprint equality, including
contracts retained in each recorded fact. An unsupported saved format is stale;
there is no migration or compatibility framework. The repository and KB prefix
come from the explicit load location; the saved evolution ID must match it.
This permits moving a checkout without persisting an absolute local path.
Loading also checks stored root facts and recorded fact shapes/identities against
those restored contracts. It does not rederive a report by replaying old code.

Only after all files are written does `ReplaceBytes` atomically publish
`latest/<evolution-id>`. Save failure leaves the previous selection intact; an
unfinished private directory may remain. Loaded values and older result directories
are never modified by a subsequent save. This provides atomic visibility, not
power-loss durability. The KB template must ignore `.kyyn/`; the store does not
edit a user's ignore rules. These files stay outside root and evolution exports.

`MatchesCapturedInputs` compares the workspace's current evaluation inputs with its
capture. `ExportAcceptedWorkspace` serializes the captured source/specifications,
with the KB-relative `evolutions/<id>` prefix defined by this store,
fixed report and Accepted state for the proposed commit; it does not mark the live
workspace accepted or move a ref. It also preserves the selected workspace's
review notes, retaining their original subjects; those notes are read separately
from captured evaluation inputs, not silently dropped when replacing the archive.
Publication calls this operation only for a checked candidate. It can therefore
fail before publication without changing the workspace lifecycle.

Creation has one scaffold form. It loads source at the selected revision, copies
its entire authored `src/` tree to `before/`, copies all non-fact root files to
`target/`, and writes a Draft manifest with the supplied human name, Before revision
and an initially empty explanation. Examples and configuration are copied too;
their suitability after editing is checked with the candidate, not guessed during
creation. The author edits `target/` for either same-schema or schema-changing work;
there is no separate schema-request mode or stale creation-time After descriptor.

Source inspection and workspace encoding finish before directory allocation.
FileSystem reserves a fresh hexadecimal child of the live `evolutions/` directory
using exclusive creation, then the store writes the encoded files and returns its
KB-scoped handle. Exclusivity is against that live directory, including archives
that remain there, not a global ID registry or a scan of deleted Git history.
Names can repeat and never choose filesystem paths. Write failure returns an
operational Failure, not a successful workspace; an unfinished directory can remain
for inspection/removal. Creation does not update Git and does not promise atomic
multi-file persistence under crashes.

Creation writes a real identity entry at `change/Evolution.hs`, with module name
`Evolution` and binding `evolution`. Its generic signature is valid for the copied
same-schema target and specializes to the selected root at build preparation:

```haskell
evolution :: root -> Program calls (Either EvolutionFailure (EvolutionOutput root))
evolution = pure . evaluateEvolution identityEvolution
```

Authors refine that entry with their concrete Before/After types and declared
capabilities when implementing a change. A pure entry stays polymorphic in its
request algebra; it does not gain a host capability through the identity scaffold.
`EvolutionWorkspace` carries only its key and owning KB; its location is derived.

The host loads the selected structurally readable source snapshot and evaluates the
entry. The application then materializes and saves an unchecked candidate through
[RootStore](0006-storage.md) and EvolutionStore:

```haskell
data EvolutionExecution :: Effect where
  EvaluateEvolution
    :: CapturedEvolution
    -> EvolutionExecution m (Either PreviewRejection EvaluatedEvolution)

data EvaluatedEvolution = EvaluatedEvolution
  { captured :: CapturedEvolution
  , after  :: After
  , value  :: CheckedValue
  , report :: EvolutionReport
  }

runEvolutionExecution
  :: (RootStore :> es, RootOpening :> es, PluginInvocation :> es, EvidenceStore :> es,
      GuestCompilation :> es, ProcessExecution :> es,
      FileSystem :> es, SchemaInspection :> es,
      Failure :> es)
  => Eff (EvolutionExecution : es) a -> Eff es a

applyEvolution
  :: (RootStore :> es, EvolutionStore :> es, EvolutionExecution :> es)
  => CapturedEvolution
  -> Eff es (Either PreviewRejection (Candidate Root))

data PreviewRejection
  = ProposedCodeRejected [Diagnostic]
  | EvolutionRejected EvolutionFailure
```

EvolutionExecution owns source/adapter preparation, entry/schema compilation and
effectful entry evaluation, including typed dispatch to declared plugin methods.
It delegates compilation to [GuestCompilation](0002-runtime.md), not a locally
assembled MicroHs command. ProcessExecution remains necessary for the compiled
entry's execution and protocol, separately from compiler invocation.
PluginInvocation installs the plugin's
own HTTP/Secrets requirements; these do not become authored entry capabilities.
The row is a lowering contract, not IO in porcelain. RootExecution in ADR 0011
retains validation and snapshot queries without acquiring plugin/acquisition
handlers merely to check a root. Source, dependency and config bytes are fixed
by capture; providers are not contacted during compilation.

EvolutionExecution itself calls `LoadRootAt` for the captured context's KB and
Before revision. It does not accept an independently supplied Root: that type
alone cannot establish its origin. Compare the loaded contract and copied source
with the captured Before before preparation; a mismatch requires a new capture.
The input need not pass semantic validation. An evolution can therefore
repair invalid facts introduced by an ordinary Git edit or merge. Preview surfaces
the source validation report separately, without treating its errors as rejection
of the transformation. The resulting candidate must still pass its own checks
before acceptance. An unreadable schema or structurally undecodable facts require
source-level repair before a typed evolution can consume them. Ordinary browsing
does not acquire this diagnostic/execution exception to validated reads.

The candidate uses the target contract and `CodeSnapshot` projected from
`context.material`, not the accepted root's code or validator by default.
`MaterializeRoot` receives that proposed code snapshot. Ill-typed/unsupported
proposed schema or entry dependency returns `Left (ProposedCodeRejected diagnostics)` before
a candidate root exists. An entry's or pure helper's
refusal returns `Left (EvolutionRejected failure)`. These are
ordinary preview outcomes, with the captured context still available for review.
A missing compiler or compiler crash is an operational
[Failure](0019-failures.md), not an empty successful result.

Independent target validators and queries compile in `CheckRootCode` during
candidate checking, after materialization, not through an additional pre-evaluation
gate. An evolution may therefore evaluate successfully and its candidate then fail
because a target validator does not compile. Evaluation answers whether the change
runs; candidate checking answers whether its result is acceptable. Both outcomes
remain visible on the same proposal. Do not construct an empty-facts Root merely
to invoke code checking earlier.

After materialization, `applyEvolution` calls `SaveCandidate` before returning
`Right candidate`. Subsequent semantic/example rejection leaves that unchecked
result available for inspection; compilation or transformation rejection creates
no replacement candidate. An earlier saved candidate is not a successful outcome
of a later failed evaluation. Publication still requires unchanged captured inputs
and fresh checking of the explicitly loaded result.

Each evolution workspace provides one conventional guest binding, `evolution`.
Choose a reusable function and bind its arguments in ordinary source:

```haskell
evolution
  :: Before.Root
  -> Program SalesCalls (Either EvolutionFailure (EvolutionOutput After.Root))
evolution = importSales September
```

`SalesCalls` illustrates the helper's declared capabilities. `importSales` may be
a reusable parameterized helper, but the workspace entry has already bound its
business arguments. Its only remaining input is the root selected by Before.
Capture includes this binding and the source/dependencies and supporting input
files it uses. There is no separate selected-entry field, argument manifest or
`EvolutionEntry input` handle to maintain alongside it. Changing September to
another input is an ordinary source edit requiring fresh evaluation and checks.

Kyyn generates an adapter for this fixed entry, supplies Before's actual root,
and materializes the returned value with the report derived from its observations.
The binding is compiled locally as source; no Haskell closure travels over the
wire. Protocol messages still contain data, including host requests and returned
values. Web/MCP/CLI evaluate the selected evolution workspace, not a separately
recorded function-and-arguments invocation. Reusable helpers need no separate
proposal-authoring handoff or guest ProposalAuthoring effect.

An entry may read selected evidence or explicitly acquire it during evaluation.
The candidate records the result actually produced; checking and acceptance use
that materialized result, not a second execution of the entry. Re-evaluation may
observe different external data and produces a new candidate to inspect. No
promise of replaying live effects, mandatory RPC transcript, automatic secret
capture or durable continuation is implied. Pure validators and helpers only see
their explicit inputs. Cancellation/failure stops further work but cannot undo
evidence acquisition already performed; it never authorizes acceptance.

## Updating the base before acceptance

An unaccepted evolution, including its `Before`, is editable in place. If its
base no longer equals local head, the agent can update `Before.revision` to head,
refresh `Before.schema` from that commit, and repair the transformation and target
schema as needed. Re-evaluate against the new base's actual facts, rerun validation
and examples, and regenerate the diff for inspection. Previous results/checks do
not apply to the revised evolution. Merely changing a revision field while
retaining the old input/result is not rebasing.

This is an author-directed rebase, not automatic conflict resolution. Same-schema
changes may type-check while overwriting an intervening business decision; the
new diff makes that visible and the human/agent decides what is intended. No
requirement to create a new proposal or archive every unaccepted attempt.

## Composition and lifecycle

Composition sequences compatible typed edges, conventionally `>=>`; `evolve`
introduces a step with declared rationale. This is arrow-like composition, not a claim that
`Evolution a b` itself is an ordinary one-parameter Monad. `do` notation inside
fallible step construction is separate from composing arbitrary schema changes.
Successful composition appends ordered step observations. List concatenation is
associative; identity returns its input with no observations. Regrouping
`(a >=> b) >=> c` as `a >=> (b >=> c)` must not alter the report. Do not concatenate
explanations into one string or invent grouping nodes based on parenthesization.
An aggregate is ordinary composition, not a separate Changeset entity/lifecycle.

`modify`, `remove`, `append` and payload traversal operate on stable fact IDs.
Missing targets and duplicate additions return diagnostics, not silent success.
Authored labels explain intent; actual before/after data determines the diff.
Transformation code may change structure in ways no optic can infer automatically.

## Declared rationale and record history

On the host, derive a reviewable ordered report from the annotated boundaries:

```haskell
newtype EvolutionReport = EvolutionReport [StepReport]

data StepReport = StepReport
  { rationale :: Rationale
  , changes   :: [FactChange]
  }

data FactChange = FactChange
  { collection :: CollectionId
  , fact       :: FactId
  , before     :: Maybe RecordedFact
  , after      :: Maybe RecordedFact
  }

data RecordedFact = RecordedFact
  { contract :: RootContract
  , value    :: Value  -- complete Fact envelope
  }
```

`Nothing` before means addition, `Nothing` after deletion, and two present values
mean modification; two absent or equal same-contract values are not changes.
Preserve the relevant contract descriptions with recorded values, including across
schema changes, so history does not depend on recompiling archived modules.
The host compares identified facts at each boundary, including changes of their
contracts, rather than relying on transformation labels or file paths.
Use collection identity plus FactId as the key, not collection position. Duplicate
IDs within a collection are rejected at every boundary, including intermediate
roots; the same ID in different collections is independent. Report ordering is
step order, then collection identity and FactId. A list reorder alone is not a
fact modification, though its root values still participate in the chain check.

The recorded contract is the whole root contract. A whole-contract identity change,
including metadata-only changes, therefore records retained facts as interpretation
changes even if their encoded values are equal. Do not introduce a second,
fact-specific compatibility identity to suppress these changes.

Result checking uses the independently inspected contracts, never contract
descriptions supplied by the guest:

```haskell
checkEvolutionReport
  :: RootStore :> es
  => [RootContract]   -- explicitly inspected intermediate contracts
  -> RootContract -> Value  -- selected Before and its decoded value
  -> RootContract           -- inspected target
  -> EvolutionObservation   -- decoded guest After value and step observations
  -> Eff es (Either [Diagnostic] (CheckedValue, EvolutionReport))
```

This capability function checks every source, intermediate and target value through
RootStore, checks the complete chain, then derives the report. It does not claim
that an arbitrary supplied Before value came from Git: EvolutionExecution owns
selecting that input as described above. Guest refusal is decoded separately from
malformed protocol; no partial successful output accompanies a refused evolution.

These reports duplicate changed fact data: each modified fact retains both its
before and after values for each step that changes it. A whole-schema migration
can therefore archive roughly the combined size of the old and new fact data,
plus contracts/metadata, in addition to the current fact tree, before Git's own
compression. More steps can retain more intermediate values. This is a cost of
the chosen inspect-without-reexecution model, not a free consequence of using Git.
Measure archive growth and transfer volume in ADR 0021; do not preemptively add
report deduplication, retention services or reconstruction from old guest code.

Rationale is **declared by the author**. The actual changed values are derived;
supporting evidence and explanation are not inferred from HTTP calls, plugin
invocations or observed reads. A reference means the author cites it, not that
Kyyn proved causality, correctness or exhaustive use of all available evidence.
Local corrections and policy changes can have an empty evidence list.

Each rationale applies to that step's actual changes. A step changing fifty facts
has a shared explanation unless the author splits it into finer steps. Two steps
changing the same fact retain both changes and rationales, even if they cancel in
the final root diff. A no-op step may retain its explanation, but does not invent
a fact change. Source/configuration-only changes remain visible in the overall
workspace comparison even when no fact history entry is produced.

The candidate retains this fixed report alongside its evaluated root. It is
evaluation output, not part of the pre-evaluation `WorkspaceSnapshot`. Checking
preserves it; acceptance archives it with the captured source and specifications
in the same Git commit as the new root (ADR 0012). Do not regenerate it by
rerunning an effectful entry at acceptance or reconstruct it later from only a
final diff and detached rationale list. Failed evaluation is not an accepted
partial evolution. No requirement to archive every failed or abandoned attempt.

Record history selects a KB revision and `(CollectionId, FactId)`, walks Git and
the accepted evolution reports, and returns matching changes with their declared
rationale. It needs neither historical guest execution nor a separate provenance
database/indexing service. Git identifies the accepting commit and chronology;
step order identifies changes inside that commit. ADR 0023 exposes this in both
review surfaces.

Stable IDs provide continuity, not display names, list positions or filenames.
An ID change, split or merge is visible as additions/deletions; continuing lineage
through it requires an explicit authored relationship. Do not infer that mapping
or introduce a general lineage system in this first design. Ordinary Git edits
may have no evolution report: show the available diff and say that rationale is
unavailable, rather than borrowing a neighbouring evolution's explanation. After
a merge, do not attribute conflict-resolution edits to an ancestor's report.
Evidence references can remain useful after local evidence bytes disappear;
report unavailable evidence honestly (ADR 0014), without requiring permanent
custody of every cited source.

Persist only `Draft`, `Ready`, `Accepted`. Drafts are editable and can be omitted
from ordinary review lists; users can explicitly list all. Ready is an author's
intent to submit, not proof of validation. Acceptance requires this Ready state
in addition to its existing result/base checks; an agent can leave unfinished work
Draft so a scripted acceptance fails and preserves it for review (ADR 0025).
Authoring operations that change evaluation inputs mark the workspace Draft;
an external editor cannot be assumed to notify Kyyn. A raw edit may leave the
stored label Ready, but `MatchesCapturedInputs` then fails and acceptance refuses
the old result. There is no watcher promising automatic demotion. Use `MarkDraft`
when reopening work and `MarkReady` when submitting it; neither operation accepts
an already Accepted workspace. Changed-base status is calculated when
checking/accepting, never a persisted `Stale` state needing a manager.
Readiness is lifecycle metadata, not transformation input. Marking an unchanged,
evaluated workspace Ready does not itself alter its captured source or invalidate
the result. Equality of captured evaluation inputs excludes that status marker;
acceptance checks the current status separately. Actual source/config/input edits
still require fresh evaluation and checking. No second approval token is introduced.

```haskell
data EvolutionState = Draft | Ready | Accepted

data EvolutionFilter = Reviewable | AllEvolutions
```

Here `Reviewable` selects Ready entries; `AllEvolutions` includes drafts and
accepted archaeology. This filter is data passed to the store, not a second
state machine. Accepted workspace deletion is not part of draft removal.

Keep accepted workspaces, their before/after definitions, source, step reports and
`Before.revision`. Git history supplies the accepting commit and its parent;
do not embed the accepting commit's own revision inside `After`. Exclude these
workspaces from normal imports/builds. Remove only unaccepted
workspaces through an explicit operation, preserving unrelated files. A proposal
is an evolution under review, not a separate transaction hierarchy.
Once accepted, an evolution has completed its job: preserving its source and
report does not require keeping it compilable or runnable. Even a same-schema
transformation that still typechecks targets its recorded Before revision, not
the new head. Schema/dependency changes may also prevent compilation. Reusing
its idea means authoring a new evolution against the chosen current base, not
replaying the accepted workspace as a normal operation.

## Alternatives and verification

Reject separate direct fact mutation, migration machinery, root-level old schema
modules, and deletion of accepted workspaces. No requirement to rerun historical
code forever. Test schema change plus add/edit/delete, failed step behavior,
candidate inspection without acceptance, draft filtering and retained archaeology.
Test a workspace binding a reusable helper's arguments in source: evaluation
uses the captured binding, and an edited binding requires a new evaluation.
Test composition associativity/identity including report order, two steps touching
one fact, cancelling changes, schema-changing boundaries and shared rationale for
multiple facts. Reopen per-record history without compiling historical code;
cover deletion, missing evidence, and ordinary Git changes without rationale.
Test repairing a structurally readable but semantically invalid head: show source
errors, evaluate the repair, reject an invalid result and accept a valid result
only through the normal checks and local-head comparison.
Test rebasing both with and without a schema change: the new input comes from
the selected commit and the diff compares the result with that base, not the old
root. Acceptance requires `Before.revision == local head` under ADR 0012.

The implemented SDK and generated-binding proof runs the same source under GHC
and pinned MicroHs. It covers ordered per-step observations, associative composition,
identity, failed-step short-circuiting with no partial success, cancelling changes,
schema changes and a same-type metadata-only transition. Both compilers reject
wrong typed bindings and public construction of EvolutionOutput. The actual
identity scaffold is compiled in this proof too. This establishes SDK composition
and encoding. The proof also transports successful observations and structured
refusal diagnostics through the guest JSON encoder and native decoder, and derives
the three expected host step reports. Focused native tests check chain discontinuity,
unknown contracts, malformed intermediate values, duplicate IDs, metadata/schema
changes, additions/deletions, cancelling edits and position-independent matching.
The separate workspace execution proof uses the actual EvolutionExecution handler,
RootOpening, schema inspection, MicroHs compilation/evaluation and Dhall stores.
Its recording Git handler supplies only the context's exact Before subtree. The
handler evaluates a value edit, metadata transition and schema migration, retaining
the captured context; the test materializes and reopens exactly the checked After.
Changed unrelated Before validators/metadata modules do not enter the compilation.
Native recording-handler tests cover preparation/compilation errors, guest refusal,
runtime/protocol failure, closure collisions and captured intermediate declarations.

The implemented execution path specializes the entry to `Program NoRequests`;
no plugin handlers are installed until the plugin invocation slice exists. A
concretely effectful entry is a type error on this path, not an ignored request.
Successful evaluation returns `EvaluatedEvolution`, not a Candidate. Candidate
materialization/persistence through `applyEvolution` remains unimplemented; no
unsaved candidate bypasses the SaveCandidate-before-return rule above.
