# Outcomes that determine the architecture

This is product scope, not a claim that every surface is implemented. The
[current guide](../docs/guide.md) describes usable CLI workflows; ADRs own the
architecture and issues own implementation work.

## Two representative systems, not two built-in verticals

**Exco:** distinguish realised revenue, scheduled billing and forecast pipeline;
preserve budget grain; calculate weighted totals with exact arithmetic; reconcile
related views; surface unresolved anomalies; refresh inputs and preview/publish
dashboards. Shared business calculations should live in ordinary KB modules,
not be independently reimplemented in each renderer.

**BEE:** group observer copies into one meeting occurrence; distinguish invitations
from attendance, and attendance from learning time; represent teaching segments,
trainer identity, evidence basis and uncertainty independently; update people and
sessions together; apply alternative reporting policies without recuration.

These requirements came from the owner's Exco sales-reporting and BEE
skills-development KBs. They motivate shared calculations, useful evidence access
and coherent changes, not domain logic hardcoded in the kernel. Anomalies and
curation records are legitimate KB models, not mandatory kernel lifecycles.

## Required journeys and architectural coverage

| Journey | Observable result | Decisions |
| --- | --- | --- |
| Establish a model with an agent | Human understands types, examples, assumptions and an initial view | 0001, 0005, 0008, 0018 |
| Install an external integration | First-/third-party code runs using the Kyyn distribution | 0002, 0015, 0016, 0020 |
| Ask an agent to install and open Kyyn | Readiness checked; human reaches their KB in a browser without toolchain knowledge | 0020, 0025 |
| Connect the agent to a selected KB | Tested per-KB MCP invocation and discoverable typed methods | 0018, 0025 |
| Examine source evidence | Typed discovery, useful source references | 0007–0009, 0014 |
| Curate a coherent change | Related records change together; unresolved cases remain visible | 0004, 0010, 0011, 0019 |
| Evolve the model | Before/after types, records, checks and tools change together | 0005, 0010–0012 |
| Inspect before adopting | Actual data and report differences against a precise base | 0011, 0012, 0017, 0018 |
| Accept and reopen | Complete validated result survives, including deletions | 0006, 0012 |
| Collaborate through Git | Local base mismatch leads to an in-place evolution rebase; upstream conflicts use ordinary Git | 0010, 0012, 0013 |
| Repeat settled work | Reuse domain functions; do not compile facts or re-explain protocols | 0006, 0008, 0014 |
| Update an external output | Render from a selected snapshot and invoke its sink; uncertainty is not reported as success | 0017, 0019 |
| Repair an integration update | Refresh its contract, fix callers and refetch evidence | 0005, 0014, 0015 |
| Run outside the developer's machine | No implicit compiler or credential dependency | 0020–0022 |
| Stop, reopen and automate settled work | Drafts survive; CLI can check/accept/render without Web or MCP servers | 0012, 0019, 0025 |
| Hand design/review work between human and agent | Shared snapshot, feedback and candidate identity across Web/MCP | 0018, 0023 |

## Synthetic acceptance fixtures

Keep these public and fabricated; do not copy business records, identities,
credentials, private endpoints or reports from the working repositories.

**Training:** two people, a dedicated session, a teaching segment inside an
ordinary meeting, duplicate observer copies split across a page boundary, and
unknown attendance. A tool proposes related person/session changes in one
workspace. A schema evolution adds vendor delivery. Two views interpret the
same facts differently without refetching them. Warnings and source limitations
stay visible. A correction and deletion survive acceptance and reopen.

**Reporting:** two business units, three months, realised/scheduled/forecast
values, a budget at a different grain, exact decimals, one missing value and one
reconciliation discrepancy. A shared calculation serves both a tool and a view.
Changing its weighting policy changes the candidate report; the accepted report
is unchanged until acceptance. Missing is not silently zero and decimal values
survive the host/guest/browser boundaries exactly.

Use these shapes to assess complete workflows, including add/edit/delete, schema
change, shared calculations and uncertainty. They are not a prescribed implementation
sequence. Guest capability tests should use synthetic providers.

Include a fresh-agent exercise: discover a named tool, inspect its contract,
change a rule, inspect a candidate, and explain the remaining uncertainty. Record
calls spent learning Kyyn mechanics separately from actual domain work. Passing
unit tests alone does not establish a good authoring or human-review surface.

Web and MCP have equal importance. Exercise the loop in both directions: a human
changes an expectation and an agent implements it; an agent finds an ambiguity
and the human explores examples before deciding. Their shared middle includes
inspection, experimentation, diagnosis, proposals and review. Technical depth
and high-level design are emphases, not exclusive permissions or personas.

Installation targets Linux, macOS and Windows (WSL acceptable initially). Agents
can bootstrap dependencies and configure a tested client invocation on behalf of
regular users; a graphical installer is not a prerequisite. Test the actual
Windows-host/WSL browser and MCP journey. Repeatable workflows can be driven by
an external runner with explicit acceptance intent, no interactive UI or daemon.

## Deliberate exclusions

No kyyn-v1 compatibility layer; universal workflow graph; mandatory causal ledger;
per-record governance ceremony; hosted identity/account service; autonomous scheduler; generic RAG platform; durable continuation store; automatic semantic
merge; historical connector-schema negotiation; arbitrary native-program plugin
ABI; or standalone execution requirement for KBs.

Domain complexity is not excluded. Exact arithmetic, heterogeneous roots,
relationships, payload unions, warnings, uncertainty and partial evidence are
required now. Transport simplicity must not erase these distinctions.
