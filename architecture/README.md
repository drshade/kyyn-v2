# Kyyn architecture

Kyyn is the rebuild; **kyyn-v1** is the legacy implementation. Start with
[principles](principles.md), [product scope](scope.md) and the
[boundary map](boundaries.md). Use [the guide](../docs/guide.md) for implemented
CLI workflows and [project practices](../docs/PROJECT-PRACTICES.md) for development.

Each ADR owns its decision and lifecycle status. The index is navigation, not an
implementation checklist. Read signatures as architectural sketches unless the
record identifies an implemented interface; production source and tests establish
what runs. Significant changes follow [the SDLC](../docs/SDLC.md).

## Decisions

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-product.md) | Runtime and workbench for executable knowledge |
| [0002](adr/0002-runtime.md) | GHC kernel, bundled MicroHs programs |
| [0003](adr/0003-effects.md) | Compile-visible porcelain/plumbing boundaries |
| [0004](adr/0004-knowledge-base.md) | Distinguish KB, root, workspace, candidate |
| [0005](adr/0005-contracts.md) | Haskell-authored schema, one checked algebra and generated bindings |
| [0006](adr/0006-storage.md) | Dhall materialized facts and runtime loading |
| [0007](adr/0007-wire.md) | Library-backed, restricted JSON runtime protocol |
| [0008](adr/0008-authoring.md) | Typed authoring; generated bindings hide plumbing |
| [0009](adr/0009-capabilities.md) | Typed capability rows, illustrative program roles |
| [0010](adr/0010-evolutions.md) | One typed evolution for data and schema |
| [0011](adr/0011-validation.md) | Full-root validity, explicit diagnostics and examples |
| [0012](adr/0012-acceptance.md) | One conditional acceptance step from local head |
| [0013](adr/0013-collaboration.md) | User/agent resolution of upstream Git conflicts |
| [0014](adr/0014-evidence.md) | Latest evidence and recipe-scoped declared curation |
| [0015](adr/0015-plugins.md) | Vendored source plugins group connectors and methods |
| [0016](adr/0016-connections.md) | Checkout-local KB secrets; plugin-owned authentication |
| [0017](adr/0017-outputs.md) | Multi-query renderers bound to typed plugin sinks |
| [0018](adr/0018-surfaces.md) | CLI, MCP and web share typed operations |
| [0019](adr/0019-failures.md) | Structured failures, cancellation, useful operational state |
| [0020](adr/0020-distribution.md) | Agent-driven installation of the bundled execution toolchain |
| [0021](adr/0021-quality.md) | Architecture checks and outcome-based implementation slices |
| [0022](adr/0022-open-source.md) | Proprietary now; future licensing kept explicit |
| [0023](adr/0023-interaction.md) | Equally important human and agent interfaces |
| [0024](adr/0024-field-experience.md) | Repeatable fresh-agent scenarios and field reports |
| [0025](adr/0025-lifecycle.md) | Agent setup, per-KB open/close and headless operation |
| [0026](adr/0026-repository-layout.md) | Monorepo with explicit host/guest and interpreter package boundaries |
| [0027](adr/0027-judgement.md) | Typed model judgements in KB tools; Jev first |
| [0028](adr/0028-agentic-workflows.md) | Typed agentic tools and fact-edit recipes |

## Reading and changing decisions

The ADRs interleave prose and type signatures to explain ownership and permitted
operations. Host and guest examples are distinct contexts; sketches may omit
representations and routine error fields. They are not files to copy verbatim.

Start with 0001/0003/0004 for the model, 0005–0009 for authoring and execution,
0010–0013 for change/acceptance, and 0014–0018 for integrations and surfaces.
The [repository layout](adr/0026-repository-layout.md) assigns package ownership;
[field-experience templates](field-experience/README.md) support usability review.

Reconcile a changed decision with implementation using the
[principles](principles.md#state-decisions-once-reconcile-intent-with-implementation).
Amend the owning ADR, not a second explanation elsewhere. Unresolved work belongs
in issues, not a duplicated list of supposedly outstanding proofs here.
[ADR conventions](adr/README.md) define file mechanics.

Supporting references to neighbouring repositories are optional historical
context, not build dependencies. Git history retains retired investigations and
reviews; current guidance does not depend on them.
