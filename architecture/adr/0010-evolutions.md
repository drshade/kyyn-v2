---
id: 0010
title: 'Target-owned evolutions over stored snapshots'
---
# Target-owned evolutions over stored snapshots

## Context

Facts, schema, recipe state and executable meaning change together. A migration
must be able to repair readable data even when the old application cannot compile
under the target compiler or dependencies. Requiring old recipe implementations
merely to recover their saved-state types couples migration to obsolete code.

## Decision

### One target application

An evolution compiles the complete target application and its migration helpers
under the target `flake.nix` and `flake.lock`. It does not compile the accepted
application, import its schema, discover its old flow signatures or rebuild its
old dependencies. Before means an immutable Git revision and its stored data;
it is not a guest Root type or an independently reconstructed historical contract.

The accepted data is read from that revision, never from ambient working-tree
fact files. The host supplies a structurally checked snapshot at runtime. Facts,
recipe state, evidence and secrets do not become Nix compilation inputs. The
target schema, codecs, generated handles and entry adapters remain compiler-owned
under ADRs 0002 and 0005.

Live module names describe their responsibilities, for example `Training.Schema`.
There is no requirement to rename a live module when its definition changes, and
no Before/After source namespace or versioned-schema coexistence rule. Optional
old-shaped input declarations live in `change/Input/`; they compile as current
migration helpers, not as a copy of the old application. Ordinary module-name
uniqueness still applies within the target-plus-helper build.

### Stored snapshot and decoding views

The host reads the storage layout owned by ADR 0006:

- residual root fields from `facts/root.dhall`;
- collections keyed by stored logical name, with membership indexes and full
  identified fact documents;
- recipe definitions and their always-present state documents.

It checks hermetic Dhall syntax/types, supported storage shapes, unique IDs,
index membership, file/envelope agreement, recipe-definition structure and state
presence. Missing listed files, unlisted fact files, duplicate IDs and malformed
data are diagnostics. An empty index is an existing empty collection, not a
missing collection. These checks need no old Root metadata, flow or validator.
They do not establish the old application's business validity.

A stored document has its own inferred structural type and exact value. It does
not carry an authoritative historical Haskell contract. In particular, textual
storage cannot recover whether a field originally meant Text, Day or a custom
newtype. Migration input types are author-selected decoding views, labelled as
such in discovery and reports. They must strictly decode the documents to which
they are applied: unknown fields and storage-shape mismatches are errors, not
projection or defaulting opportunities. Ordinary target scalar codecs apply when
selected. There is no extra decode/re-encode equality gate and no assertion that
an input type reproduces an old nominal contract.

Open recipe definitions declare their state type; closed recipe definitions identify
the flow from which the current build derives the state type. Recipe state decodes
against that current type.

All retained fields, facts and recipe states must eventually decode under the
complete target application and pass its normal validation. Untouched data does
not bypass that check. Semantic repairs may start from structurally readable but
business-invalid data; there is no prerequisite run of the old validator.

### Preparation followed by typed edits

The public guest entry has only the target root type parameter. Both phases are
pure, fallible SDK computations. Preparation works on stored data; typed edits
work on the resulting target value. A preparation cannot be inserted after typed
editing has begun.

```haskell
data Rationale = Rationale
  { explanation :: Text, evidence :: [EvidenceRef] }
data EvolutionFailure = EvolutionFailure [Diagnostic]

data Preparation root a       -- pure Monad over the working stored snapshot
-- Constructors and raw document mutation are not public.
data TargetEdits root         -- ordered Semigroup/Monoid of typed edit steps
data Evolution root          -- one preparation followed by target edits

prepare :: Preparation root () -> TargetEdits root -> Evolution root
edit :: Rationale -> Edit (KnowledgeBase root) () -> TargetEdits root
identityEvolution :: Evolution root
-- identityEvolution = prepare (pure ()) mempty

type Edit root = StateT root (Either EvolutionFailure)
```

`Preparation` has ordinary `do` sequencing and failure propagation. Each mutation
below supplies its own rationale. Reads do not fabricate change observations.
`TargetEdits` composition uses `(<>)`, retaining step order and rationale; `mempty`
is an empty sequence. The generated `Kyyn.Workspace.Evolution` facade specializes
these operations to the target Root and supplies private encoding bindings.
Authors do not construct host values, encode Dhall or write protocol wrappers.

For example, an input module declares the old persisted Person fields while the
live schema keeps its existing module name:

```haskell
import Kyyn.Workspace.Evolution
import Training.Schema (Root)
import Kyyn.Schema (Fact)
import qualified Input.Person as Input
import qualified Training.Schema as Target
import qualified Kyyn.Workspace.Target as Collections

evolution :: Evolution Root
evolution = prepare
  (migrateCollection (Rationale "Split stored names into their new fields" [])
    "people" Collections.people
    (\old -> traverse convertPerson old))
  mempty

convertPerson :: Fact Input.Person -> Either EvolutionFailure (Fact Target.Person)
-- Authored conversion preserves each FactId and supplies the target payload.
```

A same-shape or code-only change uses `prepare (pure ()) ...`; ordinary corrections
use `edit` and the existing collection operations. Source/dependency changes still
re-decode every retained value and run target validation, even with no fact diff.

### Collection preparation

Output handles are generated from the target Root and its collection metadata.
They use the same logical-name/field/type association as ordinary typed edits.
Source names refer to the working stored snapshot, not old Haskell field names.

```haskell
readCollection
  :: Contract input => Text -> Preparation root [Fact input]

migrateCollection
  :: (Contract input, Contract output)
  => Rationale -> Text -> Collection (KnowledgeBase root) output
  -> ([Fact input] -> Either EvolutionFailure [Fact output])
  -> Preparation root ()

renameCollection
  :: Rationale -> Text -> Collection (KnowledgeBase root) output
  -> Preparation root ()

removeCollection :: Rationale -> Text -> Preparation root ()
removeFact :: Rationale -> Text -> FactId -> Preparation root ()
```

Reads and migration decode every member with the selected input type and preserve
membership order. Reads see preceding preparation operations, not a mutable live
KB. A missing source is an error. For an empty collection no payload type can be
established from a fact, but the typed conversion still compiles and empty input
is valid.

`migrateCollection` replaces the selected collection with its encoded output. In
the initial API its output must contain exactly the input ID set, with no duplicate
IDs; order may change. It cannot disguise identity changes as payload edits.
When source and target logical names differ, it also renames the collection; a
pre-existing different destination is an error. `renameCollection` changes only
the collection name, with the same collision rule. Its payloads must subsequently
decode under the target handle's type. `removeCollection` requires an existing
source and explicitly removes its data. `removeFact` explicitly removes one
existing identified source fact before conversion; it refuses a missing ID. This
allows removal of obsolete records without manufacturing target-shaped placeholders.

New target collections with no source after preparation are assembled as empty,
then may be populated by typed edits. A remaining source collection that is not
declared in the target is an error: remove or rename it explicitly. The target's
metadata supplies the mapping from logical collection names to Root fields; no
old mapping is reconstructed.

Fact additions and further removals/splits/merges use ordinary explicit typed edits after
preparation. An ID change is a removal plus an addition in the report. There is
no ID-remapping operation, automatic reference rewrite or inferred lineage.
Reference semantics belong to the target's declared validation. Do not claim
that every arbitrary FactId field has generic dangling-reference protection.

### Residual root fields

Residual fields are addressed by their stored field names. Target-generated
`Kyyn.Workspace.Target.Fields` handles cover exactly the non-collection Root
fields, using their actual Haskell types. A collection cannot be modified through
a residual-field handle. There is no generated old Root or separate authored
record duplicating the complete residual schema.

```haskell
data TargetField root value  -- generated target field identity and codecs

readField :: Contract input => Text -> Preparation root input
migrateField
  :: (Contract input, Contract output)
  => Rationale -> Text -> TargetField root output
  -> (input -> Either EvolutionFailure output) -> Preparation root ()
putField
  :: Contract output
  => Rationale -> TargetField root output -> output -> Preparation root ()
renameField :: Rationale -> Text -> TargetField root output -> Preparation root ()
removeField :: Rationale -> Text -> Preparation root ()
```

`readField`/`migrateField` strictly decode the entire selected field, including a
nested record/list. Migration may change both its stored name and value; a different
existing destination is an error. Rename preserves the stored value. Remove and
rename require an existing source. `putField` explicitly creates or replaces a
target field and records either addition or replacement; it is not an implicit
default. Missing target residual fields are errors even for Optional or list
fields: supply `Nothing`, `[]` or another value explicitly. Remaining undeclared
source fields must be removed or renamed explicitly. Collections have a defined
zero-member starting point; residual fields carry domain meaning, so even an empty
list or absent Optional requires an explicit choice through `putField`.

Independent field operations allow arbitrary restructuring without reconstructing
old Root metadata: read the needed old fields, write their new target fields,
and explicitly remove the superseded ones. All writes remain typed and observed.

### Recipe preparation

Preparation can replace a definition and transform its state without inspecting
or executing the old flow. Definition handles and target state types come only
from target/helper source. Ordinary typed creation/removal/update after preparation
remain owned by ADR 0014. `migrateRecipe` converts stored input into the target
shape; `updateRecipe` operates target-to-target after that boundary.

```haskell
readRecipeState :: Contract input => RecipeId -> Preparation root input
migrateRecipe
  :: Contract input
  => Rationale -> RecipeId -> RecipeDefinition output
  -> (input -> Either EvolutionFailure output) -> Preparation root ()
retireRecipe :: Rationale -> RecipeId -> Preparation root ()
```

Migration and retirement require an existing recipe and state. Migration strictly
decodes the stored state as `input`, applies the conversion, and installs the
new definition and encoded state together under the same recipe ID. The output
codec is carried by the generated `RecipeDefinition output`. An identity state
conversion can replace only a flow reference or instructions. Retirement removes
the definition and state explicitly and reports both.

Unmentioned definitions and state are preserved. Before typed edits begin, every
remaining definition resolves in the target and its saved state strictly decodes
under that definition's target contract. A preserved obsolete flow reference is
a diagnostic, not a request to compile old code or reset state. A missing or
malformed state is an input error even when an author intended retirement; direct
explicit storage repair remains possible under the architectural principles.

### Typed target editing

After preparation, assemble the target Root using target metadata and decode
all recipe states against target definitions. This is a structural boundary, not
premature business validation; typed edits can repair remaining business errors.
Do not substitute the author-selected input types for this target check.

```haskell
within :: Collection root a -> CollectionEdit a r -> Edit root r
current :: FactId -> CollectionEdit a a
update :: FactId -> Edit a r -> CollectionEdit a ()
remove :: FactId -> CollectionEdit a ()
append :: Fact a -> CollectionEdit a ()
refuse :: [Diagnostic] -> Edit root a
```

`current`, `update` and `remove` require exactly one matching ID. Append refuses
an existing ID. Handles for ad hoc work focus through the facts lens of
`KnowledgeBase root`. Ordinary optics use the maintained lens/generic-lens
libraries; rationale is attached to an edit step, not every field assignment.
Any failed phase returns no candidate or partial successful result. After all
edits, perform full target validation and the existing example/recipe/plugin
checks before a candidate is eligible for acceptance.

### Pure evolution execution

Preparation and edits request no host/plugin/model effects. Investigation remains
separate authoring work. The host supplies an explicit stored snapshot to the
private adapter and receives the resulting target value and observations.

```haskell
data StoredSnapshot -- structurally checked named documents, identities and order
-- Host type: storage structure, not an old Haskell contract or a filesystem handle.
data EvolutionOutput root  -- target KnowledgeBase plus ordered observations

evaluateEvolution
  :: Evolution root -> StoredSnapshot
  -> Either EvolutionFailure (EvolutionOutput root)
```

The generated adapter transports stored structural types/values through the
existing framed protocol. The SDK's snapshot representation is private and has
no filesystem capability. The host materializes/validates the returned target
using the independently inspected target description. Host and guest types remain
separate implementations of that protocol, not linked KB Haskell types.

### Observation and report contract

The SDK records an ordered observation for each preparation mutation and each
typed edit. Each contains its rationale and complete structural data at its
input/output boundary. Read-only helper values have no observation. Canonical
comparison uses inferred storage types, normalized exact values, identities,
collection order and recipe definitions; it ignores Dhall formatting/comments.
It never equates two values merely because their rendered text looks similar.

The host checks the entire chain: first input equals the independently captured
stored snapshot; adjacent boundaries agree; the target-projection boundary equals
the checked result of assembling the target from prepared data; and the final
boundary equals the candidate's encoded material. An empty authored sequence is
valid only when no data change occurred beyond the explicit target projection
rules below. A missing boundary, duplicate identity or inconsistent final value
is a rejection, not a successful candidate with an inferred rationale.

Target projection records a distinct system-labelled observation for newly
introduced empty collections and any data/type representation change caused by
target decoding/encoding. It carries the workspace explanation, not an invented
author claim. Thus default empty collections, canonical scalar normalization and
code-only work cannot create an unobserved gap. It does not infer original scalar
semantics or claim that target metadata is historical metadata.

```haskell
data StepOrigin = Authored | TargetProjection

data StepReport = StepReport
  { origin :: StepOrigin, rationale :: Rationale, changes :: [Change] }
data RecordedValue -- inferred storage shape plus exact value, readable without GHC

data Change
  = FactChange Text FactId (Maybe RecordedValue) (Maybe RecordedValue)
  | MembershipChange Text (Maybe [FactId]) (Maybe [FactId])
  | FieldChange Text (Maybe RecordedValue) (Maybe RecordedValue)
  | RecipeChange RecipeId (Maybe RecordedRecipe) (Maybe RecordedRecipe)
data RecordedRecipe -- method, state storage shape and exact state value

data EvolutionReport = EvolutionReport
  { steps :: [StepReport]
  , targetContract :: RootContract
  }
```

The host derives changes from the observed actual values, never a supplied list
of claimed changed IDs. Record keys are collection name plus FactId. ID or
collection-name changes appear as removals/additions; reordering is a membership
change rather than an invented payload edit. Residual fields and recipe state
have first-class report entries. Two absent or equal values produce no change.
A changed stored type/union alternative set is visible even if the current
constructor/value text happens to be unchanged.

Before records retain storage shape/value, not a fabricated old RootContract.
The target contract is independently inspected and checked; decoded input views
may be labelled by their selected type but never replace the raw baseline. Code,
metadata, lock and configuration changes are shown in the workspace comparison.
Equal stored facts are not all relabelled as per-fact changes merely because the
target Haskell module name changed. Historical semantic metadata cannot be
recovered without old code and is not manufactured for the report.

Reports can retain whole boundary values during checking and before/after values
for each changed record in the archive. Changed values are archived as a union
over that report's inferred shapes; alternative names are local to that report.
No incremental-memory or archive-size
promise is made. Measure these costs rather than adding a history database or
reconstruction service. A report proves data continuity and captures declared
rationale; it does not prove that a rationale or evidence citation is true.

### Host capture, workspace and candidate

```haskell
newtype Before = Before { revision :: GitRevision }
data WorkspaceSnapshot -- base, authored metadata, exact target/change files, kind

data EvolutionContext -- KB/base selection and captured workspace inputs
data PreparedEvolution -- context, immutable stored input, inspected target build
data Candidate result = Candidate
  { context :: EvolutionContext, result :: result, report :: EvolutionReport }

data EvolutionExecution :: Effect where
  EvaluateEvolution
    :: EvolutionWorkspace
    -> EvolutionExecution m (Either [Diagnostic] (Candidate Root))
```

Preparation captures the workspace, reads its base revision's data through the
storage checks above, and inspects the target. It does not read the base as a
validated executable Root. Discovery inspects target schema/generated bindings
without compiling an unfinished `change/Evolution.hs`; it does not evaluate the
evolution, load facts or run validation. The implementation effects stay beneath
the porcelain boundary in ADR 0003.

```text
evolutions/<id>/
  manifest.dhall   base revision, name, explanation, kind and lifecycle state
  target/          complete proposed code/configuration/examples for root/
  change/          Evolution.hs and optional Input/ migration helpers
  notes/           the author's working notes, excluded from evaluation inputs
```

There is no copied `before/` source tree. Creation copies accepted code/configuration
and examples to target, without building the old application. Target is a complete
replacement subtree for code; removing a target file proposes deletion. Fact and
recipe material is produced through the evolution, not through parallel editable
`target/facts`, `target/recipes` or `target/recipes.dhall` overrides. Snapshot data
preservation is not an overlay rule for source publication. Change helpers are
archived, not installed into the accepted root.

A candidate owns one explicit KB/base context, the captured target/change inputs,
the fixed report and the validated target result. It is a snapshot, not a live
worktree or executable closure. Checking, examples and acceptance use this same
result. Evaluation returns `Candidate Root`; normal checking produces
`Candidate (Validated Root)` for ADR 0012. Acceptance does not silently rerun the migration. Capture comparison
includes base, kind, name/explanation and exact evaluation-source paths/bytes;
lifecycle readiness and notes are excluded. Actual edits invalidate the
saved result even if an external editor left the Ready label unchanged.

Domain-view authoring preview under [ADR 0018](0018-surfaces.md#accepted-snapshots-and-live-draft-pages)
is a separate read-only use: it may serve live `target/views/` files before checks
succeed. Its query freshness comparison may ignore those view files while still
requiring every other evaluation input to match the checked candidate. That does
not update, validate or replace the candidate's captured source. Acceptance keeps
the complete comparison above, including view files; a page edit therefore needs
a new check before acceptance even though browser preview needs only a refresh.

### Optional input-type scaffolding

`evolution new --input-types` emits editable decoding declarations under
`change/Input/` from the selected stored snapshot. It is optional assistance,
not required for creation, checking or migration. Normal creation performs no
old code inspection. The scaffold also uses stored structure, never old application
imports, helpers, validators, plugins or custom deriving dependencies.

Inspect all stored members of a collection for a consistent representable shape;
do not guess from the first record. Preserve field names and full union alternatives
with deterministic legal Haskell names and ordinary supported Contract derivation.
Empty lists and None within a document carry type annotations. An empty top-level
collection has no fact payload declaration to recover: report that omission and
use target types or an authored input type. Textual carriers do not claim to
reconstruct old scalar meaning; authors can substitute target types wherever
strict decoding accepts the stored shape, converting only what changed.

Unsupported, heterogeneous or unrepresentable shapes produce precise diagnostics;
no partial invented schema or implicit old build is substituted. A failed flagged
creation publishes no partial workspace; ordinary creation without the flag
remains available. Never overwrite authored helpers on rebase. Regeneration is
explicit and writes only with the author's requested replacement; the base
revision identifies what the scaffold was derived from.

### Ad hoc and recipe-based authoring

```haskell
data EvolutionKind = AdHoc | RecipeBased RecipeId

data RecipeEvolution root state
data RecipeEdit root state a
recipeEdit :: Rationale -> RecipeEdit root state () -> RecipeEvolution root state
editFacts :: Edit root a -> RecipeEdit root state a
getRecipeState :: RecipeEdit root state state
putRecipeState :: state -> RecipeEdit root state ()
modifyRecipeState :: (state -> state) -> RecipeEdit root state ()
instance Semigroup (RecipeEvolution root state)
instance Monoid (RecipeEvolution root state)
```

Like `TargetEdits`, `RecipeEvolution` composes ordered steps with `(<>)` and uses
`mempty` for an empty sequence, preserving each step's rationale.

Ad hoc work can migrate data, change source/configuration and create/update/remove
recipes. Recipe-based work selects one existing recipe and preserves domain schema,
source/configuration and all recipe definitions/state types. It changes domain
facts and that recipe's state, preserving all other state. These are checked
artifact constraints, not a conclusion from equal Haskell types alone.

For recipe runs the selected current application is intentionally compiled and
executed under ADR 0028; this is not compilation of an obsolete application for
migration. The selected current state is decoded normally. Open-agent and closed
recipes both use one recipe-based workspace per run, the same report checks and
the same conditional acceptance. Frozen proposals are pure checked input; checking
or acceptance never repeats model/provider effects. A schema or state-type change
requires ad hoc preparation rather than a special recipe-run migration path.

## Updating the base before acceptance

A rebase selects a new immutable revision, reloads its stored data and invalidates
the candidate. It does not regenerate or overwrite migration helpers, synthesize
new defaults or silently merge target source. Authors reconcile target/change code
and rerun checks. Acceptance never replaces the checked base with newer data.
Two independently checked evolutions cannot both publish against the same old
head after one advances it; ADR 0012 owns the conditional publication.

## Composition and lifecycle

Persist only Draft, Ready and Accepted. Ready expresses intent to submit, not
successful validation. Checking/evaluation alone never accepts. Acceptance requires
Ready, a valid saved candidate, matching captured inputs and the expected current
head. Notes and readiness changes do not invalidate unchanged evaluation inputs;
source/base/configuration changes do. Accepted work is immutable history; new
work uses a new workspace. There is no watcher, approval token, scheduler or
persisted Stale state.

## Declared rationale and record history

Rationale and evidence references are author declarations attached to actual
steps. Repeated changes to one record retain each step even if the final changes
cancel. No-op rationales remain visible without inventing changed facts. The
host archives the fixed report, captured target/change source and base selection
atomically with the new root under ADR 0012. Reports are readable without running
historical guest code. The host decodes the Dhall record against its current
record type and reports a located decode error if it cannot be read; no requirement
archives failed or abandoned attempts.

Record history uses Git revisions and `(collection name, FactId)` to find accepted
report entries. Identity changes have no inferred lineage. Direct Git edits may
lack a rationale; show that honestly rather than borrowing a neighbouring report.
Conflict-resolution changes are not attributed to an ancestor's rationale.
Unavailable evidence remains a visible unavailable reference, not a reason to
retain evidence forever or reject already accepted knowledge.

## Alternatives and verification

Reject compiling old recipes to discover state types, copying old application
source as a migration prerequisite, a historical-contract registry and a parallel
raw-filesystem editing API. Migration input records are normal editable source;
they are not permanent compatibility readers in the accepted application.

Verify a populated schema migration with an uncompilable old application and a
closed recipe whose state changes. It must complete in one evolution, retain
stable live module names and preserve identities/state except explicit changes.
Cover unchanged shapes, lock-only changes, empty/new collections, explicit
collection removal/rename, residual field splitting/merging/removal, target scalar
substitution, missing/extra fields, inconsistent collection shapes, missing states,
duplicate IDs, destination collisions and ID-set changes in migration helpers.
Verify every retained item is checked under target contracts and validation.

Check report continuity for preparation, target projection and typed edits;
include additions of empty collections, membership reorder, schema-only edits,
recipe retirement, missing observations and a forged final value. Exercise normal
recipe-based runs, frozen proposal rechecking, stale-base refusal and acceptance
failure/cancellation under ADR 0012. Optional scaffolding must work without old
Haskell, preserve nested empty/None type annotations, diagnose absent payload
types and never overwrite authored work implicitly. Reopening accepted results
must not require the migration helpers or historical executable to run.
