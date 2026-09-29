---
id: 0018
title: 'CLI, MCP and web share application operations'
status: proposed
date: 2026-09-11
---

# CLI, MCP and web share application operations

Basis: owner-established equal importance of Web and MCP, and owner-agreed CLI
navigation and KB selection. Remaining transport mechanics are proposed.

## Context

Web and MCP serve different audiences with substantial overlap. MCP's JSON
orientation need not dictate storage or force strings inside strings. A CLI is
useful for files, development and automation, but is not a substitute for either
first-class interface.

## Decision

Make typed application operations the shared product surface. CLI parsing, MCP
requests and web events translate into these requests; renderers format returned
values. No adapter implements acceptance rules or reaches directly into Git,
provider, runtime or persistence interpreters. Compose only the handlers needed
by the selected operation, not one global kitchen-sink environment.
Each command installs exactly the interpreters its effect row requires. When
operations need different dependencies, separate their capabilities rather than
install dummy handlers or a lazily initialized global runtime. For example,
[EvolutionAuthoring](0010-evolutions.md) owns compiler-dependent creation/capture;
EvolutionStore supports listing and metadata operations without a compiler or SDK.

Transport conversion is a real boundary, not another spelling of the domain
operation. For example, an MCP adapter may accept JSON while the store never does:

```haskell
data ListEvolutionsRequest = ListEvolutionsRequest
  { knowledgeBase :: KnowledgeBaseRef
  , filter        :: EvolutionFilter
  }

decodeListRequest
  :: Aeson.Value -> Either RequestDiagnostic ListEvolutionsRequest

encodeEvolutionSummaries :: [EvolutionSummary] -> Aeson.Value
```

This is **adapter code**. After decoding and resolving the KB reference through
[RootStore](0006-storage.md), it invokes the typed `ListEvolutions` operation in
[EvolutionStore](0010-evolutions.md). The Web and CLI adapters reach that same
operation without routing through MCP. JSON does not leak into its constructor,
and the operation does not print a response or call a UI. Resolving an unopened KB
adds metadata-store work, not compilation; listing an already selected KB needs
only its workspace store and failures.

Use `optparse-applicative` for a discoverable CLI with human and stable structured
output modes, explicit KB selection, input/output file support and useful exit
codes. Keep stdout results separate from progress/errors. CLI use needs no daemon.
ADR 0025 describes agent-driven setup and per-KB Web/MCP/headless lifecycles.

### CLI navigation and KB selection

The CLI is a user interface, not an inventory of kernel functions. Use
`kyyn <noun-path> <verb> [arguments]`: noun paths express useful containment,
and verbs express the user's intention. Connectors belong beneath plugins;
schema, facts and queries belong beneath the selected root. Do not reproduce
internal module nesting or add duplicate top-level shortcuts. The KB is already
selected, so ordinary commands do not need a redundant `kb` prefix.

The agreed navigation sketch is:

```text
kyyn
  kb
    init
    show
  root
    show
    check
    schema
      list
      show <name>
    fact
      list
      show <id>
    query
      list
      show <name>
      execute <name>
    tool
      list [--evolution <id>]
      show <name> [--evolution <id>]
      execute <name> --input <dhall>
    recipe
      list
      show <name>
      pending
        list <name> <plugin> <instance>
  evolution
    new <name>
    list
    show <id>
    check <id>
    ready <id>
    draft <id>
    accept <id>
    recover <id>
  plugin
    install <source>
    search <text>
    guide <plugin-or-tap/plugin> [--evolution <id>]
    list
    show <plugin>
    update <plugin>
    connector
      list <plugin>
      show <plugin> <connector>
      schema
        show <plugin>
      method
        list <plugin> <instance> [--evolution <id>]
        show <plugin> <instance> <method> [--evolution <id>]
        execute <plugin> <instance> <method> --input <dhall>
  evidence
    fetch <plugin> <instance>
    history
      list <plugin> <instance>
    change
      list <plugin> <instance>
  output
    list
    show <name>
    prepare <name>
    publish <name>
  secret
    list
    set <name>
    remove <name>
  guest
    module
      list
      show <module>
    symbol
      show <module.symbol>
  web
    serve
  mcp
    serve
  doctor
```

This establishes navigation, not a comprehensive argument specification or a
claim that these commands exist. The first evolution CLI slice implements
`kb init`, `root show/check` and the evolution group. Other groups are designed in their
own slices; do not install empty groups or placeholder handlers. `doctor` is
a deliberate standalone readiness command. Collection selection for fact IDs,
typed query arguments and secret input are details for their respective slices.
`root schema list/show` exposes the selected root contract's types, definitions,
fields and declared roles, not arbitrary compiler internals.

Tap discovery and packaged-guide commands are proposed in
[ADR 0015](0015-plugins.md#discover-packages-through-kb-local-taps), including
`tap add/remove/list/update`, qualified installation and pre-install guide access.
They share the selected `--kb` scope and do not require a valid executable root.

The plugin-install slice adds `plugin install --evolution ID --from SOURCE [--path SUBDIRECTORY]`
under the common `--kb PATH` selection. It prepares a copied source package in that evolution's target and
returns its installed name, location and origin in human/JSON output; it does not
compile or invoke the plugin, configure connectors, fetch evidence or commit the
root. ADR 0015 owns source selection, manifest, storage and refusal contracts.

Connector discovery uses `plugin connector list PLUGIN [--evolution ID]` and
`plugin connector schema show PLUGIN [--evolution ID]`. The default is the
accepted root; an evolution target can be inspected before its configuration is
accepted. Schema output is the derived Dhall type for
`target/plugins/config/PLUGIN.dhall`. Field documentation is a discovery-only
extension through API inspection, not a dependency of root preparation or fetching;
the first producer slice emits the exact type without documentation comments.
Authors write that file and use ordinary check/ready/accept. Schema
discovery must remain available when the configuration file needs repair.

Evidence operations use their own noun path:

Recipe instructions and pending evidence use `root recipe list/show` and
`root recipe pending list NAME PLUGIN INSTANCE`. They inspect the accepted root;
list/show requires no runtime bundle. Pending results contain the recipe name,
fixed `scope` (plugin, instance, fetch) and net `changes` (ID and kind), in human or
JSON form. [ADR 0014](0014-evidence.md) owns the comparison, progress and recovery
semantics. Empty pending work is displayed as "No unacknowledged changes."

Raw acquisition history remains separate:

```text
evidence fetch PLUGIN INSTANCE
evidence history list PLUGIN INSTANCE
evidence change list PLUGIN INSTANCE [--since FETCH]
evidence clear PLUGIN INSTANCE
```

Fetching selects and checks the accepted root and its configured instance;
there is no `--evolution` acquisition context. An unaccepted instance cannot
start an evidence history. Unknown plugins and instances produce `plugin.unknown`
and `plugin.instance-unknown`; a typed acquisition refusal is `plugin.fetch-failed`.
History and change results contain fetch identifiers, ordering and citations,
never payloads. `--since` is exclusive; the ending fetch is always the latest.
Clearing discards only the selected instance's local evidence and change markers.
It needs neither the runtime nor plugin preparation, and reports whether a cache existed.
Unavailable cursors, unfetched instances, incompatible producers, publication conflicts and malformed
deltas remain distinct: `evidence.cursor-unavailable`, `evidence.not-fetched`, `evidence.producer-changed`,
`evidence.base-conflict`, `evidence.invalid-delta` and `evidence.invalid-data`
(corrupt stored data). ADR 0014 owns their semantics.
History and change inspection prepare plugin declarations and contracts,
including compiled adapters.

`guest module list/show` and `guest symbol show` describe the installed public SDK
and, when a KB is selected, its generated public tool modules. Public modules come from kyyn-sdk's exposed
facade declarations under [ADR 0008](0008-authoring.md), not the shared wire-profile
package's exports; checked MicroHs exports determine symbol membership, including
reexports and their defining module. Display authored signatures and type aliases
when available, preserving useful names such as `Edit` and `Lens'`. Distinguish
checked expanded signatures from source declarations rather than claiming they
are the author's spelling. Private constructors are not exposed by reading their
source declarations.

Show data/newtype declarations projected to the exported constructors and
selectors: abstract types have only a header, and constructors with private
selectors use positional arguments. Do not include derived instances or generated
instance dictionaries. Derive constructor and selector signatures from those
declarations; specialize trivial root-parameter equalities in GADTs and retain
authored parameter names where unambiguous. Refined constructor results use GADT
syntax. Preprocess CPP-enabled defining sources with the compiler's macros before
extracting signatures. Mark fallbacks with `-- [compiler signature]`;
all catalogue entries are compiler-checked. Human function/constructor signatures
have no `value` prefix; kind summaries retain `type`. Display generated accessor
origins as module-qualified field names, preserving exact compiler identities in JSON.

Documentation uses a small source convention: a `-- |` block immediately above
a signature or type declaration, continued by adjacent `--` lines. Attach it to
the defining symbol and retain it through reexports. Store the text with the
catalogue and expose it in human and JSON output; ordinary implementation comments
are not documentation. This does not promise full Haddock parsing or rendering.

Generate this fixed catalogue from the staged SDK during the build and ship it
as Dhall in the runtime bundle. Outside a KB (no `root/kb.dhall` at the selected path), discovery reads only the
catalogue through filesystem and Dhall plumbing, without Git or guest compilation.
Within a KB it adds generated modules from the accepted root, or the evolution
target selected by `--evolution ID`.
Human output supports selective exploration and `--json` returns the same symbols
as structured data. A missing module or symbol is a refusal with a navigation hint.

#### Evolution-workspace discovery

Extend the same discovery commands with an explicit `--evolution ID` context:

```sh
kyyn-v2 --kb PATH guest module list --evolution 000001-add-todos
kyyn-v2 --kb PATH guest module show Kyyn.Workspace.Evolution --evolution 000001-add-todos
kyyn-v2 --kb PATH guest symbol show Kyyn.Workspace.After.todos --evolution 000001-add-todos
```

With `--evolution`, the catalogue also contains `Kyyn.Workspace.Evolution`,
`Kyyn.Workspace.Before` and `Kyyn.Workspace.After`, as generated for the selected
workspace's current source. The first exposes the typed `evolve`, `editBefore`
and `edit` combinators; the other two expose collection handles. Use the existing
public-export projection, documentation and human/JSON renderers. A generated-module response
identifies the selected workspace and its declared Before revision; it does not
claim that a checked candidate or accepted result exists.

This is discovery during authoring, not evaluation with its result discarded.
The author's `change/Evolution.hs` may be absent, incomplete or ill-typed. It is
not included in the compiler's discovery source set. There is no dependency on
candidate materialization, facts, semantic validation, query execution or readiness.
In contrast, endpoint schemas and their metadata must be valid: the generated
handles depend on their types and collection declarations. An invalid endpoint
produces an actionable diagnostic, not a stale catalogue or placeholder types.
The author can inspect the fixed installed SDK from a directory outside a KB.

Workspace-scoped discovery is a runtime command: it loads the installed SDK source
tree and native compiler integration, honours `--runtime`, and uses an
ApiInspection interpreter in `kyyn-microhs`, alongside SchemaInspection.
Discovery outside a KB remains catalogue-only.

#### Tool authoring discovery

For the accepted root and an evolution target, expose `Kyyn.Connectors`,
`Kyyn.Judgement` and each generated `Kyyn.Plugins.P_*.*` facade in the same
list/show/symbol commands. Omit internal request rows such as `KyynToolCalls`.
The public judgement facade reexports the question vocabulary alongside `judge`;
it is not advertised as a separate runner-less module.

Tool bindings are generated from the selected plugin declarations and configured
instances, even before a tool is registered. Discovery inspects these bindings,
not the tool implementation; an incomplete or incorrectly typed helper must not
prevent the author from learning the contract. Selected schema/plugin declarations
and configuration must be valid where the generated types depend on them.
Use the same binding generator for discovery and execution.

Looking up a fixed SDK module or symbol reads only the installed catalogue,
including inside a KB or with `--evolution`. Listing adds generated modules when
their source context is buildable. If generation fails, list still returns the
fixed catalogue with `guest.bindings-unavailable` and the cause as diagnostics;
it does not claim to be a complete list. Showing an unavailable generated module
remains a refusal and includes the available catalogue for navigation. Broken
schema or configuration must not hide the documentation needed to repair it.

`Kyyn.Connectors.Tool` documentation states the entry signature
`Input -> Tool (Either FetchError Result)`, its imports and manifest registration
fields. `Kyyn.Judgement.judge` documentation names `JEV_TOKEN`, gives
`kyyn-v2 --kb PATH secret set JEV_TOKEN`, and includes a short `judge`/`ask`
example. CLI output must suffice to write a first tool without reading kernel
source. A tool-compilation refusal includes `tool.signature` with the expected
authored input/output types and imports, alongside compiler details.

Keep the two capabilities separate so fixed discovery does not acquire compiler
or repository dependencies. The host contracts are:

```haskell
data WorkspaceApi :: Effect where
  InspectWorkspaceApi
    :: EvolutionWorkspace
    -> WorkspaceApi m (Either [Diagnostic] WorkspaceCatalogue)
  InspectToolApi
    :: FileTree
    -> WorkspaceApi m (Either [Diagnostic] [ApiModule])

data WorkspaceCatalogue = WorkspaceCatalogue
  { workspace      :: EvolutionWorkspace
  , beforeRevision :: GitRevision
  , modules        :: [ApiModule]
  }

data ApiInspection :: Effect where
  InspectApiModules
    :: FileTree -> [ModuleName]
    -> ApiInspection m (Either [Diagnostic] [ApiModule])
```

`WorkspaceApi` is porcelain. Factor endpoint preparation into one shared porcelain
function used by discovery and evolution capture/evaluation, rather than copying
their snapshot-loading or Before-copy checks. The common source-only preparation
reads the workspace snapshot through EvolutionStore, opens the declared Before
revision through RootOpening, verifies the copied Before source, and opens the
target source. Evolution capture additionally loads the required fact input;
discovery stops at the source endpoints. Discovery neither reads accepted facts
nor requires Before to equal current HEAD: discovery is useful while repairing an
outdated workspace too. Source inspection includes the existing pure schema-metadata
evaluation; it must not execute the evolution, validator or queries.

Reuse `evolutionBindings` and the same schema-closure combination/collision rules
as evolution execution. The compiler source set consists only of captured endpoint
schema closures, installed SDK dependencies and those generated bindings. No new
hand-maintained signatures, metadata inventory or discovery-specific combinator
generator is introduced. ApiInspection is the plumbing adapter to the existing
MicroHs export inspection; its handler manages temporary compilation files.
Only the three selected public generated modules enter the workspace catalogue;
codecs, entry adapters and private root bindings remain absent.

The binding generator emits `-- |` documentation alongside its public declarations.
Document `evolve`, `editBefore` and `edit` with their concrete endpoint types and
the rule that each supplied rationale describes one recorded step and its diff.
Document each collection handle with its logical collection name, root field and
fact type. Derive these details from the checked endpoint contracts and metadata
already used to generate the bindings, not a separate documentation manifest.
Extend documentation coverage tests to these generated declarations.
Generated public declarations spell their types in the facade vocabulary already
presented by `guest module show` (`Collection`, `Edit`, `Evolution`, `Rationale`),
using full schema module names and importing internals only for constructors.

The composition root supplies the installed SDK catalogue and workspace catalogue
to the same navigation functions. It installs WorkspaceApi and its source/compiler
handlers only for workspace-scoped discovery. Inspection creates no durable cache,
does not write the workspace or Git refs, and does not save or check a candidate.
Each invocation describes its captured inputs, not a snapshot promised to remain
current after the command returns. Use the normal source-collision and diagnostic
rules rather than silently selecting one of two differing same-named modules.
In workspace-scoped human output, show declarations defined in each generated
module before its reexports: the workspace-specific operations are why the author
selected this context. JSON retains a flat symbol list with exact origins.

Before implementation is considered complete, prove discovery in a newly created
workspace with an intentionally invalid evolution body; same-schema and changed-schema
targets; empty and populated collections; repair after an invalid target schema;
stale Before without a HEAD restriction; mismatched Before copies; and absence of
private generated exports. Assert that workspace-scoped declarations expose no
internal module qualifiers. Recording handlers must show no fact reads, candidate
operations, semantic validator calls or evolution execution. An installed CLI
journey must discover `edit`, `evolve` and an After collection handle, then use
those signatures to author and check a real evolution. Existing unscoped discovery
must continue to work without a KB, Git or compiler sources.

`kyyn-v2 --kb PATH kb init` creates an empty Haskell-schema KB and commits its
validated root; PATH may not exist yet. It returns the commit revision, branch,
absolute KB path and checkout synchronization status. Human output points to
`evolution new` as the next step. Initialization follows the ordinary exit table:
success 0, refusal 1, operational failure 3, published-but-unsynchronized 4.
Exit 4 includes a `git restore` command scoped to the initialized root, not a new
initialization recovery registry. ADR 0012 owns preparation/publication ordering.

All KB-scoped commands share `--kb PATH`, defaulting to `.`. Resolve relative
paths against the invoking process's working directory. The path selects the KB
directory itself; discover its containing Git repository and derive the KB's
repository-relative prefix internally. Ordinary use needs no separate
`--repository` argument. If the selected directory is not a KB, return an
actionable error rather than creating one or searching for another KB. Explicit
`kb new` owns creation; installation-level operations do not require a KB.
There is no remembered active KB or global selection state.

```sh
kyyn root schema list
kyyn --kb knowledge/sales evolution list
kyyn --kb knowledge/training root schema list
kyyn --kb /path/to/kb evidence fetch microsoft sales-mail
```

A KB may occupy a repository root or a subdirectory; several KBs may share a
repository. Each has its own root, evolutions, plugins and checkout-local secrets.
They share repository history and branch HEAD. Under [ADR 0012](0012-acceptance.md),
acceptance updates the selected KB's root/archive while preserving unrelated
content. Advancing HEAD for one KB also makes another KB's older Before revision
outdated, even if its files did not change. Update that evolution's Before and
prepare/check its candidate again; there is no per-KB HEAD exception. Separate
repositories provide independent histories.

Use consistent verbs: `list` returns a collection, `show` inspects one item,
and `check` validates. `evolution check` captures and evaluates the current
workspace, saves its candidate, then runs candidate validation and required
examples. There is no separate public `evaluate` command. `accept` freshly checks
and publishes the saved candidate without rerunning the evolution. `recover` repairs the checkout
after acceptance as specified by ADR 0012. Inspection never implicitly fetches
evidence, accepts a candidate or invokes a sink. Connector `fetch` is for source
connectors; sink invocation belongs to explicit output publication under ADR 0017.

| Result of evolution check | Saved result | CLI outcome |
| --- | --- | --- |
| Schema/entry compilation or transformation refusal before materialization | No new candidate; any earlier saved candidate remains unchanged | Refused, exit 1; explicitly says no new candidate was produced |
| Candidate validator/query compilation, semantic validation or required example rejection | New candidate and diff retained for inspection | Refused, exit 1; explicitly identifies the saved candidate as failing checks |
| Checks pass | New candidate and diff retained | Succeeded, exit 0, including warnings |

Operational failures remain Failed/exit 3, not successful checks. `show` inspects
the latest saved candidate; following a pre-candidate refusal that can still be
an earlier result. The refusal says so rather than reporting that earlier result
as freshly checked. Checking does not mark a workspace Ready or move HEAD.

Shared options and human/JSON result conventions must behave consistently across
groups. Commands support scripting without mandatory interactive prompts;
results go to stdout, progress/errors to stderr, with meaningful exit codes.
Human output explains the operation and next action, not internal interpreter or
compiler stages. Add commands for demonstrated user tasks, not merely because
another kernel function exists.

For the first CLI, selection uses the checkout's HEAD, with the current local
branch passed explicitly to acceptance/recovery. There is no branch override.
Detached HEAD is a branch-selection refusal (`git.detached-head`) for these
operations: there is no local branch to pass to publication. This is not a
`CheckoutMismatch` with an invented branch. The kernel still checks for a branch
change between selection and publication.
Snapshot reads and creation receive a resolved commit ID; `evolution new --before`
may select an explicit full commit ID. `root show` checks the selected root before
returning its structural value; `root check` returns the check report without the
browsing payload. Creation emits a stable evolution ID, workspace path and selected
Before revision in both human and JSON output, not a name-based selector.
The generated ID follows [ADR 0010](0010-evolutions.md), for example
`000001-add-review-status`; subsequent commands take that complete ID.
Ready/Draft operations do not implicitly evaluate or check.

The CLI adapter renders domain values into one JSON envelope:

```json
{"outcome":"Succeeded","result":{"evolutions":[]},"diagnostics":[]}
```

`--json` emits this structured command result on stdout, including diagnostic
objects for refusals/failures. Human mode writes results to stdout and diagnostics
to stderr. Parser help/usage retains optparse-applicative's standard presentation.
Diagnostics preserve severity, code, message and structured location. Exit codes
are 0 for success, 1 for domain refusal, 2 for invalid CLI usage, 3 for operational
failure, 4 for acceptance requiring checkout inspection/recovery (including an
already-accepted retry), and 130 for user interruption. Code 4 must retain the
accepting revision; it is not an invitation to reapply the evolution. These exits
render [ADR 0019](0019-failures.md)'s outcomes rather than adding domain states.

The host composition root obtains `user.name` and `user.email` through Git
plumbing in the selected repository. Git resolves local, global and included
configuration; the host supplies its HOME/XDG configuration locations explicitly.
Both author and committer use that configured identity, with the host's current
clock time in explicit commit metadata. There is no CLI or author/committer
environment override path. Missing/blank identity is an actionable refusal before
compilation or mutation; already-accepted diagnosis precedes identity lookup.
Malformed configuration is an operational failure. The plumbing operation is:

```haskell
data GitUser = GitUser String String -- configured name and email

readUserIdentity
  :: Git :> es => Repository -> Eff es (Either [Diagnostic] GitUser)
```

HOME/XDG forwarding applies to every Git plumbing call, so global configuration
is visible beyond identity lookup. Existing explicit options still govern the
kernel's operations: `commit.gpgsign=false` for commit construction,
`--no-ext-diff`, `--no-textconv` and `--no-renames` for comparisons,
`--no-filters` when writing blobs, and `-z` for path records. Checkout restoration
follows the user's conversion settings. Configured hooks, including a global
`core.hooksPath`, remain enabled and receive the same explicit process environment
(empty PATH); their failures follow the existing Git publication/recovery outcomes.

Runtime paths come from the
installed layout, with `--runtime` and `--git` development overrides.
Before installing compiler interpreters, the composition root configures the
unpatched compiler's `MHSCPPHS` environment variable once from the resolved runtime;
Kyyn's declaration reader uses that toolchain's preprocessor path directly.
KB-scoped guest discovery loads the SDK and compiler integration; discovery
outside a KB reads only the installed catalogue. Evolution listing,
state changes, archived inspection, recovery, plugin installation and already-accepted diagnosis do
not load the SDK. Host configuration/path resolution and interpretation live in
`kyyn`; parsing and pure rendering live in `kyyn-surfaces`. Shared application
workflows live in porcelain capabilities, reusable by CLI, MCP and Web.
Surfaces do not compose root opening, validation or evolution execution themselves.

### MCP and Web

The CLI's `plugin connector method list/show` resolves registered readers and
inspects their Haskell contracts without invoking a reader. Both allow
`--evolution ID` for inspecting target configuration. `execute` accepts only an
accepted instance, with `--input DHALL` decoded hermetically against its inspected
input contract. A type mismatch retains the normal Dhall diagnostic. Results are
rendered as Dhall by default and structural JSON with `--json`. Unknown methods
and unfetched/incompatible evidence remain explicit errors (ADR 0015); the command
neither acquires evidence nor edits the root.

`root tool list/show` discovers registered KB helpers, including a draft target
with `--evolution ID`. `root tool execute NAME --input DHALL` invokes only the
accepted declaration. Input and output follow the same Dhall/JSON conventions
as connector methods. Listing and showing compile/check declarations but do not
run the helper or read evidence. Guest discovery exposes the generated authoring facades independently of this
registered input/result discovery.

Tool diagnostics use `tool.unknown` for a missing registered name,
`tool.preparation` for invalid source assembly, and `tool.failed` for the helper's
own top-level `FetchError`. A helper can catch a plugin method's typed failure
instead of returning it. An impossible instance/type/method request from a guest
is a protocol failure, not another user-facing tool state.

MCP exports relevant named typed methods and selective discovery, using generated
JSON Schema and structured results. Expose exact source contracts as resources
or files for agent adoption too. The MCP tool specification supports input and
output schemas; do not reduce everything to one untyped command-string tool.
Expose snapshot queries, registered KB investigation tools, plugin methods and
operations on prepared evolution workspaces under ADR 0008; validation is also
an entry point, ordinarily invoked by Kyyn.
Output discovery/preparation and explicit sink invocation follow ADR 0017.
No separate generic KB-tool lifecycle
or proposal-submission effect is needed. Plugin acquisition methods may be exposed
directly without implying a change to accepted knowledge.

For evidence investigation, expose configured instance discovery, fetch history
and the raw payload-free change index alongside plugin-specific read methods.
Registered KB helpers have the same typed discovery/invocation experience; agents
need not read the Kyyn repository or write MCP adapters to compose them.
Change entries identify fetch/predecessor, change kind, evidence ID and citation;
payload interpretation goes through plugin methods, not generic history payloads.

The recipe surface lists/shows root-owned recipes and their
instructions, and queries net pending changes for a recipe and connector instance.
Results identify the selected fetch so authors can explicitly acknowledge that
scope, not an unspecified latest capture. Keep raw acquisition history distinct
from pending work. [ADR 0014](0014-evidence.md) owns the comparison, latest-only
reads, raw-history versus pending-work diagnostics and acknowledgement semantics.
An empty result must not disable investigation/evolution actions or label a task
complete. Evolution review presents the recipe and batch/individual declarations
alongside fact changes, including acknowledgement-only proposals. Fetching and
reading never implicitly acknowledge anything. No agent launcher or workflow
manager is required to expose these tools.
The [curation walkthrough](../walkthroughs/evidence-curation.md) supplies the next
journey. Final CLI spellings belong to its implementation slice, following the
noun-path convention above, not a second generic command-string API.
[MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

Web is designed for human understanding, high-level design, exploration and
review. MCP is designed for agent discovery, technical authoring and reliable
execution. Both expose the central loop: inspect the model, explore facts, try
examples, propose changes, compare consequences and resolve problems. An agent
can review and a human can inspect source or perform a precise technical action.
Presentation emphasis must not become a rigid actor-permission split.

The first local workbench shows selected outputs, records/model, tools/examples,
evolution comparison and source/operation status. It must support contributing
design feedback and examples, not only observing or approving an agent's work.
These are useful content, not a prescribed pane layout or generic dashboard
framework. Anchor the first UI in one reporting journey: inspect a number and
its assumption, contribute a counterexample, compare the candidate, and inspect
diagnostics. Add only the model/record navigation needed to understand that loop.
MCP exposes the same relevant state, including review feedback, without requiring
screen scraping. See ADR 0023 for the shared objects and handoff behavior.
No chat harness, full IDE or arbitrary frontend-plugin framework is a prerequisite.

Generic record browsing uses host-side checked structural values and snapshot
store operations. Titles, timelines and badges consume the checked role metadata
from `CheckedContract` under ADR 0005, not a separate reading or re-inspection of
authored source. Structural filtering/sorting does not require a fresh guest
invocation for every table interaction. Domain interpretation, policy comparisons
and business calculations are explicit named guest queries/views; do not duplicate
them in a host query language or browser code. An explicit query evaluates the
selected snapshot; no query-result cache is required. Displaying an already
prepared artifact is a separate operation, not an implicit cached query result.

Record/query browsing is independent of output sinks. Output controls select a
declared renderer/sink binding, prepare its typed input, and explicitly invoke it
when the caller wants to update an external output. Refreshing a view or inspecting
a query result never invokes a sink. Renderers may compose multiple queries; the
generated registration and preparation contract is owned by ADR 0017, not a
browser-side query graph or a separate UI renderer registry.

## Alternatives and consequences

Reject CLI-only as a workaround for an internal codec problem, and reject MCP-only
as the core application API. User confirmation/delegation belongs to explicit
operation intent/configuration, not assumptions that one transport is human and
another cannot be. Initially local single-owner use; do not imply multi-tenant web
security. Bind locally and protect the control surface from unrelated web origins.

## Verification

The same request via CLI/MCP/web produces the same domain result and transition.
Interface coverage follows user journeys, not mechanically identical buttons
and endpoints. Web and MCP are designed and tested in each end-to-end slice,
not bolted on after a CLI implementation has fixed the product's shape.
Listing evolutions does not start MicroHs or plugins. A fresh agent can discover
one relevant tool without receiving the entire installed catalog. A human can
explain a report change without reading protocol envelopes or Haskell internals.
