---
id: 0030
title: 'Interactive agentic workflows'
---

# Interactive agentic workflows

## Context

A sales portfolio flow starts opportunity reviews. Each review queries Salesforce,
asks an owner for clarification, waits for a Teams reply and proposes a KB update.
Captured evidence is optional in this path. A live response need not be published
into the evidence store before the workflow can use it.

Open/closed describes who directs the work; interactive describes its lifetime.
An open recipe guides an external agent. A closed recipe supplies an authored
Agentic flow. Either may be interactive. The recipe declaration explicitly selects
interactive execution; ordinary recipe invocations retain the single-invocation
contract in [ADR 0028](0028-agentic-workflows.md). Interactive closed entries have checked request and result types;
the existing recipe declaration is their registration point, not a second registry.
Their effect context additionally supplies the capabilities below. Pure queries,
renderers, evolution functions and ordinary investigation tools do not gain them.

## Decision

### Interactive flows have a durable lifetime

The library owns flow interpretation, model/tool orchestration, durable operation
identity and generic suspension/resumption semantics. Kyyn owns persistent
instances, their checked inputs and bindings, event routing, execution attempts
and links to evolution workspaces. The accepted interactive declaration advertises
its action bindings and allowed child-flow references. Description exposes the
transitive set of child definitions and their actions before start, traversing
recursive references once. Starting the instance authorises that captured set,
including unattended child execution, subject to the caller's existing authority.
Child references bind definitions/configuration from this captured execution
revision; new revisions or dynamically named undeclared children require a new
explicit start. A model cannot grant itself additional bindings.
The host is an executor of authored decisions,
not an additional model deciding goals, reminders or escalation policy.

```haskell
-- Typed guest flow combinators; lower-level request rows remain generated.
type InteractiveFlow input output = Agentic InteractiveProgram input output

data FlowRef input output
newtype FlowHandle output = FlowHandle FlowInstanceId

data FlowStatus output = FlowStatus
  { execution :: ExecutionStatus output
  , outstandingWaits :: [WaitId]
  }

data ExecutionStatus output
  = Runnable | Running | Waiting | Finished (FlowOutcome output)

data FlowOutcome output = Completed output | Failed [Diagnostic] | Cancelled

data CancelScope = ThisFlow | FlowAndDescendants

startFlow :: FlowRef input output -> InteractiveFlow input (FlowHandle output)
inspectFlow :: InteractiveFlow (FlowHandle output) (FlowStatus output)
awaitFlow :: InteractiveFlow (FlowHandle output) (FlowOutcome output)
cancelFlow :: CancelScope -> InteractiveFlow (FlowHandle output) ()
```

`InteractiveProgram` is the generated guest effect program with the selected
interactive capability row and typed failures, not arbitrary IO.
`FlowRef` resolves an accepted declaration with its checked input/result contracts.
Starting a flow records its original input, execution revision and selected
configuration. Each instance has a stable ID, optional parent ID, execution owner (hosted or
external), checked request/result contracts and status.
Runtime state lives locally under `.kyyn/flows/`, outside accepted
facts and recipe state. Operations validate handles against the selected KB and
stored contracts. Inspection is read-only; `awaitFlow` returns a terminal outcome
or durably waits. Failure is observable data, not automatic sibling cancellation.
Outstanding waits are visible independently of execution status: an instance can
be Running with earlier unanswered waits. Waiting means an attempt returned a
waiting frontier and there is no currently scheduled execution. Fulfilling any
one wait makes it Runnable; the authored composition still determines whether
other replies are needed before a join can progress. Runtime storage/dispatch
failures retain ADR 0019's operational failure boundary.

### Parents author how they manage children

A start made by a hosted flow records that instance as parent. Parentage is
immutable provenance and navigation, not a requirement to join children before
returning. The parent may await all, some or none; normal completion leaves its
children running. A daily scanner can finish after launching opportunity reviews,
and a campaign can await those same reviews to assemble its summary. Failure of
a parent does not silently cancel children either.

Replay of the same child-start occurrence returns the same child handle. Starting
another child on replay is a correctness bug. Preventing a new daily scan from
starting another review of the same opportunity is separate authored business
policy: the scanner inspects active reviews before choosing to start one.

`ThisFlow` stops only the selected instance. `FlowAndDescendants` requests
cancellation throughout its subtree, including active descendants of terminal
parents. Already terminal outcomes are preserved. Cancellation is persisted and
checked before further dispatch and resumption; it interrupts active work where
possible and closes pending waits. Subtree cancellation also covers descendants
created by a start racing with that request; publishing a child and checking the
ancestor's cancellation state must be coordinated in the instance store.
Acknowledging the request does not assert that an in-flight external action was
undone or even interrupted. Late replies are retained as unmatched/closed-wait
outcomes and never restart a cancelled instance. Existing draft evolutions remain
available; cancellation neither accepts nor deletes them.

### Live plugin capabilities and waiting

Plugins expose typed live queries, actions and incoming event contracts alongside
captured sources and sinks, using the same vendored package, instance configuration
and authentication ownership in [ADR 0015](0015-plugins.md). Generated proxies
hide transport. A query reads the provider at execution time; an action may change
it. Neither implicitly fetches evidence or accepts KB changes. An explicit action
may invoke an existing sink through ADR 0017's delivery boundary without requiring
a renderer. Input/options remain checked and delivery uncertainty remains visible.

```haskell
-- Method-specific generated bindings implement these typed boundaries.
liveQuery :: LiveQueryRef input output -> InteractiveFlow input output
performAction :: ActionRef input output -> InteractiveFlow input output

data EventRef request reply
-- Generated persistence envelope; authors use the typed EventRef binding.
data EventRequest request = EventRequest EventBindingRef request
data ReplyOrigin
  = ProviderReply PluginInstanceRef EventIdentity
  | ManualReply InvocationSurface

data ReceivedReply reply = ReceivedReply
  { origin :: ReplyOrigin, value :: reply }

awaitReply :: EventRef request reply
           -> InteractiveFlow request (ReceivedReply reply)

-- Upstream primitives, not a second Kyyn interpreter.
await :: Codec request -> Codec reply -> Agentic m request reply
resumable :: Monad m => Runtime m -> Agentic m input output
          -> input -> m (Progress output)
data Progress output = RunFinished output | RunWaiting (NonEmpty PendingWait)
fulfil :: Monad m => Runtime m -> Agentic m input output -> PendingWait -> Value
       -> m (Either ReplyRefused ())

-- Host application operation; ingress sets origin, never the submitted payload.
fulfilWait :: (FlowStore :> es, Failure :> es)
           => KnowledgeBase -> WaitId -> ReplyOrigin -> CheckedValue
           -> Eff es FulfilOutcome
```

Refs bind a specific declared method/event and checked types; they are not an
untyped provider RPC escape hatch. Runtime identities, codec projections and
wire envelopes are generated. The durable action combinator derives its operation
key from the library occurrence and instance namespace; the author does not choose
it. Only the adapter receives the key. The plugin owns provider-specific reception and
correlation; the host validates the resulting event against the registered wait
contract before committing it. `FulfilOutcome` distinguishes accepted, duplicate,
conflicting, invalid and closed-wait deliveries. The first valid fulfilment is
immutable; a conflicting value never overwrites it. Provider-origin identities
come from the authenticated adapter. CLI/MCP fulfilment records ManualReply with
the actual surface; it cannot claim provider origin. Origin is saved with the
value, returned to the flow and retained in any supporting proposal rationale.
It describes ingestion provenance, not proof that a remote person's assertion is true.

The generated awaitReply binding supplies explicit persistence codecs to upstream
await. Its typed request carries the selected event binding and authored question,
recipient and correlation metadata; the library does not interpret those fields.
EventBindingRef identifies the captured plugin/instance/event declaration; its
configured request/reply contracts are checked against the EventRef. The generated
wrapper passes EventRequest request to await, so the host routes the persisted
request by this binding, not by schema shape, labels or question text. The worker
rejects bindings outside the instance's captured declarations before dispatch.
No separate openWait operation or explicit send before await is required.

An unanswered await stops its branch. Independent branches continue until each
has finished or suspended; sequential waits become reachable one at a time. The
library returns RunWaiting with the reached frontier, whose descriptors contain
journal identity, stable key, encoded request, request/reply schemas and path notes.
An unbounded sibling can prevent an outcome; this is an authored-flow concern.
The attempt can then release its process. This works over the existing pure guest
request program under ExceptT; no native exception or MonadIO capability is added.
A real failure remains a failure, not a partial successful waiting outcome.

Kyyn persists the frontier before asking the plugin to dispatch its questions.
Dispatch is keyed by the stable wait identity: re-reporting an unanswered wait
does not resend it. The wait therefore exists before any fast reply can arrive.
A known completed dispatch is retained; an uncertain send follows the adapter's
repeat-safety policy, never a claim that local persistence makes delivery exactly
once. Some waits require no outbound message (manual input or child completion).

Ingress may queue a received delivery without loading guest code; it is not yet a
fulfilled reply. Under the instance writer lock, the worker loads the retained
flow and calls upstream fulfil, which finds the actual reply codec structurally
without executing actions, models, observers or replay. It canonicalises, decodes
and commits the reply. ReplyRefused is an actionable refusal; journal failures
remain operational errors. Unavailable builds prevent fulfilment with a diagnostic.
Kyyn checks origin and whether the wait is still open before that call. Only a
validated committed reply makes the instance Runnable; receipt alone does not.
The next attempt calls resumable again from the original input, restoring saved
results. Identical duplicate replies are accepted, conflicting replies refused.

Only a successful RunFinished/RunWaiting outcome is authoritative for withdrawing
previously reported waits absent from that frontier; failed/interrupted attempts
leave prior waits intact. Attempts and fulfilment mutations share one writer lock.
The library does not revoke withdrawn keys: Kyyn refuses late replies to closed
waits before fulfilment. Whole-instance cancellation prevents future execution;
no library cancellation verb is needed. A domain timeout can be a value in the
authored reply type, distinct from whole-instance cancellation. Duplicate wakeups
do not start concurrent writers for one instance. Time-based triggers enter through explicit external
CLI/MCP input or a declared plugin event source. The worker does not supply a
business timer or launch a daily scanner on its own. An author needing a deadline
must configure a source for that event; the passage of time alone does not wake a
wait. Reminder and escalation decisions remain authored policy.

### Replay reconstructs execution, not the external world

Use the library's durable recording contract, with Kyyn supplying its store.
Interactive execution requires both completion replay and the typed
blocked/fulfilment contract specified above from the library. Kyyn does not
implement a competing arrow interpreter to obtain them.

Each instance fixes the original request, execution revision (code, codecs and
provider configuration) and journal namespace. Resumption reuses that execution;
it does not silently switch to newly accepted code. Persist secret names, not resolved credentials; inspection never reads the secret
store. Resolve credentials only for new live operations. Live payloads follow the
same authored provider/redaction policy as captured payloads, including any
required people redaction before sending data to Jev.
Keep its guest build available
while the instance is resumable. Missing code/build or a revision/input mismatch
is a diagnostic, not an automatic migration or a compatibility reader. Inspection
of persisted status does not require executing the old build. Such a diagnostic
leaves the instance blocked from execution, with cancellation still available;
it cannot silently resume against another contract.

The interactive authoring bindings for liveQuery, performAction, selectKnowledge,
queryKnowledge, startFlow, inspectFlow, cancelFlow, prepareProposal
and inspectProposal are durable Agentic
combinators with explicit persistence codecs. They record their returned values
at the library occurrence. Their lower-level guest requests alone do not journal
anything. Captured-evidence reads must likewise be wrapped in the library's
explicit durable combinator when their results drive resumed execution.
Completed operations return stored results rather than reopening changed data.
Existing evidence reads inside `act` are unchanged and execute again; making
a recipe interactive does not automatically make arbitrary act bodies durable. A model completion is
replayed; an incomplete model call can be repeated under the upstream limitation. Model decisions
and provider tool-call identities are restored through the same journal.
An unfinished tool re-enters its body, whose completed durable sub-actions replay.
Plain `act` still runs: values affecting control flow must come from fixed inputs
or recorded operations. Refreshing external or KB data is a new durable operation,
not replacement of an earlier read result during replay. Kyyn-owned operations
which start children or prepare proposals return their existing handles
when repeated under the same operation key.

The journal stores completed results only. An action that ran but failed to save
its result can run again. External actions receive the stable instance-qualified
operation key; their adapter must establish repeat safety or report that safe
resumption cannot be provided. A destination may not support idempotency, and a
local receipt alone does not close the send/save crash window. Do not promise
exactly-once delivery or add an implicit retry of an uncertain send. Message
adapters must state and test their delivery semantics before enabling replay.

### Knowledge access and proposals remain explicit

Interactive execution composes selected-snapshot reads and evolution application
operations; it does not gain filesystem mutation of accepted facts.

```haskell
-- Guest-facing capabilities; host handlers use existing application operations.
selectKnowledge :: InteractiveFlow () KnowledgeSnapshot
queryKnowledge :: KnowledgeQueryRef input output
               -> InteractiveFlow (KnowledgeSnapshot, input) output
prepareProposal :: InteractiveFlow
                   (KnowledgeSnapshot, RecipeProposal edits state) EvolutionId
inspectProposal :: InteractiveFlow EvolutionId ProposalStatus
```

A `KnowledgeSnapshot` identifies an accepted Git revision and its checked root
contract. Queries use that selected snapshot, including across several calls;
the journal retains results required for replay. Selecting knowledge again is an
explicit refresh. A changed schema incompatible with the running entry produces
a contract diagnostic rather than coercion or silent reuse of stale types.

`prepareProposal` uses the ordinary frozen fact-edit proposal and recipe-state
contract in [ADR 0028](0028-agentic-workflows.md), with the snapshot revision as Before. The host checks edits and
state against the selected recipe/root contracts. A long conversation need not
create a workspace at its start; it may refresh knowledge and prepare a proposal
when ready. It must not relabel an old proposal as based on a newer root. Multiple
proposals are allowed, each with its own explicit base. Instance progress and
conversation state stay in the instance store; they are not a shared recipe-state
checkpoint that every child must overwrite. A child with no recipe-state change
preserves the state from its selected snapshot.

For a consolidated portfolio update, children return typed review results and the
parent refreshes knowledge and prepares one proposal. Independently finishing
children may instead propose separately. If one proposal's acceptance makes
another stale, inspectProposal reports that outcome; the author refreshes the KB,
reconsiders the edits and shared recipe state, then prepares a new draft with a
new operation occurrence. It does not repeat the conversation unless its assumptions
need clarification. Old drafts remain inspectable. Neither automatic rebasing nor
blind replay of a full old recipe state is allowed. Expected-head checking can
still reject a new race; there is no promise every parallel draft accepts at once.

Evolution checking and acceptance remain the existing host application operations.
There is no accepted-ref guest capability and flow success never accepts a
proposal. An authorised external agent or external script may explicitly check,
mark Ready and accept through those operations as in ADR 0025. The interactive
worker has no automatic acceptance policy or acceptance-on-completion hook. The interactive flow can inspect or await their recorded
outcome through the event interface. Checking a proposal never re-executes the
conversation. Rationale explains the proposed changes; conversation references
or summaries may support it without becoming mandatory evidence captures. Persist
the material live observations needed to explain an edit in the existing
`ProposedStep`'s `Rationale.explanation :: Text`. Include the relevant assertion
or query result summary, its provider/manual origin and available source identity;
a remote URL alone is insufficient. This text is part of the frozen proposal and
accepted evolution committed to Git under ADR 0010. `Rationale.evidence` contains
only actual captured EvidenceRefs and may be empty. No new citation store is
required. The explanation remains meaningful if local execution state is removed.

### Runtime ownership and observation

`kyyn-v2 flow worker`, exposed by [ADR 0018](0018-surfaces.md#interactive-flow-operations),
explicitly runs a foreground worker for the selected KB. It
executes runnable hosted instances and resumes them when fulfilled waits permit
progress. A process-scoped per-instance writer lock prevents two execution attempts
writing the same instance; process exit releases the lock without inventing a
terminal outcome. The worker also polls declared plugin event adapters for pending
waits, persisting received events and adapter cursors before advancing those
cursors. Duplicate provider event identities are deduplicated at fulfilment.
This event path introduces no inbound network listener. A provider requiring
webhooks needs a separately designed transport rather than an implicit listener.
CLI/MCP manual fulfilment remains available independently of the worker. Persisted runnable work survives worker shutdown;
reopening does not require a browser. While the worker is down, no hosted guest
advances; accepted event deliveries remain queued. An offline event receiver
cannot promise delivery: its plugin must document provider retry or catch-up
behaviour and report gaps rather than manufacture replies. Starting/stopping this worker is distinct
from starting/stopping Web and from cancelling a flow. A process loss leaves an
interrupted attempt, not a fabricated failure/completion of the durable instance.
Native process interruption and cleanup still follow ADR 0019.

CLI and MCP expose the same start/inspect/fulfil/await/cancel application operations.
Web observes instances, parent/child relationships, waits and attempts; it remains
read-only under ADR 0023. An external agent can use the same KB, plugin and
interaction operations to implement an open interactive recipe. Its harness owns
its next model turn and resumption. Kyyn persists the external instance's interactions and operation handles; it
does not journal or restore the external harness's private reasoning or execution.
A pending reply in Kyyn does not automatically
launch or reconstruct a Codex/Claude session. Externally coordinated instances
retain status and correlation records but are not dispatched as hosted guest flows.
The external harness explicitly reports its checked terminal result through a
host application completion operation; it cannot replace an existing terminal
outcome or bypass a cancellation. Disconnection alone does not mark it Completed.

Durable instance state, reply values and the replay journal are distinct from
the disposable viewer recordings in [ADR 0028](0028-agentic-workflows.md#record-recipe-execution-for-live-viewing-and-playback). Each execution attempt has its own
recording namespace. The library reports Suspended for a wait and enclosing
scopes exiting because of it, and Restored for an answered wait on replay. Those
terminals belong to an attempt, not the logical instance; an enclosing parallel
scope can still fail because another branch failed. Restoring work uses these
upstream observations rather than inferred host events. A waiting attempt is not a completed logical flow. An instance links
its attempts and draft evolutions. Clearing viewer recordings does not delete
replay state or abandon waiting work. The instance view shows logical status and child statuses separately; the run
list/viewer continues to show individual attempts, linked to their instance.
A completed parent can therefore visibly have active children.
Run identity checks for resumption do not
turn recording inspection into historical compatibility enforcement.

## Verification

Use deterministic provider/event fixtures to exercise query, await, frontier
persistence, send, process stop, reply, resume and proposal creation. Prove the
completed send is not re-executed, a reply arriving immediately after send is retained, and malformed or
conflicting replies cannot advance the flow; manual replies retain their actual origin. Exercise incomplete-action repeat
semantics without claiming to solve an unsupported provider crash window.

Exercise partial tool completion, two waits in parallel, duplicate wakeups,
child-start replay, a parent completing before children, selective await, failure
without sibling cancellation, subtree cancellation beneath a completed parent,
and a start racing with cancellation. Verify late replies cannot resurrect a
cancelled instance. Preserve a draft and any accepted changes after cancellation.

Exercise a KB refresh before proposing, a changed schema, a stale base after a
sibling accepts followed by refresh/reconsideration/new proposal, one parent
proposal assembled from child results, and unchanged ordinary recipe/tool
capability boundaries. Prove child authority stays within the captured declared
set and that no worker path accepts an evolution. The
external-agent journey uses the same application operations without launching a
hosted model loop. Restart with the retained build and journal; report missing
builds and changed input/revision honestly. Clear viewer recordings while waiting
and prove resumption still works.

