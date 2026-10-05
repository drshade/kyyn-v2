# 0022 — Proprietary now; deliberate dependency and future licensing choices

Status: Owner-established decision. Kyyn-owned project code is proprietary,
all rights reserved, for now. A future permissive open-source release is a possible
direction, not a current license grant or release commitment.

## Context

A first-/third-party plugin architecture does not require the kernel or SDK to
be open source today. Keeping future distribution options open requires deliberate
dependency choices, not prematurely selecting a public license.

## Decision

Treat Kyyn-owned kernel, SDK, first-party code and project documentation as
proprietary/all rights reserved for the current development phase. Do not add
permissive license headers, promise public redistribution rights, or describe
the current project as already open source. A later open-source/permissive release
requires an explicit owner decision.

This policy does not replace third-party licenses or notices, relicense copied
code, or establish that any prior rights grants can be withdrawn. Review the
provenance and terms of material already present before changing repository-level
license files. This ADR records project intent; it does not silently rewrite
existing notices across the prototypes and dependencies.

Keep the public-capability architecture and plugin authoring boundary independent
of this licensing choice. External extensibility remains a technical goal; source
availability and distribution permissions are separate matters. No mandatory
signing/approval service or plugin compatibility lock follows from proprietary
development.

## Dependency selection and distribution

Review the actual sources included in native binaries, guest bundles, generated
code, runtime tools and web assets. Preserve applicable notices and document local
patches. Native-linked MicroHs compiler modules need this review as well as bundled
compiler/evaluator tools; their absence from the user-facing API does not remove
them from the distributed software.

Select dependencies with the current proprietary policy and possible future
permissive release in mind. Do not assume a technically compatible library also
fits the intended distribution. Identify license questions before adopting code,
and resolve them explicitly rather than silently changing Kyyn's policy or treating
a future open-source possibility as permission today. Obtain legal review where
the implications are unclear; no particular combined-artifact licensing conclusion
is established by this ADR.

The selected host/guest JSON libraries are recorded in [ADR 0007](0007-wire.md),
with source/license inventory in [vendored inputs](../../vendor/README.md) and
[native dependency sources](../../docs/dependency-sources.md).
Check the exact selected source/dependency terms alongside the compatibility proof;
API convenience alone is not distribution clearance. This is one
dependency-selection check, not a new runtime enforcement mechanism.

## Verification and later release

For any distribution, check that Kyyn-owned artifacts carry the intended notice
and retain their dependencies' required notices and permissions. Confirm that
generated/copied code is included in that review. Do not bulk replace third-party
headers with the project's all-rights-reserved notice.

If the owner later chooses an open-source release, review the actual code,
dependencies and contribution rights before selecting the license and publishing.
Until then, write maintainable build instructions and independent plugin interfaces
without assuming that public release has already been authorized.
