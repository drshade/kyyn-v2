---
id: 0029
title: 'Evidence blobs and connector-owned sync positions'
---
# Evidence blobs and connector-owned sync positions

## Context

Mail attachments, meeting transcripts and drive files need captured bytes without
embedding binaries or large text in `state.dhall` or sending downloads through
the MicroHs process. Incremental providers also need a continuation position that
advances atomically with the evidence it describes. Plugins own provider-specific
acquisition; the host supplies blob storage and position persistence.

## Decision

### Captured bytes have typed references

The SDK supplies a recognized nominal type, not a convention inferred from fields:

```haskell
data BlobRef = BlobRef
  { sha256 :: Text
  , size :: Integer
  , mediaType :: Text
  , name :: Maybe Text
  }
```

`sha256` is lowercase hexadecimal SHA-256 of the exact stored bytes; `size` is
their nonnegative byte count. Media type and display name describe that use of
the bytes; neither participates in byte identity. Names are not paths. Absent
response media type defaults to `application/octet-stream`.

Schema inspection recognizes the SDK declaration by resolved identity under
[ADR 0005](0005-contracts.md), retaining the annotation through records, unions,
optionals and lists. It generates ordinary typed codecs and a Dhall record
projection. A structurally similar authored record is not a BlobRef. This lets
the host locate references without parsing provider-specific payloads.

Store bytes under the existing per-instance evidence directory:
`.kyyn/evidence/<plugin>-<hex instance>/blobs/<sha256>`. Dhall payloads contain
references, not bytes or absolute paths. Deduplication is instance-local; there
is no shared global store. Hashing uses a maintained native implementation.

### Acquisition streams through the host

These guest declarations extend [ADR 0009](0009-capabilities.md)'s acquisition
row; they do not grant downloads to captured readers or KB tools:

```haskell
data BlobDownload = BlobDownload
  { request :: HttpRequest
  , name :: Maybe Text
  , mediaType :: Maybe Text
  , maxBytes :: Maybe Integer
  }

data BlobResponse = BlobResponse
  { status :: Int
  , headers :: [(Text, Text)]
  , blob :: Maybe BlobRef
  }

data BlobAcquisition a where
  StoreBlob :: BlobDownload -> BlobAcquisition (Either FetchError BlobResponse)

storeBlob :: BlobDownload
          -> Acquisition payload (Either FetchError BlobResponse)
```

The native interpreter streams the response into a temporary file while hashing
and counting it. It makes a complete blob available only after successful stream
completion; truncation, cancellation, disk failure and an exceeded requested limit
return failure without a usable reference. `maxBytes` is the connector's explicit
download policy, not a universal schema-bound system. The request can supply known
attachment metadata; omitted metadata uses response headers/defaults.

Completed successful HTTP responses return a blob, including zero-byte content.
Non-success HTTP responses return their status and headers with no blob. Their
bodies are not captured as evidence. This is deliberately not just `Either
FetchError BlobRef`: the plugin must see 429/503 and Retry-After and use its existing
retry helper for downloads too. Transport/storage failures are sanitized errors;
cancellation propagates. The HTTP layer does not add hidden retries. Redirects
use native HTTP handling without forwarding credentials to unrelated origins;
provider download URLs and response headers remain excluded from routine traces.

The broker dispatches to typed native plumbing for streaming HTTP/blob storage;
it does not open files or implement HTTP itself. EvidenceStore remains responsible
for checking references and publication, not provider requests. Guest downloads
return only metadata over the existing protocol. The source bytes never enter
guest memory on this path.

### Reads belong to one captured invocation

```haskell
data BlobRead a where
  ReadBlob :: BlobRef -> BlobRead (Either FetchError ByteString)

readBlob :: BlobRef -> CapturedRead payload (Either FetchError ByteString)
readBlobText :: BlobRef -> CapturedRead payload (Either FetchError Text)

type CapturedRead payload a = Program (EvidenceRead payload :+: BlobRead) a
```

The implicit read context is the method's explicit `EvidenceSnapshot payload`
argument, installed by its host interpreter. Only references reachable in that
captured snapshot are readable. Knowing a hash from another instance or an earlier
fetch is not a historical-read API. Missing/corrupt bytes produce an actionable
error, never a provider fetch. `readBlobText` strictly decodes UTF-8 and reports
invalid encoding. These are effectful reads with immutable inputs, not Haskell
`pure` functions or a claim that filesystem failure is impossible.

An explicit byte read may bring the whole blob into guest memory. Private protocol
adapters use a maintained binary-to-text codec to carry those bytes in the string
profile of [ADR 0007](0007-wire.md); authors write no base64 or transport code.
This does not add arbitrary ByteString fields to public schema contracts. Authors
return BlobRefs when a caller needs the file rather than its interpreted content.

### Publication and reclamation

Successful fetch publication checks that every resulting reference resolves to a
complete blob in that instance. Blobs must exist before the atomic state-document
replacement, so readers cannot observe published references to incomplete files.
Evidence, change markers and sync position commit together under the existing
expected-fetch check. Failure leaves that document unchanged.

After publication, reclaim bytes no longer referenced by Available payloads in
latest evidence. Truncated payloads retain evidence metadata but no BlobRefs;
their former bytes are reclaimed unless another available item or active invocation
still needs them. Source references/fingerprints do not retain bytes. Also
reclaim temporary/unpublished downloads after failure or cancellation. In-flight
captured readers and concurrent acquisitions keep their required bytes alive
until their scoped use ends; cleanup cannot race them, including across local
Kyyn processes. Interrupted cleanup may leave garbage, never dangling published
references. Subsequent cleanup removes abandoned work after establishing it is
not active. Native scoped lifetime handling belongs beneath the plumbing effect,
not in plugin code or a public durable-session API.

The host boundary makes instance and lifetime explicit. These signatures omit
private paths and lock implementation, not the required scoped ownership:

```haskell
data BlobScope -- host-only lifetime of one instance's active capture/acquisition

withBlobScope
  :: BlobStorage :> es
  => ConnectorInstanceRef -> [BlobRef] -> (BlobScope -> Eff es a) -> Eff es a

storeBlobAt
  :: BlobStorage :> es
  => BlobScope -> BlobDownload -> Eff es (Either FetchError BlobResponse)

readBlobAt
  :: BlobStorage :> es
  => BlobScope -> BlobRef -> Eff es (Either FetchError ByteString)
```

Opening a capture and protecting its references must be coordinated with
publication/cleanup; a scope cannot be acquired after its bytes were reclaimed.
The new scope also protects downloads until publication/failure has resolved.
The porcelain composes this boundary with EvidenceStore; its IO interpreter
owns the filesystem/resource mechanics.

Neither citations nor recipe state retain evidence-store blobs. Retaining bytes
briefly for an active invocation is not offering historical fetch selection.
Clearing an instance clears its blobs along with its evidence and sync position.
Payload truncation/restoration follows ADR 0014 and is not a source-removal event.

### Surface results expose files, not binary transcripts

Guest-to-guest calls retain typed BlobRefs. At CLI/MCP presentation, the host
finds BlobRefs through the checked result contract and supplies a read-only local
file path alongside each reference. Resolution uses the originating captured
instance, including when a composed KB tool reads several plugins. A forged or
unresolvable reference is a diagnostic, not a guessed filesystem path.

The path identifies the captured local blob, not a citation, a KB fact or a
promise of permanent availability. It is usable from the current local capture;
a later refresh or explicit cache clearing can remove it. Do not create a second
archive of exported files. An agent can read a PDF/image itself;
Kyyn adds no PDF extraction, OCR, HTML interpretation or document-conversion engine.

### Sync positions are typed connector data

Stateful fetch signatures extend the stateless forms in [ADR 0015](0015-plugins.md):

```haskell
data FetchContext position = FetchContext
  { startedAt :: Text
  , priorPosition :: Maybe position
  }
data FetchResult payload position = FetchResult
  { changes :: [EvidenceChange payload]
  , position :: position
  }

fetch :: Config -> FetchContext Position -> EvidenceSnapshot Payload
      -> Acquisition Payload (Either FetchError (FetchResult Payload Position))

fetch :: Config -> Maybe Options -> FetchContext Position -> EvidenceSnapshot Payload
      -> Acquisition Payload (Either FetchError (FetchResult Payload Position))
```

`startedAt` is one host-captured UTC instant for the invocation. It supports relative
backfill/retention windows without an ambient guest clock. `Position` is an ordinary
concrete plugin-defined type; the compiler derives its contract and verifies the
same type in context/result. Stateless connectors may keep the existing signatures;
they have no stored position. A connector needing invocation time but no provider
cursor can use a nullary position type. No kernel Graph deltaLink type exists.

The host stores checked position data in the ignored Dhall state document, separate
from evidence payloads. First acquisition or changed producer supplies `Nothing`.
Changed code/contract must never reuse an incompatible position. Replacing
the producer clears the old position together with old evidence on successful
publication; a failed replacement leaves the old stored capture untouched and
incompatible for new reads. A failed/cancelled/conflicting fetch does not advance
the position. Even a no-change fetch may publish a new position.

The stored position continues the previous sync; `evidence fetch --restart-sync`
passes `Nothing` once while retaining evidence for comparison, whereas `evidence clear`
deletes evidence and position. For stateless connectors restart is a reported no-op.
Provider pagination, cursor expiry/reset and endpoint-specific reconciliation are
plugin logic. Publish only the final successful continuation, not intermediate
page links. Treat stored position as private acquisition data: no normal history
display, logs, citation fields or recipe state. Recipe state and connector sync
positions have different owners and must not advance each other.

## Consequences and verification

Exercise the same generated guest API under GHC and MicroHs. Verify binary and
large-text downloads without bytes in guest download replies, zero-byte content,
status/header preservation, retry/cancellation, actual-size limits and UTF-8 failure.
Check reference discovery through nested contracts, hash/size integrity and refusal
of references outside the captured instance. A KB helper composing two plugin
reads must expose the correct local files without granting it acquisition.

Race publication, failed acquisition and blob reads across processes. Verify old
invocations remain readable, new invocations see latest, and cleanup removes
unreferenced/abandoned bytes without retaining history. Test surface file usability
after method return and explicit instance clearing.

Check positions across empty batches, pagination failure, local base conflict,
restart and producer changes. A cursor must never describe changes that were not
published. Fake Graph responses prove adapter behavior; live permissions and
provider identities require their own opt-in field proof.

Verify new/updated evidence with Truncated payloads, same-fingerprint restoration,
and truncation independently of recipe processing. Truncation releases blobs
without changing evidence fingerprints or recipe state; explicit source removal
still removes the entry. Check that shared blobs survive until their final Available
reference and active invocation are released.
