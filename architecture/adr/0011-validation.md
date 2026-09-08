---
id: 0011
title: 'Validation checks a complete candidate, not reality'
status: accepted
date: 2026-09-07
---
# Validation checks a complete candidate, not reality

Basis: complete-root checking and the distinction between Candidate and Validated
follow owner direction. Saved examples, root checking and candidate checking are
implemented; accepted-load and complete proposal integration remain outstanding.

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
The first shared representation uses `FactLocation collection factId field`,
where the field is optional; `SourceLocation file line column`, a one-based source
position; and `ExampleLocation name`. A compiler without a structured position
leaves the diagnostic's location absent. `errorDiagnostic` constructs an error
without a location for structural/compilation failures. `checkReport` classifies
a supplied report and retains it on either result; it does not itself execute
checks or turn the supplied value into a `Validated` value.

The fixed SDK report codec carries a list of diagnostics over the JSON boundary.
Severity and locations use tagged alternatives; optional locations/fields use
the wire's None/Some form, and source coordinates use canonical integer strings.
Malformed protocol data is a decoding failure, not a semantic error report or an
empty successful report. The guest author returns `ValidationReport`; the runtime
encoder and host protocol decoder own serialization.
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
  CheckRootCode
    :: Root -> RootExecution m (Either [Diagnostic] ())
  ValidateRoot
    :: Root -> RootExecution m (Either [Diagnostic] ValidationReport)
  ExecuteQuery
    :: Root -> QueryDescriptor -> CheckedValue
    -> RootExecution m (Either [Diagnostic] QueryResult)
  DiscoverQueries
    :: Root -> RootExecution m (Either [Diagnostic] [QueryDescriptor])
  PrepareOutput
    :: Root -> OutputDescriptor -> CheckedValue -> RootExecution m PreparedOutput

runRootExecution
  :: (RootStore :> es, GuestCompilation :> es, ProcessExecution :> es,
      FileSystem :> es, SchemaInspection :> es, DhallHandling :> es, Failure :> es)
  => FileTree -- explicitly installed SDK/runtime sources
  -> Eff (RootExecution : es) a -> Eff es a
```

`ValidateRoot` is the first implemented operation. RootStore's `ReadRootDefinition`
decodes the captured manifest and extracts captured authored sources; its
`LoadRootValueForChecking` supplies the structurally checked whole-root value.
The manifest-selected validator is compiled with a generated root codec and a
fixed adapter requiring `Root -> ValidationReport`. Facts travel at runtime over
stdin, not as generated source literals. The host decodes the SDK report on stdout.
The contract already belongs to the supplied root; execution does not inspect
a new schema or read current workspace files. SDK/runtime sources are explicit
interpreter inputs, not acquired through the KB's manifest.

The outer `Left` means the captured definition/facts are unreadable or the selected
source cannot compile. `Right report` means the validator ran, including when the
report contains semantic errors. Process failures and malformed protocol replies
remain Failure, identifying the selected validator. This operation alone does not
mint `Validated Root`: the checking function below owns that decision.
Query discovery/execution use the same captured-source boundary;
PrepareOutput remains unimplemented.

Query contracts are selected through the named declarations in ADR 0008.
DiscoverQueries inspects input/result contracts without executing the query.
ExecuteQuery resolves the root-local name in the supplied root, compares those
contracts with the descriptor, checks the arguments and compiles the generated
entry. The result is checked against its declared contract and accompanied by
the logical read trace from ADR 0009. Unknown names, changed contracts, invalid
arguments and compile rejection return diagnostics; process failure, malformed
replies and a returned value violating its contract remain operational Failure.
Examples compare the checked result, not the trace.

Effectful entry evaluation belongs to [EvolutionExecution](0010-evolutions.md),
not this snapshot-checking/query effect. It derives `After`, generates bindings,
compiles the proposed program and returns the target contract with its structurally
checked result. The application materializes that result before candidate checking.
RootExecution checks the selected snapshot; it does not invoke the evolution again.
It delegates builds of checking/query/output adapters to
[GuestCompilation](0002-runtime.md), then uses ProcessExecution for the resulting
entry. Checking a loaded candidate compiles its checking code as needed;
loading the saved value itself does not compile or execute code.
Compiler flags and toolchain paths remain in the compilation interpreter.

EvolutionExecution compiles the evolution and its captured dependency closure
before materialization. Independent target validators and queries compile during
candidate checking through CheckRootCode, including entries the evolution never
calls. Their compilation diagnostics reject checking without erasing the saved
candidate. Before contributes schema/decoding definitions, not its unrelated
validators. ADR 0010 owns the evaluation/materialization boundary.

The current root checker calls CheckRootCode before semantic/example evaluation.
It compiles the validator and every registered query entry using generated typed
adapters, including queries no example invokes, without executing those entries.
Only entries selected by this root's declarations and their imports participate;
unrelated source files, drafts and archives do not. When evolution/output/plugin
entries are implemented, their proposal-level compilation must join this gate.
This initial check returns compiler diagnostics in CheckResult.Rejected; the
distinct proposal-level outcome belongs to the later evolution integration.

The source input need only be structurally readable; semantic errors in its
validation report are information for review, not a prerequisite failure for
evaluation. This allows a typed transformation to repair an invalid head.
`ValidateRoot` reads the selected snapshot's
code/facts, never latest workspace files. None of these constructors can accept a root
or fetch live evidence. RootStore owns fact/config-file decoding, SchemaInspection
owns extracting query contracts, and binding generation is pure. Query execution
uses DhallHandling's structural value check for arguments/results against the
checked contract; it does not parse storage files itself. Runtime helper names
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

Human-authored executable examples use a concrete, data-based form. An
example names a registered snapshot query, its typed arguments and expected
typed result. Free-text review notes are different objects. The host does not
know the query's Haskell types, so it checks these values against its descriptor:

```haskell
data Example = Example
  { name        :: String
  , query       :: QueryDescriptor
  , arguments   :: CheckedValue
  , expected    :: CheckedValue
  , requirement :: ExampleRequirement
  , explanation :: Text
  }

data ExampleRequirement = Required | Illustrative

encodeExample
  :: RootStore :> es
  => Example -> Eff es (Either [Diagnostic] FileTree)
```

`Example` is ordinary data. EncodeExample checks its argument and expected-value
identities and shapes before producing files; two arbitrary `CheckedValue`s are
not sufficient. Loading checks the recorded identities before decoding either
value against the current query contract. `QueryDescriptor`, owned by
[authoring](0008-authoring.md), admits only selected-snapshot reads and pure
calculation. The example has no saved answer from a different root smuggled in
as a result of running it. Evaluation always receives the explicit target root:

```haskell
checkExample
  :: RootExecution :> es
  => Root -> Example -> Eff es ValidationReport

checkRoot
  :: (RootStore :> es, RootExecution :> es)
  => Root -> Eff es (CheckResult (Validated Root))

checkCandidate
  :: (RootStore :> es, RootExecution :> es)
  => Candidate Root
  -> Eff es (CheckResult (Candidate (Validated Root)))

loadAcceptedRoot
  :: (RootStore :> es, RootExecution :> es, Failure :> es)
  => KnowledgeBase -> GitRevision
  -> Eff es (CheckResult (Validated Root))
```

`checkRoot` is implemented as composition of RootStore and RootExecution, not a
new effect or IO interpreter. It checks code, discovers query contracts, loads
examples, runs the root validator and checks every example against that same root.
Errors reject; warnings remain attached to a returned Validated value. Runtime
Failure propagates unchanged. A root with no examples still requires code and
semantic checking. `checkCandidate` composes this checker, preserving context and
report and wrapping only the returned Validated payload. Accepted-load composition
remains unimplemented.

`checkExample` uses `ExecuteQuery`, not another effect. That operation resolves
the named query in the supplied root, checks arguments and checks the response
contract. Its raw-root input admits candidate checking, not an implicit relaxation
of ordinary query/browsing requirements. Required mismatches are errors;
illustrative mismatches remain visible warnings. Compare values using their
contract's exact structural/semantic equality, not floating-point coercion or
source spelling. The current supported wire subset has canonical scalar values,
so equality is structural Value equality: object key order is irrelevant, list
order remains significant. Only a well-formed illustrative result mismatch is a
warning; malformed example files, missing queries, incompatible contracts and
execution rejection remain errors regardless of that label. A small named query
can expose the one amount a person wants to
test; no field-selector/assertion language is required. Agents may additionally
author code-based checks in the ordinary validator.

Checking examples is allowed on structurally readable candidates before they earn
`Validated`; ordinary browsing still requires validation. Incompatible query
contracts after schema migration produce actionable diagnostics, not silent skips.
Persist the example's argument/result values and whole-contract fingerprints,
not just a query name and an untyped expected literal. Metadata records the query
name, requirement, explanation and the lowercase hexadecimal input/result
ContractIds from ADR 0005. Compare fingerprints before decoding saved values;
a mismatch asks the author to rebuild the example, never silently rebinds it.
The stored identity is enough for compatibility checking. Serializing the complete
DataType/SchemaMetadata again would only add a second representation to maintain;
Git retains the schema source for historical inspection. This is contract identity,
not a code seal or implementation pin. Do not bypass whole-contract identity
using shape-only equality. Compare the saved argument/result contract identities with the selected query's
argument/result contracts, not with the whole Root contract. A Root schema change
alone does not invalidate an assertion whose query contracts remain equal. The
comparison still uses each whole contract, including its roles; there is no separate
presentation-only compatibility rule. When a query contract changes, the author explicitly
rebuilds the example against the new descriptor, checks its values and reviews the
change. A compatible assertion is carried forward in the target copy without
re-entering it for every evolution; no automatic compatibility subsystem is needed.
`checkCandidate` compiles the candidate's checking code, runs semantic checks and
examples, and returns the same context and fixed
evolution report with its validated payload. It does not infer supporting evidence
from validator reads or rewrite the author's rationale. A passing validator does
not prove the declared explanation or evidence justified the change.
Its `Rejected` result reports checking-code compilation, semantic and example
failures, including incompatible example contracts. Editing the proposed code
requires a fresh capture and evaluation before checking the new result.
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
Test that a compile error in an unused proposed validator or query rejects candidate
checking, while broken unrelated drafts/archives do not
enter that build. Test source validation errors remaining visible during a
successful repair, with candidate failures still blocking acceptance.
