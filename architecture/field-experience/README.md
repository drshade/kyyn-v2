# Field-experience templates

Use these when assessing how an unfamiliar agent or human experiences Kyyn:

- [Scenario card](scenario-template.md): setup, ordinary task, access conditions
  and independently observable outcomes.
- [Report template](report-template.md): observed results, the agent's experience
  account, human feedback where exercised, and reviewer synthesis.

[ADR 0024](../adr/0024-field-experience.md) owns the method, instrumentation and
privacy rules. These templates are not an implemented harness or evidence that a
scenario has run. Select a journey from [product scope](../scope.md), use synthetic
data and disposable destinations, and state which surfaces actually exist in the
build being tested. A CLI test does not establish Web or MCP usability.

Keep evaluator setup/checks separate from the agent's task. Give the agent the
normal documentation and discovery tools, not a prescribed command sequence.
Record setup identity, build and scenario revisions, model/harness settings,
warm/cold cache state and any assistance. Leave unavailable measurements unknown.

Keep failed and partial outcomes visible. Link findings to concrete incidents and
issues; append corrections rather than rewriting a failed run into success.
