---
id: 0017
title: 'Outputs bind snapshot renderers to typed plugin sinks'
---

# Outputs bind snapshot renderers to typed plugin sinks

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

The guest's Root is the concrete state type. Query and renderer implementations
belong to authored code, not function-valued fields serialized into facts.
Register outputs in `kb.dhall` by naming a registered query and a configured plugin
sink. The query registration owns the authored export under
[authoring](0008-authoring.md); an output does not register a second export.
The registration contains names and descriptions, not duplicated data schemas:

```haskell
-- Host representation of an output registration in kb.dhall.
data OutputDefinition = OutputDefinition
  { name :: String
  , description :: String
  , query :: String           -- name in the same root's queries list
  , sink :: SinkReference
  }

data SinkReference = SinkReference
  { plugin :: PluginName
  , instanceName :: ConnectorName
  , method :: MethodName
  }
```

Resolve the sink from the same selected root's plugin declarations and configuration.
Inspect the renderer's checked signature to derive its argument/result contracts.
Inspect the sink's registered signature to derive its input contract, then generate
an adapter that type-checks the renderer result against that input. Reject an
unknown entry, unsupported shape, mismatched type or source connector used as a
sink; matching textual names alone does not establish compatibility.
The manifest is the registration authority; generated adapters are disposable.

Query is the read-only execution context, not a distinct renderer lifecycle.
A renderer is itself a query whose result is suitable for a sink. Queries are
also public typed read interfaces: consumers use their declared result types
rather than depending on the KB's internal fact layout. Authors can preserve that
interface while changing storage schemas; Kyyn exposes the checked contract but
does not introduce contract versioning or automatic compatibility guarantees.

The renderer is an ordinary function in the snapshot-query context. It can combine
several queries, including dependent calls:

```haskell
-- Generated for this KB; SDK.Query is owned by ADR 0009.
type Query a = SDK.Query Root a

salesSummary :: Month -> Query SalesSummary
monthlyBudget :: Month -> Query Budget
salesAnomalies :: Month -> Query [Anomaly]

renderSalesReport :: Month -> Query FileSink.Input
renderSalesReport month = do
  sales    <- salesSummary month
  budget   <- monthlyBudget month
  warnings <- salesAnomalies month
  pure (renderFile sales budget warnings)
```

Here FileSink.Input denotes the selected plugin's advertised input type, not a
kernel-wide document format. The output registration names this renderer and its
configured sink; it needs no single-query slot, per-renderer lifecycle or authored
codec. A renderer needing no reads simply returns its calculation with pure.

SnapshotRead permits no live acquisition, sink invocation or root publication.
All component queries use the same selected snapshot. The host uses checked
structural descriptors without importing the KB's domain types. Query registration
and independent query invocation remain owned by ADRs 0008 and 0011.

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
  -- Root-local name, query-argument, sink-input, sink-options and result contracts,
  -- bound sink reference. Contracts derive from the checked guest declarations.

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

### Query arguments and sink options

Query arguments determine the content. Sink options control delivery for one
invocation. They have separate plugin/KB-authored types and separate checked
values; neither is an untyped override map or a host-owned set of file flags.
The sink's configuration is accepted root data; invocation options do not mutate it.
The sink declares a typed default for omitted options. An operation without
options uses the unit type. Inspection exposes both input contracts and the
default options, so CLI/MCP consumers need not inspect plugin source.

The guest boundary has the following shape (private registration representation
is omitted):

```haskell
publish :: Config -> Options -> Input -> Program SinkCalls (Either SinkError Result)
defaultOptions :: Options
```

Config, Options, Input and Result are selected-plugin types. The generated adapter
checks the renderer result against Input; the host checks query arguments and
sink options independently before execution. Neither options nor config become
an extra argument to the renderer. Invalid options must cause no sink invocation.
ADR 0009 owns the concrete SinkCalls and FileWrite request contracts. A guest
Left (SinkRejected message) maps to RejectedByDestination; Left (SinkUncertain
message) maps to Uncertain. A Right result becomes Acknowledged only after its
result contract has been checked. Protocol loss, guest failure or invalid results
after dispatch cannot establish that no write occurred and produce Uncertain.

### Invoking the sink

Delivery is the host application capability that invokes the prepared sink input
and returns its outcome. It is not another plugin model or a KB-authored workflow.
The caller explicitly requests this operation after preparation; automation can
compose the two without an intervening human interaction.

```haskell
data Delivery :: Effect where
  InvokeSink :: PreparedOutput -> CheckedValue -> Delivery m DeliveryOutcome
    -- Second argument: separately checked sink options.

runDelivery
  :: (PluginInvocation :> es, Failure :> es)
  => Eff (Delivery : es) a -> Eff es a

data DeliveryOutcome
  = Acknowledged CheckedValue
  | FailedBeforeDispatch Diagnostic
  | RejectedByDestination Diagnostic
  | Uncertain Diagnostic
```

Delivery lowers to the existing PluginInvocation boundary. There is no mandatory
delivery ledger, dispatch-intent record or delivery ID. PluginInvocation installs the sink's own
capabilities; the sink describes effects and the native host performs them.
The first file sink is a first-party plugin using host filesystem capabilities,
not a parallel native destination API. HTTP/Git sinks use their appropriate host
capabilities through the same plugin boundary.

The `local-file` plugin supplies the file sink alongside its existing source.
Its query result is text content; the destination is separate configuration:

```haskell
data FileConfig = FileConfig { path :: FilePath }
data FilePublishOptions = FilePublishOptions { pathOverride :: Maybe FilePath }
type Input = Text
type Result = FilePath -- resolved absolute destination after successful replacement
defaultOptions = FilePublishOptions Nothing
```

The sink uses pathOverride when supplied, otherwise the configured path. It writes
UTF-8 text, creates missing parent directories, and replaces the destination using
a temporary file and atomic rename in the destination directory. No expected-old
content hash, compare-and-swap, approval token or publication proposal is required.
Repeated publications replace the file; competing writers are not coordinated.
Binary files and multi-file output are not part of this contract.
Rename replaces a destination symlink itself rather than writing through it.
The replacement takes the temporary file's permissions (normal creation mode
subject to the process umask), not the previous file's permissions.
The file plugin propagates a failed host write as SinkError; it does not turn
a failed or ambiguous write into a successful path result.

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

Publishing is one application action: select the accepted root once, prepare the
typed value and invoke its sink with checked options. Preview only prepares the
value and never invokes a sink or creates directories. It is optional, not an
approval step. Publication need not compare the selected root with a newer head
before dispatch. Returned results identify the selected root and sink; they do not
require a persistent receipt or claim exactly-once execution.
Preview identifies the configured sink and shows its checked configuration
alongside the computed input. It does not claim a resolved delivery destination:
publish-time options can override it. Publish returns the file sink's resolved
absolute path on success. No plugin-specific path computation belongs in the
generic preview handler.

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
its result cannot be established, report Uncertain rather than silently retrying or
claiming rejection. Failure or cancellation of a sink invocation cannot roll back
accepted knowledge or undo an external action. A process crash may leave no result;
inspect the destination before retrying a non-idempotent action.
No external-state reconciliation or source-version custody
system is implied.

## Verification

Prove a renderer that combines sales, budget and anomaly queries from one selected
snapshot and produces a first-party file sink's exact input type. Its component
queries must remain usable independently in Web/MCP without preparing an output.
Change head during preparation and verify every query still uses the selected
root. Include dependent query calls as well as independent calculations.

Reject a renderer/sink type mismatch and a source connector supplied as a sink
binding. Prove named-entry inspection derives the argument/result contracts and
generated adapters enforce the renderer-to-sink type match. Exercise snapshot-read capabilities without granting
the renderer sink/HTTP access. Browsing and preparation must perform no sink calls.

Preview a file output, discard the intermediate result, then update it by rendering
again and invoking the sink. With unchanged inputs the pure renderer produces the
same content; the operation must not depend on a retained preview. Also update
using changed inputs and verify the newly selected result, not enforced equality
with an old preview. Test a structured non-file sink input without a universal
artifact conversion, failed/uncertain invocation, and explicit repeatable file
replacement. Keep HTML previews isolated from the workbench's privileged origin.

Check query arguments and sink options independently; reject invalid values before
dispatch. Verify omitted options use the declared default, an override changes
only that invocation, and relative paths resolve against the KB even from another
working directory. Prove UTF-8 text output, parent creation, complete replacement,
and that preview leaves the destination untouched. No retained preview or ledger
may be required for publishing.
