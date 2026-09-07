# Worked example: the implementation is correct but the design is wrong

## Situation

The system submits a payment to an external provider. ADR 0042, **Payment
submission and retry**, says that a timed-out request should be retried.

A controlled run demonstrates this sequence:

1. the provider accepts a payment;
2. the response is lost and the client observes a timeout;
3. the system retries exactly as ADR 0042 requires; and
4. the provider creates a second payment.

The code implements the accepted design correctly. The design assumption that
timeout means non-submission is false.

## 1. Record the unresolved defect

The reporter opens Issue `#381`:

```markdown
# Payment may be submitted twice after an ambiguous provider timeout

## Observed behaviour

One customer action created two provider payments when the first accepted
request timed out before its response reached us.

## Expected behaviour

One customer action must result in at most one submitted payment.

## Reproduction or evidence

1. Allow the provider to accept payment attempt A.
2. Drop its response before the client receives it.
3. Observe the timeout retry required by ADR 0042.
4. Observe two provider payment identifiers for attempt A.

## Relevant decisions

ADR 0042 currently treats timeout as a failed submission and permits retry.

## Completion criteria

An ambiguous response cannot cause blind resubmission, and the original
failure sequence is covered by an end-to-end regression test.
```

The Issue owns the unresolved defect until the software behaves correctly.

## 2. Confirm the class of defect

An engineer inspects the implementation and adds this conclusion to `#381`:

```markdown
Confirmed: the timeout path implements ADR 0042 as written. The false
assumption is in the accepted design, so a local retry patch would leave the
governing decision wrong. I will propose a revision to ADR 0042.
```

If ADR 0042 already prohibited blind retry, the work would instead follow the
routine-bug example.

## 3. Open a draft design PR

The engineer creates `design/payment-timeout-recovery` and opens draft PR
`#382`:

```markdown
# Revise ADR 0042 for ambiguous payment outcomes

## Purpose

Issue #381 disproves ADR 0042's assumption that timeout means the provider did
not accept the request.

## Related work

- Issue: Refs #381
- Governing ADR: ADR 0042

## Approach

Revise ADR 0042 in place because this remains the same architectural concern:
payment submission and retry. Introduce stable payment-attempt identity,
idempotent submission and explicit reconciliation of ambiguous outcomes.

This PR changes the design. It does not change the running software and does
not close #381.

## Verification

- ADR metadata lint passes.
- The ADR contains one unambiguous current design.

## Review focus

- Whether any path can still infer non-submission from a timeout.
- Whether delayed provider visibility is represented honestly.
```

The PR updates ADR 0042 rather than creating another payment ADR. It preserves
one place for the current payment-submission decision.

## 4. Revise the existing ADR

On the design branch, ADR 0042 changes from `implemented` to `proposed` while
the revision is under review. Its active sections propose:

```markdown
## Context

A provider may accept a request without its response reaching the client. A
timeout therefore does not prove submission failed. Issue #381 demonstrates
that the former assumption can create duplicate payments.

## Decision

Create a durable, stable attempt identity before external submission. Use it
as the provider idempotency key where supported.

A timed-out submission becomes Indeterminate. The system must observe and
reconcile that attempt. It must not resubmit until the provider has established
that submission did not occur.

An empty or delayed observation is not proof of absence.

```

The ADR's `date` is updated for the proposed revision. The obsolete instruction
is removed completely; it does not remain as apparently concurrent guidance.
Git history, Issue `#381` and PR `#382` preserve the former wording and why it
changed.

## 5. Review and decide on the design PR

The independent reviewer reads Issue `#381`, ADR 0042, the relevant code and
provider semantics. They comment on PR `#382`:

```text
The proposal assumes an empty provider lookup proves absence. What prevents a
duplicate submission while the provider's read side is temporarily behind its
write side?
```

The author updates the ADR to distinguish `ConfirmedAbsent` from
`NotYetObservable`. A material policy question remains, so the project decision
authority records the decision:

```text
Keep the attempt Indeterminate while observation is inconclusive. Do not
automatically resubmit based on an empty lookup result.
```

The author incorporates that conclusion into ADR 0042. The PR thread contains
the debate; the ADR contains the durable result.

Before merge, ADR 0042 is changed from `proposed` to `accepted`. The reviewer
rechecks the final revision and gate. The decision authority merges PR `#382`.

That merge means:

- the revised design is authoritative;
- ADR 0042 is accepted but not yet implemented;
- the software defect remains; and
- Issue `#381` remains open.

## 6. Begin active implementation

An implementer creates `fix/payment-timeout-recovery` and opens draft PR `#383`
after its meaningful first commit:

```markdown
# Make payment submission idempotent across ambiguous outcomes

## Purpose

Implement the revised ADR 0042 and resolve the duplicate-payment path in #381.

## Related work

- Issue: Closes #381 when the complete change merges
- Governing ADR: ADR 0042

## Approach

Persist a stable attempt before submission, bind provider operations to it and
replace blind timeout retry with observation-driven reconciliation.

## Implementation

- [x] Add durable payment-attempt identity and lifecycle.
- [ ] Bind provider submission to stable attempt identity.
- [ ] Reconcile indeterminate outcomes without blind retry.
- [ ] Add the end-to-end regression from #381.
- [ ] Mark ADR 0042 implemented when all properties hold.

## Verification

Focused lifecycle tests pass. Full gate and end-to-end recovery test remain.

## Review focus

- No path may resubmit while an attempt is Indeterminate.
- Attempt identity must survive restart.
```

The agent uses its private session plan for individual handlers, types, fixtures
and test commands. Those minutiae do not become Issues.

As commits land, the author keeps the durable PR checklist and verification
section current.

## 7. Handle discoveries without overloading Issues

While implementing, the agent discovers that an operations dashboard could
display indeterminate attempts more clearly. The backend can still meet ADR
0042 and Issue `#381` without redesigning that dashboard.

Because the dashboard improvement is independently valuable and deliberately
outside PR `#383`, the agent opens follow-up Issue `#384` and links it under
the PR's deferred work.

By contrast, adding the lifecycle enum, updating a timeout handler and repairing
fixtures remain session or PR tasks. They do not become Issues.

## 8. Verify the original failure

PR `#383` eventually records this end-to-end test:

1. stable attempt A is persisted;
2. the provider accepts A;
3. its response is lost;
4. the application restarts;
5. the first observation is inconclusive;
6. the application does not resubmit;
7. a later observation finds the accepted payment; and
8. local state converges with exactly one provider payment.

The complete project gate passes for the final PR revision. ADR 0042 is changed
from `accepted` to `implemented`. The separately tracked dashboard improvement
remains solely in its Issue because it is outside this PR and does not belong in
the ADR.

## 9. Review, merge and close

The reviewer verifies the code, revised ADR, original evidence and regression
test. Findings are resolved on PR `#383`, and the reviewer rechecks the final
head.

Because the PR marks an ADR implemented, the project's decision authority
merges it after independent review.

GitHub closes Issue `#381` through `Closes #381`. Issue `#384` remains open
because it represents intentionally deferred work, not an incomplete task
hidden inside the merged PR.

## Final trace

```text
Issue #381: duplicate payment after timeout
  |
  +-- PR #382: revise ADR 0042
  |     `-- merged: corrected design accepted
  |
  `-- PR #383: implement and verify ADR 0042
        |-- merged: ADR 0042 implemented
        |-- closes #381
        `-- links deferred dashboard Issue #384
```
