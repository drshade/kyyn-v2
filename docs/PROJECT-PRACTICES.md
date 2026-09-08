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
  Source-only opening is checked with absent/corrupt facts and explicit revision
  forwarding. Workspace tests use real Dhall with pure projection/matching:
  malformed manifests/layout, input additions/edits/deletions, and exclusion of
  lifecycle state and notes. They neither compile drafts nor verify archives.
  Evolution capture tests combine real filesystem/Dhall with recording RootOpening:
  repository-root/nested KB paths, exact Before copies, revision changes, unfinished
  targets, live matching without source loading, and diagnostics versus operational
  failures. No new MicroHs or Git execution is involved in those capture tests.
  Evolution execution tests use real Dhall/filesystem/process handling and recording
  RootOpening/schema/compiler handlers. They check exact nested-KB Before selection,
  contract/source mismatch, closure deduplication/collisions, intermediate declarations,
  generated entry selection and preparation/refusal/runtime/protocol failure distinctions.
  No real guest compilation is involved in these native tests.
  Candidate tests in the roots suite check contract-description round trips,
  exact context/root/report persistence, immutable repeated saves, missing/stale/corrupt
  selections and failed publication preserving the last result. Application uses a
  recording evolution handler with real RootStore/Dhall; checking records RootExecution
  calls. Reload has no source-opening/compiler path and does not restore Validated.
  Acceptance-history tests use real Git and Dhall: original introducing commit,
  inherited archive, revert/removal, reacceptance, all-parent merges, ambiguous and
  malformed histories. They forbid live-file/root-opening calls, check exact commit
  parents and optional file reads, and do not publish a ref or run guest code.
  Lifecycle fixtures reuse that temporary Git history with explicit test-only ref
  updates. They check duplicate names, Draft filtering, unknown/malformed diagnostics,
  manifest-only Ready/Draft transitions preserving captured inputs, authoritative
  Accepted state despite stale/missing/malformed local manifests, and refusal to edit
  accepted workspaces. Recording filesystem forwarding rejects recursive reads and
  non-manifest writes; no source opening/compiler or candidate loading occurs.
  Archive export tests retain captured source/manifest/report despite live edits,
  preserve current review-note bytes and deletions, reject inconsistent captured
  target code, and distinguish unsupported durable record versions from private
  candidate staleness. Root-export integration writes root and archive replacements
  into one real Git commit and reopens both exactly, including FindAcceptance of
  that commit. It exercises export/commit/CAS primitives, not the full acceptance
  readiness/overlap/checkout-synchronization workflow.
  Creation is checked by immediately capturing its returned workspace, including
  repeated labels, source rejection before allocation and failed writes. Workspace
  encoding round-trips through real Dhall, preserving non-manifest file bytes.
  RootExecution tests use a recording compiler handler and small shell fixtures
  for process exits/malformed replies; they check pre-execution rejection and
  failure classification without compiling MicroHs. These fixtures require `sh`.
  They also check that registered query entries are compiled without executing
  them. Saved-example tests use the real Dhall/store handler and recording
  RootExecution: path/contract round trips, required/illustrative mismatches,
  unchanged-root Validated minting and operational-failure propagation. The
  private constructor boundary has an import-check regression test.
  The roots suite also requires Git for export integration: a checked root is
  exported, committed as a complete subtree replacement, conditionally published
  and reopened with identical Root/files. Git and Dhall are real; validation and
  schema inspection are recording handlers, not another guest compilation run.
  It checks deletions and unrelated committed/staged/unstaged preservation; it
  does not exercise evolution acceptance or checkout synchronization.
  `cabal test git-snapshots --test-show-details=direct` exercises fixed-revision
  capture, isolated commit construction and expected-head ref updates against Git
  in a temporary repository; it is included in the fast check
  and requires an installed Git executable (tested locally with Git 2.55.0).
  `cabal test file-trees --test-show-details=direct` checks local directory capture
  without running the process cancellation or MicroHs suites; it is included in
  the fast check.
  It also checks exclusive hexadecimal directory allocation, a seeded collision
  retry with existing contents preserved, concurrent allocations and parent failure.
  Optional reads distinguish absence from failure. Atomic replacement tests cover
  initial creation, concurrent complete-value reads/writes, temporary cleanup and
  failed replacement preserving the existing directory.
  Authors choose relevant local checks and record their revision and results;
  this command is not mandatory for every PR.
  `cabal test queries --test-options=--pure --test-show-details=direct` exercises
  typed query composition, read traces, binding generation and reply decoding
  without invoking MicroHs. It is included in the fast check.
  `cabal test evolution-core --test-show-details=direct` exercises pure SDK
  composition, observations and failure behavior. `cabal test evolutions
  --test-options=--pure --test-show-details=direct` checks binding generation;
  both are included in the fast check and neither invokes a guest compiler.
  `cabal test evolution-reports --test-show-details=direct` checks observation
  chains, structural values and identity-based reports through real RootStore/Dhall,
  plus malformed protocol rejection. It is included in the fast check and needs
  neither Git nor a guest compiler.
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
  the resulting value through a generated guest codec. It also executes the real
  RootExecution handler over materialized snapshots with a manifest-selected pure
  guest validator, including warning-only and semantic-error outcomes with
  structured locations. It does not open a KB from Git or implement the full
  candidate/required-example validation gate.
  `KYYN_TEST_ROOT="$PWD" cabal test queries --test-show-details=direct` is the
  focused real-MicroHs query integration check: named input/result metadata,
  generated bindings, dependent reads over distinct payload types, typed result
  plus ordered trace, and rejection of a mismatched collection payload. It is
  included in the full check, not a mandatory per-PR command.
  `KYYN_TEST_ROOT="$PWD" cabal test evolutions --test-show-details=direct` compiles
  one generated-binding fixture and the SDK with both GHC and MicroHs, compares
  their results, and checks rejection of wrong binding types and private output
  constructors. It also compiles the identity scaffold used by creation. This
  focused SDK/encoding proof is in the full check, not a per-PR requirement; it
  additionally checks guest JSON replies through the native decoder and report
  capability. It does not claim workspace evolution execution or candidate persistence.
  `KYYN_TEST_ROOT="$PWD" cabal test workspace-evolutions --test-show-details=direct`
  exercises the actual EvolutionExecution handler with real RootOpening, schema
  inspection, MicroHs, RootStore and Dhall. A recording Git handler supplies only
  the selected Before revision/subtree; the test verifies a schema-changing chain,
  exclusion of unrelated old modules, preserved context and exact After materialization
  and reopening. It is part of full integration, not a per-PR requirement. It does
  not save Candidates or accept proposals.
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
