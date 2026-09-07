# Runtime protocol: evidence and selection gate

Initial research: 5 September 2026. The bounded `json` probe below was performed
on 7 September. [ADR 0007](adr/0007-wire.md) records the subsequently accepted
library/profile decision; successful syntax round trips alone do not establish
the complete runtime protocol.

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

## Bounded `json-0.11` probe — 7 September 2026

The [retained sources and commands](evidence/json-probe/README.md) reproduce this
evidence, including the failing baseline. They are not production adapters.

The published [json-0.11 source](https://hackage.haskell.org/package/json-0.11/json-0.11.tar.gz)
has SHA-256 `d079ab12e2482349421044851cf52cf23d0bf762ca9b5c854c902def7277e690`.
Its included license is BSD-3-Clause, with source/binary notice and non-endorsement
conditions. No dependency adoption or distribution clearance is implied by the
probe. The upstream repository is [GaloisInc/json](https://github.com/GaloisInc/json).

Pinned MicroHs `455782164e75998b140d869c1b7cdde0c8a21508` compiled the unchanged
`Text.JSON.Types` and `Text.JSON.String` modules. This uses the latter's direct
`runGetJSON readJSValue` parser and `showJSValue` encoder, not the umbrella
`Text.JSON` module or its optional Parsec/ReadP backends. The small executable read
one line with `getLine` and wrote the library-encoded result with `putStrLn`.
Node supplied runtime input through real child-process pipes and inspected output.

Observed results:

| Input | Observed result |
| --- | --- |
| Literal `München 日本語 🦋`, escaped controls including NUL | Values round-trip over actual UTF-8 pipes |
| Very large integer/decimal strings, explicit nested Some/None objects, empty list | Structure/text round-trip; no numeric arithmetic or generated scalar codec proved |
| Truncated object or trailing garbage | Library returns a syntax diagnostic |
| Duplicate object fields | Association-list representation preserves their order |
| JSON number with leading zero (`01`) | Accepted and re-encoded as `1`; not strict JSON syntax conformance |
| Valid escaped surrogate pair (`\ud83e\udd8b`) | Decoded as two surrogate Chars; output crashes with `hPutChar: surrogate` after a partial frame |

Native GHC 9.10.3 with Aeson 2.2.5.0 independently confirmed that its encoder emits
literal UTF-8 for these non-ASCII characters and escapes the control characters.
Its default decoder keeps the first duplicate object key. Guest normalization
would have to use that same policy rather than assume the two libraries agree.

The surrogate result is a library decoding limitation, not proof that MicroHs
cannot carry Unicode: the literal form works. Inspection of upstream `String.hs`
still showed independent decoding of each `\\uXXXX` escape. A second source-only
inspection, `yocto-1.0.0`, found the same per-escape decoding pattern and a Parsec
dependency; it was not compiled and is not an established alternative.

A possible restricted private profile uses library-generated literal UTF-8,
number strings as already proposed in ADR 0007, and decoded-value checks that
reject surrogate Chars before dispatch or encoding. This needs no parser patch
or additional JSON scanner. Both generators must be tested; a passing ASCII-only
test would not establish it. It preserves every Unicode scalar value but does
not promise to accept every valid equivalent JSON spelling in the guest.
The owner accepted this tradeoff in ADR 0007. The probe is evidence for that
direction, not an implemented production adapter.

A second temporary executable added only decoded-value validation and first-key
normalization around those unchanged library calls. Six asserted real-pipe cases
passed: the combined Unicode/control/exact-string/tagged-option/empty-list value;
escaped surrogate-pair rejection; JSON-number rejection (including `01`);
truncated-object rejection; trailing-garbage rejection; and first-key duplicate
normalization. Rejections produced one complete fixed error object, with no
partial output or runtime exception. This checks the proposed mitigation, not
Kyyn's still-unimplemented protocol-error envelope or generated domain codecs.
The retained driver adds nested string-value and object-key cases: decoded-value
checks apply at every depth of the retained value. It also asserts the native
duplicate policy specifically for Aeson 2.2.5.0; dependency updates must rerun that
assertion rather than assume the policy is unchanged.

The probe does not establish generated schema bindings, full framing/envelopes,
capability requests, cancellation, clean installation or whole-root validation.
Do not count it as completing those gates or the first implementation outcome.

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
