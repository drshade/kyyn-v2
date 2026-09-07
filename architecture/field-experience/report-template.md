# Field report: <scenario / run identity>

This is a template, not evidence of an executed run.

## Conditions

Date; scenario/fixture revision; Kyyn/SDK/tap identities; model/harness/settings;
fresh-session condition; actual tool catalog/access; cache condition; budget;
exact task prompt; who played each role; instrumentation gaps.

## Observed outcome

Completed, partial, failed, cancelled or assisted? Which requested outcomes
actually hold? Which remain? State the independent checks, resulting root/
candidate/artifact identities and any external effects. Distinguish “agent said
done”, “checks passed” and “human found the result useful”.

## Instrumented journey

Summarize phases, discovery/invocation counts, elapsed times, response volume,
error/retry patterns, human interventions and observed off-surface operations.
Link sanitized evidence for the important incidents. Do not paste secrets,
private payloads or hidden reasoning. Leave unavailable metrics unknown.

## Agent experience account

Preserve the agent's post-task account: clear/confusing parts, workarounds,
unfinished work and suggested improvement. Attribute it as self-report; do not
silently rewrite it to agree with telemetry or the reviewer.

## Human experience, if exercised

What could the human understand, design and review? What context was lost in
handoff? State whether this was observed with a real human or only simulated.

## Synthesis

| Incident / evidence | Interpretation and uncertainty | Proposed change | Follow-up / rerun |
| --- | --- | --- | --- |
| <observable event> | <product, domain, agent or harness issue?> | <smallest useful improvement> | <issue/ADR/scenario> |

Record contradictions between telemetry, final state and the agent's account.
Compare similar runs without claiming statistical significance from one attempt.

## Retention and corrections

Where sanitized evidence is retained; private trace retention/expiry if relevant.
Append dated corrections and follow-up links; preserve the original run outcome.
