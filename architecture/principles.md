# Architectural principles

These are the standing design/review rules for Kyyn, distilled from the owner's
direction. The [index](README.md) navigates the decisions; [scope](scope.md)
identifies the work the product must support; individual ADRs explain concrete
decisions with types and signatures. These principles guide those decisions,
not a new approval process or runtime mechanism.

## Be precise about the simple path, not exhaustive about possible paths

Specify the inputs, results, effects and failure behavior of the path we actually
need. Precision should remove ambiguity, not create mechanisms for hypothetical
cases. One whole-contract identity is preferable to separate compatibility rules
for presentation edits when regeneration already supplies a working repair path.

Do not add a cache, fast path, alternate backend or extra lifecycle simply because
it could be useful. Let measured workloads and human/agent experience establish
the problem first. If a simpler implementation supports the required journey,
use it. Correctness requirements still apply to whatever we do implement.

## Persist one current format

Kyyn-owned persisted data has one current format, with no format-version fields,
version dispatch, compatibility readers, legacy detectors or migration hints.
Decode against the current structure and report ordinary parse/type errors.
Do not invent missing fields to make an older representation readable. Integrity
checks for identities, contracts and required data still apply. External API
versions and dependency versions are separate concerns.

## Exercise judgment; challenge guidance that defeats its purpose

Principles and ADRs guide judgment, not replace it. When guidance appears
contradictory, harmful or disproportionate, raise the concern with concrete
consequences and propose the smallest correction. Do not blindly comply, silently
override the decision, or use ambiguity as permission for a broader redesign.

## Keep boundaries strong and implementations small

Explicit effects and typed interfaces state who owns each operation and what it
may depend on. They let us change an implementation later without building that
replacement now. No ambient IO in porcelain, universal service locator, package
per capability or unused interpreter shell. Pure functions remain pure functions.

Rely on guarantees the design already provides. Pure computation over explicit
snapshot inputs does not need a second runtime protocol to freeze its result or
prove that repeating it is safe. Recompute when useful; add caching only for a
demonstrated need. Do not build defensive state or approval machinery around
ordinary function composition. Keep checks at genuine boundaries, such as decoded
external values and effectful sink calls; purity of preparation does not make an
external action pure or safe to repeat.

## Require a product reason for complexity

Every mechanism must serve a current [journey](scope.md), a concrete correctness
obligation or an observed usability/performance problem. Domain complexity is real:
exact amounts, relationships, uncertainty and schema changes are not expendable
to simplify a codec. Conversely, speculative runtime machinery is not justified
by the richness of the domain.

Use field reports and representative measurements to discover what to improve.
A possible optimisation is not a commitment in the implementation plan.

## One authority and one normal route

Derive projections and bindings from authoritative Haskell schema and checked
metadata; do not maintain competing structural descriptions. Use one evolution
mechanism for changes to facts, schema and meaning. Keep materialized current
facts rather than requiring historical replay. Avoid special routes that bypass
the same checks or duplicate the same interpretation.

## Guide trusted authors; do not govern their world

Hide protocol and integration plumbing behind typed capabilities. Keep changes
and their consequences inspectable. Guarantee the local expected-head acceptance
step, but leave upstream conflicts and domain judgment to the human and agent.
Do not infer a sandbox, approval ledger or distributed coordinator from a typed
interface. Report what happened honestly, especially after an irreversible effect.

Design for trusted collaborators doing useful work, not for defeating a malicious
KB author. Types, effects and the data model guide coherent composition; the
possibility of deliberately circumventing a convention does not by itself justify
another enforcement layer, sealed value, approval protocol or bypass framework.
Prefer the simpler workflow supported by the design's existing guarantees.

Schemas, validators and business rules are authored code and may legitimately be
changed or relaxed to meet a particular need or repair a problem. Make that change
and its consequences understandable through ordinary source review and examples;
do not treat relaxation itself as hostile or make every old rule irrevocable.
Trust is not permission for an agent to silently change the requested behavior.
Raise departures from agreed intent, and preserve explicit kernel guarantees such
as local expected-head acceptance unless that decision is itself revised. Type
correctness is not proof of business correctness; authored checks and human/agent
judgment remain necessary, without an adversarial governance system around them.

## Reuse maintained implementations

Use the compiler, parsers, numeric libraries and Git primitives we selected rather
than recreating them. Own narrow adapters and generated mappings where Kyyn needs
them. An unsupported case gets an explicit diagnostic, not a hidden fallback,
private fork or new general-purpose framework.

## State decisions once; reconcile intent with implementation

Each architectural decision has one owning ADR stating the decided desired design
and its rationale, whether built or still to be built. Its high-level types and
effect rows define concrete contracts, not optional illustrations.
The code's actual types, effect boundaries and behavior show what
we have implemented. These are two things to reconcile, not two competing prose
specifications. Tests exercise that implementation against concrete expectations;
they are not another place to copy the architectural explanation.

Other ADRs and documents should reference the owning decision rather than restate
it. Source comments and UI copy must not become additional copies of that decision.
When a maintainer genuinely needs the architectural rationale at a particular
location, use a targeted ADR reference instead of a paraphrase. Do not annotate
every function with an ADR number or create a separate traceability registry.

For a change affecting architecture, review the smallest relevant loop:

1. Identify the owning decision and compare it with the actual implementation
   and relevant tests, not with comments claiming compliance.
2. If they disagree, explain the discrepancy and decide whether to correct the
   implementation or explicitly revise the decision. Neither an existing ADR
   nor existing code makes the other automatically wrong.
3. Reconcile the affected code, tests and owning ADR; track remaining implementation
   gaps in Issues rather than weakening the decision. Search for and
   remove obsolete restatements in the touched area; replace useful pointers
   with references rather than keeping several explanations synchronized.

Where implementation is still absent, record that in the Issue or PR rather than
treating a signature or a passing unrelated test as conformance. This is ordinary change review,
not a new approval workflow, inventory or automated prose-compliance system.

## Write for the reader's task, not to demonstrate architectural compliance

Correct statements are not automatically useful statements. User-facing copy,
API documentation and code comments must help their intended reader understand
or act on the current system. Do not use them to narrate the implementation
process, reassure a reviewer that a decision was followed, or leave reminders to
a future coding agent about why we chose this architecture.

For example, kyyn-v1's outbound view said: "Review ready outbound requests and
the receipts from local execution. External state remains outside Kyyn's truth
boundary." The boundary may be correct, but it is architecture language, not a
useful explanation of the user's task. Prefer concrete labels such as "Ready to
send" and "Send history", where those accurately describe the view. If a subtitle
adds nothing useful, remove it rather than rewriting the same disclaimer.

Keep code comments that explain a non-obvious local invariant, constraint or implementation
choice needed to maintain the current code. Remove comments that merely restate
the code, announce compliance with an ADR, narrate a past refactor, or explain
which hypothetical subsystem we did not build. Git history holds edit history;
the implementation is not a transcript of its authoring conversation.

This is not a ban on explanations or warnings. When a limit affects a user's
decision or recovery, explain the concrete consequence where it matters: for
example, a successful send followed by a failed local save needs an actionable
warning about checking the destination before retrying, not a statement about
"truth boundaries". Communicate what is known and what the user can do next.

During review ask: who needs this sentence, and what does it help them understand
or do here? If its only purpose is to demonstrate that the author remembered a
design decision, remove it. Record any still-needed rationale in the ADR without
duplicating it throughout the implementation or UI.

## Build and review through useful work

Web and MCP are equally important and share application operations; CLI supports
development and automation. Implement small end-to-end journeys across these
boundaries, not a forest of placeholders. Prototypes prove particular claims;
they do not prescribe production structure or prove untested compatibility.

When revising a design, ask: what must exist now, what can be removed, and what
evidence would justify more? Remove speculative mechanisms rather than leaving
them as optional interfaces, stubs or future-work breadcrumbs. Keep genuinely
unresolved choices explicit in Issues or design discussion until decided.
