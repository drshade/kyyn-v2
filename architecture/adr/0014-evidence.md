---
id: 0014
title: 'Fetch history preserves evidence changes; interpretation belongs to the KB'
status: proposed
date: 2026-09-11
---
# Fetch history preserves evidence changes; interpretation belongs to the KB

Basis: owner-agreed plugin-declared deltas, retained local fetch history and
KB-owned curation progress. The first native store implements the persistence/read
boundary below. Generated guest acquisition/read adapters have a two-compiler
recording-broker proof. Native acquisition now connects filesystem and selected
evidence reads to complete-batch publication, with a real-files integration proof.
Plugin registration and configured native fetches are implemented; configured
CLI invocation remains unimplemented.

## Context

Provider representations and business meaning are different kinds of knowledge.
BEE must group duplicate observer copies correctly; Exco must not confuse a
source correction with a new business entity. Neither requires eternal evidence
schema custody in the kernel.

## Decision

### A fetch changes an evidence snapshot

Plugin source connectors acquire typed evidence. Agents and KB functions interpret
it into candidate knowledge. Keep source identity, fetch time, plugin/contract
identity and useful references with evidence. Store evidence as Dhall in an ignored
checkout-local store, not Git. Keep successful fetch deltas and a materialized latest
snapshot: refreshing does not erase the changes an agent has yet to curate.
Identify the producing plugin and named connector instance as well as its
configuration and method. Two instances of Mail must not share evidence merely
because their package and connector type match. Secret names may occur in config;
secret values are not evidence identity or metadata.
The source/sink distinction belongs to ADR 0015. Sink connectors update external
outputs through ADR 0017; they are not evidence acquisition or KB browsing.

The plugin decides which items are new, updated or removed compared with its prior
snapshot. An update supplies a replacement payload, not a generic field patch.
Unchanged items are omitted; absence from a returned batch does not mean removal.
Illustrative **guest** types make this boundary explicit:

```haskell
data Evidence a = Evidence
  { references :: [String]
  , payload :: a
  }

data EvidenceChange a
  = NewEvidence EvidenceId (Evidence a)
  | UpdatedEvidence EvidenceId (Evidence a)
  | RemovedEvidence EvidenceId

fetch
  :: Config -> EvidenceSnapshot Payload
  -> Program calls (Either FetchError [EvidenceChange Payload])
```

`Config` and `Payload` are plugin-authored Haskell types. The snapshot is a typed
read handle; this signature need not copy all previous payloads into guest memory.
The first invocation reads an empty snapshot. Host capabilities implement snapshot
reads and external acquisition; authors do not implement storage or transport IO.
The host checks the declared payload contract and delta consistency (new IDs absent,
updated/removed IDs present, applying changes in order). It does not compare payloads
to invent changes or determine business equivalence. Provider grouping, identity,
comparison and the meaning of configuration changes belong to the plugin.

For example, a folder connector starts with only:

```haskell
data FolderConfig = FolderConfig
  { directory :: FilePath
  , recursive :: Bool
  }
```

No patterns/globs initially. It reads all files in the selected directory,
optionally recursively. The plugin chooses its IDs and comparison strategy. It
must complete enumeration successfully before interpreting missing paths as
removals; an unreadable directory is an error, not an empty successful fetch.
Switching directories has the plugin-defined consequences of that identity policy;
the kernel does not impose a new instance or provider-specific reset rule.

Start with one complete returned batch. A successful fetch publishes its changes
together; a failed fetch leaves the preceding snapshot available and publishes no
successful fetch record. Publication checks the base snapshot still matches the
instance's latest fetch, otherwise reports a conflict for retry. This prevents
concurrent batches being applied against a different base; it is not an approval
workflow. Provider pagination can happen inside acquisition, but no host partial-run,
checkpoint or resumable acquisition lifecycle is required for this first boundary.

Acquisition uses a configured instance from the checked accepted root. A draft
evolution's configuration is available for authoring and inspection, but cannot
start or advance an evidence history before acceptance. CLI navigation and
diagnostics for this boundary are specified in [ADR 0018](0018-surfaces.md).

### Retained fetches and explicit selection

The host records the instance, producing package/contract, selected configuration
and fetch metadata. Plugins do not manufacture those host identities. The core
history relationship is:

```haskell
data Fetch a = Fetch
  { id :: FetchId
  , previous :: Maybe FetchId
  , changes :: [EvidenceChange a]
  }

data EvidenceSelection = CurrentEvidence | AtFetch FetchId
data EvidenceProblem = HistoryUnavailable | ProducerContractChanged

selectEvidence
  :: (EvidenceStore :> es, Failure :> es)
  => ConnectorInstanceRef -> EvidenceSelection
  -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)

readFetchesBetween
  :: (EvidenceStore :> es, Failure :> es)
  => EvidenceSnapshotRef -> Maybe FetchId
  -> Eff es (Either EvidenceProblem [Fetch CheckedValue])

readEvidence
  :: (EvidenceStore :> es, Failure :> es)
  => EvidenceSnapshotRef -> EvidenceId
  -> Eff es (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
```

These are **host** operations over checked structural payloads. `Nothing` requests
history from the beginning; `Just f` requests changes after `f` through the selected
snapshot. An unrelated, deleted or unavailable base is an error, never an empty
successful result. Generated guest adapters restore plugin-native payload types.
`EvidenceSnapshotRef` binds instance, fetch and producing package/contract; an ID
from another instance cannot silently select its evidence.
`readEvidence` is storage access used by plugin interpretation, not a generic
agent-facing view. `Right Nothing` means that item is absent at an available
snapshot; unavailable history is a different result. The invocation supplies the
selected package/contract context against which selections are checked.

`readFetchesBetween` is the payload-bearing storage operation for host adapters,
not the agent-facing change index. Investigation exposes only change identities
and citations through the application boundary:

```haskell
data ChangeKind = New | Updated | Removed
data EvidenceChangeSummary = EvidenceChangeSummary
  { fetch :: FetchId
  , previous :: Maybe FetchId
  , kind :: ChangeKind
  , item :: EvidenceId
  , citation :: EvidenceRef
  }

listEvidenceChanges
  :: (EvidenceStore :> es, Failure :> es)
  => EvidenceSnapshotRef -> Maybe FetchId
  -> Eff es (Either EvidenceProblem [EvidenceChangeSummary])
```

The summary has no opaque payload or generic rendered content. Plugin methods
interpret selected payloads. The host assembles the shared `EvidenceRef` from
producer/instance identity, plugin-supplied item ID and `Evidence.references`;
those references are source links/paths, not a second citation type. A removal
uses the removed item's preceding references. This lets rationale reuse the SDK
citation without requiring acquisition code to repeat host-owned identity fields.

Retain every successful fetch and its actual delta payloads until explicit deletion;
no automatic pruning. Reads at an earlier fetch return the payloads at that fetch,
not the current versions of the same IDs. Reconstructing snapshots from retained
deltas is sufficient; a second archival service is not required. The materialized
latest snapshot is independently readable. Explicitly deleting history preserves
that current snapshot, but makes historical selections and change spans requiring
deleted deltas unavailable. Retain its fetch identity as a readable baseline: later
changes can be listed after that baseline, and its self-span is empty. Neither
operation requires the deleted fetch record or earlier deltas. Unknown/deleted
identities without a retained snapshot are still unavailable, even for self-spans.
Clearing the entire evidence store also clears current
evidence. Refetching does not restore lost history; reconstruction from deltas is
possible only while the required history remains available.

EvidenceStore is a porcelain capability. Its interpreter owns delta application,
producer selection, history and expected-base publication; it uses the scoped
DocumentPersistence capability from [ADR 0003](0003-effects.md) for native IO.
The lock spans reading the previous document, checking its base, encoding the
new state and replacing it. Its Dhall format helpers belong to
`Kyyn.Porcelain.Capability.EvidenceStore.Persistence` in the interpreter package.

The interpreter stores one typed document at
`.kyyn/evidence/<plugin>-<hex instance>/state.dhall`, relative to the explicitly
selected KB directory. Encode the instance name as lowercase hexadecimal UTF-8 bytes;
plugin names already follow the package-name grammar. `.kyyn/.gitignore` owns the
checkout-local ignore rule; store reads do not rewrite it. First publication creates
that shared ignore file if absent, preserving any existing content, as candidate
persistence already does. The state document records
the producer's `PackageIdentity`, payload contract fingerprint, current and baseline
fetch IDs, baseline/current values and retained deltas. Fetch timestamps use ISO 8601
UTC. Native file locking plus atomic document replacement serializes the base check
and publication. Producer changes retain the old document under the instance's
`archives/` directory until explicit history deletion or whole-store clearing.
The initial interpreter rewrites that retained per-instance history; paging and
large-history performance are not established by this implementation.

Named connector bindings (ADR 0016) select current evidence by default. Resolve and
hold the selected fetch for each instance for the duration of an invocation; later
reads do not chase a refreshed latest pointer. Callers may explicitly select a
historical fetch instead. Fix the selections when beginning the invocation, using
its configured source instances, so a later conditional read cannot accidentally
pick up a concurrent refresh. This fixes local captured inputs, not a simultaneous
external-world transaction across providers. An unavailable selection reports a
useful error when read; an unused connector need not have fetched successfully.

Historical choices are explicit per-instance invocation inputs, not edits to the
generated connector value. The caller supplies an instance-to-fetch selection to
the application operation (CLI/MCP arguments or an evolution's captured invocation
inputs); omitted instances use current evidence. Generated adapters carry the
resolved snapshot context through nested plugin calls. Ordinary helper source stays
selection-agnostic: `Mail.viewEmail Connectors.salesMail id` works for either choice.
Capture explicit selections with an evaluated evolution's inputs; do not introduce
a second manifest selecting its entry function or business arguments. An evolution
that explicitly acquires evidence can explicitly select the returned fetch for a
subsequent call; acquisition never mutates an existing selection implicitly.

### Investigation and curation

Kyyn exposes fetch history, changes and item identities. There is no required
generic `viewEvidence` method. Plugins advertise typed, documented methods such as
`viewEmail`, `hasAttachments` and `getAttachments` which interpret captured payloads
appropriately for callers. Viewing does not silently fetch fresh provider state.
[KB tools](0008-authoring.md) compose these methods, including across plugins.

An agent normally investigates through these tools, reasons about the result and
authors an evolution containing its proposed fact changes, rationale and citations.
It need not express its investigation as evolution code. For repeatable processing,
an evolution can instead read evidence programmatically.

Curation progress is ordinary KB-authored data, for example a workflow-specific
last-curated fetch. There is no global kernel "curated" flag or mandatory per-item
review/dismissal queue. Independent workflows can hold independent cursors. An
evolution updates its facts and chosen cursor together; only acceptance changes
the accepted cursor. Failed, abandoned or rejected work does not advance it.
A cursor means the author claims to have accounted for changes through that fetch,
not that Kyyn proved every item was read or understood. Domain rules and validators
can express stronger requirements when useful.

An evolution entry may invoke a plugin to read an existing evidence snapshot or
explicitly acquire new evidence. Generated typed proxies carry an `EvidenceSnapshotRef`
identifying the selected host snapshot; subsequent reads must not silently switch
to refreshed contents. This is snapshot read semantics, not a mandatory separate
capture/proposal-authoring phase.

The entry returns a root with annotated step observations (ADR 0010), from which
Kyyn materializes a candidate and derives its step report. Candidate checking uses that
result and explicit captured checking inputs, not fresh evidence or rerunning the
entry. Keep any evidence-derived values actually needed by a pure check as explicit
data. No requirement to archive all RPC responses or source bytes for the life of
every candidate. Accepted knowledge keeps useful references and explanation;
an archived evolution may consequently be non-runnable later. Re-evaluation can
acquire changed evidence and produces a new result for inspection. Acquisition
and reads do not change accepted facts or mark curation as accepted.

### Declared provenance

Supporting provenance is declared through each evolution step's `Rationale`:
an explanation and a list of `EvidenceRef`s, paired with the actual changes
derived at that boundary. Reading evidence does not automatically cite it;
fetching evidence does not create a review obligation. The kernel does not infer
support from call traces or promise to prove that a cited item caused a change.

`EvidenceRef` is the shared durable citation value, not the transient acquisition
snapshot handle:

```haskell
data EvidenceRef = EvidenceRef
  { producer   :: String
  , connector  :: String
  , source     :: String
  , references :: [String]
  }
```

Producer and connector identify the integration and selected instance; source is
the plugin-supplied scoped item identity. References carry useful source links or
paths. These are authored descriptive values, not proof that the source is still
available. `EvidenceSnapshotRef` instead selects cached data for plugin reads;
the native acquisition broker binds guest reads to this selection. A citation
must not silently become a cache lookup handle.

An archived citation must retain enough source identity to describe what was
cited independently of a transient cache lookup: producer/connector identity,
source item identity and useful source references.
Plugins should make a best effort to provide good source identifiers: prefer a
stable source URI where available, or a provider-native item ID with the account,
mailbox, organization or other scope needed to identify and locate it. For example,
cite an email by its provider-supported identifier/link, a Salesforce opportunity
by its scoped opportunity ID, or a local file by its path with an explicit base
if relative. A useful source link can accompany an ID; do not require every
identifier to be a publicly accessible URL or invent a URI scheme merely for
uniformity. Avoid using only a temporary Kyyn cache key when the source provides
a better identifier. Choosing the provider's best available identifier belongs
to the plugin, not a provider-specific identity system in the kernel.

The citation contract is **"here is the source item supporting this rationale"**,
not "here is an immutable historical version". A stable item ID or file path may
later resolve to changed content. Paths can move, items can be deleted, and
following a source link may require credentials. Useful source identification
does not guarantee permanent access, retention or historical reconstruction.

Do not require source versions, fingerprints, content hashes or change tracking
for citations. Hashing a fetched representation would only compare those chosen
bytes: fetch metadata or other incidental differences can change them without a
meaningful change to the source item. Defining a canonical business projection
to make that comparison useful is not part of this contract. Kyyn does not ask
plugins to manufacture one or promise to detect whether cited content changed.

These are ordinary reference data, not a requirement to keep all source bytes.
When a citation's snapshot is gone, keep the saved source reference visible.
Following that reference or fetching again accesses the source as available now,
not a recovered historical version. The retained evolution records its fact
changes and declared rationale, not the history of the external system.

## Updates and alternatives

When a plugin changes, invalidate affected evidence selections/bindings, refresh its
contract, repair consumers and refetch. Compare package identity as well as schema:
same type does not mean same behavior. Retained old fetch bytes are not automatically
deleted, but the new plugin cannot reinterpret them under its contract. A refetch
under the new producer starts from an empty compatible snapshot; old curation
cursors cannot cross that boundary as if no changes occurred. Report the unavailable
comparison and let the agent reconcile against freshly fetched evidence. No old
plugin restoration, per-run schema migration or compatibility negotiation is required.
Do not delete accepted facts because evidence expired. Reconsidering them is an
explicit KB evolution. Preserve uncertainty when a provider cannot refetch old data.

## Verification

New/updated/removed/unchanged inputs, duplicate IDs, refresh during investigation,
failed acquisition, stale-base publication, rejected curation and changed same-schema
plugin behavior. Two instances retain independent histories; historical reads return
the saved payload, and missing history never means no changes. Verify a KB helper
composes plugin reads with fixed selections and no live acquisition or sink calls.
The [curation walkthrough](../walkthroughs/evidence-curation.md) is the integration
journey, not an assertion that these operations are already implemented.
No scenario silently marks unaccepted work processed or loses accepted knowledge.
After deleting a fixture's evidence cache, its archived citation still exposes
the source URI, scoped provider ID or file path supplied by the plugin. A plugin
can supply a useful citation without a version or fingerprint. Following its
source reference is presented as source access, not historical reconstruction;
the test does not require detecting whether the source content changed.
