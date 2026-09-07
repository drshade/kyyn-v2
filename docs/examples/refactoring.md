# Worked example: refactoring

## Situation

A developer is already working in a large report module and can separate its
query construction from rendering without changing intended behaviour. The
change follows existing module boundaries and can be completed now.

## 1. Decide whether an Issue or ADR adds value

No Issue is required merely to authorize a PR. The work is not being deferred,
prioritised later or handed to another effort; it is immediately active.

No ADR is required because the refactor applies an existing boundary rather
than establishing a new architectural rule.

The developer opens draft PR `#610` directly:

```markdown
# Separate report query construction from rendering

## Purpose

Make the existing report module easier to change by separating query
construction from output rendering without changing behaviour.

## Related work

- Issue: None; this work moved directly into active implementation.
- Governing ADR: Existing report module boundary; no new decision.

## Approach

Move query construction mechanically, preserve the public interface, then
redirect rendering through the extracted component.

## Implementation

- [x] Move query construction without semantic edits.
- [ ] Redirect the renderer through the extracted boundary.
- [ ] Confirm existing behaviour and tests remain unchanged.

## Review focus

- Distinguish mechanical movement from behavioural changes.
- No new public interface or dependency direction.
```

## 2. Keep mechanical and behavioural work distinguishable

The author uses separate commits for the mechanical move and the call-site
change. A project might instead use two PRs if the diff is large enough that
separation materially improves review.

The point is not a universal commit rule. The reviewer must be able to tell
whether behaviour changed.

## 3. Review and merge

The existing gate passes. The reviewer compares the old and new boundaries,
checks for hidden semantic edits and confirms that documentation remains
accurate. PR `#610` merges without closing an Issue.

## When the path would change

Use an Issue if the refactor is identified now but will be scheduled later,
must coordinate several active changes, or has an independently valuable
maintainability outcome.

Use an ADR if the work introduces a new architectural boundary, reverses a
dependency direction or establishes a pattern future modules must follow.

Code volume alone determines neither choice.
