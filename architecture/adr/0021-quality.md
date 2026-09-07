---
id: 0021
title: 'Architecture is a tested deliverable before feature volume'
status: proposed
date: 2026-09-07
---
# Architecture is a tested deliverable before feature volume

Basis: deliberate implementation with precise, expressive boundaries is an
owner requirement. The ordered proofs and their workload choices are proposed
engineering mechanics, not a claim that any software gate has already passed.

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

## Ordered implementation slices

The first implementation is a CLI journey through the real kernel and MicroHs:
load–compile–validate, followed by evolution, saved-candidate checking and local
acceptance/reopen. Use the [todo walkthrough](../walkthroughs/todo-evolution.md)
as its integration fixture. Create only the packages needed for those operations,
with real build/tests at each merge, rather than a package-scaffolding PR or a
separate native-Haskell stand-in for guest execution. The codec compatibility and
dependency gates below must be resolved before relying on that runtime boundary.
This establishes a narrow working foundation; it does not discharge the reporting,
Web/MCP, capability, performance or distribution proofs below.

1. Accept meaning/boundary decisions. Establish the package DAG and operation
   signatures inside the first working CLI PR, with forbidden imports checked.
   Load/compile can be established before validation exercises the runtime codec.
   No empty capability implementations pretending the product exists.
2. Carry ADR 0005's passing standalone schema-extraction/binding proof into the
   production boundary, retaining its conformance tests; resolve local source capture,
   packaging/maintenance and the remaining wire/library/license gates.
   Prove pure Haskell schema-metadata evaluation and field-role coherence without
   reading facts. Integrate selected existing numeric types/codecs; the fixture's
   coefficient/scale record does not establish production decimal arithmetic.
   Bind an authored heterogeneous root and
   method binding; load runtime facts; exercise one multi-request host program.
   This is the protocol proof; slice 3 repeats it inside the actual reporting KB.
   Prove the authored module has no protocol imports. Carry a payload union,
   nested optional, exact amount and reference through disk/host/guest/browser;
   test exact semantic values and canonical codec round trips, not preservation
   of arbitrary source spelling. Measure whole-root costs before relying on them.
3. Implement evaluate/check/inspect with the synthetic reporting model and both
   Web and MCP surfaces. The human contributes an example/design comment; the
   agent discovers it and revises the proposal; both inspect the same data/view
   differences, source/check changes and warnings. Include a policy-only evolution
   and a schema-changing evolution, such as optional forecast confidence, with
   add/edit/delete. The agent prepares an evolution workspace whose single
   `evolution` binding is evaluated through the ordinary MCP/Web/CLI operations.
   The entry makes several typed host requests (including a request depending on an earlier response) to
   inspect anomalies and return its proposed root. Kyyn materializes a candidate;
   there is no guest `Propose` call. This fixture needs no provider or secret
   capability. This tests generated
   Before/After types and their bindings AND the guest capability/continuation encoding within the
   product loop; neither proof waits for the connector slice. Keep the CLI useful
   for development and automation. Exercise setup/open/close under ADR 0025.
   Include a composed Before-to-Mid-to-After migration: inspect/generate bindings
   for the explicit intermediate schema and retain the two distinct step reports.
   Measure whole-root encoding, transfer, diffing and archive growth as fact volume
   and annotated step count increase. Reject a wrong initial observation, a gap
   between steps, a mismatched final result, and a changed root with no observations
   as `EvolutionRejected`; unchanged identity with no observations must succeed.
   Test malformed chains at the host boundary and a compile-fail authored attempt
   to construct/update the SDK's private EvolutionOutput/StepObservation values.
   The agent trials/refines the workspace and marks it Ready; the human reviews
   its outputs and accepts or requests revisions, without a helper-launching UI.
4. Implement acceptance/reopen and Git races/crash cases, including deletion.
   Reopen a record's history from archived step reports without historical guest
   execution. Test ordered rationale under associative composition and identity,
   two changes to one record that cancel in the final diff, schema changes,
   deletion, unavailable evidence and ordinary Git edits without rationale.
   Verify acceptance stores the evaluated report, not a subsequently edited file,
   and that merely reading evidence does not produce a citation or review duty.
   Together slices 3–4 complete the first reporting product journey; acceptance
   is not an untested happy-path shortcut hidden in the preview slice.
5. Vendor and locally compile an independently authored tap plugin. Exercise one
   provider package with two named instances of the same connector type and another
   connector type, plus a second plugin in the same KB. Prove correct instance
   selection with shared and different secret keys, config isolation and missing-key
   repair and omission of sensitive host trace payloads. Acquire/refresh paged evidence and
   repeat curation without duplicate knowledge using the training fixture.
   Malformed config must fail the whole root load with a useful file diagnostic;
   decoded config rejected by its pure validator must fail whole-root validation.
   Neither case silently disables an instance or returns a partially valid root.
   Rebuild offline from the vendored source with local compiled artifacts removed;
   no imported plugin executable or review-receipt mechanism is needed.
6. Prove the output path in ADR 0017: a renderer composes several queries over
   one selected root and produces a configured first-party file sink's exact input
   type. Inspect preparation, explicitly invoke the sink and verify the written
   bytes. Ordinary query browsing and output preparation must make zero sink calls.
   Discard a preview result and update by rendering afresh; no retained preview is
   required. Check unchanged-input reproducibility and an update that deliberately
   selects newer inputs. Test renderer/sink type mismatch, a source passed as a
   sink, independent and dependent queries, and a non-file structured sink input.
   Exercise failed/uncertain invocation through Web/MCP/CLI, then supported-platform
   release installation. A separate native destination path is not the file-sink proof.
   Exercise the same registered query/renderer form with pure calculations and
   actual snapshot reads. Test relative file destinations from different process
   working directories, plus an explicit absolute destination: the host adapter
   resolves against the selected KB directory without importing plugin config types.

Each slice completes a real path and its failure behavior. These are engineering
milestones, not product-visible states or permission to stub every later interface.
In the reporting loop include a failed required example, a guest crash mid-check
and cancellation by the owning caller. Include proposed code that does not compile:
capture it, return an ordinary preview rejection and attach source feedback before
any candidate root exists. Include compile errors in target validation/query/evolution entries
that the evolution never calls; they use the same pre-candidate rejection channel.
Also count acquisition calls: checking and acceptance must not rerun the entry.
An explicit re-evaluation with changed evidence produces a new candidate for review.
Broken unrelated drafts and archives must not enter that compilation scope. Repair
a structurally readable but semantically invalid head through an evolution: retain
source diagnostics, require the resulting candidate to pass, then accept normally.
Do not require Web to cancel an independent
MCP process as a condition of this first slice. Start installer/toolchain feasibility
checks alongside the runtime proof; final supported-platform verification is not
a reason to discover packaging blockers only after feature completion.

The reporting-first order is a review recommendation, not a claim that training
has no value without a connector. Reporting exposes arithmetic, missing-versus-zero,
budget grain and shared policy through useful local inputs before provider work.

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
