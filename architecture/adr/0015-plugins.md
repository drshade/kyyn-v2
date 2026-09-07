# 0015 — Locally built plugins group source and sink connectors

Status: Proposed implementation details. **Owner-established direction: uniform
MicroHs runtime, source vendoring and local compilation, with related connectors
and account setup in one plugin. One KB has many plugins; each plugin can have
many named connector instances, including multiple instances of the same type.
Explicit source updates without plugin version
pinning or SDK/runtime compatibility machinery are the first-release model.**

## Context

Open extensibility must work for a user who has installed Kyyn, not a collection
of language toolchains. First-party integrations must exercise the public boundary.

## Decision

A tap is a Git repository with a data catalog. It distributes three package
kinds: MicroHs plugins with registered methods; reusable MicroHs libraries; and
templates copied into a new KB. The latter two are not pretend running plugins.
Any third-party tap URL and local development checkout can be used without a
central approval service. First-party packages use the same interfaces.

Evidence-producing methods should supply useful source identifiers as described
in [evidence](0014-evidence.md): a stable URI where available, a scoped provider
item ID, or a local file path. Citations should remain meaningful outside Kyyn's
temporary evidence cache, without promising permanent access to the source.
No source-version, fingerprint or historical-reconstruction obligation accompanies
that guidance; identifying the cited item is sufficient.

The distributed plugin is an inspectable source directory with its declarations
and dependencies, not a supplied WASM/native/combinator executable. Installation
vendors plugin source and its source dependencies into the KB, remembering their
remote origins so an explicit update can fetch them again. No dependency-version
lock or compatibility solver is required. Keep those source files with the KB in
Git so the human/agent can review the actual code, including dependencies, and
another checkout can build it with its installed Kyyn toolchain. Plugins target
the SDK/runtime supplied by that installation; ordinary users need no other compiler.
Kyyn generates bindings and compiles that fixed source locally. Compiled artifacts
are disposable local build products under ADR 0006, not a second imported authority.

### One plugin, several connectors

A plugin supplies **connector types**: their configuration types, implementations
and registered methods. The KB configures **connector instances** beneath that
plugin. Kyyn understands this shallow hierarchy, not the provider-specific fields
or behavior. Instances are configuration data, not separate plugin installations
or connection-provider components.

Connector types have two distinct purposes: **Sources** acquire evidence from the
external world; **Sinks** mutate or update the external world. A plugin can supply
both, with multiple configured instances of either kind. Kind is declared on the
connector type and inherited by its instances, not another installation or
permission lifecycle. Shared health/configuration helpers remain ordinary methods.
A sink's declared operation input is the exact type a KB renderer must produce;
[outputs](0017-outputs.md) owns that binding and invocation model.

For example:

```text
KB
  Microsoft plugin
    sales-inbox        : Mail (Source)
    support-inbox      : Mail (Source)
    team-meetings      : Meetings (Source)
    budget-folder      : Files (Source)
    report-mail        : SendMail (Sink)
  Salesforce plugin
    open-opportunities : Query (Source)
    active-accounts    : Query (Source)
  Local files plugin
    monthly-report     : WriteFile (Sink)
```

Each instance has a name unique within its plugin, a connector type selected from
that plugin's advertised types and configuration checked against that type. Repeated
types are normal: sales-inbox and support-inbox are independent Mail configurations.
Across plugins, instance references use both plugin and instance name. A configured
acquisition source is such a connector instance, not another source registry.

Mail and Meetings instances may name the same local secret key without duplicating
the secret. Shared account settings/authentication functions are ordinary plugin
data/code; there is still no kernel Connection entity or enrollment model.
Plugins can also publish methods not attached to a connector. This hierarchy does
not force every plugin to implement acquisition, accounts or delivery.

Fixed health/description/configuration methods and typed named methods share one
registration mechanism and generated adapter. Connector entries use that same
typed method boundary; they do not need their own executable/plugin framework.
Health is explicit and may fail; opening a KB must not probe every provider.
Account setup uses host capabilities under ADR 0016, not IO in authored modules.

Distinguish installed package identity and selected method. Configuration is
ordinary typed data, not another plugin-instance lifecycle:

```haskell
data PackageKind = PluginPackage | LibraryPackage | TemplatePackage

data PackageIdentity  -- selected source contents and resolved dependency identity

data ConnectorKind = Source | Sink

data ConnectorType = ConnectorType
  { name           :: ConnectorTypeName
  , kind           :: ConnectorKind
  , configContract :: CheckedContract
  , methods        :: [MethodDescriptor]
  }

data ConnectorInstance = ConnectorInstance
  { name          :: ConnectorName
  , connectorType :: ConnectorTypeName
  , configuration :: CheckedValue
  }

listConnectors
  :: (RootStore :> es, Failure :> es)
  => Root -> PluginName -> Eff es [ConnectorInstance]

listMethods
  :: (PluginInvocation :> es, Failure :> es)
  => PackageIdentity -> Eff es [MethodDescriptor]

callPlugin
  :: (PluginInvocation :> es, Failure :> es)
  => PackageIdentity -> MethodDescriptor -> CheckedValue
  -> Eff es (Either PluginError CheckedValue)
```

These are **host** signatures: they use the structural descriptors from
[authoring](0008-authoring.md). The interpreter checks that method/package
and input contract match, then checks the returned contract. A `CheckedValue`
from another method is not automatically valid input here. `PluginError` is a
declared method failure; process/protocol loss belongs to [Failure](0019-failures.md).
The guest-facing generated proxy has native input/output types instead. This
host boundary is not a public unchecked `call bytes` escape hatch.
`ConnectorType` comes from the plugin's declarations; `ConnectorInstance` is
root-owned data loaded under the explicitly selected plugin. Verify its type
exists there, its config contract matches and names are unique. Provider-specific
configuration validation remains a pure plugin function under ADR 0016.
Generated source and sink bindings retain that kind distinction: a source instance
cannot satisfy a renderer's SinkBinding merely because a method has a similar
input shape. This expresses intended use, not a claim that generic HTTP can prove
remote operations read-only. Both kinds still describe host-interpreted effects.

For a connector invocation, the caller selects plugin and connector instance,
not just a method name with an ambient default account. RootStore loads that
instance from the selected snapshot; dispatch verifies the method belongs to its
connector type. Configuration forms part of the method's declared typed input,
alongside call arguments, assembled/checked by generated bindings before the
low-level `callPlugin`. The plugin receives the chosen instance's concrete config,
not the whole config file or a list it must search itself. This does not restore
the discarded plugin-instance lifecycle or invent plugin-wide configuration.

Method discovery reads registered descriptors, not every method's health endpoint.
The [capability broker](0009-capabilities.md) installs the method's selected host
handlers; installing a package alone grants no caller an ambient all-plugin API.
Grouping methods in one source package does not union their capability rows.
These boundaries guide authoring and interpretation, not a claim of containment.

### Explicit updates, ordinary repair

`kyyn plugin update microsoft` illustrates the update operation; the command
spelling is provisional. It fetches from the recorded remote origin, updates the
local vendored source, rebuilds and reports compilation/check failures. The unit
is the plugin package, including its connectors, not an individual connector
installation. Preserve account/source configuration and credentials; refuse to
overwrite local source edits silently. An incompatible update remains inspectable
and repairable, not a reason to invent an automatic compatibility resolver.

Fetch/vendor source dependencies during explicit installation or update, outside
pure checking. Compilation and execution use captured local source and the
installed SDK/runtime, never an implicit fetch from a live tap branch. Changed
source or toolchain must not select old compiled artifacts; rebuilding is sufficient
without a compatibility-version system. Generated bindings still identify their
actual checked contracts under ADR 0005.

Installation/update prepares local files; it does not create a special install
commit or silently accept a new root. Adopt changes through the ordinary code-only
evolution route, or ordinary Git with checking on load under ADR 0013. Git exposes
the source diff and can recover committed earlier code. Compiler diagnostics,
KB checks and human/agent review provide the repair workflow; typechecking alone
does not detect every behavior change. Old evidence may still require refetch.

This is sufficient for the first release, not temporary scaffolding awaiting a
version-management system. No plugin version pins, SDK/runtime compatibility
declarations, negotiation, supported-version matrix or backward-compatibility
promise is required. Add such machinery only if actual support experience
demonstrates a need, not simply because Kyyn is being released.

Template creation copies files and substitutions, after which the owner controls
them. Later template improvements are explicit changes, not overwrites. Vendored
libraries remain named local dependencies, not hand-maintained copies spliced
into each plugin's implementation.

### Trust the selected source and the installed toolchain

Source distribution removes the need to establish that an imported executable
corresponds to reviewed source: Kyyn builds the source it will execute. It does
not establish that the source is benign or that its dependencies/compiler are
infallible. Human/agent review is ordinary judgment, not a mandatory runtime gate.
Package/build identities select the right code and bindings; they are not trust
scores or approval receipts. Do not introduce plugin signing, executable provenance
attestations, reproducible-build approval gates or a central trust service.
The installed Kyyn toolchain remains trusted software under ADR 0020.

## Alternatives and consequences

Reject arbitrary-program plugin distribution, private first-party engine imports,
multi-language conformance requirements, and a separate receipt/control plane
for each plugin role. Haskell authoring is an intentional ecosystem constraint.
Extending a plugin cannot silently extend the native host's capability vocabulary;
new native integrations require a Kyyn release and reviewed boundary.

## Verification

Build a reference acquisition plugin and an independently authored plugin using
only the public SDK and tap documentation. Install source from a clean Kyyn release,
then compile and invoke offline with no tap-supplied executable. Delete local
build products and rebuild from the same vendored sources. Changed source must
not select an old compiled artifact merely because its package name is unchanged.
Exercise two plugins in one KB, including two Mail instances and a Meetings
instance beneath Microsoft. Verify independent configuration and dispatch, shared
and distinct secret keys, and rejection of duplicate names, unknown connector
types, wrong methods and mismatched config contracts. Discover typed methods, explicitly
update source from a remote, break a contract and repair a caller using compiler
diagnostics and Git diffs. Preserve configuration/credentials and refuse destructive
replacement of local source edits. No kernel rebuild, user-managed language toolchain
or new connection-provider plugin is needed for ordinary MicroHs package changes.
