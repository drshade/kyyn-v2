# 0019 — Typed failures, explicit cancellation and modest operational state

Status: Proposed. No general durable workflow engine is intended.

## Context

Untyped `fail`, swallowed IO errors and printed success obscure whether work
changed accepted state or an external destination. Long calls also need cancellation.

## Decision

Represent expected failures at their owning boundary: not found, invalid input,
contract mismatch, validation diagnostics, base conflict, missing local secret,
protocol failure and uncertain external outcome. Preserve source/fact/field
locations where available and a useful repair action. Translate native exceptions once at the
plumbing edge. Never turn unknown failures into empty successful results.

Validation reports are data, not thrown errors for every warning. Provider errors
are typed results that authored programs may handle. Fatal runtime/process failure
is distinct from a domain rejection. Surface both cleanly through every adapter.

Do not hide all of these behind one exception channel. Host operational failures
stop an operation; expected domain outcomes remain in its result type:

```haskell
data Failure :: Effect where
  Raise :: OperationalFailure -> Failure m a

runFailure
  :: Eff (Failure : es) a -> Eff es (Either OperationalFailure a)

data OperationalFailure
  = StorageUnavailable StorageDiagnostic
  | CodeRejected [Diagnostic]
  | RuntimeUnavailable RuntimeDiagnostic
  | ProtocolBroken ProtocolDiagnostic
  | ContractMismatch [ContractDiagnostic]
  | InvalidRequest [Diagnostic]
  | OperationCancelled
```

This is a selected failure vocabulary, not an excuse to convert every validation
diagnostic into `Raise`. Diagnostic payloads retain available structured locations and repair
information, with native causes translated at their owning boundary. Missing facts
use `Maybe` ([storage](0006-storage.md)); failed checks use `CheckResult`
([validation](0011-validation.md)); local publication and external delivery have
their own [acceptance](0012-acceptance.md) and [delivery](0017-outputs.md) outcomes.

`CodeRejected` is for execution outside proposed-work review, for example an
installed/previously usable program unexpectedly rejected after a toolchain change.
Do not raise it for ordinary compilation errors in a proposed workspace.
[Preview](0010-evolutions.md) returns `ProposedCodeRejected` before materialization
for compilation errors anywhere in the selected proposal's build scope, including
its target validation, query and evolution entries. [Checking](0011-validation.md) returns
`Rejected ValidationReport` for semantic/example failures, not a second compilation
error channel. The compiler helper returns diagnostics so the caller can distinguish
proposed-work rejection from failure of installed code. `RuntimeUnavailable`
means the runtime could not execute normally, such as a missing or crashed compiler.

For MicroHs compiler errors, initially preserve the original message and use
`location = Nothing` when the compiler supplies only exception text. Give the
diagnostic a host-owned category code; do not claim a parsed compiler subcategory
or manufacture a source span. The message may already contain a useful filename
and line, which every UI can display as text. Inspector-owned errors can retain
structured declaration/field positions from checked identifiers. This is an
intentional use of ADR 0011's optional location, not loss of the error itself.
Do not parse the compiler's prose for control flow or clickable positions, and
do not make an upstream structured-diagnostic API a prerequisite for the initial
implementation. Generated-source diagnostics remain honestly identified if an
authored-source mapping is unavailable.

In particular, after a commit or possible external write, catch cancellation or
native failure at that operation's boundary and report its meaningful outcome.
Do not raise `OperationCancelled` in place of an already-known accepting revision.
A hard process kill cannot return a value; inspecting persisted state afterward
must distinguish that case from a returned pre-effect failure.

Cancellation is operation-scoped. The composition root releases process pipes,
workers, temporary files and locks. Cancelling a pure computation prevents later
publication; cancelling after a remote write may leave `Uncertain`. Cancelling
after the local Git ref update reports acceptance, even if later checkout work
was stopped. This does not require a dedicated projection/recovery service.
Do not promise that killing a guest rolls back host actions it already requested.

Report progress and results to the owning caller. Do not add a generic persisted
operation registry; durability belongs to a concrete operation that needs it.
A crashed pure call can rerun from captured inputs; an external write cannot
blindly replay.
ADR 0017 assigns persistent delivery/dispatch outcomes to Delivery. Generic
progress is not a substitute for that specific restart behavior. ADR 0007 assigns
nested guest lifetimes to the outer invocation. Initially cancellation is exercised
through the operation's owning caller/process; Web cancelling work owned by an
independent MCP process is not an implied cross-process coordination feature.

## Alternatives and consequences

Reject string parsing of error messages, catch-all success, hidden retries and
one universal state machine for every operation. No per-field schema bounds.
Operational cancellation/deadline policy is separate from data contracts; tune
resource ceilings from measurements rather than smuggling them into every type.

## Verification

Inject every boundary failure and assert its caller-visible result and remaining
state. Include Unicode decoding errors, truncated frames, lost responses after
external dispatch, cancelled validation and failed checkout work after acceptance.
Logs carry useful identities but omit secret responses and all HTTP headers, URLs and bodies
under ADR 0016, and avoid dumping raw evidence. This is host logging discipline,
not a promise to detect all secret values copied into arbitrary plugin output.
