# Boundary map

Use this map to find the owning decision, not as a second interface specification.

| Question | Owning decision |
| --- | --- |
| Where do effects, native IO and interpreter composition belong? | [0003 — effects](adr/0003-effects.md) |
| Which package owns a module? | [0026 — repository layout](adr/0026-repository-layout.md) |
| How does the bundled guest execute? | [0002 — runtime](adr/0002-runtime.md), [0007 — wire](adr/0007-wire.md), [0009 — capabilities](adr/0009-capabilities.md) |
| What are KB, root, workspace and candidate? | [0004 — knowledge base](adr/0004-knowledge-base.md), [0010 — evolutions](adr/0010-evolutions.md) |
| What can the schema-agnostic host inspect and persist? | [0005 — contracts](adr/0005-contracts.md), [0006 — storage](adr/0006-storage.md) |
| What gets checked and accepted? | [0011 — validation](adr/0011-validation.md), [0012 — acceptance](adr/0012-acceptance.md), [0013 — collaboration](adr/0013-collaboration.md) |
| How do sources, evidence and authentication interact? | [0014 — evidence](adr/0014-evidence.md), [0015 — plugins](adr/0015-plugins.md), [0016 — connections](adr/0016-connections.md) |
| How are external outputs produced? | [0017 — outputs](adr/0017-outputs.md) |
| How do authored tools and agentic flows compose? | [0008 — authoring](adr/0008-authoring.md), [0027 — judgements](adr/0027-judgement.md), [0028 — agentic workflows](adr/0028-agentic-workflows.md) |
| What do clients share and how do failures surface? | [0018 — surfaces](adr/0018-surfaces.md), [0019 — failures](adr/0019-failures.md), [0023 — interaction](adr/0023-interaction.md) |

For actual effect rows and handlers, read the capability and interpreter modules
in the [host packages](../host). The [import checker](../tools/checks/check-imports.mjs)
checks their allowed dependency boundaries. Examples in ADRs describe the selected
architecture; they are not a parallel inventory of current module names.
