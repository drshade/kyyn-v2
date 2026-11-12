---
id: 0023
title: 'Web is a read-only surface for showing a KB'
---

# Web is a read-only surface for showing a KB

## Context

Kyyn is a set of tools for whoever works on a KB, human or AI. Those working
together on a KB need a way to show each other the thing under discussion: a
record, a type, a query, a flow or a proposed change. Dhall facts, Haskell
source and evolution directories are a poor way to see it.

## Decision

Web is a tool for showing a KB; CLI and MCP change it. Whoever is working on
the KB starts `kyyn-v2 web serve` and opens or shares a link, for example an AI
agent showing a proposed change to the person it works with. Web has no mutation
endpoints, forms that change a KB, accept control, review notes or inbox.

Web has two kinds of page:

- **Inspection pages** are host-owned and generated. They render what Kyyn
  already knows about any KB, so nothing is authored to use them.
- **Domain views** are KB-owned HTML and JavaScript for readers of results.
  [ADR 0018](0018-surfaces.md#kb-owned-domain-views) owns their serving and
  [ADR 0008](0008-authoring.md) their declaration.

### Inspection pages

| Route | Shows |
| --- | --- |
| `GET /` | Index: evolutions, collections, types, queries, tools, recipes and a link to `/kb/` |
| `GET /evolutions/<id>` | Explanation, lifecycle state, the step report with each changed record's before and after values, and the source diff against the base |
| `GET /collections/<collection>` | The records of one collection |
| `GET /records/<collection>/<id>` | One record as labelled fields, with references to other records as links |
| `GET /types/<name>` | A schema type's fields, their types and descriptions |
| `GET /queries/<name>` | Description, input and result types, the module that implements it and, when `input` is given, the result |
| `GET /tools/<name>` | Description, input and result types, model selection and the module that implements it |
| `GET /recipes/<name>` | Instructions or flow structure, state type and saved checkpoint, without executing actions |
| `GET /recipes/<name>/types/<type>` | Types reachable from this recipe's checked state contract, with fields, descriptions and nested type links |
| `GET /connectors/<plugin>/<instance>` | Accepted connector configuration, latest local fetch/report and evidence items |
| `GET /evidence/<plugin>/<instance>/<id>` | Current local payload, fingerprint, references and blob metadata |
| `GET /connectors/<plugin>/<instance>/types/<role>/<type>` | Payload or report contract types scoped to the connector capture |

Each page is complete when opened directly from a link, and links to related
pages and to the index. The routes are stable and listed in the guide, so a link
can be composed from a name.

Every page shows the accepted KB or one draft, and states which. `?evolution=ID`
selects a draft for that page, and its links carry the parameter; without it the
page shows the accepted KB. A draft evolution page is the exception: its record
links and existence checks always use that evolution's last checked candidate,
regardless of the incoming selector. An accepted evolution's archived report
retains the selected KB context for its record links. The server's `--evolution` option applies only to
domain views under `/kb/`.

Draft facts, types, declarations and query results come from the evolution's
last successfully checked candidate, not from live target source, so the pages
of one draft agree with each other. Pages read current state on each request, so
a reload shows the latest successful check. A GET never runs a check.

The evolution page takes its step report from that candidate, or from the
archived report of an accepted evolution. The report carries each change's
before and after values, so removed records and intermediate steps are shown
there. A changed record links to its record page only when it exists in the
context shown. The source diff is that candidate's captured source against
the base. An evolution with no checked candidate shows its explanation and a
source diff of the live target, labelled as unchecked. Check diagnostics are
not stored; the command that ran the check reports them.

Connector and evidence pages show this machine's current local capture and use
accepted connector configuration; `?evolution` does not select their data. The
index labels that section separately from snapshot configuration. Reads use the
existing evidence store and never fetch. Fetch summaries and reports describe
only the latest capture. Not-fetched and changed-producer diagnostics remain
visible. Evidence references in evolution rationales link to current local items
where they resolve, not to an inferred historical payload. Blob pages show only
metadata. Inspection does not read the secret store.

Query and tool pages show the captured module that contains the implementation,
whole, not an extracted definition.

Rendering is generic. Records and types are laid out from the checked contract
and its role metadata under [ADR 0005](0005-contracts.md), not from a second
reading of authored source. A query's `input` URL parameter is a Dhall expression
checked against its input contract, as `--input` is on the CLI. Presentation
designed for a domain belongs in a domain view. A one-off explanatory page is a
view declared in a draft; its pages are served live without a check.

Pages are server-rendered HTML produced by the host from the same typed
operations CLI and MCP use. No client framework or separate JSON API is needed
for them.

### Authoring workflow

An author creates an evolution workspace, populates its `evolution` binding and
supporting files, trials and refines the result, then marks it Ready. The
evolution page and its linked pages explain the change to whoever reviews it.
Revision and acceptance are CLI or MCP operations. Ready is not proof of
validation, and acceptance still checks the local Before revision under
[ADR 0012](0012-acceptance.md).

Executable examples are KB material written under
[ADR 0011](0011-validation.md), not entered through Web.

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

Reject a Web workbench with review notes, example forms and an accept button.
It duplicates the conversation collaborators already have and the operations
CLI and MCP already provide.

The server binds to loopback and serves one KB. Inspection pages and domain views
share an origin; isolation between them is not provided.

## Verification

Test the journey from the guide: prepare an evolution that changes schema, facts
and a query, start the server and compose links from names alone.
The evolution page lists the changed records and links to record pages showing
draft values; the same record URL without `?evolution` shows the accepted value.
A removed record appears in the step report with its former value and no link.
The query page shows its module and a result for a given input. After a failed
check the pages still show the last checked candidate. No request changes the KB.
