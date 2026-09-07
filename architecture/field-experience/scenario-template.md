# Scenario: <name>

## Product question

Which user journey or interface hypothesis does this test? Link relevant ADRs.

## Seed and setup — evaluator only

- Scenario/fixture revision; Kyyn/SDK/plugin versions.
- Initial accepted root and existing workspaces; required examples/views/tools.
- Synthetic evidence/provider behavior; disposable external destination, if any.
- Cold/warm cache; machine/runtime requirements; setup success check.
- New workspace creation only; cleanup/retention plan with exact target.

## Agent-facing task — copy into task.md

Write an ordinary user request with a concrete desired outcome and KB location.
Do not prescribe tool names, the step sequence or the evaluator's answers.
Include genuine constraints and known domain context the user would supply.

## Access and interaction conditions

- Natural authoring access or explicit MCP-only discovery condition?
- What public documentation, source files and other tools are available?
- Fresh model/harness session; no prior implementation conversation.
- Real human, scripted response or agent-simulated human? State which.
- Which actions are explicitly authorized for this disposable scenario?
- Time/cost stop conditions, and how to report unfinished work.

## Observable outcomes — evaluator only

State meaningful results and non-results, allowing multiple valid solutions.
Identify independent checks of state, diagnostics and generated artifacts.
Include a check against false success, lost uncertainty or unintended delivery.

## Reflection prompt — after task

What was clear? What took unnecessary work? Which errors helped or misled you?
What workarounds or non-MCP tools did you use, and why? What remains unfinished?
What one interface change would most improve this task? Refer to visible events;
do not provide hidden chain-of-thought.

## Privacy and comparison

Explain why fixture data is safe. Specify trace capture/redaction/retention.
Name the comparable baseline/variant, without showing it to the tested agent.
