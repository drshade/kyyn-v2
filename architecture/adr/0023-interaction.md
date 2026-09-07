# 0023 — Two first-class interfaces with a shared design and review loop

Status: Proposed. Basis: explicit owner feedback on equal Web/MCP importance.

## Context

A web dashboard that only approves completed agent work is not a design tool.
An MCP interface that only edits records is not a capable collaborator's interface.
Conversely, presenting every internal technical object to humans is not parity.

## Decision

Design Web for humans and MCP for agents as equally important product surfaces.
Humans will generally work at the level of meaning, design, examples, results
and review; agents will generally do more technical construction, code/schema
editing and repeatable execution. Both can work across those levels.

The initial evolution-authoring workflow is explicit: an agent creates a workspace,
populates its single `evolution` binding and supporting files, trials and refines
the result, then marks it Ready for review. The human inspects its changes,
outputs, checks and rationale, requests revisions as needed, and may accept the
checked result as the new head. Ready is not proof of validation, and acceptance
still checks the local Before revision. These are workflow expectations, not
role-based permissions restricting who may use the underlying operations.

Equal importance means access to shared review objects and operations, not a
graphical equivalent of every source-authoring operation. Web need not create an
evolution by selecting a reusable Haskell helper and filling in its arguments.
There is no helper-launch catalog, argument-to-source generator or separate
invocation model required for this flow. Query/example forms remain useful typed
data interfaces; they do not imply graphical evolution-source authoring.

A request for new work before any evolution exists goes to the user's agent,
not a new Kyyn task/inbox object. Once work exists, Kyyn-native examples and review
notes support human design feedback without orchestrating the agent that responds.
External schedulers can use the same agent-and-ordinary-operations workflow for
settled work; agent-less preparation conveniences are not an initial requirement.

| Shared activity | Human-oriented Web | Agent-oriented MCP |
| --- | --- | --- |
| Understand the system | Model browser, examples, assumptions, connected views | Exact contracts, documentation, source/binding locations |
| Explore knowledge | Tables, filtering, drill-down, alternate policies | Typed queries, stable paging, reusable calculation tools |
| Design a change | Describe intent, adjust examples, inspect alternatives | Scaffold/edit workspace, implement functions, execute examples |
| Review consequences | Data/schema/rule/report comparison; focused diagnostics | Structured diffs, failed examples, affected identities and comments |
| Explain a record | Timeline of changes, reasons and cited evidence | Revision-scoped record history with step diffs and declared rationale |
| Operate and repair | Progress, source status, missing-secret setup guidance | Typed errors, resumable input references, explicit repeatable operations |

Share concrete objects, not a mandatory conversation platform: selected KB/root,
evolution workspace, evaluated candidate, example, diagnostic, artifact and review
feedback. Feedback can target a fact/field, source location, example or artifact,
and is tied to the candidate version the reviewer saw. Store workspace review
notes through EvolutionStore, not an independent approval/ticket subsystem.
Notes can request changes without being automatically executable instructions.

Separate free-text feedback from the executable data examples defined in
[validation](0011-validation.md). The latter name a query and contain typed
arguments/expected results; Web can build a form from those contracts without
asking the human to write a Haskell expression. A note saying "this looks too high"
does not automatically become a check, whereas a saved expectation for a named
monthly-total query does. This data-example representation is a design proposal,
not an assertion-language requirement or an owner-decided UI layout.

The selected operations belong to EvolutionStore even though they serve Web/MCP:

```haskell
data ReviewSubject
  = CapturedWork EvolutionContext
  | EvaluatedResult (Candidate Root)

data ReviewTarget
  = WholeSubject
  | FactTarget CollectionId FactId
  | ExampleTarget ExampleId
  | SourceTarget RelativePath SourceSpan
  | ArtifactTarget ArtifactId

addReviewNote
  :: (EvolutionStore :> es, Failure :> es)
  => ReviewSubject -> ReviewTarget -> Text -> Eff es ReviewNoteId

saveExample
  :: (EvolutionStore :> es, Failure :> es)
  => EvolutionWorkspace -> Example -> Eff es ExampleId
```

A note references fixed captured work or the actual evaluated root, not simply
the workspace name that will later contain different code. `CapturedWork` supports
source/whole-proposal feedback even if the proposed schema or Haskell never compiled
and no candidate root exists. `EvaluatedResult` retains exact result identity for
data/artifact feedback and failed semantic checks as well as successful checks.
Targets must be meaningful within their subject; capture alone does not invent
an evaluated fact or artifact. The workspace supplies its owning KB for saving
examples, avoiding a second KB argument.
Saving an example writes `target/examples/` under the proposed ADR 0010 layout,
marks the workspace Draft and requires recapturing, evaluation and checking;
it cannot retroactively validate an earlier preview. It becomes current-root
material on acceptance, following [the example lifecycle](0011-validation.md),
rather than remaining an archive-only attachment. The store returns
identifiers/data, not a printed success or an implicit request to run an agent.

Review presents four related dimensions: fact/schema differences, selected
view-output differences, source changes in KB modules, and changed or removed
checks/examples. These are not four mandatory screens. A policy-only evolution
may have no fact changes but substantial report differences; passing a weakened
check does not establish that the previous intended rule still holds.

Alongside the overall diff, show the ordered step report defined in
[evolutions](0010-evolutions.md). Each step pairs actual changed records with its
declared explanation and evidence. Preserve intermediate changes even when the
net diff is empty. These authored rationales are distinct from reviewer notes;
neither observed reads nor a review comment silently becomes supporting evidence.

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

Both surfaces identify the base and evaluated result a preview depicts. Editing
or rebasing the evolution requires fresh checks and diffs; the old preview is not
evidence about the revised result. Review is an aid to judgment, not a sealed
authorization transaction. No cross-client editing coordinator is required.
Acceptance is an explicit operation on a checked evolution, conditional on its
`Before.revision` still matching local head, regardless of the client. Actor names and
method-role metadata describe work; they do not establish a universal authority
hierarchy. Delegation is an explicit owner choice, not inferred from transport.

## Boundaries and alternatives

Transport adapters handle presentation, navigation and client interaction. Shared
application operations own mutations/checking and return structured results.
Avoid both extreme UI symmetry and asymmetric capabilities that force an agent
to scrape a screen or a human to use a terminal for ordinary design feedback.
MCP and Web do not call each other to reach the engine.

A Web update notification or refresh mechanism may project operation/workspace
state; it is not a new canonical state store. Initial local single-owner use can
support multiple clients with revision checks without implementing collaborative
text editing, chat orchestration or presence protocols.

## Verification

Test a complete handoff: human supplies a counterexample in Web; agent sees it
through MCP, changes an evolution and checks it; human compares the resulting
report and requests a revision; agent fixes it; either explicitly authorized
client accepts the checked evolution against its current local base. Also test an agent reviewing a
human-authored change. Neither path should depend on private chat history,
screen scraping or an assumption that “human means approver, agent means writer”.
