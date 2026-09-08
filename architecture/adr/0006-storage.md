---
id: 0006
title: 'Materialized facts and runtime data loading'
status: proposed
date: 2026-09-07
---
# Materialized facts and runtime data loading

Basis: Dhall fact storage and materialized current facts are owner-selected.
The file layout, snapshot representation and store signatures specify proposed
implementation mechanics, not a renewed choice of storage format.

## Context

The prototype's generated fact literals couple data volume to compilation.
That is not required by pure validation or typed transformations. Normal reads
also must not execute the history of every past mutation.

## Decision

Keep one current materialized fact tree, readable without replay. Use
data-only Dhall files per identified fact, parsed and structurally checked by
the host's library. Encoding and normalizing fact files is host plumbing. Guest
functions receive decoded typed values through ADR 0007, never Dhall source.
Workspace manifests use Dhall as well. DhallHandling supplies the real host
library for these files and ADR 0016's plugin configuration; it is not a guest
parser or another schema authority. The runtime wire remains a separate decision.

DhallHandling is shape-directed: its decode operation takes a `Shape` and text,
returning a structurally checked value; its encode operation takes a `Shape` and
runtime wire value, returning self-contained Dhall text. The library adapter lives
in `kyyn-plumbing-interpreters`; its API exposes no Dhall types or dependency.
It performs no file reads or import resolution. Local, environment and remote
imports in fact contents are rejected before normalization. Exact integers become
canonical decimal strings on the wire; optionals and unions use tagged values.
Encoding uses the library AST and pretty-printer, not concatenated source.
Semantic values round-trip; authored formatting and comments do not.

Malformed inputs return diagnostics. Unexpected conversion failure after successful
type checking is `dhall.internal-conversion`; an ill-typed generated expression is
`dhall.internal-encoding`. These indicate kernel defects, not invalid authored
data. The format adapter knows shapes, not collection layout or whole-contract
identity. RootStore supplies shapes from the selected contract and kernel-owned
storage structures such as the membership list.

The initial RootStore implements checking runtime values, materialization into
immutable file trees, and reopening those trees. It tags a checked value with the
whole contract identity and compares that identity before materialization. A
role-only contract change therefore rejects an old checked value. Materialization
does not confer semantic validation, execute guest code or write files. Its
porcelain interpreter requires only DhallHandling, with no IOE. Code and supporting
files are preserved verbatim in a separate tree; code paths cannot overlap `facts/`.

Fact-tree paths are relative to `root/`. Reserved file `facts/root.dhall` retains
non-collection root fields (an empty record when there are none). Each collection
uses `facts/<collection>/index.dhall` plus `<id>.dhall` files. Nonempty names made
only of lowercase ASCII letters, digits, hyphens and underscores pass through,
except `index` and Windows device names. Every other name is encoded as `~` followed
by its complete lowercase UTF-8 hex. The escape prefix cannot occur in a pass-through
name, and uppercase is escaped to avoid case-folding collisions. This keeps common
paths such as `facts/todos/todo-001.dhall` readable without interpreting arbitrary
IDs as paths. Original IDs remain in the envelopes and membership files. Membership
preserves the guest list order; no unordered-collection metadata is implemented.
RootStore rejects duplicate IDs, missing/unlisted files, malformed UTF-8 and
path/envelope mismatches. File trees reject duplicate paths and file/directory
collisions, and canonicalize entry order. RootOpening handles manifest-driven
schema inspection from a captured tree or Git revision. Supporting configuration
validation and publication of a complete root remain unimplemented.

Dhall's structural checks do not establish domain validity: exact decimal,
date and money conventions still need their semantic checks. Storage contracts
are generated from the checked Haskell declarations under ADR 0005.
Dhall is the chosen implementation path, not a conditional default requiring
parallel JSON support. Revisit it only if concrete authoring, compatibility or
performance evidence makes a case against it. Measure parsing/normalization costs
in the existing representative tests; hypothetical concerns do not keep the
decision permanently open or justify a storage-backend abstraction in advance.

Collection routing belongs to the root contract/store, not business names in
the kernel. Stable `FactId`s address values, not list positions or display names.
An ordered collection preserves order explicitly if meaningful; an unordered
collection has deterministic ID order. Generated routing detects ID/path
collisions. Paths are not parsed to infer arbitrary domain meaning.

The store makes snapshot selection explicit. These host operations use
[Root and its wrappers](0004-knowledge-base.md), not the guest's domain types:

```haskell
data RootStore :: Effect where
  LoadRootValueForChecking
    :: Root -> RootStore m CheckedValue
  ListFacts
    :: Validated Root -> CollectionId -> PageRequest
    -> RootStore m (Page FactId)
  ReadFact
    :: Validated Root -> CollectionId -> FactId
    -> RootStore m (Maybe CheckedValue)
  ReadExamples
    :: Root -> RootStore m [Example]
  ExportRootFiles
    :: Root -> RootStore m SubtreeReplacement
  MaterializeRoot
    :: CheckedContract -> CodeSnapshot -> CheckedValue
    -> RootStore m Root

runRootStore
  :: DhallHandling :> es
  => Eff (RootStore : es) a -> Eff es a
```

RootOpening has a separate row because locating source and inspecting a schema
requires capabilities that snapshot-only materialization and publication do not:

```haskell
data RootOpening :: Effect where
  OpenCapturedRoot :: FileTree -> RootOpening m (Either [Diagnostic] Root)
  LoadRootAt :: Repository -> GitRevision -> TreePath
             -> RootOpening m (Either [Diagnostic] Root)

runRootOpening
  :: (Git :> es, SchemaInspection :> es, DhallHandling :> es, RootStore :> es)
  => FileTree -- installed SDK sources, with compiler-relative paths
  -> Eff (RootOpening : es) a -> Eff es a
```

The initial manifest is exactly `kb.dhall` inside the selected root subtree:
`{ schemaType = "Schema.Root", schemaMetadata = "Schema.schemaMetadata" }`.
It selects declarations, not a second schema. Authored modules are under `src/`;
the opener strips that prefix for compiler inputs and appends the explicit SDK
source tree. Duplicate compiler paths fail. The SDK is supplied by the installed
runtime, not loaded from a KB-selected location, and participates in compilation
identity under ADR 0002. ADR 0005 owns schema capture and inspection.
`kb.dhall`, `src/` and `facts/` are distinct reserved layout locations; the manifest
is retained verbatim in the supporting-code snapshot alongside source and other
supporting files. FileTree rejects overlapping file/directory paths.

Drafts can use FileSystem.ReadTree followed by OpenCapturedRoot, without atomicity
under concurrent editing. Accepted roots open only from a fixed Git revision.
LoadRootAt captures the selected tree then follows the same manifest path; it does
not resolve a newer head. Missing/malformed manifests, rejected schemas and bad fact
files return diagnostics. Compiler/Git infrastructure failures remain Failure.
The result is Root, not Validated Root. This initial manifest does not advertise
validators, queries or plugins, and the opener does not validate supporting files.

`ReadExamples` loads the selected root's saved assertions, including their recorded
contracts. It does not run them or silently rebind them to new query contracts;
[checking](0011-validation.md) reports incompatibility. Its raw-root input permits
checking a candidate before it earns validation. `ExportRootFiles` supplies
publication with a complete, fixed file tree, including facts, code, configuration
and examples. It is not a callback or a path to an editable directory:

```haskell
type FileTree = [(RelativePath, Bytes)]

data SubtreeReplacement = SubtreeReplacement
  { prefix :: RelativePath  -- relative to the KB directory
  , files  :: FileTree      -- paths relative to that prefix
  }
```

Use plain immutable file trees for `FactSnapshot`, `CodeSnapshot` and captured
workspace material. Their owning store defines the path base and partitions;
they contain bytes, not live paths or callbacks. `FileTree` is a representation,
not a CAS service. Duplicate paths and file/directory collisions are errors.
An empty collection is represented by its empty membership file, not an empty
directory which Git cannot retain.

These pure host values, including repository/path primitives, live in
`kyyn-domain`; plumbing may import explicitly allowlisted pure value modules,
including schema shapes/bindings and diagnostics as well as path/byte primitives,
not KB workflow modules. ADR 0003's module import checks enforce that restriction within the
package dependency; a Cabal dependency alone does not enforce it. They need no
guest-side counterpart or new package. RootStore owns its
layout and encoding and exports prefix `root`; EvolutionStore exports its own
archive prefix. Publication composes each prefix with `KnowledgeBase.prefix`.
Git consumes repository-relative paths and bytes, without knowing either layout.
Each export replaces its complete subtree: missing paths mean deletion.

`LoadRootAt` structurally decodes a commit; it cannot confer semantic validation
without the [checker](0011-validation.md). `MaterializeRoot` verifies that the
value matches the target root contract, produces an in-memory file tree and never
advances the accepted ref. Its signature requires no guest evaluation. Its inputs
contain no implicit current schema or code. DhallHandling owns plugin-config
and fact decoding; neither leaks into the domain API. SchemaInspection
derives the contract from the selected authored schema under ADR 0005; that is
separate from parsing fact files. `MaterializeRoot` does not write a second
temporary root: `SaveCandidate` owns persistence of that returned value, context
and report. Loading a saved candidate reconstructs these same value representations.
Structural root loading includes its plugin configuration. A malformed or
structurally incompatible config fails the whole load (ADR 0016); no partial root
or silently disabled connector is returned. Pure config validation subsequently
participates in the whole-root semantic check.

Git's `ResolveRevision` reads the selected branch once and returns a revision for callers
to pass explicitly to loading, creation or rebasing. Source reads do not substitute
an ambient latest root. Publication still compares the live ref atomically; the
earlier resolution is not a reservation or a substitute for that comparison.

The initial Git plumbing supplies `ResolveRevision Repository String` and
`ReadTreeAt Repository GitRevision TreePath`. `WholeTree` selects the repository
tree itself; `Subtree RelativePath` selects a directory beneath it. Both operations
return Either [Diagnostic] for content conditions. Resolution returns a full commit
object ID; subtree capture reads that fixed revision, not the working tree. Its
interpreter lowers through ProcessExecution using an explicitly supplied Git
executable, with no IOE of its own. NUL-delimited tree entries preserve whitespace
in file names; blob contents remain bytes. Symlinks, submodules and unsupported
paths are explicit diagnostics. Regular and executable blobs are captured as byte
files; FileTree does not retain mode bits. Missing selectors/subtrees are diagnostics,
not empty snapshots. Nonzero infrastructure outcomes remain GitUnavailable; the
interpreter does not classify errors by parsing human-readable stderr. Ref mutation
and commit construction are not implemented by this reader.

`ReadFact` returns `Nothing` only for an absent ID in an existing collection.
Unknown collections, corrupt data and inaccessible storage are explicit failures.
`CheckedValue` carries the collection's payload contract, not an arbitrary JSON
object. Reads remain effects even when the initial interpreter answers from an
already loaded snapshot.
`LoadRootValueForChecking` is the explicit diagnostic/execution path for a
structurally readable but not yet semantically validated root. It is not used to
silently weaken the validation requirement on ordinary fact browsing.
Evolution execution uses this path for its source too: domain-invalid facts may
be transformed into a valid candidate without first earning `Validated`.

Browsing facts and consuming connector evidence need manageable result pages.
Paging here is that user-facing operation, not a paged storage engine or an
incremental evaluator. The initial fact interpreter can slice an already loaded
collection. A cursor is opaque and tied to its selected snapshot and query; it
is not a portable offset into whichever root is latest:

```haskell
data Page a = Page
  { items :: [a]
  , next  :: Maybe PageCursor
  }

data PageRequest = FirstPage | ContinuePage PageCursor
```

Batch size is an implementation/operation policy, not a per-field contract bound.
A mismatched cursor is an error. The [evidence](0014-evidence.md) store uses the
same envelope but binds its cursors to evidence snapshots, not root snapshots.

On the guest side, identity remains outside the typed payload so migration can
change payload shape without accidentally replacing record identity:

```haskell
newtype FactId = FactId String
data Fact a = Fact FactId a

data CollectionBinding a  -- generated collection ID + payload codec/contract
```

The generated binding is consumed by [SnapshotRead](0009-capabilities.md).
The positional SDK constructor avoids introducing a selector named `id` into
author imports. Its generated data representation is still the `id`/`value`
record envelope. The recognised SDK `FactId` projects and encodes as plain text,
not a tagged constructor; unrelated authored newtypes retain their normal encoding.
No native host function imports the payload type `a`; its corresponding data is
checked structurally through the collection contract.

Propose one complete `root/` subtree for accepted executable knowledge:

```text
root/
  kb.dhall                 selected schema and declaration exports
  src/                     current authored Haskell modules
  facts/<collection>/      identified Dhall fact files
  examples/                persistent executable assertions
  plugins/                 vendored source, origins and non-secret configuration
evolutions/<evolution>/     editable workspaces and retained accepted archives
.kyyn/                     ignored checkout-local data and disposable caches
```

This is a proposed layout for review, illustrated by the
[todo walkthrough](../walkthroughs/todo-evolution.md), not an implemented format.
The important distinction is one complete publication subtree versus evolution
archaeology and local runtime data. RootStore exports the whole subtree, so absence
from the new tree means deletion; acceptance does not guess which old files to keep.
The schema and collection declarations distinguish an empty collection from missing
data; use an explicit ordered ID list per collection to record membership/order,
including the empty list. A listed fact must exist; duplicate IDs and unlisted fact
files are errors. For unordered collections the list is sorted by ID.

Propose that each fact file encodes the full `Fact` envelope, not only its payload.
The path is derived from its collection and ID, using an unambiguous filename
encoding; a path/envelope mismatch is an error. The payload's title is never an ID.
The collection's membership list is storage structure, not another authored schema.

Secrets and machine-local configuration never become facts or committed defaults.
Non-secret connector configuration is different: RootStore persists named instances
beneath their plugin in `root/plugins/config/<plugin>.dhall`, checked against that
plugin's advertised connector types and Haskell configuration schemas under ADR 0016.
It is captured and materialized with a root's schema/code, not stored in a separate
plugin-instance service. EvolutionStore captures proposed configuration files;
normal validation and acceptance apply. Live secret values are not part of that
snapshot or its review artifacts.

Keep compilation separate from runtime fact inputs. The initial
[runtime boundary](0002-runtime.md) returns an immutable compiled value which
callers can use for multiple inputs; it does not persist a compiled-artifact cache.
Generated contract bindings, SDK and dependency source belong to its compilation
inputs. Use the whole contract, including roles, without special compatibility
rules for particular edits.

Schema inspection and pure metadata evaluation may run again when loading or
capturing a root. Do not require a separate cache for their results. Begin with
whole-root in-memory evaluation and complete validation; the page interface above
does not promise lazy or incremental guest evaluation.

Add persistent compiled-artifact caching only when the concrete loading/checking
journey demonstrates the need. Such reuse requires the complete source, contract,
SDK, dependency, actual compiler/toolchain and build-option identity, not merely a
revision label for independently built or altered installations. Publish complete
entries atomically; never expose partial artifacts as cache hits. Multiple processes
may duplicate compilation work; no duplicate-work coordinator is needed. Draft and
acceptance working-tree responsibilities are specified in ADR 0012.

## Alternatives, consequences and verification

Reject event replay on reads and compilation of records as Haskell literals.
Do not introduce a database until measured needs justify an interpreter change.
Deleting caches must not delete accepted knowledge. Reopen tests must preserve
record deletions and distinguish an empty collection from a missing/corrupt file.
Changing one fact must not rebuild unchanged guest code. Measure runtime memory
and validation time separately from compilation on representative synthetic sizes.
Include many-small-file Dhall parsing/normalization in that measurement rather
than attributing all loading cost to guest execution. ADR 0021 places this proof
before the first product slice relies on whole-root performance. If representative
interactive work is impractical, revisit the execution/storage choice then.
Browsing pages are not a claim that whole-root computation scales; do not add
storage-streaming or incremental-validation APIs in anticipation.
