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

### Install a source package

The package root is the directory containing `kyyn-plugin.dhall`, not necessarily
the containing Git repository's root. The initial installation interface is:

```sh
kyyn-v2 --kb ../my-kb plugin install --from ./plugins/local-file
kyyn-v2 --kb ../my-kb plugin install --from https://example.org/team/plugins.git --path plugins/local-file
```

Every source is a Git repository. A local directory may select a package inside
that repository; installation reads committed HEAD, not working-tree bytes.
`--path`, when supplied, selects a relative package subdirectory within either the
local directory or the fetched repository. It cannot escape that source root.
Local paths resolve against
the invoking working directory, independently of `--kb`. An explicit Git URL
selects the repository's fetched default HEAD, captured once for installation;
local Git repositories can also be acquired as Git using a `file://` URL. A missing
local path is a local-source error, not an instruction to try a network fetch.
A directory outside Git receives the existing repository-discovery refusal.

For local checkouts, refuse staged, unstaged or untracked changes within the selected
package, excluding the package exclusions below. Report the affected paths as
`plugin.source-uncommitted` and ask the author to commit first. Unrelated changes
elsewhere in the repository do not prevent installation. Ignored, untracked build
products are not package inputs. This avoids silently installing an older committed
package than the one the author is inspecting; the recorded revision describes the
copied bytes without capturing local edits into an implicit source commit.

Source classification is a pure domain rule: a value containing `://` denotes a
Git URL; otherwise it denotes a local path. Refuse scp-style Git addresses rather
than mistaking them for local paths. This slice supports `file://` and unauthenticated
`https://` Git URLs; other schemes receive an unsupported-source diagnostic. The
current Git subprocess environment does not provide `ssh` on PATH, so a refusal
must recommend HTTPS or a local checkout, not suggest an unsupported SSH retry.
Reuse `TreePath`: omitted `--path` is `WholeTree`, and a supplied relative directory
is `Subtree RelativePath`. No second package-relative path type is needed.

The package manifest is a hermetic Dhall value with this initial shape:

```dhall
{ name = "local-file", entryModule = "LocalFile.Plugin" }
```

`name` is a single lowercase ASCII name component (letters, digits and internal
hyphens); it determines the installed name. `entryModule` is a Haskell module name
whose source must exist under the package's `src/` directory. The manifest describes
source location, not method or configuration schemas: those remain Haskell
declarations. This first install operation validates package structure, not guest
typechecking, method registration, configuration, health or evidence acquisition.
It requires no installed guest runtime. It must not advertise a copied package as
a successfully executable connector.

Install a captured copy under `root/plugins/packages/<name>/source/`, and write
Kyyn-owned `origin.dhall` beside `source/`, not inside the package. Record the
absolute discovered local repository root or supplied Git URL, the repository-relative
package path, and the exact captured Git revision. This remembers where an explicit
future update should look and which commit supplied the copy; it is
not a version pin, compatibility promise or live source link. Connector configuration
remains separate under ADR 0016. Copy the package's source and supporting files,
excluding `.git`, `.kyyn`, `dist-newstyle` and `.stack-work` directories/entries
before loading their contents. Package authors keep other generated build products
outside the distributed package. Git tree entry checks refuse symlinks rather than
creating links into the source checkout. Git acquisition does not recursively initialize submodules.
A selected tree containing a submodule entry is refused.

Origin is encoded as this Dhall shape, with `None Text` for the whole repository:

```dhall
{ repository : < Local : Text | Git : Text >
, path : Optional Text
, revision : Text
}
```

The revision identifies the source commit; KB Git history separately records its
adoption. It is not a dependency-version constraint. Layout constants for
`plugins/packages`, `source`, `origin.dhall`, `kyyn-plugin.dhall` and the exclusion
list belong in `Kyyn.Domain.Root` alongside `factsLocation`, shared by installation
and later root consumers.

Prepare and validate the complete captured package before installing it. Refuse an
existing destination (including an empty directory or symlink); do not merge into
it or overwrite it. A missing/invalid manifest, absent entry source, failed fetch
or unsupported package entry leaves the KB's installed packages unchanged.
Installation does not create a Git commit, change accepted HEAD, configure instances
or accept an evolution. The copied source is an ordinary local root change for the
owner to adopt using the existing workflow.

The first packages are self-contained. Dependency acquisition, tap lookup and update
commands are separate slices; installation does not silently fetch imports or
invent dependency declarations before those operations exist.

The host boundary keeps package operations in porcelain and native operations in
plumbing. Illustrative contracts for this slice are:

```haskell
data PluginSource
  = LocalPackage DirectoryScope TreePath
  | GitPackage GitUrl TreePath

data PluginManifest = PluginManifest
  { name :: PluginName, entryModule :: ModuleName }

data PluginRepository = LocalRepository DirectoryScope | RemoteRepository GitUrl

data PluginOrigin = PluginOrigin
  { repository :: PluginRepository, path :: TreePath, revision :: GitRevision }

data InstalledPlugin = InstalledPlugin
  { name :: PluginName, location :: DirectoryScope, origin :: PluginOrigin }

data PluginInstallation :: Effect where
  InstallPlugin
    :: KnowledgeBase -> PluginSource
    -> PluginInstallation m (Either [Diagnostic] InstalledPlugin)
```

CLI composition resolves the KB and source selection. The installation interpreter
uses filesystem, Git acquisition and Dhall capabilities; it has no `IOE`, compiler,
root-publication, plugin-invocation or secret-store requirement. The successful
CLI result exposes the installed name, location and origin in human/JSON forms.

Both acquisition routes resolve to a `Repository`, one captured HEAD revision and
a repository-relative `TreePath`. Remote acquisition adds one Git operation for a
shallow, no-checkout clone into a temporary scope. Local acquisition uses existing
`DiscoverRepository`, combining its directory prefix with `--path`, and
`CheckoutChanges` for the scoped dirty-source check, including untracked entries.
Both use the existing exclusion-carrying `ReadTreeAt` to produce the same `FileTree`;
existing Git entry checks refuse symlinks and submodules. No filesystem source-tree
reader or second package-entry error mode is needed. Filesystem access failures
remain operational failures.
After acquisition, hermetic manifest decoding and pure package preparation are
shared: validate the name and module, require its source, and construct the same
destination payload and origin encoding. Neither route gets a second installer.

Use stable refusal codes at these boundaries:

| Code | Meaning |
| --- | --- |
| `plugin.source-invalid` | Unsupported URL scheme or ambiguous scp-style source |
| `plugin.source-unavailable` | Selected local package directory is absent |
| `plugin.path-invalid` | Package subdirectory is not a valid relative path |
| `plugin.manifest-missing` | Selected package root has no manifest |
| `plugin.manifest-invalid` | Manifest is malformed or its name/module is invalid |
| `plugin.entry-missing` | Declared entry module has no source under `src/` |
| `plugin.source-uncommitted` | Selected local package has staged, unstaged or untracked changes |
| `plugin.already-installed` | Destination already exists |

Git acquisition/entry diagnostics retain their Git codes (including
`git.clone-failed` and the existing `git.unsupported-entry`) rather than being
misreported as manifest errors. CLI option syntax errors retain the normal usage
exit; semantic refusals use these codes, and operational failures remain distinct.

Before this slice is complete, test refusal of directories outside Git, packages nested
inside local and remote repositories, scoped dirty-source refusals, copy independence,
exact source revision and repository-relative origin paths,
exclusion of repository/build metadata, and duplicate/malformed/unsupported package
refusals with existing KB files and HEAD preserved. Use a local Git remote for the
acquisition integration test, avoiding network-dependent tests. The first-party
`plugins/local-file` package uses exactly this boundary.

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
