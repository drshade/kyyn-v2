---
id: 0005
title: 'One authoritative contract and mechanical projections'
status: proposed
date: 2026-09-08
---
# One authoritative contract and mechanical projections

Basis: schema authority was accepted by the owner on 5 September 2026: authored
Haskell types, following the bounded MicroHs experiment. Pure Haskell metadata
alongside the schema and reuse of existing numeric libraries are owner-selected.
Interface mechanics and production integration remain under review; this status
does not reopen those established choices.

## Context

The host needs schema discovery without knowing domain types. Agents need
matching types, not a manifest which drifts from the implementation. JSON on a
pipe does not decide which definition owns the schema.

## Decision proposed

Use one **checked contract algebra** as the internal input to structural checking,
binding/codec generation, collection routing, JSON Schema, Dhall config types and
generic presentation.
It represents the supported shapes and their declared metadata. Each projection
consumes this representation rather than independently interpreting authored
source. This is an internal typed representation, not a new authored language,
plugin interface or requirement to support multiple schema frontends.

The host needs a finite structural vocabulary, not arbitrary Haskell types hidden
inside a generic JSON value. This selected algebra makes the lowering obligation
visible (identifiers are ordinary newtypes, not business types):

```haskell
data Shape
  = Record [(FieldName, Shape)]
  | List Shape
  | Optional Shape
  | Union [(CaseName, Maybe Shape)]
  | Scalar ScalarKind
  | Reference CollectionId

data ScalarKind
  = TextScalar | BoolScalar | IntegerScalar | NaturalScalar
  | DecimalScalar | DateScalar | InstantScalar

data CheckedContract  -- supported shape + checked metadata/codec descriptors + identity

shapeOf :: CheckedContract -> Shape
metadataOf :: CheckedContract -> SchemaMetadata
contractId :: CheckedContract -> ContractId
```

`CheckedContract` carries the checked roles/affordances as well as collection and
codec descriptors. `InspectedSchema.contract` is the common source for bindings,
discovery and presentation; clients do not inspect authored metadata separately.
Use one `ContractId` for the complete checked contract, including presentation
roles and scalar codec parameters. A role-only change invalidates dependent
bindings through the normal regeneration path, even when their encoding would
be unchanged. Do not split presentation and codec compatibility identities to
avoid that work. Conservative invalidation keeps one understandable rule.

The initial pure `SchemaInspection.Contract.checkContract` combines an inspected
`DataType` with decoded `SchemaMetadata`, returning diagnostics or a checked value.
It keeps the resolved type for code generation, checks collection envelopes and
metadata references, and annotates reference fields in the checked shape. It does
not establish that referenced IDs exist in particular facts. Title accepts text
and badge accepts nullary enums (optionally wrapped); timeline assignments remain
unsupported until a date/instant scalar codec is implemented.

The initial contract identity is SHA-256 of a version-tagged JSON-array encoding
of resolved types and all metadata, including descriptions and declaration order.
It does not use derived Show output or claim behavioral/source-package identity.
Declaration reordering may conservatively invalidate it. There is no separate
presentation identity or compatibility exception.

A nullary union arm has `Nothing` for its payload shape; that is separate from a
value of an optional type. Checking rejects duplicate field/case names and invalid
collection/ID descriptors. Reference shape checking verifies an ID's representation
and declared target; existence in a particular root is a validation concern.
This internal algebra is an explicit proposal, not a claim that these constructors
are native Dhall types. Scalar conventions still need reviewed representations.

Use **Haskell-authored types as the authoritative KB schema**. The author already writes
Haskell for transformations, validators, queries and tools; the schema should
use those same authored names and types. Generate codecs, method
adapters, collection descriptors and discovery from checked declarations, rather
than generate a second authoritative set of Haskell types from another language.
Generated wrappers may import or qualify the authored modules; generated files
remain disposable. Do not duplicate or silently replace authored declarations.

Types describe structure; roles describe how the host should use selected fields.
Carry forward kyyn-v1's distinction between KB-authored roles and a small
host-understood affordance vocabulary. A title role names a fact, a timeline role
selects its relevant date/instant, and a badge role selects a closed enum for
presentation. Do not infer any of these from a field's spelling. These are field
interpretation roles, not program capability grants.

Authors attach roles through **pure Haskell data declarations alongside the
schema**, in the schema module or a nearby imported metadata module. They do not
maintain a JSON/RON sidecar as the rebuild's authoritative authoring surface.
These sketches label the semantic components. The initial shared implementation
uses positional constructors in the same order, avoiding different selector APIs
between GHC and MicroHs:

```haskell
data Affordance = Title | Timeline | Badge

data RoleDecl = RoleDecl
  { name        :: RoleName
  , description :: Text
  , affordance  :: Affordance
  }

data FieldRole = FieldRole
  { recordType :: TypeName
  , field      :: FieldName
  , role       :: RoleName
  }

data CollectionDecl = CollectionDecl
  { collection :: CollectionId
  , rootField  :: FieldName
  , references :: [(FieldName, CollectionId)]
  }

data SchemaMetadata = SchemaMetadata
  { roles       :: [RoleDecl]
  , fieldRoles  :: [FieldRole]
  , collections :: [CollectionDecl]
  }
```

For example, in a KB with `Schema.Todo` fields `title` and an optional
date field `due`, an authored export could be:

```haskell
-- Guest schema/metadata module; string literals denote SDK identifier values.
schemaMetadata :: SchemaMetadata
schemaMetadata = SchemaMetadata
  { roles =
      [ RoleDecl "task-name" "Names a task in lists and links" Title
      , RoleDecl "due-date" "Places a task on the due-date timeline" Timeline
      ]
  , fieldRoles =
      [ FieldRole "Schema.Todo" "title" "task-name"
      , FieldRole "Schema.Todo" "due" "due-date"
      ]
  , collections = [CollectionDecl "todos" "todos" []]
  }
```

This repeats field **references**, not field types. The initial references are
explicit names checked against the compiler's resolved declarations; they are
not claimed to be statically typed field handles. Arbitrary Haskell accessor
functions do not expose their meaning to the inspector. Reject missing types,
fields, roles and reference targets, incompatible affordance shapes, and ambiguous
affordance assignments. Optional scalar fields may adopt compatible roles; lists
are not scalar titles or dates. Derive badge alternatives from the checked enum,
not a manually duplicated variant schema. Neither titles nor dates redefine identity.
Collection membership and links belong in the same metadata export, but their
storage/reference semantics are distinct from presentation affordances. Propose
that a declared root collection field has type `[Fact payload]`, using the SDK's
[Fact envelope](0006-storage.md). Inspection derives the payload contract from
that checked type; identity is the envelope's `FactId`, not another selectable
payload field. Reject a collection declaration on an incompatible root field.
There is no `idField` metadata to keep consistent with a second identity model.

The demonstrated extraction route is the pinned MicroHs frontend linked into the
native GHC host. A separate bounded experiment (`kyyn-v2-experiment/haskell-schema-experiment/README.md`)
now demonstrates source-linking, checked-type extraction and generated guest
bindings on Linux, without upstream source edits. It does **not** establish a
stable library component, production packaging or the whole integration gate.
Extract from checked types, not a debug pretty-printer or a new Haskell-subset parser. Keep the
compiler coupling behind SchemaInspection, a plumbing capability; it exposes a
checked algebra and binding information, not compiler ASTs throughout the kernel.
`SchemaSource` identifies fixed source modules, captured local imports, the exported type
and the named `SchemaMetadata` export. It is not a live source path.
It refers to captured source, which may still be ill-typed; inspection establishes
that separately. Workspace creation instead takes authored contents through
[ProposedSchemaModules](0010-evolutions.md), before there is a capture to identify.

```haskell
data SchemaSource
data TypeBindings  -- checked correspondence to authored modules/types/constructors

data InspectedSchema = InspectedSchema
  { contract :: CheckedContract
  , bindings :: TypeBindings
  }

data SchemaInspection :: Effect where
  InspectSchema
    :: SchemaSource
    -> SchemaInspection m (Either [ContractDiagnostic] InspectedSchema)

inspectSchema
  :: (SchemaInspection :> es, Failure :> es)
  => SchemaSource
  -> Eff es (Either [ContractDiagnostic] InspectedSchema)

data UncheckedValue  -- private structural value from the selected parser
data CheckedValue    -- private pair of contract identity and checked contents

checkValue
  :: CheckedContract -> UncheckedValue
  -> Either [ContractDiagnostic] CheckedValue

valueContract :: CheckedValue -> ContractId
```

`inspectSchema` reports unsupported/ill-typed source as diagnostics. Runtime or
frontend infrastructure failure remains Failure. `TypeBindings` preserves the
names needed to generate codecs against real declarations; the structural algebra
alone would erase that information. It is derived by inspection, never a second
hand-maintained registry. A `CheckedValue` proves
only conformity to its recorded contract, not KB semantic validity. Whenever a
different expected contract is supplied, compare identities or perform an explicit
checked conversion; the wrapper alone does not establish that they match.

Reading the metadata export requires **pure evaluation**, not just reading type
tables. SchemaInspection checks the source and metadata export's SDK type, obtains
the value through a fixed SDK metadata entry/codec, and checks its declarations
against the extracted structure before returning `InspectedSchema`. This fixed
codec does not depend on generating bindings for the KB contract it is helping
construct. Metadata evaluation is deterministic and takes no root facts, live
evidence or host capabilities. It does not execute validators or queries.

The proposed native-library interpreter owns frontend initialization and exception
translation, and uses GuestCompilation to compile the fixed metadata adapter and
ProcessExecution to evaluate it. These dependencies are explicit; do not smuggle
evaluation into pure projection helpers or route it
through RootExecution, which already depends on schema inspection:

```haskell
runSchemaInspectionIO
  :: (GuestCompilation :> es, FileSystem :> es, ProcessExecution :> es,
      IOE :> es, Failure :> es)
  => GuestToolchain -> Eff (SchemaInspection : es) a -> Eff es a
```

The [runtime capability](0002-runtime.md) owns GuestCompilation and GuestToolchain.
Its scoped artifact helper needs FileSystem when materializing the metadata entry
for ProcessExecution; no build-directory handle is retained in the schema value.
The metadata adapter uses its fixed SDK codec; compiling it must not call
SchemaInspection again or require bindings derived from the KB contract being
inspected. Composition supplies the same toolchain selection to both interpreters.

This signature locates the implementation boundary; the separate experiment
establishes a source-linked route, not an implemented production runner or approval
to build it. Source graphs and dependencies are supplied explicitly, not discovered
through arbitrary ambient imports inside the inspector.
Under the [repository layout](0026-repository-layout.md), this native interpreter
belongs to `kyyn-microhs`, behind the plumbing API. The pure projections below
remain capability-owned helpers outside that native compiler integration package;
callers do not import compiler implementation merely to project a checked contract.

Projection functions consume the one checked representation. Their selected
signatures describe pure generation, not filesystem writes or compiler execution:

```haskell
generateBindings  :: InspectedSchema -> GeneratedSources
projectJsonSchema :: CheckedContract -> JsonSchema
projectDhallType  :: CheckedContract -> DhallType
```

Unsupported shapes fail before these functions. Generated method adapters also
use the [method descriptors](0008-authoring.md), rather than inventing another
request/result schema. `JsonSchema` is a discovery projection, never the host's
universal domain value.
`projectDhallType` produces a host-library Dhall type expression, required for
the Dhall fact/manifest files selected in ADR 0006 and ADR 0016's connector configuration.
Combine connector config types with the fixed named-instance envelope and a
generated connector-choice union. Dates/decimals use their selected codec
representations and semantic checks; do not assume native Dhall date/decimal
types. Unsupported mappings are diagnostics, not a second authored schema.

The supported data algebra is finite records, lists, optionals, tagged unions
with payloads, booleans, text and exact integer/decimal conventions. Root contracts
describe heterogeneous collections, their stable IDs and reference targets.
References are IDs, not recursive value embedding. Dates, instants and money
must use reviewed library representations and semantic checks. No per-field
byte/list bounds or universal map/type-level programming requirements.

Reuse existing Haskell/MicroHs numeric and date/time libraries rather than create
Kyyn-owned arithmetic or calendar implementations. The pinned MicroHs includes
`Data.Fixed` (`Fixed`, `Centi`, `Milli`, and other resolutions); evaluate this
existing implementation first for decimal use. Fixed versus variable precision,
arithmetic rounding behavior and cross-host/guest codec compatibility still need
review and tests. Its presence is not evidence that our inspector already supports
it. The SDK may re-export selected library types and supply adapters without
inventing their arithmetic.

If `Fixed` is selected, initially support an explicit set of standard library
resolutions; reject custom `HasResolution` instances rather than add arbitrary
instance evaluation. The pinned implementation uses integer `div` for multiplication
and division, rounding down rather than toward zero; `fromRational` also uses
`floor`. Test negative amounts as well as positive ones. A different business
rounding policy needs explicit code using the chosen library, not an assumption
that its default operations implement that policy.

Recognize supported scalar types by resolved library type identity and actual
dependency source, including relevant type parameters such as `Fixed`'s resolution.
The checked contract and generated bindings must retain that codec identity and
its parameters; the `DecimalScalar` tag alone is not a complete decimal contract.
Do not infer scalar meaning from an unqualified name or a presentation role.
The experiment's authored `Decimal { coefficient, scale }` is an ordinary record
used to exercise exact values, **not** a decimal library or the production decimal
contract. The proposed `DecimalScalar`/date/instant/natural mappings become usable
only with an actual selected library type and tested codec. An unrelated KB type
called `Decimal` remains structural data; guest representation and wire spelling
may differ only through the selected explicit codec. Business rounding policy is
still KB code, not something schema extraction infers.

Reject unsupported shapes when a contract is introduced, before it can become
accepted. Maintain one lowering from checked structure to each target, with
round-trip tests. Colocate human descriptions and examples; structural generation
does not infer business meaning. Resolve contract imports only from explicit
local dependencies captured with the source, before pure evaluation.

## Alternatives and tradeoff

Haskell schema authority is settled, not conditional on another feasibility trial.
The earlier Dhall-authoritative fallback is no longer part of the design. Do not
build automatic frontend switching, a second schema authoring language or parallel
authorities. A future obstacle requires an explicit decision review, not a silent
format fallback or permission for a substantial compiler fork.

Dhall-authored contracts were considered for their mature structural checking and
contract/import semantics. Haskell was selected for authoring coherence after the
experiment demonstrated extraction without upstream source edits. The tradeoff
is maintaining a pinned compiler adapter and its conformance tests. Collection/ID/
reference semantics still need explicit descriptors; a type declaration alone
cannot infer them. Authoring ergonomics remain something to measure, not a claimed
automatic improvement in agent error rates.
JSON Schema authority would ease some discovery but still requires selecting a
code-generatable subset. A new schema DSL means owning another language; do not
introduce one merely to avoid this choice.

Storage and runtime encoding have their own owning decisions in ADRs 0006 and
0007. Dhall storage contracts are derived projections of the Haskell authority,
not separately authored truth. No Dhall parser is required in the guest.

## Evidence and remaining implementation gates

The separate experiment (`kyyn-v2-experiment/haskell-schema-experiment/README.md`) passed native
source-linking, checked extraction across imported/aliased/applied types, payload
unions, nested collections/optionals, exact values and generated bindings against
the original declarations. It exercises runtime-loaded facts, rejects unsupported
shapes with diagnostics, and refuses an old response binding before sending a
request. Guest compilation, host inspection and guest invocation also work with
an empty PATH after the development build. These results establish the bounded
feasibility needed for the owner's schema-authority decision.

Retain those conformance tests while implementing SchemaInspection. Review the
finite supported algebra and scalar conventions, local source-capture integration,
compiler exception translation, maintained source/library packaging and upgrade
behavior. The pinned upstream package has no Cabal library component; the proof
links exported source modules, not a stable supported library API. No upstream
compiler source patches were needed, but compiler-internal coupling remains real.
The experiment's JSON descriptor sidecar remains a test fixture, not the selected
rebuild authoring form. The implementation now evaluates a named Haskell metadata
export through a fixed JSON adapter, using the shared `kyyn-types` vocabulary.
`SchemaInspection.Metadata.evaluateMetadata` consumes a complete captured adapter
input and returns decoded `SchemaMetadata`, not a `CheckedContract`. The pure
contract checker combines this result with structural inspection; the focused
integration fixture exercises both against the same authored modules. A production
captured-source SchemaInspection interpreter is still outstanding.
Coherence coverage must include missing/renamed
fields, incompatible title/timeline/badge assignments and invalid reference targets.
Test a role-only edit invalidating the complete contract and dependent bindings,
then recovering through normal regeneration; no presentation-only exception.
Compiler type errors retain their message and may have no structured location;
use retained declaration locations for inspector diagnostics where available,
as specified in ADR 0019. No error-text parser or upstream diagnostic change is
required to ship that initial policy.

Complete the disk/host/guest/browser integration with the selected production
codecs: preserve exact semantic values and canonical codec round trips, not
necessarily original numeric spelling. The experiment's Read/Show test transport
does not choose the production protocol or prove browser integration. Explicitly
reject types outside the algebra rather than attempting arbitrary Haskell
introspection. A response-schema change must reject an old binding before invoking
its consumer. Schema equality cannot establish behavioral equality; package
identity also matters. ADR 0024 tests authoring ergonomics within the selected
Haskell surface, not whether to reopen schema authority by default.
