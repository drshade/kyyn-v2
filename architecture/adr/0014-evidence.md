---
id: 0014
title: 'Latest evidence informs the KB; change markers support curation'
status: proposed
date: 2026-09-15
---
# Latest evidence informs the KB; change markers support curation

Basis: owner-directed latest-only evidence model. The accepted KB is our prior
understanding; the latest successful acquisition supplies current external input.
Accepted evolutions update the KB. Implementation of this storage revision and
typed plugin read discovery/KB helpers remains outstanding.

## Context

Kyyn helps keep a knowledge base up to date, not reconstruct past external worlds.
The KB already records prior understanding and its evolutions. Keeping every fetched
version duplicates a responsibility the evidence store does not need.

Curation still needs to know what changed since it last processed a source. That
requires lightweight change markers, not old payloads. Separate these concerns.

This revision removes historical fetch selection, payload replay, producer archives
and history-deletion baselines. Existing caches using that unreleased format are
refused with `evidence.invalid-data` and guidance to clear the selected instance
and refetch. Scoped clearing must discard all its cache files, including archives,
without modifying accepted KB facts. There is no format migration commitment.

## Decision

### One current captured value per evidence item

Each configured connector instance has one latest captured evidence state, stored
as Dhall in an ignored checkout-local store. A successful fetch replaces changed
items, adds new items and removes deleted items. Persistent payload storage contains
only the resulting current values.

All new evidence-read invocations use the latest successful fetch. Latest means latest successfully
captured input, not a claim of continuous synchronization with the provider.
Browsing does not implicitly acquire fresh provider data.

Identify evidence by plugin, configured connector instance and plugin-supplied item
ID. Two instances of the same connector type have independent evidence. Source
identity, configuration meaning, provider grouping and useful source references
belong to the plugin, not provider-specific rules in the host.

The guest envelope separates stable item identity, change detection and content:

```haskell
newtype EvidenceFingerprint = EvidenceFingerprint String

data Evidence a = Evidence
  { fingerprint :: EvidenceFingerprint
  , references :: [String]
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

Every supplied item has a nonempty connector-supplied fingerprint. It is an opaque
equality token for the captured content of that item, scoped to its connector and
producer. An unchanged captured representation has the same token; changed content
has a different token. Item IDs identify items; fingerprints compare their captured
content. The host does not attempt to infer business equivalence.

For local files, use a content hash. The first-party folder connector combines the
source path with that digest, so changing its directory updates matching items and
their source references too. A connector may instead use a suitable provider
revision or hash of a deliberately chosen stable representation. Exclude fetch
timestamps and other incidental acquisition metadata from that representation.
Plugins own this choice; there is no requirement to canonicalize arbitrary external
objects in the kernel. Host file acquisition can supply the hash alongside the text
from the same read, so guest authors need neither native IO nor a hashing library.

Connectors still declare New/Updated/Removed; adding fingerprints does not move
change derivation into the host. A provider delta feed is translated into these
same operations, supplying full replacement payloads and suitable revision tokens
for changed items. Acquisition compares with the current prior capture. Unchanged items produce no
delta. An update supplies the full replacement value, not a field patch. The host
checks payload contracts, nonempty fingerprints and delta consistency: new IDs must
be absent and updated/removed IDs present. An update with the same fingerprint as
the current item is refused as `evidence.invalid-delta`. The snapshot read handle
returns `Evidence a`, including its fingerprint, for that comparison.
The host applies changes in order. It does not
manufacture changes by comparing arbitrary payloads.

The first-party folder connector starts with:

```haskell
data FolderConfig = FolderConfig
  { directory :: FilePath
  , recursive :: Bool
  }
```

No patterns/globs initially. It enumerates the configured directory, optionally
recursively. Enumeration and file reads must succeed before a complete batch is
published; unreadability is not an empty directory or evidence of deletion.
Switching directories has the plugin-defined consequences of its identity policy.

Acquisition uses a configured instance from the checked accepted root. A draft
evolution's configuration can be inspected but cannot acquire evidence before
acceptance. Config and payloads are plugin-authored Haskell types; the host supplies
typed bindings and capabilities as described in ADRs 0008, 0009 and 0016.

### Atomic refresh and invocation-local reads

Publish one complete successful batch atomically. Failure leaves the current
capture and its change markers unchanged. Publication checks the expected previous
fetch ID (or no fetch for a new instance) so a concurrent acquisition cannot apply its delta against a different
base. This is local update consistency, not a curation approval workflow.

A plugin invocation reads one immutable in-memory view of the latest captured
evidence. The host owns its lifetime and releases the store lock before running
guest code or external acquisition. Refresh does not change an already-loaded
invocation's input; the next invocation uses the latest capture. That in-memory
view lasts only for its invocation.

```haskell
-- Host-side materialization of current captured evidence.
data CurrentEvidence = CurrentEvidence
  { snapshot :: EvidenceSnapshotRef
  , items :: [(EvidenceId, Evidence CheckedValue)]
  }

loadCurrentEvidence
  :: EvidenceStore :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (Maybe CurrentEvidence))

-- The guest sees a typed EvidenceSnapshot read handle, not the host representation.
```

An instance without a successful fetch is different from an available empty capture.
Acquisition can start from empty evidence for its first fetch. Reading an unfetched
or incompatible instance reports an actionable error, not fabricated empty input.
A missing item in an available capture is an ordinary absent result.

### Payload-free change tracking

Keep fetch identity, predecessor, acquisition time and lightweight item-change
markers. These support independent KB-authored curation cursors:

```haskell
data Fetch = Fetch
  { identity :: FetchId
  , previous :: Maybe FetchId
  , fetchedAt :: String
  , changes :: [EvidenceChangeMarker]
  }

data EvidenceChangeMarker = EvidenceChangeMarker
  { kind :: ChangeKind
  , item :: EvidenceId
  , fingerprint :: EvidenceFingerprint
  , citation :: EvidenceRef
  }

data ChangeKind = New | Updated | Removed

listEvidenceChanges
  :: EvidenceStore :> es
  => ConnectorInstanceRef -> Maybe FetchId
  -> Eff es (Either EvidenceProblem [EvidenceChangeSummary])
```

The marker records the supplied fingerprint for additions/updates, and the last
known fingerprint and source references for a removal. The fingerprint does not
encode the content. An unchanged fetch can have an empty change list. Change
summaries associate markers with their fetch/predecessor; they contain no payload.
The initial implementation retains this lightweight metadata until the instance's
evidence store is explicitly cleared; marker retention is unbounded for now.

`Nothing` requests all available markers; `Just f` requests markers after that fetch
through the latest fetch. A cursor identifies progress, not a payload version to
read. Investigating any changed ID reads its latest contents, even if it changed
several times since the cursor. A removed ID is absent; compare against the KB's
prior understanding rather than loading deleted evidence.

An unknown cursor or unavailable marker history is an error, never an empty result
claiming nothing changed. The agent can reconcile the full current capture instead.
Clearing evidence removes the local capture and marker history, not accepted facts,
rationales or KB-owned curation state. No per-item review/dismissal queue, inferred
curation progress or automatic acceptance.

Diagnostics distinguish `evidence.cursor-unavailable` for unknown/unavailable
curation markers, `evidence.not-fetched` for an instance without a current capture,
`evidence.producer-changed` for incompatible producing code/contract,
`evidence.base-conflict` for a concurrent publication, `evidence.invalid-delta` for
inconsistent returned changes and `evidence.invalid-data` for malformed storage.

EvidenceStore is a porcelain capability. Its interpreter owns delta application,
producer context and expected-base publication; scoped DocumentPersistence from
[ADR 0003](0003-effects.md) owns native locking and atomic byte replacement.
The lock spans reading, checking, encoding and replacement. Persistence helpers
belong to `Kyyn.Porcelain.Protocol.EvidencePersistence`.

Use one current typed document at
`.kyyn/evidence/<plugin>-<hex instance>/state.dhall`, relative to the selected KB.
The instance component is lowercase hexadecimal UTF-8. `.kyyn/.gitignore` owns the
checkout-local ignore rule; first publication creates it if absent, preserving
existing content. Store producer identity, latest values and payload-free fetch
markers. Timestamps use ISO 8601 UTC.
The initial implementation may rewrite this document; paging or another storage
engine is not required by this decision.

### Investigation and curation belong to the KB

Plugins advertise typed methods such as `viewEmail`, `hasAttachments` and
`getAttachments`. There is no required generic `viewEvidence` function. Plugin
methods interpret the latest captured payload for callers; viewing does not
silently fetch from the provider. [KB tools](0008-authoring.md) can compose these
reads, including across plugins, and compare them with accepted facts.

An agent investigates, reasons and authors an evolution with its proposed changes,
rationale and citations. It need not express its investigation as evolution code.
Repeatable processing may read current evidence through the same typed helpers.

A curation cursor is ordinary KB data. An evolution updates facts and that cursor
together; only acceptance advances accepted progress. Failed, rejected or abandoned
work does not advance it. The cursor is the author's assertion that changes through
that fetch were accounted for, not proof that every item was read or understood.
Independent workflows may use independent cursors.

An evolution may explicitly acquire evidence and then read the resulting latest
capture. Already-loaded invocation inputs do not change implicitly. Candidate
checking uses its computed result and captured checking inputs, not a fresh fetch
or replay of acquisition. Re-evaluation starts from current inputs and produces a
new candidate. Accepted evolution history records our changing understanding,
not versions of the external evidence store.

### Declared provenance

Each evolution step's Rationale carries explanation and declared EvidenceRefs
(ADR 0010). Reading does not automatically cite an item or create an obligation to
curate it. The host does not infer support from observed calls.

```haskell
data EvidenceRef = EvidenceRef
  { producer :: String
  , connector :: String
  , source :: String
  , references :: [String]
  }
```

Producer and connector identify the integration and instance; source is the
plugin-supplied item ID. References should use good source identifiers: stable URIs
where available, provider IDs with useful account/mailbox/organization scope, or
file paths with an explicit base. They need not be publicly accessible URLs.

A citation means "this source supports the change". It remains useful independently
of Kyyn's transient cache. Following it accesses the provider as available now;
the provider may change or delete the source.

The operational EvidenceFingerprint is separate from EvidenceRef. Citations do not
need fingerprints, source versions or content hashes. The connector's change token
supports refresh comparison only; it is not an immutable provenance proof and does
not establish whether the external source has changed since a citation was made.

### Plugin changes and cache replacement

Current evidence is bound to its producing plugin source and payload contract.
After a plugin update, do not reinterpret incompatible cached contents under the
new producer. Refetch. A successful fetch replaces that instance's capture and
marker history. Previous cursors report unavailable history
and the agent reconciles the new current capture. A failed refetch publishes nothing.

`evidence clear PLUGIN INSTANCE` discards that instance's local capture and metadata.
Accepted KB facts and curation progress remain owned by evolutions.

## Verification

Exercise new/updated/removed/unchanged files, stable content fingerprints, failed
acquisition and stale-base publication. After several updates, inspect stored Dhall:
only latest payloads remain; removed and superseded text is absent, and fetch
markers still identify changes after a curation cursor.

Verify latest reads across separate invocations, consistent reads within one
invocation during refresh, instance isolation, missing evidence and unavailable
cursors. Verify complete capture replacement following a plugin change.
Keep source citations and accepted KB facts intact after
scoped evidence clearing. Prove the first-party connector under GHC and MicroHs.

The [curation walkthrough](../walkthroughs/evidence-curation.md) illustrates this
journey; it does not claim that typed KB helpers or curation are already implemented.
