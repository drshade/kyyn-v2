# A todo evolution, from accepted files to accepted files

Status: Proposed review fixture. No new executable implementation accompanies it.

This follows one change across the boundaries questioned in the
[architecture review](../review-2026-09-07.md). The owning ADRs define the contracts;
this document instantiates them with data and paths. Code is illustrative Haskell,
not a claim that the proposed SDK already compiles. `A` and `B` below stand for real
Git commit IDs, not another root revision scheme.

## 1. What exists at A?

The example repository has an ordinary checked-out branch `main` at commit A:

```text
example-kb/
  root/
    kb.dhall
    src/SchemaV1.hs
    src/Queries.hs
    src/Validate.hs
    facts/todos/index.dhall
    facts/todos/todo-001.dhall
    facts/todos/todo-002.dhall
    examples/receipts-title.dhall
  evolutions/
  .kyyn/                         ignored local material; initially empty
  .gitignore
```

The proposed [storage layout](../adr/0006-storage.md) puts current executable
knowledge under `root/`. For this fixture `kb.dhall` selects `SchemaV1.Root`, its
schema metadata and the current entry declarations. The complete declaration
format/registration API remains a separate design task; this fixture requires only
a validator and two named queries, not an automatic export-discovery framework.

The authoritative guest schema is ordinary source:

```haskell
module SchemaV1 where

-- SDK imports supply Text, Fact and generated encoding support.
data Status = Open | InProgress | Done
data Todo = Todo { title :: Text, status :: Status }
data Root = Root { todos :: [Fact Todo] }
```

Its collection metadata selects the root field `todos`, whose checked type exposes
the payload `Todo`. There is no `todoId` field inside Todo and no configurable
`idField`: [identity belongs to Fact](../adr/0006-storage.md). Presentation metadata
may mark `title` for display, but renaming a title does not rename a fact.

`index.dhall` contains `[ "todo-001", "todo-002" ]`. The first fact file contains:

```dhall
{ id = "todo-001"
, value =
  { title = "Write report"
  , status = < Open | InProgress | Done >.Open
  }
}
```

The second has title `Check receipts` and status `InProgress`. The host checks
these data files against the Dhall projection of the checked Haskell contract.
The files do not define a second authoritative schema, and facts are not Haskell
literals compiled into the validator.

The validator rejects blank titles. The query implementations calculate a title
or completion flag for a supplied FactId; ordinary declaration adapters expose
them as snapshot queries. Their domain calculation signatures are:

```haskell
import qualified SchemaV1 as Schema

titleFor :: FactId -> Schema.Root -> Maybe Text
isDone   :: FactId -> Schema.Root -> Bool
```

The existing required example invokes `titleFor "todo-002"` and expects
`Just "Check receipts"`. Its saved representation includes the descriptor,
argument/result contracts and typed values defined in
[validation](../adr/0011-validation.md), not just those display strings. Exact
serialized descriptor fields are not invented here ahead of registration design.

## 2. The agent authors the next root

Create evolution `simplify-todos` against A. The store copies the current non-fact
root files into its target and records the source schema from A. The agent then
removes `InProgress`, changes one todo, adds another, and adds a required example.
After editing, the workspace looks like:

```text
evolutions/simplify-todos/
  manifest.dhall                     Before = A; state = Draft; name; explanation
  before/src/SchemaV1.hs             definitions from A, plus necessary imports
  target/
    kb.dhall                        now selects SchemaV2.Root
    src/SchemaV2.hs                  Open | Done; same Todo fields
    src/Queries.hs                  imports SchemaV2 as Schema
    src/Validate.hs                 imports SchemaV2 as Schema
    examples/receipts-title.dhall    existing assertion, checked for target bindings
    examples/report-done.dhall       new required assertion
  change/Evolution.hs
  notes/                            review notes, outside evaluation inputs
```

`target/` is the **complete proposed non-fact root**, not a partial overlay. In
particular `target/src/SchemaV1.hs` is absent: acceptance must delete the old current
schema, not leave it on the build path. Existing plugin source/configuration would
also be copied into target if this KB used plugins. No `target/facts/` competes with
the transformation's result. These choices belong to
[workspace authoring](../adr/0010-evolutions.md).

The proposed schema has `data Status = Open | Done`. The transformation can import
both schemas without ambiguous module definitions:

```haskell
import qualified SchemaV1 as Before
import qualified SchemaV2 as After

change :: Evolution Before.Root After.Root
change = simplifyStatuses >=> completeReport >=> addReview

simplifyStatuses :: Evolution Before.Root After.Root
completeReport   :: Evolution After.Root After.Root
addReview        :: Evolution After.Root After.Root

evolution
  :: Before.Root
  -> Program NoRequests (Either EvolutionFailure (EvolutionOutput After.Root))
evolution before = pure (evaluateEvolution change before)
```

Here `NoRequests` denotes the empty request algebra: this fixture has no host
requests from authored code. The three helpers are ordinary `evolve` steps with
generated typed bindings: `beforeRoot` to `afterRoot` for `simplifyStatuses`, then
`afterRoot` on both sides of each same-contract step. They have these concrete
transformations and declared explanations:

| Step | Transformation | Rationale |
| --- | --- | --- |
| Simplify statuses | Transform every payload to After.Todo; map InProgress to Open and preserve Open/Done and every FactId | “Track completion only; unfinished work remains Open.” |
| Complete report | Modify the fact with ID todo-001 to title “Write sales report” and status Done; fail if absent | “The sales report is complete; make its title specific.” |
| Add review | Append todo-003 with title “Review sales report” and status Open; fail on duplicate ID | “Review the completed report before sharing it.” |

All evidence lists are empty for this local example. The report derives actual
before/after fact changes at each step, including changed payload contracts, rather
than trusting the table's claimed IDs. Renaming todo-001 is not delete-and-add.
The use of separate helpers here makes intermediate types visible; the same three
steps can be authored inline as one chain without another runtime abstraction.

Only SchemaV2 remains in the proposed current root. SchemaV1 survives in the
workspace archive and Git. Following the agreed
[module-naming convention](../adr/0010-evolutions.md), current queries and validators
now use `import qualified SchemaV2 as Schema`: their signatures still say
`Schema.Root`. The evolution uses `Before` and `After` to distinguish its sides.
The names coexist without compiler rewriting or a growing collection of old types
in current source. Accepted evolutions need not remain executable forever.

The new example invokes `isDone "todo-001"` and expects `True`. Both examples must
use valid target query descriptors. If the existing example's contracts change,
the author explicitly rebuilds it against the new descriptor and checks the same
assertion. There is no shape-only exemption or automatic compatibility engine.

## 3. Capture, evaluate, materialize, save, check

The host application selects concrete inputs once. It does not hand the evaluator
an editable workspace path and let later reads silently pick up source changes:

```haskell
captured <- send (CaptureEvolution workspace)
beforeRoot <- send (LoadRootAt kb captured.context.before.revision)
result <- applyEvolution captured beforeRoot
```

These host operations have the types defined in
[evolutions](../adr/0010-evolutions.md) and [storage](../adr/0006-storage.md).
`beforeRoot` is a structurally readable host Root; the source can be repaired even
if its semantic validation fails. It is not the guest's `Before.Root` value.

Inside `applyEvolution`, the meaningful sequence is:

1. `EvaluateEvolution captured beforeRoot`: inspect the target schema, compile
   the entry and proposed executable entries, decode source data, evaluate, and
   obtain the target value plus the derived step report.
2. `TargetCode captured.context.material`: select the captured target files only.
3. `MaterializeRoot after.schema targetCode value`: encode the returned facts
   as Dhall alongside the proposed source/configuration/examples in an immutable
   in-memory file tree. Saving, not materialization, writes that result to disk.
   The accepted root remains A.
4. Construct `Candidate captured.context report materializedRoot`, then
   `SaveCandidate candidate`. Return that unchecked candidate to the application.
5. The application calls `checkCandidate candidate`: validate the materialized
   root and execute its own examples, returning diagnostics and, on success,
   `Candidate (Validated Root)`.

The result has these facts:

| FactId | Title | Status |
| --- | --- | --- |
| todo-001 | Write sales report | Done |
| todo-002 | Check receipts | Open |
| todo-003 | Review sales report | Open |

The persisted candidate contains fixed source, configuration, examples, fact data,
capture context and step report. A possible private cache layout is:

```text
.kyyn/candidates/<private-result-directory>/
  candidate.dhall          context and stored-result metadata, not Validated
  capture/                captured manifest inputs, before/, target/ and change/
  root/                   complete materialized proposed root
  report.dhall            derived step changes and declared rationales
.kyyn/candidates/latest/<evolution-id>    selects its most recent complete result
```

Private directory names are implementation details. Previously loaded snapshot
values remain unchanged, and loading must not select a partially saved result.
This is local result persistence, not a committed registry of every attempt.

The user/agent inspects the facts, schema/source changes, examples and report, then
marks the workspace Ready. Ready changes lifecycle metadata, not captured program
inputs. The evaluating process may now exit; no live continuation or in-memory
Validated value is needed for acceptance.

## 4. A different process accepts it

The next process resolves the workspace and performs this sequence:

| Call | Result and purpose |
| --- | --- |
| `ResolveEvolution kb id` | Resolve the stable ID returned by creation/listing; names are labels |
| `FindAcceptance kb id head` | Diagnose an already accepted workspace from Git before needing local candidate files |
| `LoadCandidate workspace` | `Maybe (Candidate Root)`; load fixed saved data, not a saved validation authority |
| `checkCandidate candidate` | `CheckResult (Candidate (Validated Root))`; rerun pure validation and examples |
| `AcceptEvolution main checked` | `AcceptanceResult`; publish only after readiness, input-match and expected-head checks |

No candidate means “evaluate this workspace first.” Rejected checks retain their
diagnostics and do not call publication. None of these calls executes `evolution`
again or acquires source evidence. This separation is important even though the
particular todo transformation happens to be pure.

Within [publication](../adr/0012-acceptance.md), EvolutionStore supplies current
state, input matching and the accepted archive bytes; RootStore supplies complete
root bytes. Git/FileSystem plumbing does not interpret root handles, infer the
workspace format or perform business validation.

Starting from A's tree, replace `root/` and this evolution's archive subtree only.
Create B with parent A, then atomically compare-and-swap `main` from A to B. B has:

```text
root/
  kb.dhall                          selects SchemaV2.Root
  src/SchemaV2.hs                    no SchemaV1.hs here
  src/Queries.hs
  src/Validate.hs
  facts/todos/index.dhall            [todo-001, todo-002, todo-003]
  facts/todos/todo-001.dhall
  facts/todos/todo-002.dhall
  facts/todos/todo-003.dhall
  examples/receipts-title.dhall
  examples/report-done.dhall
evolutions/simplify-todos/
  manifest.dhall                     Accepted, Before = A
  before/src/SchemaV1.hs
  target/                           proposed source/config/examples, retained
  change/Evolution.hs
  report.dhall                      fixed step report, readable without guest code
```

The archive does not embed B's own hash. Git records B and its parent. The live
workspace becomes Accepted when the accepted tree is synchronized; a failure after
the ref update is reported as acceptance with incomplete working-tree update,
not as an unaccepted operation safe to repeat. If the process dies, the next
acceptance request identifies B from the committed archive and reports
`AlreadyAccepted`; it does not reinterpret the old local Before as a request to
rebase and accept again. Unrelated drafts and staged files
are not swept into the commit or discarded.

Closing the process and deleting disposable candidate/build caches does not erase
the accepted result. Loading B reads current materialized facts and runs the
current validator and both examples. It does not compile or replay the archived
evolution. Looking up todo-001's history reads Git and the archived report.

## 5. The second evolution proves that examples survived

Create a same-schema evolution at B. Its target initially includes **both** current
examples. Have its transformation delete todo-001, without changing the examples.

Materialization removes `todo-001.dhall` and updates the collection index. The
blank-title validator can still pass, but `isDone "todo-001"` returns False and the
required example fails. The unchecked candidate remains inspectable; acceptance
cannot proceed. This is the persistence test: the example is found through the
candidate's root, not by reopening `simplify-todos` or keeping an old process alive.

For a successful deletion variant, the author explicitly removes/revises that
example and explains why. Review includes the removed assertion as well as the
deleted fact. A passing, intentionally changed specification is not forbidden by
an additional governance layer. Acceptance then removes both files from current
root while their prior forms remain in Git/history.

## 6. Implementation acceptance tests

Build this journey in the actual kernel with real MicroHs execution, starting
with load–compile–validate and extending it through evaluation and publication.
Keep the host schema-agnostic. Do not substitute a native Haskell fake for the
guest boundary or create another disposable prototype before integrating it.
Resolve the library-backed codec gate in ADR 0007 through representative runtime
values and actual pipes; an ASCII-only fixture or passing GHC build is insufficient.

The integration tests should exercise:

- Evaluation and acceptance in different processes; no invocation of the evolution
  on the accept path. Count fixture entry calls so an accidental rerun is observable.
- Addition, rename-by-ID, schema replacement and successful fact/source deletion;
  reopen from disk and assert files as well as decoded values.
- The second evolution's inherited required example failing as described above.
- Draft acceptance refusing; a raw source edit after Ready refusing the saved
  result; missing/corrupt candidate data producing useful distinct outcomes.
- Another commit advancing head between checking and publication; the conditional
  update refuses, and explicitly rebasing/evaluating the workspace permits retry.
- Two drafts plus unrelated staged/unstaged files; acceptance preserves them and
  does not publish their contents. Failure after ref update reports the new commit.
- Cache removal after acceptance; current reads and archived rationale still work.
- Process death after ref update, followed by an already-accepted diagnosis even
  without local candidates; later commits do not change the reported accepting commit.
- Listing after that interruption reports Accepted from Git. Reverting acceptance
  removes that diagnosis; a later re-acceptance reports its own introducing commit.
- Identical shared modules compiled once, conflicting definitions rejected during
  build preparation, and invalid proposed source still capturable for review.

No Web/MCP server, live provider, new wire parser, plugin manager or full method
registration system is needed for this first CLI journey. Those are not thereby
settled or removed from the product. In particular the review's query-effect,
registration, evidence-reference and wire-library questions remain separate work.

The owning ADRs define these boundaries; this fixture supplies concrete assertions
for their implementation rather than a parallel specification.
