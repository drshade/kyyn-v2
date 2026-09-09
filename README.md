# kyyn-v2

The Kyyn rebuild. Start with the [architecture decisions](architecture/README.md)
and [architectural principles](architecture/principles.md).

For development, read [the SDLC](docs/SDLC.md),
[project practices](docs/PROJECT-PRACTICES.md) and [contributing](CONTRIBUTING.md).
Run the fast check with `bash tools/test.sh`. Run `bash tools/test.sh --full`
for full integration verification before completing an issue.

The first implementation boundary inspects Haskell data types with the native
MicroHs frontend and generates private JSON codecs importing the authored types.
GuestCompilation builds captured sources into immutable bytecode, then executes
it with the vendored evaluator; guest compilation does not invoke a C compiler.
Guest invocation uses a scoped native process interpreter, tested for pipe exchange,
failure and cancellation cleanup.
See [the codec integration fixture](tests/integration/codecs/README.md) for scope
and supported cases. The initial CLI now wires root inspection/checking and
evolution authoring, evaluation, checking and acceptance into those handlers.
Install locally with `bash tools/install-cli.sh`, then invoke `kyyn-v2` (the
existing `kyyn` command is left untouched).
See [trying the CLI](docs/cli-development.md) for installation, developer staging and a fresh
todo KB. The installed integration journey covers schema-changing acceptance
and inherited examples; this is not a released distribution.

Build prerequisites are in [project practices](docs/PROJECT-PRACTICES.md).
Earlier experiments remain in the separate `kyyn-v2-experiment` repo.
