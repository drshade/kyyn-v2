# Worked example: contained requirement

## Situation

Users can view a report in the application and now need to download the same
result as CSV. The report query, authorization boundary and extension pattern
already exist.

## 1. Open the requirement Issue

Issue `#210` records:

```markdown
# Export the existing customer report as CSV

## Desired capability

An authorized user can download the currently filtered customer report as a
CSV file.

## Motivation

Users need to analyse the same result in spreadsheet tools.

## Observable outcome

- The export contains the same rows and filters as the on-screen report.
- Column names and order are documented and stable within the current API.
- Values with commas, quotes and newlines round-trip correctly.
- Existing report authorization applies unchanged.

## Known constraints and affected areas

Use the existing report query and download-response abstraction. Do not create
a separate authorization or filtering path.
```

Triage confirms that existing architectural decisions determine the approach.
No ADR is needed merely because this is a new feature.

## 2. Check whether existing decisions need updating

The implementer reads the reporting ADRs before starting. Suppose ADR 0055,
**Reporting boundary**, establishes the shared query, authorization and
representation extension points without limiting reports to on-screen use.
The CSV export follows that current decision, so the ADR needs no change.

If ADR 0055 instead said that reports are available only for viewing, or
otherwise described an exhaustive boundary that the export changes, leaving
it untouched would make the ADR incomplete or misleading. Revise that ADR in
place so it states the resulting current design.

When the accepted design already determines the implementation, that
documentation correction can be included in the implementation PR. Use a
preceding design PR only if enabling download requires a significant new or
revised decision. Contained scope does not excuse stale governing
documentation, but neither does every new capability require design ceremony.

## 3. Open the active draft PR

The implementer opens draft PR `#211`:

```markdown
# Add CSV export for the customer report

## Purpose

Provide the contained export capability requested in #210.

## Related work

- Issue: Closes #210
- Governing ADR: Existing report and download boundaries; no new ADR.

## Approach

Feed the existing filtered report result into the established download
response and a streaming CSV encoder.

## Implementation

- [x] Add CSV representation of the existing report rows.
- [ ] Add the download route through the existing authorization boundary.
- [ ] Cover quoting, newlines and empty results.
- [ ] Document the exported columns.
- [ ] Run the complete gate.

## Review focus

- The export must not reimplement filtering or authorization.
- CSV escaping and content type must be correct.
```

The checklist is durable because it helps collaborators understand the feature
boundary. Individual functions and test invocations remain in the agent's
session plan.

## 4. Keep the boundary coherent

During implementation, the author discovers that exporting a million rows is
slow. The current requirement has no demonstrated need for that scale and the
existing on-screen report is already bounded.

The PR retains the established bound and documents it. A speculative
high-volume export subsystem is not added. If a real large-export requirement
arrives later, it will become a new Issue and may warrant its own decision.

## 5. Verify, review and merge

The final PR proves that on-screen and exported row identities match for the
same filter, exercises CSV edge cases and runs the complete gate. An independent
reviewer examines the final head and the reuse of existing boundaries.

PR `#211` merges and closes Issue `#210`.

This feature may contain hundreds of lines, but it remains contained because it
does not introduce a new system-wide assumption or contract.
