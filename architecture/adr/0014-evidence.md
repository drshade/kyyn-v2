---
id: 0014
title: 'Latest evidence updates the KB; change markers support curation'
status: proposed
date: 2026-09-15
---
# Latest evidence updates the KB; change markers support curation

Basis: owner-directed latest-only evidence model. The accepted KB is our prior
understanding; the latest successful acquisition supplies current external input.
The existing historical-payload implementation must be replaced to satisfy this
revision. Typed plugin read discovery and KB helpers remain separate implementation
work.

## Context

Kyyn helps keep a knowledge base up to date, not reconstruct past external worlds.
The KB already records prior understanding and its evolutions. Keeping every fetched
version duplicates a responsibility the evidence store does not need.

Curation still needs to know what changed since it last processed a source. That
requires lightweight change markers, not old payloads. Separate these concerns.

## Decision

### One current captured value per evidence item

Each configured connector instance has one latest captured evidence state, stored
as Dhall in an ignored checkout-local store. A successful fetch replaces changed
items, adds new items and removes deleted items. Superseded and removed contents
are not retained in fetch history, baselines or producer archives.

All new evidence-read invocations use the latest successful fetch. There is no
historical fetch selector, version-addressed payload lookup, replay API or
restoration of an earlier evidence snapshot. Latest means latest successfully
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
has a different token. It is not the item ID, a storage address or a means of
retrieving an old version. The host does not attempt to infer business equivalence.

For local files, use a content hash. A connector may instead use a suitable provider
revision or hash of a deliberately chosen stable representation. Exclude fetch
timestamps and other incidental acquisition metadata from that representation.
Plugins own this choice; there is no requirement to canonicalize arbitrary external
objects in the kernel. Host file acquisition can supply the hash alongside the text
from the same read, so guest authors need neither native IO nor a hashing library.

Acquisition compares with the current prior capture. Unchanged items produce no
delta. An update supplies the full replacement value, not a field patch. The host
checks payload contracts, nonempty fingerprints and delta consistency: new IDs must
be absent and updated/removed IDs present. It applies changes in order. It does not
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
fetch ID so a concurrent acquisition cannot apply its delta against a different
base. This is local update consistency, not a curation approval workflow.

A plugin invocation reads one immutable in-memory view of the latest captured
evidence. The host owns its lifetime and releases the store lock before running
guest code or external acquisition. Refresh does not change an already-loaded
invocation's input; the next invocation uses the latest capture. There is no public
way to reopen that old input after the invocation ends.

```haskell
-- Host-side materialization; not a historical selector.
loadCurrentEvidence
  :: EvidenceStore :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (Maybe CurrentEvidence))

-- CurrentEvidence contains the latest fetch identity and checked item values.
-- The guest sees a typed EvidenceSnapshot read handle, not the host representation.
```

An instance without a successful fetch is different from an available empty capture.
Acquisition can start from empty evidence for its first fetch. Reading an unfetched
or incompatible instance reports an actionable error, not fabricated empty input.
A missing item in an available capture is an ordinary absent result.

### Payload-free change tracking

Keep fetch identity, predecessor, acquisition time and lightweight item-change
markers. These support independent KB-authored curation cursors. They do not retain
payloads or permit replay:

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
markers. Timestamps use ISO 8601 UTC. No old-payload baseline or producer archive.
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

A citation means "this source supports the change", not "this old source version
can be retrieved". It remains useful independently of Kyyn's transient cache.
The provider may change or delete the source. Kyyn neither retains that content
nor promises historical reconstruction.

The operational EvidenceFingerprint is separate from EvidenceRef. Citations do not
need fingerprints, source versions or content hashes. The connector's change token
supports refresh comparison only; it is not an immutable provenance proof and does
not establish whether the external source has changed since a citation was made.

### Plugin changes and cache replacement

Current evidence is bound to its producing plugin source and payload contract.
After a plugin update, do not reinterpret incompatible cached contents under the
new producer. Refetch. A successful fetch replaces that instance's old capture and
marker history; it does not archive either. Old cursors report unavailable history
and the agent reconciles the new current capture. A failed refetch publishes nothing.

This is an unreleased local cache, not a compatibility commitment. Replacing the
historical format must not leave old payload archives behind as an unused fallback.
Implementation must use an explicit scoped discard/refetch path for old-format
evidence; it must not silently migrate or rewrite accepted KB facts.

## Verification

Exercise new/updated/removed/unchanged files, stable content fingerprints, failed
acquisition and stale-base publication. After several updates, inspect stored Dhall:
only latest payloads remain; removed and superseded text is absent, and fetch
markers still identify changes after a curation cursor.

Verify latest reads across separate invocations, consistent reads within one
invocation during refresh, instance isolation, missing evidence and unavailable
cursors. Reject historical-selection CLI arguments. Plugin changes replace rather
than archive evidence. Keep source citations and accepted KB facts intact after
scoped evidence clearing. Prove the first-party connector under GHC and MicroHs.

The [curation walkthrough](../walkthroughs/evidence-curation.md) illustrates this
journey; it does not claim that typed KB helpers or curation are already implemented.
