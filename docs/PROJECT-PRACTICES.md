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

- **Available fast check:** `bash tools/test.sh`: documentation/import checks, native
  compilation, process/filesystem tests and pure metadata codec/adapter/contract tests.
  The native Dhall boundary has a focused `cabal test dhall-values --test-show-details=direct`
  check, also included in the fast check; it does not compile guest code.
  `cabal test roots --test-show-details=direct` checks RootStore materialization
  and reopening from immutable file trees through the Dhall interpreter. It is
  included in the fast check and does not compile guest code or publish Git refs.
  The same suite exercises manifest-driven RootOpening with the real Dhall and
  RootStore handlers and recording schema/Git test handlers. It checks source/SDK
  capture and revision forwarding, not a second real-compiler execution.
  `cabal test git-snapshots --test-show-details=direct` exercises fixed-revision
  capture, isolated commit construction and expected-head ref updates against Git
  in a temporary repository; it is included in the fast check
  and requires an installed Git executable (tested locally with Git 2.55.0).
  `cabal test file-trees --test-show-details=direct` checks local directory capture
  without running the process cancellation or MicroHs suites; it is included in
  the fast check.
  Authors choose relevant local checks and record their revision and results;
  this command is not mandatory for every PR.
- **Full integration check:** `bash tools/test.sh --full` adds real MicroHs
  compilation and codec tests. Run it before declaring an Issue complete, or when
  needed for a particular change or investigation; not for every PR or merge.
- **Development prerequisites for this gate:** Bash 3.2+, Node.js 22+, GHC 9.10.3,
  Cabal 3.16.1.0, Make and a C compiler; no npm packages. Fetch native dependencies
  with `cabal update` on a new development machine.
  Node is development/build tooling, not an installed Kyyn runtime dependency (ADR 0020).
- **CI:** `.github/workflows/check.yml` is manual-dispatch only, with a `full`
  checkbox. No automatic PR/push runs or remote-CI merge requirement. After merge,
  sync and continue. This policy applies during private, pre-release development.
  CI caches Cabal's compiled dependency store by platform, toolchain and resolved
  build configuration. Compatible older stores can seed changed dependency plans;
  Cabal still resolves and builds the current plan. Project build outputs and test
  results are not cached, and the selected check runs on cache hits and misses.
- **Current scope:** documentation/ADR checks, checker regressions, explicit pure-module
  import allowlists, native package builds, scoped process lifetime tests and actual MicroHs generated-codec tests.
  `tools/test-guest.sh` builds the vendored compiler/evaluator/preprocessor and the
  native test suite inspects authored types, generates codecs, compiles them and
  exchanges runtime values with the resulting guest. It does not substitute GHC
  for guest execution. Captured source compilation uses GuestCompilation and
  emits bytecode consumed by the bundled evaluator, not C-compiled guest binaries.
  Process and filesystem tests exercise scoped cleanup, real children, byte pipes, failures and
  cancellation; their reaping assertions currently require POSIX (Linux in CI).
  No complete KB workflow, plugin or Web build exists yet.
  For the named metadata export boundary alone, after building the bundled tools,
  run `KYYN_TEST_ROOT="$PWD" cabal test metadata --test-show-details=direct`.
  This compiles the shared metadata declarations with MicroHs and evaluates the
  named export through the fixed SDK codec, without running the full codec suite.
  It combines structural inspection and metadata evaluation from the same captured
  sources, then materializes/reopens runtime facts through RootStore and passes
  the resulting value through a generated guest codec. It also compiles a small pure
  guest validator and checks the SDK validation-report wire, including warnings,
  errors and structured locations. This report fixture is not the RootExecution
  handler or a complete root-validation gate. It does not open a KB from Git.
- **As implementation arrives:** keep the default check fast and extend full
  integration coverage separately. Do not silently skip failures in a selected check.

The documentation check validates project-owned documentation, not third-party/vendor/cache trees.
Historical evidence in neighbouring repositories is cited as source paths rather
than required local links; a clean checkout is sufficient for this gate. External
HTTP links and heading anchors are not validated. The small checker handles inline
links outside top-level fenced blocks and single-line backtick code spans; it is
not a full Markdown parser. Multiline code spans and fences nested at four or more
spaces inside lists are not interpreted as code. Use top-level fenced examples
when demonstrating links that are not actual documentation references.
HTML comments are not excluded from inline-link checks, and reference-style link
definitions are not validated; use ordinary inline links for checked references.
Do not configure the optional `check` workflow as a required merge check.

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

- **Published releases:** none. The repo contains design, process and initial codec implementation.
- **Release runbook:** not yet applicable. Establish and verify one before publishing
  a build; ADRs 0020 and 0022 own distribution and licensing decisions.
- **Dependency evidence:** [native runtime source inventory](dependency-sources.md)
  records inspected archive licenses; it is not a complete distribution audit.

## Additional practices

ADR 0024 owns the proposed field-experience method. Its scenarios apply when the
relevant product paths exist; this adoption does not require a field run for every
documentation change. Further extensions follow [EXTENDING.md](EXTENDING.md).
