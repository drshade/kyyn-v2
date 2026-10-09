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
materialized Dhall facts, recipe definitions/state, and vendored plugin source
and configuration. Haskell types are authoritative; generated contracts and
bindings describe those types rather than introducing another schema to maintain.

An evolution workspace has three useful parts:

- `before/` and its selected Git revision identify the starting point.
- `target/` holds proposed schema, validator, helper code and configuration.
- `change/Evolution.hs` computes the fact and recipe changes.

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
configured Git identity. For an existing KB, inspect its facts, schema and
relevant recipes first.

```sh
kyyn-v2 evolution new first-collection
```

Use the returned ID and workspace path. An ordinary, ad hoc evolution can change
schema, facts, code, configuration and recipe definitions. A recipe-based
evolution has the narrower role described below.

### Add the first collection

This complete example starts from a newly initialized empty KB. In the draft,
replace `target/src/RootV1.hs` with `target/src/RootV2.hs`:

```haskell
module RootV2 where
import Kyyn.Schema

data Todo = Todo { title :: String } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
```

In `target/kb.dhall`, change `schemaType` to `"RootV2.Root"` and
`schemaMetadata` to `"RootV2.metadata"`. Keep `validator = "Validate.validate"`
and replace `target/src/Validate.hs` with:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Validate where
import RootV2
import Kyyn.Schema
import Kyyn.Validation

validate :: Root -> ValidationReport
validate (Root todos) = ValidationReport
  [ errorDiagnostic "todo.title" "Todo title must not be empty"
  | Fact _ (Todo name) <- todos, null name
  ]
```

Leave Before unchanged. Write `change/Evolution.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified RootV1 as Before
import qualified RootV2 as After
import qualified Kyyn.Workspace.After as Collections

evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution =
  evolve (Rationale "Start tracking work." [])
    (onFacts (\Before.Root -> Right (After.Root [])))
  >=> edit (Rationale "Record the first task." [])
    (within Collections.todos $
      append (Fact (FactId "todo-001") (After.Todo "First task")))
```

`evolve` changes the schema; `onFacts` preserves recipes while transforming domain
data. `edit` uses state operations to change the resulting KB. Generated collection
handles focus edits on the right collection. Fact IDs are stable identities, not
list positions. Put explanations and supporting evidence references in each
step's `Rationale`.

For a later same-schema edit, import the current schema as both Before and After
and use `edit` without `evolve`. Discover collection updates and optics through
`Kyyn.Edit` and `Kyyn.Optics`; ordinary record updates preserve unchanged fields.
You do not write the generated bindings or the execution wrapper.

Before and After compile together. Give changed schema modules distinct names
and import them with readable aliases. An unchanged shared type can be imported
by both endpoints; declaring the same-looking type twice creates distinct Haskell
types and requires conversion. Do not change a shared module out from under Before.

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
update Before and the transformation, then check and review again. Acceptance
commits the new root and retained workspace; it does not push remotely. Accepted
evolutions are history, not programs replayed on every read.

If a diagnostic says a commit succeeded but checkout synchronization failed,
follow its recovery instructions rather than blindly repeating acceptance.

## Use plugins and evidence

Taps are plugin catalogues. Refresh a tap to discover its packages and read their
guides before installation. Install or update plugin source in an evolution;
configure named connector instances in its `target/plugins/config/` files using
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

Secrets are configured separately for each checkout and stored as plaintext in
ignored local storage. Use `secret set` with its hidden prompt or stdin rather
than placing credentials in source, connector options or shell arguments. Follow
the plugin/provider guide for the required secret names.

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
`Kyyn.Workspace.After.RecipeTypes.*` and `RecipeFlows.*` handles supply the typed
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

Define model-facing data types in modules independent of flows/generated bindings.
Import `Kyyn.Contracts.<defining module>.<type> ()` in a flow module to bring the
generated contract into scope. Nonempty enums also get generated `Options`.
Use monomorphic data/newtypes; wrap standalone compound types when needed. Do not
also define a competing instance. No handwritten wire codec is needed.

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

For development source builds, run `bash tools/install-cli.sh` from the Kyyn
repository; [build prerequisites](PROJECT-PRACTICES.md#development-setup) apply.
It installs `~/.local/bin/kyyn-v2` and its runtime bundle. Installed users need
Git, not the Haskell/Node/C toolchains. Plain `cabal install` does not install
the runtime assets. Rerun the installer to update; KBs are left untouched.
An executable update can make a KB's vendored plugin source incompatible with the
new SDK; updating the executable does not update those plugins.
