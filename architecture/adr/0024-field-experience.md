---
id: 0024
title: 'Fresh-agent scenarios and two-part field reports'
---

# Fresh-agent scenarios and two-part field reports

## Context

Authors already know the intended tool sequence and can unconsciously compensate
for bad discovery and errors. Passing deterministic tests or an agent saying
“done” does not establish a usable product. Kyyn-v1's reports usefully paired
telemetry with the agent's experience; we should make that repeatable and easier
to feed back into design, without importing its release-governance machinery.

## Decision

Maintain versioned scenario packages: a synthetic seeded KB, fixed local plugin sources and
runtime inputs, a user-level task prompt, declared starting knowledge/tools,
observable outcome checks, and a short reflection prompt. Start a fresh agent
without implementation-session context. Give it the task and normal product
discovery, not a script prescribing tool names or the evaluator's checklist.

Run through the actual MCP adapter and common application operations. Instrument
MCP discovery and calls at the adapter boundary, correlating operation IDs with
elapsed time, result/error status, selected snapshot/candidate and response volume.
Record CLI/file-edit fallback and human intervention when available, and clearly
state observation gaps. Instrumentation is an optional test observer, not a new
effect every KB function must request or a mandatory production provenance ledger.

After the task, collect the agent's account before feeding it the evaluator's
interpretation. Independently inspect resulting KB/artifacts and compare them
with the task outcomes. The resulting field report has both halves: observable
trace/outcome and agent experience, plus reviewer synthesis. Neither replaces
the other. Do not request hidden chain-of-thought; concise explanations of visible
actions, confusion and workarounds are sufficient.

## Experiment discipline

Support natural tool access (representative work) and deliberately restricted
MCP-only discovery probes; label the condition. Restriction is an experimental
control, not a product rule that agents may never edit source. Record the exact
build, scenario revision, model/harness/configuration, prompt, tool catalog and
cache condition. Repeat important comparisons; one stochastic run is not a
benchmark. Partial, failed, cancelled and assisted runs remain visible.

Include agent-driven installation/readiness and opening a KB for a human under
ADR 0025, recording permissions, configuration work and human assistance rather
than assuming a developer's prepared machine. Test schema-authoring ergonomics
within ADR 0005's selected Haskell surface: record edits, compiler/schema errors,
unsupported-shape diagnostics and recovery cost. Compare scaffolding and discovery
presentations over equivalent supported types, not competing schema authorities.
Lower agent error rates remain a hypothesis to test, not an established consequence
of choosing Haskell. These scenarios do not introduce another frontend or reopen
the authority decision as a routine implementation gate.

Web/human handoffs belong in scenarios too. If an agent simulates the human,
label it; that run cannot establish actual human usability. Feedback, candidate
identity and effects are evaluated across both surfaces under ADR 0023.

## Consequences and verification

Field tests are a developer/research harness outside Kyyn's runtime workflow,
using disposable KBs and destinations. No unattended live publication or private
data is implied. Sanitized reports may be committed; payload-bearing transcripts
stay local under an explicit retention policy. Corrections append to the record
rather than rewriting a failed run as successful.

Each finding links a concrete incident to a proposed product/interface change,
an ADR or ordinary issue, and a scenario to rerun. No numeric score optimizes call
count at the expense of correctness or appropriate human consultation. See the
[method and templates](../field-experience/README.md). No field run is claimed by
creating these documents.
