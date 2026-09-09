# Trying the first CLI

The current CLI supports root inspection/checking and the evolution commands in
[ADR 0018](../architecture/adr/0018-surfaces.md#cli-navigation-and-kb-selection).
The installed integration fixture covers schema-changing acceptance and inherited
examples; this is not a released installation.

From the development repository, assemble a new staging directory:

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

Copy the example into a fresh directory and give it an initial Git commit:

```sh
mkdir /tmp/my-todos
cp -R examples/todos/. /tmp/my-todos/
git -C /tmp/my-todos init -b main
git -C /tmp/my-todos add .
git -C /tmp/my-todos commit -m 'Initial knowledge base'

/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos root check
/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos evolution new my-change
```

Git needs your normal identity configured for that setup commit. The example
contains two todos, an authoritative Haskell schema and a blank-title validator.
It has no queries or saved examples yet. The returned ID identifies a draft
workspace. Edit its `change/Evolution.hs` and, when changing schema or validation,
its `target/` files. `before/` records the selected source. Use the returned ID
in place of `ID` below:

```sh
/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos evolution evaluate ID
/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos evolution show ID
/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos evolution check ID
/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos evolution ready ID

export GIT_AUTHOR_NAME='Your Name'
export GIT_AUTHOR_EMAIL='you@example.com'
/tmp/kyyn-development/bin/kyyn --kb /tmp/my-todos evolution accept ID
```

The generated scaffold is an identity evolution until edited. `evaluate` saves a
candidate; `check` and `accept` use that saved result rather than executing the
evolution again. Inspect the candidate and its rationale with `show` before
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
