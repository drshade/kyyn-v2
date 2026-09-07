# kyyn-v2

The Kyyn rebuild. Start with the [architecture decisions](architecture/README.md)
and [architectural principles](architecture/principles.md).

For development, read [the SDLC](docs/SDLC.md),
[project practices](docs/PROJECT-PRACTICES.md) and [contributing](CONTRIBUTING.md).
Run the complete current gate with `bash tools/test.sh`.

The first implementation boundary inspects Haskell data types with the native
MicroHs frontend and generates private JSON codecs importing the authored types.
The gate compiles and executes those codecs with the vendored MicroHs toolchain.
Guest invocation uses a scoped native process interpreter, tested for pipe exchange,
failure and cancellation cleanup.
See [the codec integration fixture](tests/integration/codecs/README.md) for scope
and supported cases. There is not yet a user-facing KB CLI.

Build prerequisites are in [project practices](docs/PROJECT-PRACTICES.md).
Earlier experiments remain in the separate `kyyn-v2-experiment` repo.
