# Trying the first CLI

The executable is named `kyyn-v2` while the original version owns `kyyn`.
The current CLI supports plugin source installation, guest SDK discovery, root inspection/checking and the evolution commands in
[ADR 0018](../architecture/adr/0018-surfaces.md#cli-navigation-and-kb-selection).
The installed integration fixture covers schema-changing acceptance and inherited
examples; this is not a released installation.

To install locally from this development repository:

```sh
bash tools/install-cli.sh
```

This builds and installs the complete bundle under `~/.local/lib/kyyn-v2`, with
`~/.local/bin/kyyn-v2` pointing to its executable. If needed, add `~/.local/bin`
to PATH. The existing `kyyn` command is untouched. Run the same script after
pulling changes to update the installation; it replaces only its dedicated bundle
and link, not KBs. A custom prefix is supported: `bash tools/install-cli.sh /path/to/prefix`.
Both the bundle and link must be writable. If replacement fails after moving the
old bundle, the installer prints where it retained that bundle for recovery.
To uninstall, remove `~/.local/bin/kyyn-v2` and `~/.local/lib/kyyn-v2` (or those
paths under your chosen prefix). KBs stored elsewhere are untouched.

Plain `cabal install exe:kyyn-v2` installs only the host executable, not the
MicroHs/runtime/SDK bundle it needs. Use the script for a usable local installation.

Guest compilation is cached per KB under `.kyyn/compiled`. If a local compiled
artifact is damaged, delete that directory and rerun the command; accepted facts
and source are unaffected. Native schema/API inspection still runs normally.

To inspect command costs, set `KYYN_TIMINGS=1`, for example
`KYYN_TIMINGS=1 kyyn-v2 evolution check 000001-update`. Timing lines go only to
stderr; normal output and `--json` results are unchanged. They identify native
type/API inspection, compiler cache hits/misses, guest execution (including plugin
registration), and command wall time. Durations are inclusive: a guest that calls
another guest includes that nested execution, so do not blindly sum every line.
No timing lines are emitted unless the variable is exactly `1`.
It reuses the staging helper and existing Cabal/Make build, without custom Cabal hooks.

```sh
kyyn-v2 --kb /path/to/kb root show
kyyn-v2 --kb /path/to/kb evolution new my-change
```

Alternatively, assemble a new staging directory without installing:

```sh
bash tools/stage-cli.sh /tmp/kyyn-development
```

The destination must not already exist. The script builds the host executable
and bundles MicroHs, its evaluator/preprocessor, libraries and Kyyn SDK beneath
`lib/kyyn/`. It is a developer staging helper, not a portable release installer
or a completed distribution/license audit. Building needs the development tools
in [project practices](PROJECT-PRACTICES.md); executing this staged CLI does not
invoke GHC, Cabal, Node or a C compiler. For KB commands, Git must be available or selected with
`--git /absolute/path/to/git`.

The staged compiler uses MicroHs's upstream native build (`bin/gmhs`), exposed
under the toolchain's existing `bin/mhs` name. GHC remains a build dependency;
the installed compiler does not invoke it. ADR 0002 owns this build choice.

Create your own empty KB (the directory does not need to exist):

```sh
kyyn-v2 --kb /tmp/my-kb kb init
kyyn-v2 --kb /tmp/my-kb root check
kyyn-v2 --kb /tmp/my-kb evolution new my-change
```

Git needs your normal identity configured. For a new repository this normally
means global `user.name` and `user.email`; for an existing repository its local
configuration applies too. Git chooses the initial branch using `init.defaultBranch`.
Initialization works inside an existing repository and preserves unrelated files
and staged changes. It refuses an existing root or evolution directory.

The new root has no fields or collections: `root/src/RootV1.hs` defines its empty
schema, `root/src/Validate.hs` its validator, and `root/facts/root.dhall` its value.
Your first evolution can introduce the schema and facts you need. It has no
queries or saved examples yet. The returned evolution ID identifies a draft
workspace, for example `000001-add-review-status`. Use that full ID in commands;
the six-digit prefix orders local creation, not acceptance. Edit its
`change/Evolution.hs` and, when changing schema or validation,
its `target/` files. `before/` records the selected source. Use the returned ID
in place of `ID` below:

`.kyyn/` holds private candidate cache files and ignores itself in Git; no
top-level `.gitignore` rule is needed. Accepted workspaces remain in `evolutions/`.

If initialization reports a committed root but incomplete checkout,
follow its scoped Git restore command rather than initializing again. A failure
after setup starts may leave an empty directory or Git repository behind; inspect
it before removing it. Ordinary identity/validation refusals do not create it.

```sh
/tmp/kyyn-development/bin/kyyn-v2 --kb /tmp/my-kb evolution check ID
/tmp/kyyn-development/bin/kyyn-v2 --kb /tmp/my-kb evolution show ID
/tmp/kyyn-development/bin/kyyn-v2 --kb /tmp/my-kb evolution ready ID

git -C /tmp/my-kb config user.name 'Your Name'
git -C /tmp/my-kb config user.email 'you@example.com'
/tmp/kyyn-development/bin/kyyn-v2 --kb /tmp/my-kb evolution accept ID
```

The generated scaffold is an identity evolution until edited. `check` evaluates
the current workspace, saves its candidate and diff, then validates that candidate.
Run it again after editing either the evolution or its target schema/validator.
Validation failure leaves the new candidate available through `show`; compilation
or transformation refusal before candidate creation leaves any older candidate
unchanged and explicitly reports that no new one was produced.
Acceptance uses the repository's configured Git identity; existing
global configuration also works, so those `git config` commands are unnecessary
when your identity is already configured. `accept` freshly checks the saved
result rather than executing the evolution again.

An authored entry is the evolution itself, with a rationale for each step:

```haskell
module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Schema (FactId(..))
import qualified RootV1 as Before
import qualified RootV2 as After
import qualified Kyyn.Workspace.Before as BeforeCollections
import qualified Kyyn.Workspace.After as AfterCollections

evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution =
  evolve (Rationale "Add review status" []) (onFacts addReviewStatus)
  >=> edit (Rationale "Complete the report" [])
    (within AfterCollections.todos $ update (FactId "todo-001") $
      modify (\todo -> todo { After.status = After.Done }))
  >=> edit (Rationale "Remove the cancelled task" [])
    (within AfterCollections.todos $ remove (FactId "todo-002"))
```

`addReviewStatus` is an authored `Before.Root -> Either EvolutionFailure After.Root`
function; `onFacts` preserves recipes while transforming domain data. `edit` takes
a State action over the KB: use `zoom facts` for whole-domain `get`, `put` or `modify`, or
`within` a generated collection handle to `current`, `update`, `remove` or `append`
facts by ID. `update` focuses on a payload without changing its FactId. Missing or
duplicate IDs report a located error. For nested updates, define a `Lens'` with
`lens getter (\record value -> record { field = value })`, then use
`zoom details (modifying priority (+ 1))`; lenses compose with `(.)`.
`refuse diagnostics` rejects an edit without producing partial state.

Collection bindings use the schema's root field names, independently of their
logical collection names. They are in `Kyyn.Workspace.Before` and
`Kyyn.Workspace.After`, not on disk in the authored sources. Schema selectors
remain under the ordinary Before/After schema imports. `Kyyn.Workspace.Evolution`
is generated when checking: it supplies the endpoint-specific step constructors,
composition, rationale/evidence, fact and diagnostic types. No generated bindings
or execution wrapper need to be supplied. Each step produces its own diff.
Same-schema changes can use only edits. For a schema change, give the new module
a distinct name, update `target/kb.dhall` and the After import, and implement
the transition with `evolve`. Temporary helper types need no declaration.
Use `editBefore` for a State edit before that transition. Each edit has one
rationale/diff even if it touches several facts; compose separate edits to give
them separate explanations.

Inspect the candidate and its rationale with `show` before
acceptance. Use `evolution draft ID` to return unfinished work to Draft.

All these commands also accept shared `--json` before the noun path for structured
output. `--kb` defaults to the current directory. The development overrides
`--runtime DIRECTORY` and `--git EXECUTABLE` are normally unnecessary when using
the staged layout. Use `--help`, `evolution --help` or a command's `--help` for
its actual arguments.

After acceptance, `show` reads the report from Git. An already-accepted retry or
incomplete checkout reports a nonzero outcome with the accepted revision. Inspect
the diagnostics and use `evolution recover ID` when checkout synchronization is
needed; do not create another evolution merely to retry publication.

For a schema-changing authoring example, see the integration fixture's
[migration](../host/kyyn/test/journey/Migrate.hs),
[target schema](../host/kyyn/test/journey/TodoSchemaV2.hs) and
[queries](../host/kyyn/test/journey/Queries.hs). The
[journey test](../host/kyyn/test/Journey.hs) shows the CLI sequence and prepares
saved examples using the host's existing encoder. Run it with
`bash tools/test-installed.sh`; this is a slower integration check, not necessary
for each edit to your own evolution.

## Local secrets

```sh
kyyn-v2 --kb /path/to/kb secret set JEV_TOKEN "$JEV_TOKEN"
kyyn-v2 --kb /path/to/kb secret set JEV_TOKEN  # hidden prompt, or stdin when piped
kyyn-v2 --kb /path/to/kb secret list
kyyn-v2 --kb /path/to/kb secret show JEV_TOKEN
kyyn-v2 --kb /path/to/kb secret remove JEV_TOKEN
```

`show` displays a masked value with its original character count; `list` displays
names only. These commands also support `--json`. An empty value is refused without
changing an existing secret. Argument values can appear in shell history or process
listings; use stdin or the hidden prompt when that matters.

Secrets are plaintext in the selected checkout's ignored `.kyyn/secrets` directory.
They are not copied by Git; configure each checkout separately. Setup does not need
a compiled schema or a guest runtime; the selected directory must contain
`root/kb.dhall`.

## Install plugin source

Discover available packages and read their guides before installing:

```sh
kyyn-v2 --kb /path/to/kb tap list
kyyn-v2 --kb /path/to/kb tap update
kyyn-v2 --kb /path/to/kb plugin search
kyyn-v2 --kb /path/to/kb plugin guide first-party/microsoft-graph
kyyn-v2 --kb /path/to/kb plugin install first-party/microsoft-graph --evolution ID
```

New KBs include the first-party tap declaration. For an existing KB, add it with
`tap add first-party --from https://github.com/drshade/kyyn-v2`. Search uses the
downloaded catalogue; use `tap update [NAME]` to refresh it. `tap add/remove` edits
`taps.dhall` without committing it. `plugin list`, `plugin show NAME` and
`plugin guide NAME` inspect installed packages; add `--evolution ID` for a draft.
Guides and discovery work even when the KB or plugin code cannot compile.

`tap list` shows the synced catalogue revision, or `not synced`. Installation uses
that catalogue to locate the package, then captures the package source's current
HEAD; its installed revision can therefore be newer than the catalogue revision.
`evolution check` and `evolution show` include plugin additions, removals, origin
changes and changed package paths, including edits with an unchanged origin.

Create an evolution, then copy a committed plugin package into its target:

```sh
kyyn-v2 --kb /path/to/kb evolution new add-plugin
kyyn-v2 --kb /path/to/kb plugin install --evolution 000001-add-plugin --from ./plugins/local-file
kyyn-v2 --kb /path/to/kb --json plugin install --evolution 000001-add-plugin --from /path/to/another/repo --path plugins/example
```

`--from` accepts a local directory inside a Git checkout or a `file://` / unauthenticated
`https://` Git repository URL. `--path` selects a package below that directory or
repository. Local paths are relative to your current working directory, not `--kb`.
Commit source changes before installing: Kyyn copies the selected HEAD tree, not
uncommitted or untracked source. Ignored untracked files and the package exclusions
do not block installation. SSH/scp-style addresses are not supported; use HTTPS or
a local checkout. Prefix a local relative path containing a colon with `./`.

The package has `kyyn-plugin.dhall` with `name` and `entryModule`, and the entry's
source under `src/`. Installed files go into `evolutions/ID/target/plugins/packages/NAME/source/`;
the adjacent `origin.dhall` records the repository, package path and exact Git revision.
The command reports those details in both human and JSON output. Repeat installation
to update: it replaces the named package completely, removing obsolete files while
preserving connector configuration. For catalogue installs, use `tap update` then
`plugin install TAP/PLUGIN --evolution ID`.

Installation needs Git but no guest runtime. It validates package structure, not
guest compilation or connector behavior.
Use the ID returned by `evolution new`; `--evolution` is required. Missing or accepted
evolutions are refused. Installation leaves HEAD and accepted `root/` unchanged.
Review the target changes, check the evolution, mark it ready and accept it normally.
New evolutions inherit accepted plugins. Reinstallation replaces any local edits
inside that evolution's named package; review them with Git before updating.

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

## Discover guest and KB APIs

Outside a KB these commands show the installed SDK without needing a source
checkout. Inside a KB they also show its generated bindings and authored modules:

```sh
kyyn-v2 guest module list
kyyn-v2 guest module show Kyyn.Edit
kyyn-v2 guest symbol show Kyyn.Edit.update
kyyn-v2 guest symbol show 'Kyyn.Evolution.>=>'
kyyn-v2 --json guest symbol show Kyyn.Schema.Fact
kyyn-v2 --kb PATH guest module show Helpers
kyyn-v2 --kb PATH guest symbol show Helpers.greet
```

Module output lists exported types, constructors and functions. Symbol output
includes its defining name, so shared reexports can be recognized. Look symbols
up through the listed public modules; their definitions may live in implementation
modules outside the catalogue. A name such as `Fact`
may identify both a type and its constructor; discovery returns both.
Authored signatures preserve aliases such as `Edit` and `Lens'`. Data/newtype
declarations show public constructors and record fields. Abstract types show only
their header; selective reexports show only their exported constructors. If a
constructor's record labels are not all exported, its arguments appear positionally
and any public selectors remain separate entries. These are API summaries, not
an instance inventory or a source-file dump. Constructor and record-accessor
signatures are derived from these declarations, retaining aliases such as `String`.
GADT signatures specialize root-parameter equalities; parameter names follow the
source where unambiguous. Constructors with refined result types use `where`
syntax; existential-only constructors may use equivalent `forall` syntax.

Entries marked `-- [compiler signature]` use the compiler's expanded type or kind instead;
all entries are compiler-checked. JSON distinguishes
these with a null `declaration` and always includes `checkedSignature`.
Re-exported transformer operations such as `modify` use their authored signatures;
CPP-enabled modules are preprocessed with the compiler's macro configuration first.
Functions and constructors always use `name :: signature`, without a `value`
prefix; kind-only fallbacks use `type Name :: kind`. Human origins omit generated
accessor machinery, while JSON's `definedAs` retains the exact compiler identity.

Documentation appears as comments above the declaration and in JSON's `documentation` field.
Write `-- |` immediately above a signature or type declaration, with further
adjacent `--` lines for continuation. A physical blank line ends the association;
use a bare `--` line for a paragraph break within the documentation. Reexports
retain the defining declaration's documentation. Other Haddock forms and ordinary
implementation comments are not collected.

Use `guest module list` for the installed author-facing modules. Shared `Kyyn.Types.*`
modules and runtime operations are implementation APIs, not catalogue entries.
Reexports retain their real defining identities.

Origins are labelled `sdk`, `generated` or `kb` (JSON `origins` for a list and
`origin` for a module/symbol). KB module names follow their paths under `root/src`,
for example `Helpers/Email.hs` defines `Helpers.Email`. Listing does not type-check
every helper body; showing a module or symbol checks that module and its dependencies.
Only exports are shown. Accepted-root discovery reads the selected Git revision,
not uncommitted working-tree edits; use a draft to explore edits before acceptance.

Add `--evolution ID` to explore generated bindings and authored target modules for a draft:

```sh
kyyn-v2 --kb PATH guest module list --evolution 000001-add-todos
kyyn-v2 --kb PATH guest module show Kyyn.Workspace.Evolution --evolution 000001-add-todos
kyyn-v2 --kb PATH guest symbol show Kyyn.Workspace.After.todos --evolution 000001-add-todos
```

This adds `Kyyn.Workspace.Evolution`, `Kyyn.Workspace.Before` and
`Kyyn.Workspace.After` to the SDK catalogue. Results identify the workspace and
its declared Before revision (`result.context` in JSON). The schema and metadata
must compile, but the evolution body can be missing or unfinished. Fix invalid
target schemas and repeat the command; run from outside a KB to inspect the SDK alone.
Human module output places workspace-defined operations before reexports.
`--runtime DIRECTORY` selects the runtime for either form of discovery.

If an older installation lacks the catalogue, reinstall with `bash tools/install-cli.sh`.

For data-described fact edits, import `Kyyn.Evolution.Proposal` and the generated
`Kyyn.Workspace.FactEdits`. The latter provides `RootEdit` and `proposalEvolution`:
each root collection field gets a constructor such as `Edit_todos`, containing
a typed `FactEdit` (`Append`, `Replace` or `Remove`). Group operations into
`ProposedStep`s with a rationale, then pass a `ProposedCuration` to
`proposalEvolution` to obtain an ordinary pure evolution.

`Kyyn.Workspace.FactEdits` is generated only when Before and After have the same
checked schema **and metadata**, and contain at least one domain fact collection.
If the module is unavailable because the schema or metadata changes, use the
ordinary `evolve`/`edit` combinators instead. A root without fact collections has
no fact-edit proposal bindings.

Prepared fact proposals keep their operations, rationale and curation declaration
in `change/proposal.dhall`. Checking decodes that captured file and supplies
`KyynFrozenProposal.proposal` to the ordinary evolution entry; no model is called.
Editing the file requires checking again before acceptance. The proposal-authoring
operation is also used by `root recipe run` to save closed-recipe results.

For tool authoring, inspect these modules on an accepted root or add
`--evolution ID` to inspect its target:

```sh
kyyn-v2 --kb PATH guest module show Kyyn.Connectors
kyyn-v2 --kb PATH guest module show Agentic.Questions
kyyn-v2 --kb PATH guest module show Kyyn.Plugins.P_local_file.Folder
```

`Kyyn.Connectors` documents `Tool` and the expected entry signature;
`Agentic.Questions` exposes the library's question builders and answer types.

## KB investigation helpers

Register helpers in the root's `kb.dhall` `tools` list. The
[authoring example](../architecture/adr/0008-authoring.md#composed-kb-investigation-tools)
shows a bulk local-file reader using generated instance bindings. Edit the helper
and registration in an evolution target, then check and accept it as usual.

```sh
kyyn-v2 --kb PATH root tool list --evolution ID
kyyn-v2 --kb PATH root tool show bulkContent --evolution ID
kyyn-v2 --kb PATH root tool execute bulkContent --input '["notes.txt", "summary.txt"]'
```

### Per-fetch options

`plugin connector show PLUGIN INSTANCE` displays the instance's optional Dhall
fetch-options type. Add `--evolution ID` to inspect a draft target. Supply a value
with `evidence fetch PLUGIN INSTANCE --options 'DHALL'`; the host checks its type
before acquisition. Omit the option to use the connector's own default. A connector
without an options type refuses supplied options; local-file has no options.
`evidence history list PLUGIN INSTANCE` includes supplied options as normalized
Dhall, or an absent value when omitted. These are visible non-secret arguments;
credentials belong in the local secret store.

An options-aware fetch accepts `Maybe Options` between config and snapshot. Kyyn
derives this contract from the checked function signature; registration names the
function, without repeating its input or result types.

Execution uses the accepted helper and latest fetched evidence. Fetch the named
instances first with `evidence fetch PLUGIN INSTANCE`. Use
`kyyn-v2 --kb PATH evidence list PLUGIN INSTANCE` to discover current IDs and
fingerprints before passing IDs to a helper; add `--json` for structured listing output.
Evidence JSON identifies the configured connector with `instance` in selection
contexts, clear results and citations.
Helper results are Dhall by default;
add `--json` for structured JSON. Discovery does not execute the helper.

Existing KB manifests without tools need this field in `kb.dhall`:

```dhall
, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }
```

New KBs already include it. An older captured evolution may need the same manifest
update before it can be checked with this development build.

### Model-assisted questions

Expose an Agentic judgement flow through an ordinary registered helper. For
example, `Helpers.assess` takes `Helpers.Input` and returns `Helpers.Output`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
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
  >>> arr (\(YesNo p) -> toInteger (basisPoints p))

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

## Model-assisted tools

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

Register `Helpers.summary` as a tool with `Helpers.Input` and `Helpers.Output`,
as above. Use `A.act` with `liftTool` to compose existing captured-read helpers
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

## Recipe declarations and curation progress

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
constructors can be inspected and edited. Authored uses of the earlier `Recipe "..."` constructor must
be changed to `OpenAgent "..."`; existing stored instruction-only recipes still
read correctly. Recipe JSON now carries `recipe: { kind, instructions }` or
`recipe: { kind, flow }`.

Run a closed recipe against one or more fetched connector instances:

```sh
kyyn-v2 --kb ./my-kb root recipe run syncTodos local-file documents local-file prices
kyyn-v2 --kb ./my-kb evolution check 000003-curate-synctodos
```

Use the evolution ID returned by `run`. It creates a Draft with
`change/proposal.dhall`; checking and acceptance use that saved proposal, not
another model invocation. Review it before marking it ready and accepting it.
Each selected instance supplies its pending changes and fetch scope. Its evidence
contents are captured once for the invocation, including subsequent plugin reads.
Reads of other instances capture lazily as ordinary tools do, but the proposal
can acknowledge only supplied scopes and their pending IDs. Duplicate instance
pairs are refused. Open recipes remain instructions for an external agent.

The host persists these values in `root/recipes.dhall`; an absent file means no
recipes. Do not place this file in an evolution target: the evolution must return
the recipe data. Queries and validators still receive the domain Root.

For an older development KB, remove the `recipes` field from `root/kb.dhall` and
move its entries to `root/recipes.dhall`, converting each
`{ name = "syncTodos", instructions = "..." }` to
`{ id = "syncTodos", value = { instructions = "..." } }` in a list. Commit that
repair before creating a new evolution. Existing draft entries need the wrapped
`Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)` signature;
wrap domain migration functions with `onFacts`. Generated collection handles
already focus through `facts`, so ordinary `within AfterCollections.todos` edits
need no change.

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
marks anything handled. An incompatible cached producer requires refetching.
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
