# Kyyn architecture decisions

Decision set under review. Each owning ADR distinguishes owner-established choices
from proposed signatures and implementation details; this index is navigation,
not a second specification.
Development process is owned by [the SDLC](../docs/SDLC.md) and
[project practices](../docs/PROJECT-PRACTICES.md); ADR file mechanics are in
[adr/README.md](adr/README.md). Adoption does not change the imported decisions'
authority or silently resolve their proposed mechanics.
Kyyn means the rebuild; **kyyn-v1** means the legacy implementation. These are
design proposals for discussion, not permission to start a production rewrite.

Start with [architectural principles](principles.md) and [outcomes and scope](scope.md),
then [boundaries and interfaces](boundaries.md).
The [repository layout](adr/0026-repository-layout.md) records the agreed monorepo
and package ownership; ADR 0003 defines interpreter versus application-execution naming.
The [todo evolution walkthrough](walkthroughs/todo-evolution.md) makes the proposed
storage/workspace layout, saved candidate and acceptance path concrete. It is a
concrete integration fixture for the first real CLI implementation, not a claim
that the remaining technical gates have passed.
The [protocol investigation](protocol-investigation.md) separates observations
from assumptions about JSON libraries. Each ADR records a concrete recommendation,
alternatives, consequences, and evidence required before implementation relies on it.
An unresolved gate is not permission to quietly invent a fallback.

The [evidence curation walkthrough](walkthroughs/evidence-curation.md) illustrates
the proposed recipe-guided curation journey. Plugin installation, acquisition and
typed KB tools, recipe-scoped acknowledgements and pending-work discovery exist.

The ADRs are written literately: types and signatures appear where they explain
the decision, not in a detached interface appendix. Each definition has one owning
ADR; [boundaries](boundaries.md) links them and shows composition rather than a
second set of signatures. Read host and guest examples as distinct module contexts.

The notation is **architecturally meaningful, syntactically provisional**. Effect
dependencies, input/output relationships and stated ownership are proposed
contracts; changing them changes the decision. Code blocks are selected declarations,
not compilable production modules. Opaque `data T` declarations mean the representation
is omitted, not that the product should implement an uninhabited type. Ordinary
identifier/diagnostic payload definitions may be elided when they do not affect
the argument. No proof of MicroHs/library compatibility is claimed by the notation.
Each boundary states where runtime identity checks or interpreter tests are still
needed; nominal Haskell types do not prove equal Git revisions or atomic writes.

## Architecture home

This repository is the target for the Kyyn build and the maintained home of these
architecture documents. The initial import includes the experiment working tree's
ADR updates and walkthrough, including the agreed schema-module naming convention.
The storage, workspace and acceptance ADRs incorporate the follow-up mechanics
for the first local evolution journey. Their proposed revisions require design
review before implementation; the runtime codec remains an explicit technical gate.

Historical experiment and working-KB evidence is cited by repository-relative source
path for readers with those checkouts. These references are supporting context,
not required files or build dependencies in a clean checkout. No prototype
implementation was copied with these documents.

## Basis and precedence

Current owner direction is recorded in the owning ADRs. Earlier reviews and
prototypes supply evidence, not competing specifications. This set supersedes
conflicting recommendations in the earlier clean-slate note (`kyyn-v2-experiment/design-notes/clean-slate.md`)
without amending kyyn-v1's contracts or authorizing a production rewrite.

Start with the [principles](principles.md); use the index below to find the
decision to inspect or amend. Keep technical proof results in their linked
experiments and design rationale with its decision, not a parallel review diary.

## Decision index

Records retain **Proposed** implementation details, with settled owner decisions
called out separately in their status/basis. “Gate” identifies a significant
unresolved choice or proof, not a second lifecycle to administer.

| ADR | Decision | Gate / review focus |
| --- | --- | --- |
| [0001](adr/0001-product.md) | Runtime and workbench for executable knowledge | Scope and non-goals |
| [0002](adr/0002-runtime.md) | GHC kernel, bundled MicroHs programs | Representative data/runtime proof |
| [0003](adr/0003-effects.md) | Compile-visible porcelain/plumbing boundaries | Package DAG and effect vocabulary |
| [0004](adr/0004-knowledge-base.md) | Distinguish KB, root, workspace, candidate | Host versus guest types |
| [0005](adr/0005-contracts.md) | Haskell-authored schema, one checked algebra and generated bindings | Authority settled; production adapter/projection integration |
| [0006](adr/0006-storage.md) | Dhall materialized facts and runtime loading | Multi-collection layout and parsing costs |
| [0007](adr/0007-wire.md) | Library-backed, restricted JSON runtime protocol | Guest codec and transport proof |
| [0008](adr/0008-authoring.md) | Typed authoring; generated bindings hide plumbing | Real authoring example and codegen |
| [0009](adr/0009-capabilities.md) | Typed capability rows, illustrative program roles | Guest effect representation and composition |
| [0010](adr/0010-evolutions.md) | One typed evolution for data and schema | Workspace and lifecycle ergonomics |
| [0011](adr/0011-validation.md) | Full-root validity, explicit diagnostics and examples | Whole-root performance |
| [0012](adr/0012-acceptance.md) | One conditional acceptance step from local head | Expected-base equality and complete result |
| [0013](adr/0013-collaboration.md) | User/agent resolution of upstream Git conflicts | Local acceptance versus remote publication |
| [0014](adr/0014-evidence.md) | Latest evidence and recipe-scoped declared curation | Latest-only payloads, batch/individual acknowledgements and net pending work |
| [0015](adr/0015-plugins.md) | Vendored source plugins group connectors and methods | Local builds and shared-account plugin example |
| [0016](adr/0016-connections.md) | Checkout-local KB secrets; plugin-owned authentication | Local storage details and real integration flows |
| [0017](adr/0017-outputs.md) | Multi-query renderers bound to typed plugin sinks | Pure preparation, explicit external updates and honest outcomes |
| [0018](adr/0018-surfaces.md) | CLI, MCP and web share typed operations | Discovery and useful first UI |
| [0019](adr/0019-failures.md) | Structured failures, cancellation, useful operational state | Error propagation across boundaries |
| [0020](adr/0020-distribution.md) | Agent-driven installation of the bundled execution toolchain | Linux/macOS/Windows-WSL install proof |
| [0021](adr/0021-quality.md) | Architecture checks and outcome-based implementation slices | Review acceptance before code |
| [0022](adr/0022-open-source.md) | Proprietary now; future licensing kept explicit | Dependency/distribution review |
| [0023](adr/0023-interaction.md) | Equally important human and agent interfaces | Shared design/review loop and handoffs |
| [0024](adr/0024-field-experience.md) | Repeatable fresh-agent scenarios and field reports | Instrumented experience feedback loop |
| [0025](adr/0025-lifecycle.md) | Agent setup, per-KB open/close and headless operation | Complete ordinary-user and automation journeys |
| [0026](adr/0026-repository-layout.md) | Monorepo with explicit host/guest and interpreter package boundaries | Create packages as the implemented slice needs them |
| [0027](adr/0027-judgement.md) | Typed model judgements in KB tools; Jev first | Guest continuation, actual provider response semantics and local secrets |
| [0028](adr/0028-agentic-workflows.md) | Typed agentic tools and explicitly executable recipes | MicroHs portability, frozen proposal representation and model configuration |

## Remaining implementation proofs

The product decisions are not an assertion that the proposed implementation
already works. The outstanding technical work has these owners:

- [0005 — contracts](adr/0005-contracts.md): production compiler-adapter integration,
  supported scalar libraries and generated bindings.
- [0007 — wire](adr/0007-wire.md) and [0009 — capabilities](adr/0009-capabilities.md):
  generated ADT codec integration, exact scalar encoding and MicroHs-compatible
  request interpretation with the selected JSON libraries.
  Dependency selection follows [0022](adr/0022-open-source.md).
- [0006 — storage](adr/0006-storage.md), [0010 — evolutions](adr/0010-evolutions.md)
  and [0017 — outputs](adr/0017-outputs.md): representative performance and complete
  typed authoring paths.
- [0012 — acceptance](adr/0012-acceptance.md): the concrete Git publication sequence
  and its failure/race tests.
- [0020 — distribution](adr/0020-distribution.md): clean-machine installation and
  supported-platform runtime integration.

[0021](adr/0021-quality.md) orders the end-to-end proofs and
[0024](adr/0024-field-experience.md) supplies fresh-agent feedback. A failed proof
is evidence to discuss with the owner, not permission to add a hidden fallback.

## Suggested review order

1. **Meaning and boundaries:** 0001, 0003, 0004, 0009. Can we explain ownership
   and permitted calls without reading an interpreter?
2. **Authoring and transport:** 0002, 0005–0008, 0020, 0022, 0025. What does an agent
   actually write, and what work are we signing up to maintain?
3. **Change and persistence:** 0010–0013. What exactly was checked, what is
   accepted, and what happens when state changes or the process dies?
4. **Useful work:** 0014–0019, 0023 and 0025. Can Exco-like and BEE-like work be expressed
   without either provider logic in the kernel or protocol logic in the KB?
5. **Build discipline:** 0021, 0024 and the [field-experience method](field-experience/README.md).

## How these records should be used

Accept or revise the relevant decisions before implementing a boundary. An ADR
is not an additional runtime object, approval service, or receipt. Prefer editing
these proposals during discussion over creating competing “final” designs.
When implementation reveals a contradiction, use the
[intent/implementation reconciliation rule](principles.md#state-decisions-once-reconcile-intent-with-implementation).
Review actual public signatures, dependencies, behavior and tests against the
owning ADR, not duplicated explanations beside the implementation.
Do not keep unused abstraction shells
merely because the index mentions a future slice.
Apply the [principles](principles.md) when reviewing changes: remove speculative
mechanisms, not just rename them optional. The ADRs are not a backlog of every
optimisation we can imagine.
