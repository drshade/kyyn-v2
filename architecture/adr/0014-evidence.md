---
id: 0014
title: 'Current evidence and recipe-owned state'
---
# Current evidence and recipe-owned state

## Context

Kyyn helps keep a knowledge base up to date, not reconstruct past external worlds.
The KB already records prior understanding and its evolutions. Keeping every fetched
version duplicates a responsibility the evidence store does not need.

Agents and recipes decide what evidence matters to their task. An acquisition log
must not become a mandatory processing queue. Keep current evidence available for
investigation, and let recipes explicitly own any processing state they need.

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
newtype EvidenceFingerprint = EvidenceFingerprint Text

data EvidencePayload a = Available a | Truncated

data Evidence a = Evidence
  { fingerprint :: EvidenceFingerprint
  , references :: [Text]
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
can be newly discovered or changed like any other item.

`SetEvidencePayload` operates only on an existing ID; its supplied fingerprint
must equal that entry's current fingerprint or the operation is refused. It
preserves the fingerprint and references. It allows Available-to-Truncated retention and restoration to
Available without violating the same-fingerprint UpdatedEvidence rejection.
Apply it in batch order with the other operations; unknown IDs are invalid deltas.
Restoration must supply the same evidence version. If the connector observes
changed content, it emits UpdatedEvidence with the new fingerprint instead.
Repeatedly setting Truncated is a harmless no-op. All Available values undergo
the payload contract checks, including blob-reference checks under ADR 0029.

Payload-only operations do not represent a source addition, update or removal. They still publish atomically with the successful
fetch and its sync position. No expiry event or append-only connector category is
needed. A source removal is exclusively the connector's domain declaration about
an existing item; truncation, missing bytes and local cache clearing never imply it.

Snapshot reads distinguish an absent ID from a present Evidence with Truncated
payload. Plugin methods handle the latter explicitly, returning a useful unavailable
payload result rather than an empty successful value or an implicit provider fetch.
A method requiring content returns a typed FetchError identifying payload truncation,
distinct in its diagnostic from a missing ID or corrupt/missing blob. CLI/MCP
presentation must expose that distinction rather than claim the item was deleted.
Discovery shows payload availability alongside identity/fingerprint. Agents and
recipes decide whether to follow source references, skip an item or request
another acquisition. The host does not track whether it was processed.

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

The Calendar connector synchronizes the mailbox's default calendar through
[calendarView delta](https://learn.microsoft.com/en-us/graph/api/event-delta?view=graph-rest-1.0).
Its configured `windowStart` and `windowEnd` are explicit, fixed, timezone-qualified
ISO 8601 instants selecting meeting times, including expanded recurring occurrences.
Reject invalid or inverted windows and non-default calendar IDs; there is no
rolling window or second full-events acquisition path.

```haskell
newtype CalendarPosition = CalendarPosition { deltaLink :: Text }

fetch :: CalendarConfig -> FetchContext CalendarPosition -> EvidenceSnapshot Event
      -> Acquisition Event (Either FetchError (FetchResult Event CalendarPosition))
```

The first fetch establishes a baseline. Subsequent fetches follow the saved delta
link verbatim, including its encoded window. Follow all next links before publishing
evidence and the final delta link together, as specified in [ADR 0029](0029-evidence-blobs-sync.md).
Use event IDs and `@odata.etag` (or `changeKey` when omitted) for additions/updates, retaining source links and
`lastModifiedDateTime` in the payload. For repeated IDs in a round, the last copy wins.
An `@removed` entry removes a captured ID from this source's scope; unknown IDs do nothing.
HTTP 410 or `syncStateNotFound` restarts a full baseline, reconciling prior IDs against
that complete result; failed rounds publish nothing. Authentication belongs to ADR 0016.

### Microsoft Graph mail, meeting artifacts and files

These sources share the Microsoft Graph package, authentication and download/retry
helpers under ADRs 0015, 0016 and 0029. They expose provider data rather than
classifying what it means to a KB. Payload fingerprints hash the connector's
stable captured projection, excluding fetch times, transient download URLs and
sync positions. Provider citations remain separate from these operational tokens.

#### Mail

```haskell
data MailConfig = MailConfig
  { auth :: GraphAuth, mailbox :: Text
  , folders :: [MailFolder], retentionDays :: Integer }
data MailFolder = WellKnownFolder Text | FolderPath Text
data MailFetch = MailFetch
  { since :: Maybe Text
  , maxAttachmentBytes :: Maybe Integer
  , attachmentMediaTypes :: [Text] }
data MailPosition = MailPosition
  { folders :: [FolderPosition] }
data FolderPosition = FolderPosition
  { folderId :: Text, deltaLink :: Text }

data AttachmentContent = Stored BlobRef | Link Text | Skipped Text
data Attachment = Attachment
  { name :: Text, mediaType :: Text, size :: Integer
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
  { onlineMeetingId :: Text, joinUrl :: Text
  , subject :: Text, organizer :: Text }
data MeetingArtifact
  = Transcript { meeting :: MeetingRef, started :: Text, ended :: Text
               , content :: BlobRef }
  | Attendance { meeting :: MeetingRef, started :: Text, ended :: Text
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
  = SiteLibrary { site :: Text, library :: Text }
  | OneDrive { user :: Text }
  | SharedUrl { url :: Text }
data FilesConfig = FilesConfig
  { auth :: GraphAuth, scope :: FilesScope
  , folderPath :: Text, includeGlobs :: [Text] }
data FileContent = StoredFile BlobRef | SkippedFile Text
data FilePayload = FilePayload
  { name :: Text, path :: Text, webUrl :: Text
  , mediaType :: Text, size :: Integer
  , modified :: Text, modifiedBy :: Text
  , cTag :: Maybe Text, content :: FileContent }
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

### Current evidence, not a processing log

Persist current values, producer identity, the connector's optional checked sync
position and the latest successful fetch summary. Do not retain an acquisition
event log, removal-marker history, recipe watermarks or acknowledgement register.
New/Updated/Removed remain connector operations applied atomically to the current
snapshot, not a durable work queue. Keep the existing expected-base publication
check and invocation-local read consistency.

```haskell
data FetchSummary = FetchSummary
  { identity :: FetchId
  , fetchedAt :: Text
  , suppliedOptions :: Maybe DhallText
  , added :: Integer, updated :: Integer, removed :: Integer
  }
```

Options are the checked, normalized hermetic Dhall supplied by the caller; absence
does not invent plugin defaults. A no-change fetch still records successful
acquisition. The latest identity distinguishes publications; it is not a historical
selector or a recipe cursor. Generate identities without relying on a retained
history. Clearing an instance removes its current evidence, summary and position,
not accepted facts, recipe state or citations.

EvidenceStore is a porcelain capability. Its interpreter owns delta application,
producer checks and expected-base publication. Scoped DocumentPersistence from
[ADR 0003](0003-effects.md) owns native locking and atomic replacement. Persist one
typed document at `.kyyn/evidence/<plugin>-<hex instance>/state.dhall`; the instance
component is lowercase hexadecimal UTF-8. The checkout-local ignore rule belongs
to `.kyyn/.gitignore`. Blob lifetime remains owned by ADR 0029.

Distinguish unfetched, fetched-empty, incompatible producer, truncated payload,
malformed storage and publication conflict. A missing ID or cleared cache is not
proof of upstream deletion. There is no generic pending/reconciliation result.
After refetch, recipe code decides what a changed producer means for its own task.

### Investigation reads the current evidence

Provide generic current-evidence enumeration and payload access as well as
plugin-authored typed methods. A caller must not need a historical change list or
already know every ID to investigate a source.

```haskell
listEvidenceIds
  :: ReadsEvidence row payload
  => EvidenceSnapshot payload
  -> Program row (Either FetchError [EvidenceId])

readEvidence
  :: ReadsEvidence row payload
  => EvidenceSnapshot payload -> EvidenceId
  -> Program row (Either FetchError (Maybe (Evidence payload)))
```

Generated instance bindings expose equivalent typed reads to KB tools and recipe
flows, not only plugin implementations. The broker captures each instance lazily
on its first read and reuses it for that invocation. CLI/MCP provide current item
listing and payload inspection/export, including availability and source references.
Plugin methods such as `viewEmail` or `getAttachments` may provide more useful
domain-specific views. KB helpers can compose these reads across connectors and
compare them with accepted facts. No general query language is required.

An agent may investigate and then author literal edits; it need not reproduce
its investigation in evolution code. A recipe may inspect any current evidence,
including previously seen items, and may use several connectors. Source selection
is authored logic/instructions, not a recipe whitelist enforced by the host.
Nothing requires every item to be processed, dismissed or cited.

### Each recipe owns an always-present typed state

A recipe is identified authored knowledge in the accepted root. Open recipes
guide an external agent; closed recipes name a regular authored flow
([ADR 0028](0028-agentic-workflows.md)). Both own state, independently of their mode.

```haskell
data RecipeMethod
  = OpenAgent { instructions :: Text }
  | ClosedAgent { flow :: FlowEntryRef }

data Recipe state = Recipe
  { method :: RecipeMethod
  , state :: state
  }
```

Different recipes may have different Haskell state types. Their IDs identify
separate values even when their state types coincide. Authors can use ordinary
Root facts for intentionally shared knowledge; dedicated recipe state avoids
implicit ownership conventions and accidental cross-recipe updates.

Creating a recipe supplies its state type and initial value in the same ad hoc
evolution. Updating a recipe supplies its resulting state, preserving the prior
value when appropriate or transforming it when the state type changes. Removing
a recipe removes its state; recreating that ID requires a new initial value.
A stateless recipe uses `()`. There is no absent/first-run state and no automatic
reset on instruction or flow changes.

State types use the existing compiler-inspected contract and generated codec
machinery. Open recipes explicitly select an authored state type. Closed recipes derive
the state type from their flow signature; they do not declare it a second time. These are references to
Haskell declarations, never a second structural schema maintained by the author.
The generated authoring facade supplies typed recipe handles and codecs; authors
do not construct host Value envelopes or decode Dhall. The host representation
erases the heterogeneous types only after contract checking:

```haskell
-- Host material, not a guest schema declaration.
data StoredRecipe = StoredRecipe
  { identity :: RecipeId
  , method :: RecipeMethod
  , stateType :: TypeRef
  , stateContract :: CheckedContract
  , stateValue :: CheckedValue
  }
```

For open recipes the persisted definition includes the selected state type name.
For closed recipes it contains the flow name instead; inspection derives both
request and state types from that signature. StoredRecipe.stateType above is the
resolved in-memory projection, not an additional closed-recipe declaration.

Persist definitions in `root/recipes.dhall` and each state's hermetic Dhall at
`root/recipes/<recipe-id>/state.dhall`. The selected authored state type determines
the contract; the host derives it rather than trusting a competing stored schema.
The CheckedContract above is an inspected in-memory value. Missing, mismatched or
malformed state fails loading/checking; it is never silently initialized.
Recipe IDs retain the existing unique binding-identifier rule.

Ad hoc evolution bindings support typed creation, removal and updates of recipes,
including state-schema migration. The contract-bearing handles are generated,
not assembled by the author:

```haskell
data RecipeType state        -- generated type reference and codec
data RecipeDefinition state  -- method and its generated state binding

openRecipe :: RecipeType state -> Text -> RecipeDefinition state
unitRecipeType :: RecipeType ()

createRecipe
  :: RecipeId -> RecipeDefinition state -> state
  -> Edit (KnowledgeBase root) ()

updateRecipe
  :: RecipeType before -> RecipeId -> RecipeDefinition after
  -> (before -> Either EvolutionFailure after)
  -> Edit (KnowledgeBase root) ()

removeRecipe :: RecipeId -> Edit (KnowledgeBase root) ()
```

An author requests a state handle by importing
`Kyyn.Workspace.Before.RecipeTypes.<Module>.<Type>` or
`Kyyn.Workspace.After.RecipeTypes.<Module>.<Type>`; each exports `recipeType`.
Before uses the selected Git revision's source closure. After uses the captured
target sources, including newly authored types. Defining modules stay independent
of generated bindings. Resolve imports through compiler parsing as for
Kyyn.Contracts; no extra type registration list. Ordinary aliases keep imports
readable. Unit uses the SDK's unitRecipeType, with its codec, instead of a
fabricated authored declaration.

Closed definitions are requested through
`Kyyn.Workspace.After.RecipeFlows.<Module>`, which exports selected flow names
as typed RecipeDefinition values. For example, importing this module as Flows
makes `Flows.captureNotes :: RecipeDefinition ReviewState` available when the
authored flow has the corresponding state type. Generation inspects the actual
flow signature; no author-supplied state type, request codec or flow registry.
These are definition handles, not executable flows inside the pure evolution.
Source modules and their ordinary flows remain available through ordinary imports.

Creation refuses an existing ID; update/removal refuse a missing ID. Updating
checks the selected existing state type before applying the transformation.
Instruction-only updates use the same state type and an identity transformation.
The heterogeneous recipe container stays behind the guest KnowledgeBase wrapper;
generated adapters encode/decode each selected state contract. These operations
do not require a universal guest Dynamic value or author-maintained codec.

For creation, suppose target sources introduce
`ReviewV1.ReviewState { reviewedIds :: [String] }`. The complete workspace entry
can add the recipe while retaining the existing domain schema:

```haskell
module Evolution where

import Kyyn.Workspace.Evolution
import qualified RootV1 as Root
import qualified ReviewV1 as Review
import qualified Kyyn.Workspace.After.RecipeTypes.ReviewV1.ReviewState as State

evolution :: Evolution (KnowledgeBase Root.Root) (KnowledgeBase Root.Root)
evolution = edit (Rationale "Add the email review recipe" []) $
  createRecipe (RecipeId "reviewMail")
    (openRecipe State.recipeType "Review relevant emails and propose useful tasks.")
    (Review.ReviewState [])
```

For a later migration, Before contains ReviewV1 and the target contains
`ReviewV2.ReviewState { reviewedIds :: [String], lastWindow :: Maybe String }`:

```haskell
module Evolution where

import Kyyn.Workspace.Evolution
import qualified RootV1 as Root
import qualified ReviewV1 as Old
import qualified ReviewV2 as New
import qualified Kyyn.Workspace.Before.RecipeTypes.ReviewV1.ReviewState as BeforeState
import qualified Kyyn.Workspace.After.RecipeTypes.ReviewV2.ReviewState as AfterState

evolution :: Evolution (KnowledgeBase Root.Root) (KnowledgeBase Root.Root)
evolution = edit (Rationale "Remember the last reviewed window" []) $
  updateRecipe BeforeState.recipeType (RecipeId "reviewMail")
    (openRecipe AfterState.recipeType "Review relevant emails in the requested window.")
    (\(Old.ReviewState reviewed) -> Right (New.ReviewState reviewed Nothing))
```

Before/After source closure naming follows ADR 0005, including its collision rules.
An unchanged domain root type does not erase the changed recipe-state contract.
The complete recipe set and state values are evaluated root material, not
target-file overrides of the result. Generated bindings preserve untouched recipes.
Endpoint
inspection includes each selected recipe state type; state migration uses the
same Before/After source and contract rules as domain migration.

### Recipe state changes only through evolutions

[ADR 0010](0010-evolutions.md) owns the ad hoc/recipe-based distinction and author
edit surface. A recipe-based evolution selects exactly one existing recipe from
Before. Kyyn supplies its state from that same Git revision as the domain root;
the result proposes fact changes and the next state. It cannot implicitly select
or mutate another recipe's state. Creating recipes or changing their definition
or state schema is ad hoc work. Open and closed recipes both use this route;
one closed run produces one evolution, never an aggregate of different recipes.

State-only proposals are valid. Full candidate checking and the single expected-head
acceptance publish facts, recipe state and the archive together. A failed, abandoned
or merely evaluated proposal does not update accepted state. State is included in
review with its before/after contracts and values; it is not hidden runtime metadata.
The SDK may provide State-style editing ergonomics without introducing a separate
mutable store or acceptance protocol.

Kyyn does not interpret state as a cursor, dismissed-ID set, completeness claim or
proof of processing. It does not compare it with the evidence cache at acceptance.
Reads and citations have no implicit state effect. Recipes may choose to remember
IDs/fingerprints or a window; loss of local evidence does not erase that knowledge,
nor does it prove that anything disappeared upstream.

Recipe list/show exposes method, selected state type and stored state. State
inspection need not execute a flow. Root validation checks every state against its
selected contract; authored business validation and normal evolution checks decide
whether the resulting KB is valid.

### Declared provenance

Each evolution step's Rationale carries explanation and declared EvidenceRefs
(ADR 0010). Reading does not automatically cite an item or create an obligation to
curate it. The host does not infer support from observed calls.

```haskell
data EvidenceRef = EvidenceRef
  { producer :: Text
  , instanceName :: Text
  , source :: Text
  , references :: [Text]
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
supports operational refresh; it is not an immutable provenance proof and does
not establish whether the external source has changed since a citation was made.

### Plugin changes and cache replacement

Current evidence is bound to producing plugin source and payload contract. Do not
reinterpret incompatible values under a new producer. Successful refetch replaces
the capture and position; failed refetch publishes nothing. Recipe state is not
reset or forced through reconciliation. Authors decide how to adapt their methods.

## Verification

Exercise connector additions, updates, removals, payload truncation/restoration,
stable fingerprints, failed pages and expected-base conflicts. Verify that only
current payloads and the latest fetch summary remain, with no acquisition history.
Test consistent reads within an invocation and fresh reads in the next, instance
isolation, empty versus unfetched captures, and producer replacement.

Prove generic guest enumeration/read and agent payload inspection without pending
selection; compose reads across plugins. Cache clearing must leave accepted facts,
recipe state and citations unchanged. Missing cache data never implies deletion.

Create open and closed recipes with distinct state types and initial values.
Reject missing/wrongly typed state and duplicate IDs. Exercise state-only proposals,
atomic fact-plus-state acceptance, failed-run preservation, no-recipe ad hoc changes,
and independent state for two recipes sharing a state type. Migrate a recipe state
type through an ad hoc evolution and inspect its old/new values without rerunning
archived code. Removing/recreating a recipe must not resurrect old state.
