---
id: 0011
title: 'Validation checks a complete candidate, not reality'
status: proposed
date: 2026-09-07
---
# Validation checks a complete candidate, not reality

## Context

Per-fact checks are useful, but cross-record relationships and reconciliation
are central to the working KBs. Types alone cannot verify business meaning.

## Decision

Keep three distinct results: structural decoding/contract errors, KB-authored
semantic diagnostics, and executable example expectations. A diagnostic has
severity, stable code, readable message, and optional fact/field/source location.
Errors block validation; warnings remain visible without automatically rejecting
useful partial knowledge. A failed required example blocks readiness to accept.

These outcomes must retain diagnostics even when a checked value is returned:

```haskell
data Severity = Warning | Error

data Diagnostic = Diagnostic
  { severity :: Severity
  , code     :: DiagnosticCode
  , message  :: Text
  , location :: Maybe DiagnosticLocation
  }

newtype ValidationReport = ValidationReport [Diagnostic]

data CheckResult a
  = Rejected ValidationReport
  | Passed a ValidationReport
```

`DiagnosticLocation` identifies a fact/field, source span or example, rather than
requiring callers to parse the message. `Passed` may contain warnings. These are
pure values shared with the guest SDK; they do not contain native exceptions.
The optional location is deliberate: compiler messages without structured spans
remain useful diagnostics with `Nothing`, as specified in ADR 0019. Neither a
missing span nor a warning may be mistaken for a missing diagnostic.

The semantic baseline is complete-root validation against the candidate's own
schema and code. Offer per-fact functions as composition helpers and aggregate
checks. Rules needing both before and after values belong in the evolution's
fallible transformation; the root validator receives only its selected root.
Do not replace arbitrary
whole-root rules with a summary API that cannot express them.

The authored validator consumes the **guest's concrete root**, with no capability
row. The native host's execution capability invokes that code on decoded data:

```haskell
-- Guest module; Root is an authoritative authored Haskell type for this KB.
validate :: Root -> ValidationReport
```

On the **host**, `Root` is instead the opaque snapshot from
[ADR 0004](0004-knowledge-base.md). These selected execution constructors make
evaluation distinct from persisting or publishing its output:

```haskell
data RootExecution :: Effect where
  ValidateRoot
    :: Root -> RootExecution m ValidationReport
  ExecuteQuery
    :: Root -> QueryDescriptor -> CheckedValue -> RootExecution m CheckedValue
  PrepareOutput
    :: Root -> OutputDescriptor -> CheckedValue -> RootExecution m PreparedOutput

runRootExecution
  :: (RootStore :> es, GuestCompilation :> es, ProcessExecution :> es,
      FileSystem :> es, SchemaInspection :> es, Failure :> es)
  => Eff (RootExecution : es) a -> Eff es a
```

Effectful entry evaluation belongs to [EvolutionExecution](0010-evolutions.md),
not this snapshot-checking/query effect. It derives `After`, generates bindings,
compiles the proposed program and returns the target contract with its structurally
checked result. The application materializes that result before candidate checking.
RootExecution checks the selected snapshot; it does not invoke the evolution again.
It delegates builds of checking/query/output adapters to
[GuestCompilation](0002-runtime.md), then uses ProcessExecution for the resulting
entry. Loading a saved candidate may require compiling its checking code if the
build cache is empty; forbidding evolution re-execution does not forbid compilation.
Compiler flags and toolchain paths remain in the compilation interpreter.

Treat the selected proposal as one build scope: before materializing a candidate,
typecheck the evolution and every executable entry point to be published in the
target root, including validation, query and evolution entries, with their captured local dependency
closure. This includes entries the evolution does not call. Compile errors in any
of them return `ProposedCodeRejected`, not a later validation report. It does not
mean compiling unrelated drafts, accepted evolution archives, or source-root
validators into the proposed program. Before contributes the schema/decoding
definitions needed by the transformation. There is one proposal-level compilation
gate and rejection channel; this does not prescribe a module-level build cache.

The source input need only be structurally readable; semantic errors in its
validation report are information for review, not a prerequisite failure for
evaluation. This allows a typed transformation to repair an invalid head.
`ValidateRoot` reads the selected snapshot's
code/facts, never latest workspace files. None of these constructors can accept a root
or fetch live evidence. There is no Dhall dependency in execution: RootStore owns
fact/config-file decoding, SchemaInspection owns extracting contracts, and
binding generation is pure. Runtime helper names
and native process protocol are owned by [runtime](0002-runtime.md) and
[wire](0007-wire.md), not repeated implementations here.
RootStore supplies the explicit whole-root checking read; the interpreter does
not smuggle filesystem callbacks into `Root` to obtain its facts.

`PrepareOutput` evaluates an output's renderer against the supplied root and returns
its typed sink input/binding as defined in [outputs](0017-outputs.md). This result
may be recomputed; it is not an approval or persistent preview object. Like query
execution it can use selected-snapshot reads, but does not invoke the sink or any
live source. The normal application wrapper requires `Validated Root`; the raw
effect input is not permission for ordinary adapters to bypass that requirement.
Output adapters/renderers and their query dependencies belong to the proposed
code compilation gate, including outputs the evolution does not execute.

Examples are current-root material, not only attachments to a pending evolution.
Under the proposed [storage layout](0006-storage.md), they live in `root/examples/`;
authoring edits the workspace's `target/examples/`. Materialization includes them
in the candidate's CodeSnapshot, and publication installs that complete set.
Both `checkCandidate` and `loadAcceptedRoot` obtain examples through RootStore's
`ReadExamples` and execute them alongside semantic validation. Loading an accepted
root therefore retains their meaning after the authoring workspace becomes an
archive. Deleting or weakening an example is an ordinary visible root change.

Human-authored executable examples need a concrete, data-based form. Propose an
example naming a registered snapshot query, its typed arguments and expected
typed result. Free-text review notes are different objects. The host does not
know the query's Haskell types, so it checks these values against its descriptor:

```haskell
data Example = Example
  { query       :: QueryDescriptor
  , arguments   :: CheckedValue
  , expected    :: CheckedValue
  , requirement :: ExampleRequirement
  , explanation :: Text
  }

data ExampleRequirement = Required | Illustrative

makeExample
  :: QueryDescriptor -> UncheckedValue -> UncheckedValue
  -> ExampleRequirement -> Text
  -> Either [ContractDiagnostic] Example
```

`Example` construction checks the argument and expected-value contract identities;
two arbitrary `CheckedValue`s are not sufficient. `QueryDescriptor`, owned by
[authoring](0008-authoring.md), admits only selected-snapshot reads and pure
calculation. The example has no saved answer from a different root smuggled in
as a result of running it. Evaluation always receives the explicit target root:

```haskell
checkExample
  :: (RootExecution :> es, Failure :> es)
  => Root -> Example -> Eff es ValidationReport

checkCandidate
  :: (RootStore :> es, RootExecution :> es, Failure :> es)
  => Candidate Root
  -> Eff es (CheckResult (Candidate (Validated Root)))

loadAcceptedRoot
  :: (RootStore :> es, RootExecution :> es, Failure :> es)
  => KnowledgeBase -> GitRevision
  -> Eff es (CheckResult (Validated Root))
```

`checkExample` uses `ExecuteQuery`, not another effect. That operation resolves
the named query in the supplied root, checks arguments and checks the response
contract. Its raw-root input admits candidate checking, not an implicit relaxation
of ordinary query/browsing requirements. Required mismatches are errors;
illustrative mismatches remain visible warnings. Compare values using their
contract's exact structural/semantic equality, not floating-point coercion or
source spelling. A small named query can expose the one amount a person wants to
test; no field-selector/assertion language is required. Agents may additionally
author code-based checks in the ordinary validator.

Checking examples is allowed on structurally readable candidates before they earn
`Validated`; ordinary browsing still requires validation. Incompatible query
contracts after schema migration produce actionable diagnostics, not silent skips.
Persist the example's argument/result values and recorded contracts, not just a
query name and an untyped expected literal. Do not bypass whole-contract identity
using shape-only equality. Compare the saved argument/result contract identities with the selected query's
argument/result contracts, not with the whole Root contract. A Root schema change
alone does not invalidate an assertion whose query contracts remain equal. The
comparison still uses each whole contract, including its roles; there is no separate
presentation-only compatibility rule. When a query contract changes, the author explicitly
rebuilds the example against the new descriptor, checks its values and reviews the
change. A compatible assertion is carried forward in the target copy without
re-entering it for every evolution; no automatic compatibility subsystem is needed.
`checkCandidate` runs the candidate's semantic checks and examples using the
captured, already typechecked code, and returns the same context and fixed
evolution report with its validated payload. It does not infer supporting evidence
from validator reads or rewrite the author's rationale. A passing validator does
not prove the declared explanation or evidence justified the change.
Its `Rejected` result reports semantic/example failures, including
incompatible example contracts, not proposed-source compilation errors. Editing
the code requires a fresh capture and the compilation gate before checking again.
`loadAcceptedRoot` pins an explicit accepted revision
at the call site and admits failure of an unknown ordinary Git commit. A failing
validator therefore does not manufacture `Validated Root` or erase its report.
Callers obtain a local revision through RootStore's explicit `ResolveHead`, or
use the revision already recorded in Before. For repair, use `LoadRootAt` instead
of requiring a successful `loadAcceptedRoot`. The preview application retains
the source's validation report alongside the evaluation/checking outcome (see
the [composition sketch](../boundaries.md)); source errors do not earn validation
and do not by themselves reject the repair. Actual runtime failure remains Failure.

Capture source/configuration, dependencies and supporting input files before entry
evaluation. The workspace's `evolution` binding selects its helper and binds its
arguments in source (ADR 0010), not in a separate invocation manifest.
The entry may gather external inputs through declared capabilities;
its pure transformation helpers receive those as values. Candidate checks use
only the materialized result and captured checking inputs, never fresh acquisition
or rerunning the effectful entry. Time-dependent checks take a declared as-of
value; no hidden “now”. Checks apply to the actual evaluated
result and the schema, validators, examples, dependencies and inputs used to
produce/check it. Editing any of them or rebasing `Before` requires evaluation,
checks and diffs to be rerun; an earlier preview is not the revised result.
No separate sealing/approval protocol is required. Show edits to checks/examples
beside fact/report changes, especially removed checks. Passing the newly relaxed
validator is not evidence that the old intended rule survived.
Plugin configuration receives structural checking and any advertised pure
`validateConfig` checks as part of checking the selected root's config files.
This imports/calls the pure validation function through generated code, not an
effectful health method or secret lookup. Missing local credentials therefore do
not make a structurally/semantically valid configuration invalid on a fresh clone.

## Alternatives and consequences

Reject compile-all-facts validation and Bool-only reports. Start with complete
validation on each explicit check or load for validated use, without a validation
cache or per-fact invalidation mechanism. A `Validated Root` describes a fixed
snapshot, not a request lifetime. Code already holding that value may use it
across calls or requests without rechecking; it does not thereby describe a newer
head. This permits ordinary value reuse, not a requirement to retain roots or
build a cache, head watcher or invalidation service. Saved reports support inspection, not
skipping checks on a subsequent load. Measure whole-root cost honestly before
changing this baseline. Per-fact composition helpers do not imply incrementality.

## Verification

Fixtures cover dangling references, impossible durations, warning-only uncertainty,
empty roots, changed validators and aggregate discrepancies. A deletion that
passes structural checking can still fail an example. Loading a root for validated
use runs its checks, including when an earlier report exists for that revision.
Test that a compile error in an unused proposed validator, query or tool is caught
before candidate materialization, while broken unrelated drafts/archives do not
enter that build. Test source validation errors remaining visible during a
successful repair, with candidate failures still blocking acceptance.
