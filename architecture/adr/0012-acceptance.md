---
id: 0012
title: 'Acceptance is one conditional step from local head'
status: proposed
date: 2026-09-07
---
# Acceptance is one conditional step from local head

Basis: the equality check against local Git head and the absence of remote
coordination are owner-established guarantees. The publication sequence, result
types and recovery diagnostics are proposed implementation mechanics.

## Context

Kyyn must not accept an evolution based on a root other than its current local
head. This is a narrow local correctness guarantee, not a mandate to coordinate
all users, processes, working-directory edits or upstream repositories.

## Decision

The rule is **`Before.revision == current local accepted head`**. Require equality,
not an ancestry or timestamp comparison: a divergent base is also unsuitable.
The revision identifies the complete source root, not merely its schema version.

KB initialization creates the first commit as a separate operation; evolution
acceptance always advances an existing local head.

The selected workspace must also be Ready. A Draft is not implicitly submitted
by calling accept, even if it happens to have a passing candidate; an already
Accepted workspace is not replayed. Ready expresses intent, not validation or
approval by a particular actor. Require the checked result and unchanged captured
inputs as well as readiness. An unready workspace returns NotAccepted, leaves
head unchanged and retains the workspace/results for further work.

Publication receives one value containing the checked output, fixed step report and captured
[evolution context](0010-evolutions.md). This synonym introduces no new wrapper,
registry or duplicate base field:

```haskell
type CheckedEvolution = Candidate (Validated Root)

data RootPublication :: Effect where
  AcceptEvolution
    :: LocalBranch -> CheckedEvolution
    -> RootPublication m AcceptanceResult

runRootPublication
  :: (RootStore :> es, EvolutionStore :> es,
      Git :> es, FileSystem :> es, Failure :> es)
  => Eff (RootPublication : es) a -> Eff es a
```

The branch argument selects the local branch for this operation, not a mandatory
persisted branch configuration. The KB and expected revision come only from the
candidate's context. There is no independent KB or expected-base argument that
could disagree. Notably the interpreter requires no
RootExecution, EvolutionExecution, plugin invocation or schema parser: it publishes fixed, already
checked material rather than evaluating new source behind the caller's back.
RootStore supplies `ExportRootFiles`; EvolutionStore supplies the observed state,
`MatchesCapturedInputs` and `ExportAcceptedWorkspace`. Those capabilities own
snapshot access, workspace layout and Dhall/report serialization. Publication
assembles their returned file trees and performs the Git operation; it does not
unwrap snapshot handles into undocumented filesystem paths or duplicate their
encoders. Installing the stores' interpreters does not invoke their compiler-using
operations during publication.
Publish the candidate's exact `EvolutionReport` into the retained evolution
workspace alongside captured source/specifications. It was derived during
evaluation, not read afresh from an editable report file. The root and its report
enter the same commit; accepting neither reruns the entry nor recomputes step
history from the final diff. Later history reads can therefore explain intermediate
changes without running archived code. No separate provenance commit, receipt or
database is required.

Keep evaluation, validation and diff inspection available before acceptance.
For a new CLI/Web process, perform the already-accepted lookup described below,
then use EvolutionStore's `LoadCandidate` and `checkCandidate` on that stored
result, and only pass a successful checked value
to `AcceptEvolution`. Missing saved material is an actionable request to evaluate,
not an implicit evaluation during acceptance. A saved passing report does not
replace fresh validation. This application path needs RootExecution for checking;
the publication handler itself does not. Source acquisition and the evolution
entry are never rerun on this path.

Accept the resulting validated evolution by constructing its complete Git tree,
including deletions and its retained workspace, and creating a commit whose parent
is `Before.revision`. Advance the local accepted ref **atomically only if it
still equals that revision**. A separate read/check followed by an unconditional
ref update is insufficient. Git already supplies the conditional primitive.
[Git update-ref](https://git-scm.com/docs/git-update-ref)

The plumbing distinction is equally important: commit construction is separate
from the conditional ref update. These selected operations belong to Git, below
the semantic publication boundary:

```haskell
createCommit
  :: (Git :> es, Failure :> es)
  => Repository -> GitTree -> GitRevision -> CommitMetadata
  -> Eff es GitRevision

compareAndSwapRef
  :: (Git :> es, Failure :> es)
  => Repository -> LocalBranch -> GitRevision -> GitRevision
  -> Eff es RefUpdate

data RefUpdate
  = RefUpdated
  | RefNotUpdated (Maybe GitRevision)
```

`createCommit` takes one parent; publication supplies `Before.revision`.
`compareAndSwapRef` takes expected-old then desired-new revision. Its comparison
and update must be atomic in the interpreter. `Nothing` means the ref no longer
exists. Failure of that comparison leaves the accepted ref unchanged, even if
unreachable candidate Git objects were already written. These signatures do not
themselves prove the atomic implementation; real Git tests must do that.

Validation applies to the result being accepted. If the author changes the base,
transformation, target schema or other evaluation inputs, rerun the checks and
diffs; do not reuse the old result. This is ordinary correct use of a checked
value, not a mandatory sealed-candidate identity, approval receipt or custody
protocol. Kyyn need not prove that a reviewer noticed every semantic overwrite.

`After` has no preassigned commit revision. Retain `Before.revision` in the
workspace; ordinary Git history records the accepting commit and parent. No
additional from/to root-content hash scheme is required by acceptance.

## Concurrent instances and upstream

Multiple instances may operate on one local repository. If two evolutions start
at A, one may advance head to B; the other's conditional update from A must
refuse. No singleton process, daemon or cross-instance coordinator is required.
Return the expected and actual local revisions. The author can rebase the same
unaccepted evolution as described in ADR 0010 and try again.

A caller must also distinguish an unaccepted operation from an accepted commit
whose working-tree update needs attention:

```haskell
data AcceptanceResult
  = NotAccepted AcceptanceProblem
  | AcceptedCommit GitRevision WorkingTreeOutcome
  | AlreadyAccepted GitRevision Diagnostic

data AcceptanceProblem
  = BaseMismatch GitRevision (Maybe GitRevision)
  | NotReady EvolutionState
  | CheckoutMismatch LocalBranch (Maybe LocalBranch)
  | WorkspaceChanged EvolutionId
  | OverlappingEdits [RelativePath]

data WorkingTreeOutcome
  = WorkingTreeUpdated
  | WorkingTreeUpdateIncomplete Diagnostic
```

`NotReady` reports the observed lifecycle state; the CLI exits non-zero rather
than marking it Ready on the caller's behalf. This is the same check for scripted
and interactive acceptance, not an automation permission system.

`WorkspaceChanged` means the currently selected workspace no longer matches the
captured input material; recapture and recheck instead of substituting edited
source into the old result. It specializes an overlapping workspace edit with
that distinct repair, while `OverlappingEdits` covers other paths acceptance would
overwrite. `CheckoutMismatch` includes detached HEAD. Unexpected
pre-publication IO failures use [Failure](0019-failures.md). After a successful ref
update, returned errors/cancellation must retain `AcceptedCommit` and its revision;
they are not permission to retry acceptance as though nothing happened.

A process can die after the ref update and before returning or synchronizing the
workspace. On the next acceptance request, inspect the selected branch's Git
history before loading/checking a candidate or diagnosing an old Before as a
rebase request. The committed Accepted archive is authoritative for this lookup,
not the possibly still-Ready local manifest:

```haskell
-- EvolutionStore operation; reads Git, not a second acceptance registry.
FindAcceptance
  :: KnowledgeBase -> EvolutionId -> GitRevision
  -> EvolutionStore m (Maybe GitRevision)
```

Start by reading this workspace's archive in the input revision's tree. If absent
or not Accepted, return `Nothing`: a Git revert can remove an acceptance. Otherwise
take its recorded Before B and walk the input revision's ancestors through all
parents, finding the commit with parent B that introduced that Accepted archive.
Return that introducing commit, not a later head that merely carries the archive.
An ambiguous or malformed history is a diagnostic, not a guess. A subsequent
re-acceptance uses the current archive's Before and resolves to its new commit.
The application returns `AlreadyAccepted` with that revision and guidance to
inspect/repair local files through Git. Publication repeats this lookup before
base/readiness checks so a concurrent completed acceptance is diagnosed honestly.
If conditional ref update loses a race, repeat the lookup once at the returned
actual revision before reporting `BaseMismatch`; the competing operation may
have accepted this very workspace. This is diagnosis, not a retry of publication.
It does not automatically overwrite a live workspace, replay the evolution or
publish a replacement acceptance. Missing disposable candidate files do not hide
an acceptance already recorded in Git. No durable recovery coordinator is needed.

The guarantee is local to the selected accepted branch. It does not reserve a
remote branch. Push rejection and upstream conflicts belong to the user/agent's
ordinary Git workflow (ADR 0013). Simultaneous edits of an uncommitted workspace
are also their responsibility, not another synchronization system for Kyyn.

## Working tree, index and other drafts

Propose the ordinary checked-out local branch as the accepted ref, not a private
`refs/kyyn/...` history. Acceptance requires the branch selected for the operation
to be checked out; refuse detached HEAD or a different checked-out branch with an
actionable explanation. Recheck the selection before publication; this is not a
new long-lived branch/session manager.
Reading an explicitly selected snapshot remains separate from accepting it.

Draft workspaces are ordinary local files, not automatically committed or hidden
in an ignored cache. Creating a draft does not move head. Users/agents can commit
and share draft files through ordinary Git when desired; that commit advances
head and can require rebasing their evolutions. Ready is author intent, not an
automatic commit. Accepted workspaces are committed and retained.

Build the accepting tree from `Before.revision`'s tree, applying the complete
subtree replacements exported by RootStore and EvolutionStore. Their prefixes
are relative to the explicit KB location (ADR 0006); publication does not
hardcode either store's layout.
This includes facts, source, configuration and examples; missing files are deletions.
Preserve already committed unrelated files. Do not sweep other uncommitted
drafts, staged files or raw edits into that tree. Other drafts become base-mismatched
when acceptance advances head; an explicit in-place rebase is the intended repair.

Tree construction must not use the user's index as an implicit source of changes.
After the conditional ref update, synchronize the paths written or removed by
this acceptance in both the working tree and index, while preserving unrelated
working-tree and staged changes. Refuse
known overlapping edits before publication rather than silently discard them.
This requires a tested Git tree/index/worktree sequence; no particular checkout
command is endorsed here as already sufficient. Simultaneous arbitrary raw edits
remain the user's responsibility, not grounds for a workspace coordination service.
Failures after the ref update must report successful acceptance separately from
incomplete working-tree synchronization.

Ordinary Git commits need not have been produced by Kyyn. Loading an unknown
accepted root checks it as specified in ADRs 0004 and 0013; selecting an ordinary
branch does not make every commit valid by definition.

## Implementation responsibilities and exclusions

Validate the complete result before publication; acceptance writes that checked
result, preserves unrelated files and reports errors honestly. The publication
handler does not secretly evaluate or validate fresh guest code. A failed
conditional update leaves the accepted ref
unchanged. If an error occurs after that update, report that acceptance occurred;
do not present a failed checkout write as if the commit never happened. These
are implementation responsibilities, not a requirement for a durable recovery
manager, a workspace projection service or distributed transaction machinery.

Reject integer-only ETags, unguarded accepted-ref updates and automatic conflict
repair. Do not introduce additional lifecycle states, historical attempt archives
or approval protocols to enforce the single local-head condition.

## Verification

Test matching, older and divergent bases; two local accept attempts against the
same head; validation failure; and a rebase followed by successful acceptance.
The accepted commit's parent equals `Before.revision`. Reopen preserves additions,
edits and deletions. Test honest failure reporting before/after the ref update.
A rejected upstream push does not undo or misreport successful local acceptance.
Use two drafts in a real temporary repository: accept one with a deletion, keep
the other's local files, rebase it and accept it. Include unrelated staged and
unstaged files, a previously committed draft, overlapping edits, detached HEAD
and changed branch selection. Assert both the committed tree and remaining
index/worktree contents; a passing ref-update test alone does not prove this seam.
Kill the process after successful ref update but before local synchronization,
then retry with disposable candidates removed. It must identify the actual
accepting commit without evaluating or creating another commit. Repeat after a
later unrelated commit: inherited archive presence must not misidentify that
later head as the accepting commit.
Revert the acceptance so its archive is absent/not Accepted at head: lookup returns
`Nothing`. Re-accept from the new base and verify lookup identifies the new commit.
After interrupted synchronization, listing reports the committed Accepted state
and accepting revision even when the local workspace still says Ready.
