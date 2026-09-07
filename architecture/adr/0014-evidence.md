# 0014 — Evidence is replaceable input; interpretation belongs to the KB

Status: Proposed. Basis: owner-established operational/refetch semantics.

## Context

Provider representations and business meaning are different kinds of knowledge.
BEE must group duplicate observer copies correctly; Exco must not confuse a
source correction with a new business entity. Neither requires eternal evidence
schema custody in the kernel.

## Decision

Plugin source connectors acquire and normalize provider evidence into typed views. KB functions
interpret those views into candidate knowledge. Keep source identity,
fetch time, plugin/contract identity and useful references
with evidence. Evidence is an ignored local cache, replaceable on refresh.
Identify the producing plugin and named connector instance as well as its
configuration and method. Two instances of Mail must not share evidence merely
because their package and connector type match. Secret names may occur in config;
secret values are not evidence identity or metadata.
The source/sink distinction belongs to ADR 0015. Sink connectors update external
outputs through ADR 0017; they are not evidence acquisition or KB browsing.

A source selection is a snapshot, not an instruction to ask the provider for
"latest" every time a page is read. On the host the contract is structural:

```haskell
data EvidenceSnapshot  -- fixed query + producer/contract identity + stored pages

data EvidenceProblem
  = EvidenceReplaced
  | EvidenceIncomplete
  | ProducerContractChanged

readEvidencePage
  :: (EvidenceStore :> es, Failure :> es)
  => EvidenceSnapshot -> PageRequest
  -> Eff es (Either EvidenceProblem (Page CheckedValue))
```

The snapshot remembers the [package identity](0015-plugins.md), not just the
shape of its result. Its [Page](0006-storage.md) cursor is interpreted only in
that snapshot/query. Expected staleness or incompleteness is data with a repair
path, distinct from storage failure. Generated guest bindings decode these values
into the method's typed page; they do not hand `CheckedValue` to KB authors.

Expose snapshot-scoped typed pages with opaque cursors. A cursor is bound to a
query and evidence snapshot. Replacement invalidates it explicitly rather than
silently mixing cached snapshots. This fixes locally acquired data for reading;
it does not promise a historical version or transactionally consistent snapshot
of the external system. Provider-specific grouping and pagination belong to
the plugin; KB-specific grouping/classification belongs to the KB. Completing a
page is not equivalent to completing a logical meeting occurrence.

Acquisition checkpoints advance only after fetched data is persisted; incomplete
runs remain distinguishable from complete snapshots. This tracks acquisition,
not a kernel-enforced queue of evidence awaiting review, dismissal or acceptance.
A fetch checkpoint is not proof that evidence became accepted knowledge.
Interrupted or rejected curation must remain repeatable; stable domain
IDs and explicit deduplication prevent accidental duplicate facts.
If a KB needs to prove every source item was considered, it can model that rule
with ordinary facts, queries and validation. It is not mandatory connector machinery.

An evolution entry may invoke a plugin to read an existing evidence snapshot or
explicitly acquire new evidence. Generated typed proxies carry an `EvidenceRef`
identifying the selected host snapshot; subsequent pages must not silently switch
to refreshed contents. This is snapshot read semantics, not a mandatory separate
capture/proposal-authoring phase.

The entry returns a root with annotated step observations (ADR 0010), from which
Kyyn materializes a candidate and derives its step report. Candidate checking uses that
result and explicit captured checking inputs, not fresh evidence or rerunning the
entry. Keep any evidence-derived values actually needed by a pure check as explicit
data. No requirement to archive all RPC responses or source bytes for the life of
every candidate. Accepted knowledge keeps useful references and explanation;
an archived evolution may consequently be non-runnable later. Re-evaluation can
acquire changed evidence and produces a new result for inspection. Acquisition
and reads do not change accepted facts or mark curation as accepted.

Supporting provenance is declared through each evolution step's `Rationale`:
an explanation and a list of `EvidenceRef`s, paired with the actual changes
derived at that boundary. Reading evidence does not automatically cite it;
fetching evidence does not create a review obligation. The kernel does not infer
support from call traces or promise to prove that a cited item caused a change.

An archived citation must retain enough source identity to describe what was
cited independently of a transient cache lookup: producer/connector identity,
source item identity and useful source references.
Plugins should make a best effort to provide good source identifiers: prefer a
stable source URI where available, or a provider-native item ID with the account,
mailbox, organization or other scope needed to identify and locate it. For example,
cite an email by its provider-supported identifier/link, a Salesforce opportunity
by its scoped opportunity ID, or a local file by its path with an explicit base
if relative. A useful source link can accompany an ID; do not require every
identifier to be a publicly accessible URL or invent a URI scheme merely for
uniformity. Avoid using only a temporary Kyyn cache key when the source provides
a better identifier. Choosing the provider's best available identifier belongs
to the plugin, not a provider-specific identity system in the kernel.

The citation contract is **"here is the source item supporting this rationale"**,
not "here is an immutable historical version". A stable item ID or file path may
later resolve to changed content. Paths can move, items can be deleted, and
following a source link may require credentials. Useful source identification
does not guarantee permanent access, retention or historical reconstruction.

Do not require source versions, fingerprints, content hashes or change tracking
for citations. Hashing a fetched representation would only compare those chosen
bytes: fetch metadata or other incidental differences can change them without a
meaningful change to the source item. Defining a canonical business projection
to make that comparison useful is not part of this contract. Kyyn does not ask
plugins to manufacture one or promise to detect whether cited content changed.

These are ordinary reference data, not a requirement to keep all source bytes.
When a citation's snapshot is gone, keep the saved source reference visible.
Following that reference or fetching again accesses the source as available now,
not a recovered historical version. The retained evolution records its fact
changes and declared rationale, not the history of the external system.

## Updates and alternatives

When a plugin changes, invalidate affected cached evidence/bindings, refresh its
contract, repair consumers and refetch. Compare package identity as well as schema:
same type does not mean same behavior. No per-run schema migration/negotiation.
Do not delete accepted facts because evidence expired. Reconsidering them is an
explicit KB evolution. Preserve uncertainty when a provider cannot refetch old data.

## Verification

Duplicate/corrected input, grouping over page boundaries, refresh during paging,
failed partial fetch, rejected curation and changed same-schema plugin behavior.
No scenario silently marks unaccepted work processed or loses accepted knowledge.
After deleting a fixture's evidence cache, its archived citation still exposes
the source URI, scoped provider ID or file path supplied by the plugin. A plugin
can supply a useful citation without a version or fingerprint. Following its
source reference is presented as source access, not historical reconstruction;
the test does not require detecting whether the source content changed.
