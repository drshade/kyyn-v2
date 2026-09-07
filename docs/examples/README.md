# Worked examples

These examples show how the SDLC flows mechanically through GitHub. They are
yardsticks, not required numbers of Issues, PRs, commits, files or days.

Magnitude is semantic. Consider:

- whether intended behaviour is already established;
- whether implementation or design is wrong;
- whether the effect is local or cross-cutting;
- whether a contract or architectural boundary changes;
- whether the choice establishes a future pattern;
- whether work must land in a particular order; and
- whether each proposed merge can be verified independently.

A ten-line contract change may be foundational. A large implementation behind
an established extension boundary may be contained.

## Scenarios

| Scenario | Starting artifact | ADR? | Typical active work |
| --- | --- | --- | --- |
| [Routine bug](routine-bug.md) | Bug Issue | No, when intended behaviour is clear | One draft PR |
| [Design defect](design-defect.md) | Bug Issue plus existing ADR | Revise the existing ADR | Design PR, then implementation PR |
| [Contained requirement](contained-requirement.md) | Requirement Issue | Usually no | One or a few PRs |
| [Foundational requirement](foundational-requirement.md) | Requirement Issue | Yes | Design PR, then several coherent PRs |
| [Refactoring](refactoring.md) | Optional Issue or direct draft PR | Only for a new architectural boundary | One or more reviewable PRs |
| [Investigation](investigation.md) | Investigation Issue | Only if the conclusion requires a decision | Evidence first; code may never merge |

A feature is a coherent capability, not a repository artifact. It may span
several PRs without becoming several features. Artifact responsibilities come
from [SDLC §3](../SDLC.md#3-one-source-of-truth-for-each-kind-of-state).
