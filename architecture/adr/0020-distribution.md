---
id: 0020
title: 'One installation supplies the execution toolchain'
status: proposed
date: 2026-09-09
---
# One installation supplies the execution toolchain

Basis: owner-established scope: Linux, macOS and Windows; Windows via WSL is
acceptable initially. Installation feasibility remains to be proved.

## Context

“Works without a toolchain” must hold on an ordinary user's machine, not just
with an engineer's Cabal cache and compiler executables nearby.
Kyyn is for regular users, not only developers. The owner expects agents to do
most setup initially; hiding toolchain work does not require a graphical installer.

## Decision

Provide an agent-drivable install path yielding the native kernel, pinned MicroHs
compiler and evaluator, `cpphs`, base/SDK libraries, chosen guest codecs, necessary native
libraries, and web assets. Include dependency licenses/notices. Runtime package
compilation uses these bundled tools and captured local source, not arbitrary
system Cabal resolution or a network download during validation.

The SDK's fact-editing dependencies ship as the small unmodified transformers
source subset recorded in [vendored inputs](../../vendor/README.md), with its
license. The guest compiler adapter selects its supported CPP branches; users
do not install another package manager or fetch libraries to edit a fact.

The staged compiler is the GHC-built pinned MicroHs described in
[ADR 0002](0002-runtime.md); GHC is needed to build it, not to execute KB code.
The source selection is unchanged, but native library dependencies and notices
still need distribution review; compiler parity is not a clean-machine proof.

The development executable is temporarily named `kyyn-v2` to coexist with
kyyn-v1's `kyyn`. The local installer deploys the staged bundle under the selected
prefix's `lib/kyyn-v2` and links `bin/kyyn-v2` to it. Runtime discovery resolves
that link before locating the bundled assets. Cabal's executable installation alone
does not provision these assets; the development script reuses the complete
staging build. [Developer usage](../../docs/cli-development.md) owns the commands.
This is a source-build convenience, not the cross-platform release installer.

Installing Kyyn itself may download and verify pinned release artifacts and
required dependencies. This trusted toolchain distribution is distinct from
installing a tap plugin: under ADR 0015, plugin installation vendors source and
resolved source dependencies, then Kyyn compiles them locally. No tap-supplied
executable or plugin attestation service is required.
Make installation safe to rerun and provide a structured account
of installed versions, resolved paths, missing requirements and next actions.
The bootstrap supplies the initial command; documentation must not assume
`kyyn install` already exists on a machine with no Kyyn. Exact command names are
illustrative. A readiness/doctor operation checks the environment and a small
offline compile/execution without making unrelated changes.

The result must tell an agent what is usable and what still needs attention,
including partial setup. A selected value shape is sufficient; this is not a
new persisted installation workflow:

```haskell
data SetupReport = SetupReport
  { installed   :: [InstalledComponent]
  , outstanding :: [SetupRequirement]
  }

data SetupRequirement
  = MissingComponent ComponentName
  | PermissionRequired Text
  | AuthenticationRequired Text
  | UnsupportedConfiguration Text
```

`InstalledComponent` records verified version and resolved location. A nonempty
`outstanding` list is not success, and setup must not secretly satisfy a permission
request by escalating privilege. Readiness uses the same report vocabulary but
does not provision dependencies. Actual installation and readiness are distinct
commands even if the CLI presents them under one command group.

Prefer unattended setup where possible. Required OS permissions or human
authentication become explicit actionable needs-input results, not hidden prompts
or assumed authority to install privileged packages. The human need not understand
MicroHs, PATH or MCP configuration for their agent to get them to a working KB.
Graphical installers, desktop launchers, self-update and automatic MCP client
registration are not initial requirements. See ADR 0025 for the full journey.

Source/developer and release builds may use GHC, a C compiler and Node.js. These
are build dependencies, not requirements on an ordinary plugin user's machine.
Use Node.js tooling to build the Web UI into static HTML, CSS, JavaScript and other
browser assets. Package the resulting assets with Kyyn and serve them through the
native application. Browser JavaScript runs in the user's browser; the installed
application needs no Node.js server, package manager, frontend build or development
server. Embedding the assets versus shipping an accompanying asset directory is a
packaging choice, not a different runtime architecture. The repository's build and
packaging entry points are located by [ADR 0026](0026-repository-layout.md).

Alex-generated scanners or other generated dependency
sources are release build inputs/artifacts, not automatically new user toolchains.
Use absolute paths for bundled tools, including `MHSCPPHS`, rather than requiring
PATH mutation. Adding cpphs to the prototype bootstrap is evidence of feasibility,
not complete production wiring.

Separate selected vendored source/dependencies, disposable compiled caches,
per-KB local secrets and authored KB files. Vendored source and remote-origin
information travel with the KB; generated executables do not. Build identity under ADR 0006 includes
source/contract/compiler/options/SDK/dependencies; changing runtime version
invalidates binaries, not accepted facts. No claim that
combinator artifacts are portable across arbitrary runtime versions/platforms.
These are local build correctness rules, not plugin compatibility declarations.
The first release uses the source-update/compiler/Git repair model in ADR 0015;
shipping a release does not require introducing version pins or negotiation for
plugins and their SDK expectations.

Propose canonical Git plumbing through a tested Git executable behind the Git
capability, avoiding maintenance of a libgit2 binding initially. Bundling is not
settled: the installer may provision Git or locate and verify a compatible
installation. Missing Git is an actionable installation requirement, never an
undisclosed runtime surprise left for the ordinary user to diagnose.

## Alternatives and consequences

Reject “install the right compiler yourself”, dynamic online dependency resolution
inside checking, and a toolchain per plugin language. Platform scope is decided,
but MicroHs portability alone does not prove a working distribution. Work out
native dependency packaging, platform launch/trust requirements, local secret store
and license obligations for Linux, macOS and the Windows/WSL journey. Verify those
details on the target systems before release claims. WSL acceptance does not
create a promise of native Windows support on a particular roadmap.

## Verification

From published artifacts on each supported OS: create KB, install a tap, compile
changed source, exchange Unicode/exact values, validate/evolve, accept/reopen and
render without GHC/Node/Rust/Python or ambient cpphs. Open and use the packaged Web
UI without rebuilding assets, contacting a development server or requiring Node.js.
Repeat offline after explicit
installation, including a rebuild after deleting disposable plugin artifacts.
Test corrupted/missing packages and report repair rather than silently
fetching different code. Fresh installation must not depend on this repository layout.
Test install reruns and readiness failures as well as success. Windows coverage
requires a Windows host exercising WSL launch, browser access, paths and the MCP
client-to-process connection; a Linux CI build alone is not that test. Build and
installation checks cover each supported execution target. Agent-managed MCP setup
must name the client/configuration tested, not claim universal client compatibility.
