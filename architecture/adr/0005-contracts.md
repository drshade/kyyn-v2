---
id: 0005
title: 'One authoritative contract and mechanical projections'
---
# One authoritative contract and mechanical projections

## Context

The host needs schema discovery without knowing domain types. Agents need
matching types, not a manifest which drifts from the implementation. JSON on a
pipe does not decide which definition owns the schema.

## Decision

Use one **checked contract algebra** as the internal input to structural checking,
binding/codec generation, collection routing, JSON Schema, Dhall config types and
generic presentation.
Generic presentation here means host-generated inspection-page presentation, not a
required vocabulary for KB-owned HTML/JavaScript views. The `views` manifest list
is source/navigation metadata under [ADR 0008](0008-authoring.md#domain-view-authoring);
it creates no view contract, typed parameters or query-dependency declarations.
Named-query arguments and results still use this checked algebra when a view
invokes them through [ADR 0018](0018-surfaces.md#kb-owned-domain-views).

It represents the supported shapes and their declared metadata. Each projection
consumes this representation rather than independently interpreting authored
source. This is the host-checked description vocabulary, not a new authored language
or a requirement to implement multiple compiler backends.

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
  | BlobReference

data ScalarKind
  = TextScalar | BoolScalar | IntegerScalar | NaturalScalar
  | DecimalScalar | DateScalar | InstantScalar | ProbabilityScalar

data CheckedContract  -- supported shape + checked metadata/codec descriptors + identity

newtype RootContract = RootContract CheckedContract -- constructor private

checkRootLayout :: CheckedContract -> Either [Diagnostic] RootContract
rootSchema :: RootContract -> CheckedContract

contractShape :: CheckedContract -> Shape
metadataOf :: CheckedContract -> SchemaMetadata
contractId :: CheckedContract -> ContractId
```

`BlobReference` retains the resolved SDK BlobRef identity through structural
lowering. Its storage record and surface projection are owned by
[ADR 0029](0029-evidence-blobs-sync.md#captured-bytes-have-typed-references);
it is not inferred from an authored record's field names.

`CheckedContract` carries the checked roles/affordances as well as collection and
codec descriptors. `InspectedSchema.contract` is the common source for bindings,
discovery and presentation; clients do not inspect authored metadata separately.
Use one `ContractId` for the complete checked contract, including presentation
roles and scalar codec parameters. A role-only change invalidates dependent
bindings through the normal regeneration path, even when their encoding would
be unchanged. Do not split presentation and codec compatibility identities to
avoid that work. Conservative invalidation keeps one understandable rule.

The pure `Kyyn.Domain.Contract.checkContract` combines an inspected
`DataType` with decoded `SchemaMetadata`, returning diagnostics or a checked value.
It accepts every supported shape in the algebra, not only records:
query arguments and results may be scalars, lists, optionals or unions. Roles
can still refer to reachable record types within those values. Declared collection
metadata is checked, but a query value containing a list of facts need not declare
that list as a persistent collection.

Persistent roots additionally pass `checkRootLayout`: a single record
constructor, with every direct `[Fact a]` field declared as a collection.
The zero-field case is included: its fields are vacuously both all named and all
positional, and the convention chooses the record projection. `data Root = Root`
and `data Root = Root {}` therefore have the same empty-record shape
(`{}` in JSON, `{=}` in Dhall).
The unit value `()` uses this same empty-record projection for stateless recipe
state and no-argument requests. It retains its own nominal type identity; sharing
the representation with an authored empty record does not equate their contracts.
Unit is a value contract, not an authored persistent root. This does not extend
support to multi-element tuples.
This gives initialization an empty root without dummy fields or collections.
The rule applies to all values, not only initialization; multi-constructor
nullary enums remain tagged unions. Generated guest codecs use the same projection.
Adding a second constructor to a single-nullary-constructor type changes its
encoding from an empty record to a tagged union: it requires a schema migration,
not merely adding a compatible case.
`RootContract` refines the existing checked value without computing another
identity or duplicating its schema. `rootSchema` returns that same checked value;
the identity encoding is unchanged. RootOpening refines inspected contracts, and
Root/RootStore require the refined type. This structural distinction does not
confer semantic validation or introduce a second query-contract representation.

The general checker keeps the resolved type for code generation, checks collection envelopes and
metadata references, and annotates reference fields in the checked shape. It does
not establish that referenced IDs exist in particular facts. Title accepts text, Badge accepts nullary enums, and Timeline requires a recognized
date/instant scalar codec (each optionally wrapped). A role never makes an otherwise
unsupported scalar representable; reject unsupported mappings explicitly.
The checker reports the first incoherence. A role may name a single
reachable instantiation of a polymorphic record, but multiple distinct reachable
instantiations of that name are ambiguous and are rejected.

The contract identity is SHA-256 of a JSON-array encoding
of resolved types and all metadata, including descriptions and declaration order.
It does not use derived Show output or claim behavioral/source-package identity.
The host computes it from the checked structure and metadata for in-process
value/contract agreement. Stored values decode against the current type.

A nullary union arm has `Nothing` for its payload shape; that is separate from a
value of an optional type. Checking rejects duplicate field/case names and invalid
collection/ID descriptors. Reference shape checking verifies an ID's representation
and declared target; existence in a particular root is a validation concern.
These constructors are Kyyn's checked algebra, not native Dhall types. Scalar
mappings must carry a reviewed representation and codec, as specified below.

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
The shared declarations use positional constructors:

```haskell
data Affordance = Title | Timeline | Badge

data RoleDecl = RoleDecl Text Text Affordance
-- Role name, description, affordance.

data FieldRole = FieldRole Text Text Text
-- Qualified record type, field, role name.

data CollectionDecl = CollectionDecl Text Text [(Text, Text)]
-- Collection name, root field, reference-field/target-collection pairs.

data SchemaMetadata = SchemaMetadata [RoleDecl] [FieldRole] [CollectionDecl]
```

For example, a KB declares a title and an enum badge alongside its schema:

```haskell
schemaMetadata :: SchemaMetadata
schemaMetadata = SchemaMetadata
  [ RoleDecl "task-name" "Names a task in lists and links" Title
  , RoleDecl "task-status" "Displays a task's status" Badge
  ]
  [ FieldRole "Schema.Todo" "title" "task-name"
  , FieldRole "Schema.Todo" "status" "task-status"
  ]
  [CollectionDecl "todos" "todos" []]
```

This repeats field **references**, not field types. The initial references are
explicit names checked against the compiler's resolved declarations; they are
not claimed to be statically typed field handles. Arbitrary Haskell accessor
functions do not expose their meaning to the inspector. Reject missing types,
fields, roles and reference targets, incompatible affordance shapes, and ambiguous
affordance assignments. A record has at most one Title assignment and one
Timeline assignment. It may have multiple Badge assignments with distinct role
names, such as status and priority. Each role is assigned at most once per record;
duplicate assignments, including assigning the same role to two fields, are
ambiguous and rejected. Optional scalar fields may adopt compatible roles; lists
are not scalar titles or dates. Derive badge alternatives from the checked enum,
not a manually duplicated variant schema. Neither titles nor dates redefine identity.
Collection membership and links belong in the same metadata export, but their
storage/reference semantics are distinct from presentation affordances. A declared
root collection field has type `[Fact payload]`, using the SDK's
[Fact envelope](0006-storage.md). Inspection derives the payload contract from
that checked type; identity is the envelope's `FactId`, not another selectable
payload field. Reject a collection declaration on an incompatible root field.
There is no `idField` metadata to keep consistent with a second identity model.

### Build-derived guest description

The GHC guest SDK derives contracts in the module defining the authored type,
using ordinary `deriving (Generic, Contract)`. The single `Contract` class is
upstream haskell-agentic's structural description, extended with an extensible
scalar vocabulary. Kyyn supplies scalar definitions for FactId, exact decimals
and blob references. Kyyn interpreters derive the checked description and value
codecs, including distinct storage and model projections, from that same contract.
This requires an upstream haskell-agentic change (ADR 0028), not a second Kyyn
contract class or a second derivation on each model-facing type. Authors do not import generated `Kyyn.Contracts.*` modules
or maintain another structural schema. Applied types and containers can use
compositional instances; supported contract shapes, not a monomorphic-only rule,
determine eligibility. Aliases do not introduce a distinct instance identity.

The host has no linked guest compiler frontend. Compiler-specific guest build
tooling checks manifest exports and entry signatures. Entry adapters are private
build outputs, never imports required by authored code: they are generated after
the selected authored exports type-check, then compiled into the same executable
and Nix derivation. Description and invocation use that executable's contracts.
A full build does not publish a description if a registered implementation fails
its signature check.

Root-specific collection handles and edit bindings retain a narrow schema-only
prepass. It derives `KyynQueryBindings`, workspace Target handles and
FactEdits before compiling their consumers, in the same derivation and under the
same dependencies. The Root schema must not import its own generated bindings;
there is no general restriction separating type definitions from flows or other
consumers. Root handles carry collection identity and typed update/edit operations;
`HasField` alone supplies field reads, not that complete interface. This prepass
is not used to generate Contract instances. The build helper owns compiler API
integration and must support the chosen GHC; arbitrary libraries do not imply
every compiler version works with every SDK.

Pure schema metadata is evaluated with the fixed SDK metadata codec, independent
of the KB contract being derived. It takes no facts, evidence, host capabilities
or live inputs, and does not execute queries or validators. Derived description,
codecs and method adapters share one checked lowering and selected dependencies.

```haskell
data SchemaSource -- source/export selection within one captured guest build

data InspectedSchema = InspectedSchema
  { contract :: CheckedContract
  , loadedSources :: [RelativePath]
  }

data SchemaInspection :: Effect where
  InspectSchema
    :: SchemaSource
    -> SchemaInspection m (Either [Diagnostic] InspectedSchema)

inspectSchema
  :: SchemaInspection :> es
  => SchemaSource -> Eff es (Either [Diagnostic] InspectedSchema)

data CheckedValue -- private constructor: checked contract identity and structural value
```

The interpreter builds the selected source through GuestCompilation, describes
that exact CompiledProgram through GuestInspection (ADR 0002), and checks the
returned structural descriptors with `checkContract` and, for roots,
`checkRootLayout`. The host recomputes contract identities; a guest-supplied hash
alone is not a CheckedContract. Protocol/schema mismatch is a diagnostic before
invocation, not a request to negotiate an older contract.

The description retains resolved declaration names and local source dependencies.
`loadedSources` identifies captured files needed by a schema, excluding external
locked packages and metadata-only dependencies. It identifies dependencies within the selected target/helper build; it never
requires copying old application source into a migration. It is neither a second
lock nor a hand-authored registry.
Compiler implementation objects do not cross the protocol.

Description is build-derived and may be cached by immutable build identity. Do
not commit a parallel description file requiring authors to synchronize it with
source. Reading stored values checks their shape against the selected description;
fact files do not persist an independent authoritative contract identity.
Evolution preparation reads a structurally checked stored snapshot without an old
Haskell contract. Authored migration-local types are strict decoding views of
selected documents; they are not assertions about historical nominal identity.
The complete prepared data then decodes under the target contracts and undergoes
normal validation (ADR 0010), including untouched facts and recipe state. Ordinary
decode, type and validation errors apply to lock changes too. No historical
application build, stored-description registry or extra roundtrip gate is required.
A CheckedValue proves structural conformity, not semantic validation of the KB.
Its constructor remains private to checking code.

Schema-only/API discovery builds select the requested source closures without
compiling an unfinished evolution body. Failure to build the selected schema
returns diagnostics, never an older catalogue. Description parsing cannot invoke
RootExecution or depend on runtime facts, avoiding a build/inspection cycle.

The SDK build owns Haskell binding/codec generation. The host owns projections
for storage, validation and surfaces. These remain separate implementations of
mechanical projections from the shared contract vocabulary, checked by conformance
tests; they do not duplicate authored business types.

Host projection functions consume the one checked representation. Their selected
signatures describe pure projection, not filesystem writes or compiler execution:

```haskell
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

Reuse maintained Haskell numeric and date/time implementations rather
than create Kyyn-owned arithmetic or calendar types. A scalar adapter must select
the library type, parameters, canonical encoding and semantic checks together.
Its conformance tests cover the host and built guest, exact round trips, range limits and
negative as well as positive amounts. Business rounding policy remains authored
KB code, not something schema extraction infers.

Recognize scalar types by resolved library identity and captured dependency source,
including type parameters such as fixed-point resolution. Retain that identity
and its parameters in the checked contract and generated bindings; a
`DecimalScalar` tag alone is not a complete decimal contract. Do not infer scalar
meaning from an unqualified name or presentation role. An unrelated KB type called
`Decimal` is ordinary structural data, not a built-in numeric codec.

Recognize upstream `Agentic.Questions.Probability` as `ProbabilityScalar`, without
inspecting its private constructor or generating a replacement Contract instance.
Authored code retains that type and fractional literals such as `0.85`. Its exact
storage representation is basis points: Dhall `Natural` in `0..10000`, and a
canonical integer string on the guest value wire (`"8500"`). Reject out-of-range
stored/wire inputs before calling upstream's clamping constructor. Nested fields,
collections, optional values and union payloads use this same leaf codec.

Model contracts instead use upstream's `Contract Probability` schema and numeric
codec (`0.85`), including upstream rounding/clamping semantics. This projection
does not make arbitrary numeric JSON valid for Integer fields, nor broaden the
guest wire profile. Contract identity distinguishes Probability from an ordinary
integer. Model and persistence encodings are projections of the same semantic type.

Reject unsupported shapes when a contract is introduced, before it can become
accepted. Maintain one lowering from checked structure to each target, with
round-trip tests. Colocate human descriptions and examples; structural generation
does not infer business meaning. Resolve contract imports only from explicit
local dependencies captured with the source, before pure evaluation.

## Alternatives and tradeoff

Haskell schema authority is settled, not conditional on another feasibility trial.
Do not build automatic frontend switching, a second schema authoring language or parallel
authorities. A future obstacle requires an explicit decision review, not a silent
format fallback or permission for a substantial compiler fork.

Dhall-authored contracts were considered for their mature structural checking and
contract/import semantics. Haskell was selected for authoring coherence after the
compiler adapter demonstrated checked-type extraction. The tradeoff
is maintaining guest build-time compiler integration and its conformance tests. Collection/ID/
reference semantics still need explicit descriptors; a type declaration alone
cannot infer them. Authoring ergonomics remain something to measure, not a claimed
automatic improvement in agent error rates.
JSON Schema authority would ease some discovery but still requires selecting a
code-generatable subset. A new schema DSL means owning another language; do not
introduce one merely to avoid this choice.

Storage and runtime encoding have their own owning decisions in ADRs 0006 and
0007. Dhall storage contracts are derived projections of the Haskell authority,
not separately authored truth. No Dhall parser is required in the guest.

## Verification

Exercise checked extraction across imported, aliased and applied types, payload
unions, nested collections and optionals, runtime-loaded facts and generated
bindings against the original declarations. Reject unsupported shapes with
diagnostics. Test guest compilation, host inspection and guest invocation without
a development toolchain on PATH after installation.

Compiler-internal coupling remains in guest build tooling: keep source capture,
checked extraction and packaging under conformance tests when updating GHC or the SDK.
Metadata evaluation consumes the captured source and returns `SchemaMetadata`;
the pure contract checker combines that value with structural inspection. Test
this through materialization, reopening and the generated GHC guest codec.

Coherence coverage includes missing or renamed fields, incompatible affordances,
ambiguous role assignments and invalid reference targets. A role-only edit must
invalidate the complete contract and dependent bindings, then recover through
normal regeneration. Compiler type errors retain their messages and may lack a
structured location; use retained declaration locations when available (ADR 0019).

Disk/host/guest/presentation round trips preserve exact semantic values and
canonical codec encodings, not original numeric spelling. A response-schema
change rejects an old binding before invoking its consumer. Schema equality does
not establish behavioral equality or source-package identity. ADR 0024 measures
authoring ergonomics against these contracts.
