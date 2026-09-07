# Generated ADT codec integration

Run `bash tools/test.sh` from the repository root. To repeat only this boundary
after native dependencies are installed, run `bash tools/test-guest.sh`.

The native compiler adapter inspects `Model.Root` and its alias using MicroHs's
checked declarations. Pure generation emits codecs importing those declarations;
MicroHs compiles the generated module with the private guest runtime. A native
Aeson test sends runtime values and independently checks the returned JSON.

Covered: records, instantiated polymorphic records, aliases, nullary and single
positional payload constructors, named record payloads, lists, nested optionals,
String, Bool and canonical arbitrary-precision Integer strings. Negative cases
exercise unsupported recursive/function/opaque types, ill-typed modules, multiple
positional fields, malformed input, fields/tags and numeric/profile restrictions.
Unknown shapes produce diagnostics, not a fallback representation.

Multiple positional constructor fields currently require an authored record
payload. Decimal/date libraries, metadata/roles, full contract identity and root
storage are not implemented by this slice. `DataType` carries resolved Haskell
binding information; `shapeOf` projects the structural `Shape` algebra from it.
This is not yet a `CheckedContract` with schema metadata.

The test harness invokes the compiler directly by its explicit vendored path;
production compilation workflows will use the GuestCompilation capability.
Its artifacts are isolated in `.build/codecs`, never a production compiler cache.
No porcelain code or effect handlers are introduced merely to wrap a test harness.

The native adapter package builds compiler sources from the monorepo's `vendor/`
tree. Use a complete checkout or Git source archive, not an individual package's
`cabal sdist`; Cabal reports that the upstream source directories lie outside the
adapter package. This slice does not establish release packaging.
