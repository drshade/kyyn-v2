# 0018 — CLI, MCP and web share application operations

Status: Proposed. Basis: owner-established equal importance of Web and MCP.

## Context

Web and MCP serve different audiences with substantial overlap. MCP's JSON
orientation need not dictate storage or force strings inside strings. A CLI is
useful for files, development and automation, but is not a substitute for either
first-class interface.

## Decision

Make typed application operations the shared product surface. CLI parsing, MCP
requests and web events translate into these requests; renderers format returned
values. No adapter implements acceptance rules or reaches directly into Git,
provider, runtime or persistence interpreters. Compose only the handlers needed
by the selected operation, not one global kitchen-sink environment.

Transport conversion is a real boundary, not another spelling of the domain
operation. For example, an MCP adapter may accept JSON while the store never does:

```haskell
data ListEvolutionsRequest = ListEvolutionsRequest
  { knowledgeBase :: KnowledgeBaseRef
  , filter        :: EvolutionFilter
  }

decodeListRequest
  :: Aeson.Value -> Either RequestDiagnostic ListEvolutionsRequest

encodeEvolutionSummaries :: [EvolutionSummary] -> Aeson.Value
```

This is **adapter code**. After decoding and resolving the KB reference through
[RootStore](0006-storage.md), it invokes the typed `ListEvolutions` operation in
[EvolutionStore](0010-evolutions.md). The Web and CLI adapters reach that same
operation without routing through MCP. JSON does not leak into its constructor,
and the operation does not print a response or call a UI. Resolving an unopened KB
adds metadata-store work, not compilation; listing an already selected KB needs
only its workspace store and failures.

Use `optparse-applicative` for a discoverable CLI with human and stable structured
output modes, explicit KB selection, input/output file support and useful exit
codes. Keep stdout results separate from progress/errors. CLI use needs no daemon.
ADR 0025 describes agent-driven setup and per-KB Web/MCP/headless lifecycles.

MCP exports relevant named typed methods and selective discovery, using generated
JSON Schema and structured results. Expose exact source contracts as resources
or files for agent adoption too. The MCP tool specification supports input and
output schemas; do not reduce everything to one untyped command-string tool.
KB tools expose queries and operations on prepared evolution workspaces under
ADR 0008; validation is also an entry point, ordinarily invoked by Kyyn.
Output discovery/preparation and explicit sink invocation follow ADR 0017.
No separate generic KB-tool lifecycle
or proposal-submission effect is needed. Plugin acquisition methods may be exposed
directly without implying a change to accepted knowledge.
[MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

Web is designed for human understanding, high-level design, exploration and
review. MCP is designed for agent discovery, technical authoring and reliable
execution. Both expose the central loop: inspect the model, explore facts, try
examples, propose changes, compare consequences and resolve problems. An agent
can review and a human can inspect source or perform a precise technical action.
Presentation emphasis must not become a rigid actor-permission split.

The first local workbench shows selected outputs, records/model, tools/examples,
evolution comparison and source/operation status. It must support contributing
design feedback and examples, not only observing or approving an agent's work.
These are useful content, not a prescribed pane layout or generic dashboard
framework. Anchor the first UI in one reporting journey: inspect a number and
its assumption, contribute a counterexample, compare the candidate, and inspect
diagnostics. Add only the model/record navigation needed to understand that loop.
MCP exposes the same relevant state, including review feedback, without requiring
screen scraping. See ADR 0023 for the shared objects and handoff behavior.
No chat harness, full IDE or arbitrary frontend-plugin framework is a prerequisite.

Generic record browsing uses host-side checked structural values and snapshot
store operations. Titles, timelines and badges consume the checked role metadata
from `CheckedContract` under ADR 0005, not a separate reading or re-inspection of
authored source. Structural filtering/sorting does not require a fresh guest
invocation for every table interaction. Domain interpretation, policy comparisons
and business calculations are explicit named guest queries/views; do not duplicate
them in a host query language or browser code. An explicit query evaluates the
selected snapshot; no query-result cache is required. Displaying an already
prepared artifact is a separate operation, not an implicit cached query result.

Record/query browsing is independent of output sinks. Output controls select a
declared renderer/sink binding, prepare its typed input, and explicitly invoke it
when the caller wants to update an external output. Refreshing a view or inspecting
a query result never invokes a sink. Renderers may compose multiple queries; the
generated registration and preparation contract is owned by ADR 0017, not a
browser-side query graph or a separate UI renderer registry.

## Alternatives and consequences

Reject CLI-only as a workaround for an internal codec problem, and reject MCP-only
as the core application API. User confirmation/delegation belongs to explicit
operation intent/configuration, not assumptions that one transport is human and
another cannot be. Initially local single-owner use; do not imply multi-tenant web
security. Bind locally and protect the control surface from unrelated web origins.

## Verification

The same request via CLI/MCP/web produces the same domain result and transition.
Interface coverage follows user journeys, not mechanically identical buttons
and endpoints. Web and MCP are designed and tested in each end-to-end slice,
not bolted on after a CLI implementation has fixed the product's shape.
Listing evolutions does not start MicroHs or plugins. A fresh agent can discover
one relevant tool without receiving the entire installed catalog. A human can
explain a report change without reading protocol envelopes or Haskell internals.
