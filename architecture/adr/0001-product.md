---
id: 0001
title: 'Kyyn is a runtime and design workbench'
---

# Kyyn is a runtime and design workbench


## Context

The useful asset is not just data. It includes the definitions, computations,
examples and working methods that make recurring knowledge work understandable.
Kyyn-v1 proves useful outcomes but wraps too many ordinary actions in governance.

## Decision

Build a local-first runtime and workbench for a human and their existing agent.
The KB owns its domain types, facts, validation, calculations, instructions,
tools and views. Kyyn owns loading, execution, discovery, candidates, acceptance
and operational integration. KBs may depend on Kyyn to execute.

Treat exploration and improved understanding as useful outcomes before reporting
or automation is complete. Preserve unknown and disputed domain values rather
than forcing every accepted fact to mean “verified true”. External schedulers
and agent harnesses call ordinary Kyyn operations; Kyyn does not autonomously
orchestrate agents. Explicitly invoked KB-authored agentic flows are proposed in
[ADR 0028](0028-agentic-workflows.md); they do not make the kernel an agent scheduler.

## Boundaries and alternatives

Reject a standalone-code requirement, a universal knowledge ontology, and a
general governance/workflow engine. Also reject “just a folder of scripts”: the
runtime must remove repeated loading, protocol, review and persistence work.
Trusted agents still benefit from explicit effects and visible consequences;
those conventions are not claims of hostile-code containment.

## Consequences and verification

A feature must support a journey in the scope document or justify a new one.
Apply the [architectural principles](../principles.md): be precise about the
simple path, not exhaustive about possible paths. A reviewed boundary is not
permission to build unused mechanisms behind it.
The training and reporting fixtures must remain ordinary KBs, with no finance
or training branches in kernel code. The human must be able to inspect and
challenge their meaning, not merely confirm an engine receipt.
