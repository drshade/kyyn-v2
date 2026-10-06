# Kyyn user guide

Kyyn stores a knowledge base's facts and executable meaning together. Work in an
evolution, check its proposed result, review it, and accept it into Git. The
development executable is `kyyn-v2`; it does not replace kyyn-v1's `kyyn`.

- [Install](#install) and [create a KB](#select-or-create-a-kb)
- [Evolve, check and accept](#create-check-and-accept-an-evolution)
- [Secrets](#secrets), [plugins and taps](#plugins-and-taps), [evidence](#fetch-and-inspect-evidence)
- [Tools and models](#tools-and-models), [recipes and curation](#recipes-and-curation)
- [Browse facts/schema](#explore-schemas-collections-and-facts), [discover APIs](#discover-apis-while-authoring)

## Install

From this repository, with the [build prerequisites](PROJECT-PRACTICES.md#development-setup):

```sh
bash tools/install-cli.sh
```

This installs the complete runtime under `~/.local/lib/kyyn-v2` and links
`~/.local/bin/kyyn-v2`. Add `~/.local/bin` to PATH if necessary.
A custom prefix is supported: `bash tools/install-cli.sh /path/to/prefix`.
Plain `cabal install` does not install the required runtime assets.

The installed bundle runs KB code without GHC, Cabal, Node or a C compiler.
Git must be available. This is a development source build, not a published
cross-platform release. Rerun the installer to replace the bundle; KBs are
untouched. To uninstall, remove the dedicated executable link and bundle directory.

## Select or create a KB

```sh
kyyn-v2 --kb /path/to/my-kb kb init
kyyn-v2 --kb /path/to/my-kb root check
kyyn-v2 --kb /path/to/my-kb root show
```

`--kb` defaults to the current directory. The KB may be a subdirectory of a
larger Git repository, and one repository may contain several KBs. Use
`--json` before the command for structured results. `--help` works at every
command level; `--runtime DIRECTORY` and `--git EXECUTABLE` are optional overrides.

Initialization creates and commits an empty root using your configured Git
identity and initial-branch preference. Configure `user.name` and
`user.email` first. In an existing repository it preserves unrelated files
and staged changes; it refuses an existing root or evolutions directory.

The new KB contains:

- `root/src/RootV1.hs`: the current schema and metadata.
- `root/src/Validate.hs`: the validator.
- `root/kb.dhall`: root and entry-point declarations.
- `root/facts/`: materialized Dhall facts.
- `evolutions/`: drafts and retained accepted workspaces.
- `taps.dhall`: plugin catalogue sources, initially the first-party tap.

Private checkout data lives under the Git-ignored `.kyyn/` directory. Secrets
and evidence are local to this checkout, not copied by cloning.

## Create, check and accept an evolution

```sh
kyyn-v2 --kb PATH evolution new first-collection
kyyn-v2 --kb PATH evolution list
```

Use the returned ID, such as `000001-first-collection`, in place of `ID` below.
The six-digit prefix orders creation, not acceptance. In `evolutions/ID/`,
edit `change/Evolution.hs` and the proposed source/configuration under
`target/`. `before/` records the source schema; the manifest selects its Git
revision. The generated entry is an identity evolution until edited.

### Add the first collection

In a draft created from an empty KB, replace `target/src/RootV1.hs` with
`target/src/RootV2.hs`:

```haskell
module RootV2 where
import Kyyn.Schema

data Todo = Todo { title :: String } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo] } deriving (Eq, Show)

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "todos" "todos" []]
```

Change the `RootV1` references in `target/kb.dhall` and
`target/src/Validate.hs` to `RootV2`. Leave the Before copy unchanged.
Then write `change/Evolution.hs`:

```haskell
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

`evolve` changes schema; `onFacts` preserves recipes while transforming domain
data. `edit` takes a State action. In a collection, use `current`,
`append`, `update` and `remove` by FactId. For example, in a later
same-schema evolution:

```haskell
evolution = edit (Rationale "Clarify the task." []) $
  within Collections.todos $ update (FactId "todo-001") $
    modify (\todo -> todo { After.title = "Review the sales report" })
```

Import the current schema as both Before and After for a same-schema edit.
Generated collection handles use root field names. They and the endpoint-specific
`Kyyn.Workspace.Evolution` module are generated during inspection/checking;
you do not write bindings or a runtime wrapper.

For nested edits, use `zoom` with a `Lens'` built using `lens`, or
`zoom facts` for a whole-domain State action. `refuse diagnostics` rejects an
edit without returning partial state. Use `editBefore` for an edit before the
schema transition. Compose separate steps with `>=>` when they deserve
separate rationales and diffs.

Record updates such as `todo { After.title = "New title" }` preserve all other
fields; you do not need to reconstruct the record for a same-type edit.

When multiple root versions use unchanged domain types, you can define those
types in a shared module and import it from both roots. For example, both
`RootV3` and `RootV4` can import `Status(..)` from `TaskTypes`; their Todo records
then share exactly the same Status type and migration can copy it directly.
Moving an existing declaration into that module creates a new nominal type once,
so that initial move still requires conversion. Keep the shared module unchanged
while compiling both endpoints; if its types change, give the changed module a
distinct name. This is optional, not a requirement to split small schemas.

### Review and accept

```sh
kyyn-v2 --kb PATH evolution check ID
kyyn-v2 --kb PATH evolution show ID
kyyn-v2 --kb PATH evolution ready ID
kyyn-v2 --kb PATH evolution accept ID
```

`check` evaluates the current workspace, saves the candidate and diff, and
validates that candidate. Run it again after edits. Validation failure leaves the
new result inspectable; an earlier compilation/transformation failure leaves any
previous saved candidate unchanged and says no new candidate was produced.

`accept` checks the saved result afresh without rerunning the evolution.
It requires Ready state, matching proposal inputs and the same local Git head
that the evolution targets. If head advanced, update Before and the transformation,
then check and review again. Acceptance commits the complete new root and archive;
it does not push to a remote.

Use `evolution draft ID` to return unfinished work to Draft. Accepted workspaces
remain as history; normal root reads do not execute them again.

If initialization or acceptance reports a committed result but incomplete checkout,
follow its recovery diagnostic rather than repeating the operation blindly.
`evolution recover ID` repairs an accepted evolution's checkout synchronization.

## Secrets

```sh
kyyn-v2 --kb PATH secret set MODEL_KEY
kyyn-v2 --kb PATH secret list
kyyn-v2 --kb PATH secret show MODEL_KEY
kyyn-v2 --kb PATH secret remove MODEL_KEY
```

`set` uses a hidden prompt or piped stdin; a positional value is also supported
but may appear in shell history/process listings. Empty values are refused.
`list` returns names; `show` masks the value.

Secrets are plaintext in checkout-local ignored storage. Configure each checkout
separately. Secret setup needs `root/kb.dhall`, not a compiled schema.

## Plugins and taps

```sh
kyyn-v2 --kb PATH tap list
kyyn-v2 --kb PATH tap update
kyyn-v2 --kb PATH plugin search
kyyn-v2 --kb PATH plugin guide first-party/local-file
kyyn-v2 --kb PATH evolution new add-plugin
kyyn-v2 --kb PATH plugin install first-party/local-file --evolution ID
```

A tap points at a plugin catalogue. `tap add NAME --from URL` and
`tap remove NAME` edit `taps.dhall` without committing it; commit those
changes with Git. `tap update [NAME]` refreshes the local download.
`tap list` shows its synced revision. Search and guides use that catalogue;
installation captures the package source's current HEAD, which can be newer.

You can also install directly from a committed local checkout or HTTPS/file URL:

```sh
kyyn-v2 --kb PATH plugin install --evolution ID --from /path/to/kyyn-v2 --path plugins/local-file
```

Local source paths are relative to your working directory, not `--kb`.
Kyyn copies committed source, not uncommitted/untracked changes. SSH/scp-style
URLs are unsupported. Repeat installation to replace the complete package while
preserving connector configuration; local package edits in that draft are replaced.

Plugin source is installed into `target/plugins/packages/`, never directly
into the accepted root. Inspect it with `plugin list`, `plugin show NAME`
or `plugin guide NAME`, adding `--evolution ID` for the draft. Discovery
and guides work even if the plugin cannot compile.

Discover a plugin's configuration before creating named connector instances:

```sh
kyyn-v2 --kb PATH plugin connector schema show local-file --evolution ID
kyyn-v2 --kb PATH plugin connector list local-file --evolution ID
```

For local-file, create `target/plugins/config/local-file.dhall`:

```dhall
let Connector = < Folder : { directory : Text, recursive : Bool } >
in [ { name = "documents"
     , binding = "documents"
     , connector = Connector.Folder
         { directory = "/path/to/documents", recursive = True }
     } ]
```

The name selects the instance in commands; the binding names its generated guest
value in `Kyyn.Connectors`. Check, review, ready and accept the evolution.
For Microsoft Graph authentication/configuration use
`plugin guide first-party/microsoft-graph` (or the installed plugin's guide).

## Fetch and inspect evidence

```sh
kyyn-v2 --kb PATH evidence fetch local-file documents
kyyn-v2 --kb PATH evidence list local-file documents
kyyn-v2 --kb PATH evidence history list local-file documents
kyyn-v2 --kb PATH evidence change list local-file documents --since FETCH_ID
kyyn-v2 --kb PATH plugin connector method list local-file documents
kyyn-v2 --kb PATH plugin connector method show local-file documents content
kyyn-v2 --kb PATH plugin connector method execute local-file documents content --input '"notes.txt"'
```

Fetching uses accepted configuration and updates local evidence, not KB facts.
Only latest payloads are retained. History/change commands report payload-free
markers; they cannot retrieve old contents. Plugin methods expose useful typed
reads of captured evidence: local-file's `content` reads the latest captured
text, not the current file on disk. Human method results are Dhall; `--json`
returns structured JSON.

Some connectors accept `evidence fetch PLUGIN INSTANCE --options 'DHALL'`.
Inspect the optional type with `plugin connector show PLUGIN INSTANCE`;
omitting options uses connector defaults. Local-file has no fetch options.
Options appear in history, so use secrets for credentials.

`evidence clear PLUGIN INSTANCE` discards that instance's local cache.
Refetch to rebuild it. Clearing evidence does not remove accepted facts or recipe
acknowledgements.

## Tools and models

Register a helper in the target `kb.dhall` `tools` list, with its name,
description, implementation, inputType and resultType. Write its implementation
under `target/src/`; check and accept the evolution. See the
[composed-reader example](../architecture/adr/0008-authoring.md#composed-kb-investigation-tools).

```sh
kyyn-v2 --kb PATH root tool list --evolution ID
kyyn-v2 --kb PATH root tool show bulkContent --evolution ID
kyyn-v2 --kb PATH root tool execute bulkContent --input '["notes.txt", "summary.txt"]'
```

Execution uses the accepted helper and latest fetched evidence. Discover IDs
with `evidence list` first. Showing a tool exposes its contracts without
executing it; helpers can compose reads across configured connector instances.

### Judgements

Expose an Agentic judgement flow through an ordinary registered helper. For
example, `Helpers.assess` takes `Helpers.Input` and returns `Helpers.Output`:

```haskell
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Helpers where
import qualified Agentic as A
import Agentic.Questions (yesNo, YesNo(..), basisPoints)
import Control.Arrow ((>>>), arr)
import qualified Data.Text as Text
import Kyyn.Agentic (Flow, interpret)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)

type Input = String
type Output = Integer

assessment :: Flow Text.Text Integer
assessment = A.judge (yesNo "Does this require a reply?")
  >>> arr (\answer -> toInteger (basisPoints answer.yes))

assess :: Input -> Tool (Either FetchError Output)
assess = interpret assessment . Text.pack
```

The result is probability basis points (`9500` means 95%), projected into a
supported tool result type. Authors choose any decision threshold. Register,
check and accept the tool, then configure the checkout-local key:

```sh
kyyn-v2 --kb PATH secret set JEV_TOKEN
kyyn-v2 --kb PATH root tool execute assess --input '"Please approve the revised budget"'
```

See [judgement workflows](../architecture/adr/0027-judgement.md).
Use `guest module show Agentic.Questions` for question builders and answers;
`guest module show Kyyn.Agentic` exposes the generated workflow integration.
The same flow can be composed into a closed recipe.

For three-way routing, define the domain decision in its own module:

```haskell
module Decisions where
data Commitment = Committed | NotCommitted | Unclear deriving (Eq, Show)
```

Import its generated contract/options in the flow module. Confidence thresholds
are your policy, expressed directly with `Probability` literals:

```haskell
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Routing where
import qualified Agentic as A
import qualified Agentic.Questions as Q
import Control.Arrow ((>>>), arr)
import qualified Data.Text as Text
import Kyyn.Agentic (Flow)
import Decisions
import Kyyn.Contracts.Decisions.Commitment ()

classify :: Flow Text.Text Commitment
classify = A.judge (Q.choice "Is this a concrete commitment?") >>> arr route

route :: Q.Choice Commitment -> Commitment
route answer
  | answer.confidence >= 0.7 = answer.chosen
  | otherwise = Unclear
```

The result can select your flow's keep/drop/review branches. `Unclear` remains
possible even with high confidence; low confidence routes there regardless of
the chosen answer. Neither Kyyn nor Agentic sets that threshold for you.
Use record-dot access for library records (`answer.chosen`, `answer.confidence`,
`answer.yes`). MicroHs supports this syntax directly; the pragma also makes the
source explicit for GHC. Upgrading older flows requires replacing renamed fields
such as `Q.choiceConfidence answer` with `answer.confidence`. MicroHs still accepts
some unchanged selectors such as `Q.chosen` and `Q.yes`; GHC respects the upstream
`NoFieldSelectors` setting, so prefer record-dot for portable authoring.

`Probability` works inside flows, but is not currently supported as a field in
Kyyn-generated model contracts, tool result contracts or fact schemas. Return a
supported domain decision as above, or explicitly project confidence to Integer
basis points when it must cross those boundaries.

### Drafting with a configured model

Add `model.dhall` to an evolution's `target/` directory, then check and accept it:

```dhall
{ provider = < OpenAI | Anthropic >.Anthropic
, model = "your-provider-model-name"
, credential = "MODEL_KEY"
}
```

Set the corresponding checkout-local credential with
`kyyn-v2 --kb PATH secret set MODEL_KEY`. For OpenAI, select `.OpenAI` instead.
`root tool show NAME` shows the captured provider/model and secret name.

Registered tools can execute upstream Agentic flows through generated
`Kyyn.Agentic`. For example, a text-only tool needs no authored codec:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Helpers where

import qualified Agentic as A
import qualified Data.Text as Text
import Kyyn.Agentic (Flow, interpret)
import Kyyn.Connectors (Tool)
import Kyyn.Plugin (FetchError)

type Input = String
type Output = String

summarise :: Flow Text.Text Text.Text
summarise = A.draft "Summarise the supplied text in one sentence."

summary :: Input -> Tool (Either FetchError Output)
summary input = fmap (fmap Text.unpack) (interpret summarise (Text.pack input))
```

Register `Helpers.summary` with `Helpers.Input` and `Helpers.Output`. Use `A.act` with `liftTool` to compose existing captured-read helpers
into a flow. Failures return through the ordinary tool result; Ctrl-C cancels
the invocation. Model requests use the configuration captured when the tool was
prepared. No model is contacted by listing or showing a tool.

For an authored type, define it in a separate module:

```haskell
-- Todos.hs
module Todos where
data Todo = Todo { name :: String, completed :: Bool }
```

Then import its generated instance in the flow module:

```haskell
import Todos (Todo)
import Kyyn.Contracts.Todos.Todo ()

extractTodo :: Flow Text.Text Todo
extractTodo = A.draft "Extract the actionable task from this evidence."
```

Kyyn generates the `Contract Todo` instance and its codec from the checked type;
the empty import list brings the instance into scope. No deriving clause or
handwritten codec is needed. Keep `Todos` independent of flow/generated-contract
modules. The import convention is `Kyyn.Contracts.<defining module>.<type>`;
inspect it with `guest module show Kyyn.Contracts.Todos.Todo` inside the KB.
Generated modules also export a typed `codec` for explicit-codec uses.

For a nonempty enum, the same import supplies `Options` for Agentic `choice`
and `score`, using constructor names and declaration order:

```haskell
-- In Todos.hs: data Priority = Routine | Important | Urgent
import Todos (Priority)
import Kyyn.Contracts.Todos.Priority ()

priority = A.judge (A.choice @Priority "How urgent is this?")
```

Use `TypeApplications` for the example. Generated options have no descriptions.
For custom labels, descriptions or ordering, write your own instances instead
of importing the generated module. Importing it alongside your own instance
produces the compiler's duplicate-instance error; remove one of the definitions.

Select monomorphic data/newtype declarations. For aliases, import the underlying
type's defining contract; for a standalone list or applied generic contract, use
a named data/newtype wrapper. Existing primitive library contracts still work.
Agentic's SystemOne uses Jev; SystemTwo uses the configured OpenAI or Anthropic provider.

## Recipes and curation

Recipes are first-class data in `KnowledgeBase a`, alongside the authored domain
Root. Add, edit and remove them through ordinary evolution steps:

```haskell
import Kyyn.Workspace.Evolution
import Kyyn.Schema (Fact(..), FactId(..))

evolution = edit (Rationale "Teach the KB how to curate todos" []) $
  within recipes $ append (Fact (FactId "syncTodos")
    (OpenAgent "Inspect item/status evidence and update todos."))
```

Use `update` and `remove` with the same FactId to refine or remove the recipe.
The ID is its name and follows the connector-binding identifier rule; IDs must
be unique. Recipe changes appear distinctly in the evolution review.

`ClosedAgent (FlowEntryRef "Tasks.reconcile")` stores a named authored flow
instead of instructions. Root checking resolves the function and checks
`Flow (RecipeInput Root) (ProposedCuration RootEdit)` without running it. Both
constructors can be inspected and edited.

Import `Kyyn.Evolution.Proposal` and generated `Kyyn.Workspace.FactEdits` to
construct a `ProposedCuration RootEdit`. Each collection has a constructor such
as `Edit_todos`, containing `Append`, `Replace` or `Remove`; group edits in
`ProposedStep`s with rationale. These proposals edit facts, not schema. The
bindings require a root with fact collections; for an evolution context its
Before/After schema and metadata must match. Use `evolve` for schema changes.

`Kyyn.Recipe` provides pure helpers for the captured input:

```haskell
pendingItems :: [PendingEvidence] -> [(EvidenceScope, EvidenceId)]
removedItems :: [PendingEvidence] -> [(EvidenceScope, EvidenceId)]
scopes :: [PendingEvidence] -> [EvidenceScope]
acknowledgeAll :: RecipeInput root -> Curation
acknowledgeItems :: [(EvidenceScope, EvidenceId)] -> [Acknowledgement]
cite :: EvidenceScope -> EvidenceId -> EvidenceRef
```

`pendingItems` includes New/Updated items and reconciliation's current IDs;
`removedItems` includes only explicit removals. Both preserve scope and order.
Use `cite scope ident` in a rationale; it identifies the connector/item without
inventing an external link. `acknowledgeAll input` explicitly declares all supplied
batches handled, including reconciliation: use it only for flows that process
the whole supplied source, after completing that work. For partial processing,
pass only the items actually handled to `acknowledgeItems`:

```haskell
curation = Curation recipe (acknowledgeItems handledItems)
```

It groups `(EvidenceScope, EvidenceId)` pairs into one `IndividualRecords` per
scope, preserving first-seen scope order and item order. It does not deduplicate
IDs or decide what succeeded. Include handled deletions explicitly too.
The host refuses individual acknowledgements for producer reconciliation scopes;
authors explicitly add `EntireBatch scope` after completing that reconciliation.

For effectful actions inside a flow, import `Step` from `Kyyn.Agentic`:

```haskell
type Step = ExceptT FetchError Tool
type Flow input output = Agentic Step input output
```

String literals can be typed directly as `Text`, avoiding `Text.pack` around each
literal. For example, with `Agentic` imported as `A` and `Data.Text` as `Text`:

```haskell
instruction :: Text.Text
instruction = Text.unlines ["Read the note.", "Extract concrete tasks only."]

summarise :: Flow Text.Text Text.Text
summarise = A.draft (A.Instruction instruction)
```

MicroHs supports these literals directly; add `{-# LANGUAGE OverloadedStrings #-}`
for GHC too. Existing `String` values (including `show` results) still need
`Text.pack` when passed to a Text API.

Inspect the flow:

```sh
kyyn-v2 --kb ./my-kb root recipe describe syncTodos
kyyn-v2 --kb ./my-kb root recipe describe syncTodos --dot > flow.dot
kyyn-v2 --kb ./my-kb root recipe describe syncTodos --mermaid > flow.mmd
```

The default is Agentic's readable tree. The format flags are mutually exclusive;
stdout contains only renderer output, or a contextual result envelope with
`--json`. Description compiles the accepted flow but does not run its actions,
validate facts, read evidence or call a model. Named steps and declared branches
are visible; arbitrary pure/effectful functions remain opaque. Open recipes have
instructions instead of a flow: use `root recipe show NAME`.

`guest module show Tasks` can inspect a recipe's authored module, and
`guest module show Kyyn.Workspace.FactEdits` shows its generated edit type.
With `--evolution ID`, recipe bindings describe the target root; the evolution's
Before/After APIs remain a separate compilation context.

Run a closed recipe against one or more fetched connector instances:

```sh
kyyn-v2 --kb ./my-kb root recipe run syncTodos local-file documents local-file prices
kyyn-v2 --kb ./my-kb evolution check 000003-curate-synctodos
```

Use the evolution ID returned by `run`. It creates a Draft with
`change/proposal.dhall`; checking and acceptance use that saved proposal, not
another model invocation. Review it before marking it ready and accepting it.
Its generated `Evolution.hs` imports `frozen` from `KyynFrozenProposal`:

```haskell
evolution :: Evolution (KnowledgeBase RootV3.Root) (KnowledgeBase RootV3.Root)
evolution = frozen
```

The root type is your KB's current type. `frozen` applies the saved proposal's
edits, rationales and curation declaration. Kyyn prepares that value from
`change/proposal.dhall` when checking; the evolution itself does not read files.
Inspect its generated signature with
`kyyn-v2 guest module show KyynFrozenProposal --evolution ID`.

Each selected instance supplies its pending changes and fetch scope. Its evidence
contents are captured once for the invocation, including subsequent plugin reads.
Reads of other instances capture lazily as ordinary tools do, but the proposal
can acknowledge only supplied scopes and their pending IDs. Duplicate instance
pairs are refused. Open recipes remain instructions for an external agent.

The host persists these values in `root/recipes.dhall`; an absent file means no
recipes. Do not place this file in an evolution target: the evolution must return
the recipe data. Queries and validators still receive the domain Root.

The host stores acknowledged evidence in `root/curation.dhall`; a missing file
means no acknowledgements. It is not part of the guest Root schema or copied into
evolution targets. Ordinary evolutions preserve it through acceptance.

An evolution can explicitly declare evidence handled for one recipe:

```haskell
evolution = withCuration
  (Curation (RecipeId "syncTodos")
    [ EntireBatch (EvidenceScope "local-file" "documents" "FETCH_ID")
    , IndividualRecords (EvidenceScope "local-file" "other" "OTHER_FETCH_ID")
        [EvidenceId "todo.txt"]
    ]) identityEvolution
```

These names are exported by `Kyyn.Workspace.Evolution`. Replace `identityEvolution`
with your fact/schema transformation, or keep it when no fact change is needed.
Pending human output includes a ready-to-paste `Scope: EvidenceScope ...` line;
copy the expression after `Scope:` into the acknowledgement.
Use the exact fetch ID you considered (`evidence history list PLUGIN INSTANCE`
shows retained fetches). An individual ID absent at that fetch acknowledges its
deletion. The recipe must exist in the returned KB; adding it and acknowledging
evidence for it in the same evolution is supported.

`evolution check` resolves these declarations and saves the resulting progress;
`evolution show` displays them. Acceptance publishes that saved progress even if
evidence has since refreshed or been cleared. An unavailable fetch scope must be
updated and checked again.

Discover the accepted recipes and their net pending evidence:

```sh
kyyn-v2 --kb PATH root recipe list
kyyn-v2 --kb PATH root recipe show syncTodos
kyyn-v2 --kb PATH --json root recipe pending list syncTodos local-file documents
```

List/show needs no runtime bundle. Pending discovery returns a fixed `scope`
(`plugin`, `instance`, `fetch`), `kind: "Changes"` and `changes` (`id`, `kind`), comparing latest
evidence against this recipe's accepted acknowledgements. It neither fetches nor
marks anything handled. For example, New then Updated before curation is still
one pending New; New then Removed disappears from pending work. Two recipes can
consider the same evidence independently. An incompatible cached producer requires refetching.
After refetch, a producer change relative to accepted progress returns
`kind: "Reconciliation"` and `currentIds` instead of `changes`. These are all
currently present IDs, not a diff against the previous producer. The same input
arrives in closed flows as `Reconciliation scope currentIds`. Compare current
evidence with the root, then return `EntireBatch scope` or omit acknowledgement
to leave reconciliation pending. `IndividualRecords` is refused for that scope.
An empty reconciliation set still needs consideration; it is not an empty delta.
An empty ordinary changes list means no unacknowledged
changes, not that the recipe's task is complete. Use plugin methods or KB tools to
read the actual evidence.

## Explore schemas, collections and facts

```sh
kyyn-v2 --kb PATH root schema list
kyyn-v2 --kb PATH root schema show Tasks.Todo
kyyn-v2 --kb PATH root collection list
kyyn-v2 --kb PATH root collection show tasks
kyyn-v2 --kb PATH root fact list tasks
kyyn-v2 --kb PATH root fact show tasks todo-001
```

Schema commands list reachable named types and show their Dhall shape and field
roles. Collection commands show logical names, root fields, payload types and
references. Add `--evolution ID` to either group to inspect target source without
running the evolution or its validator; fact material is not needed.

Fact commands validate the accepted root and read its records. Lists show exact
IDs with Title-role text where available; `show` prints the selected payload as
Dhall. `--json` exposes structured values and selection context. Facts do not take
`--evolution`: use `evolution show ID` to review a saved candidate's changes.

## Discover APIs while authoring

```sh
kyyn-v2 guest module list
kyyn-v2 guest module show Kyyn.Edit
kyyn-v2 guest symbol show Kyyn.Edit.update
kyyn-v2 --kb PATH guest module show Helpers
kyyn-v2 --kb PATH guest module show Kyyn.Workspace.Evolution --evolution ID
kyyn-v2 --kb PATH guest symbol show Kyyn.Workspace.After.todos --evolution ID
```

Outside a KB, discovery reads the installed SDK catalogue. Inside one it adds
generated bindings and authored modules, labelled `sdk`, `generated` or
`kb`. Accepted discovery reads Git, not uncommitted edits. Draft discovery
uses target source; the schema must compile, but the evolution body may be unfinished.

Showing a module checks it and its dependencies, then lists exported types,
constructors, functions and documentation. Private definitions are omitted.
Reexports retain their defining names. A symbol name can identify both a type
and its constructor. `-- [compiler signature]` marks an expanded type/kind
rather than the author's spelling.

Explicit instance headers are a separate section (`instances` in JSON).
For example, inspect `Kyyn.Contracts.Todos.Priority` to see its generated
`Contract` and `Options` instances. Imported/derived instances and method
bodies are omitted; absence is not proof that no instance is available.

Put `-- |` immediately above a signature/type declaration for discoverable
documentation, continuing with adjacent `--` lines. A blank physical line
ends the block. Reexports retain this documentation.

Useful starting modules are `Kyyn.Schema`, `Kyyn.Validation`,
`Kyyn.Query`, `Kyyn.Evolution`, `Kyyn.Connectors` and
`Kyyn.Agentic`. Generated `Kyyn.Workspace.FactEdits` exposes data-described
collection edits for closed recipes; inspect the recipe's module in the same
context. Evolution Before/After bindings are a separate context.

## Script settled work

CLI commands return nonzero on refusal/failure. Use `--json` for structured
results and `&&` or your runner's failure handling to stop on errors.
An external agent can populate and check a draft, then mark it Ready; a later
scripted acceptance step fails if it remains Draft. Closed recipes save their
proposals as drafts for the same check/review/accept path.

No Web server, MCP server or built-in scheduler is needed for these CLI workflows.
