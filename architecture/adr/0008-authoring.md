---
id: 0008
title: 'Domain authors write typed functions, not adapters'
status: accepted
date: 2026-09-11
---
# Domain authors write typed functions, not adapters

Basis: typed authoring is accepted; the KB-tool entry-point addition is under
design review. Full authoring surfaces remain under implementation.

## Context

A cleaner wire is insufficient if every helper imports a parser, constructs
request envelopes, repeats schema declarations and writes an IO entry point.
The training-session helper should talk about sessions and people.

## Decision

The authored surface consists of ordinary MicroHs schema/code modules, generated
bindings, pure functions, and explicit host-capability operations. Under the
selected Haskell schema authority in ADR 0005, bindings refer to authored
domain types; generated declarations are only genuinely derived adapters or
projections, never a replacement authoritative set of domain types.
Kyyn generates entry adapters, codecs, transport calls and typed registration
wrappers. No authored `main :: IO ()`, manual JSON/Dhall decoding, response IDs,
paths to runtime artifacts or printer callbacks for ordinary KB tools.

Group the installed author API by concept, with seven public SDK modules:

- `Kyyn.Schema`: identified facts and schema metadata/roles.
- `Kyyn.Validation`: diagnostics, locations, severities and validation reports.
- `Kyyn.Query`: the abstract Query and CollectionBinding types plus collection/fact reads.
- `Kyyn.Evolution`: evolution composition, the guest KnowledgeBase/recipe vocabulary,
  rationale and evidence, reexporting editing vocabulary.
- `Kyyn.Edit` and `Kyyn.Optics`: focused editing and optics sub-vocabularies.
- `Kyyn.Plugin`: abstract Program and evidence-snapshot handles, evidence changes and typed acquisition failures.

These are facades over the existing definitions, not new nominal types. Keep the
shared `Kyyn.Types.*` wire profile available to host/runtime code but outside the
author catalogue. Execution adapters, Program interpretation, CheckResult and
checkReport, query read instructions/local handlers, CollectionBinding's constructor,
EvolutionOutput and evaluateEvolution are implementation APIs, not facade exports.
Existing internal modules and the shared profile remain their home; do not add
duplicate wrapper types merely to hide them from discovery.

Schema sources import Kyyn.Schema, validators import Kyyn.Validation, and queries
import Kyyn.Query. Authors import Kyyn.Schema separately when constructing facts.
Generated Kyyn.Workspace.Evolution reexports only Kyyn.Evolution alongside its own
workspace-specific combinators, not a mixed collection of schema/runtime modules.
The installed catalogue derives its module inventory only from kyyn-sdk's public
facade list; shared-profile package exports are not a second author inventory.

Plugin adapters generate `KyynPluginBindings` for the selected entry. An acquisition
entry receives an `Acquisition a` alias and filesystem/evidence helpers; a captured
reader receives `CapturedRead a` and evidence helpers only. Both reexport the
acquisition vocabulary: `Program`, `EvidenceSnapshot`, `FetchError`, `EvidenceId`,
`Evidence` and `EvidenceChange`. Registration declarations (`SourceConnector` and
its record fields) stay with the plugin entry module's direct `Kyyn.Plugin` import;
they do not enter acquisition modules through generated bindings.
Authors use ordinary `do` notation and explicit typed snapshot
arguments; the generated helpers inject requests into the selected capability sum
without exposing codecs or request envelopes. The concrete algebras belong to
[ADR 0009](0009-capabilities.md).

KB-authored code has these entry-point kinds:

| Entry point | Result and boundary |
| --- | --- |
| Query | Answer or view over the selected snapshot, without proposing a change |
| Evolution | Produce a candidate through the [pure transformation contract](0010-evolutions.md#pure-evolution-execution), never implicitly accept it |
| Validation | Pure checks of supplied root/config values, returning diagnostics |
| KB tool | Compose captured-evidence reads and [model judgements](0027-judgement.md), without evidence acquisition, sink calls or root mutation |

A report is a query result. Agent-facing operations expose queries, KB tools,
plugin methods and evolution workspaces. A KB tool is an authored function, not a
second proposal-authoring workflow. Plugin methods remain integration operations;
acquisition need not propose knowledge. ADR 0010 defines evolution composition.
An output declaration binds an ordinary renderer function to a typed plugin sink,
as defined in [outputs](0017-outputs.md). Renderer execution is selected-snapshot
computation, like a query, not an effectful KB tool. It can compose
multiple queries. Generated output adapters prepare values; a separate host
operation invokes the sink. Queries remain independently discoverable/callable.
Each evolution workspace has a single `evolution` binding; reusable helper
selection and arguments are expressed in that source, such as
`evolution = importSales September`. Evaluating a workspace does not require a
separate named-entry/arguments manifest. Query and plugin method arguments remain
ordinary typed request data; this convention concerns evolution authoring.

Authors also export the pure `SchemaMetadata` value defined in
[ADR 0005](0005-contracts.md), alongside their schema. It attaches KB-defined
roles to actual fields and declares collection identities/reference targets.
The host uses those roles for titles, timelines and badges without knowing the
domain model. This is checked interpretation metadata, not a second copy of field
types. The initial name-based field references are validated against extracted
declarations; moving them into Haskell does not by itself make them typed lenses.
Kyyn generates the metadata entry/transport; authors supply no IO entry point.

Registration binds one name and description to an implementation with a checked
request/result contract and declared capability requirements. Fixed plugin functions
(description, health, configuration checks) coexist with explicitly registered domain methods. “Dynamic”
means discovered from the installed program rather than compiled into the
kernel; it need not mean mutable registrations during an invocation.
Related connector methods and account-setup declarations live in one authored
plugin package under ADR 0015. Authors do not split authentication, mail and
meetings into separately distributed plugins merely because their effects differ.
They distribute source; Kyyn's installed toolchain generates and builds the adapters.
Connector methods are advertised under a plugin-defined connector type. Generated
caller bindings select a named instance under that plugin; the host verifies its
type and supplies that instance's typed configuration, as specified in ADR 0015.
Two configured instances of the same type share code, not configuration or identity.

In the **guest authoring API**, a generated method handle fixes its input, output
and request algebra. Registration cannot attach an unrelated function to it:

```haskell
data Method requests input output  -- generated handle; constructor private

registerMethod
  :: Method requests input output
  -> (input -> Program requests output)
  -> RegisteredMethod requests
```

`RegisteredMethod` hides the individual input/output types only after this check.
The selected `Program` representation is explained in
[capabilities](0009-capabilities.md). Generated handles contain the matching
adapter/codec information; they are not unchecked user-authored phantom casts.
Pure calculations can be lifted into a method without acquiring host capabilities.

The **host** cannot use those native Haskell input/output types. Discovery carries
a structural counterpart, generated from the same contract authority:

```haskell
data MethodDescriptor = MethodDescriptor
  { identity       :: MethodIdentity
  , inputContract  :: CheckedContract
  , outputContract :: CheckedContract
  , capabilities   :: [CapabilityId]
  }

data QueryDescriptor = QueryDescriptor
  { name           :: QueryName
  , inputContract  :: CheckedContract
  , outputContract :: CheckedContract
  }
```

`MethodIdentity` locates an entry in a particular code/package context, not just
a globally meaningful string. `QueryDescriptor` is instead a **root-local name
and contract** description, with construction restricted to snapshot queries.
It permits only pure computation/selected-snapshot reads. Its input and output
contracts serve [human-authored examples](0011-validation.md) as well as invocation.
Resolve that name in the explicitly selected root's code on execution and compare
contracts/capabilities. Persisted examples can therefore test a revised calculation
with unchanged types. They do not pin an old implementation, contain a future
commit hash, or silently authorize a same-named incompatible function.

For example, the reporting KB—not the kernel—might define this reusable query:

```haskell
-- Guest reporting module; all three types belong to this KB/its SDK.
monthlySummary :: ReportingPolicy -> Query MonthlySummary
```

The generated query adapter interprets its typed reads against the explicitly
selected Root, using the representation owned by ADRs 0009 and 0017. The externally
visible argument is `ReportingPolicy`, and the host sees its checked contract,
not an import of that Haskell declaration. This is why guest static typing and
host structural checking are complementary, not interchangeable representations.

The initial query registration is a `queries` list in `kb.dhall`. Each declaration
supplies `name`, `description`, `implementation`, `inputType`, `inputMetadata`,
`resultType`, and `resultMetadata`. The latter five are qualified Haskell export
names, not repeated structural type definitions. Input/result metadata are explicit
named exports of SchemaMetadata, checked against their respective types; the
kernel does not copy the root's collection declarations into arbitrary query
contracts. An empty metadata value can be shared where appropriate. Type aliases
can give scalar/list/optional contracts an exported name.

The generated `KyynQueryBindings` module exports the KB-specific `Query a` alias
and a typed binding for each collection, named after its Haskell root field while
retaining its declared collection identity. Schema modules must not depend on
this derived module: Kyyn first inspects the schema, then generates bindings for
query modules. Source collisions with generated adapter modules are diagnostics,
not silent overwrites. Discovery inspects contracts without executing queries;
the generated entry type-checks the chosen implementation at invocation.

RootExecution takes structurally checked Root values so it can evaluate candidate
examples. ADR 0011's checkRoot now produces Validated Root after code, semantic and
example checks; query execution alone cannot mint that wrapper. The eventual
CLI/Web/MCP browsing operations use that validated boundary, not the raw checking
operation directly. Those surface wrappers are not implemented yet.

KB helpers call generated bindings for registered plugin methods. Provider interpretation belongs inside the
plugin or its generated provider client, not in the KB. Generated plugin proxies expose concrete input/output types
while routing calls through the host and the plugin's own capability context.

### Composed KB investigation tools

The initial registry is a `tools` list alongside `queries` in `kb.dhall`:

```dhall
tools =
  [ { name = "bulkContent"
    , description = "Read captured documents"
    , implementation = "Helpers.bulkContent"
    , inputType = "Helpers.DocumentIds"
    , resultType = "Helpers.Contents"
    }
  ]
```

Types and implementations are qualified Haskell exports, not inline structural
schemas. Tool names reuse the connector-binding identifier rule and must be
unique among tools; queries have a separate namespace. A KB without tools declares
`tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }`.
Whole-root checking compiles registered tools without invoking them. Discovery
uses the same checked declarations; invocation accepts typed arguments and returns
the inspected result type. No second registration file or historical manifest
decoder is needed.

For the initial captured-read implementation, an authored helper can be:

```haskell
import Kyyn.Plugin (FetchError)
import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import qualified Kyyn.Plugins.P_local_file.Folder as Files

type DocumentIds = [String]
type Contents = [String]

bulkContent :: DocumentIds -> Tool (Either FetchError Contents)
bulkContent ids = sequence <$> mapM (Files.content Connectors.documents) ids
```

Generated bindings import the plugin's real contract-bearing Haskell modules.
They do not generate structurally identical replacement data types. The caller
source closure includes every installed plugin's `src/` tree; conflicting module
paths are reported, not silently renamed. Plugin implementation adapters are
generated in their own execution context, not imported by the caller. A plugin's
contract-bearing type modules must not import its generated acquisition bindings:
those bindings exist only when compiling the plugin entry, not its callers.

For investigation, a KB author can compose plugin methods as ordinary functions:

```haskell
import qualified Kyyn.Connectors as Connectors
import qualified Microsoft.Mail as Mail
import qualified Microsoft.Calendar as Calendar

emailWithAttachments mailbox emailId = do
  email <- Mail.viewEmail mailbox emailId
  attachments <- Mail.getAttachments mailbox emailId
  pure (EmailWithAttachments email attachments)

getActivity day = do
  emails <- Mail.emailsOn Connectors.salesMail day
  meetings <- Calendar.meetingsOn Connectors.teamCalendar day
  pure (Activity emails meetings)
```

These are illustrative authored modules and result types, not installed SDK exports.
[ADR 0016](0016-connections.md) owns generated instance values; [ADR 0014](0014-evidence.md)
owns selection of their captured evidence. The same composition can cross plugin
packages. Register `getActivity` as a KB tool to expose its checked input/result
contracts and documentation to agents; unregistered helpers remain ordinary private
functions. The initial manifest registry generates a typed entry signature with
the capabilities in ADR 0009, not another registry of structural
schemas or an author-written MCP wrapper. Discovery checks exports and contracts
without invoking the tool. A KB tool is not a snapshot `Query`: adding this entry
point must not give queries, validators or renderers access to plugin calls.

Plugin calls from these tools read captured evidence only. Fresh acquisition is a separate
explicit operation, and external writes use the sink path in ADR 0017. The agent
can investigate, then write literal fact edits with rationale in an evolution;
that evolution follows [ADR 0010](0010-evolutions.md#pure-evolution-execution).
[ADR 0027](0027-judgement.md) defines model-assisted investigation through the
same tool entry point.

### Recipe-guided authoring

[ADR 0014](0014-evidence.md) owns recipes, their agent instructions and declared
curation progress. A recipe is not another executable registry entry alongside
queries and tools. An agent uses those existing entries to investigate, then
prepares an evolution following the selected recipe. Generated SDK helpers expose
the acknowledgement vocabulary without requiring register or fingerprint plumbing
in authored code. Recipe discovery does not launch an agent or prescribe its steps.

### Shared authoring vocabulary

Pure calculations are reusable from validation, queries and views. Provide a
small SDK for identified facts, diagnostics, selected existing exact-value library
types/adapters and evolution composition. Do not create a Kyyn arithmetic library
in place of evaluating existing Haskell/MicroHs implementations. Use standard
optics if compatible; do not expand the custom optics
implementation as a substitute for evaluating dependencies. Keep `After` imports
qualified in evolution scaffolds and generate record field optics mechanically.

## Alternatives and consequences

Reject hand-maintained registries that duplicate structural schema, blanket Generic/Template-Haskell
derivation assumptions, and a single stringly `invoke` API as the author surface.
Some generated code is a deliberate maintenance cost, but the author edits one
contract plus its implementation, not an encoder and a schema in parallel.
Diagnostics should identify authored sources rather than generated boilerplate.
Keep source positions when supplied by the compiler/inspector; when only compiler
message text exists, display it with no structured location under ADR 0019. Do not
invent a span or parse compiler prose merely to make it clickable.

## Verification

First prove the reporting tool and schema-changing evolution in ADR 0021, including
scaffolded Before/After modules and generated bindings, several host requests and no codec/transport
imports in authored code. Then implement the synthetic training tool. Its
request includes structured people and sessions, not `record_json`/`record_dhall`
strings. Break a result type and see a compile error. Change an imported plugin
contract and see a binding error. The kernel must remain unchanged in both cases.
