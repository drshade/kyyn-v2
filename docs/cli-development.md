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

## Install plugin source

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
The command reports those details in both human and JSON output. It refuses an
existing destination rather than updating or merging into it.

Installation needs Git but no guest runtime. It validates package structure, not
guest compilation or connector behavior. The current `local-file` package demonstrates
installation only; its source/sink operations are not implemented yet.
Use the ID returned by `evolution new`; `--evolution` is required. Missing or accepted
evolutions are refused. Installation leaves HEAD and accepted `root/` unchanged.
Review the target changes, check the evolution, mark it ready and accept it normally.
New evolutions inherit accepted plugins. If a filesystem write fails after destination
creation, inspect the reported directory before removing the partial copy and retrying.

## Discover the guest SDK

These commands work anywhere; no KB or source checkout is needed:

```sh
kyyn-v2 guest module list
kyyn-v2 guest module show Kyyn.Edit
kyyn-v2 guest symbol show Kyyn.Edit.update
kyyn-v2 guest symbol show 'Kyyn.Evolution.>=>'
kyyn-v2 --json guest symbol show Kyyn.Schema.Fact
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

The catalogue covers seven author-facing modules: `Kyyn.Schema`, `Kyyn.Validation`,
`Kyyn.Query`, `Kyyn.Evolution`, `Kyyn.Edit`, `Kyyn.Optics` and `Kyyn.Plugin`. Shared `Kyyn.Types.*`
modules and runtime operations are implementation APIs, not catalogue entries.
Reexports retain their real defining identities.

Add `--evolution ID` to explore generated bindings for a draft:

```sh
kyyn-v2 --kb PATH guest module list --evolution 000001-add-todos
kyyn-v2 --kb PATH guest module show Kyyn.Workspace.Evolution --evolution 000001-add-todos
kyyn-v2 --kb PATH guest symbol show Kyyn.Workspace.After.todos --evolution 000001-add-todos
```

This adds `Kyyn.Workspace.Evolution`, `Kyyn.Workspace.Before` and
`Kyyn.Workspace.After` to the SDK catalogue. Results identify the workspace and
its declared Before revision (`result.context` in JSON). The schema and metadata
must compile, but the evolution body can be missing or unfinished. Fix invalid
target schemas and repeat the command; omit the option to inspect the SDK alone.
Human module output places workspace-defined operations before reexports.
`--runtime DIRECTORY` selects the runtime for either form of discovery.

If an older installation lacks the catalogue, reinstall with `bash tools/install-cli.sh`.

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

Execution uses the accepted helper and latest fetched evidence. Fetch the named
instances first with `evidence fetch PLUGIN INSTANCE`. Results are Dhall by default;
add `--json` for structured JSON. Discovery does not execute the helper.

Existing KB manifests without tools need this field in `kb.dhall`:

```dhall
, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }
```

New KBs already include it. An older captured evolution may need the same manifest
update before it can be checked with this development build.

## Recipe declarations and curation progress

Recipes are first-class data in `KnowledgeBase a`, alongside the authored domain
Root. Add, edit and remove them through ordinary evolution steps:

```haskell
import Kyyn.Workspace.Evolution
import Kyyn.Schema (Fact(..), FactId(..))

evolution = edit (Rationale "Teach the KB how to curate todos" []) $
  within recipes $ append (Fact (FactId "syncTodos")
    (Recipe "Inspect item/status evidence and update todos."))
```

Use `update` and `remove` with the same FactId to refine or remove the recipe.
The ID is its name and follows the connector-binding identifier rule; IDs must
be unique. Recipe changes appear distinctly in the evolution review.

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
(`plugin`, `instance`, `fetch`) and `changes` (`id`, `kind`), comparing latest
evidence against this recipe's accepted acknowledgements. It neither fetches nor
marks anything handled. Missing evidence asks you to fetch; changed producers ask
you to refetch or reconcile as appropriate. An empty list means no unacknowledged
changes, not that the recipe's task is complete. Use plugin methods or KB tools to
read the actual evidence.
