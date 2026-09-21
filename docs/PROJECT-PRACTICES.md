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

Broad guest integration tests use the shipped native MicroHs compiler, not the
self-hosted compiler. `tools/stage-microhs.sh` is shared by CLI packaging and
`tools/test-guest.sh`: it builds `gmhs`, `mhseval` and `cpphs`, and stages `gmhs`
as `bin/mhs` alongside the evaluator, preprocessor and libraries. The guest-test
script selects that temporary toolchain through `KYYN_TEST_TOOLCHAIN` and removes
it when finished. Compiler-library inspection still runs in process.
Only the focused native/self-hosted parity step in `tools/test-installed.sh`
builds and invokes the self-hosted `bin/mhs`.

For the direct real-guest commands below, first stage and select a toolchain
(choose a destination that does not already exist):

```sh
bash tools/stage-microhs.sh /tmp/kyyn-test-toolchain
export KYYN_TEST_ROOT="$PWD"
export KYYN_TEST_TOOLCHAIN=/tmp/kyyn-test-toolchain
export MHSDIR="$KYYN_TEST_TOOLCHAIN"
export MHSCPPHS="$KYYN_TEST_TOOLCHAIN/bin/cpphs"
```

Pure/codec-only test modes do not need this setup. `bash tools/test.sh --full`
performs it automatically.

`cabal test plugin-fetch --test-show-details=direct` uses that toolchain plus the
matching versioned GHC executable to compile the same folder acquisition and
captured-read fixtures under both compilers. A recording host exchanges real JSON
pipe frames: typed config/prior evidence, new/updated/removed changes, Unicode,
enumeration/read failures and malformed replies. Both compilers reject filesystem
calls from the captured-read entry. The native MicroHs broker also fetches real files,
publishes successive Dhall evidence batches, reads latest captured input and verifies
that unchanged files and failed acquisitions do not manufacture changes. Recording
handlers check that malformed, unknown-snapshot and out-of-row requests are refused.
They also check one current-evidence load before guest execution and the loaded
fetch as publication's expected base; the broker has no storage capability. A native fixture
publishes another fetch between callbacks and verifies that the invocation still
sees its original input. This focused check does not exercise plugin registration
or a CLI command.

`cabal test plugin-registration --test-show-details=direct` uses the same toolchain
to load the actual first-party local-file package, evaluate its declaration,
inspect Haskell config/payload contracts and compile fetch/config-validation
adapters. The first-party acquisition adapter also compiles with the matching
versioned GHC executable, checking generated exports against both compilers.
It decodes two configured instances, fetches real files independently,
and rejects invalid config through the whole-root checker. It also compiles the
local-file content reader with both compilers and invokes it through PluginRead,
checking missing captures/IDs and malformed input. It also checks reflected
record-field documentation, invalid registration/instance names and a mismatched
fetch signature. This is a focused native integration check, not an installed CLI journey.

`node tools/test-connector-fetch.mjs INSTALLED_EXECUTABLE` runs the installed
producer journey in a disposable nested KB: discover the emitted Dhall schema,
configure and accept two instances, fetch and change real files, inspect retained
history and payload-free deltas, and preserve the head after acquisition failures.
It checks superseded/removed payload absence, invalid-data repair and scoped
clear/refetch without a runtime bundle, without adding a generic evidence-view endpoint.
It belongs to the full installed check and can be run independently for changes
to this boundary. `--read-smoke` focuses on method discovery (including draft
targets), reads while the source folder is unavailable, independent instances,
refresh/removal, input refusal and Dhall/JSON outputs. `--tool-smoke` instead adds
and accepts a registered helper, discovers its contracts, and composes captured
reads across two configured instances while the source directory is unavailable.
It checks structured and Dhall results, invalid arguments and typed method failure.

The plugin-registration suite also exercises generated tool bindings in GHC and
MicroHs: an empty request row, wrong-instance compile refusal, two-instance reads,
catchable missing-item failures, one captured-input load per instance, and
invocation-level not-fetched refusal. These tests reuse the configured plugin
fixture; no second acquisition setup or full integration gate is required.

`cabal test plugin-packages --test-show-details=direct` checks source classification,
hermetic plugin manifest/origin codecs, scoped Git source changes and shallow
no-checkout acquisition from a local Git remote. It uses real Dhall
and Git handlers, without network access, a guest compiler or plugin invocation.
It is included in the fast check.

`cabal test evidence-store --test-show-details=direct` checks ordered delta application,
real Dhall persistence, instance isolation, latest-only payloads and payload-free change
summaries, concurrent expected-base publication, cursor refusal, scoped clear,
producer-change refusal/reset and malformed-data repair. It requires no guest compiler,
plugin invocation or external provider. [ADR 0014](../architecture/adr/0014-evidence.md)
owns the store layout and persistence contract.
This suite lives in `kyyn-porcelain-interpreters`; it includes a pure recording
DocumentPersistence proof of semantic publication and conflict refusal, plus the
existing real-Dhall/filesystem integration assertions.

`cabal test document-persistence --test-show-details=direct` in
`kyyn-plumbing-interpreters` checks scoped native locking across read/modify/replace,
scoped clearing (including lock continuity across clear), replacement-failure cleanup and lock release on
cancellation. It uses bytes, not evidence types or a guest compiler.

`cabal test file-acquisition --test-show-details=direct` checks native text/fingerprint
capture against a known digest, repeated reads, changed bytes and invalid UTF-8.
It requires no guest compiler and is included in the fast check.

`cabal test plugin-installation --test-show-details=direct` checks the installation
handler with write-forbidding refusal handlers and real Git/filesystem/Dhall
integration: local and file-URL sources, nested KBs, persisted origins, independent
copies, existing destinations (including empty directories and symlinks), and
unchanged KB HEAD. It is included in the fast check and does not compile or invoke guests.

Plugin installation targets an evolution, not the accepted root. The installed
`node tools/test-plugin-evolution.mjs EXECUTABLE` journey checks install into a Ready
target, stale-candidate refusal, check/accept, accepted-workspace refusal and plugin
inheritance through creation and acceptance of the next evolution. It uses real
Git, Dhall and MicroHs, and belongs to the full installed check.

`node tools/test-plugin-install.mjs EXECUTABLE` copies the host executable without
its runtime and tests CLI installation from committed local/file-URL packages into
a nested KB. It includes the first-party package, human/JSON results, origin revisions,
source and destination refusals, exclusions, independent copies and unchanged HEAD.
It runs in the installed integration check; the source fixture is committed in a
disposable repository, so the developer checkout need not be clean.

Guest API discovery has two focused checks: `cabal test guest-catalogue
--test-show-details=direct` exercises the read-only catalogue capability and real
Dhall codec, and `KYYN_TEST_ROOT="$PWD"
cabal test guest-api --test-show-details=direct` checks real MicroHs exports,
reexports and abstraction. The latter recompiles copies of the SDK with all
displayed signatures/aliases substituted and compares checked exports; it is in full
integration. Data/newtype fixtures additionally recompile projected public
constructors and compare their types up to variable renaming, covering records,
GADTs, abstract headers and selective reexports. These compiler checks are not in fast
checks. Constructor/accessor and upstream transformer signatures are compiled as
annotation witnesses; a CPP fixture checks branch selection and documentation.
`node tools/test-guest-api.mjs INSTALLED_EXECUTABLE`
tests a copied executable/catalogue-only bundle with no KB, Git, SDK sources or
compiler, including human/JSON results and refusals. It is included in the
installed integration check.

- **Available fast check:** `bash tools/test.sh`: documentation/import checks, native
  compilation, process/filesystem tests and pure metadata codec/adapter/contract tests.
  `cabal test cli-arguments --test-show-details=direct` checks pure CLI parsing,
  KB-selection defaults/overrides, command routing, help and invalid arguments.
  It does not execute KB operations or prove the installed CLI journey.
  `cabal test cli-adapters --test-show-details=direct` uses pure recording handlers
  to check explicit snapshot selection, validation before root browsing, candidate
  checking without root reopening/evolution execution, missing-candidate refusal,
  Unicode rendering, structured diagnostics and publication/interruption exit codes.
  `node tools/test-cli-selection.mjs "$(cabal list-bin exe:kyyn-v2)"` exercises the
  actual executable against disposable Git repositories without a runtime or
  valid schema: nested/multiple KBs, cwd default, symlink resolution, missing
  selections and detached recovery. It does not compile guests.
  Git discovery tests cover root/nested directories, non-repositories and bare
  repositories, with missing directories/executables remaining operational failures.
  Publication fixtures inspect a draft's saved report and an accepted archive
  after its candidate pointer is removed and its live manifest is malformed.
  The native Dhall boundary has a focused `cabal test dhall-values --test-show-details=direct`
  check, also included in the fast check; it does not compile guest code.
  `cabal test roots --test-show-details=direct` checks RootStore materialization
  and reopening from immutable file trees through the Dhall interpreter. It is
  included in the fast check and does not compile guest code or publish Git refs.
  The same suite exercises manifest-driven RootOpening with the real Dhall and
  RootStore handlers and recording schema/Git test handlers. It checks source/SDK
  capture and revision forwarding, not a second real-compiler execution.
  Source-only Git capture excludes fact blobs before loading bytes, retaining
  examples and other non-fact files. Git tests temporarily make an excluded blob
  unavailable: filtered capture succeeds, unfiltered capture fails, and the blob
  is restored. Exclusion matching preserves similarly prefixed sibling paths.
  Source-only opening is checked with absent/corrupt facts and explicit revision
  forwarding. Workspace tests use real Dhall with pure projection/matching:
  malformed manifests/layout, input additions/edits/deletions, and exclusion of
  lifecycle state and notes. They neither compile drafts nor verify archives.
  Evolution capture tests combine real filesystem/Dhall with recording RootOpening:
  repository-root/nested KB paths, exact Before copies, revision changes,
  target preparation, live matching without source loading, and diagnostics versus operational
  failures. No new MicroHs or Git execution is involved in those capture tests.
  Evolution execution tests use real Dhall/filesystem/process handling and recording
  schema/compiler handlers. They check captured Before input reuse without RootOpening,
  contract/source mismatch, closure deduplication/collisions, generated endpoint steps,
  generated entry selection and preparation/refusal/runtime/protocol failure distinctions.
  Recording counts forbid repeated Before opening and any schema inspection during
  execution. Workspace discovery tests use real RootOpening/RootStore/Dhall with
  recorded Git/schema/API handlers: each tree read excludes facts, each endpoint is
  inspected once, Before mismatch stops before target inspection, bad targets stop
  before API inspection, and repair does not reuse stale results. Missing/invalid
  evolution bodies are excluded; candidate, lifecycle, validator and execution
  operations are unavailable or rejected. No real guest compilation is involved
  in these native tests.
  Candidate tests in the roots suite check Dhall contract-description round trips
  (all type constructors and metadata), refusal of forward/cyclic/out-of-range
  type references,
  exact context/root/report persistence, immutable repeated saves, missing/stale/corrupt
  selections and failed publication preserving the last result. Application uses a
  recording evolution handler with real RootStore/Dhall; checking records RootExecution
  calls. Combined check tests cover capture/evaluation, saving before validation,
  rejected-candidate retention, failed evaluation leaving the pointer unchanged and
  passing warnings through. Reload has no source-opening/compiler path and does not restore Validated.
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
  Publication fixtures separately compose the full native application/store/Git
  path: create/capture, recording guest output with real report construction,
  save/fresh checks, refusal, atomic publication, reopening and explicit recovery.
  They cover two drafts, root-level/nested KBs, deletion, stale/rebased and shared
  drafts, invalid/missing candidates, workspace/root edits, detached/changed branch,
  same/different-workspace CAS races, index-lock synchronization failure, injected
  asynchronous interruption immediately after a successful ref update, recovery
  without candidate files or a valid live manifest, later-head repair, archive
  removal and reacceptance. Direct publication/recovery forbid source-opening and
  validation calls. Schema inspection, guest computation and validation are recording
  handlers: these fixtures are not a real-MicroHs or installed-CLI integration check.
  Creation is checked by immediately capturing its returned workspace, including
  repeated labels, source rejection before allocation and failed writes. Workspace
  encoding round-trips through real Dhall, preserving non-manifest file bytes.
  Creation/capture use EvolutionAuthoring. Candidate and lifecycle/history tests
  install EvolutionStore with no RootOpening effect or placeholder handler; their
  interpreter rows require no compiler or SDK.
  RootExecution tests use a recording compiler handler, a separate GuestExecution
  handler and small shell fixtures
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
  Scoped checkout fixtures also check branch/head refusal, staged/working changes
  that cancel each other, ignored root files, deletion, preservation of unrelated
  staged/working/untracked files and another draft, tracked/untracked selected
  workspaces, and synchronization retry after an index-lock failure. This is Git
  plumbing evidence, not a complete acceptance workflow.
  `cabal test file-trees --test-show-details=direct` checks local directory capture
  without running the process cancellation or MicroHs suites; it is included in
  the fast check.
  It also checks exclusive named directory reservation, one winner under concurrent
  creation, existing-file/directory preservation and missing-parent errors.
  Random private-directory allocation has a seeded collision
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
  `tools/test-guest.sh` stages the native compiler/evaluator/preprocessor and the
  native test suite inspects authored types, generates codecs, compiles them and
  exchanges runtime values with the resulting guest. It does not substitute GHC
  for guest execution. Captured source compilation uses GuestCompilation and
  emits bytecode consumed through GuestExecution by the bundled evaluator, not
  C-compiled guest binaries. GuestExecution owns both one-shot and conversational
  invocation; compile-only tests do not install execution handlers.
  Process and filesystem tests exercise scoped cleanup, real children, byte pipes, failures and
  cancellation; their reaping assertions currently require POSIX (Linux in CI).
  The first CLI is under development; plugin and Web builds do not exist yet.
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

`bash tools/test-installed.sh` locally installs the development CLI and bundled runtime in
a disposable prefix, compares native/self-hosted MicroHs bytecode for a
metadata entry, then runs the `installed-journey` suite. It is included
only in `--full`, not the default check. The fixture uses real Git, Dhall and
MicroHs: a schema-changing evolution is evaluated and accepted in separate
processes, its archived report survives cache removal, and an inherited required
example rejects a later deletion until the author deliberately retires that
assertion. Fixture setup uses the existing example encoder; it is not a second
on-disk format or a schema-aware production kernel. This complements the native
recording-handler tests for publication races and absence of evolution replay.

`node tools/test-cpp-paths.mjs INSTALLED_EXECUTABLE` is a focused installed check
for native schema/API inspection and guest compilation with CPP enabled. It copies
the runtime into a path containing spaces, single quotes and Unicode, and uses
a similarly named KB directory. It is included in the full
installed check and can be run independently for compiler updates.
This fixture uses a space-free compiler temporary directory; CPP source-location
handling under space-containing temporary paths is tracked in
[issue #109](https://github.com/drshade/kyyn-v2/issues/109).

The installed check also runs `tools/test-initialization.mjs`: an empty KB is
initialized through the CLI and evolved into its first collection. It checks
new/existing/nested repositories, edited entries/validators through the single check
command, rejected candidate inspection and earlier-result retention after compilation
failure, unrelated staged/working-file preservation,
read-only refusals and explicit recovery after an index-lock synchronization
failure. Run it independently with the installed executable path, or pass a
runtime directory as its second argument when using a development executable.

On hosts where a sandbox creates transient ancestor `/tmp/.git` metadata, initialization-test refusals are environmental; run the installed journey with `TMPDIR` elsewhere, for example `TMPDIR=/var/tmp bash tools/test-installed.sh`.

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
