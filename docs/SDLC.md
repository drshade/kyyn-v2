# Software Development Lifecycle

This document is the authoritative software-development process for this
repository. It defines how unresolved work becomes a decision, an active
change, a reviewed merge and, where applicable, a release.

Supporting instructions, templates and examples must agree with this document.
Project-specific choices live in `PROJECT-PRACTICES.md` and may tailor only the
points this document leaves configurable.

## 1. Scope

This baseline covers the common software change lifecycle. It does not
prescribe specialist organisational or assurance practices; a project may
extend it when its product, customer or environment requires more.

## 2. The lifecycle

```text
unresolved work -> Issue -> decide whether design work is required
                              |
             +----------------+----------------+
             |                                 |
             v                                 v
      implementation ready             design PR + ADR
             |                                 |
             |                          accepted decision
             +----------------+----------------+
                              |
                       draft implementation PR
                              |
                    implement + verify + review
                              |
                             merge
                              |
                  close the Issue when resolved
                              |
                       release when applicable
```

Feedback from any stage may create another Issue or expose a decision that must
be revised.

## 3. One source of truth for each kind of state

| Artifact | Owns | Does not own |
| --- | --- | --- |
| GitHub Issue | An unresolved problem, requirement or investigation | Active implementation minutiae |
| ADR | A significant decision: authoritative desired architecture | Implementation status, undecided options or backlog |
| Draft PR | Active implementation, its meaningful checklist and current state | Deferred work outside the change |
| PR review | Examination and discussion of the proposed repository change | The durable wording of a decision |
| Session plan | Temporary, fine-grained execution steps | Durable project state |
| Git history and release records | Landed changes and published releases | Unresolved work |

## 4. Issues own unresolved work

Open an Issue when a bug, requirement or investigation needs to be remembered,
discussed, prioritised or completed later and no active PR already owns it.

A useful Issue records:

- the problem or desired outcome;
- why it matters;
- evidence, reproduction steps or relevant context;
- known constraints and related decisions; and
- observable completion criteria.

An Issue may produce one PR, several PRs or no code at all. It remains open
until its outcome is satisfied or deliberately declined. Accepting a design
does not close the Issue whose software outcome remains unimplemented.

Do not create Issues for ordinary implementation steps such as adding a field,
editing a handler or writing a test. Keep those in the developer's session plan
or, when useful to collaborators, in the draft PR checklist.

Create another Issue when discovered work must outlive the active PR: it is
deliberately deferred, independently valuable, separately schedulable, owned by
another effort, or outside the current change's correct boundary.

## 5. Significant decisions are ADRs

Use an ADR when a choice:

- changes an architectural boundary or important contract;
- establishes a pattern that several areas or future changes will follow;
- rests on an assumption whose failure would materially change the system;
- has substantial compatibility or migration consequences; or
- is difficult to reverse and has credible alternatives worth recording.

Routine bugs, contained features, local refactoring and implementation choices
do not need ADRs when the existing design already determines their shape.

### ADRs describe decided desired state

An ADR defines the architecture the implementation must satisfy, whether the code
already exists or remains to be built. A single ADR may contain both, so it has no
implementation status. Issues and PRs track outstanding outcomes; code and tests
establish actual behavior. Git history records when the decision changed.

Interleave concrete high-level types, signatures and effect rows with the prose
that explains them. They specify ownership, inputs, results, permitted dependencies
and failure behavior, not illustrative alternatives that implementers may ignore.
Omit private representations and routine detail explicitly; do not omit the
boundary being decided. Other ADRs reference the owner rather than redefine its
contract.

Reconciliation compares actual code and tests with that desired state. Correct
stale documentation where the decision is already clear; record implementation
gaps as unresolved outcomes; raise genuinely different design choices for decision.
Do not silently redefine the architecture to match incidental implementation.
Undecided options and possible future work belong in Issues or design discussion,
not in the authoritative ADR.

### Revise decisions in place

Revise the existing ADR when the same architectural concern evolves. Rewrite
its active sections so they contain only unambiguous current guidance, and
remove obsolete instructions completely.

Git history, the motivating Issue and the design PR preserve the former wording
and its rationale. If a decision no longer applies, delete its ADR in the same
change that removes or replaces the governed behaviour. Never reuse its number.

### Design review is a PR

A design change is proposed through a PR that updates the ADR and references
the motivating Issue. Reviewers examine the evidence, alternatives and
consequences. Discussion happens on the PR, but every material design
conclusion must be incorporated into the ADR.

The project-defined decision authority merges an ADR acceptance or revision
after independent review. That merge makes the design authoritative; it does
not claim that the software is already implemented or close the motivating
Issue.

## 6. Active implementation belongs to a draft PR

Implementation happens on a dedicated branch or equivalent isolated workspace.
Before editing, inspect its state and preserve unrelated changes.

Open a draft PR once active implementation has a meaningful starting point.
Its description should state:

- the outcome being advanced;
- the governing Issue and ADR, if any;
- the chosen approach;
- a checklist of meaningful implementation components when useful;
- current verification evidence;
- what reviewers should scrutinise; and
- deliberately deferred work.

The developer or agent keeps finer-grained steps in a private session plan.
Update the PR description as commits change its approach or state.

A requirement may need several PRs without needing several Issues. Split PRs
when doing so makes each change easier to understand, verify or integrate and
each merge leaves the repository correct. Earlier PRs reference the Issue; the
PR that establishes the completion criteria closes it.

## 7. Verification is proportional to the change

`PROJECT-PRACTICES.md` identifies the verification entry points and setup. The
scripts select suites; coverage belongs in the test entry files' header comments,
not a parallel inventory in the process document.
The author chooses proportionate verification and records the tested revision,
commands and results in the PR. No blanket test command or remote CI run is required
for every PR. Independent review is the merge gate. A fix-sized Issue closes on
focused checks and an installed journey covering the changed behavior. For a
large outcome, run the full integration check on its terminal PR before closing
the Issue.

The project decides what the gate contains. Common components include
formatting, compilation, linting, unit tests, integration tests, contract tests
and documentation validation.

A passing gate is evidence about the exact revision that ran it. It is not
permission to merge. When a PR changes the gate itself, demonstrate that the
new check detects the condition it claims to prevent.

Use proportionate additional verification when automation cannot establish the
changed behaviour. Record the relevant evidence in the PR; do not invent a
mandatory manual ceremony for changes that automated checks already prove.

## 8. Independent review examines the change

A PR is reviewed by someone other than its author. The reviewer works from the
Issue, ADR, diff, code and verification evidence rather than trusting the PR's
summary alone.

Review establishes:

- the change addresses the stated outcome;
- it follows relevant accepted decisions;
- important failure cases and boundaries were considered;
- the repository remains coherent and maintainable;
- tests and documentation changed where behaviour changed; and
- recorded verification applies to the change under review.

Reviewers assess the change and the author's evidence; they do not routinely
repeat local tests, clean-export builds or remote CI. Request or run additional
targeted checks when a concrete concern warrants them, not as a default ceremony.

Findings and discussion live on the PR. The author updates the implementation,
PR description and any governing documentation as required. The reviewer
re-examines the resulting final revision.

Green automation is evidence, not authority. Independent review remains the
merge control.

## 9. Merge and completion

A PR may merge when:

- its intended outcome and boundary are clear;
- proportionate verification evidence is recorded and any concrete concerns resolved;
- independent review is complete;
- material findings are resolved; and
- relevant documentation represents the resulting behaviour.

Use `Refs #N` or equivalent when a PR advances an Issue without resolving it.
Use `Closes #N` only when the merge satisfies that Issue's completion criteria.

The final implementation PR records evidence that the governing decision is
satisfied and closes the resolved Issue. It does not change ADR metadata to
announce implementation. If required verification can happen only after merge,
record that evidence on the Issue before closing it.

Newly discovered work outside the correct PR boundary becomes a follow-up
Issue. Do not expand a coherent change indefinitely merely to avoid recording
future work.

## 10. Releases are recorded and repeatable

Projects that publish releases keep their release procedure in the repository.
At minimum, a release:

- comes from a reviewed, clean and identifiable revision;
- passes the project gate;
- records what changed;
- receives an immutable version or tag; and
- avoids relying on unrecorded operator memory.

The project chooses its versioning, cadence, distribution channels and degree
of automation in `PROJECT-PRACTICES.md` or a linked runbook. Projects that do
not publish releases state that explicitly.

## 11. Feedback returns to unresolved work or design

A defect, user observation, test failure or development friction may create:

- an ordinary Issue when the accepted design is clear and implementation is
  wrong;
- an ADR revision when the implementation is correct but an accepted design
  assumption is wrong; or
- an investigation Issue when the cause or appropriate outcome is not yet
  known.

The worked examples under `examples/` demonstrate these paths mechanically.
They are yardsticks, not required numbers of Issues, PRs, commits, files or
days.

## 12. Tailoring and extension

Projects record configurable mechanics in `PROJECT-PRACTICES.md`: repository
host, workspace convention, verification entry points, CI, review requirements,
merge strategy and release approach.

Additional practices may extend this lifecycle for a particular context. They
must state when they apply, where their authority lives, what they add to
verification or review, and how they relate to Issues, ADRs and PRs. They must
not silently redefine the baseline sources of truth.
