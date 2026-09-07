# Field-experience testing

Proposed method under [ADR 0024](../adr/0024-field-experience.md). This folder
contains specifications/templates, not an implemented harness or executed reports.
It adapts the useful two-part practice in
[kyyn-v1's scenarios](../../../kyyn/field-scenarios/README.md), without inheriting
mandatory owner-only verbs, causal receipts or its SDLC release queue.

## A scenario is an outcome, not a tool recipe

Proposed scenario package contents:

```text
scenarios/<name>/
  scenario.md          experiment card; evaluator/setup information
  task.md              only the task given to the fresh agent
  kb/                  synthetic initial KB, code, contracts, examples, lock
  evidence/            synthetic provider responses or local documents
  checks/              outcome checks independent of the agent's success claim
```

There is no requirement to generate these folders before we have a runnable
implementation. Setup must refuse an existing destination, create a disposable
workspace and record its identity. It must not solve the task, preselect the
tool sequence or inject private implementation knowledge. Public fixtures are
invented from first principles, not lightly anonymized business datasets.

Some tasks assess discovery from an empty template; others start with a configured
KB and test routine reuse, schema change or repair. Both are important. State
exactly what the agent is expected to know and which ordinary docs it can discover.

## Initial scenario catalog

| Scenario | Seed and task | What we want to learn |
| --- | --- | --- |
| Install and open | Clean supported environment; agent installs Kyyn and opens a selected synthetic KB for a human | Toolchain/configuration burden, readiness diagnostics, actual browser and MCP connection |
| First useful model | Blank KB plus tidy synthetic renewals input; create model and reviewable proposal | Discovery and schema/tool authoring cost |
| Training refresh | Configured training KB; duplicate/corrected observations and unknown attendance | Existing helper reuse, stable identity, paging and uncertainty |
| Model evolution | Training KB; add vendor-delivery distinction and remove an old status | Typed migration, error repair, data/view preview |
| Exact reporting | Configured reporting KB; policy change, optional-confidence schema evolution and a multi-request anomaly tool | Exact arithmetic, migration, typed host requests, shared calculations and human counterexamples |
| Haskell contract authoring | Author a union/optional/reference shape using the selected Haskell surface and its discovery/scaffolding | Compiler/codegen diagnostics, unsupported-shape recovery and authoring friction |
| Headless repeat | Settled synthetic reporting workflow with explicit acceptance intent, no Web/MCP server | Repeatability, structured failures, draft survival and local-head conflict handling |
| Contract drift | Upgrade a fixture plugin with an intentionally changed response | Detect, rediscover contract, regenerate binding and repair consumer |
| Evolution rebase | Local head advances before acceptance; agent updates Before and reruns checks/diffs | Clear base mismatch and author-directed repair without a new proposal |
| Upstream conflict | Two disposable clones accept locally; second push is rejected | Clear distinction between local success and user/agent Git resolution |
| Publication interruption | Prepared synthetic artifact; disposable sink gives uncertain response | Honest outcome and no blind duplicate delivery |

The training/reporting shapes come from [scope](../scope.md), not copied private
facts. First useful model is deliberately low domain ambiguity; more realistic
tasks assess judgment separately so we do not blame every difficulty on MCP.

## What the harness records

Capture both discovery (`tools/list`, resource/schema access) and invocations.
Keep an event sequence/correlation ID, method identity, start/end time, selected
KB/root/workspace identity, outcome/error code, and request/response size. Native
operation IDs allow distinguishing slow compilation/provider work from repeated
agent discovery. Measure tool-call counts by task phase, not just one total.

For wholly synthetic fixtures, opt-in full requests/results can support diagnosis.
For other data, default to redacted summaries and retain raw artifacts privately
only by explicit choice. Omit secret lookup response values and HTTP headers,
URLs and bodies even in synthetic runs, as required by ADR 0016's host logging
boundary. Do not claim this detects every secret copied into arbitrary plugin
output. Document
what instrumentation cannot see: private reasoning, unobserved shell commands,
provider state and time spent outside the harness. Do not infer them from gaps.

Record model/harness identifier and settings, prompt/tool catalog, runtime/SDK/tap
versions, scenario revision, warm/cold caches, duration, explicit budget/stop
condition and any human assistance. Count tokens/cost only if actually available;
unknown is not zero. For repeated trials keep model and scenario conditions fixed
where possible and report variability, not only the best run.

Observer failures must be visible. Do not quietly change application behavior
to keep telemetry neat. Trace capture should not add agent-visible instructions,
new approvals or accepted-fact metadata. Public reports reference sanitized
event excerpts, outcomes and artifact identities, not sensitive raw transcripts.

## Assessment and report

Before the reflection, inspect no hidden reasoning. Ask the agent about what
was clear, misleading, repetitive or impossible, which workarounds it used, and
what would have helped. Then compare that account with observed calls and final
state. Record contradictions honestly: “agent reported all done; one collection
remained unprocessed” is a finding, not permission to edit the task retroactively.

Outcome checks permit different valid domain models/names. Do not reward matching
the author's exact architecture or require a hidden golden tool trace. Report:

- correctness/completeness of the requested outcome;
- discovery and technical work needed to achieve it;
- quality of errors and recoveries;
- appropriate handling of ambiguity and human input;
- source/CLI escapes and whether they were normal authoring or workarounds;
- human visibility and fidelity of the handoff, where actually exercised.

Classify findings provisionally as product defect, interface friction, absent
capability, domain ambiguity, agent error or harness limitation. The reviewer can
disagree with the agent's diagnosis. Pair a proposed improvement with concrete
evidence and a rerun condition. Some findings need only documentation or a better
example; not every finding deserves a new capability or ADR.

## Feedback loop

```text
versioned scenario -> fresh attempt -> telemetry + experience account
                                      |
                              independent assessment
                                      |
                         design discussion / issue / ADR
                                      |
                          implementation and regression test
                                      |
                           comparable fresh scenario rerun
```

Keep reports as honest records, including unsuccessful attempts. Append corrections
or link a follow-up; never replace the original outcome with a later success.
Use the [scenario card](scenario-template.md) and [report template](report-template.md).
Architecture/interface changes should select relevant field scenarios; this is
feedback practice, not a universal ceremony for every documentation typo.
