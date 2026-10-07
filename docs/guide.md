# Kyyn user guide

Kyyn stores a knowledge base's facts and executable meaning together. Work in an
evolution, check its proposed result, review it, and accept it into Git. The
development executable is `kyyn-v2`; it does not replace kyyn-v1's `kyyn`.

- [Install](#install) and [create a KB](#select-or-create-a-kb)
- [Evolve, check and accept](#create-check-and-accept-an-evolution)
- [Secrets](#secrets), [plugins and taps](#plugins-and-taps), [evidence](#fetch-and-inspect-evidence)
- [Tools and models](#tools-and-models), [recipes and recipe state](#recipes-and-recipe-state)
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
kyyn-v2 --kb PATH evidence show local-file documents notes.txt
kyyn-v2 --kb PATH plugin connector method list local-file documents
kyyn-v2 --kb PATH plugin connector method show local-file documents content
kyyn-v2 --kb PATH plugin connector method execute local-file documents content --input '"notes.txt"'
```

Fetching uses accepted configuration and updates local evidence, not KB facts.
Only current evidence and one latest-fetch summary are retained. Evidence list
and show include its ID, time, added/updated/removed counts and supplied options.
Plugin methods expose useful typed
reads of captured evidence: local-file's `content` reads the latest captured
text, not the current file on disk. Human method results are Dhall; `--json`
returns structured JSON.

`evidence show` displays the current typed payload as Dhall, its fingerprint and
source references. A missing item is different from an unfetched connector;
neither retrieves historical contents.

Some connectors accept `evidence fetch PLUGIN INSTANCE --options 'DHALL'`.
Inspect the optional type with `plugin connector show PLUGIN INSTANCE`;
omitting options uses connector defaults. Local-file has no fetch options.
Options appear in the latest-fetch summary, so use secrets for credentials.

`evidence fetch PLUGIN INSTANCE --restart-sync` keeps existing evidence but starts a
fresh provider sync; stateless connectors report that the flag has no effect.
`evidence clear PLUGIN INSTANCE` deletes the local evidence and position, so the next
fetch starts empty and reports everything as new.
Refetch to rebuild it. Clearing evidence does not remove accepted facts or recipe
state.

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

Each generated connector proxy has an `Evidence` module for generic current reads,
even when the plugin provides no enumeration method. For a local-file instance
whose binding is `documents`:

```haskell
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_local_file.Folder.Evidence as Evidence

-- Within a Tool action:
-- Evidence.listEvidenceIds Connectors.documents
-- Evidence.readEvidence Connectors.documents evidenceId
```

The first returns `Either FetchError [EvidenceId]`; the second returns
`Either FetchError (Maybe (Evidence Payload))`, with the connector's actual payload
type in place of `Payload`. Use `guest module show` on that generated module to
see the exact signatures. Closed flows can use these actions through
`Kyyn.Agentic.liftTool`, just like plugin methods. All reads of an instance within
one invocation share its captured snapshot.

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

`Probability` is supported in generated model contracts, tool results and fact
schemas. Authors use the upstream type and literals such as `0.85`; generated
code handles its representation. Dhall stores exact basis points (`8500` means
85%, with a range of `0..10000`), while model responses use upstream's numeric
probability contract (`0.85`). Invalid stored basis points are rejected, not
clamped. General floating-point fields are not supported.

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

## Recipes and recipe state

Recipes are root-owned definitions with independently typed state. Create, update
or remove them through an ad hoc evolution. State is mandatory; use `()` when
the recipe has nothing to remember.

For an open recipe, declare its state type in a target source module:

```haskell
module Review where
data State = State { seen :: [String] }
```

Import its generated type handle in the evolution:

```haskell
import Kyyn.Workspace.Evolution
import qualified Kyyn.Workspace.After.RecipeTypes.Review.State as ReviewType
import qualified Review

-- Inside an edit:
createRecipe (RecipeId "reviewMail")
  (openRecipe ReviewType.recipeType "Review relevant mail and update the tasks")
  (Review.State [])
```

`updateRecipe` takes the old type handle, the new definition and a fallible
state transformation. `removeRecipe` takes the recipe ID. Instruction-only
updates can preserve state with `Right`. Recipe state appears in evolution
reviews and is stored as typed Dhall in `root/recipes/<id>/state.dhall`;
definitions are in `root/recipes.dhall`. Neither file belongs in an evolution's
target: they are evaluated data.

### Author a recipe-based evolution

```sh
kyyn-v2 --kb PATH evolution new review-mail --recipe reviewMail
```

The generated facade binds the domain root and the selected recipe's state:

```haskell
import Kyyn.Workspace.Evolution
import qualified Kyyn.Workspace.Before as BeforeCollections
import qualified Review

evolution :: RecipeEvolution Root RecipeState
evolution = recipeEdit (Rationale "Reviewed the message" []) $ do
  -- Domain collection edits go inside editFacts:
  -- editFacts (within BeforeCollections.todos ...)
  modifyRecipeState $ \(Review.State seen) ->
    Review.State (seen ++ ["message-123"])
```

A recipe-based evolution changes facts and only its selected recipe's state.
Use an ad hoc evolution to change schema, code, configuration or recipe definitions.
Checking and acceptance use the ordinary evolution commands.

### Closed recipes

A closed recipe is an authored flow with explicit request and state types:

```haskell
import Kyyn.Agentic (Flow)
import Kyyn.Recipe
import Kyyn.Workspace.FactEdits (RootEdit)

review :: Flow (RecipeInput Root Request ReviewState)
               (RecipeProposal RootEdit ReviewState)
```

The input carries the accepted domain root, invocation arguments and current
recipe state. The result carries ordered `ProposedStep` values and the complete
next state. Flows read current evidence through generated connector bindings
and plugin methods, just like KB tools; Kyyn does not supply a pending-work queue
or require declarations that evidence was handled. If a recipe needs cursors,
dismissals or other progress tracking, model that in its state.

Each `RootEdit` constructor identifies a collection, for example
`Edit_todos (Append (Fact ...))`, `Edit_todos (Replace factId payload)` or
`Edit_todos (Remove factId)`. Group edits under `ProposedStep rationale edits`.
An empty steps list with updated state is valid, including for roots with no
fact collections.

To create a closed recipe in an evolution, import its generated definition handle.
For a flow named `Flows.review`:

```haskell
import qualified Kyyn.Workspace.After.RecipeFlows.Flows as Flows

-- Inside an edit:
createRecipe (RecipeId "reviewMail") Flows.review (Review.State [])
```

The compiler derives the state type from the actual flow signature. These handles
are definitions, not flow executions. Explore imported generated handles with
`guest module show MODULE --evolution ID`.

```sh
kyyn-v2 --kb PATH root recipe list
kyyn-v2 --kb PATH root recipe show reviewMail
kyyn-v2 --kb PATH root recipe describe reviewMail
kyyn-v2 --kb PATH root recipe describe reviewMail --dot
kyyn-v2 --kb PATH root recipe describe reviewMail --mermaid
kyyn-v2 --kb PATH root recipe run reviewMail --input '"October"'
```

`--input` is Dhall checked against the flow's request type; it may be omitted
only for `()`. Description renders the authored flow's structure without running
its actions.

A successful run creates a recipe-based draft with `change/proposal.dhall` and:

```haskell
evolution :: RecipeEvolution Root RecipeState
evolution = frozen
```

`frozen` is supplied by `KyynFrozenProposal`. It applies the saved fact steps
and next state through the normal evolution machinery. Check, inspect, mark ready
and accept the draft as usual; those operations do not invoke the flow again.
Malformed proposal data is rejected before guest compilation. Subsequent reads
of external evidence do not alter a saved proposal.

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
