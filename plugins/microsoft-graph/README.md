# Microsoft Graph calendar

The `Calendar` source synchronizes one user's default calendar within a configured
date window, including recurring occurrences. Event IDs
identify evidence; Graph's `changeKey` identifies updates. The `event` method reads
the latest captured event without contacting Microsoft.

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
      | DeviceCode : { tenant : Text, clientId : Text, tokenKey : Text }
      >
let Connector =
      < Calendar :
          { auth : Auth, mailbox : Text, calendarId : Optional Text, sharedCalendar : Bool
          , windowStart : Text, windowEnd : Text }
      >
in [ { name = "work"
     , binding = "workCalendar"
     , connector = Connector.Calendar
         { auth = Auth.DeviceCode
             { tenant = "YOUR-TENANT-ID"
             , clientId = "YOUR-APP-CLIENT-ID"
             , tokenKey = "graph-work-refresh"
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
login. `sharedCalendar = True` requests `Calendars.Read.Shared` instead; the signed-in
user must also have access to the configured mailbox/calendar. Changing delegated
scope requires running login again.
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

## Verification and provider documentation

The `graph-calendar` test compiles the actual adapters under GHC and MicroHs and
uses a recording provider for authentication, token rotation, pagination, throttling,
delta continuation, duplicate IDs, removals, resets and failed pages. Live Entra consent/tenant policy remains an opt-in
test with the user's own app and account.

- [Calendar delta synchronization](https://learn.microsoft.com/en-us/graph/api/event-delta?view=graph-rest-1.0)
- [Event IDs, changeKey and lastModifiedDateTime](https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0)
- [Device-code authentication](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Application authentication](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [Shared calendar access](https://learn.microsoft.com/en-us/graph/outlook-get-shared-events-calendars)
