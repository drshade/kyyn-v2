# Generated ADT codec integration

Run `bash tools/test.sh` from the repository root. To repeat only this boundary
after native dependencies are installed, run `bash tools/test-guest.sh`.

The native compiler adapter inspects `Model.Root` and its alias using MicroHs's
checked declarations. Pure generation emits codecs importing those declarations;
MicroHs compiles the generated module with the private guest runtime. A native
Aeson test sends runtime values and independently checks the returned JSON.

Covered: records, instantiated polymorphic records, aliases, newtypes, Either, nullary and single
positional payload constructors, named record payloads, lists, nested optionals,
String, Bool and canonical arbitrary-precision Integer strings. Two differently
named generated codec modules coexist in the compiled guest. Negative cases
exercise unsupported recursive/function/opaque types, ill-typed modules, multiple
positional fields, missing modules/types, tuple/Char/Double/Natural fields,
malformed input, fields/tags and numeric/profile restrictions.
Unknown shapes produce diagnostics, not a fallback representation.

Multiple positional constructor fields currently require an authored record
payload. Decimal/date libraries, metadata/roles, full contract identity and root
storage are not implemented by this slice. `DataType` carries resolved Haskell
binding information; `shapeOf` projects the structural `Shape` algebra from it.
This is not yet a `CheckedContract` with schema metadata.
Inspection forces its result before returning, reports compiler/unsupported-type
diagnostics separately from native operational failures, and rethrows asynchronous
exceptions. It is a native library boundary, not an installed porcelain handler.

Compilation uses GuestCompilation with captured authored/generated/SDK sources.
It produces `.comb` bytes, which are executed by the bundled evaluator through
ProcessExecution. Both subprocesses have an empty PATH; no C compiler is needed
after the MicroHs toolchain is built. Build directories are removed before the
same compiled value is exercised against multiple runtime inputs. Each invocation
has its own temporary artifact scope. No test artifact persists in the checkout.

Additional cases exercise captured CPP imports, reusable bytecode, canonical
source identity (including selected entry), source/path rejection, missing compiler,
and structured distinction between code rejection and operational failure. Native
compiler exit/crash policy is also checked with deterministic process responses;
these complement rather than replace the real compiler/evaluator tests.

The native adapter package builds compiler sources from the monorepo's `vendor/`
tree. Use a complete checkout or Git source archive, not an individual package's
`cabal sdist`; Cabal reports that the upstream source directories lie outside the
adapter package. This slice does not establish release packaging.
