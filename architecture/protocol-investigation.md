# Runtime protocol: evidence and selection gate

Research notes, 5 September 2026. This is not a completed JSON compatibility
experiment. Library selection remains open in ADR 0007. No JSON library was
compiled under MicroHs during this documentation task.

## What is actually established

The existing host-effect experiment executes a pure guest program with a live
continuation over several host requests. Its direct-Dhall codec round-trips a
documented data subset and the native host checks messages with the actual Dhall
library. This proves the interaction model, not a reason to maintain that parser.

Bundled `cpphs` builds from MicroHs's generated C using `make bin/cpphs`; the
prototype bootstrap now includes it. Retried imports get beyond preprocessing:
microlens 0.5.0.0 rejects `type family Index`; dhall-haskell 1.42.3 reaches the
associated `type Item` in `Dhall.Map` and is rejected. These are bounded import
probes, not proof that a port is impossible. The pinned compiler is 0.16.6.0,
revision `455782164e75998b140d869c1b7cdde0c8a21508`.

The prototype also exposed a UTF-8 assumption in its pinned ByteString handle IO.
Any new library's parser/builder and the pipe transport must be tested with real
Unicode—not inferred correct from an ASCII demo or a GHC-only test.

## Candidate assessment

| Option | Evidence | Assessment |
| --- | --- | --- |
| Full Dhall in both peers | Host library works; useful guest import not established | Too much guest machinery for plain runtime values |
| Handwritten data-only Dhall | Existing proof passes its covered cases | Do not adopt as product parser; own-subset maintenance is precisely the concern |
| Aeson on host and guest | Established JSON library; guest dependency compatibility untested | Strong host choice; do not assume full guest package works |
| Aeson host, microaeson guest | Small API; concrete restrictions below | Candidate, not default; compatibility, diagnostics and license gates |
| Another maintained small JSON library | Not evaluated here | Worth considering if it avoids a broad port or fork; same conformance suite |
| Custom binary / Show-Read | Could reduce some syntax work | Sacrifices ecosystem/inspection and still needs a defined typed mapping; not the first recommendation |

[Aeson](https://github.com/haskell/aeson) supplies maintained JSON parsing and
encoding. The wire contract must explicitly define its field/tag representations
rather than inheriting generic-instance defaults. Using a library does not
eliminate the need for generated domain codecs.

## Microaeson is small, not MicroHs-specific

The inspected [package definition](https://github.com/haskell-hvr/microaeson/blob/master/microaeson.cabal)
identifies version 0.1.0.3, GPL-3, dependencies on base, array, bytestring,
containers, deepseq and text, and an Alex build tool. Alex output can be generated
when building a release; it need not become a user-installed tool, but that
distribution path needs proving.

Its [implementation](https://github.com/haskell-hvr/microaeson/blob/master/src/Data/Aeson/Micro.hs)
uses lists for arrays and `Map Text Value` for objects. Numeric values are
`Double`; integer conversion can lose precision. Optional encoding collapses
`Nothing` and `Just Nothing`. Decoder errors become `Nothing`, losing useful
details; duplicate keys collapse through `Map.fromList`. Generic derivation of
the library's own `Value` does not automatically generate codecs for arbitrary
user records. API similarity to Aeson is not identity.

Consequences for Kyyn are recommendations, not claims of library defects:

- Avoid numeric loss with explicit exact-value string codecs, not coercion
  through the default integer instances.
- Generate unambiguous tagged options/unions rather than using nullable defaults.
- Preserve field-path errors in generated structural decoding. If syntax failures
  remain generic, decide whether that meets authoring needs; do not fake locations.
- Document duplicate-key policy consistently. Do not write a new scanner merely
  to demand a policy the chosen library cannot provide.
- Review license fit before embedding the guest library in every plugin bundle.
- Compile the real generated scanner, builders and dependencies on pinned MicroHs.

JSON's interoperability cautions about duplicate keys and numeric precision are
documented in [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259). Restricting the
typed value mapping is different from writing a restricted JSON syntax parser.

## Smallest decisive experiment, after review

1. Pin a candidate library and build it with the distributed MicroHs toolchain.
   Record every patch, generated-source requirement and dependency license.
2. Generate bindings for the training/reporting value shapes, including nested
   optional values, payload unions, references, dates, large integers and money.
3. Load those values at runtime into compiled code; do not generate fact literals.
4. Run a pure transformation and a multi-request capability program through
   real framed pipes with Unicode and malformed-input cases.
5. Independently decode each peer's output, compare typed values, inspect errors,
   and repeat from a clean installation without ambient language toolchains.
6. Review the authored module. If it mentions JSON/Dhall transport, request IDs,
   decoder boilerplate or private host modules, the authoring boundary has failed
   even if the transport works.

Stop and revisit the library/runtime choice if this requires a parser fork or
substantial base-library/compiler work. Do not turn this gate into another
open-ended prototype implementation by accident.
