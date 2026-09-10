---
id: 0018
title: 'CLI, MCP and web share application operations'
status: proposed
date: 2026-09-09
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
    list
    show <plugin>
    update <plugin>
    connector
      list <plugin>
      show <plugin> <connector>
      fetch <plugin> <connector>
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

`guest module list/show` and `guest symbol show` describe the installed public SDK,
independently of KB selection. Public modules come from the SDK packages' exposed
module declarations; checked MicroHs exports determine symbol membership, including
reexports and their defining module. Display authored signatures and type aliases
when available, preserving useful names such as `Edit` and `Lens'`. Distinguish
checked expanded signatures from source declarations rather than claiming they
are the author's spelling. Private constructors are not exposed by reading their
source declarations.

Show data/newtype declarations projected to the exported constructors and
selectors: abstract types have only a header, and constructors with private
selectors use positional arguments. Do not include derived instances. GADTs may
be presented in equivalent lowered existential/equality-constraint syntax with
source-safe parameter names. Mark checked-signature fallbacks in a comment;
all catalogue entries are compiler-checked.

Documentation uses a small source convention: a `-- |` block immediately above
a signature or type declaration, continued by adjacent `--` lines. Attach it to
the defining symbol and retain it through reexports. Store the text with the
catalogue and expose it in human and JSON output; ordinary implementation comments
are not documentation. This does not promise full Haddock parsing or rendering.

Generate this fixed catalogue from the staged SDK during the build and ship it
as Dhall in the runtime bundle. Discovery reads the catalogue through filesystem
and Dhall plumbing; it does not select a KB, invoke Git or compile guest code.
Human output supports selective exploration and `--json` returns the same symbols
as structured data. A missing module or symbol is a refusal with a navigation hint.

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
kyyn --kb /path/to/kb plugin connector fetch microsoft sales-mail
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
installed layout, with `--runtime` and `--git` development overrides. Listing,
state changes, archived inspection, recovery and already-accepted diagnosis do
not load the SDK. Host configuration/path resolution and interpretation live in
`kyyn`; parsing and pure rendering live in `kyyn-surfaces`. Shared application
workflows live in porcelain capabilities, reusable by CLI, MCP and Web.
Surfaces do not compose root opening, validation or evolution execution themselves.

### MCP and Web

MCP exports relevant named typed methods and selective discovery, using generated
JSON Schema and structured results. Expose exact source contracts as resources
or files for agent adoption too. The MCP tool specification supports input and
output schemas; do not reduce everything to one untyped command-string tool.
KB tools expose queries and operations on prepared evolution workspaces under
ADR 0008; validation is also an entry point, ordinarily invoked by Kyyn.
Output discovery/preparation and explicit sink invocation follow ADR 0017.
No separate generic KB-tool lifecycle
or proposal-submission effect is needed. Plugin acquisition methods may be exposed
directly without implying a change to accepted knowledge.
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
