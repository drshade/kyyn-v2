# Microsoft Graph

This plugin provides `Calendar`, `Mail`, `Meetings` and `Files` source connectors, with shared Graph
authentication. Use `plugin guide microsoft-graph` to read this guide from an
installed package.

## Calendar

The `Calendar` source synchronizes one user's default calendar within a configured
date window, including recurring occurrences. Event IDs
identify evidence; Graph's returned ETag (or `changeKey`) identifies updates. The `event` method reads
the latest captured event without contacting Microsoft. Descriptive fields omitted
by Graph are empty; absent participant lists are empty and absent flags are false.

Each attendee includes name, address and optional `status`; the event's optional
`responseStatus` is the configured mailbox owner's response. A status contains
Graph's `response` text (`accepted`, `tentativelyAccepted`, `declined`, `none`,
`notResponded` or `organizer`) and optional response `time`. Missing/null status
is absent, not an inferred response. Unusable response data is also absent; an
unusable timestamp does not discard a valid response. Provider response strings
are preserved. Graph's `none` with time `0001-01-01T00:00:00Z` is a placeholder,
not an actual reply timestamp.

## Install and configure

From this committed checkout, with an initialized KB:

```sh
kyyn-v2 --kb /path/to/kb evolution new add-calendar
kyyn-v2 --kb /path/to/kb plugin install --evolution EVOLUTION --from /path/to/kyyn-v2/plugins/microsoft-graph
kyyn-v2 --kb /path/to/kb plugin connector schema show microsoft-graph --evolution EVOLUTION
```

Create `target/plugins/config/microsoft-graph.dhall` inside the evolution directory
printed by `evolution new`. Use the discovered schema to check this configuration:

```dhall
let Auth =
      < ClientSecret : { tenant : Text, clientId : Text, secretKey : Text }
      | DeviceCode : { tenant : Text, clientId : Text, tokenKey : Text, scopes : List Text }
      >
let Connector =
      < Calendar :
          { auth : Auth, mailbox : Text, calendarId : Optional Text, sharedCalendar : Bool
          , windowStart : Text, windowEnd : Text }
      | Mail :
          { auth : Auth, mailbox : Text
          , folders : List < WellKnownFolder : Text | FolderPath : Text >
          , retentionDays : Integer }
      | Meetings : { auth : Auth, retentionDays : Integer }
      | Files :
          { auth : Auth
          , scope : < SiteLibrary : { site : Text, library : Text }
                    | OneDrive : { user : Text } | SharedUrl : { url : Text } >
          , itemPath : Text, includeGlobs : List Text }
      >
in [ { name = "work"
     , binding = "workCalendar"
     , connector = Connector.Calendar
         { auth = Auth.DeviceCode
             { tenant = "YOUR-TENANT-ID"
             , clientId = "YOUR-APP-CLIENT-ID"
             , tokenKey = "graph-work-refresh"
             , scopes = [ "Calendars.Read" ]
             }
         , mailbox = "you@example.com"
         , calendarId = None Text
         , sharedCalendar = False
         , windowStart = "2026-01-01T00:00:00Z"
         , windowEnd = "2027-01-01T00:00:00Z"
         }
     } ]
```

`mailbox` is explicit for both authentication modes. `calendarId = None Text`
selects its default calendar; named calendars are not supported by this delta API.
Choose explicit `windowStart` and `windowEnd` instants for the meeting times you
want to capture. The window does not slide automatically. Different instances may
use different mailboxes, windows and secret keys.

Check, review and accept the evolution:

```sh
kyyn-v2 --kb /path/to/kb evolution check EVOLUTION
kyyn-v2 --kb /path/to/kb evolution show EVOLUTION
kyyn-v2 --kb /path/to/kb evolution ready EVOLUTION
kyyn-v2 --kb /path/to/kb evolution accept EVOLUTION
```

## Authenticate

For **DeviceCode**, register a Microsoft Entra public client with device-code flow
enabled and delegated `Calendars.Read`. Run:

```sh
kyyn-v2 --kb /path/to/kb plugin connector login microsoft-graph work
```

Follow the displayed Microsoft sign-in instructions. The refresh token is saved
under `tokenKey` in this KB's ignored local secret store. Fetch refreshes the access
token and persists any replacement refresh token. It never starts an interactive
login. Both login and refresh request the whole configured `scopes` list, plus
`offline_access`. Use the same tenant, client ID, token key and scope list across
instances that share a login. For example, `[ "Calendars.Read", "Mail.Read" ]`
requests consent for Calendar and Mail together; no additional permissions are
requested automatically. Scopes may be short names or Graph-qualified names
such as `https://graph.microsoft.com/Calendars.Read`.

`sharedCalendar = True` requires `Calendars.Read.Shared` or `Calendars.ReadWrite.Shared`
in that list (case-insensitive); the signed-in
user must also have access to the configured mailbox/calendar. Adding delegated
scopes requires running login again. Configuration checks shared-calendar scope
without checking remote consent; own-calendar permission is checked by Graph.
`sharedCalendar` only affects delegated DeviceCode authentication; ClientSecret
uses the application's consented permissions.

For **ClientSecret**, grant and consent the app's application `Calendars.Read`
permission and replace `auth` with:

```dhall
Auth.ClientSecret
  { tenant = "YOUR-TENANT-ID", clientId = "YOUR-APP-CLIENT-ID", secretKey = "graph-app-secret" }
```

Set the client secret without putting it in source or shell history:

```sh
kyyn-v2 --kb /path/to/kb secret set graph-app-secret
kyyn-v2 --kb /path/to/kb plugin connector login microsoft-graph work
```

Application login checks token acquisition; calendar access is checked by fetch.
Application permissions can cover many mailboxes: configure their access in Entra/
Exchange appropriately. No access token is persisted.

## Fetch and inspect

```sh
kyyn-v2 --kb /path/to/kb evidence fetch microsoft-graph work
kyyn-v2 --kb /path/to/kb evidence list microsoft-graph work
kyyn-v2 --kb /path/to/kb plugin connector method execute microsoft-graph work event --input '"EVENT-ID"'
```

The first fetch reads the configured window. Later fetches use Graph's saved delta
link to request changes. All pages must succeed before evidence and the new position
are saved together. Removed entries disappear from the captured scope. An expired
provider position triggers a fresh baseline.

The saved link continues the previous sync even if you change the instance config.
To start fresh after changing its mailbox or window, restart the sync while keeping
captured evidence for comparison:

```sh
kyyn-v2 --kb /path/to/kb evidence fetch microsoft-graph work --restart-sync
```

HTTP 429/503 with numeric `Retry-After` pauses before retrying (at least one second).
`evidence clear microsoft-graph work` instead deletes evidence and its position;
the next fetch reports everything as new.
Without a usable delay, fetch reports a retry-later error. Ctrl-C interrupts waits.

## Mail

Add a `Mail` instance using the same `Connector` union above. For example, replace
the instance in the configuration with:

```dhall
{ name = "sent", binding = "sentMail"
, connector = Connector.Mail
    { auth = Auth.DeviceCode
        { tenant = "YOUR-TENANT-ID", clientId = "YOUR-APP-CLIENT-ID"
        , tokenKey = "graph-work-refresh", scopes = [ "Calendars.Read", "Mail.Read" ] }
    , mailbox = "you@example.com"
    , folders = [ < WellKnownFolder : Text | FolderPath : Text >.WellKnownFolder "sentitems" ]
    , retentionDays = +90
    }
}
```

`WellKnownFolder` accepts Graph names such as `inbox` and `sentitems`.
`FolderPath "Projects/Client"` resolves exact display names from the mailbox's
top-level folders; missing or ambiguous names fail the fetch. Multiple folders
share one mailbox and capture. Their configuration order decides the first-seen
folder when the same message appears in more than one. DeviceCode needs delegated
`Mail.Read` (or appropriate shared-mail permissions); ClientSecret needs consented
application mail-reading permission. Login again after changing delegated scopes.

After checking and accepting the configuration:

```sh
kyyn-v2 --kb /path/to/kb plugin connector login microsoft-graph sent
kyyn-v2 --kb /path/to/kb evidence fetch microsoft-graph sent
kyyn-v2 --kb /path/to/kb evidence list microsoft-graph sent
kyyn-v2 --kb /path/to/kb plugin connector method execute microsoft-graph sent message --input '"MESSAGE-ID"'
kyyn-v2 --kb /path/to/kb plugin connector method execute microsoft-graph sent body --input '"MESSAGE-ID"'
kyyn-v2 --kb /path/to/kb plugin connector method execute microsoft-graph sent attachments --input '"MESSAGE-ID"'
```

The first fetch starts 30 days before invocation. To choose another initial boundary,
use `--options '{ since = Some "2026-09-01T00:00:00Z" }'`. Later fetches follow saved
folder delta links; supplying `since` again is refused. An expired delta link
re-enumerates from that folder's original boundary, skipping already captured IDs.
Changing mailbox or wanting to recapture messages requires `evidence clear` and
a new fetch; clear removes the local capture, including its attachment bytes.

Mail captures each immutable message ID once, including drafts. Later edits,
read flags, moves and upstream deletions do not change captured mail. The plain-text
body preserves quoted correspondence; no second raw parent-message copy is stored.
Byte-backed attachments (including inline files and attached messages) are stored
locally and returned as `BlobRef`s. CLI results containing blobs include local paths.
Linked attachments instead contain their Graph attachment resource URI and metadata,
not the target cloud-file URL. All folder pages and attachment downloads must succeed
before the fetch is published.

`retentionDays` must be nonnegative; zero retains identities but truncates messages
received before the fetch start immediately. During fetch it truncates payloads older than
that age by received time, reclaiming unreferenced attachment bytes. Evidence IDs
and fingerprints remain, so truncation does not cause repeated capture. Reading a
truncated message reports that its payload is unavailable. Retention is independent
of whether any recipe has processed a message.

## Meetings: transcripts and attendance

`Meetings` captures artifacts from recently ended Teams meetings discovered in
the credential's calendar scope. Each transcript and attendance report is a separate
evidence item, including multiple artifacts from recurring meetings. The connector
keeps all returned artifacts; recipes decide how they relate to calendar facts.

Add a Meetings instance using the `Connector` union above:

```dhall
{ name = "meetings", binding = "meetingArtifacts"
, connector = Connector.Meetings
    { auth = Auth.DeviceCode
        { tenant = "YOUR-TENANT-ID", clientId = "YOUR-APP-CLIENT-ID"
        , tokenKey = "graph-meetings-refresh"
        , scopes = [ "User.Read", "Calendars.Read", "OnlineMeetings.Read"
                   , "OnlineMeetingTranscript.Read.All", "OnlineMeetingArtifact.Read.All" ] }
    , retentionDays = +90
    }
}
```

DeviceCode uses the signed-in user's `/me` endpoints. There is no configured
user ID and no tenant user enumeration. The delegated permissions above require
appropriate tenant consent; personal Microsoft accounts are unsupported. When
sharing a refresh-token key with other connectors, use the same complete scope
list on each instance. Run login again after changing scopes.

ClientSecret lists all tenant users through paginated `/users?$select=id`, then
reads each user's calendar. Its application requires consented `User.Read.All`,
`Calendars.Read`, `OnlineMeetings.Read.All`, `OnlineMeetingTranscript.Read.All`
and `OnlineMeetingArtifact.Read.All`, plus the Teams application access policy
for users whose meeting artifacts it may access. No trainer list is configured.
Calendar access is separately governed by Exchange/Graph permissions: Teams
policy controls meeting access, not the directory or calendar listing.

Application discovery keeps events marked `isOrganizer` so a meeting is discovered
under its organizer rather than every attendee. Delegated discovery keeps attended
meetings too. This is our discovery rule, not a claim that all Graph application
lookups are organizer-only: the [Get onlineMeeting documentation](https://learn.microsoft.com/en-us/graph/api/onlinemeeting-get)
explicitly permits invited attendees for meeting-ID lookup and does not establish
an organizer-only rule for every lookup. Calendar discovery preserves attendance
capture; the application-only [getAllTranscripts API](https://learn.microsoft.com/en-us/graph/api/onlinemeeting-getalltranscripts)
is not used, and its applicability to the intended per-user access policy has not
been established here.

A denied application calendar skips that user. Recognized 404 mailbox codes
`MailboxNotEnabledForRESTAPI` and `MailboxNotSupportedForRESTAPI` skip users without
a Graph-accessible calendar. Other 404s and unexpected errors remain fatal.
Directory enumeration must complete: a denial or failure on any user-list page
fails the entire fetch. Expect at least one calendar request per tenant user,
plus calendar pages and organizer meeting/artifact requests. Calls are sequential
and use shared Graph throttling handling. Use an explicit one-week `since` for the
pilot; the connector's normal initial window remains 30 days.

Unsupported providers, missing join URLs, zero/multiple resolution matches and
incomplete meeting-reference metadata remain per-meeting skips, recorded in
`skippedMeetings`. A meeting-resolution 403 skips that meeting. Transcript and
attendance requests run independently; a 403 skips only the denied collection or
artifact. A denial on a later page discards that incomplete collection. Already
captured artifact IDs are not downloaded again; duplicate artifacts across user
contexts publish once. An alternative context can supply a capture denied in the
first context.

The successful sync position records `deniedUsers` (distinct user contexts with
at least one 403) and `unavailableUsers` (recognized unavailable mailboxes).
A 403 does not prove that Teams policy was the cause. Application mode leaves
`deniedRequests` empty to avoid storing many user URLs; delegated mode retains
its artifact-denial URLs. These are diagnostics for the latest successful run,
not a permanent exclusion list or CLI warnings. An empty/partially accessible
successful run advances the boundary. Delegated calendar-discovery denials,
authentication failures, malformed responses and unexpected errors remain fatal.

After checking and accepting the configuration:

```sh
kyyn-v2 --kb /path/to/kb plugin connector login microsoft-graph meetings
kyyn-v2 --kb /path/to/kb evidence fetch microsoft-graph meetings
kyyn-v2 --kb /path/to/kb evidence list microsoft-graph meetings
kyyn-v2 --kb /path/to/kb plugin connector method execute microsoft-graph meetings artifact --input '"ARTIFACT-ID"'
```

The initial fetch covers the preceding **30 days**. Later fetches start **one day
before the last successful fetch's acquisition start**, through now. This catches
late artifacts while covering gaps between runs without rescanning all 30 days.
Failed fetches do not advance the saved boundary. A successful run advances it even
if there are no new artifacts or some artifact requests returned 403.

To backfill or recheck older meetings (including after permissions change), use
`--options '{ since = Some "2026-01-01T00:00:00Z" }'`. This overrides the boundary
on both initial and subsequent fetches. The next ordinary fetch uses the usual
one-day overlap from that successful run. Artifacts arriving later than the overlap
can be missed until an explicit backfill. Skipped 403 requests are retried only if
their meetings fall in the selected window; there is no background retry loop.

The connector deduplicates repeated join URLs and captures each artifact identity
once. Provider deletion does not delete captured artifacts. Transcript `created`
is Graph's transcript creation timestamp, not an inferred meeting start. Attendance
`started` and `ended` are the report's session times; participant identities and all
returned attendance intervals are retained. Transcript VTT bytes are stored as a
`BlobRef`; CLI blob results include a local path. The `artifact` method reads only
captured data and makes no provider requests.

Each published artifact must have complete metadata and content. A 403 skips the
affected request as described above; other page or download failures prevent
publication of the whole fetch. Graph returns at most the latest 50 attendance reports for a
meeting; pagination cannot recover reports outside that provider limit. Only
calendar-backed Teams online meetings are discovered, not standalone calls or
virtual-event endpoints. Tenant settings may prohibit transcripts or
speaker-attributed VTT; a 403 refusal is recorded and skipped. There is no silent change to
an unattributed transcript format.

Retention uses each artifact's end time. A nonnegative `retentionDays` controls
payload truncation during fetch; zero truncates artifacts ended before that fetch
started. Identities and fingerprints remain, and old artifacts are not downloaded
again. Recurring-meeting listings can include sessions older than the discovery
window. On first capture, their content is downloaded before retention is applied,
so an old transcript may be downloaded and immediately truncated. Reading a
truncated artifact reports that its payload is unavailable.
`evidence clear microsoft-graph meetings` removes the capture and permits recapture.

## Verification and provider documentation

The `graph-calendar` test compiles the actual adapters under GHC and MicroHs and
uses a recording provider for authentication, token rotation, pagination, throttling,
delta continuation, duplicate IDs, removals, resets and failed pages. Live Entra consent/tenant policy remains an opt-in
test with the user's own app and account.
The `graph-mail` test exercises recorded-provider acquisition under both compilers,
including capture-once, attachment retries/failure, retention and fingerprint parity.
The `graph-meetings` test covers initial/overlap/backfill windows and independent 403 handling, recurring-meeting discovery,
artifact identity, pagination, retention, capture-once, delegated identity, failure
paths and captured reads under both compilers. Live tenant access is not established
by these recorded-provider tests.

- [Calendar delta synchronization](https://learn.microsoft.com/en-us/graph/api/event-delta?view=graph-rest-1.0)
- [Event IDs, changeKey and lastModifiedDateTime](https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0)
- [Attendee and mailbox-owner response status](https://learn.microsoft.com/en-us/graph/api/resources/responsestatus?view=graph-rest-1.0)
- [Device-code authentication](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Application authentication](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [Shared calendar access](https://learn.microsoft.com/en-us/graph/outlook-get-shared-events-calendars)
- [Mail delta synchronization](https://learn.microsoft.com/en-us/graph/api/message-delta?view=graph-rest-1.0)
- [Attachment content](https://learn.microsoft.com/en-us/graph/api/attachment-get?view=graph-rest-1.0)
- [Linked attachment metadata](https://learn.microsoft.com/en-us/graph/api/resources/referenceattachment?view=graph-rest-1.0)

- [Resolve online meetings by join URL](https://learn.microsoft.com/en-us/graph/api/onlinemeeting-get?view=graph-rest-1.0)
- [Transcript metadata and permissions](https://learn.microsoft.com/en-us/graph/api/onlinemeeting-list-transcripts?view=graph-rest-1.0)
- [Transcript content and tenant controls](https://learn.microsoft.com/en-us/graph/api/calltranscript-get?view=graph-rest-1.0)
- [Attendance report listing and limits](https://learn.microsoft.com/en-us/graph/api/meetingattendancereport-list?view=graph-rest-1.0)
- [Attendance record pages](https://learn.microsoft.com/en-us/graph/api/attendancerecord-list?view=graph-rest-1.0)

## SharePoint and OneDrive files

`Files` captures a single file or every ordinary file below a selected folder,
including subfolders. Each fetch lists the selection again and follows every page.
There is no delta cursor, age window or fetch-options record.

Use the `Files` alternative in the connector schema above. For example:

```dhall
Connector.Files
  { auth = Auth.DeviceCode
      { tenant = "YOUR-TENANT-ID", clientId = "YOUR-APP-CLIENT-ID"
      , tokenKey = "graph-files-refresh", scopes = [ "Files.Read.All" ] }
  , scope =
      < SiteLibrary : { site : Text, library : Text }
      | OneDrive : { user : Text } | SharedUrl : { url : Text }
      >.SiteLibrary { site = "YOUR-GRAPH-SITE-ID", library = "Documents" }
  , itemPath = "Reports"
  , includeGlobs = [ "**/*.pdf", "**/*.docx" ]
  }
```

`SiteLibrary.site` is a Graph site ID; `library` is its drive ID or exact library
name. Ambiguous names fail with guidance to use an ID. `OneDrive.user` accepts a
user ID/email, or `me` with delegated authentication. `SharedUrl.url` accepts a
sharing URL for a file or folder. It is resolved through Graph's shares API;
ordinary browser navigation URLs are not automatically converted to sharing links.

`itemPath` is relative to the library/OneDrive root, or to the folder identified
by a sharing URL. Empty selects that root or shared item itself. If the sharing
URL identifies a file, leave `itemPath` empty. Paths use forward slashes and
unescaped names; the connector encodes them for Graph. The configured path is
resolved every time: if you rename or move the selected root, update its path.
A missing root fails the fetch and preserves earlier evidence.

Globs match case-sensitive relative file paths below the selected folder.
`*` and `?` stay within a path segment; `**` crosses directories, and `**/` also
matches zero directories. An empty list includes every file. For a single-file
selection, the relative path is its filename. Globs filter files; all folders
are still traversed.

Graph permissions depend on the scope and account. Library and file APIs support
read permissions such as delegated `Files.Read.All` or application
`Files.Read.All`/`Sites.Read.All`. The shares API documents `Files.ReadWrite`
(delegated) or `Files.ReadWrite.All` (application) as its least permissions even
for resolving a shared item. The connector performs reads only. Consent to the
appropriate scopes and rerun connector login after changing them. Use a separate
tokenKey or keep scopes consistent for instances sharing a refresh token, and
run refreshes sequentially when sharing that key.

Accept the evolution, then run (substitute your configured instance name):

```sh
kyyn-v2 plugin connector login microsoft-graph files
kyyn-v2 evidence fetch microsoft-graph files
kyyn-v2 evidence list microsoft-graph files
kyyn-v2 plugin connector method execute microsoft-graph files file --input '"DRIVE-ID/ITEM-ID"'
```

Evidence IDs combine escaped drive and item IDs; copy them from `evidence list`.
Names and relative paths are payload metadata, so renames and moves preserve
identity when Graph keeps the IDs. Removed files and files moved outside the
selection leave the capture. Empty successful listings remove prior evidence.
Concurrent upstream moves can make a file temporarily absent; a later complete
fetch adds it again. Repeated file identities keep the first
observed occurrence, and repeated folders are visited once. OneNote notebooks
and other packages, remote shortcuts, and other non-file/folder items are skipped.
To capture a shortcut target, configure its actual drive or sharing URL directly.
There is no retained skip log or sync position.

The payload includes metadata and a content blob, not extracted document text.
Size is the actual stored byte count; it need not equal Graph’s listed size.
Missing MIME types use application/octet-stream.
A present unchanged content tag reuses the existing blob; metadata-only
changes update the payload without downloading identical bytes. Missing tags or
truncated payloads require downloading content. `modifiedBy` is the provider's
user display name, otherwise application/device display name, or empty when absent.
The `file` method reads captured metadata and its blob reference without networking.

Expect one metadata request per folder page, scope-resolution requests, and one
streamed download per new/changed file. There is no connector-specific size cap:
selected files are downloaded in full to local blob storage, so choose a narrow
folder/glob selection and allow enough local disk space. Unchanged files with
usable content tags are not downloaded again. Graph throttling follows the shared
plugin Retry-After handling. Failed pages or downloads leave the prior capture
unchanged; a listing is not an upstream transaction across concurrent edits.

Provider references: [children listing](https://learn.microsoft.com/en-us/graph/api/driveitem-list-children),
[shared items](https://learn.microsoft.com/en-us/graph/api/shares-get), and
[content download](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content).
