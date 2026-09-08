# 0017 — Outputs bind snapshot renderers to typed plugin sinks

Status: Accepted. Output implementation remains outstanding. Renderers compose
queries over one selected root and produce the input of a configured plugin sink.
Preparation and external mutation are separate operations.

## Context

Browsing the KB and updating an external output are different activities. A report
may combine several calculations; it should not duplicate business rules in a
browser or require a workflow language just to compose ordinary functions.

## Decision

An output binds a KB-authored renderer to a configured
[sink connector](0015-plugins.md). The renderer produces the sink's input type.
It can call several queries, including queries whose arguments depend on earlier
results, and reuse ordinary calculation helpers. All read the same selected root,
including its code and configuration, not whichever head happens to be latest.

Record/query browsing does not involve a sink. Opening, refreshing or filtering
a view never implicitly updates an external output. Evolutions change the KB;
invoking a sink changes something outside it and does not itself require an
evolution. Changing an output's definition or its root-owned sink configuration
is a KB code/configuration change and follows the ordinary evolution route.

### Root data and authored declarations

The guest's Root remains the concrete state type. Queries and output declarations
belong to the KB's code, not function-valued fields serialized into its facts.
Use one registered query/renderer form, returning the snapshot-read Program from
ADR 0009. This is a pure description interpreted against the selected snapshot;
ordinary business calculations need not themselves acquire an effect parameter.
The type relationships are:

```haskell
-- Generated for this KB; the SDK representation is owned by ADR 0009.
type Query a = SDK.Query Root a

data SinkBinding input
  -- Generated typed reference to a plugin, configured sink instance and operation.

data Output root args where
  Output
    :: (args -> SDK.Query root input)
    -> SinkBinding input
    -> Output root args
```

The renderer is just the first function argument to Output, not another component
requiring independent registration or a lifecycle. There is no single query slot
on Output: query composition belongs inside the function.

```haskell
salesSummary :: Month -> Query SalesSummary
monthlyBudget :: Month -> Query Budget
salesAnomalies :: Month -> Query [Anomaly]

renderSalesReport :: Month -> Query FileSink.Input
renderSalesReport month = do
  sales    <- salesSummary month
  budget   <- monthlyBudget month
  warnings <- salesAnomalies month
  pure (renderFile sales budget warnings)

salesReportFile :: SinkBinding FileSink.Input

monthlySalesReport :: Output Root Month
monthlySalesReport =
  Output renderSalesReport salesReportFile
```

These are guest-side sketches, not implemented SDK declarations. FileSink.Input
is the file plugin's actual advertised input type, not a kernel-wide document
format. The generated SinkBinding cannot be constructed by casting an arbitrary
source connector or a sink expecting another type. Configuration selects the
destination; it comes from the named instance in the selected root.

Queries obtain typed collections/facts through generated bindings and can pass
the resulting values to ordinary pure calculations. A renderer that needs no query requests can likewise
return its result with pure. There is one Output constructor, not separate pure
and effectful renderer variants. SnapshotRead permits no live source acquisition,
sink invocation or accepted-root publication. Its interpreter supplies reads from
the selected snapshot, so this signature does not weaken repeatable preparation.

A KB can declare several differently typed queries and outputs:

```haskell
data SomeQuery root where
  SomeQuery :: (args -> SDK.Query root result) -> SomeQuery root

data SomeOutput root where
  SomeOutput :: Output root args -> SomeOutput root

data KbDefinition root = KbDefinition
  { queries :: [SomeQuery root]
  , outputs :: [SomeOutput root]
  }
```

These selected declaration fields do not replace the host's KnowledgeBase/Root
types or the existing validation/schema exports. Generated registration supplies
names, descriptions, contracts and codecs from the checked declarations. Hiding
types existentially does not itself make values serializable or discoverable.
That adapter work must be proved; authors do not write protocol wrappers or repeat
structural schemas. Both query results and sink inputs use the supported contract
subset. The host need not import a KB's domain types to inspect or invoke them.

### Preparing an output

Queries remain independently callable through the application operation:

```haskell
queryRoot
  :: (RootExecution :> es, Failure :> es)
  => Validated Root -> QueryDescriptor -> CheckedValue -> Eff es QueryResult
```

RootExecution checks the selected query's argument/result contracts as described
in ADRs 0008 and 0011. Web can display its structured values without invoking a
renderer or sink and without reimplementing authoritative calculations in JS.

QueryResult includes the checked result and ordered read trace from ADR 0009.
Queries should eventually be visible alongside schemas, facts and evolutions,
with SQL-like explanations where reads/filters are expressed as data; arbitrary
Haskell following a read remains opaque to that display. A sufficiently expressive
request language might also allow some queries to execute entirely host-side;
queries expressible in both interpreters must then agree exactly. These are future
directions, not a predicate language, static read declaration, or extra check to
implement now.

For outputs, the host has a generated structural counterpart of the declaration:

```haskell
data OutputDescriptor
  -- Root-local output name, argument and sink-input contracts, bound sink reference.

data PreparedOutput
  -- Checked renderer result and selected sink binding for an invocation.

prepareOutput
  :: (RootExecution :> es, Failure :> es)
  => Validated Root -> OutputDescriptor -> CheckedValue -> Eff es PreparedOutput
```

Preparation evaluates the renderer through the generated adapter and checks its
result against the selected sink's input contract. It resolves the binding from
the same root's plugin declarations and configuration; a same-named connector in
some other root is not interchangeable. RootExecution owns this selected-snapshot
computation, with no PluginInvocation dependency merely to render. Query calls
inside a renderer do not each resolve a fresh head.

PreparedOutput is an ordinary intermediate value, not a product lifecycle,
approval object or retained preview identity. Preparation is pure computation over
the selected inputs; the application may compute it again when updating an output,
or reuse a result if useful. There is no requirement to persist or hold the same
value between Web requests, and no prepared-output registry. The generated adapter
carries the matching input contract and sink binding, not an untyped guest payload.

Preview and update need not share an evaluation. An update selects its root and
arguments and computes or reuses the corresponding result; all query calls within
that evaluation still use the same selected snapshot. If inputs changed since a
preview, the output can change too. Show the snapshot used where relevant, without
promising that publication reproduces an earlier preview's exact bytes or adding
an approval/revalidation handshake between them.

The host can inspect the checked input structurally. File-like content may also
have a suitable preview. Do not assume every sink input is HTML or bytes, or that
an arbitrary typed sink request automatically has a custom visual editor.

Large file/document payloads may use existing immutable artifact references:

```haskell
data Artifact  -- immutable bytes + media type

loadArtifact
  :: (ArtifactStore :> es, Failure :> es)
  => ArtifactId -> Eff es (Maybe Artifact)
```

ArtifactStore holds/loads bytes when needed; it is not a compulsory conversion of
every sink input into a generic document. References in a prepared input must
resolve the fixed bytes or fail, not read whatever is now at a mutable filename.
Unknown IDs return Nothing; missing/corrupt bytes for a known artifact are failure.
No new universal Destination type sits alongside the configured sink binding.

### Invoking the sink

Delivery is the host application capability that invokes the prepared sink input
and retains its outcome. It is not another plugin model or a KB-authored workflow.
The caller explicitly requests this operation after preparation; automation can
compose the two without an intervening human interaction.

```haskell
data Delivery :: Effect where
  InvokeSink :: PreparedOutput -> Delivery m DeliveryOutcome
  InspectDelivery :: DeliveryId -> Delivery m (Maybe DeliveryRecord)

runDelivery
  :: (PluginInvocation :> es, FileSystem :> es, Failure :> es)
  => Eff (Delivery : es) a -> Eff es a

data DeliveryOutcome
  = Acknowledged DeliveryId DeliveryAcknowledgment
  | FailedBeforeDispatch DeliveryId Diagnostic
  | RejectedByDestination DeliveryId Diagnostic
  | Uncertain DeliveryId Diagnostic
```

Delivery lowers to the existing PluginInvocation boundary and filesystem plumbing
for its local dispatch/outcome records. PluginInvocation installs the sink's own
capabilities; the sink describes effects and the native host performs them.
The first file sink is a first-party plugin using host filesystem capabilities,
not a parallel native destination API. HTTP/Git sinks use their appropriate host
capabilities through the same plugin boundary.

For the file sink, path text is plugin input/configuration, not native IO or a
host-imported plugin configuration type. The plugin issues a filesystem write
request with the selected path and bytes. The command composition root supplies
that KB checkout's directory as the base; the host filesystem request adapter
resolves the path and lowers the write through ADR 0003's FileSystem capability.
Relative paths are relative to the KB directory, never process working directory
or a temporary guest build folder. Absolute paths are honoured as explicit
destinations. FileSystem does not learn about reports or plugin config schemas.
This resolves ownership, not a sandbox restricting destinations to the KB.

InvokeSink is the external-effect boundary: it consumes the renderer result and
its selected binding. The application may render afresh before calling it; the
separation from RootExecution is ownership, not a ban on recomputation between
preview and update. Neither rendering nor sink invocation accepts facts.
Verify the selected sink/method and checked input
contract before dispatch and validate its returned result through the plugin's
advertised result contract. Unexpected exceptions/protocol loss are not success.

DeliveryRecord identifies the sink operation that was attempted, its dispatch
state and outcome for later inspection; it does not require retaining a preview
or its prepared value. Persist dispatch intent before an external action
can occur. InspectDelivery returns recorded data, never invokes a sink or rerenders;
Nothing means an unknown ID, not a successful invocation. These are concrete
external-write outcomes, not a new generic operation registry or approval receipt.

Use an accepted snapshot for normal output updates. Explicit candidate export
for discussion may use a validated candidate, clearly identified as such rather
than presented as accepted publication. This is not a requirement to prove that
someone inspected a preview. Inspection, preparation and invocation remain
separate; neither opening Web nor evaluating an evolution dispatches an output.

### Failure behavior

Distinguish idempotent replacement, such as a file output, from non-idempotent
actions such as sending a message. Plugin-specific behavior belongs to the sink;
do not infer idempotency from its name. Use provider support where available,
without implementing exactly-once distributed coordination.

A known pre-dispatch failure is not Uncertain. If dispatch may have occurred but
its result was not recorded, report Uncertain rather than silently retrying or
claiming rejection. Failure or cancellation of a sink invocation cannot roll back
accepted knowledge or undo an external action. Inspect the recorded outcome and
repair as appropriate. No external-state reconciliation or source-version custody
system is implied.

## Verification

Prove a renderer that combines sales, budget and anomaly queries from one selected
snapshot and produces a first-party file sink's exact input type. Its component
queries must remain usable independently in Web/MCP without preparing an output.
Change head during preparation and verify every query still uses the selected
root. Include dependent query calls as well as independent calculations.

Reject a renderer/sink type mismatch and a source connector supplied as a sink
binding. Prove generated registration retains the codecs/contracts hidden by
existential declarations. Exercise snapshot-read capabilities without granting
the renderer sink/HTTP access. Browsing and preparation must perform no sink calls.

Preview a file output, discard the intermediate result, then update it by rendering
again and invoking the sink. With unchanged inputs the pure renderer produces the
same content; the operation must not depend on a retained preview. Also update
using changed inputs and verify the newly selected result, not enforced equality
with an old preview. Test a structured non-file sink input without a universal
artifact conversion, failed/uncertain invocation, and explicit repeatable file
replacement. Keep HTML previews isolated from the workbench's privileged origin.
