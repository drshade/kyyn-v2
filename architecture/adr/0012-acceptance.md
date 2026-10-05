---
id: 0012
title: 'Acceptance is one conditional step from local head'
---
# Acceptance is one conditional step from local head

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

Initialization uses `KnowledgeBaseInitialization`, not an evolution workspace or
the evolution-history interpreter. Preparation is read-only and captures the
requested directory, the nearest existing directory for Git/config lookup, and
an optional existing KB location, checked-out branch and head. Identity is read
before compilation; the pure empty scaffold then passes `OpenCapturedRoot` and
the ordinary `checkRoot` path. Publication accepts only the resulting checked root:

```haskell
data KnowledgeBaseInitialization :: Effect where
  PrepareKnowledgeBase :: DirectoryScope
    -> KnowledgeBaseInitialization m (Either [Diagnostic] InitializationTarget)
  PublishInitialRoot :: InitializationTarget -> CommitMetadata -> Validated Root
    -> KnowledgeBaseInitialization m (Either [Diagnostic] InitializationResult)

runKnowledgeBaseInitialization
  :: (FileSystem :> es, Git :> es, RootStore :> es)
  => Eff (KnowledgeBaseInitialization : es) a -> Eff es a
```

Only publication creates missing directories or initializes Git. It rechecks the
prepared target, exports the validated root through RootStore, constructs a commit,
conditionally publishes it, and synchronizes only `root/`. A new repository uses
Git's configured default branch; an existing repository retains its checked-out
branch and unrelated content, including staged and unstaged changes. An unborn
branch has no parent; otherwise initialization adds one commit to the existing head.

Refuse existing `root/` or `evolutions/` content at the target in HEAD, the index
or the working directory, detached HEAD, and placement inside another KB's owned
`root/` or `evolutions/` subtree. Unrelated content beside those subtrees is allowed.
Ordinary preflight refusals, including missing identity and validation failures,
precede filesystem writes. Concurrent target/head changes can still cause a
publication-time refusal. Operational failure after directory/repository creation
may leave that empty setup in place; initialization does not recursively roll it back.
If the ref update succeeds but checkout synchronization fails, return the revision,
branch, KB directory and `WorkingTreeUpdateIncomplete`. The CLI supplies a scoped
Git restore command; retrying initialization refuses the already-published root.

Git discovery uses command outcomes, not error-text matching. When discovery
cannot open a working tree, initialization also checks ancestor directories for
an existing `.git` entry; unusable metadata is a refusal, not permission to run
`git init` over it.

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
    :: LocalBranch -> CommitMetadata -> CheckedEvolution
    -> RootPublication m AcceptanceResult

runRootPublication
  :: (RootStore :> es, EvolutionStore :> es, Git :> es)
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

Under the [curation model](0014-evidence.md), root export also includes
the candidate's resolved host-owned progress register. Facts, progress and the
archive publish through this same conditional commit. Publication does not consult
the evidence cache or resolve declarations against a newer fetch. Inspection shows
the declared acknowledgements even when the fact diff is empty. Expected-head,
readiness and recovery rules apply unchanged.

Archive export is defined in ADR 0010. Only its notes subtree is
read from the live workspace; captured manifest fields, source and fixed report
are not replaced by current files. The host-produced Dhall record and its durable
version/readability policy are owned there. Root export and archive export return
the two replacements for one commit, not two publication steps.

Keep evaluation, validation and diff inspection available before acceptance.
For a new CLI/Web process, perform the already-accepted lookup described below,
then use EvolutionStore's `LoadCandidate` and `checkCandidate` on that stored
result, and only pass a successful checked value
to `AcceptEvolution`. Missing saved material is an actionable request to evaluate,
not an implicit evaluation during acceptance. A saved passing report does not
replace fresh validation. This application path needs RootExecution for checking;
the publication handler itself does not. Source acquisition and the evolution
entry are never rerun on this path.

The application operation lives with the semantic evolution operations, not in
CLI/MCP/Web adapters:

```haskell
acceptStoredEvolution
  :: (RootPublication :> es, EvolutionStore :> es,
      RootExecution :> es, RootStore :> es)
  => LocalBranch -> CommitMetadata -> EvolutionWorkspace -> Eff es AcceptanceResult
```

It calls `FindAcceptanceOnBranch` first, returning an existing acceptance without
candidate access. Otherwise it loads the saved candidate, runs `checkCandidate`,
and calls `AcceptEvolution` only for a passing result. Missing, stale or rejected
material is `NotAccepted (InvalidMaterial diagnostics)`. The application has no
Git or filesystem dependency; publication owns branch resolution and delegates
the history walk to EvolutionStore.

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
  => Repository -> GitTree -> Maybe GitRevision -> CommitMetadata
  -> Eff es GitRevision

compareAndSwapRef
  :: (Git :> es, Failure :> es)
  => Repository -> LocalBranch -> Maybe GitRevision -> GitRevision
  -> Eff es RefUpdate

data RefUpdate
  = RefUpdated
  | RefNotUpdated (Maybe GitRevision)
```

`createCommit` takes an optional parent; evolution publication supplies
`Just Before.revision`. Initialization without an existing head supplies `Nothing`,
constructing a parentless commit from an empty tree.
`GitTree` supplies non-overlapping complete replacements, each located at a
subtree prefix or the whole tree. Empty subtree replacements remove that subtree;
an empty whole-tree replacement produces an empty root tree. Unrelated entries
retain their existing objects and modes, including symlinks and executable files.
Replacement `FileTree` values carry bytes, not modes: their files are written as
regular `100644` entries. Construction uses Git objects directly, without the
live index or working tree.

`CommitMetadata` supplies the message and separate author/committer identities,
each with a name, email and explicit Git-format date (Unix seconds and timezone
offset). The caller supplies these; construction does not consult the clock or
derive identity from user configuration.

`compareAndSwapRef` takes expected-old then desired-new revision. `Nothing` requires
an absent branch ref, for initial publication; evolution acceptance supplies
`Just Before.revision`. Its comparison
and update must be atomic in the interpreter. `Nothing` means the ref no longer
exists. Failure of that comparison leaves the accepted ref unchanged, even if
unreachable candidate Git objects were already written. These signatures do not
themselves prove the atomic implementation; real Git tests must do that.
The actual revision returned after a refused update is a subsequent observation,
not a frozen snapshot of the comparison instant. A failed update while the ref
still has the expected value is an operational failure, such as a held ref lock.
The raw ref primitive does not synchronize the checkout; the publication sequence
below owns that separate step.

Validation applies to the result being accepted. If the author changes the base,
transformation, target schema or other evaluation inputs, rerun the checks and
diffs; do not reuse the old result. This is ordinary correct use of a checked
value, not a mandatory sealed-candidate identity, approval receipt or custody
protocol. Kyyn need not prove that a reviewer noticed every semantic overwrite.

The Root validated and the Root committed are the same value within this sequence.
ExportRootFiles reads only that validated value's captured files; it does not reload
the checkout or substitute a freshly materialized root before commit construction.

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
  | InvalidMaterial [Diagnostic]

data WorkingTreeOutcome
  = WorkingTreeUpdated
  | WorkingTreeUpdateIncomplete [Diagnostic]
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
update, normal returned outcomes must retain `AcceptedCommit` and its revision.
A checkout synchronization failure is reported alongside that acceptance, not as
a `Failure` that hides it. A non-zero Git update exit with the ref observed at
the desired revision also counts as published; the exit status alone must not
report that publication failed. `RefUpdated` means the desired publication is
observed in the ref, not that this particular attempt performed the update.
For the commit constructed for this publication, that is acceptance whichever
attempt wrote it.

Asynchronous cancellation or process death can interrupt an invocation after the
ref update and before returning or synchronizing the workspace. Such an
interruption yields no normal outcome; it does not guarantee delivery of an
`AcceptedCommit` result and must not be interpreted as evidence of non-acceptance.
On the next acceptance request, inspect the selected branch's Git
history before loading/checking a candidate or diagnosing an old Before as a
rebase request. The committed Accepted archive is authoritative for this lookup,
not the possibly still-Ready local manifest:

```haskell
-- EvolutionStore operation; reads Git, not a second acceptance registry.
FindAcceptance
  :: KnowledgeBase -> EvolutionId -> GitRevision
  -> EvolutionStore m (Either [Diagnostic] (Maybe GitRevision))
```

Archived manifests are read by projecting the metadata needed for history
(Before revision, name, explanation and state); active workspace manifests are
read strictly as current execution inputs. Extra historical fields do not require
rewriting accepted archives.

Start by reading this workspace's archive in the input revision's tree. If absent
or not Accepted, return `Nothing`: a Git revert can remove an acceptance. Otherwise
take its recorded Before B and walk the input revision's ancestors through all
parents, finding the commit with parent B that introduced that Accepted archive.
Return that introducing commit, not a later head that merely carries the archive.
An ambiguous or malformed history is a diagnostic, not a guess. A subsequent
re-acceptance uses the current archive's Before and resolves to its new commit.
The implementing walk visits each reachable commit once, follows every parent,
and examines the selected archive manifest at potential introductions and their
parents. An introduction has B as a parent, declares Accepted with Before B, and
does not inherit that Accepted/Before pair from any parent. A merge carrying an
acceptance from its second parent therefore resolves to the original acceptance,
not the merge. Multiple reachable introductions for the selected Before are
ambiguous. Later note edits do not require byte-identical archive trees.

This is a history walk, not a lookup index: Git reads grow with the reachable
ancestor count, and the initial list-based visited set can require quadratic local
membership work. There is no history cap or cache. Missing history needed to prove
the introduction returns diagnostics; it is not silently treated as a root commit.
The implementation reads raw commit parent headers and only `manifest.dhall`, not
archived Haskell, reports or evidence. It does not read the live checkout or private
candidate storage and never invokes the compiler. Its plumbing inputs are explicit:

```haskell
readFileAt
  :: Git :> es => Repository -> GitRevision -> RelativePath
  -> Eff es (Either [Diagnostic] (Maybe ByteString))

readCommitParents
  :: Git :> es => Repository -> GitRevision
  -> Eff es (Either [Diagnostic] [GitRevision])
```

An absent path is `Right Nothing`; a directory or unsupported entry is a diagnostic.
An unknown revision is a diagnostic, not an absent file or a parentless commit.
Git infrastructure failures remain Failure.
The application returns `AlreadyAccepted` with that revision and guidance to
inspect/repair local files through Git. Publication repeats this lookup before
base/readiness checks so a concurrent completed acceptance is diagnosed honestly.
If conditional ref update loses a race, repeat the lookup once at the returned
actual revision before reporting `BaseMismatch`; the competing operation may
have accepted this very workspace. This is diagnosis, not a retry of publication.
It does not automatically overwrite a live workspace, replay the evolution or
publish a replacement acceptance. Missing disposable candidate files do not hide
an acceptance already recorded in Git. No durable recovery coordinator is needed.

Branch-aware lookup and explicit recovery are also RootPublication operations:

```haskell
FindAcceptanceOnBranch
  :: LocalBranch -> EvolutionWorkspace
  -> RootPublication m (Either [Diagnostic] (Maybe GitRevision))

RecoverAcceptedEvolution
  :: LocalBranch -> EvolutionWorkspace
  -> RootPublication m (Either [Diagnostic] (Maybe CheckoutRecovery))

data CheckoutRecovery = CheckoutRecovery
  { acceptingCommit :: GitRevision
  , checkoutRevision :: GitRevision
  , outcome :: WorkingTreeOutcome
  }
```

Lookup resolves the branch and delegates to `FindAcceptance`; it does not maintain
another history reader. Recovery first requires that branch to be checked out,
resolves HEAD and finds this workspace's acceptance at that revision. If none is
present, it returns `Right Nothing`. Otherwise it inspects the root and this
archive's checkout paths: no differences means already synchronized; differences
invoke scoped synchronization. It targets the current head, **not** the original
accepting commit, so later accepted work is not rolled back. The result names both
revisions. Other evolutions' archives are outside this explicit repair selection.

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

The Git capability exposes checkout inspection and synchronization independently
of commit construction and ref publication:

```haskell
checkedOutBranch :: Git :> es => Repository -> Eff es (Maybe LocalBranch)

checkoutChanges
  :: Git :> es
  => Repository -> GitRevision -> [RelativePath] -> Eff es [RelativePath]

synchronizeCheckout
  :: Git :> es
  => Repository -> LocalBranch -> GitRevision -> [RelativePath]
  -> Eff es (Either [Diagnostic] ())
```

Paths are explicit repository-relative selections; an empty selection touches
nothing. `checkoutChanges` returns the union of index differences against the
given revision, working-file differences against the index, and untracked files
(including ignored files). Staged and working edits that cancel each other must
not disappear from this check. Publication checks the root selection; the selected
workspace's authored changes are instead guarded by captured-input matching.

`synchronizeCheckout` requires the selected branch to be checked out at the given
revision. It uses path-limited `git restore --staged --worktree --no-overlay`, then
checks the selected paths for remaining differences. It does not advance any ref
or include other paths. Untracked files absent from the commit are retained and
reported as incomplete synchronization, not deleted. Operational failures on this
path become synchronization diagnostics; asynchronous interruption is governed by
the recovery rule above. Normal acceptance can compose this operation after CAS;
recovery can inspect Git and synchronize the current accepted checkout separately,
without reevaluating an evolution or constructing another accepting commit.

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

## Responsibilities and exclusions

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
