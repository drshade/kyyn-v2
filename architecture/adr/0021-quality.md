---
id: 0021
title: 'Architecture is a tested deliverable before feature volume'
---
# Architecture is a tested deliverable before feature volume

## Context

The prototypes answered useful feasibility questions and accumulated boundary
debt. A passing demo cannot justify carrying that structure into the rebuild.

## Decision

Start a clean implementation after reviewing the relevant ADRs. Port ideas and
tests, not package structure by inertia. Before a boundary is implemented, review
its public types, effect dependencies, handler composition, failure semantics and
one authored example. Keep these artifacts small enough to read together.
Apply the [architectural principles](../principles.md) in that review: identify
the current journey or correctness obligation for each mechanism, and remove
speculative fast paths, alternate implementations and unused interfaces. An
effect boundary is sufficient room for a later implementation change; it does
not need that change designed in advance.

Checks include pure properties, generated-contract round trips, compile-fail
boundary examples, deterministic semantic interpreters, real process/Git fault
tests and clean-install tests. Native integration must be tested as well as
simulated: an in-memory store does not prove atomic filesystem/Git behavior.
No direct provider access in routine tests; use synthetic fixtures and explicit
opt-in integration runs.

## End-to-end verification

Build complete paths rather than empty packages or a native-Haskell stand-in for
guest execution. Choose the next slice from a real user journey; implementation
ordering belongs in issues, not a permanent roadmap in this decision.

- Contracts/runtime: generated ADT codecs, exact values, actual MicroHs execution,
  typed host requests and nested-call cancellation (ADRs 0005–0009).
- Evolutions/acceptance: step reports, saved candidates, repair of invalid heads,
  inherited examples, deletion, Git races and post-publication recovery
  (ADRs 0010–0013). Checking/accepting must not rerun acquisition.
- Integrations: independently vendored source, multiple plugins/instances,
  configuration isolation, local secrets, refresh and curation (ADRs 0014–0016).
- Outputs/surfaces: typed renderers/sinks, no sink effects while browsing,
  failure/uncertainty and human/agent review (ADRs 0017–0019, 0023).
- Installation: a complete runtime on supported user machines, not merely
  successful execution in a developer checkout (ADRs 0020, 0025).

Test failures and boundary exclusions explicitly. A mocked compiler does not prove
guest compatibility; a successful CLI journey does not prove Web/MCP usability.
Keep concrete coverage/setup in the test entry headers and assertions.
[Project practices](../../docs/PROJECT-PRACTICES.md#verification) owns proportionate
check selection and review; a passing test never grants merge authority.

## Alternatives and consequences

Reject a big generated scaffold followed by cleanup, generic framework development
before a use case, and placeholder effects with `fail "unimplemented"` in a
claimed working path. Use explicit signatures, small modules, `NoFieldSelectors`
in host packages and deliberate local use of record conveniences; verify guest
extensions separately. Use `coerce` rather than selector/unwrap boilerplate.

Record measured compilation/evaluation times, memory, author edits and agent
mechanics calls. No numeric performance promises without a workload and baseline.
Use ADR 0024's fresh-agent field scenarios to pair MCP telemetry with an experience
report. Deterministic tests check correctness; field runs expose discoverability,
workarounds and human/agent friction. Preserve unsuccessful runs rather than
reporting only the successful final attempt.
Measure source compilation separately from disk parsing/normalization, wire
encoding/transfer/decoding, guest evaluation and memory, including cold and warm
caches for compiled artifacts. These measurements do not require schema,
validation or query-result caches. Start with synthetic scales such as 1k/10k/50k
facts, then representative shapes from the intended KBs. These are experiments,
not invented product limits.
If the representative interactive loop is impractical, revisit storage/evaluation
before building around it. Result paging serves browsing and evidence acquisition,
not an unimplemented storage-streaming or incremental-evaluation escape hatch.
If an operation needs most capabilities, review the design before adding another
constraint. No mandatory contributor governance beyond normal tests and review.
