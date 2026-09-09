# Trying the first CLI

The executable is named `kyyn-v2` while the original version owns `kyyn`.
The current CLI supports root inspection/checking and the evolution commands in
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
invoke GHC, Cabal, Node or a C compiler. Git must be available, or selected with
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
import qualified RootV1 as Before
import qualified RootV2 as After

evolution :: Evolution Before.Root After.Root
evolution =
  editBefore (Rationale "Correct an old title" []) correctTitle
  >=> evolve (Rationale "Add review status" []) addReviewStatus
  >=> editAfter (Rationale "Remove the cancelled task" []) removeCancelledTask
```

The three helpers in this sketch are ordinary authored functions returning
`Either EvolutionFailure` of the appropriate root. `Kyyn.Workspace.Evolution`
is generated when checking: it supplies the endpoint-specific step constructors,
composition, rationale/evidence, fact and diagnostic types. No generated bindings
or execution wrapper need to be supplied. Each step produces its own diff.
Same-schema changes can use only edits. For a schema change, give the new module
a distinct name, update `target/kb.dhall` and the After import, and implement
the transition with `evolve`. Temporary helper types need no declaration.

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
