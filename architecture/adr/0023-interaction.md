---
id: 0023
title: 'Agents drive Kyyn; Web shows their work to people'
---

# Agents drive Kyyn; Web shows their work to people

## Context

A person works on a KB by talking to their agent. The agent authors, checks and
accepts through CLI and MCP. What the person lacks is a way to see what the agent
is describing: a record, a type, a query, a flow or a proposed change. Reading
Dhall facts, Haskell source and evolution directories is the agent's job.

## Decision

The agent is the only driver of Kyyn. Web is a read-only surface the agent uses
to show something to a person: the agent starts `kyyn-v2 web serve` and sends a
link. The person responds in their conversation with the agent, and the agent
acts through CLI or MCP. Web has no mutation endpoints, forms that change a KB,
accept control, review notes or inbox.

Web has two kinds of page:

- **Inspection pages** are host-owned and generated. They render what Kyyn
  already knows about any KB, so an agent authors nothing to use them.
- **Domain views** are KB-owned HTML and JavaScript for readers of results.
  [ADR 0018](0018-surfaces.md#kb-owned-domain-views) owns their serving and
  [ADR 0008](0008-authoring.md) their declaration.

### Inspection pages

| Route | Shows |
| --- | --- |
| `GET /` | Index: evolutions, collections, types, queries, tools, recipes and a link to `/kb/` |
| `GET /evolutions/<id>` | Explanation, lifecycle state, check result and diagnostics, the step report with changed records linked to their record pages, and the source diff against the base |
| `GET /collections/<collection>` | The records of one collection |
| `GET /records/<collection>/<id>` | One record as labelled fields, with references to other records as links |
| `GET /types/<name>` | A schema type's fields, their types and descriptions |
| `GET /queries/<name>` | Description, input and result types, implementation source and, when `input` is given, the result |
| `GET /tools/<name>` | Description, input and result types, model selection and implementation source |
| `GET /recipes/<name>` | Instructions or flow structure and typed state, without executing actions |

Each page stands alone: a person arrives from a link, not through navigation.
The routes are stable and listed in the guide so an agent can compose a link
from a name it already has.

Every page shows the accepted KB or one draft. `?evolution=ID` selects a draft
for that page, and its links carry the parameter. Without it, the page uses the
server's selection (`--evolution ID`, otherwise accepted). Every page states
which it shows. Draft facts, types and query results come from the evolution's
last successfully checked candidate, as draft queries do under ADR 0018; an
evolution that has never checked still shows its explanation, diagnostics and
source diff. Pages read current state on each request, so a reload shows the
agent's latest edit or check.

Rendering is generic. Records and types are laid out from the checked contract
and its role metadata under [ADR 0005](0005-contracts.md), not from a second
reading of authored source. A query's `input` URL parameter is a Dhall expression
checked against its input contract, as `--input` is on the CLI. Presentation
designed for a domain belongs in a domain view. An agent that wants a one-off
explanatory page writes one under a draft's `target/views/`, which is served
live without a check.

Pages are server-rendered HTML produced by the host from the same typed
operations CLI and MCP use. No client framework or separate JSON API is needed
for them.

### Authoring workflow

An agent creates an evolution workspace, populates its `evolution` binding and
supporting files, trials and refines the result, then marks it Ready. It shows
the person the evolution page and whatever else explains the change. The person
asks for revisions or approves in conversation; the agent revises or accepts.
Ready is not proof of validation, and acceptance still checks the local Before
revision under [ADR 0012](0012-acceptance.md).

Executable examples are KB material the agent writes under
[ADR 0011](0011-validation.md). A person's counterexample reaches the KB through
the agent.

### Record history

Record history is a read operation on the existing EvolutionStore, not a new
provenance service or a guest query that executes archived code:

```haskell
recordHistory
  :: (EvolutionStore :> es, Failure :> es)
  => KnowledgeBase -> GitRevision -> CollectionId -> FactId
  -> Eff es [RecordHistoryEntry]

data RecordHistoryEntry = RecordHistoryEntry
  { revision  :: GitRevision
  , evolution :: Maybe EvolutionId
  , step      :: Maybe Natural
  , change    :: HistoricalChange
  , rationale :: Maybe Rationale
  }

data HistoricalChange
  = RecordedChange FactChange
  | UnannotatedChange GitDiff

data GitDiff  -- available repository diff, not a claim of typed historical decoding
```

The revision fixes the history being inspected. Return matching accepted steps
newest-first, with reverse step order within a commit; preserve Git parent links
when presenting merges, rather than inventing a linear causal chain across them.
The initial implementation reads Git and archived reports directly. For ordinary
Git edits without a report, expose the available diff with absent rationale; if
record correspondence cannot be established, state the gap instead of pretending
the history is complete. Stable record IDs support lookup, but ID changes and
splits/merges do not gain inferred lineage. A missing evidence cache entry leaves
the explanation/reference visible and its content explicitly unavailable.

`Maybe Rationale` distinguishes absent provenance from an authored explanation
whose evidence list is empty. Source-only changes remain available in workspace
and Git review; a per-record timeline does not claim to explain every change in
the algorithms that interpret that record.

## Boundaries and alternatives

Reject a human-driven workbench with review notes, example forms and an accept
button. It duplicates the conversation the person already has with their agent
and adds a second writer to every evolution.

The server binds to loopback and serves one KB. Inspection pages and domain views
share an origin; isolation between them is not provided.

## Verification

Test the journey from the guide: an agent prepares an evolution that changes
schema, facts and a query, starts the server and composes links from names alone.
The evolution page lists the changed records and links to record pages showing
draft values; the same record URL without `?evolution` shows the accepted value.
The query page shows its source and a result for a given input. A failing check
shows diagnostics on the evolution page. No request changes the KB.
