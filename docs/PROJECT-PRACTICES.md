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
  execution does not fetch instructions from another checkout. `SDLC.md` is
  maintained locally, including Kyyn's proportional verification policy.

## Verification

Choose checks proportional to the change and record the exact revision, commands
and results in the PR. Independent review is the merge gate, not a blanket test
run. Reviewers do not routinely repeat the author's tests.

| Entry point | Scope |
| --- | --- |
| `bash tools/test.sh` | Fast checks: docs/import boundaries, native build and focused native/pure tests |
| `bash tools/test.sh --full` | Fast checks plus real MicroHs and installed-CLI integration |
| `bash tools/test-installed.sh` | Disposable local installation, installed journeys and native/self-hosted compiler parity |

The scripts own suite membership. Each test entry file's header comment describes
its coverage, important exclusions and unusual setup or focused modes. Keep that
comment current when changing the test; do not append per-test inventories here.
Fixtures and assertions supply the detailed examples.

For a contained fix, select the relevant native check and installed journey.
For a large outcome, run full integration on its terminal PR before closing the
issue. Documentation-only work normally needs the documentation/link check,
not compilation:

```sh
node tools/checks/check-docs.mjs
```

This checks repository-local Markdown links, not external URLs or heading anchors.
Run `node tools/checks/check-imports.mjs` when changing source dependencies.
Native tests can be selected with `cabal test SUITE --test-show-details=direct`;
installed journey scripts accept the executable path (see their header/usage).

### Development setup

Build tools: Bash 3.2+, Node.js 22+, GHC 9.10.3, Cabal 3.16.1.0, Make and a C
compiler. Git is needed for repository operations. Fetch native dependencies with
`cabal update` on a new machine. Node is build/test tooling, not an installed
runtime dependency. See [the guide](guide.md#install) for local installation and
[vendored inputs](../vendor/README.md) for guest libraries.

Full integration stages the toolchain automatically. For a focused real-guest
test, stage it once in a new directory and select it explicitly:

```sh
bash tools/stage-microhs.sh /tmp/kyyn-test-toolchain
export KYYN_TEST_ROOT="$PWD"
export KYYN_TEST_TOOLCHAIN=/tmp/kyyn-test-toolchain
export MHSDIR="$KYYN_TEST_TOOLCHAIN"
export MHSCPPHS="$KYYN_TEST_TOOLCHAIN/bin/cpphs"
cabal test guest-api --test-show-details=direct
```

Do not silently skip a failing selected check. Record environmental limitations;
some process tests require POSIX, and installed journeys need a writable disposable
Git workspace. On a harness that inserts ancestor `/tmp/.git` metadata, select a
different `TMPDIR` for initialization tests.

### CI

`.github/workflows/check.yml` is manual-dispatch only, with an optional full run.
There are no automatic PR/push tests or remote-CI merge requirement during private
development. After a reviewed merge, sync and continue. Do not configure the
optional workflow as a required check. CI caches compiled dependencies, not test
results; a selected run still resolves, builds and tests its current inputs.

## Review and merge

- **Architectural/process decision authority:** Tom (`drshade`). An independent
  reviewer examines significant decisions; Tom resolves the decision before merge.
- **Independent review:** a different human or agent may review. An author rereading
  their own work is not independent review. The reviewer examines the actual final
  diff and verification evidence, not only the author's summary.
  Reviewers do not routinely rerun the author's tests or require a clean-export
  build. Additional targeted verification needs a concrete concern, not a default
  duplicate gate. Review clearance, not green remote CI, permits an authorised merge.
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

- **Published releases:** none. The CLI and bundled runtime are available as development source builds.
- **Release runbook:** not yet applicable. Establish and verify one before publishing
  a build; ADRs 0020 and 0022 own distribution and licensing decisions.
- **Dependency evidence:** [native runtime source inventory](dependency-sources.md)
  records inspected archive licenses; it is not a complete distribution audit.

## Additional practices

ADR 0024 owns the proposed field-experience method. Its scenarios apply when the
relevant product paths exist; this adoption does not require a field run for every
documentation change.
