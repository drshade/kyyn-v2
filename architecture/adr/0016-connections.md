---
id: 0016
title: 'Local secrets, typed configuration and named connector bindings'
status: proposed
date: 2026-09-24
---
# Local secrets, typed configuration and named connector bindings

Basis: **owner-established decision: a
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

On the **host**, secret access belongs to plumbing. Its runner receives an explicit
local store scope for the explicitly selected KB from the composition root; the
SDK caller need not know a path or pass a second KB identity with every lookup:

```haskell
data SecretStore :: Effect where
  ReadSecret :: SecretName -> SecretStore m (Either SecretError Text)
  WriteSecret :: SecretName -> Text -> SecretStore m ()
  ListSecretNames :: SecretStore m [SecretName]
  RemoveSecret :: SecretName -> SecretStore m Bool

data SecretError = SecretNotFound SecretName

runSecretStoreIO
  :: (IOE :> es, Failure :> es, DhallHandling :> es)
  => DirectoryScope -> Eff (SecretStore : es) a -> Eff es a
```

Missing keys
produce `SecretNotFound name` and an actionable setup message naming the key, never
the value. Calling code may handle this result; the normal convention is to
propagate a missing-key diagnostic through its declared error rather than
swallow it or substitute an empty credential. Inaccessible/corrupt storage is an operational failure, not a missing
secret or empty successful value. Do not introduce per-plugin secret grants,
opaque credential handles or a provider-connection registry. The backing store
and local setup interface must work on the supported installation targets; no
automatic secret synchronization or enrollment state machine is implied.
The store lives in an ignored local directory belonging to the KB checkout,
never in tracked root/config files or captured evolution material. Removing that
checkout removes its locally stored secrets; another clone does not restore them.

### Local storage and CLI

Store each value as a hermetic Dhall `Text` literal at
`.kyyn/secrets/<name>.dhall`, relative to the selected KB directory. This is
**plaintext at rest**, with ordinary filesystem permissions, not encrypted storage
or an OS keychain. Kyyn does not manage permissions or impose owner-only modes.
Install an ignore rule before writing any value. Root and evolution capture must
not include this directory. A Git clone does not back up secrets.

`SecretName` is a nonempty ASCII name containing letters, digits, hyphens and
underscores. It identifies one file component, never a relative path. Per-key
replacement makes unrelated keys independent; simultaneous writes to the same
key use ordinary last-writer-wins local configuration semantics.

```text
kyyn-v2 --kb PATH secret set NAME [VALUE]
kyyn-v2 --kb PATH secret list
kyyn-v2 --kb PATH secret show NAME
kyyn-v2 --kb PATH secret remove NAME
```

`set` uses the supplied argument verbatim. When omitted, it reads a hidden single
line from an interactive terminal, or UTF-8 text from standard input when piped.
For stdin, remove one final LF (and its preceding CR, if present)
so ordinary line-oriented shell input does not add a credential character;
preserve all other whitespace. The CLI refuses empty input without replacing an
existing value, so accidentally pressing Enter does not install a broken
credential. The store itself distinguishes an empty value from an absent key;
it does not validate provider-specific credential formats.
An argument value can appear in shell history and process listings; stdin is the
alternative when that matters. Empty values are refused on all three CLI paths.
`list` returns sorted names
only. `show` returns a masked value: preserve the first four characters for values
longer than eight characters and replace each remaining character with `*`;
fully mask shorter values. The displayed length is the actual character count,
useful for spotting truncated input. Human and JSON results use the same masking;
neither prints the complete secret. `remove` reports whether a key existed.
These operations require a selected KB directory, not a valid schema, a guest
compiler, an installed plugin or an evolution.

Storage decoding errors must not print the malformed document or parser excerpts;
report the operation and key instead. Routine success output likewise contains
only names, except for the explicit masked `show` result. Do not derive a logging
representation that prints a stored value.
The host capability can be interpreted by a recording handler without filesystem
access. Install it only in compositions that need secret access; no ambient store
or universal handler is introduced.

The first implementation exposes this host store and local setup commands.
Guest request algebras are introduced with their actual consumers, not as unused
SDK constructors. An integration implemented in a host handler reads its credential
there, without automatic credential injection or a kernel-owned authentication
workflow.

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
List { name : Text, binding : Text, connector : < Mail : MailConfig | Meetings : MeetingsConfig | ... > }
```

This is the structural shape sketch; Kyyn generates the concrete Dhall type rather
than requiring the user to repeat the Haskell schemas. The selected union case
identifies the connector type and pairs it with the correctly typed payload; the
host decodes it into `ConnectorInstance`. No string containing nested Dhall or
generic unchecked config blob. Generated bindings supply the selected instance's
concrete config to the method, not the complete list. Use files from the selected
snapshot or captured evolution workspace, not changing ambient files during a call.

Each instance declares an author-facing `binding`, for example:

```dhall
{ name = "sales-inbox"
, binding = "salesMail"
, connector = Mail { mailbox = "sales@example.com", secretKey = "microsoft" }
}
```

Here `Mail` illustrates the generated union constructor. Kyyn generates a module
such as `Kyyn.Connectors` from the selected configuration:

```haskell
salesMail :: Mail.Instance
```

Generated proxy modules are named `Kyyn.Plugins.P_<plugin>.<ConnectorType>`,
replacing hyphens in the plugin name with underscores. Plugin names forbid
underscores, so this mapping is unambiguous: `local-file` becomes
`Kyyn.Plugins.P_local_file.Folder`. Authors can import it qualified as `Files`.
The exported `Instance` is phantom-typed by plugin and connector type; handles
for another connector type cannot be passed to its methods. Configured handles
are exported by `Kyyn.Connectors`, together with the selected `Tool a` alias.

Authors use `Mail.viewEmail Connectors.salesMail emailId` without repeating plugin
names, config lookup or instance construction. The generated value identifies the
instance and its connector type; it does not contain a fetched payload or a secret.
Bindings must be valid unqualified Haskell value identifiers, not reserved words,
and unique across this KB's generated connector module. Report collisions rather
than silently renaming exports. Instance identity remains plugin plus instance name;
changing only `binding` changes the authoring API, not the instance or its evidence
history. [ADR 0014](0014-evidence.md) defines latest-only evidence and invocation-local
read consistency separately from this config binding. Installation creates no instances.

Malformed or structurally incompatible plugin configuration fails preparation of
the whole root for use, with a diagnostic locating the offending configuration. Do not skip
the broken instance, substitute defaults or return a partially usable root.
Raw `RootOpening` carries these files as bytes; it does not compile plugins for
scaffolding or Before comparisons. `PrepareRoot` inspects connector declarations,
decodes every configured instance and retains the compiled pure validators;
`ValidateRoot` combines their reports with root validation. Neither probes a provider.
Repair the configuration files and retry checking. There is no partial-loading
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

The integration reads the named secret and constructs its authenticated
request. No special `SecretRef` type or kernel-understood connection schema is
required. Reusing account configuration is ordinary plugin data/composition, not
a mandatory kernel concept. Changing a local secret does not mutate accepted
knowledge. Secret values are not implicit candidate capture inputs.

Generic Web configuration display/editing can consume the checked record/list/
union/scalar structure without understanding `MailConfig`. It is not a prerequisite
for the initial persistence/invocation path. Do not generate secret-value fields
in root configuration or automatically capture secret responses into proposals.

### Authentication belongs to the integration

Integration code implements provider-specific authentication and response handling.
Native libraries
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

Check the local store with real Dhall/filesystem handling and a separate recording
handler. Cover set/replace/remove, sorted names, absent versus empty, invalid
names, corrupt/inaccessible storage and cancellation cleanup. Exercise
the installed CLI without a runtime bundle, including piped and hidden-terminal
input, argument input, JSON name-only output and ignored storage. Assert that diagnostics and
routine output contain none of the fixture secret values.

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
