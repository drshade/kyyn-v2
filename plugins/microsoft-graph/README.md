# Microsoft Graph calendar

The `Calendar` source reads one user's default or named calendar. It fetches single
events and recurring-series masters, not expanded recurrence instances. Event IDs
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
          { auth : Auth, mailbox : Text, calendarId : Optional Text, sharedCalendar : Bool }
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
         }
     } ]
```

`mailbox` is explicit for both authentication modes. `calendarId = None Text`
selects its default calendar; use `Some "ID"` for a named calendar. Different
instances may use different mailboxes/calendars and secret keys.

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

An unfiltered fetch reads every page and emits additions, updates and removals.
A failed page publishes nothing. Recurring series are not expanded; a listing
is not a transactionally frozen view of a changing calendar.

Optional inclusive last-modified bounds restrict upserts:

```sh
kyyn-v2 --kb /path/to/kb evidence fetch microsoft-graph work --options \
  '{ modifiedFrom = Some "2026-09-01T00:00:00Z", modifiedTo = None Text }'
```

Bounds accept calendar dates with seconds, optional fractional seconds, and `Z`
or a numeric `+HH:MM`/`-HH:MM` offset. They refer to when an item changed, not when
the meeting occurs. Both empty bounds select all upserts. Every fetch still downloads
the full listing and detects removals against that whole list, never against only
the selected upserts. Existing items outside the bounds remain captured. There is
no automatic timestamp watermark; run without bounds to capture all current changes.

HTTP 429/503 with numeric `Retry-After` pauses before retrying (at least one second).
Without a usable delay, fetch reports a retry-later error. Ctrl-C interrupts waits.

## Verification and provider documentation

The `graph-calendar` test compiles the actual adapters under GHC and MicroHs and
uses a recording provider for authentication, token rotation, pagination, throttling,
date bounds and failed pages. Live Entra consent/tenant policy remains an opt-in
test with the user's own app and account.

- [Calendar events and recurrence semantics](https://learn.microsoft.com/en-us/graph/api/calendar-list-events?view=graph-rest-1.0)
- [Event IDs, changeKey and lastModifiedDateTime](https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0)
- [Device-code authentication](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Application authentication](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [Shared calendar access](https://learn.microsoft.com/en-us/graph/outlook-get-shared-events-calendars)
