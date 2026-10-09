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

Under the [recipe-state model](0014-evidence.md), root export includes each
recipe's definition and checked state. Facts, state and archive publish through
the same conditional commit. Publication does not consult the evidence cache.
Inspection includes state-only changes. Expected-head, readiness and checkout
rules apply unchanged.

Archive export is defined in ADR 0010. Only its notes subtree is
read from the live workspace; captured manifest fields, source and fixed report
are not replaced by current files. The host-produced Dhall record and its durable
version/readability policy are owned there. Root export and archive export return
the two replacements for one commit, not two publication steps.

Keep evaluation, validation and diff inspection available before acceptance.
For a new CLI/Web process, require Ready in the local manifest,
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

It reads the local lifecycle state first, refusing non-Ready workspaces without
candidate access. Otherwise it loads the saved candidate, runs `checkCandidate`,
and calls `AcceptEvolution` only for a passing result. Missing, stale or rejected
material is `NotAccepted (InvalidMaterial diagnostics)`. The application has no
Git or filesystem dependency; publication owns branch resolution and the
Before/head check.

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
Lifecycle metadata comes from the workspace manifest on disk (ADR 0010).
A locally Accepted workspace is refused as `NotReady Accepted` before candidate
loading, compiler setup or commit-identity lookup. A still-Ready workspace based
on an old head is refused as `BaseMismatch`; this includes a retry after publication
whose checkout synchronization was interrupted. The diagnostic gives expected
and actual revisions and says: if this evolution was already committed, inspect
`git status` and restore the checkout from Git. Kyyn does not infer the original
accepting commit or repair the checkout during a retry.

For a normal `AcceptedCommit revision (WorkingTreeUpdateIncomplete diagnostics)`
result, the diagnostic names the known accepting commit and supplies an exact,
shell-quoted Git command restoring only the root and this evolution's workspace:

```sh
git -C '<repository>' restore --source=HEAD --staged --worktree -- '<root>' '<workspace>'
```

The actual command uses the selected repository and exported repository-relative
paths, not these placeholders. Restore from current HEAD so later accepted work
is not rolled back to the earlier commit. Explain that this overwrites local edits
within those paths and ask the operator to inspect `git status` first. Other
workspaces and unrelated paths are outside the selection. Untracked files need
separate inspection; the command is not a promise to remove them. There is no
Kyyn recovery command or recovery registry.

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
path become synchronization diagnostics. Normal acceptance composes this operation
after CAS; interrupted or incomplete synchronization is repaired through ordinary
Git as described above, without reevaluating or republishing the evolution.

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
Interrupt after successful ref update but before local synchronization. A retry
must not publish another commit; a stale-base refusal points the operator to Git.
Test the scoped restore command, including repository paths containing spaces and
quotes, unrelated local work, and restoration from HEAD after another commit.
After restoration, the local Accepted state refuses acceptance without candidate
or runtime access. Listing before restoration honestly reports the local state.
Commit an old accepted manifest missing a currently required field, then repair
only its on-disk manifest: listing and archived report inspection must work
without decoding historical versions or running archived guest code.
