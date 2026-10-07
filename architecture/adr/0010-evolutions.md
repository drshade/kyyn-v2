---
id: 0010
title: 'One evolution mechanism for facts, schema and meaning'
---
# One evolution mechanism for facts, schema and meaning

## Context

Updating facts, migrating a schema and revising the tools that interpret them
must not be disconnected workflows. Evaluation must be useful without acceptance.

## Decision

An evolution is one of the three KB entry-point kinds in ADR 0008. The authored
entry is an ad hoc `Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)`
or a recipe-based `RecipeEvolution Root State` value, as specified below.
The guest wrapper and recipe data are defined in [ADR 0014](0014-evidence.md).
The generated adapter applies
it to Before and returns After with annotated step observations; Kyyn materializes
a candidate and derives its review report. It never implicitly accepts its result.

The reusable `Evolution before after` value describes a fallible pure
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

-- Generated in Kyyn.Workspace.Evolution for this workspace:
editBefore
  :: Rationale -> Edit (KnowledgeBase Before.Root) ()
  -> Evolution (KnowledgeBase Before.Root) (KnowledgeBase Before.Root)

evolve
  :: Rationale
  -> (KnowledgeBase Before.Root -> Either EvolutionFailure (KnowledgeBase After.Root))
  -> Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)

edit
  :: Rationale -> Edit (KnowledgeBase After.Root) ()
  -> Evolution (KnowledgeBase After.Root) (KnowledgeBase After.Root)

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

`EvolutionOutput` and `StepObservation` are abstract in the public SDK API; the
generated adapter calls `evaluateEvolution`, rather than authors wrapping their
entry in `pure . evaluateEvolution`. Generated step constructors use
`Kyyn.Evolution.Internal`, which an author can also import from the vendored source.
Public exports guide construction; they do not enforce observation completeness.
The host's contract/value and chain checks below are the actual boundary checks.

### Ad hoc and recipe-based authoring

A workspace has an explicit kind, captured with its evaluation inputs:

```haskell
data EvolutionKind = AdHoc | RecipeBased RecipeId
```

Ad hoc evolutions perform general changes, including domain schema migration and
creating, updating or removing recipe definitions and their state. Recipe-based
evolutions select exactly one existing recipe from Before and change domain facts
plus that recipe's state. They preserve domain schema, recipe definitions/state
types, source and configuration. Same endpoint Haskell types alone do not establish
these artifact constraints; compare captured source/configuration as well.

Open-agent and closed-flow recipes both produce recipe-based evolutions. A closed
run produces one workspace. No multi-recipe run or cross-recipe state composition
is introduced. An ad hoc schema migration may update several recipe definitions
as part of its general root transformation; that is not a multi-recipe run.

The guest facade exposes typed editing of the selected pair:

```haskell
data RecipeEvolution root state
data RecipeEdit root state a

recipeEdit
  :: Rationale -> RecipeEdit root state ()
  -> RecipeEvolution root state

editFacts :: Edit root a -> RecipeEdit root state a
getRecipeState :: RecipeEdit root state state
putRecipeState :: state -> RecipeEdit root state ()
modifyRecipeState :: (state -> state) -> RecipeEdit root state ()

(>=>)
  :: RecipeEvolution root state -> RecipeEvolution root state
  -> RecipeEvolution root state
```

RecipeEdit has the ordinary fallible State-style sequencing used by Edit.
The generated facade supplies domain collection handles focused on the root for
editFacts. It does not expose another recipe's state through this context.
Composition sequences the same typed pair and appends observations, using the
same evolution machinery, not a second evaluator or publication implementation.
The recipe facade uses the same composition operator convention as ad hoc work.

For example, an author can edit facts and remember an investigated email together:

```haskell
evolution :: RecipeEvolution Before.Root ReviewState
evolution =
  recipeEdit (Rationale "Create a task from George's email" [emailReference]) $ do
    editFacts $
      within BeforeCollections.todos $
        append (Fact (FactId "prepare-report")
                     (Before.Todo "Prepare September report"))
    modifyRecipeState $ \s ->
      s { reviewedIds = "email-123" : s.reviewedIds }
```

Before supplies both values from the same recorded Git revision. There is no
Maybe state: recipe creation supplies its initial state; stateless recipes use ().
Generated adapters lower this typed pair to the common observation/check/report
path and preserve all other root material. Missing state is an error, not a reset.
A state-only edit is valid and appears in review even with no changed facts.

The workspace kind determines the expected entry signature and selected recipe.
Changing it or rebasing invalidates the saved candidate. Rebase reloads both
domain facts and recipe state; acceptance never substitutes newer state into a
previously evaluated result. [ADR 0014](0014-evidence.md) owns state persistence,
and [ADR 0028](0028-agentic-workflows.md) owns closed-flow proposals.

### Endpoint contracts

One workspace has exactly two endpoint contracts: Before and After. Optional
Before edits precede a transition to After; After edits follow it. Same-contract
evolutions need no transition step. Ordinary types and helper functions inside a
step need no contract declaration or encoder; only the annotated boundaries are
visible to Kyyn. Multiple distinct schema transitions require separate evolutions.

`RootBinding` and the binding-taking step constructor live in
`Kyyn.Evolution.Internal`. The generated workspace module supplies bindings
internally, re-exports the public evolution, diagnostic and fact vocabulary, and
does not export `beforeRoot` or `afterRoot`. For example:

```haskell
import Kyyn.Workspace.Evolution
import qualified RootV1 as Before
import qualified RootV2 as After
import qualified Kyyn.Workspace.Before as BeforeCollections
import qualified Kyyn.Workspace.After as AfterCollections

evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution =
  editBefore (Rationale "Correct the old title" []) (zoom facts correctTitle)
  >=> evolve (Rationale "Track review status" []) (onFacts introduceReviewStatus)
  >=> edit (Rationale "Remove a cancelled task" [])
    (within AfterCollections.todos $ remove (FactId "todo-002"))
```

There is one `edit`/`evolve` vocabulary over the complete guest value. Domain
helpers remain ordinary typed functions or state actions; `onFacts` and `zoom facts`
reuse them without manual recipe copying. Generated collection handles compose
the facts lens internally: `AfterCollections.todos` has type
`Collection (KnowledgeBase After.Root) After.Todo`. Ordinary `within` edits need
no extra zoom. Recipe definitions and heterogeneous state use ADR 0014's typed
recipe operations. In a recipe-based facade the collection handles instead focus
on the domain root inside editFacts. Accepted archives remain readable without
recompiling entries.

Same-schema edits use standard strict StateT over Either. A refusal returns no
partially modified root. One `edit` has one rationale and one observed boundary,
even when its state action edits several facts or collections:

```haskell
type Edit root = StateT root (Either EvolutionFailure)
type CollectionEdit a = ReaderT Text (Edit [Fact a])
data Collection root a -- abstract publicly; generated name and collection lens

within :: Collection root a -> CollectionEdit a r -> Edit root r
current :: FactId -> CollectionEdit a a
update :: FactId -> Edit a r -> CollectionEdit a r
remove :: FactId -> CollectionEdit a ()
append :: Fact a -> CollectionEdit a ()
refuse :: [Diagnostic] -> Edit root a

zoom :: Lens' root a -> Edit a r -> Edit root r
modifying :: Lens' root a -> (a -> a) -> Edit root ()
assigning :: Lens' root a -> a -> Edit root ()
```

The endpoint collection modules expose one handle per declared collection, named
after its root field; the handle's diagnostic name comes from CollectionDecl.
This preserves distinct logical collection names and Haskell field names. Schema
modules retain their ordinary selectors; collection modules do not re-export or
replace them. The constructor and state executor remain Internal conveniences for
generation, not public author vocabulary. As elsewhere, this is a construction
convention, not a sandbox against authors importing Internal source.

`current`, `update` and `remove` require exactly one matching FactId; `append`
rejects an existing ID. Errors locate the collection and fact using the generated
handle. `update` gives the action the payload, preserving its ID and list position;
missing or ambiguous IDs fail before invoking that action. `current` leaves state
unchanged. Standard `get`, `gets`, `put` and `modify` work on the focused state.

The SDK owns a small standard van Laarhoven optics surface (`lens`, `view`, `set`,
`over`, composition with `(.)`). Authors can write nested field lenses; only
collection handles are generated. Pure set/over can change types; state zoom
preserves its focused type. Full microlens requires MicroHs-unsupported machinery
not needed for these operations. The small optics implementation and fact-aware
combinators avoid that dependency; StateT/ReaderT use maintained transformers
sources rather than a second custom monad implementation.

The guest `kyyn-sdk` package owns the pure composition implementation and private
observation constructors. Its public `Kyyn.Evolution` module exposes no JSON types.
The private encoding values use the existing JSON library; the guest runtime can
consume them without the SDK depending on runtime transport. Pure binding generation
lives with the host plumbing protocol helpers, outside compiler-specific code.
An SDK output is not yet a host EvolutionReport: execution must check its chain
and derive changes as described below.

Adjacent types must line up, including across a schema change. A failed step
stops composition; `Diagnostic` is the shared value described in
[validation](0011-validation.md). Different endpoint types reject out-of-order
composition at compilation. When metadata changes without changing the Haskell
type, the generated bindings still carry distinct contract identities; the host's
continuity checks reject incorrect ordering. No extra phase type is introduced.

### Pure evolution execution

An evolution is a pure transformation of its supplied knowledge base. It does not
request host or plugin effects. Agents investigate using tools while authoring,
then express the chosen changes, rationale and evidence references in evolution
source. Evaluation and checking do not invoke external models or acquire evidence.
The generated adapter owns the runtime handoff, not an author-written effectful
entry surrounding the transformation.

`StepObservation` is SDK-produced data, not a closure or a second authored wire
format. Generated bindings retain the contract identity and encoded root values
on both sides of each `evolve` boundary, including the recipe data under ADR 0014.
The host decodes those observations and
derives the actual changes while both sides are available. Boundary values use
only Before or After's contract. There is no registry of intermediate schemas
and no introspection of arbitrary helper values inside a step.

The host must check that observations form the evaluated chain from the selected
Before to the returned result; an independently authored list of claimed changed
IDs is not the diff. Compare contract identities and decoded values structurally:
the first observed before must match the selected Before, adjacent endpoints
must match, and the final observed after must match the returned result. Once the
chain enters a distinct After contract it cannot return to Before. An empty
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
type or lifecycle. Verification covers both code-only and schema-changing
evolutions through this same mechanism (ADR 0021).

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

data PreparedEvolution = PreparedEvolution
  { context :: EvolutionContext
  , beforeSource :: SourceRoot
  , afterSource :: SourceRoot
  }

data CapturedEvolution = CapturedEvolution
  { context :: EvolutionContext
  , input :: Root
  , sourceClosure :: [RelativePath]
  , preparedAfter :: SourceRoot
  }
```

Here a workspace is simply the evolution's folder inside the KB, containing its
specifications, transformation source and supporting files. It is not a separate
Git worktree, interactive session or service. Capture fixes those bytes for one
evaluation; it does not introduce an invocation registry or a replay obligation.
One source-only preparation function reads the workspace, opens Before at its
explicit Git revision, checks the copied Before source, then opens the target.
Capture and workspace discovery both call it. Capture subsequently adds the
Before fact input and carries both its closure and the prepared After into
execution. Discovery stops at the source endpoints. These are invocation-local values, not new persisted
candidate/archive fields or a cache. The existing context/file snapshots remain
the durable authority.

Propose a complete target copy, not a patch overlay on the current root:

```text
evolutions/<id>/
  manifest.dhall      Before revision, state, name, explanation
  before/            source schema/imports copied from the selected commit
  target/            complete proposed code/config/example contents of root/
  change/            Evolution.hs and evolution-only helpers/input files
  notes/             review notes, excluded from evaluation inputs
```

Creation copies the base root's code, configuration and examples into `target/`.
Editing that copy proposes their replacement; removing a target file proposes its
deletion. Domain facts and recipes are produced by `evolution`, not edited in a
parallel `target/facts/`, `target/recipes/` tree or `target/recipes.dhall` file. RootStore combines
the returned data with this target code snapshot. This
costs a copy of source/dependencies per workspace; begin there rather than invent
overlay rules, tombstones or dependency-sharing machinery.

`before/` preserves the source definitions for the author and archive, but the
selected Git commit remains authoritative. Capture verifies those definitions
against that commit; rebasing refreshes them. `change/` and `before/` are archived,
not installed into the current root. The manifest's explanation covers the whole
proposal, including source/config/example-only changes with no fact history entry.
Its explanation and Before selection are captured; lifecycle state and separate
review notes are not evaluation inputs. Changing a note does not change a candidate.

The manifest is a hermetic Dhall value with this shape:

```dhall
{ before : { revision : Text }
, name : Text
, explanation : Text
, state : < Draft | Ready | Accepted >
, kind : < AdHoc | RecipeBased : Text >
}
```

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
notes trees with their directory prefixes stripped. The root-level `result.dhall`
is reserved for the host-produced archive record. Projection accepts but excludes
it from the snapshot and captured-input comparison, without parsing it; its presence
does not establish acceptance. Re-encoding a WorkspaceSnapshot does not emit it;
archive export supplies the fixed record separately. `result.dhall` is a file,
not another captured subtree. Projection rejects other files
outside the layout, any `target/facts` or `target/recipes` tree and `target/recipes.dhall`. Incomplete draft source is
capturable; projection does not promise that it compiles or matches the selected
commit. Evolution capture performs that source-selection check separately.
Input equality compares the parsed Before revision, name and explanation, and
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

change :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
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
archives and Git. See the [authoring guide](../../docs/guide.md#create-check-and-accept-an-evolution).

Workspace material contains the projected target bytes, not a stored compiler
adapter or independently selected schema descriptor. `ReadWorkspace` can capture
and inspect those bytes without compiling them, including unfinished proposals.
`CaptureEvolution` then prepares both source endpoints through RootOpening:
the manifest selects schema/metadata exports, and inspection derives their checked
contracts from captured modules plus installed SDK sources. A malformed or
unsupported target schema returns diagnostics before evaluation. A successfully
captured evolution retains the prepared After, so execution does not inspect it again.
Raw workspace review remains available when this preparation fails (ADR 0023).
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
its result is checked. Evidence retention belongs to [ADR 0014](0014-evidence.md),
not candidate or archive lifetime; the archive need not duplicate evidence bytes.
No registry of approved snapshots is introduced.

Workspace operations return entities rather than printing, and listing remains
independent of root compilation:

```haskell
data EvolutionStore :: Effect where
  ReadEvolutionSummary
    :: EvolutionWorkspace -> GitRevision -> EvolutionStore m (Either [Diagnostic] EvolutionSummary)
  ReadArchivedReport
    :: EvolutionWorkspace -> GitRevision -> EvolutionStore m (Either [Diagnostic] (Maybe EvolutionReport))
  ListEvolutions
    :: KnowledgeBase -> EvolutionFilter -> EvolutionStore m (Either [Diagnostic] [EvolutionSummary])
  ResolveEvolution
    :: KnowledgeBase -> EvolutionId -> EvolutionStore m (Either [Diagnostic] EvolutionWorkspace)
  ReadWorkspace
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] WorkspaceSnapshot)
  SaveCandidate
    :: Candidate Root -> EvolutionStore m ()
  LoadCandidate
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] (Maybe (Candidate Root)))
  ReadEvolutionState
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] EvolutionState)
  MarkReady
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] ())
  MarkDraft
    :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] ())
  MatchesCapturedInputs
    :: EvolutionContext -> EvolutionStore m (Either [Diagnostic] Bool)
  ExportAcceptedWorkspace
    :: Candidate (Validated Root)
    -> EvolutionStore m (Either [Diagnostic] (TreePath, FileTree))

runEvolutionStore
  :: (RootStore :> es, WorkspaceStore :> es,
      FileSystem :> es, Git :> es, DhallHandling :> es, Failure :> es)
  => Eff (EvolutionStore : es) a -> Eff es a

data EvolutionAuthoring :: Effect where
  CreateEvolution
    :: KnowledgeBase -> EvolutionName -> GitRevision
    -> EvolutionAuthoring m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution
    :: EvolutionWorkspace -> EvolutionAuthoring m (Either [Diagnostic] CapturedEvolution)

runEvolutionAuthoring
  :: (EvolutionStore :> es, RootOpening :> es,
      WorkspaceStore :> es, FileSystem :> es, DhallHandling :> es)
  => Eff (EvolutionAuthoring : es) a -> Eff es a
```

These are selected constructors; review-note persistence is defined in
[interaction](0023-interaction.md). Creation and capture belong to EvolutionAuthoring
because they need source inspection; EvolutionStore's metadata, candidate and archive
operations remain installable without RootOpening, the compiler or SDK.
Inspection receives a resolved revision explicitly. `ReadEvolutionSummary` uses
the same `summaryAt` derivation as listing, at that revision. `ReadArchivedReport`
reads `result.dhall` from Git at that revision, requires acceptance confirmed by
the same history lookup as `FindAcceptance`, then decodes the report and checks
the workspace identity. A report file without confirmed acceptance returns
`evolution.unverified-report`; hand-committing a result or reverting only its
manifest cannot make a report outrank the history rule.
The effectful capability helper `inspectEvolution` combines them for an accepted
workspace, or reads the saved candidate's report for an unaccepted workspace.
It returns `(EvolutionSummary, Maybe EvolutionReport)` rather than printing or
executing code. Accepted inspection needs neither a candidate cache nor a valid
live manifest. Missing reports are distinguishable from malformed reports;
unsupported durable encodings return diagnostics rather than being rerun.
`ReadWorkspace` captures and decodes the local workspace without interpreting its
Haskell; capture delegates this read to the store before checking the Before copy.
RootOpening supplies the source commit's derived contract
through `LoadSourceAt` (ADR 0006); RootStore remains Dhall-only. WorkspaceStore
decodes workspace manifests through DhallHandling; it does not execute proposed
Haskell. Listing needs no compiler frontend,
and reading workspace bytes does not compile them. Creation derives the source
schema; capture prepares both Before and After through RootOpening, including pure
metadata evaluation under ADR 0005. Capture then adds Before's fact material
without semantic validation or executing a transformation. Operation-specific composition installs
the semantic handlers needed by the command.
Do not use partial handlers that fail on the store's other operations.

EvolutionStore's handler dependencies are listed above; Git supplies its
FindAcceptance lookup from ADR 0012. EvolutionAuthoring adds the source-opening
dependencies for capture. Capture reads the workspace at the derived location,
decodes its manifest, and calls `LoadSourceAt` for that manifest's Before revision
and the owning KB's root subtree. The projected `before/` tree must equal that
source root's entire authored `src/` tree (prefix stripped) exactly, including
helper additions, deletions and byte edits. A mismatch returns a diagnostic asking
the author to refresh the copy; it does not choose edited definitions over Git.
The resulting Before contract comes from the selected source root, never the
target or copied modules. The captured context and files are immutable values;
this operation does not save them to local storage.

Live `MatchesCapturedInputs` reads and decodes the current workspace and applies
the pure comparison above. It does not load the source root or require its compiler
to run. A valid changed workspace returns `Right False`; malformed workspace
contents return diagnostics, and storage/compiler/Git infrastructure errors remain
operational Failure. Neither operation confers readiness or acceptance.

Each `EvolutionSummary` includes its stable `EvolutionId`, human name and state.
Names may repeat; IDs do not. Commands use the ID returned by creation/listing,
and `ResolveEvolution` reports an unknown ID without creating a workspace.
An ID is one safe directory component: lowercase ASCII letters, digits and hyphens,
starting with a letter or digit. Creation generates `000001-add-review-status`:
a six-digit local sequence followed by a slug of the supplied name. Lowercase the
name, replace runs outside ASCII letters/digits with a hyphen, and trim separators.
A name that produces no slug is refused; the display name otherwise stays exactly
as supplied. The ID stays fixed when the display name changes. They are within the
storage filename pass-through alphabet and need no escaping. The workspace's location is
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

The lifecycle operations return diagnostics for unknown or malformed
workspaces. Their summaries and filter are ordinary data:

```haskell
data EvolutionSummary = EvolutionSummary
  { workspace :: EvolutionWorkspace
  , name :: EvolutionName
  , state :: EvolutionState
  , acceptingCommit :: Maybe GitRevision
  }

data EvolutionFilter = AllEvolutions | ExcludeDrafts
```

Listing enumerates immediate names under the live and selected Git `evolutions/`
directories, considers valid evolution IDs, then derives each summary once.
Git's `ReadDirectoryAt Repository GitRevision TreePath` returns
`Either [Diagnostic] (Maybe [RelativePath])`: immediate entry names, `Nothing`
for an absent directory, and diagnostics for an invalid revision or non-directory
selection. It never reads child blobs. The filesystem counterpart is defined in
[effects](0003-effects.md).
It sorts by ID and applies ExcludeDrafts as a pure filter over those same summaries.
It reads manifests, not source/evidence/candidate files, and does not compile even
unfinished drafts. Malformed manifests/history are diagnostics rather than silently
omitted workspaces. The filter is not a way to suppress malformed metadata.
The history lookup cost in ADR 0012 is incurred per selected evolution; no listing
index or cache is introduced.

For each summary, committed acceptance is checked before reading the local manifest.
Its name and accepting revision come from the selected Git history, so a missing or
malformed local manifest cannot hide acceptance. Without committed acceptance, a
local manifest is required: absent unaccepted drafts are not resurrected from Git.
A local Accepted label without authoritative acceptance returns an
`evolution.unverified-acceptance` diagnostic, not Accepted or an implicit downgrade.
Resolve uses this same existence/state derivation and never creates a workspace.

MarkReady and MarkDraft pin HEAD once, refuse already-accepted and unknown workspaces,
then atomically replace only the local manifest. They preserve Before, name,
explanation; source, target, changes and notes are
untouched. Manifest formatting may normalize through Dhall. Neither transition
compiles, evaluates, validates or commits anything, and matchesCapturedInputs remains
true across the transition. An explicit transition can correct an unverified local
Accepted label when Git confirms no acceptance. Storage failures remain Failure.

The target code is a pure projection of the captured WorkspaceSnapshot; it needs
no store effect. `SaveCandidate` persists
the materialized root, context and derived report so another process can load them;
it does not advance Git or persist a `Validated` marker. The root/context must
refer to fixed stored bytes, not source files that will change when editing resumes.
`LoadCandidate` returns `Right (Just candidate)` for the workspace's latest saved result,
or `Right Nothing` only when its latest pointer is absent. An unrecognised
candidate layout, missing record metadata, or readable contracts that no longer
reconstruct their fingerprints return `candidate.stale`, asking the author to
check the evolution again. Actual read failures and corrupt content inside a
recognised layout remain operational Failure, not `Nothing` or an implicit
request to rerun the evolution. Loading does not compile source or execute the guest.
[Checking](0011-validation.md) earns validation
again after loading. Deleted local results can be regenerated by explicit evaluation.

Use ignored local storage for captures and candidates. A save publishes a complete
result before making it the workspace's latest result; never expose a partial save.
Replacing that selection does not change previously loaded snapshot values.
One simple implementation uses private directories and a latest-result
pointer, not an attempt history, approved-candidate registry or public content store.
Store-local locations are not committed as portable identities in the archive.

The implementation writes a fresh `.kyyn/candidates/<id>/` containing `capture/`,
the materialized `root/` and host-owned `candidate.dhall` metadata/report. Fact
files remain Dhall. The shared record format described below holds the complete
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
power-loss durability. Saving a candidate creates `.kyyn/.gitignore` containing
`*` when it is absent, preserving any existing rule. No template or change to the
user's top-level ignore rules is required. Reads do not write ignore files. These files
stay outside root and evolution exports.

`MatchesCapturedInputs` compares the workspace's current evaluation inputs with its
capture. `ExportAcceptedWorkspace` serializes the captured source/specifications,
with the KB-relative `evolutions/<id>` prefix defined by this store,
fixed report and Accepted state for the proposed commit; it does not mark the live
workspace accepted or move a ref. It also preserves the selected workspace's
review notes, retaining their original subjects; those notes are read separately
from captured evaluation inputs, not silently dropped when replacing the archive.
Publication calls this operation only for a checked candidate. It can therefore
fail before publication without changing the workspace lifecycle.

The export returns the `Subtree` prefix and FileTree pair consumed by
GitTree. It admits a Candidate (Validated Root), checks that the captured target
code and Before revision agree, then emits an Accepted manifest from the captured
manifest values, exact before/target/change bytes, and the fixed report. The only
archive component read from the live workspace is `notes/`: its current bytes,
including additions and deletions, replace the captured notes tree. Absent notes
mean an empty notes tree. Notes retain their stored subjects unchanged. No other
live manifest, source, target, report or candidate file supplies export content.
Export itself does not check readiness, reread HEAD, compile, evaluate, validate,
write files or advance Git; publication owns its separate checks and writes.

`result.dhall` stores the evolution ID, Before/After contract descriptions and fixed
report using the same host-owned EvolutionRecord codec as private candidate storage.
Both records are self-contained Dhall. A fixed header contains the format version,
identity and endpoint contract descriptions. Each description holds metadata,
the whole-contract fingerprint and an ordered table of type declarations. Child
indices reference only earlier declarations, with the root type last; decoding
reconstructs and checks the contract and its fingerprint. This represents the
finite Haskell schema without introducing recursive Dhall types.

The reader projects and decodes that header through DhallHandling, derives the
report's structural shape from the restored contracts, then decodes the complete
document with the same shape-directed capability. There is no compiler call,
shape-free value decoder or JSON persistence path. Steps form an ordered list;
changes are grouped by collection and fact sides are optional `Before`/`After`
unions containing typed fact values. Rationale and evidence remain ordinary
records and lists. Candidate reload and archived inspection return the same domain
report types they received at save time.

New records use version 5, including the recipe constructors in
[evidence](0014-evidence.md) and the host-derived plugin package comparison
described in [plugins](0015-plugins.md). Versions 1–4 remain readable: old recipe
payloads read as OpenAgent, absent plugin summaries are empty, and versions 1–2
have no recipe changes. Reading an
older archive does not reconstruct a missing summary from current source.

Once committed, this record is durable history, not a disposable cache:
future readers must either support an older version or return an unsupported-record
version diagnostic, never classify a recognised unsupported version as corruption
or require recompiling/reapplying archived modules. Generic contract/record decode
diagnostics do not suggest replay; only LoadCandidate converts incompatibility into
`candidate.stale` with reapplication guidance. There is no version migration
framework in this implementation.

Recipe-based archive records retain the selected recipe identity and state changes,
with before/after contracts and values. Historical curation declarations may be
read as legacy report data, but do not authorize any current progress update.
Use the archive version policy above when extending the representation.

The replacement is confined to the owning KB's `evolutions/<id>/`. It includes no
materialized root facts, absolute candidate-store paths, validation marker or
`.kyyn/` contents. RootStore independently exports the same Validated Root's files;
publication combines those two replacements into one GitTree.

Creation selects an ad hoc or recipe-based scaffold from EvolutionKind. It loads source at the selected revision, copies
its entire authored `src/` tree to `before/`, copies all non-fact root files to
`target/`, and writes a Draft manifest with the supplied human name, Before revision
and an initially empty explanation. Examples and configuration are copied too;
their suitability after editing is checked with the candidate, not guessed during
creation. The author edits `target/` for either same-schema or schema-changing work;
there is no separate schema-request mode or stale creation-time After descriptor.

Source inspection and workspace encoding finish before directory allocation.
Creation lists the live `evolutions/` directory, finds the maximum prefix consisting
of exactly six digits followed by a hyphen, and adds one. Accepted workspaces still
present count; deleted history is not scanned. No counter file, timestamp or random
suffix is needed. Refuse at 999999 instead of wrapping or changing the width.
The named directory is created exclusively through FileSystem. An existing entry
returns an ordinary creation refusal without retrying or overwriting its contents.
Other filesystem failures remain operational. The store then writes the encoded
files and returns its KB-scoped handle. Independent checkouts can allocate the
same number with different slugs; the whole ID distinguishes them. An identical
name is an ordinary conflict to resolve, not a distributed coordination problem.
Creation order is local; Git owns acceptance order. Names can repeat and never
directly choose filesystem paths. Write failure returns an
operational Failure, not a successful workspace; an unfinished directory can remain
for inspection/removal. Creation does not update Git and does not promise atomic
multi-file persistence under crashes.

Creation writes a real identity entry at `change/Evolution.hs`, with module name
`Evolution` and binding `evolution`. The signature names the selected schema with
qualified Before/After aliases; creation initially copies the same schema to both:

```haskell
import Kyyn.Workspace.Evolution
import qualified RootV1 as Before
import qualified RootV1 as After

evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = identityEvolution
```

Authors update the After import when changing its schema. Identity then fails to
type-check until the author supplies the transformation. The generated workspace
module is derived during preparation, not a second authored schema or codec.
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
  , value  :: KnowledgeBase CheckedValue
  , report :: EvolutionReport
  }

runEvolutionExecution
  :: (RootStore :> es, GuestCompilation :> es, GuestExecution :> es,
      DhallHandling :> es, Failure :> es)
  => FileTree -- installed SDK/runtime sources
  -> Eff (EvolutionExecution : es) a -> Eff es a

applyEvolution
  :: (RootStore :> es, EvolutionStore :> es, EvolutionExecution :> es)
  => CapturedEvolution
  -> Eff es (Either PreviewRejection (Candidate Root))

data PreviewRejection
  = ProposedCodeRejected [Diagnostic]
  | EvolutionRejected EvolutionFailure
```

EvolutionExecution owns source/adapter preparation, entry/schema compilation and
execution of the compiled transformation.
It delegates compilation to [GuestCompilation](0002-runtime.md), not a locally
assembled MicroHs command. GuestExecution invokes the compiled pure entry;
native process lifetime and protocol remain below that plumbing boundary.
The row is a lowering contract, not IO in porcelain. RootExecution in ADR 0011
retains validation and snapshot queries without acquiring plugin/acquisition
handlers merely to check a root. Source, dependency and config bytes are fixed
by capture; providers are not contacted during compilation.

EvolutionExecution consumes the input Root and dependency closure supplied by
capture, rather than loading or inspecting Before again. A Root alone does not
establish its origin: the capture operation derives it from the selected immutable
Git subtree. Execution checks its contract and source against the context, then
decodes its facts. It consumes the prepared After without another schema inspection,
checking that its code matches the captured target. Accept-time freshness checks
still inspect current workspace sources when comparing a saved candidate.
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

Independent target validators and queries compile in `PrepareRoot` during
candidate checking, after materialization, not through an additional pre-evaluation
gate. An evolution may therefore evaluate successfully and its candidate then fail
because a target validator does not compile. Evaluation answers whether the change
runs; candidate checking answers whether its result is acceptable. Both outcomes
remain visible on the same proposal. Do not construct an empty-facts Root merely
to invoke code checking earlier.

After materialization, `applyEvolution` saves the proposed root including recipe
state through `SaveCandidate` before returning
`Right candidate`. Subsequent semantic/example rejection leaves that unchecked
result available for inspection; compilation or transformation rejection creates
no replacement candidate. An earlier saved candidate is not a successful outcome
of a later failed evaluation. Publication still requires unchanged captured inputs
and fresh checking of the explicitly loaded result.

Porcelain also owns the workspace-level application operations:

```haskell
evaluateWorkspace
  :: (EvolutionAuthoring :> es, EvolutionExecution :> es,
      EvolutionStore :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es (Either PreviewRejection (Candidate Root))

checkEvolution
  :: (EvolutionAuthoring :> es, EvolutionExecution :> es,
      EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => EvolutionWorkspace
  -> Eff es (Either PreviewRejection (CheckResult (Candidate (Validated Root))))

checkSavedCandidate
  :: (EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es (CheckResult (Candidate (Validated Root)))
```

`checkEvolution` is the author-facing workflow: capture and evaluate current
workspace contents, materialize/save the candidate, then validate it. The helper
`evaluateWorkspace` retains that first portion as an internal composition step.
`checkSavedCandidate` loads and checks the saved result without reopening or
executing the evolution; acceptance uses this operation, and a missing candidate
is a diagnostic refusal. CLI, MCP and Web reuse these operations rather than
maintaining their own workflow implementations. ADR 0018 defines the observable
outcomes and the single public check command.

Each evolution workspace provides one conventional guest binding, `evolution`.
Choose a reusable function and bind its arguments in ordinary source:

```haskell
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = importSales September
```

`importSales` illustrates a reusable parameterized helper over supplied data; the
workspace entry has already bound its
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

Investigation precedes this pure entry, as specified under
[pure evolution execution](#pure-evolution-execution).
[ADR 0028](0028-agentic-workflows.md) proposes an explicit recipe flow that freezes
its result into an ordinary workspace before checking. It does not add model or
acquisition calls to evolution evaluation.

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
data EvolutionReport = EvolutionReport EvolutionKind [StepReport]

data StepReport = StepReport
  { rationale :: Rationale
  , changes   :: [Change]
  }

data Change = FactChange
  { collection :: CollectionId
  , fact       :: FactId
  , before     :: Maybe RecordedFact
  , after      :: Maybe RecordedFact
  }
  | RecipeChange RecipeId (Maybe StoredRecipe) (Maybe StoredRecipe)

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
  => RootContract -> KnowledgeBase Value  -- selected Before and its decoded value
  -> RootContract           -- inspected target
  -> EvolutionObservation   -- decoded guest After value and step observations
  -> Eff es (Either [Diagnostic] (KnowledgeBase CheckedValue, EvolutionReport))
```

This capability function checks every annotated boundary value through
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

data EvolutionFilter = AllEvolutions | ExcludeDrafts
```

`AllEvolutions` includes drafts, ready work and accepted archaeology;
`ExcludeDrafts` includes Ready and Accepted entries. This filter is data passed to the store, not a second
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

The SDK and generated-binding conformance test runs the same source under GHC
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
handler evaluates a Before edit, schema migration and After edit, retaining
the captured context; the test materializes and reopens exactly the checked After.
Changed unrelated Before validators/metadata modules do not enter the compilation.
Native recording-handler tests cover preparation/compilation errors, guest refusal,
runtime/protocol failure, closure collisions and rejection of unknown contracts.

The execution adapter lifts pure Evolution evaluation into
`Program NoRequests` for the runtime; no plugin handlers are installed.
Successful execution returns `EvaluatedEvolution`, which `applyEvolution`
materializes and saves before returning a Candidate.
