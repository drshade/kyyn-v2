# Worked example: foundational requirement

## Situation

A previously single-user application must authenticate users. Authentication
affects Web routes, API calls, background operations, tests and configuration.
It establishes a boundary that future features must follow.

## 1. Open one requirement Issue

Issue `#500` records the unresolved capability:

```markdown
# Require authenticated identity for application access

## Desired capability

Every externally reachable application action has an authenticated identity,
and authorization decisions receive that identity explicitly.

## Motivation

The system is moving from a single trusted operator to several users.

## Observable outcome

- Anonymous requests cannot reach protected application behaviour.
- Web, API and background entry points use one identity model.
- Tests can construct identities without bypassing production boundaries.
- Existing data remains attributable after the transition.

## Open questions

- Identity source and session model
- Treatment of existing local-only operation
- Boundary between authentication and authorization
```

The cross-cutting contract and consequential assumptions make this significant
design work.

## 2. Accept the design through an ADR PR

Draft PR `#501` adds proposed ADR 0008, **Authenticated identity boundary**,
and uses `Refs #500`.

The ADR decides:

- which entry points require identity;
- the canonical identity passed into application operations;
- where credential/session handling ends and application authorization begins;
- how local and background operation identify their principal.

Review debate happens on PR `#501`. The decision authority resolves material
alternatives, the author updates the ADR, its status becomes `accepted`, and
the reviewed PR merges. Issue `#500` remains open with the requirement's
completion criteria; as work becomes active, each draft PR owns its own slice
and checklist.

For this worked example, implementation ultimately flows through these
coherent PRs:

1. identity types and application-operation boundary;
2. one complete authenticated Web journey;
3. API and background entry points;
4. migration of remaining routes and removal of implicit identity; and
5. system-level verification and documentation.

This list explains the example; it is not copied into the ADR or into five new
Issues. The Issue may link the active PRs for navigation without duplicating
their task lists.

## 3. Implement through several PRs

The team decides that one combined diff would be difficult to review. It uses
several PRs, all linked to Issue `#500` and ADR 0008.

### PR #502 — establish the identity boundary

```markdown
## Purpose

Implement ADR 0008's identity types and application-operation boundary.

## Related work

- Issue: Refs #500
- Governing ADR: ADR 0008, implementation slice 1

## Approach

Require an explicit principal at the shared operation boundary while leaving
external routes on their existing adapter until later slices migrate them.

## Review focus

- No application operation may synthesize an implicit user.
- The dormant boundary must not alter current external behaviour yet.
```

The merge leaves main correct: the new boundary exists, tests cover it and
unmigrated entry points still use an explicit transitional adapter documented
by the ADR.

### PR #503 — prove one complete journey

This draft PR implements one Web login-to-operation path end to end. It uses
`Refs #500`, updates its checklist as commits land, and proves that anonymous
access fails while authenticated identity reaches the shared operation.

Testing one representative vertical journey exposes boundary problems before
many routes adopt it.

### PR #504 — migrate remaining entry points

This PR moves API and background entry points to the accepted boundary and
removes the transitional adapter. It still uses `Refs #500` because final
system-level verification remains.

No Issues are opened for individual routes, middleware functions or test
fixtures. The active PR checklist and session plans own those tasks.

### PR #505 — close the requirement

The final PR:

- verifies every externally reachable entry point;
- adds the system-level regression matrix;
- updates public and contributor documentation;
- changes ADR 0008 from `accepted` to `implemented`;
- uses `Closes #500`.

The independent reviewer verifies the final repository against the Issue and
ADR. The decision authority merges because the PR changes the ADR's lifecycle.

## 4. Create follow-up Issues only when work leaves the programme

Suppose PR `#503` reveals that the account-settings page should show recent
sessions. That capability is useful but not required to establish the accepted
identity boundary. It is deliberately deferred and independently schedulable,
so it becomes a follow-up Issue.

By contrast, adding authentication to each required route is part of active PR
`#504`; those routes do not become separate Issues.

## Final trace

```text
Issue #500: authenticated identity requirement
  |
  +-- PR #501: accept ADR 0008
  +-- PR #502: identity boundary                 Refs #500
  +-- PR #503: one vertical authenticated path   Refs #500
  +-- PR #504: remaining entry points            Refs #500
  `-- PR #505: system proof + ADR implemented    Closes #500
```

Authentication is one foundational feature. The PRs are implementation slices,
not separate features merely because they merged separately.
