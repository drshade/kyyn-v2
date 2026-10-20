# Salesforce query evidence

`Query` runs a saved SOQL SELECT and captures one evidence item per returned record.
Every fetch runs the whole query. New or changed records enter the capture; records
no longer returned leave it. This does not delete curated KB facts or prove that a
record was deleted in Salesforce.

## Configure a query

Install `first-party/salesforce` into an evolution and inspect its configuration:

```sh
kyyn-v2 plugin install --evolution ID first-party/salesforce
kyyn-v2 plugin connector schema show salesforce --evolution ID
```

Set `target/plugins/config/salesforce.dhall` in that evolution. For example:

```dhall
let Auth =
      < ClientSecret : { clientId : Text, secretKey : Text }
      | DeviceCode : { clientId : Text, tokenKey : Text }
      >
let Connector =
      < Query :
          { instanceUrl : Text, auth : Auth, apiVersion : Text
          , query : Text, idField : Text }
      >
in [ { name = "pipeline"
     , binding = "pipeline"
     , connector = Connector.Query
         { instanceUrl = "https://YOUR-DOMAIN.my.salesforce.com"
         , auth = Auth.DeviceCode
             { clientId = "YOUR-APP-CONSUMER-KEY", tokenKey = "salesforce-refresh" }
         , apiVersion = "v62.0"
         , query = "SELECT Id, Name, Amount, StageName FROM Opportunity WHERE IsClosed = false"
         , idField = "Id"
         }
     }
   ]
```

Use an API version enabled by your org; `v62.0` is an example, not automatic
version selection. `instanceUrl` is your exact HTTPS My Domain origin, without a
trailing slash, path, query or fragment. Sandbox My Domains work the same way.

The query must return a nonempty string in the configured top-level `idField`,
unique across its complete result. Include `Id` in ordinary queries. You can choose
another field for a custom projection, but it must supply stable unique identities.
Missing, blank, numeric or duplicate identities fail the whole fetch. There is no
row-number fallback. Aggregate queries without a suitable identity are unsupported.

Several named Query instances can share authentication settings and a secret key
while running different queries. Each instance has independent evidence. When
DeviceCode instances share a tokenKey, run their logins and fetches sequentially:
concurrent refreshes can race if the org rotates refresh tokens.

Check, ready and accept the evolution before login or fetch:

```sh
kyyn-v2 evolution check ID
kyyn-v2 evolution ready ID
kyyn-v2 evolution accept ID
```

## Sign in

For `DeviceCode`, enable the Salesforce app's device flow and `api` and
`refresh_token` scopes, then run:

```sh
kyyn-v2 plugin connector login salesforce pipeline
```

Follow the displayed verification URL and code. The refresh token is stored under
`tokenKey` in the KB's local secret store; later fetches refresh access and persist
rotated refresh tokens. Device login can depend on your org's current app and
OAuth policies; a rejected login is an error, not a switch to another auth mode.

For unattended use, configure Salesforce client credentials and its integration
Run As user, with the API, object, field and record access needed by the query.
Replace the auth value with:

```dhall
Auth.ClientSecret
  { clientId = "YOUR-APP-CONSUMER-KEY", secretKey = "salesforce-client-secret" }
```

Store the secret with `kyyn-v2 secret set salesforce-client-secret` using its hidden
prompt. Login for this mode checks token acquisition; the fetch checks query access.
Client secrets and refresh tokens never belong in committed configuration. Both
authentication modes use the configured My Domain for OAuth and query requests.

## Fetch and read

```sh
kyyn-v2 evidence fetch salesforce pipeline
kyyn-v2 evidence list salesforce pipeline
kyyn-v2 plugin connector method execute salesforce pipeline record --input '"RECORD-ID"'
```

The captured `Record` contains `recordId` and `json`. JSON retains all returned
fields, including custom fields, arrays, relationship objects and null values.
Object keys have a deterministic order; array order and exact decimal/integer
values are preserved. Equivalent JSON key order or numeric spelling does not
create updates. The source reference is the configured query URL. Changing that
query URL changes the fingerprint even for otherwise identical returned records.
Changing apiVersion therefore updates every returned record; Salesforce may also
include that version in each record’s attributes.url.
The `record` method only reads captured evidence; it makes no provider request.

There is no lookback, retained query cursor, or fetch-options record. Follow-up
fetches rerun the configured query and compare its complete result with the prior
capture. An empty successful result removes all prior evidence for this instance.
Every query page must succeed before any updates or removals can publish. A 403,
malformed response, inconsistent count, invalid continuation or failed page leaves
the prior capture intact. Bounded throttling retries honor numeric Retry-After
values up to five minutes; exhausted retries fail the fetch.

Nested relationship results are retained as returned only when complete. If a
child collection requires its own pagination, the fetch fails with guidance to
query the child object separately. Bulk API, automatic query rewriting, Salesforce
writes and automatic schema discovery are not part of this connector.

## Verification and provider documentation

`salesforce-query` exercises generated fetch/login/read adapters under GHC and
MicroHs with recorded providers. `tools/test-salesforce-install.mjs` installs the
actual source through the CLI and checks configuration and method discovery.
Neither test uses real Salesforce credentials or establishes live org access.

- [SOQL query and pagination](https://developer.salesforce.com/docs/platform/api-rest/guide/dome-query.html)
- [Device flow](https://help.salesforce.com/s/articleView?id=remoteaccess_oauth_device_flow.htm&language=en_US&type=5)
- [Client credentials and integration users](https://developer.salesforce.com/blogs/2024/02/invoke-rest-apis-with-the-salesforce-integration-user-and-oauth-client-credentials)
