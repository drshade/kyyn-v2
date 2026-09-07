# 0016 — Local secrets and plugin-owned authentication

Status: Proposed implementation details. **Owner-established decision: a
plugin-independent, checkout-local per-KB key/value secret store, readable through a host
capability. Trusted plugins receive secret values and own authentication logic.
No kernel Connection entity or automatic credential injection.**

## Context

Keeping plugins free of native IO does not require hiding credentials from them
or moving provider-specific authentication into the kernel. The host supplies
storage and transport; authored programs decide how to use them. Ordinary typed
configuration and local secrets have different persistence needs, not different
plugin installation or approval lifecycles.

## Decision

Each KB in a local checkout has its own named secret values, independently of installed plugins. A secret
name is a lookup key, not a provider, account object or permission token. Plugins
can request a value by name; plugins and connector instances within that KB may
share the same key where useful. The same key in another KB is a separate local
setting: lookup does not fall back to a global/per-user store or search other KBs.
Secret values stay outside the accepted root, evolution workspaces and Git. Local setup
populates the selected KB's store without requiring a plugin or an evolution.
A Git clone carries configuration naming the required keys, not their values;
credentials are supplied locally for that KB. No cross-KB synchronization or
shared credential registry is required.
Different clones/worktrees of the same KB require their own local setup; logical
KB identity does not make their secret stores shared. If one repository contains
several KBs, scope each store by its KB directory within that checkout.

The **guest SDK** exposes a typed request, interpreted by the host:

```haskell
data Secrets a where
  GetSecret :: Text -> Secrets (Either SecretError Text)

data SecretError = SecretNotFound Text

getSecret :: Text -> Program Secrets (Either SecretError Text)
```

Compose `Secrets` with HTTP through the request-algebra composition in ADR 0009.
The value returned by `GetSecret` is ordinary text in guest memory. The plugin
constructs the appropriate header, token-exchange request or other provider-specific
authentication data and requests HTTP through its host capability. The host does
not infer how to inject it, classify the provider or select an authentication flow.

On the **host**, secret access belongs to plumbing. Its runner receives an explicit
local store scope for the explicitly selected KB from the composition root; the
SDK caller need not know a path or pass a second KB identity with every lookup:

```haskell
data SecretStore :: Effect where
  ReadSecret :: Text -> SecretStore m (Either SecretError Text)

runSecretStoreIO
  :: (IOE :> es, Failure :> es)
  => DirectoryScope -> Eff (SecretStore : es) a -> Eff es a
```

The generated adapter routes guest `GetSecret` to host `ReadSecret`. Missing keys
produce `SecretNotFound name` and an actionable setup message naming the key, never
the value. Authored code may handle this result; the normal convention is to
propagate a missing-key diagnostic through its declared plugin error rather than
swallow it or substitute an empty credential. Inaccessible/corrupt storage is an operational failure, not a missing
secret or empty successful value. Do not introduce per-plugin secret grants,
opaque credential handles or a provider-connection registry. The backing store
and local setup interface must work on the supported installation targets; no
automatic secret synchronization or enrollment state machine is implied.
The store lives in an ignored local directory belonging to the KB checkout,
never in tracked root/config files or captured evolution material. Removing that
checkout removes its locally stored secrets; another clone does not restore them.
The exact directory name, backing encoding/protection and setup-command spellings
remain implementation choices. Checkout-local scope does not itself select a
plaintext-at-rest policy or require a keychain integration. No cross-checkout
sharing or synchronization mechanism is part of this implementation.

### Configuration remains ordinary typed root data

Plugins advertise each connector type's configuration through a Haskell type in
the supported schema subset. A well-known file per plugin, such as
`root/plugins/config/microsoft.dhall` under the proposed ADR 0006 layout, holds
its named connector instances, not one
opaque plugin-defined configuration blob. RootStore owns its persistence/loading and
EvolutionStore captures proposed changes. The files belong to the accepted
repository snapshot and travel in Git, but are not fields in the KB-authored facts
type and do not require a heterogeneous `Root.plugins` value or an independent
configuration service. Kyyn owns the plugin/instance-name/type envelope from ADR
0015; the plugin owns each configuration payload's schema and meaning.
Upstream locations remain plugin installation metadata under ADR 0015.

Read and decode config as runtime data, not compiled literals. The host uses its
Dhall library and contracts derived from the plugin's Haskell configuration types;
Dhall is the config-file format, not a second schema authority. One file can hold
heterogeneous instances using a generated union of advertised connector types:

```text
List { name : Text, connector : < Mail : MailConfig | Meetings : MeetingsConfig | ... > }
```

This is the structural shape sketch; Kyyn generates the concrete Dhall type rather
than requiring the user to repeat the Haskell schemas. The selected union case
identifies the connector type and pairs it with the correctly typed payload; the
host decodes it into `ConnectorInstance`. No string containing nested Dhall or
generic unchecked config blob. Generated bindings supply the selected instance's
concrete config to the method, not the complete list. Use files from the selected
snapshot or captured evolution workspace, not changing ambient files during a call.
Malformed or structurally incompatible plugin configuration fails loading the
whole root, with a diagnostic locating the offending configuration. Do not skip
the broken instance, substitute defaults or return a partially usable root.
Repair the configuration files and retry loading. There is no partial-loading
model in the initial implementation. Successfully decoded config can still fail
its pure semantic validator; that rejects validation of the whole root and blocks
acceptance, not merely use of that connector. Missing local secrets remain a
separate invocation-time error, not malformed root configuration.
The pure config validator has this guest shape:

```haskell
validateConfig :: Config -> ValidationReport
```

The selected connector type's pure validator runs on each of its configured
instances during root checking, with diagnostics identifying plugin and instance.
It checks provider-specific combinations and values without fetching evidence,
accessing secrets or testing credentials. Health/login are separate effectful
plugin methods. Disk storage is owned by ADR 0006; it does not require Dhall
parsing inside the guest.

For example, a guest configuration can name the required secret:

```haskell
data MailConfig = MailConfig
  { mailbox   :: Text
  , secretKey :: Text
  }
```

The plugin requests `getSecret config.secretKey` and constructs its authenticated
request. No special `SecretRef` type or kernel-understood connection schema is
required. Reusing account configuration is ordinary plugin data/composition, not
a mandatory kernel concept. Changing a local secret does not mutate accepted
knowledge. An effectful evolution entry can invoke an acquisition plugin that
uses Secrets, but pure validation and transformation helpers cannot request live
secrets or providers. Secret values are not implicit candidate capture inputs.

Generic Web configuration display/editing can consume the checked record/list/
union/scalar structure without understanding `MailConfig`. It is not a prerequisite
for the initial persistence/invocation path. Do not generate secret-value fields
in root configuration or automatically capture secret responses into proposals.

### Authentication belongs to the integration

Plugin code implements provider-specific authentication and response handling
using Secrets, HTTP and other demonstrated host capabilities. Native libraries
still handle TLS, transport, filesystem access and document parsing. Authored
code never needs to implement those IO mechanisms itself. A static credential
lookup does not prove login or refresh support; test the actual flow before
claiming it. Additional secret operations need a concrete integration use case,
not speculative lifecycle constructors. Required user actions must be explicit,
not hidden interactive prompts inside scheduled work.

## Trust and consequences

Trusted plugins can read and disclose secret values they request. This is an
accepted consequence, not a sandbox guarantee. Routine host/protocol/field-report
traces omit all secret response values and all HTTP headers, URLs and bodies.
They may record operation identity, HTTP method/status, timings and byte counts;
the host must not classify plugin-constructed payloads as safe to log. Do not
promise to detect every secret a plugin
copies into an arbitrary result or diagnostic. Source review and ordinary authoring
discipline apply; there is no credential-containment or taint-tracking system.

Reject a kernel Connection model, automatic authentication injection, a closed
provider-authentication taxonomy and raw native IO in plugins. Host capability
boundaries remain explicit even when their results include sensitive values.

## Verification

Use fake secret/HTTP interpreters to prove retrieval, actionable missing-key errors,
storage failure, request construction and provider-error handling. Two connector
methods can read the same configured key without duplicated secret storage or
plugin-specific enrollment. Two KBs using the same key name can hold different values, and a missing key in
one must not resolve from the other. Both source and sink invocations use their
owning KB's store. Two checkouts of the same logical KB must not share values
implicitly, nor may two KB directories within one repository. A config change survives evolution acceptance/reopen;
a fresh clone retains config and reports the absent local secret when requested.
Routine host logs and field traces must omit secret response values and HTTP
headers, URLs and bodies, including query strings that may contain credentials.
Real integration tests use opt-in local credentials, never committed fixtures.
