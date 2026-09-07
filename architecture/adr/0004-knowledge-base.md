---
id: 0004
title: 'Distinguish the KB, its root and its evolutions'
status: proposed
date: 2026-09-07
---
# Distinguish the KB, its root and its evolutions

## Context

A KB is not a list of facts or a single evolution workspace. Confusing these
objects hides context, permits reads against the wrong revision, and makes
validation markers meaningless.

## Decision

`KnowledgeBase` identifies a repository-scoped workspace aggregate. It has one
accepted root and a collection of evolution workspaces. Do not eagerly load all
workspaces to open the KB. `Root` on the host is an opaque snapshot descriptor:
its schema, executable meaning/dependency identities and materialized fact tree.
The guest's `Root` is the concrete KB-owned data type, potentially a record of
several identified collections. They are not the same Haskell representation.

On the **host**, we can describe the contents without importing the KB's `Todo`,
`Forecast` or the guest's authored `Root` type:

```haskell
data KnowledgeBase = KnowledgeBase
  { repository :: Repository
  , prefix     :: RelativePath  -- KB directory relative to repository root
  }

data Root = Root
  { schema :: CheckedContract
  , facts  :: FactSnapshot
  , code   :: CodeSnapshot
  }
```

`CheckedContract` belongs to [contracts](0005-contracts.md). `FactSnapshot` and
`CodeSnapshot` contain immutable file-tree values as defined in
[storage](0006-storage.md), including vendored dependency source, executable
examples and supporting non-secret config files alongside code. Loading reads
the bytes into the value; subsequent reads do not resolve editable paths or
require a store-specific handle service. The guest receives decoded domain values.
The explicit repository and KB-relative prefix let publication address the selected
KB without guessing its location. The prefix may denote the repository root.
Under the proposed [storage layout](0006-storage.md), the host root's selected
source/config files include `root/plugins/config/*.dhall` and `root/examples/`.
They belong to the accepted snapshot, not to the guest's domain facts type;
ADR 0016 defines their typed runtime loading. The code snapshot here includes
supporting files, not just compiler input modules; config values remain runtime data.
The guest-side query/output declarations in ADR 0017 belong to that code snapshot,
not function-valued fields serialized in the guest Root. The host Root therefore
selects both the current facts and the definitions that interpret or render them.

`EvolutionWorkspace` is an editable proposal whose `Before` contains a Git
revision and the schema from that commit. Its `After` specifies the target
schema, without a future commit revision (ADR 0010). Its evaluated after snapshot
is `Candidate Root`; successful checking
produces `Candidate (Validated Root)`. An archive can retain metadata without
loading either typed root. Only explicit compatible loading invokes the runtime.

`Candidate a` supports mapping while preserving base/provenance context and the
fixed evolution report produced during evaluation (ADR 0010).
`fmap f` maps its payload, not that context or report; it does not map through `Validated`.
`Validated a` does not provide `Functor`. No mapping operation may carry an old
validation result onto changed content. `CheckedEvolution` groups the `Before`
specification with the evaluated, validated after result and workspace material
to commit. It is an ordinary checked value, not a sealed-candidate registry or
approval token. Editing/rebasing the workspace requires new evaluation and checks.

The wrappers express different operations. A candidate has one captured
[evolution context](0010-evolutions.md); validation marks a particular value:

```haskell
data Candidate a = Candidate
  { context :: EvolutionContext
  , report  :: EvolutionReport
  , value   :: a
  }

instance Functor Candidate where
  fmap f (Candidate context report value) = Candidate context report (f value)

newtype Validated a = Validated a  -- constructor private to checking code
```

This ADR owns the wrapper convention, not a requirement to define both wrappers
in the domain package. `Validated` is implemented in a non-public, validation-owned
module inside `kyyn-porcelain`, alongside the checking implementation that constructs
it. The public validation capability exports the abstract type for store APIs and
other consumers. Keep its type-definition module separate from effectful checking
dependencies so capability modules can refer to it without an import cycle. No
public unchecked constructor is needed to bridge a package boundary; domain values
such as `Root` do not import porcelain. Package/import checks govern construction
within the owning package. `Candidate` remains ordinary host data with its stated
Functor convention, not a sealed constructor or validation certificate.

There is no `Functor Validated`. Mapping `Root -> Root` over a candidate produces
another unchecked candidate; it cannot map through `Validated Root`. These are
ordinary data conventions, not evidence that a reviewer approved the contents.
The report describes the evaluated transformation, not arbitrary subsequent
applications of `fmap`. Mapping a payload for inspection does not establish new
provenance. Changing the proposed root requires a new evolution evaluation and
report; the publication path checks the evaluated root, rather than replacing
its facts by an unrecorded mapping. The report is output attached after evaluation,
not a claim that pre-evaluation captured inputs already contained the result.
`CheckedEvolution` is only the [acceptance](0012-acceptance.md) name for the final
composition, not another object duplicating its base or captured material.

## Boundaries and consequences

Ordinary fact reads require an explicit `Validated Root`; they remain effects
even if an interpreter currently answers from memory. Invalid raw data may be
inspected through diagnostic operations, not cast into a validated root.
Evolution evaluation also admits a structurally readable `Root` so it can repair
semantic errors; only its checked result can earn `Validated` for acceptance.
Loading an accepted root for validated operations checks it. An accepted Git
revision or an earlier saved report does not itself confer the marker; reading
an arbitrary edited directory never earns it automatically.

Use ordinary identity newtypes without `unThing` selectors. Prefer `coerce`
where representation conversion is intended; keep constructors private where
validation identity matters. Do not rely on wrapper names alone as enforcement.

## Alternatives and verification

Reject a universal mutable `Kb` holding disk paths, IO callbacks and current
values. Test two explicit snapshot values in one operation, draft listing
without compilation, and fresh checking when loading a root for validated use.
