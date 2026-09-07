# Worked example: routine implementation bug

## Situation

A report accepts an inclusive date range, but records from the final day are
missing. The API documentation and existing product behaviour both say that
the end date is inclusive. No design decision is required.

## 1. Open the bug Issue

Issue `#101` records:

```markdown
# Report excludes records from the inclusive end date

## Observed behaviour

For `from=2026-08-01&to=2026-08-03`, records after midnight at the start of
3 August are excluded.

## Expected behaviour

The documented `to` date includes the whole calendar day.

## Reproduction or evidence

Create records at 2026-08-03 00:00 and 15:00, run the report and observe that
only the midnight record is returned.

## Relevant decisions

The report API documentation defines both dates as inclusive. No ADR changes
the normal date-range contract.

## Completion criteria

All records on the final date are included, records on the following date are
excluded, and the boundary has regression coverage.
```

## 2. Start implementation in a draft PR

An engineer reproduces the bug, creates `fix/inclusive-report-end-date` and
opens draft PR `#102`:

```markdown
# Include the complete final day in report ranges

## Purpose

Correct the implementation bug described by #101.

## Related work

- Issue: Closes #101
- Governing ADR: None; existing API documentation defines the behaviour.

## Approach

Convert the inclusive end date to an exclusive boundary at the start of the
following day before constructing the query.

## Implementation

- [x] Correct range construction.
- [ ] Add boundary regression tests.
- [ ] Run the complete gate.

## Review focus

- Time-zone handling at the day boundary.
- Overflow or invalid-date behaviour.
```

The developer's private plan contains the individual source files and test
commands. No implementation Issues are opened.

## 3. Verify and review

The PR adds tests for:

- the first instant of the final date;
- a later time on the final date;
- the first instant of the following date; and
- the configured time zone around a daylight-saving transition, if the project
  supports one.

The full project gate passes. An independent reviewer confirms that the fix
matches the documented contract and that the passing result belongs to the
final revision.

## 4. Merge and close

The reviewer or project maintainer merges PR `#102`. `Closes #101` closes the
Issue automatically.

No ADR was created or revised because the intended design never changed.
