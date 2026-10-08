---
id: 0015
title: 'Locally built plugins group source and sink connectors'
---
# Locally built plugins group source and sink connectors

## Context

Open extensibility must work for a user who has installed Kyyn, not a collection
of language toolchains. First-party integrations must exercise the public boundary.

## Decision

### Install a source package

The package root is the directory containing `kyyn-plugin.dhall`, not necessarily
the containing Git repository's root. The initial installation interface is:

```sh
kyyn-v2 --kb ../my-kb plugin install --evolution 000002-add-plugin --from ./plugins/local-file
kyyn-v2 --kb ../my-kb plugin install --evolution 000002-add-plugin --from https://example.org/team/plugins.git --path plugins/local-file
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

Installation requires an existing, unaccepted evolution. Refuse missing or accepted
workspaces before acquiring source. Draft and Ready targets remain editable; changing
a target makes any previously checked candidate stale through the existing captured-input
comparison. Installation does not automatically mark the evolution ready or accept it.

Install a captured copy under `evolutions/<id>/target/plugins/packages/<name>/source/`, and write
Kyyn-owned `origin.dhall` beside `source/`, not inside the package. Record the
absolute discovered local repository root or supplied Git URL, the repository-relative
package path, and the exact captured Git revision. This records the source for
explicit re-vendoring and which commit supplied the copy; it is
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

Prepare and validate the complete captured package before installing it. Repeating
installation replaces that named package in the selected evolution, including its
origin; files absent from the new package are removed rather than merged. This is
also the update route, with no force flag or separate upgrade lifecycle. Connector
configuration lives outside the package and is preserved. Stage the replacement
before exchanging directories; refuse file/symlink destinations. A missing/invalid manifest, absent entry source, failed fetch
or unsupported package entry leaves the KB's installed packages unchanged.
Installation does not create a Git commit, change accepted HEAD, configure instances
or accept an evolution. The accepted `root/` is untouched until evolution acceptance
publishes the complete target, including `plugins/`, as the new root. New evolutions
inherit all accepted non-fact root files, including plugin packages and configuration.
Plugin installation, later updates and removals follow this same evolution-owned
route; there is no direct-to-accepted-root installation mode.

Evolution review includes a host-derived comparison of captured Before and target
plugin packages, separate from guest-authored rationale and citations. Record each
added, removed or changed package, its before/after origin and changed file paths.
Compare package bytes, not only origin revisions: local edits to vendored source
must remain visible under an unchanged origin. Save this comparison with the
candidate and accepted report so inspection does not consult live package files
or require a compiler. Tap aliases are not retained provenance; show the concrete
source repository/path instead.

The first packages are self-contained. Dependency acquisition, tap lookup and update
commands are separate slices; installation does not silently fetch imports or
invent dependency declarations before those operations exist.

The host boundary keeps package operations in porcelain and native operations in
plumbing. The installation boundary is:

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
    :: EvolutionWorkspace -> PluginSource
    -> PluginInstallation m (Either [Diagnostic] InstalledPlugin)
```

CLI composition resolves the KB and source selection. The installation interpreter
uses EvolutionStore for lifecycle lookup, then filesystem, Git acquisition and Dhall capabilities; it has no `IOE`, compiler,
root-publication, plugin-invocation or secret-store requirement. The successful
CLI result exposes the installed name, location and origin in human/JSON forms.

Both acquisition routes resolve to a `Repository`, one captured HEAD revision and
a repository-relative `TreePath`. Remote acquisition adds one Git operation for a
shallow, no-checkout clone into a temporary scope. Local acquisition uses existing
`DiscoverRepository`, combining its directory prefix with `--path`.
The dirty-source check reports staged and unstaged differences from HEAD within
the selected package, plus untracked entries that are not ignored, minus the fixed
package exclusions; use a distinct scoped Git query, not `CheckoutChanges`, whose
checkout-synchronization semantics deliberately include ignored residue.
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
| `plugin.evolution-accepted` | Selected evolution is already accepted; create a new evolution |
| `evolution.unknown` | EvolutionStore found no workspace manifest; retain its existing diagnostic |

Git acquisition/entry diagnostics retain their Git codes (including
`git.clone-failed`, `git.unsupported-entry`, `git.missing-subtree` for an absent
`--path`, and `git.no-working-tree` for a directory outside Git) rather than being
misreported as manifest errors. CLI option syntax errors retain the normal usage
exit; semantic refusals use these codes, and operational failures remain distinct.

Test refusal of directories outside Git, packages nested
inside local and remote repositories, scoped dirty-source refusals, copy independence,
exact source revision and repository-relative origin paths,
exclusion of repository/build metadata, complete re-vendoring and malformed/unsupported package
refusals with existing KB files and HEAD preserved. Use a local Git remote for the
acquisition integration test, avoiding network-dependent tests. The first-party
`plugins/local-file` package uses exactly this boundary.

### Discover packages through KB-local taps

A tap is a Git repository with a Dhall catalogue, not a dependency
resolver or runtime registry. First- and third-party catalogues use the same
interface; no central approval service is involved. The catalogue lists plugins.

The KB's top-level `taps.dhall` records tap names and upstream Git locations:

```dhall
[ { name = "first-party", source = "https://github.com/drshade/kyyn-v2" } ]
```

This file is committed with the KB but is outside `root/` and evolution ownership.
It describes where authors discover code, not the accepted KB's executable meaning.
`tap add/remove` edits it directly without creating a commit; ordinary Git provides
sharing and review. A malformed declaration affects tap operations, not root
validation or execution of already vendored plugins. There is no user-wide or
system-wide registry, configuration precedence or daemon.

`kb init` writes the first-party declaration as part of the initial KB commit,
without downloading the repository. It is an ordinary editable entry, not an
implicit fallback: removing it is respected. Existing KBs can add it explicitly
through `tap add`; installation guidance supplies the first-party URL.

Synced repositories live under `.kyyn/taps/<name>/` and are ignored, disposable
downloads. `tap update` reconstructs or refreshes them from the declarations;
a shallow fetch of the default branch is sufficient.
Deleting the cache loses no declarations or installed source. Updating or removing
a tap never updates or removes an installed plugin. A cloned KB retains its
discovery setup without inheriting another checkout's cache.

The repository-root `kyyn-tap.dhall` catalogue supplies a plugin name, short description, source repository
and package-relative path. The description is the catalogue's offline-search
summary, not a replacement for the plugin's own description. Illustratively:

```dhall
[ { name = "microsoft-graph"
  , description = "Microsoft calendar evidence"
  , source = "https://github.com/drshade/kyyn-v2"
  , path = "plugins/microsoft-graph"
  } ]
```

The first-party catalogue may live in the Kyyn monorepo. Search reads downloaded
catalogues, without an implicit network refresh; an unsynced tap reports how to
sync it. A qualified selection `tap-name/plugin-name` resolves to the existing
`PluginSource`, then uses the same captured-source installation operation. It
does not introduce a second installer or version/compatibility pinning. Installed
origin still records the actual package repository, path and captured revision;
execution never resolves a tap name. Direct `--from` installation stays available.

```sh
kyyn-v2 --kb PATH tap add community --from URL
kyyn-v2 --kb PATH tap list
kyyn-v2 --kb PATH tap update
kyyn-v2 --kb PATH plugin search calendar
kyyn-v2 --kb PATH plugin install community/calendar --evolution ID
```

### Read packaged guides without executing plugins

A plugin's guide is `README.md` at the package root, by convention. There is no
guide field in `kyyn-plugin.dhall` or duplicate documentation declaration.

The host reads that file, not a guest function. Guide access requires neither a
compiler nor valid connector configuration, credentials, authentication or root
validation. It must work when incompatible plugin source prevents root checking.
The guide path stays inside the selected package and uses the existing package
file rules. Missing or unreadable guides receive a specific actionable diagnostic.

```haskell
data PluginLocation
  = AcceptedPlugins KnowledgeBase GitRevision
  | EvolutionPlugins EvolutionWorkspace

readPluginGuide
  :: PluginDocumentation :> es
  => PluginLocation -> PluginName -> Eff es (Either [Diagnostic] PluginGuide)

readAvailableGuide
  :: PluginDiscovery :> es
  => KnowledgeBase -> TapName -> PluginName
  -> Eff es (Either [Diagnostic] PluginGuide)
```

Installed documentation reads selected package files without compilation.
Pre-install discovery resolves a tap entry and acquires its source through Git.
Both return the guide plus package/origin information, never a second stored copy.
Their interpreters need neither guest execution nor secrets.

`plugin guide microsoft-graph` reads the accepted vendored package;
`--evolution ID` instead reads that evolution's target package. Before installation,
`plugin guide first-party/microsoft-graph` resolves the tap entry without installing
it. When its source equals the tap's declared repository location, read the package
at the synced tap revision without a network fetch. Otherwise use existing source
acquisition into a temporary scope, read the guide and discard the temporary
download. This does not create another persistent package cache. The result
identifies the source revision it describes; a later install may select a newer
upstream revision. There is no separate guide copy or requirement to retain the
previewed revision.

`plugin show` advertises guide access, and successful installation points to both
the guide and configuration-schema discovery. Guides explain setup, authentication,
examples and limitations; checked Haskell declarations remain authoritative for
exact types and signatures. Existing package READMEs are the guides, avoiding
duplicate documentation or any need for consumers to find the source repository.

Verification must cover discovery in a fresh clone after syncing taps, independent
KB caches, cache deletion/reconstruction, qualified-name resolution through the
existing installer, and unchanged installed packages after tap updates/removal.
Read guides before installation and from accepted/draft packages whose Haskell
does not compile, without invoking the guest. Check missing/invalid guide paths
and source identity in results.

Evidence-producing methods should supply useful source identifiers as described
in [evidence](0014-evidence.md): a stable URI where available, a scoped provider
item ID, or a local file path. Citations should remain meaningful outside Kyyn's
temporary evidence cache, without promising permanent access to the source.
Identifying the cited item is sufficient for provenance; citations need no version
or fingerprint. The separate operational fingerprint required for current evidence
and refresh comparison belongs to ADR 0014, not the citation contract.

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
its separately typed invocation options control delivery and have a plugin-declared
default. Configuration, input, options and result contracts are discoverable;
[outputs](0017-outputs.md) owns that binding and invocation model. The host does
not interpret plugin-specific option fields or merge them into saved config.

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
Each instance also declares its generated guest binding under ADR 0016; the binding
is an authoring name, not another identity or installed plugin.

A source's acquisition method returns plugin-declared evidence changes under
[ADR 0014](0014-evidence.md). Its plugin-specific captured-evidence methods, such as
`viewEmail` or `getAttachments`, are separately discoverable typed methods; the host
does not prescribe a generic evidence view. Agents invoke them directly or through
composed KB tools under ADR 0008. Acquisition and captured reads have distinct
capability requirements under ADR 0009, even when they share a connector type.

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

Source registration is a plugin entry module's `connectors` value. Registration
names implementations; checked function signatures determine their data contracts.

```haskell
connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Folder"
  , fetch = "LocalFile.Folder.fetch"
  , login = Nothing
  , validateConfig = "LocalFile.Config.validate"
  , methods = [CapturedMethod
      { methodName = "content"
      , methodDescription = "Read the latest fetched text of a file by its evidence ID."
      , implementation = "LocalFile.Read.content"
      }]
  }]
```

`SourceConnector` is exported through `Kyyn.Plugin`. The connector name must match
`[A-Z][A-Za-z0-9_]*` and be unique within the plugin; it becomes an alternative in
the derived Dhall configuration union. Qualified names refer to Haskell declarations,
not duplicated structural schemas. A fixed adapter evaluates the registration;
the compiler inspects each selected function's checked signature. It derives Config,
Payload and optional Options from fetch, lowering those data types through ADR 0005's
existing algebra. Generated adapters check the pure `Config -> ValidationReport`
validator and optional login against the same derived Config.
All source connectors use [ADR 0009's acquisition row](0009-capabilities.md#provider-acquisition-and-explicit-login).
The optional `login` qualified entry is checked and dispatched
under [ADR 0016](0016-connections.md#authentication-belongs-to-the-integration).
Graph advertises its login entry; the folder needs no login. Login is present or
absent independently of which capabilities a fetch happens to use.
Discovery exposes this declaration without executing authentication or fetching.

The supported fetch signatures determine whether per-invocation options exist;
expose the derived contract through `plugin connector show`:

```haskell
fetch :: Config -> EvidenceSnapshot Payload
      -> Acquisition Payload (Either FetchError [EvidenceChange Payload])

fetch :: Config -> Maybe Options -> EvidenceSnapshot Payload
      -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
```

[ADR 0029](0029-evidence-blobs-sync.md#sync-positions-are-typed-connector-data)
adds stateful signatures carrying a typed `FetchContext Position` and returning
`FetchResult Payload Position`. Derive Position from the checked signature, just
as Config, Payload and Options are derived; no position-type registration string.
Preserve that contract in PreparedConnector and generated dispatch. Existing
stateless entry forms have no position. BlobRefs in payloads/results retain their
SDK identity for checked capture, reading and surface file presentation.

Authored functions import ordinary SDK types and helpers, not a generated
payload-specific bindings module. `Acquisition payload a` and `CapturedRead payload a`
are parameterised SDK types; helpers preserve that payload parameter. This lets the
compiler inspect a function before the host knows its Payload. Generated execution
entries and codecs remain private runtime plumbing, built after inspection.

Inspection uses checked compiler types, including expanded aliases, not source-text
parsing or pretty-printed signatures. Config, Payload, Options, Input and Result must
be concrete supported data types. Check the complete entry shape: arity, effect row,
typed failure, result wrapper and agreement of Payload wherever it occurs. Reject
unresolved polymorphic data, residual unsupported constraints on the inspected
entry or its data contracts, and mismatched types rather than guessing contracts.
This does not prohibit constrained reusable helpers: ADR 0009's `ReadsEvidence`
constraint is resolved by a concrete registered entry's row. The host checks supplied options before guest execution, while the
connector owns their meaning and defaults. ADR 0014 owns invocation and history.
Native `ConnectorTypeName`, `BindingName` and `ConnectorName`
distinguish declared names after decoding. Registered implementations are qualified
Haskell value exports. Bindings match
`[a-z][A-Za-z0-9_']*` and exclude Haskell keywords; instance names are nonempty text.
Inspection takes a captured source tree and selected function export, returning
the derived data contracts without authored metadata. No synthetic metadata module
is compiled for plugin config or payload types.
The `methods` list extends this declaration with captured-evidence readers.
`CapturedMethod` supplies a name, agent-facing description and qualified Haskell
implementation export. The compiler derives Input and Result from
`Input -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Result)`
and verifies that Payload matches the containing source connector. Descriptions belong to registration, not a second API
documentation registry. No method is executed during discovery.

Misfit diagnostics name the plugin, connector or method, the selected export, and
the expected signature shape. A compiler failure caused by an authored import of
`KyynPluginBindings` additionally points to the ordinary SDK imports; do not supply
a compatibility bindings module. Compiler diagnostics retain their useful source
locations. Registration/data-shape errors and operational compiler failures remain
distinct under ADR 0019.

Verification must derive the local-file and Graph contracts without type-name
declarations, exercise fetches with and without options, aliases and concrete
instantiations of parameterised data, and reject wrong rows, arities, wrappers
and inconsistent Config/Payload.
Generated adapters must compile under GHC and MicroHs. Installed discovery must
continue exposing exact schemas, and a mixed-capability fetch must still work.

Native `MethodName` uses the same identifier rule as `BindingName`. Method names
must be unique within a connector; a malformed or duplicate declaration is a
`plugin.preparation` diagnostic locating the plugin/connector. A selected unknown
method is `plugin.method-unknown`. The local-file method takes an evidence ID as
`Text` and returns the captured text as `Text`. A missing ID is a typed `FetchError`,
surfaced as `plugin.read-failed`, not a live-file fallback.

The `PluginRead` porcelain capability receives a resolved instance, producer,
payload contract, prepared method and structural input. Its interpreter validates
the input against that method's contract, loads current evidence once, and calls
the captured-read broker with that immutable value. It has no file-acquisition
capability. `evidence.not-fetched`, producer-change and invalid-cache diagnostics
are preserved; absence never becomes an empty snapshot. The result is checked
against the inspected output contract. ADR 0018 owns direct discovery/invocation;
generated KB-caller proxies and helper registration remain separate implementation.

Distinguish installed package identity and selected method. Configuration is
ordinary typed data, not another plugin-instance lifecycle:

```haskell
data PreparedMethod = PreparedMethod
  MethodName String CheckedContract CheckedContract CompiledProgram
-- Name, description, input contract, result contract and compiled entry.

data PreparedConnector -- inspected source connector, contracts and compiled entries
data ConfiguredConnector =
  ConfiguredConnector ConnectorName BindingName PreparedConnector CheckedValue

data PreparedPackage = PreparedPackage PluginName PackageIdentity [PreparedConnector]
data PreparedPlugin = PreparedPlugin PreparedPackage [ConfiguredConnector]

data PluginPreparation :: Effect where
  PreparePackages :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPackage])
  PreparePlugins :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPlugin])
  ValidatePlugins :: [PreparedPlugin] -> PluginPreparation m (Either [Diagnostic] ValidationReport)

listConnectorMethods
  :: (RootOpening :> es, EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] [PreparedMethod])

data PluginRead :: Effect where
  LoadCapturedInput :: EvidenceSelection -> CheckedContract
    -> PluginRead m (Either [Diagnostic] EvidenceIndex)
  ExecuteCapturedMethod :: EvidenceIndex -> PreparedMethod -> Value
    -> PluginRead m (Either [Diagnostic] (Either FetchError CheckedValue))
```

These are **host** declarations. Preparation inspects/compiles captured source and
checks configuration without invoking provider methods. `PreparedConnector` retains
the derived configuration, payload and optional fetch-options contracts, fetch and
config-validation entries, optional login, and captured-read methods. Its representation
is not an additional authored registration form.

PluginRead checks a method's structural input before dispatch and validates its
result contract. Declared FetchError remains distinct from storage/contract
diagnostics and operational Failure. The explicit EvidenceIndex value lets a
composed tool reuse one invocation-local index instead of reopening it for each
call. Payloads are read selectively through EvidenceStore under
[ADR 0014](0014-evidence.md). Generic evidence list/show uses the lighter selection
operation there, not PluginPreparation. Guest proxies retain native input/output types; these structural host values
do not expose an unchecked byte-call API to authors.

This block defines source preparation and captured reading; it does not grant
sinks those read-only rows or force delivery through PluginRead.
[ADR 0017](0017-outputs.md) owns the typed sink binding and invocation boundary.
A source instance cannot satisfy an output's sink reference merely because a method
has a similar input shape. Kind denotes intended use, not proof that generic HTTP
can only read remote state.

For a connector invocation, the caller selects plugin and connector instance,
not just a method name with an ambient default account. PluginPreparation loads that
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

### Microsoft Graph source family

The single `microsoft-graph` package contains Calendar, Mail, Meetings and Files
source types. Every instance has its own configuration, evidence and sync position;
they share ordinary plugin authentication code and may share an app/token key under
[ADR 0016](0016-connections.md#microsoft-graph-authentication). This is not another
kernel connection entity or a separate plugin per endpoint.

Mail exposes typed message/body/attachment reads; Meetings exposes transcript and
attendance reads; Files exposes metadata and BlobRefs. These operate on captured
evidence only. Large binary content is referenced, not eagerly inserted into a
method's text response. KB helpers can compose those methods through existing
generated bindings. Payload capture policy belongs to
[ADR 0014](0014-evidence.md#microsoft-graph-mail-meeting-artifacts-and-files),
and blob/sync mechanics to [ADR 0029](0029-evidence-blobs-sync.md).

### Explicit updates, ordinary repair

Repeat `plugin install --evolution ID` with an explicit source or tap-qualified
package to replace the vendored package using the installation contract above.
The unit is the complete plugin, not an individual connector. Preserve instance
configuration and credentials outside that package. Compilation/check failures
remain visible during normal evolution checking; an incompatible update is
inspectable and repairable, not a reason to add a compatibility resolver.

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
