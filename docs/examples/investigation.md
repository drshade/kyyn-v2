# Worked example: bounded investigation

## Situation

A requirement says the existing database must return a new analytical query in
under two seconds. The team does not yet know whether the current storage model
can meet that expectation.

## 1. Open an investigation Issue

Issue `#620` records:

```markdown
# Determine whether the current database can meet the analytical query target

## Question

Can the current storage model execute the representative analytical query in
under two seconds at the expected data volume?

## Why it matters

The answer determines whether requirement #619 can use the current query path
or needs a significant storage decision.

## Investigation boundary

Measure the current schema with representative synthetic volumes and the two
credible index variants. Do not redesign the storage layer or ship prototype
indexes to production.

## Evidence sought

- Query plans
- Warm and cold execution distributions
- Index size and write-cost effect
- The point at which the target is no longer met

## Stopping condition

Stop after the baseline and two index variants have been measured at the three
agreed data volumes, even if none meets the target.
```

The bounded question prevents an open-ended optimisation project.

## 2. Run the experiment without pretending it is production work

The investigator uses a disposable branch, notebook or script as appropriate.
If the experiment needs reviewable repository changes—for example a reusable
synthetic fixture—it may use a draft PR linked with `Refs #620`.

Prototype code is not merged merely because it exists. The session plan owns
individual experiments and commands.

## 3. Record the conclusion on the Issue

The investigator adds a concise result to `#620` with enough evidence for
another engineer to assess it:

```markdown
Conclusion: the current schema plus index variant B meets the target through
the expected two-year volume. Variant A does not. At five-year volume neither
variant meets it.

The current requirement is bounded to two years, so no storage redesign is
needed. The reusable synthetic fixture is proposed in PR #621.
```

If this conclusion simply enables contained implementation, Issue `#620`
closes with the evidence and requirement `#619` proceeds to its draft PR.

If the result instead requires choosing a new storage model, the investigator
opens a design PR proposing an ADR and references both Issues. The ADR records
the significant decision; the investigation Issue remains the evidence rather
than becoming a design document.

## Possible endings

```text
Investigation Issue
  +-- conclusion only ----------------------> close
  +-- reusable supporting change ----------> PR -> close
  +-- significant decision required -------> ADR PR
  `-- implementation now understood -------> implementation PR
```

An investigation that disproves the hoped-for approach is still complete when
it answers the bounded question honestly.
