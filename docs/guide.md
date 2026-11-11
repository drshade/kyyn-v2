# Authoring a Kyyn knowledge base

Kyyn keeps a knowledge base's facts, schema and executable meaning together.
Agents inspect evidence and prepare changes; humans and agents review those
changes before accepting them. This guide explains that workflow. Use the CLI
and guest API discovery for exact commands, types and functions.

`kyyn-v2 guide` reads this guide without a KB. `--json` returns its Markdown in
`result.markdown`. The development executable is named `kyyn-v2`.

## Discover what you need

Select a KB with `--kb PATH`; the default is the current directory. A KB can be
inside a larger Git repository. Use `--json` for structured results; typed
arguments use Dhall, and typed human-readable results generally do too.

Start with the relevant command group rather than guessing its syntax:

```sh
kyyn-v2 --help
kyyn-v2 root --help
kyyn-v2 evolution --help
```

Continue with `--help` at any level. The `root` groups expose facts, schemas,
collections and registered entry points; their `list` and `show` commands reveal
what this KB contains. Entry-point descriptions expose input/result contracts
before execution. Read a recipe's instructions before working on its task.

For Haskell authoring, discover the actual exports and generated bindings:

```sh
kyyn-v2 guest module list
kyyn-v2 guest module show Kyyn.Edit
kyyn-v2 guest symbol show Kyyn.Edit.update
kyyn-v2 guest module show Kyyn.Workspace.Evolution --evolution ID
```

Replace `ID` with your draft's ID. Inside a KB, discovery includes SDK, authored
and generated modules. Normal discovery reads the accepted Git revision, not
uncommitted source. `--evolution ID` selects a draft's target source where
supported. Its schema must compile, but its evolution body may be unfinished.
Do not guess generated module names: list them in the context you are authoring.

Useful starting modules are `Kyyn.Schema`, `Kyyn.Validation`, `Kyyn.Evolution`
and `Kyyn.Query`. Generated modules such as `Kyyn.Connectors`, `Kyyn.Agentic`
and the workspace facades depend on the selected KB or evolution. Module/symbol
discovery exposes signatures, constructors and doc-comments. Add `-- |` comments
immediately above your own declarations to make them discoverable too.

Plugin-specific setup belongs in `plugin guide PLUGIN` (installed) or
`plugin guide TAP/PLUGIN` (available). Use connector schema/method discovery for
the exact configuration and callable interfaces, not a copied example from
another KB.

## Understand what you are changing

The accepted `root/` contains Haskell source, declarations in `kb.dhall`,
materialized Dhall facts, recipe definitions/state, vendored plugin source and
configuration, and `flake.nix`/`flake.lock`. The flake declares the guest build;
the lock pins its compiler, SDK and library inputs. Haskell types are authoritative; derived contracts and
bindings describe those types rather than introducing another schema to maintain.

An evolution workspace identifies an immutable input revision and has two editable parts:

- The manifest selects stored facts and recipe states from a Git revision; old application code is not compiled.
- `target/` holds proposed schema, validator, helper code and configuration.
- `change/Evolution.hs` prepares stored data and edits the typed target. Helper modules live alongside it.

Author changes in that workspace, not directly in the accepted facts. Kyyn
materializes the evaluated result when it accepts the evolution. Code/config
changes in `target/` are part of the proposal even when the function is
`identityEvolution`; inspect the source diff as well as the result report.

The ignored `.kyyn/` directory holds checkout-local data, including credentials
and fetched evidence. A Git clone does not bring those with it. Evidence is
captured source material, not accepted KB truth. Fetching does not mutate facts;
an evolution does. Publishing an output changes an external destination, not
the accepted root.

## Create, check and accept an evolution

For a new KB, `kb init` creates an empty root and its first commit using the
configured Git identity. It writes a complete pre-locked flake from the host's
repository revision, without resolving dependency versions. Its first check may
fetch the locked inputs and build the guest. For an existing KB, inspect its facts, schema and
relevant recipes first.
The initial source and Dhall files live in [the KB template](../templates/kb/);
the repository flake adds its pinned `flake.nix` and `flake.lock` at build time.

```sh
kyyn-v2 evolution new first-collection
```

Use the returned ID and workspace path. An ordinary, ad hoc evolution can change
schema, facts, code, configuration and recipe definitions. A recipe-based
evolution has the narrower role described below.

### Add the first collection

This complete example starts from a newly initialized empty KB. In the draft,
edit `target/src/Schema.hs` in place:

KB modules use GHC2024 plus `OverloadedStrings`, `DeriveAnyClass`,
`OverloadedRecordDot`, `DuplicateRecordFields`, `NoFieldSelectors`,
`RecordWildCards`, `BlockArguments` and `MultiWayIf`. Compilation and discovery
use the same defaults. Module pragmas can enable or disable extensions locally.

The standard guest environment exposes the Kyyn SDK and build support plus
`aeson` (JSON), `bytestring`, `text`, `containers`, `time`, `cryptohash-sha256`,
`lens`, `generic-lens`, `scientific` (exact JSON numbers), `attoparsec` (parsing)
and `http-types` (HTTP/URI encoding), alongside GHC's bundled libraries. Use these for data
handling, dates, hashing and typed record updates. For example, import
`Data.Time`, `Crypto.Hash.SHA256` or `Data.Generics.Product.Fields` directly.

To add another library, edit the `mkGuest` call in the KB's `flake.nix`:

```nix
value.kyyn-guest = kyyn.lib.mkGuest {
  inherit system;
  src = self;
  dependencies = h: [ h.vector ];
};
```

The dependency comes from the pinned package set. Changing library versions means
changing the flake input or package-set selection and explicitly updating its
lock; ordinary Kyyn checks never update it for you.

```haskell
module Schema where
import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Schema

data Todo = Todo { title :: Text }
  deriving stock (Eq, Show, Generic)
  deriving anyclass Contract
data Root = Root { todos :: [Fact Todo] }
  deriving stock (Eq, Show, Generic)
  deriving anyclass Contract

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
```

The existing `Schema.Root` and `Schema.metadata` references in `target/kb.dhall`
already select this module. Replace `target/src/Validate.hs` with:

```haskell
module Validate where
import qualified Data.Text as Text
import Schema
import Kyyn.Schema
import Kyyn.Validation

validate :: Root -> ValidationReport
validate (Root todos) = ValidationReport
  [ errorDiagnostic "todo.title" "Todo title must not be empty"
  | Fact _ (Todo name) <- todos, Text.null name
  ]
```

Write `change/Evolution.hs`:

```haskell
module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified Schema as Target
import qualified Kyyn.Workspace.Target as Collections

evolution :: Evolution Target.Root
evolution = prepare (pure ()) $
  edit (Rationale "Record the first task." [])
    (within Collections.todos $
      append (Fact (FactId "todo-001") (Target.Todo "First task")))
```

`prepare` first runs typed operations on stored data, then decodes it using the
new target contracts. New collections start empty. Residual fields need an
explicit `putField`; Kyyn does not invent values. A system-labelled
`TargetProjection` step records this boundary using the workspace explanation.
`edit` then changes the typed target KB. Compose ordered edits with `<>`; use
`mempty` when preparation is the only authored work. Fact IDs are identities, not
list positions. Each operation records its rationale and declared evidence.

Keep schema module names stable. Only target code and the change helpers compile.
When stored shapes change, define small input decoding types in `change/` and use
`migrateCollection`, `migrateField` or `migrateRecipe`. Their input types describe
the stored shape, not the old executable. `migrateRecipe` converts stored state;
`updateRecipe` changes already decoded target state or its definition.

`kyyn-v2 evolution new NAME --input-types` can scaffold those input declarations
from stored Dhall shapes. `change/Input/README.md` identifies empty collections
whose payload shape cannot be recovered. Text carriers do not recover historical
scalar semantics; replace them with compatible target types where useful. Empty
lists and `None` retain their stored annotations. The generated declarations are
editable helpers, not a second schema that must be maintained.

Discover `Kyyn.Workspace.Target` for collection handles and
`Kyyn.Workspace.Target.Fields` for residual-field handles. Use explicit
rename/remove operations for stored fields, collections, facts and obsolete
recipes. A changed fact ID is a removal and addition; the authored target validator must check
references to the removed identity. Unchanged compatible data needs no conversion.
For later same-schema edits, use `prepare (pure ())` with the desired `edit`s.

### Review the result

```sh
kyyn-v2 evolution check ID
kyyn-v2 evolution show ID
kyyn-v2 evolution ready ID
kyyn-v2 evolution accept ID
```

`check` evaluates the workspace, saves a candidate/diff and validates the candidate.
Repeat it after edits. A validation failure leaves the new result inspectable.
A compilation or transformation failure can leave an earlier saved candidate
unchanged: heed the diagnostic rather than treating that old report as a fresh result.

Inspect the proposed facts, rationales and source/configuration changes. Type
correctness and validation are useful checks, not proof that the requested change
is sensible. Mark Ready when the proposal is ready for the agreed review; accept
when authorized by that workflow.

Acceptance rechecks the saved result without rerunning the evolution. It requires
unchanged proposal inputs and the same local Git head as Before. If head advanced,
update the manifest base revision and preparation, then check and review again. Acceptance
commits the new root and retained workspace; it does not push remotely. Accepted
evolutions are history, not programs replayed on every read.

If a diagnostic says a commit succeeded but checkout synchronization failed,
inspect `git status` and follow the supplied Git restore instructions rather than
blindly repeating acceptance.

## Use plugins and evidence

Taps are plugin catalogues. Refresh a tap to discover its packages and read their
guides before installation. Install or update plugin source in an evolution;
installation creates `target/plugins/config/` and returns the KB-relative path for
this plugin's configuration file, plus guide, schema and check commands. From the
KB directory, run the printed guide command, copy its instance example to that
path, and fill in your settings. Run the printed schema command for the exact
configuration type, then the check command to validate the draft. In JSON, these
hints are under `result.configuration`; the file is not created or overwritten.
Configure named connector instances in its `target/plugins/config/` files using
the advertised schema. One plugin can provide multiple connectors and instances.
An instance's `binding` names its generated guest value in `Kyyn.Connectors`.

Installation copies committed upstream source. Reinstalling replaces the package,
including local edits to it, but preserves instance configuration. Review the
upgrade in the evolution. A local source checkout's uncommitted edits are not
installed. Tap declarations live in `taps.dhall`; tap edits are separate Git
working-tree changes, not evolution fact edits.

Acquisition uses accepted connector configuration. Fetch, then inspect current
evidence or call the plugin's typed captured-read methods. Methods may offer a
more useful view than the raw payload. KB helpers can compose these methods
across instances; generic evidence reads are also available through generated
connector `Evidence` modules. Discover those modules rather than writing their
codecs or plumbing yourself.

Only the latest captured contents are available. A `Truncated` payload means the
ID/fingerprint remains but the content is unavailable; it is not a deletion.
Captured reads do not silently fetch missing contents. Plugin results containing
`BlobRef`s can expose local paths for attachments; those paths are temporary
captured material, not durable published outputs. Refetching or clearing evidence
does not change accepted facts or recipe state.

Kyyn does not require every item of evidence to be processed. Choose what matters
for the task. If progress tracking is useful, model it in recipe state. Cite useful
source identifiers in rationales; a citation does not guarantee permanent access
to that evidence.

To investigate a slow acquisition, enable optional timing output:

```sh
KYYN_TIMINGS=1 kyyn-v2 --kb /path/to/kb --json evidence fetch microsoft-graph meetings \
  --options '{ since = Some "2026-10-27T12:00:00Z" }' > result.json 2> timings.log
```

Choose a `since` before the current time. Ordinary sync uses its saved overlap;
an explicit `since` controls the measurement window. Use a disposable KB when
measuring first downloads rather than reuse of existing evidence.

Independent Meetings requests run with up to four host workers. Set
`KYYN_FETCH_CONCURRENCY=1` to compare serial execution, or choose a width from
`1` through `8`. The override applies to this process's evidence fetches; it
is not stored in KB configuration or sync positions. Pagination within each
workflow remains sequential. A retry wait holds the current request round open.

Concurrency timing lines report each round's width, request count, local/remote/
waiting counts and wall time, with peak active requests and HTTP status totals
in the summary. Status counts include blob downloads. The summary also totals
round time and time spent in rounds containing waits. HTTP duration sums can
exceed wall time when requests overlap.

Timing output goes to stderr; stdout remains the normal JSON result. Only the
literal `KYYN_TIMINGS=1` enables it. Sync operations emit start/completion events
with a matching call number, followed by operation counts and elapsed-time totals.
HTTP events show method and status (or transport failure), blob downloads show
status and stored bytes, and waits show requested seconds. Evidence begin, read,
publication and overall acquisition spans separate network work from local storage.
Cancellation records an aborted span and emits the accumulated summary when the
process can unwind normally; forced termination cannot guarantee a final summary.

The command and acquisition spans contain child operations: do not add them to
HTTP, blob or wait totals. A blob download includes network and storage time.
Requests are counted individually, including retries. Waits are plugin-requested
delays, not proof of a particular throttle unless paired with a 429/503 response.
These are capability-level measurements; they do not label provider-specific
stages such as calendar discovery versus meeting resolution. URLs, headers,
request/response bodies, evidence IDs and payloads are omitted from sync events.

Secrets are configured separately for each checkout and stored as plaintext in
ignored local storage. Use `secret set` with its hidden prompt or stdin rather
than placing credentials in source, connector options or shell arguments. Follow
the plugin/provider guide for the required secret names.

## Add a browser view

Domain views are ordinary HTML/JavaScript pages for readers. They get KB data
through named queries; they do not use raw fact endpoints or publish outputs.
Start an evolution and create a page under its `target/views/<directory>/`:

```sh
kyyn-v2 evolution new training-view
```

In the returned draft's `target/kb.dhall`, replace the empty `views` list with:

```dhall
views =
  [ { name = "training_register"
    , description = "Browse the training register"
    , path = "views/training-register/index.html"
    }
  ]
```

Use an existing named query, discovering its arguments with
`kyyn-v2 root query show NAME`, or author and register one in the same draft.
For example, a KB with a `trainingRegister` query taking `fromDate`, `toDate` and
`minConfidence` can put this in `target/views/training-register/index.html`:

```html
<!doctype html>
<meta charset="utf-8">
<title>Training register</title>
<script src="/kb/kyyn.js"></script>
<h1>Training register</h1>
<pre id="report">Loading…</pre>
<script>
const params = kyyn.params();
const input = {
  fromDate: params.get('from') || '2026-11-01',
  toDate: params.get('to') || '2026-11-30',
  minConfidence: { tag: 'Low' }
};
kyyn.query('trainingRegister', input)
  .then(result => document.querySelector('#report').textContent = JSON.stringify(result, null, 2))
  .catch(error => document.querySelector('#report').textContent = error.message);
</script>
```

Replace that query name and argument with your KB's actual contract. JSON uses
the same structural representations as CLI JSON output: strings remain strings,
union cases use `tag`, and exact numeric scalars use their declared encoding.
Unit arguments are `{}`. The host checks arguments before invoking the query;
errors preserve Kyyn's diagnostics. The helper rejects an Error with `status`,
`outcome`, `diagnostics` and `context` for a failed query response.

```sh
kyyn-v2 web serve --evolution ID --port 8080
```

Open the printed `/kb/` address and select the view. The page and its CSS/JS/assets
serve immediately, even if the evolution has never checked or its Haskell is
broken. Edit a page file and refresh; no guest rebuild or automatic browser reload
is required. Relative asset URLs resolve within that view's directory.

Queries use the latest successfully checked candidate, so run
`kyyn-v2 evolution check ID` to provide query data. A failed check does not replace
that successful candidate. Until a successful check exists, query calls return a
diagnostic requesting one, while the page stays available. In this first slice,
queries keep using that candidate after other source edits too; recheck explicitly
to update their data. Non-view freshness detection is tracked in #304.

Before acceptance, check all changes again, inspect the result, and follow the
normal ready/accept workflow. Stop the draft server with Ctrl-C, then run:

```sh
kyyn-v2 web serve
```

Accepted serving reads committed source and facts, ignoring uncommitted edits.
Each request selects the accepted revision anew; accepting another evolution is
visible on refresh. A page and its later query requests can see different accepted
revisions. This is not a browser-session snapshot or a query-result cache.

Pages include `kyyn.js` explicitly. `kyyn.viewUrl('training_register', {from:
'2026-11-01'})` constructs a link to a declared view and encodes its parameters;
an undeclared view is an error. `kyyn.params()` returns `URLSearchParams`, so use
`.get(...)` or `.getAll(...)`. View parameters have no declared types; checking
happens only when the page passes values to a query.

The server binds only to `127.0.0.1`, defaults to port 8080, and supports `--port 0`
to choose a free port. It has no authoring workbench, mutation endpoints, static
publishing or cross-view isolation. Host-header validation is deferred to #304;
this first slice is not hardened against DNS rebinding. Keep routine use with
personal-data KBs for after that follow-up.

## Choose the right entry point

- **Query:** a typed read of accepted KB facts. Register it in `kb.dhall` to expose
  a stable interface to consumers. `KyynQueryBindings` supplies the root-specific
  `Query` type and collection bindings; `Kyyn.Query` supplies read operations.
- **Tool:** a typed helper that can use permitted host capabilities, including
  captured evidence and model calls. Put it in `src/` and register it in
  `kb.dhall`. Executing a tool does not itself accept changes to the KB.
- **Recipe:** instructions or an authored flow for a recurring task, with typed
  state. A recipe's proposed updates still go through an evolution.
- **Output:** a registered query/renderer connected to a configured plugin sink.
  Preview renders; publish invokes the sink and can change the outside world.

Inspect existing registrations in `kb.dhall` before adding your own. `show`
exposes contracts; discovery exposes the Haskell implementation interfaces.
Prefer composing existing helpers to reproducing their integration logic.

### Recipes and model flows

Recipes have a definition and mandatory state; use `()` if nothing needs to be
remembered. Create/update/remove them through the evolution combinators, providing
initial or transformed state. Do not hand-author `recipes.dhall` or recipe state
files in `target/`: those are evaluated data.

Open recipes contain agent instructions. Creating an evolution with `--recipe`
generates `RecipeEvolution Root RecipeState`; it can change domain facts and only
that recipe's state. Use `recipeEdit`, `editFacts` and recipe-state operations from
its generated facade. Use an ad hoc evolution for schema, code, configuration or
recipe-definition changes.

Closed recipes run an authored flow with this shape:

```haskell
review :: Flow (RecipeInput Root Request ReviewState)
               (RecipeProposal RootEdit ReviewState)
```

It receives the accepted root, request and state, and returns proposed fact-edit
steps with rationales plus the complete next state. Inspect `Kyyn.Recipe` and
generated `Kyyn.Workspace.FactEdits` for those constructors. Generated
`Kyyn.Workspace.Target.RecipeTypes.*` and `RecipeFlows.*` handles supply the typed
recipe definitions used in an ad hoc evolution; list them in that draft's context.

A successful closed run creates a draft with a saved proposal and
`evolution = frozen`. Checking and accepting it do not rerun model calls or read
new evidence. Inspect the proposal through the normal review path. Describing a
closed recipe shows its flow structure without executing its actions.

For model work, use Agentic through generated `Kyyn.Agentic`; the same flow can
be exposed as a tool or composed into a closed recipe. Configure provider/model
and a secret name in `target/model.dhall`:

```dhall
{ provider = < OpenAI | Anthropic >.Anthropic
, model = "your-provider-model-name"
, credential = "MODEL_KEY"
}
```

Set the actual key separately. Agentic's SystemOne judgements use Jev;
SystemTwo uses the configured OpenAI or Anthropic provider. Consult
`Agentic`, `Agentic.Questions` and `Kyyn.Agentic` through API discovery before
authoring a flow. Use record-dot access for upstream library records.

Define model-facing types with upstream Agentic's `Contract` and GHC `Generic`:

```haskell

import Agentic.Contract (Contract)
import Data.Text (Text)
import GHC.Generics (Generic)

data Task = Task { title :: Text }
  deriving (Generic, Contract)
```

Use `Text` for string fields in contract types, including paths. `String` and
`FilePath` are lists of `Char` and do not have a supported contract. Path values
are converted to filesystem paths at the host boundary.

That single derivation supplies the
structural contract interpreted by Kyyn's describe, storage and model codecs.
Nonempty enums can also derive `Options`; custom labels and ordering use an
ordinary instance. Types and flows may share a module. Applied types and containers
use compositional instances where their shapes are supported; there is no blanket
monomorphic-only or wrapper requirement. No generated contract import or handwritten
wire codec is needed. Root-specific collection/edit bindings remain generated;
the Root schema must not import its own bindings.

### Render and publish

A renderer is a query: it may combine several reads or other queries to produce
the sink's input. Register the query, configure the sink, and add an `outputs`
entry to `kb.dhall`, for example:

```dhall
{ name = "website", description = "Publish the KB page", query = "page"
, sink = { plugin = "local-file", instanceName = "website", method = "publish" }
}
```

The compiler checks renderer/sink Haskell type compatibility, not just similar
serialized shapes. Discover the sink's input/configuration in its plugin guide
and schema; `root output show` exposes the bound contracts and defaults.
Query arguments and sink invocation options are separate typed values.

Preview writes nothing. Publish rerenders from the selected accepted root and
invokes the sink; it is not an evolution acceptance step. A reported uncertain
result means an external write may have happened: inspect the destination before
retrying. The local-file plugin's guide owns its path and replacement behavior.

## Script settled work

Use `--json` and stop on nonzero exit status. An external agent can prepare/check
a draft and mark it Ready; a later acceptance step fails if it remains Draft.
Agree whether a task is to prepare a proposal or also accept/publish it. These
CLI workflows need no daemon or built-in scheduler.

## Install

Install Nix and Git, then install Kyyn from its repository flake:

```sh
nix profile install github:drshade/kyyn-v2
```

The flake builds the host executable `kyyn-v2`. Nix supports Linux, macOS and
Windows through WSL2; it supplies the compiler and libraries rather than requiring
a global Haskell toolchain. Contributors use `nix develop` and `nix build .#kyyn`
in the repository; see [development setup](PROJECT-PRACTICES.md#development-setup).

A KB has its own build environment inside its accepted root:

```text
root/
  flake.nix       guest build and library dependencies
  flake.lock      pinned compiler, SDK and external inputs
  kb.dhall        schema, query and tool declarations
  src/            authored Haskell
  facts/          materialized facts
```

Initialization pins the SDK input to the host's repository revision. Add Haskell
libraries through the KB's flake and update its lock explicitly as part of an
evolution. Checks may fetch or build locked dependencies; they do not update pins.
The guest build exports `packages.${system}.kyyn-guest`. Updating the installed
host does not rewrite existing KB locks or plugin source. If a KB's description
no longer matches the host protocol, repair its SDK pin/code and check it again.

### Explore a complete evidence capture

Read all current payloads without writing a recipe or opening cache files:

```sh
kyyn-v2 --kb /path/to/kb --json evidence show microsoft-graph meetings --all > meetings.json
```

The normal response envelope contains `result.selection`, `result.latest` and
`result.items`. Each item has an ID, fingerprint, external references, a payload
(`Available` with a value, or `Truncated`), and a `blobs` array of references and
usable local paths. Binary content is not embedded. No provider requests are made.
An empty captured result is different from an instance that has never been fetched.

To require the same capture as a preceding inspection, add
`--expect-fetch FETCH_ID`, using `result.selection.fetch` from that inspection.
A mismatch refuses the operation; this cannot retrieve an older capture.
The command reads one index and buffers all selected payloads before returning a
single JSON response. Do not refresh or clear that instance while inspecting it;
blob paths can cease to exist after a later refresh or clear.

### Inspect the last successful sync

`evidence list PLUGIN INSTANCE` displays a report from the last successful fetch.
The JSON forms of list, single-item show and bulk show expose the same value as
`result.latest.report`. Discover its schema with `plugin connector show PLUGIN
INSTANCE` (`reportType` in JSON). A connector without a report returns `null`;
a connector using a unit report returns `{}`. Human output previews long lists
and states how many entries were omitted; use `--json` for the complete report.

The Meetings report records the effective window, examined mailbox IDs for
application authentication, refusals, unavailable mailboxes, skipped meetings
and potential attendance-list coverage limits. Each issue identifies the source
context and processing stage. It describes that fetch, not the whole accumulated
capture. A successful fetch with no new artifacts still updates its report. A
failed attempt leaves the previous successful report intact.

The report is public connector data; private resume positions are not exposed.
This index format requires clearing and refetching every existing connector
capture after upgrading the executable, including stateless Directory and
local-file captures. Upgrade incompatible vendored plugin source in an evolution
before fetching again. A fresh Meetings fetch defaults to 30 days;
use its explicit `since` option when rebuilding a longer historical window.
