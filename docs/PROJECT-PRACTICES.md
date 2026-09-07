# Kyyn project practices

This file supplies the configurable mechanics of [the SDLC](SDLC.md). Architectural
decisions remain in [architecture/](../architecture/README.md); development process
does not become another specification of the product's runtime workflows.

## Repository and adoption

- **Repository:** `drshade/kyyn-v2` on GitHub; primary branch `main`.
- **Workspace:** a dedicated branch; use an isolated checkout/worktree when concurrent
  work could interfere. Worktrees and particular branch-name prefixes are not required.
- **Adoption:** prospective from the merge of the SDLC adoption PR. The prior
  architecture import is commit `deca3d0`; do not manufacture retrospective Issues,
  design approvals or implementation completion for it.
- **Foundation:** adapted from `sdlc` commit
  `347b154d9c5be56d2506401b134625850ed4adf4`. This repository owns its process copy;
  execution does not fetch instructions from another checkout. `SDLC.md` retains
  that baseline verbatim; Kyyn's adoption details live here.

## Verification

- **Complete gate:** `bash tools/test.sh`, invoked identically locally and in CI.
- **Development prerequisites for this gate:** Bash 3.2+ and Node.js 22+; no npm packages.
  Node is development/build tooling, not an installed Kyyn runtime dependency (ADR 0020).
- **CI:** `.github/workflows/check.yml`, job `check` on pull requests and pushes to main.
- **Current scope:** documentation, ADR metadata, process-script syntax and regression
  tests of the documentation checks, including final newlines and trailing whitespace
  (stricter than the foundation's checker). No GHC, MicroHs, plugin or Web build exists yet.
  The gate reports this scope explicitly and refuses newly populated implementation
  directories, including `tests/integration/`, until its owner adds the corresponding
  real checks in that change.
- **As implementation arrives:** replace the documentation-only guard with actual
  host/shared/guest, integration and Web checks as applicable. Use the entry-point
  locations in ADR 0026; do not silently skip MicroHs/plugin failures behind a native
  build. No placeholder scripts are required now.

The check validates project-owned documentation, not third-party/vendor/cache trees.
Historical evidence in neighbouring repositories is cited as source paths rather
than required local links; a clean checkout is sufficient for this gate. External
HTTP links and heading anchors are not validated. The small checker handles inline
links outside top-level fenced blocks and single-line backtick code spans; it is
not a full Markdown parser. Multiline code spans and fences nested at four or more
spaces inside lists are not interpreted as code. Use top-level fenced examples
when demonstrating links that are not actual documentation references.
Branch protection is a repository setting, not
established by this PR; configure the `check` job as required where available.

## Review and merge

- **Architectural/process decision authority:** Tom (`drshade`). An independent
  reviewer examines significant decisions; Tom resolves the decision before merge.
- **Independent review:** a different human or agent may review. An author rereading
  their own work is not independent review. The reviewer examines the actual final
  diff and verification evidence, not only the author's summary.
- **Ordinary merge authority:** Tom, or a reviewer/maintainer explicitly authorised
  by him for the PR or workstream. Passing checks or writing the PR does not grant
  an agent permission to merge it.
- **Review record:** PR review/comments contain findings and their resolution.
  Switchboard can coordinate reviewers, but material conclusions must reach the PR
  and, for design decisions, the owning ADR or process document.
  When agents share a GitHub identity, the PR identifies its authoring and reviewing
  agents, and each agent-authored review names its author. The reviewing agent must
  differ from the authoring agent; the shared GitHub login is not that distinction.
- **Merge strategy:** not prescribed; do not force-push or rewrite another contributor's
  history without agreement.

## Decisions and active work

- **ADR directory:** `architecture/adr/`; [file conventions](../architecture/adr/README.md)
  retain the literate types/signatures in the existing architecture.
- **Imported baseline:** ADRs 0001–0026 retain their existing status/basis text.
  Some combine owner-established choices with unresolved mechanics. Do not interpret
  the adoption as making every proposal authoritative or every decision undecided.
  A substantive revision reconciles the affected decision and adopts the standard
  lifecycle metadata, without requiring a mass rewrite now.
- **Unresolved outcomes:** GitHub Issues, not a second backlog in process documents
  or an issue for every package, effect or implementation step. Immediately active
  contained work may be owned directly by its PR as described in the SDLC examples.
- **Architecture versus process:** architectural principles guide design judgment;
  SDLC governs how work is recorded and reviewed. Raise conflicts for correction in
  the owning document, rather than duplicating or silently overriding instructions.

## Releases

- **Published releases:** none. The repo currently contains design and process work.
- **Release runbook:** not yet applicable. Establish and verify one before publishing
  a build; ADRs 0020 and 0022 own distribution and licensing decisions.

## Additional practices

ADR 0024 owns the proposed field-experience method. Its scenarios apply when the
relevant product paths exist; this adoption does not require a field run for every
documentation change. Further extensions follow [EXTENDING.md](EXTENDING.md).
