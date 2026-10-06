---
id: 0014
title: 'Latest evidence and recipe-scoped declared curation'
---
# Latest evidence and recipe-scoped declared curation

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
only the resulting current values. Binary and large-text payloads use typed
BlobRefs under [ADR 0029](0029-evidence-blobs-sync.md), not embedded file contents.
That ADR owns atomic connector sync positions and blob lifetime. Neither is
historical evidence or a curation watermark.

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

data EvidencePayload a = Available a | Truncated

data Evidence a = Evidence
  { fingerprint :: EvidenceFingerprint
  , references :: [String]
  , payload :: EvidencePayload a
  }

data EvidenceChange a
  = NewEvidence EvidenceId (Evidence a)
  | UpdatedEvidence EvidenceId (Evidence a)
  | RemovedEvidence EvidenceId
  | SetEvidencePayload EvidenceId EvidenceFingerprint (EvidencePayload a)

fetch
  :: Config -> EvidenceSnapshot Payload
  -> Program calls (Either FetchError [EvidenceChange Payload])
```

Every supplied item has a nonempty connector-supplied fingerprint. It is an opaque
equality token for the captured content of that item, scoped to its connector and
producer. An unchanged captured representation has the same token; changed content
has a different token. Item IDs identify items; fingerprints compare their captured
content. The host does not attempt to infer business equivalence. Fingerprints
describe the observed evidence version, not whether its bytes are retained.
A newly discovered item may already have a Truncated payload: the connector must
still supply a meaningful fingerprint, from a provider token or a stable observed
projection. Never fingerprint the Truncated constructor as the item's version.

For local files, host acquisition returns lowercase hexadecimal SHA-256 over the
UTF-8 source path and captured bytes, each prefixed by its unsigned 64-bit
big-endian byte length. The first-party folder connector uses that token directly,
so changing its directory updates matching items and their source references too.
A connector may instead use a suitable provider
revision or hash of a deliberately chosen stable representation. Exclude fetch
timestamps and other incidental acquisition metadata from that representation.
Plugins own this choice; there is no requirement to canonicalize arbitrary external
objects in the kernel. Host file acquisition can supply the hash alongside the text
from the same read, so guest authors need neither native IO nor a hashing library.

Connectors still declare New/Updated/Removed; adding fingerprints does not move
change derivation into the host. A provider delta feed is translated into these
same operations, supplying replacement evidence envelopes and suitable revision tokens
for changed items. Acquisition compares with the current prior capture. Unchanged evidence produces no semantic
delta. An update supplies the full replacement value, not a field patch. The host
checks payload contracts, nonempty fingerprints and delta consistency: new IDs must
be absent and updated/removed IDs present. An update with the same fingerprint as
the current item is refused as `evidence.invalid-delta`. The snapshot read handle
returns `Evidence a`, including its fingerprint, for that comparison.
The host applies changes in order. It does not
manufacture changes by comparing arbitrary payloads.

### Payload availability is independent of evidence changes

Truncation discards a payload, not an evidence entry. The ID, fingerprint and
source references remain present in the current snapshot. Available and Truncated
are payload states, not alternatives to New, Updated or Removed. A truncated item
can be newly discovered, changed, acknowledged or pending like any other item.

`SetEvidencePayload` operates only on an existing ID; its supplied fingerprint
must equal that entry's current fingerprint or the operation is refused. It
preserves the fingerprint and references. It allows Available-to-Truncated retention and restoration to
Available without violating the same-fingerprint UpdatedEvidence rejection.
Apply it in batch order with the other operations; unknown IDs are invalid deltas.
Restoration must supply the same evidence version. If the connector observes
changed content, it emits UpdatedEvidence with the new fingerprint instead.
Repeatedly setting Truncated is a harmless no-op. All Available values undergo
the payload contract checks, including blob-reference checks under ADR 0029.

Payload-only operations produce no New/Updated/Removed change marker and do not
alter recipe acknowledgements. They still publish atomically with the successful
fetch and its sync position. No expiry event or append-only connector category is
needed. A source removal is exclusively the connector's domain declaration about
an existing item; truncation, missing bytes and local cache clearing never imply it.

Snapshot reads distinguish an absent ID from a present Evidence with Truncated
payload. Plugin methods handle the latter explicitly, returning a useful unavailable
payload result rather than an empty successful value or an implicit provider fetch.
A method requiring content returns a typed FetchError identifying payload truncation,
distinct in its diagnostic from a missing ID or corrupt/missing blob. CLI/MCP
presentation must expose that distinction rather than claim the item was deleted.
Discovery shows payload availability alongside identity/fingerprint; pending results
must not silently omit truncated items. Recipes decide whether to acknowledge,
follow source references or leave the item pending. EntireBatch acknowledgement
includes truncated entries too; it is an explicit declaration, not proof of reading.

Retained references are source citations, not references keeping discarded blobs
alive. Only Available payloads own blob references. Metadata persists until an
explicit connector removal or instance cache clearing; payload retention does not
promise bounded metadata storage or current upstream liveness. Truncated entries
still contribute to whole-document read/rewrite cost in `state.dhall`; truncation
reduces payload storage, not that scaling cost. It introduces no paging engine.

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

### Connector-owned fetch options

`evidence fetch PLUGIN INSTANCE [--options DHALL]` accepts a value of the
connector's advertised options type, inspected and checked as specified in
[ADR 0015](0015-plugins.md#one-plugin-several-connectors). The host checks the
supplied hermetic Dhall against that contract before executing the plugin.
It refuses supplied options when the connector advertises no options type.
Omission reaches an options-aware connector as `Nothing`; the connector owns
defaulting and semantic validation. Options are non-secret invocation data, not
persisted instance configuration. Use named secrets for credentials.

A fetch returns changes applied to the prior capture, not an implicit replacement
listing. Absence from a partial result never means deletion. Removals require
the source to establish absence. The host has no timestamp semantics or generic
watermark, and fetching remains independent of accepted recipe progress.

### Microsoft Graph calendar acquisition

The first calendar connector captures event resources from one configured user
calendar, not a calendarView of expanded recurring occurrences. Graph's
[events collection](https://learn.microsoft.com/en-us/graph/api/calendar-list-events?view=graph-rest-1.0)
contains single events and recurring-series masters. A
[calendarView](https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview?view=graph-rest-1.0)
instead expands occurrences in an event-time window. Its required start/end dates
cannot implement a modified-time window. The connector must not claim that series
master acquisition covers every occurrence exception or cancellation.

Default acquisition paginates the full events collection and compares all returned
items, with no timestamp cutoff derived from previous captures. The connector
advertises optional per-fetch scope:

```haskell
data CalendarFetch = CalendarFetch
  { modifiedFrom :: Maybe String, modifiedTo :: Maybe String }
```

Supplied bounds are timezone-qualified ISO 8601 instants compared inclusively
against `lastModifiedDateTime`, independently of meeting start/end dates. Reject
malformed or inverted bounds. Missing bounds are unbounded; `Nothing` options
and an options record with both bounds absent select all upserts. Compare parsed
instants, not arbitrary timestamp strings. These options limit additions/updates
only; they do not restrict removal detection or discard already captured items
merely because those items fall outside the bounds.

Paginate the calendar's events collection and filter by modified time in plugin
code. This initial choice requires no undocumented server-side timestamp-filter
support and makes no remote-query efficiency claim. Every fetch reads the whole
calendar: supplied options narrow captured upserts, not what is downloaded. Follow every
returned next page before publishing a batch; a page failure publishes nothing. The payload
retains the provider modification time. There is no separate persisted fetch clock.

Use the provider event ID within the configured instance and its `changeKey` as
the opaque change token. Keep returned source links for citations. Graph describes
these fields in its [event resource contract](https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0).
Capture a stable projection of the event, without fetch-time fields. Emit New for
an absent ID, Updated for a different token, and nothing for an unchanged token.
A scoped re-fetch reads current provider values, not historical versions.

After the full listing succeeds, emit Removed for previously captured IDs absent
from that complete, unfiltered listing, even when upsert options were supplied.
Never compare captured IDs against only the option-selected subset. A returned
cancellation field is an update. This mirrors the selected event-resource
collection, not expanded recurring occurrences or a transactionally frozen view
of the remote calendar. Provider ID behavior and changes during pagination need
live verification; fake-server tests do not establish those properties.
Authentication is owned by ADR 0016, not this fetch contract.

### Microsoft Graph mail, meeting artifacts and files

These sources share the Microsoft Graph package, authentication and download/retry
helpers under ADRs 0015, 0016 and 0029. They expose provider data rather than
classifying what it means to a KB. Payload fingerprints hash the connector's
stable captured projection, excluding fetch times, transient download URLs and
sync positions. Provider citations remain separate from these operational tokens.

#### Mail

```haskell
data MailConfig = MailConfig
  { auth :: GraphAuth, mailbox :: String
  , folders :: [MailFolder], retentionDays :: Integer }
data MailFolder = WellKnownFolder String | FolderPath String
data MailFetch = MailFetch
  { since :: Maybe String
  , maxAttachmentBytes :: Maybe Integer
  , attachmentMediaTypes :: [String] }
data MailPosition = MailPosition
  { folders :: [FolderPosition] }
data FolderPosition = FolderPosition
  { folderId :: String, deltaLink :: String }

data AttachmentContent = Stored BlobRef | Link String | Skipped String
data Attachment = Attachment
  { name :: String, mediaType :: String, size :: Integer
  , inline :: Bool, content :: AttachmentContent }
```

The payload is one message: subject, from/to/cc addresses, sent/received instants,
conversationId, internetMessageId, first-seen folder, text body and attachments.
Resolve configured well-known names (such as inbox/sentitems) or custom folder
paths to provider folder IDs. Keep one delta continuation per folder and publish
all folder results/positions together. Configure one mailbox per instance.

Use Graph's immutable message ID, with `Prefer: IdType="ImmutableId"` on every
relevant request, including pagination. Deduplicate across selected folders by
that ID; do not prefix it with the current folder or replace it with a timestamp.
The first-seen folder is recorded once, using configured folder order to break a
first-fetch tie. The immutable-ID guarantee is mailbox-scoped; archive-mailbox
moves and export/reimport can create a different identity. See
[Graph immutable IDs](https://learn.microsoft.com/en-us/graph/outlook-immutable-id).

This connector captures newly encountered mail, not a mirror of read flags or
folder membership. Ignore provider deletions/moves and changes to already captured
messages; fingerprint the captured payload, not `changeKey`. No owner-address
direction inference. Message-to-fact interpretation belongs to curation.

Initial backfill uses `since`, defaulting to 30 days before the invocation's
captured start time; later fetches follow saved folder continuations. Do not
silently reinterpret `since` as a new cursor: reject a supplied initial boundary
once a position exists, with clear/refetch guidance. Follow all pages; failed
pagination publishes neither messages nor cursors. If a cursor expires, rebuild
that folder's enumeration, deduplicate against retained IDs and publish only on
success. `retentionDays` truncates older message payloads based on received time,
preserving their IDs/fingerprints/references; it does not remove evidence. A retained
truncated ID still participates in deduplication. Retention is not a historical-read promise.
The [message delta contract](https://learn.microsoft.com/en-us/graph/api/message-delta)
owns available filters and continuation semantics; do not infer a general query
language from it.

Request text bodies; do not dump HTML as the agent's normal reading surface.
Capture inline attachment metadata too. Download policy uses declared size/media
type and the streaming byte limit; an intentionally omitted attachment records a
Skipped reason, not an empty successful file. Missing metadata must not silently
claim a download passed a policy check. Transient transport/throttling failures
fail/retry acquisition rather than becoming permanent Skipped results.

File attachments use raw bytes. Attached messages use MIME `.eml`; attached contacts
and events retain their actual `.vcf`/`.ics` representations. Reference attachments
remain links rather than attempted `$value` downloads. These distinctions follow
[Graph attachment content](https://learn.microsoft.com/en-us/graph/api/attachment-get).
All actual downloads use the same status-aware retry route as metadata requests.

#### Teams meeting artifacts

```haskell
data MeetingRef = MeetingRef
  { onlineMeetingId :: String, joinUrl :: String
  , subject :: String, organizer :: String }
data MeetingArtifact
  = Transcript { meeting :: MeetingRef, started :: String, ended :: String
               , content :: BlobRef }
  | Attendance { meeting :: MeetingRef, started :: String, ended :: String
               , attendees :: [AttendanceRecord] }
```

`AttendanceRecord` preserves the provider's participant identity and attendance
intervals; its ordinary record definition is plugin-owned. Instance configuration
selects the user and retention days. Fetch options select a look-back window,
defaulting to three days before acquisition start. Discover recently ended online
meeting events with calendarView, resolve onlineMeeting by join URL, and enumerate
its transcript/report resources. Use actual artifact/session times, not the
calendar start as an item key.

An item is an artifact, not a selected "best" transcript or an inferred occurrence.
Use an unambiguous encoding of artifact kind, onlineMeeting ID and Graph artifact
ID; this preserves provider identity even if IDs are only unique within a meeting
or collide across transcript/report families. Keep every returned transcript/report,
skip already captured IDs, and fingerprint the captured payload. VTT content is a
blob. Fetch every available page of attendance records, preserving all attendees.
No longest-transcript selection, heuristic occurrence linkage or connector-authored
meeting judgement. Curation links artifacts to calendar facts and cites them.

Provider deletions are not tracked. Retention truncates older artifact payloads
using their ended time, retaining identity/fingerprint/references and deduplication.
Discovery is a bounded look-back, not a guarantee
of finding arbitrarily late artifacts; authors can request a wider window.
The [transcript API](https://learn.microsoft.com/en-us/graph/api/onlinemeeting-list-transcripts)
and [attendance API](https://learn.microsoft.com/en-us/graph/api/meetingattendancereport-list)
have their own permissions, supported meeting kinds and availability limits.
In particular, report listing exposes at most the latest 50 reports; fetching every
returned page cannot remove that provider limit. A missing eligible artifact is not
proof that a meeting did not happen. Fail clearly on authorization or unsupported
mode rather than presenting it as empty evidence.

#### SharePoint and OneDrive files

```haskell
data FilesScope
  = SiteLibrary { site :: String, library :: String }
  | OneDrive { user :: String }
  | SharedUrl { url :: String }
data FilesConfig = FilesConfig
  { auth :: GraphAuth, scope :: FilesScope
  , folderPath :: String, includeGlobs :: [String] }
data FileContent = StoredFile BlobRef | SkippedFile String
data FilePayload = FilePayload
  { name :: String, path :: String, webUrl :: String
  , mediaType :: String, size :: Integer
  , modified :: String, modifiedBy :: String
  , cTag :: Maybe String, content :: FileContent }
```

Resolve the configured site/library, user drive or pasted URL to drive/item IDs
on initial acquisition and retain them in the typed sync position. A changed
source configuration starts a new producer, not a cursor pointed at another drive.
The selected folder is rooted by ID after resolution. Include globs match relative
slash-separated paths beneath it: `*`/`?` stay within a segment, `**` crosses
segments, and an empty list includes every file. No separate recursive flag.

Use drive-root delta for the business-drive path, filtering results to the selected
subtree and globs in plugin code. Evidence ID is an unambiguous driveId/itemId pair,
not a path. Retain the folder hierarchy in the connector-owned position so folder
renames/moves update descendants' paths and scope even when the provider omits
those descendants. Coalesce repeated item entries before deriving one consistent
delta against the prior capture. A failed page/hydration leaves the capture and
position unchanged. A provider-invalidated cursor triggers complete reconciliation,
not blind deletion from a partial response.

Hydrate metadata absent from delta before content decisions. Compare `cTag` to the
previous payload: unchanged content reuses its blob; changed/absent tags require
retrieval rather than treating absent tags as equal proof of unchanged content.
A rename/path/metadata change updates the payload fingerprint but does not itself
require downloading identical bytes. Download URLs are transient acquisition data,
not stable payload fields. Provider deletions and moving out of the selected scope
emit RemovedEvidence. Files have no age-out retention; the capture mirrors their
latest scoped state. Follow the [drive delta contract](https://learn.microsoft.com/en-us/graph/api/driveitem-delta)
for cursor reset, repeated entries and hierarchy omissions.

### Atomic refresh and invocation-local reads

Publish one complete successful batch atomically. Failure leaves the current
capture and its change markers unchanged. Publication checks the expected previous
fetch ID (or no fetch for a new instance) so a concurrent acquisition cannot apply its delta against a different
base. This is local update consistency, not a curation approval workflow.

A plugin invocation reads one immutable in-memory view of the latest captured
evidence. The host owns its lifetime and releases the store lock before running
guest code or external acquisition. Refresh does not change an already-loaded
invocation's input; the next invocation uses the latest capture. That in-memory
view lasts only for its invocation. Referenced blobs share that scoped lifetime
under ADR 0029; refresh must not reclaim bytes an active reader still needs.

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
markers. These describe acquisition, independently of any recipe's processing:

```haskell
data Fetch = Fetch
  { identity :: FetchId
  , previous :: Maybe FetchId
  , fetchedAt :: String
  , suppliedOptions :: Maybe DhallText
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

`suppliedOptions` records the supplied checked value as normalized hermetic Dhall
text, not an unevaluated expression with imports. Omission remains absent; do not
invent or record plugin defaults in the host. Persist it with the successful fetch
and display it in `evidence history list`, including for an unchanged fetch.
The history reader does not need the currently installed plugin's options schema
to display that text. Options are non-secret by convention, not host-redacted data.
Fetch records written without the options field read as absent options; malformed
present options remain an error. Both evidence loading and historical curation
resolution use this rule.

The marker records the supplied fingerprint for additions/updates, and the last
known fingerprint and source references for a removal. The fingerprint does not
encode the content. An unchanged fetch can have an empty change list. Change
summaries associate markers with their fetch/predecessor; they contain no payload.
The initial implementation retains this lightweight metadata until the instance's
evidence store is explicitly cleared; marker retention is unbounded for now.
New fetch IDs are eight lowercase hexadecimal digits from 32 random bits, redrawn
on collision with an ID in that instance's retained history; existing IDs remain valid.

`Nothing` requests all available markers; `Just f` requests markers after that fetch
through the latest fetch. This is an acquisition-history selector, not recipe
progress or a payload version to read. Investigating any changed ID reads its latest
contents, even if it changed several times since that fetch. A removed ID is absent; compare against the KB's
prior understanding rather than loading deleted evidence.

An unknown fetch ID or unavailable marker history is an error for raw history
requests, never an empty result claiming nothing changed. Recipe pending discovery
does not require this history.
`evidence list PLUGIN INSTANCE` lists the latest capture's current IDs and
fingerprints and payload availability, without payload contents or recipe filtering;
it changes no curation progress.
An unfetched instance returns `evidence.not-fetched`; a fetched empty set lists no items.
Clearing evidence removes the local capture and marker history, not accepted facts,
rationales or accepted curation progress. No mandatory per-item review queue, inferred
curation progress or automatic acceptance.

Diagnostics distinguish `evidence.cursor-unavailable` for unknown/unavailable
raw-history fetch selectors (not recipe progress), `evidence.not-fetched` for an instance without a current capture,
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
markers, and the connector's optional checked sync position. Timestamps use ISO 8601 UTC.
Publication rewrites this document; no paging or separate storage engine is used.
Blob bytes live beside the document under ADR 0029; the document remains metadata
and typed current values, never base64 file contents.

### Investigation and curation belong to the KB

Plugins advertise typed methods such as `viewEmail`, `hasAttachments` and
`getAttachments`. There is no required generic `viewEvidence` function. Plugin
methods interpret the latest captured payload for callers; viewing does not
silently fetch from the provider. [KB tools](0008-authoring.md) can compose these
reads, including across plugins, and compare them with accepted facts.

An agent investigates, reasons and authors an evolution with its proposed changes,
rationale and citations. It need not express its investigation as evolution code.
Repeatable processing may read current evidence through the same typed helpers.

### Recipes name the curation task

A recipe is authored knowledge about how to interpret evidence and do useful
work: for example, synchronize todos or update grocery prices. Its instructions
are part of the KB's accumulated understanding, not tool configuration. Recipes
are identified data in the accepted root, edited by the same typed evolution
that edits domain facts. In instruction-led mode, an agent follows
their instructions and uses ordinary investigation and evolution tools.
[ADR 0028](0028-agentic-workflows.md#open-and-closed-recipes-share-ordinary-curation)
owns explicit flow execution alongside this mode. This ADR owns the recipe data
type; recipes remain neither scheduled jobs nor autonomous kernel-managed
sequences of agent actions. Both constructors are persisted and inspectable;
ADR 0028 owns explicit flow execution into a draft evolution.

```haskell
-- Shared SDK data; the KB author still defines the domain facts type.
data Recipe
  = OpenAgent { instructions :: String }
  | ClosedAgent { flow :: FlowEntryRef }
newtype FlowEntryRef = FlowEntryRef String
data KnowledgeBase facts = KnowledgeBase facts [Fact Recipe]

-- Author-facing optics/edit handles; their implementation owns the wrapper.
facts :: Lens (KnowledgeBase a) (KnowledgeBase b) a b
recipes :: Collection (KnowledgeBase a) Recipe

onFacts
  :: (a -> Either EvolutionFailure b)
  -> KnowledgeBase a -> Either EvolutionFailure (KnowledgeBase b)
```

`FlowEntryRef` stores the name of a callable KB function, not executable code or
a closure. ADR 0028 owns its resolution and execution. The guest wrapper is a
materialized value, not the host repository locator named
`KnowledgeBase` in ADR 0004. It contains no paths, code, closures or curation
register. `onFacts` lifts an ordinary fallible domain transformation and preserves
the recipes; it does not lift a previously observed Evolution or create another
observation protocol. A failed domain transformation returns no changed wrapper.
The SDK reexports this vocabulary through `Kyyn.Evolution` and the generated
workspace facade. No new recipe editor or command family is needed.

The recipe fact ID is its name. A `RecipeId` in a curation declaration refers to
that same textual ID, not another ID stored in the payload. Names retain the
connector-binding identifier rule, uniqueness and their own namespace. At the
host boundary, reject invalid/duplicate recipe IDs with a diagnostic identifying
the recipe. Ordinary fact IDs need not obey this additional addressability rule.

For example, a recipe-only evolution uses the existing collection operations:

```haskell
evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution = edit (Rationale "Explain how to reconcile todos" []) $
  within recipes $
    append (Fact (FactId "syncTodos")
      (OpenAgent "Read pending evidence and reconcile the corresponding todos."))
```

For this recipe-only edit, Before and After alias the same authored root type.
`update (FactId "syncTodos")` focuses the Recipe payload, and `remove` removes
that recipe. Generated domain collection handles already focus through the
wrapper's facts lens, so the same `edit` action can edit either kind of collection.
A facts-only edit is just:

```haskell
evolution = edit (Rationale "Remove the cancelled task" []) $
  within AfterCollections.todos $ remove (FactId "todo-002")
```

Persist the recipes in `root/recipes.dhall` as identified values of the shared
Recipe union, with an OpenAgent instructions payload or a ClosedAgent function
reference. The fixed codec follows the shared Recipe/Fact structure; it is not a
second KB-authored schema. Existing instruction-only `{ instructions : Text }`
payloads decode as `OpenAgent`; new writes use the constructor representation.
This narrow old-shape read also preserves existing recipe payloads in archived
reports, without introducing a general migration framework.
Initialization emits an empty list; absence reads as empty, malformed data fails.
Materialization and acceptance always write recipes.dhall, including an empty list.
Recipes do not change the author's RootContract identity. Read them from the
Before revision, send them with facts to the guest, validate the returned recipes
and materialize them with the returned facts. Exclude them from source/config
capture and reject `target/recipes.dhall`, like a parallel target fact edit.
There is no target-manifest override of the evolved result.

`root/kb.dhall` has no recipes field. Its ordinary exact-shape decoder rejects
unexpected fields; do not add recognition of retired manifest fields or a second
read path. The CLI guide explains the one-time repair for existing KBs: move
entries to recipes.dhall and remove the field. An entry `{ name, instructions }` becomes
an identified `OpenAgent` value carrying those instructions. This is a one-time manual working-KB
repair, not a versioned migration subsystem. Already accepted evolution archives
remain readable without loading or rerunning their old source.

Every observed boundary includes both domain facts and recipe data. The host
checks their continuity from Before to the returned result and derives recipe
additions, updates and removals by ID, beside domain fact changes under the same
step rationale. Use a distinct recipe-change report case with typed before/after
Recipe payloads, not a fake collection in the author's RootContract. Human and
structured review display both:

```haskell
-- Host review data; RecordedFact retains the domain contract on its value.
data Change
  = FactChange CollectionName FactId (Maybe RecordedFact) (Maybe RecordedFact)
  | RecipeChange FactId (Maybe Recipe) (Maybe Recipe)

data StepReport = StepReport Rationale [Change]
```

`RecipeChange` compares the complete payload, including its constructor. Switching
OpenAgent to ClosedAgent is an update to the same recipe ID; review displays the
before/after mode and instructions or callable name, respectively. Changing a
closed recipe's callable name is likewise a recipe update, not a fact edit.

The two cases keep a recipe named `todos` distinct from a domain collection of
that name; no reserved domain collection name is needed. Archive format and
older-record reading are owned by [evolutions](0010-evolutions.md).

Resolve acknowledgements against the returned recipe set: an evolution can add a
recipe and acknowledge evidence for it in the same result. Removing a recipe does
not delete or mutate its host-maintained progress. Reusing its name restores that
identity and its progress; a different task should use a different name. Queries
and authored validators keep their existing domain-Root inputs; this change does
not widen every guest entry point. Kernel recipe validation and discovery use the
fixed shared type.

CLI discovery is rooted at `root recipe list`, `root recipe show NAME`, and
`root recipe pending list NAME PLUGIN INSTANCE`. List/show needs only the selected
revision's recipe data, not a schema or plugin compiler. The read-only `RecipeStore`
capability exposes those selected root-document reads separately from schema opening:

```haskell
LoadRecipesAt :: KnowledgeBase -> GitRevision
  -> RecipeStore m (Either [Diagnostic] [Recipe])
LoadCurationAt :: KnowledgeBase -> GitRevision
  -> RecipeStore m (Either [Diagnostic] CurationRegister)
```

Its interpreter reads through Git and delegates recipe/register decoding to
RootStore. It does not create another writer. Pending discovery prepares the
selected connector, loads its current capture under that producer contract, reads
the register from the same selected Git revision and performs the pure comparison.
Results include a fixed plugin/instance/fetch scope and ID/change-kind entries,
not payloads. An incompatible stored capture requires refetch
(`evidence.producer-changed`); a refetched producer which differs from accepted
recipe progress returns `Reconciliation` with the full current ID set, rather
than pretending the producers' fingerprints are comparable.

An evolution may name one recipe or none. A recipe may use many connector instances;
different recipes may independently process the same evidence. Instructions can
change without automatically resetting progress. Ordinary manual corrections and
schema changes need no recipe. Acknowledgement declarations require a named recipe.

### Declare what was handled; derive progress in the host

An evolution's result may declare batches or individual items handled for its
recipe. These are not inferred from reads, citations or changes to facts. The
shared SDK declarations make the scope explicit:

```haskell
data EvidenceScope = EvidenceScope
  { scopePlugin :: String, scopeInstance :: String, scopeFetch :: String }

data Acknowledgement
  = EntireBatch EvidenceScope
  | IndividualRecords EvidenceScope [EvidenceId]

data Curation = Curation RecipeId [Acknowledgement]

withCuration :: Curation -> Evolution a b -> Evolution a b
```

Small SDK helpers attach this declaration to the existing evolution result; no
second required guest entry point. One result has at most one recipe context;
composition combines acknowledgements within that context, not across recipes.
A single evolution can acknowledge a batch for one instance and selected items
for another. Handling evidence without changing facts is valid. Rationale explains
the author's decision; acknowledgements do not duplicate it or require an
explanation per item. Citing evidence neither acknowledges it nor requires doing so.

Discovery supplies ordinary scope data naming the fetch considered, not a moving
reference to latest. No session, lease or server-side selection registry is needed.
The agent can retain this scope while preparing literal edits; the guest need not
replay the investigation. If it reads a later capture, it can declare that later
scope instead. Kyyn does not prove what the agent actually read or understood.

During candidate preparation the host resolves declarations against the named
capture's retained identity/change metadata, including deletion states, and
derives progress from the Before root's register. The guest does not construct
register maps or look up fingerprints. Unknown scopes
or insufficient history are explicit diagnostics, never a substitution of latest.
The host projects the stored header and history, validates the
marker chain and reconstructs item states from its first fetch through the named
fetch. Missing evidence or a chain which no longer contains that fetch gives
`curation.scope-unavailable`. It does not reconstruct payloads. The resolved
producer is the stored header's producer, not the currently installed plugin:
acknowledging an older producer records that producer; pending comparison against
a newer producer then requires reconciliation with an entire batch.

The guest's `EvidenceScope` contains plugin name, instance name and
fetch ID strings. Evolution entries do not receive the generated connector
handles used by KB tools. Scope data can be copied from evidence discovery;
preparation checks its identity against retained evidence. `withCuration` appends
its declarations after those already in the wrapped result. Composing different
recipe contexts fails with `curation.recipe-conflict`; the host checks the selected
recipe against the returned recipe data, allowing a new recipe and its first
acknowledgements in the same evolution.

Preparation diagnostics give the author a concrete repair:

| Code | Repair |
| --- | --- |
| `recipe.invalid-id` | Rename the identified recipe using the connector-binding identifier rule. |
| `recipe.duplicate` | Give the identified recipes distinct IDs or remove the unintended duplicate. |
| `recipe.invalid-data` | Repair the recipe file to the documented list of Fact Recipe values; malformed Dhall retains its Dhall diagnostic. |
| `curation.recipe-invalid` | Use a valid recipe identifier. |
| `curation.recipe-unknown` | Add the recipe in this evolution or select a recipe present in its result. |
| `curation.recipe-conflict` | Compose declarations for one recipe per evolution. |
| `curation.scope-invalid` | Correct the plugin/instance/fetch fields or an empty evidence ID. |
| `curation.scope-unavailable` | Inspect a fresh fetch and update the declaration to its scope. |
| `curation.progress` | For a changed producer, reconcile an entire batch; for malformed captured IDs/fingerprints, repair or refetch the evidence as the message directs. |
| `curation.producer-changed` | Inspect current evidence and acknowledge an entire batch to reconcile the recipe with the new producer. |

For an individual declaration, presence at the selected fetch supplies its
fingerprint; absence removes its acknowledged entry. Absence can be established
from a complete capture even after a fresh clone/refetch, without a historical
deletion marker. This is an explicit acknowledgement operation, not inference of
a pending source deletion. A present truncated item supplies its retained fingerprint.
Removing an already absent register entry is a no-op.

The prepared candidate contains the resolved register update and declarations for
inspection. Acceptance publishes that fixed register with facts and the evolution
archive in the same Git commit, through the existing expected-head operation.
It neither looks up latest evidence nor reruns the guest. Failed, rejected or
abandoned work leaves accepted progress unchanged. A refresh after preparation
does not invalidate the declaration or acknowledge the new fetch; later changes
remain discoverable. Cache loss after preparation does not prevent publishing an
already resolved, otherwise acceptable candidate.

### Accepted progress and net pending evidence

The host owns a Git-tracked Dhall register within the accepted root's persisted
material, separate from the guest's domain Root type and from the ignored evidence
cache. Root capture/export preserves it. Git supplies its history; there is no
second acknowledgement database. Store resolved states, not references into the
checkout-local fetch history:

```haskell
data CurationRegister -- opaque map from (recipe, instance) to producer and acknowledged states

type CurationEntry =
  (RecipeId, ConnectorInstanceRef, EvidenceProducer, [(EvidenceId, EvidenceFingerprint)])

curationEntries :: CurationRegister -> [CurationEntry]
curationRegister :: [CurationEntry] -> Either String CurationRegister
```

Persist the register at `root/curation.dhall`, as host material alongside facts,
excluded from the code tree copied into evolution targets. Root capture/export
must preserve it separately from authored code; preparation derives candidate
progress from Before, never from a target-edited register. Absence means an empty
register, so existing KBs need no empty-file migration. The Dhall codec uses sorted
association lists for stable diffs; its exact schema accompanies the persistence
implementation below. Removing a recipe declaration does not delete its acknowledged
map; it is inactive until that identity is used again.

The register document is a list of records with Text fields `recipe`, `plugin`,
`instance`, `producer`, `contract`, and `acknowledged : List { id : Text,
fingerprint : Text }`. Entries sort by recipe/plugin/instance, and members by ID.
Duplicate keys, empty member IDs/fingerprints and malformed contract identities are
refused. Structurally invalid register entries report `curation.invalid-register`;
Dhall parsing/type failures retain their Dhall diagnostics. The contract field is
the producer's lowercase hexadecimal contract fingerprint, not a duplicated schema.
Empty registers are omitted from both candidate storage and root export.

A batch replaces the instance's map
with all IDs/fingerprints present at its selected fetch, not just pending rows.
An individual declaration inserts/replaces selected present items and removes
selected absent ones. Apply declarations in their authored list order; the last
accepted declaration wins. An explicitly older state can make evidence pending
again; there is no monotonic-progress enforcement. With no prior progress, use
an empty map. Fetching never changes this register.

Fetch identities are needed to resolve declarations during preparation, not to
interpret accepted progress. Bare fingerprints are not comparable across producer
replacements; retain the producing context with the map.

Pending discovery compares each item's acknowledged state with the current capture
and explicit connector removal evidence. It does not return every intervening
acquisition event. No historical payload is required:

```haskell
data PendingEvidence
  = PendingEvidence EvidenceSnapshotRef [(EvidenceId, ChangeKind)]
  | Reconciliation EvidenceSnapshotRef [EvidenceId]

-- Pure comparison after host capabilities load progress and evidence metadata.
pendingEvidence
  :: RecipeId -> CurationRegister -> EvidenceCapture
  -> Either CurationProblem PendingEvidence
```

`EvidenceCapture` contains the snapshot identity, current ID/fingerprint pairs
(including truncated items), and the IDs whose latest relevant source change is
an explicit removal. Derive the latter from retained change markers, not missing
payloads. New or Updated for an ID supersedes its earlier removal. These are host
types: EvidenceSnapshotRef also retains the producer. No historical payloads enter
the comparison.
The guest projection in ADR 0028 uses EvidenceScope plus typed PendingChange values;
it cannot fabricate a host producer identity. The caller selects the recipe and
instance before comparison.

| Acknowledged state | Later acquisition changes | Pending result |
| --- | --- | --- |
| Absent/unseen | New, Updated | New with latest state |
| Absent/unseen | New, Updated, Removed | None |
| Present | Updated, Updated | Updated if fingerprint differs |
| Present | Updated, Removed | Removed |
| Present | Removed, New | Updated, or none if fingerprint matches |
| Absent/unseen | New with Truncated payload | New |
| Present | Payload truncated or restored, same fingerprint | None |
| Present | Absent after cache clear/refetch, no removal marker | None |

If the New state was individually acknowledged before removal, removal remains
pending. Acknowledgements by another recipe have no effect on this comparison.
An absent ID is pending Removed only if it was acknowledged and the captured
producer has an explicit, unsuperseded removal marker for it. Presence always
uses fingerprint comparison, regardless of payload availability. Accepting the
removal acknowledgement drops that ID from the recipe map, so the retained marker
does not keep reporting it. Deleting evidence does not itself delete facts.

An empty pending result means only no net unacknowledged evidence changes. It
does not mean the task is complete or prohibit inspecting current evidence,
revisiting acknowledged items, or preparing an evolution. New grocery items may
need existing prices even when no prices have changed. The intelligence and task
completion judgment belong to the agent, not Kyyn.

A missing current capture requires fetching, not reconstructing old history.
After a fresh clone or cache clear, a successful fetch from the same producer is
enough to compare present IDs against the committed register. Clearing the cache
loses unprocessed removal markers: absence after refetch cannot reconstruct a
source deletion. Such deletions may no longer be pending and derived facts can
remain stale until a recipe explicitly reconciles them. This is an accepted local
cache-loss limitation, not grounds to invent removals from missing IDs.
A failed/unavailable fetch is not an empty capture. Producer mismatch is explicit:
do not compare incompatible fingerprints or silently report no work. The agent
receives `Reconciliation scope currentIds` through pending discovery and closed
recipe input. This includes an empty current set when applicable. It is not a
delta: old IDs are not presented as deletions and current IDs are not labelled
new. Compare the current evidence with the supplied root according to the recipe.
The flow may omit acknowledgement, leaving reconciliation pending, or declare
`EntireBatch scope` to establish the map under the new producer. Reject individual
acknowledgements for that scope before saving a proposal. Acceptance still owns
updating progress; fetching and merely executing a flow do not.
Individual updates cannot mix producer contexts within one map. The register
stores no payloads, tombstones, read log or review statuses.
Its size is proportional to acknowledged present items.

### Declared provenance

Each evolution step's Rationale carries explanation and declared EvidenceRefs
(ADR 0010). Reading does not automatically cite an item or create an obligation to
curate it. The host does not infer support from observed calls.

```haskell
data EvidenceRef = EvidenceRef
  { producer :: String
  , instanceName :: String
  , source :: String
  , references :: [String]
  }
```

Producer and instanceName identify the integration and instance; source is the
plugin-supplied item ID. References should use good source identifiers: stable URIs
where available, provider IDs with useful account/mailbox/organization scope, or
file paths with an explicit base. They need not be publicly accessible URLs.

A citation means "this source supports the change". It remains useful independently
of Kyyn's transient cache. Following it accesses the provider as available now;
the provider may change or delete the source.
Human evolution reports label these as declared citations, not verified evidence.
Citation storage and evolution-wire codecs encode the instance name under the
`connector` key; human/agent-facing JSON uses `instance`.

The operational EvidenceFingerprint is separate from EvidenceRef. Citations do not
need fingerprints, source versions or content hashes. The connector's change token
supports operational refresh and curation comparison; it is not an immutable provenance proof and does
not establish whether the external source has changed since a citation was made.

### Plugin changes and cache replacement

Current evidence is bound to its producing plugin source and payload contract.
After a plugin update, do not reinterpret incompatible cached contents under the
new producer. Refetch. A successful fetch replaces that instance's capture and
marker history. Raw history requests for old fetch IDs report unavailable history;
recipe pending discovery instead checks the register's producer context and asks
for reconciliation on mismatch. A failed refetch publishes nothing.

`evidence clear PLUGIN INSTANCE` discards that instance's local capture and metadata.
Accepted KB facts and curation progress remain owned by evolutions.

## Verification

For Graph acquisition, cover initial/empty captures, default full comparison,
inclusive equal-time bounds, edits to old meetings, invalid options, pagination
failure, unchanged tokens and real removals. Check that an item outside supplied
bounds is not falsely removed, while an ID absent from the unfiltered listing is
removed. Verify option discovery, pre-execution type refusal, unchanged no-options
connector signatures and supplied-option history round trips. Failed batches leave
evidence and history unchanged. Exercise throttling waits and cancellation. Run
the same guest under GHC and MicroHs with recording HTTP/secret handlers, then the
installed CLI against a fake server. Live calendar checks must distinguish series
masters from occurrences and verify the advertised modified-time behavior.

Exercise new/updated/removed/unchanged files, stable content fingerprints, failed
acquisition and stale-base publication. After several updates, inspect stored Dhall:
only latest payloads remain; removed and superseded text is absent, and fetch
markers still identify acquisition changes after a retained fetch ID.

Verify latest reads across separate invocations, consistent reads within one
invocation during refresh, instance isolation, missing evidence and unavailable
raw-history fetch IDs. Verify complete capture replacement following a plugin change.
Keep source citations and accepted KB facts intact after
scoped evidence clearing. Prove the first-party connector under GHC and MicroHs.

Exercise the net-difference table as pure cases,
including selective acknowledgement between fetches, independent recipes and
instances, mixed batch/individual declarations, duplicate declarations and authored
order/last-declaration semantics. Prove acknowledgement-only evolution,
failed/rejected work leaving progress untouched, and acceptance after a newer fetch
without skipping its changes. Reopen the register from Git without the evidence
cache; refetch with the same producer and obtain correct pending additions/updates,
but no invented removals for absent IDs whose markers were lost. Cover explicit
acknowledgement of an absent ID after that refetch, failed fetch versus empty
capture, and producer mismatch/reconciliation. Verify New and Updated with
Truncated payloads remain pending, same-fingerprint truncation/restoration leaves
progress and change markers unchanged, mismatched-fingerprint payload operations
fail, and re-addition supersedes an old removal even if its payload is later truncated.

The [curation guide](../../docs/guide.md#recipes-and-curation) shows the CLI and
guest acknowledgement helpers.
